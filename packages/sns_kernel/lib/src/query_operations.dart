part of 'engine.dart';

extension _QueryOperations on GameKernel {
  List<Map<String, Object?>> _objectCandidates(
    CharacterInstance actor,
    List<String> selected,
    ChooseObjects e, {
    bool enemiesOnly = false,
  }) {
    final owners = _effectTargets(
      actor,
      selected,
      e.target,
    ).where((c) => e.query.includeDead || c.alive).toList();
    final rows = _collectionRows(e.query, actor, owners);
    final chooser = e.chooser == ChoiceChooser.target ? owners.single : actor;
    return rows.where((r) {
      if (enemiesOnly &&
          e.query.kind == CollectionKind.characters &&
          !_enemy(actor, _character(r['instanceId']! as String))) {
        return false;
      }
      if (e.query.kind == CollectionKind.cards && r['disabled'] == true) {
        return false;
      }
      if (e.query.kind == CollectionKind.marks) {
        final definition = catalog.marks[r['definitionId']]!;
        return definition.visibility == MarkVisibility.public ||
            r['ownerId'] == chooser.instanceId;
      }
      return true;
    }).toList();
  }

  void _openObjectChoice(
    CharacterInstance actor,
    List<String> selected,
    ChooseObjects e,
    void Function(List<Map<String, Object?>>) complete, {
    bool enemiesOnly = false,
  }) {
    if (_previewMode) throw const PreviewBoundary('objectSelectionRequired');
    final minimum = _amount(0, e.minimum, actor, actor);
    final maximum = _amount(0, e.maximum, actor, actor);
    if (minimum < 0 || maximum < minimum || maximum > 128) {
      throw StateError('Invalid object choice range');
    }
    final owners = _effectTargets(
      actor,
      selected,
      e.target,
    ).where((c) => c.alive).toList();
    final chooser = e.chooser == ChoiceChooser.target ? owners.single : actor;
    final player = state.players.firstWhere((p) => p.character == chooser);
    final chosen = <Map<String, Object?>>[];
    final queryLocals = _abilityLocals;
    final queryNumber = _abilityNumber;
    final queryTrigger = _currentTrigger;
    final queryStatus = _chosenStatus;
    late void Function() open;
    void openBody() {
      final candidates =
          _objectCandidates(actor, selected, e, enemiesOnly: enemiesOnly)
              .where(
                (r) => !chosen.any((c) => c['instanceId'] == r['instanceId']),
              )
              .toList();
      if (chosen.length >= maximum || candidates.isEmpty) {
        if (chosen.length < minimum) {
          throw StateError('Not enough eligible object choices');
        }
        complete(List.unmodifiable(chosen));
        return;
      }
      final resolved = <String, Map<String, Object?>>{};
      final options = <Map<String, Object?>>[];
      if ((e.query.kind == CollectionKind.cards ||
              e.query.kind == CollectionKind.skills) &&
          !e.reveal) {
        _shuffle(candidates);
      }
      for (final row in candidates) {
        final id = state.id('option');
        resolved[id] = row;
        final hidden =
            !e.reveal &&
            ((e.query.kind == CollectionKind.skills &&
                    row['ownerId'] != chooser.instanceId) ||
                (e.query.kind == CollectionKind.cards &&
                    ((e.query.zone == CardZone.hand &&
                            row['ownerId'] != chooser.instanceId) ||
                        e.query.zone == CardZone.drawPile)));
        options.add({
          'optionId': id,
          if (hidden)
            'hidden': true
          else ...{
            'instanceId': row['instanceId'],
            'definitionId': row['definitionId'],
            if (row['ownerId'] != null) 'targetId': row['ownerId'],
            for (final key in ['stacks', 'intensity', 'count', 'cooldown'])
              if (row.containsKey(key)) key: row[key],
          },
        });
      }
      if (options.any((o) => o['hidden'] == true)) _shuffle(options);
      final done = chosen.length >= minimum ? state.id('option') : null;
      if (done != null) options.add({'optionId': done, 'done': true});
      final kind = switch (e.query.kind) {
        CollectionKind.cards => ChoiceKind.discardCard,
        CollectionKind.statuses => ChoiceKind.status,
        CollectionKind.marks => ChoiceKind.mark,
        CollectionKind.skills => ChoiceKind.resetCooldown,
        CollectionKind.characters => ChoiceKind.character,
        CollectionKind.records => throw StateError(
          'Record queries do not open choices',
        ),
      };
      state.choice = PendingChoice(
        id: state.id('choice'),
        playerId: player.id,
        kind: kind,
        options: options,
        details: {
          'bind': e.bind,
          'min': minimum,
          'max': maximum,
          'selectedCount': chosen.length,
        },
      );
      _choiceContinuation = (id) {
        if (id == done) {
          complete(List.unmodifiable(chosen));
          return;
        }
        chosen.add(resolved[id]!);
        open();
      };
      _event('choiceOpened', {
        'choiceId': state.choice!.id,
        'playerId': player.id,
        'kind': kind.name,
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

  void _editQueryMarks(
    CharacterInstance actor,
    CharacterInstance target,
    EditMarks e,
    int multiplier,
  ) {
    final matches = target.marks
        .where(
          (m) => _matchesMarkData(_markQueryData(m), e.query, actor, target),
        )
        .toList();
    final amount = _amount(0, e.amount, actor, target) * multiplier;
    for (final mark in matches) {
      _modifyMark(
        actor,
        target,
        ModifyMark(
          mark.definition.id,
          amount: e.mode == StatusEditMode.remove ? 0 : amount,
          set: e.mode != StatusEditMode.add,
          references: mark.references,
        ),
        1,
        preserveSource: true,
        originalSourceId: mark.sourceId,
      );
    }
  }

  void _transferQueryMarks(
    CharacterInstance actor,
    CharacterInstance from,
    List<String> selected,
    TransferMarks e,
  ) {
    final to = _effectTargets(
      actor,
      selected,
      e.to,
    ).where((c) => c.alive).single;
    if (to == from) return;
    final matches = from.marks
        .where((m) => _matchesMarkData(_markQueryData(m), e.query, actor, from))
        .toList();
    final limit = e.amount == null
        ? 1000000
        : _amount(0, e.amount, actor, from).clamp(0, 1000000);
    for (final mark in matches) {
      final definition = mark.definition;
      final existing = to.marks
          .where(
            (m) =>
                m.definition.id == definition.id && m.sourceId == mark.sourceId,
          )
          .firstOrNull;
      final previous = existing?.count ?? 0;
      var capacity = definition.playerCountBonus == null
          ? definition.maxCount ?? 1000000
          : setup.players.length + definition.playerCountBonus!;
      if (definition.group != null && definition.groupLimit != null) {
        final others = to.marks
            .where(
              (m) => m != existing && m.definition.group == definition.group,
            )
            .fold(0, (n, m) => n + m.count);
        capacity = capacity.clamp(
          0,
          (definition.groupLimit! - others).clamp(0, 1000000),
        );
      }
      final amount = mark.count
          .clamp(0, limit)
          .clamp(0, (capacity - previous).clamp(0, 1000000));
      if (amount == 0) continue;
      final moved = _modifyMark(
        actor,
        to,
        ModifyMark(
          mark.definition.id,
          amount: amount,
          references: mark.references,
        ),
        1,
        preserveSource: true,
        originalSourceId: mark.sourceId,
      );
      if (moved > 0) {
        _modifyMark(
          actor,
          from,
          ModifyMark(mark.definition.id, amount: -moved),
          1,
          preserveSource: true,
          originalSourceId: mark.sourceId,
        );
      }
    }
  }

  void _editQuerySkills(
    CharacterInstance actor,
    CharacterInstance target,
    EditSkills e,
    int multiplier,
  ) {
    final matches = target.skills
        .where(
          (s) => _matchesSkillData(
            _skillQueryData(s, target.instanceId),
            e.query,
            actor,
            target,
          ),
        )
        .toList();
    final amount = _amount(0, e.amount, actor, target) * multiplier;
    for (final skill in matches) {
      final before = skill.cooldown;
      _setSkillCooldown(
        skill,
        (switch (e.mode) {
          StatusEditMode.add => before + amount,
          StatusEditMode.set => amount,
          StatusEditMode.remove => 0,
        }).clamp(0, 1000000),
      );
      _performance.cooldownChange(actor, target, skill.cooldown - before);
    }
  }

  void _moveQueryCards(
    CharacterInstance actor,
    List<String> selected,
    MoveCards e, {
    int multiplier = 1,
  }) {
    final owners = _effectTargets(
      actor,
      selected,
      e.target,
    ).where((c) => c.alive).toList();
    final recipient = e.destination == CardDestination.hand
        ? _effectTargets(
            actor,
            selected,
            e.recipient,
          ).where((c) => c.alive).single
        : null;
    final subject = owners.firstOrNull ?? actor;
    final candidates = _queryCards(e.zone, owners)
        .where((c) => !c.disabled && _matchesCard(c, e.query, actor, subject))
        .toList();
    final count = e.amount == null
        ? candidates.length
        : (_amount(0, e.amount, actor, subject) * multiplier).clamp(
            0,
            candidates.length,
          );
    if (e.random) _shuffle(candidates);
    final cards = candidates
        .where(
          (c) =>
              e.copy ||
              e.zone != CardZone.hand ||
              recipient == null ||
              !recipient.hand.contains(c),
        )
        .take(count)
        .toList();
    if (!e.copy && e.zone == CardZone.hand) {
      _commitHandCards(
        actor,
        selected,
        ChooseCards(
          minimum: const EffectValue(),
          maximum: const EffectValue(),
          target: e.target,
          destination: e.destination,
          recipient: e.recipient,
        ),
        cards,
      );
      return;
    }
    if (!e.copy &&
        (e.zone == CardZone.initialDeck || e.zone == CardZone.action)) {
      throw StateError('This card zone can only be copied');
    }
    final before = recipient?.hand.length ?? 0;
    for (final source in cards) {
      final card = e.copy
          ? CardInstance(state.id('card'), source.definition)
          : source;
      if (!e.copy) {
        (e.zone == CardZone.drawPile ? state.drawPile : state.discardPile)
            .remove(source);
      }
      switch (e.destination) {
        case CardDestination.hand:
          recipient!.hand.add(card);
          _performance.resourceChange(
            actor,
            recipient,
            1,
            resource: StatisticsResource.hand,
          );
          _event(e.copy ? 'cardCopied' : 'cardRetrieved', {
            'actorId': recipient.instanceId,
            'instanceId': card.instanceId,
            'definitionId': card.definition.id,
          });
        case CardDestination.discard:
          state.discardPile.add(card);
        case CardDestination.deck:
          state.drawPile.insert(_nextInt(state.drawPile.length + 1), card);
      }
    }
    if (recipient != null) {
      _handCountIncreased(recipient, before, source: actor);
    }
  }
}
