part of 'engine.dart';

extension _AttackAssembly on GameKernel {
  void _assembleAttack(
    String playerId,
    List<String> targets,
    List<CardInstance> originals,
    void Function(String, List<CardInstance>) complete,
  ) {
    final actionId = state.id('action');
    final actor = _player(playerId).character;
    final cards = List<CardInstance>.of(originals);
    for (final card in actor.preparedCards) {
      cards.add(card);
      state.discardPile.add(card);
    }
    actor.preparedCards.clear();
    void finish() => complete(
      actionId,
      List.unmodifiable(_assembleRotatingCards(actor, actionId, cards)),
    );
    _activatePrey(actor, targets, actionId, cards);
    final traits = actor.traits
        .where((t) => t.definition.borrowAttackCard)
        .toList();
    if (_previewMode && traits.isNotEmpty) {
      throw const PreviewBoundary('unknownBorrowedCards');
    }
    void next(int index) {
      if (index == traits.length ||
          !actor.alive ||
          _blocked(actor, (s) => s.blockTraits) ||
          targets.isEmpty) {
        finish();
        return;
      }
      final owner = _character(targets.first);
      final candidates = owner.hand.where((c) => !c.disabled).toList();
      if (!owner.alive || candidates.isEmpty) {
        next(index + 1);
        return;
      }
      final card = candidates[_nextInt(candidates.length)];
      final held = state.cardCustody.hold(
        id: state.id('heldCard'),
        actionId: actionId,
        owner: owner,
        card: card,
        revealed: true,
      );
      state.revealedCards[card.instanceId] = card.definition.id;
      _event('cardBorrowed', {
        'actorId': actor.instanceId,
        'ownerId': owner.instanceId,
        'actionId': actionId,
        'instanceId': card.instanceId,
        'definitionId': card.definition.id,
      });
      final defenseBonus = [
        ...cards,
        card,
      ].fold(0, (sum, c) => sum + c.definition.defenseBonus * _cardScale(c));
      if (!card.definition.attacks ||
          defenseBonus <= -50 ||
          _blocked(actor, (s) => s.blockCards || s.blockAttackCards)) {
        _restoreAttackCard(held);
        next(index + 1);
        return;
      }
      final attach = state.id('option');
      final decline = state.id('option');
      state.choice = PendingChoice(
        id: state.id('choice'),
        playerId: playerId,
        kind: ChoiceKind.attackCard,
        options: [
          {
            'optionId': attach,
            'action': 'attach',
            'instanceId': card.instanceId,
            'definitionId': card.definition.id,
          },
          {
            'optionId': decline,
            'action': 'return',
            'instanceId': card.instanceId,
            'definitionId': card.definition.id,
          },
        ],
      );
      _choiceContinuation = (id) {
        if (id == attach) {
          cards.add(_effectiveCard(actor, card));
          _event('attackCardAttached', {
            'actorId': actor.instanceId,
            'actionId': actionId,
            'instanceId': card.instanceId,
          });
        } else {
          _restoreAttackCard(held);
        }
        next(index + 1);
      };
      _event('choiceOpened', {
        'choiceId': state.choice!.id,
        'playerId': playerId,
        'kind': ChoiceKind.attackCard.name,
      });
    }

    if (traits.isEmpty) {
      finish();
    } else {
      _flowSteps([_drainTriggers, () => next(0)]);
    }
  }

  void _restoreAttackCard(HeldCard held) {
    final before = held.owner.hand.length;
    state.cardCustody.restore(held, state.discardPile);
    _handCountIncreased(held.owner, before);
    _event('cardReturned', {
      'actionId': held.actionId,
      'ownerId': held.owner.instanceId,
      'instanceId': held.card.instanceId,
      'destination': held.owner.alive ? 'hand' : 'discardPile',
    });
  }

  void _returnAttackCards(String actionId) {
    _attackCaps.remove(actionId);
    _cardContentModule.finishAction(actionId);
    _preyModule.finishAction(actionId);
    for (final held
        in state.cardCustody.entries
            .where((h) => h.actionId == actionId)
            .toList()
            .reversed) {
      _restoreAttackCard(held);
    }
  }
}
