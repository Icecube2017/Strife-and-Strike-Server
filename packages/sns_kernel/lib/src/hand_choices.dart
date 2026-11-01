part of 'engine.dart';

extension _HandChoices on GameKernel {
  List<CardInstance> _handCandidates(
    CharacterInstance actor,
    List<String> selected,
    ChooseCards effect,
  ) => _effectTargets(actor, selected, effect.target)
      .expand((c) => c.hand)
      .where(
        (c) =>
            !c.disabled &&
            c.definition.tags.length >= effect.minimumTags &&
            (effect.anyTags.isEmpty ||
                effect.anyTags.any(c.definition.tags.contains)) &&
            _matchesCard(
              c,
              effect.query,
              actor,
              state.players
                  .map((p) => p.character)
                  .firstWhere((o) => o.hand.contains(c)),
            ),
      )
      .toList();

  void _openHandChoice(
    CharacterInstance actor,
    List<String> selected,
    ChooseCards effect,
    void Function(List<CardInstance>) complete,
  ) {
    final minimum = _amount(0, effect.minimum, actor, actor);
    final maximum = _amount(0, effect.maximum, actor, actor);
    if (minimum < 0 || maximum < minimum || maximum > 128) {
      throw StateError('Invalid hand choice range');
    }
    final chosen = <CardInstance>[];
    final player = state.players.firstWhere((p) => p.character == actor);
    final queryLocals = _abilityLocals;
    final queryNumber = _abilityNumber;
    final queryTrigger = _currentTrigger;
    final queryStatus = _chosenStatus;
    late void Function() open;
    void openBody() {
      final candidates = _handCandidates(
        actor,
        selected,
        effect,
      ).where((c) => !chosen.contains(c)).toList();
      if (chosen.length >= maximum || candidates.isEmpty) {
        if (chosen.length < minimum) {
          throw StateError('Not enough unlocked eligible cards');
        }
        complete(List.unmodifiable(chosen));
        return;
      }
      final options = <Map<String, Object?>>[];
      final resolved = <String, CardInstance>{};
      for (final card in candidates) {
        final id = state.id('option');
        resolved[id] = card;
        options.add({
          'optionId': id,
          'instanceId': card.instanceId,
          'definitionId': card.definition.id,
        });
      }
      final done = chosen.length >= minimum ? state.id('option') : null;
      if (done != null) options.add({'optionId': done, 'done': true});
      state.choice = PendingChoice(
        id: state.id('choice'),
        playerId: player.id,
        kind: ChoiceKind.discardCard,
        options: options,
        details: {
          'min': minimum,
          'max': maximum,
          'destination': effect.destination.name,
          'selectedCardIds': chosen.map((c) => c.instanceId).toList(),
        },
      );
      _choiceContinuation = (id) {
        if (id == done) {
          complete(List.unmodifiable(chosen));
        } else {
          chosen.add(resolved[id]!);
          open();
        }
      };
      _event('choiceOpened', {
        'choiceId': state.choice!.id,
        'playerId': player.id,
        'kind': 'discardCard',
      });
    }

    open = () {
      final oldLocals = _abilityLocals;
      final oldNumber = _abilityNumber;
      final oldTrigger = _currentTrigger;
      final oldStatus = _chosenStatus;
      _abilityLocals = queryLocals;
      _abilityNumber = queryNumber;
      _currentTrigger = queryTrigger;
      _chosenStatus = queryStatus;
      try {
        openBody();
      } finally {
        _abilityLocals = oldLocals;
        _abilityNumber = oldNumber;
        _currentTrigger = oldTrigger;
        _chosenStatus = oldStatus;
      }
    };

    open();
  }

  void _commitHandCards(
    CharacterInstance actor,
    List<String> selected,
    ChooseCards effect,
    List<CardInstance> cards,
  ) {
    final owners = _effectTargets(actor, selected, effect.target);
    final recipients = effect.destination == CardDestination.hand
        ? _effectTargets(
            actor,
            selected,
            effect.recipient,
          ).where((c) => c.alive).toList()
        : <CharacterInstance>[];
    if (effect.destination == CardDestination.hand && recipients.length != 1) {
      throw StateError('Card transfer requires one recipient');
    }
    final before = {
      for (final recipient in recipients) recipient: recipient.hand.length,
    };
    for (final card in cards) {
      final owner = owners.singleWhere((c) => c.hand.contains(card));
      if (card.disabled) throw StateError('Selected card became locked');
      owner.hand.remove(card);
      _performance.resourceChange(
        actor,
        owner,
        -1,
        resource: StatisticsResource.hand,
      );
      switch (effect.destination) {
        case CardDestination.discard:
          state.discardPile.add(card);
          _discardedCount++;
        case CardDestination.hand:
          recipients.single.hand.add(card);
          _performance.resourceChange(
            actor,
            recipients.single,
            1,
            resource: StatisticsResource.hand,
          );
        case CardDestination.deck:
          state.drawPile.insert(_nextInt(state.drawPile.length + 1), card);
      }
      _event('cardsLost', {
        'actorId': owner.instanceId,
        'count': 1,
        if (_interactionRulesVersion >= 5 &&
            effect.destination == CardDestination.discard)
          'cards': [card.instanceId],
      });
      _event('handCardMoved', {
        'actorId': actor.instanceId,
        'sourceId': owner.instanceId,
        if (recipients.isNotEmpty) 'targetId': recipients.single.instanceId,
        'instanceId': card.instanceId,
        'definitionId': card.definition.id,
        'destination': effect.destination.name,
      });
    }
    for (final entry in before.entries) {
      _handCountIncreased(entry.key, entry.value, source: actor);
    }
  }
}

extension _GeneratedChoices on GameKernel {
  void _openGeneratedChoice(
    CharacterInstance actor,
    GenerateChosenCard effect,
    void Function(CardDefinition, String?) complete,
  ) {
    final definitions = setup.deck
        .toSet()
        .where(
          (id) =>
              !effect.exclude.contains(id) &&
              _matchesCard(
                CardInstance('definition_$id', catalog.cards[id]!),
                effect.query,
                actor,
                actor,
              ),
        )
        .map((id) => catalog.cards[id]!)
        .toList();
    if (_previewMode) {
      throw const PreviewBoundary('generatedCardChoiceRequired');
    }
    if (definitions.isEmpty) throw StateError('No eligible initial-deck card');
    _mechanismChoice(
      actor,
      [
        for (final d in definitions)
          {'action': 'chooseGeneratedCard', 'definitionId': d.id},
      ],
      (o) {
        final definition = catalog.cards[o['definitionId']]!;
        if (effect.use == GeneratedCardUse.nextAttack ||
            (!definition.attacks &&
                !definition.effects.any(
                  (e) => e.target == EffectTarget.selected,
                ))) {
          complete(definition, null);
          return;
        }
        final candidates = state.players
            .map((p) => p.character)
            .where(
              (c) =>
                  c.alive &&
                  (!definition.attacks ||
                      (c != actor && _incomingAttackTargetAllowed(actor, c))),
            )
            .toList();
        if (candidates.isEmpty) {
          throw StateError('No legal generated-card target');
        }
        _mechanismChoice(actor, [
          for (final c in candidates)
            {'action': 'generatedTarget', 'targetId': c.instanceId},
        ], (target) => complete(definition, target['targetId']! as String));
      },
    );
  }
}
