part of 'engine.dart';

extension _TraitMechanisms on GameKernel {
  RollResult _rerollPendingAttack(
    CharacterInstance actor,
    PendingResolution pending,
  ) {
    final rawSides =
        pending.forcedDiceSides ??
        pending.cards.fold<int>(
          pending.baseDiceSides,
          (sides, card) => card.definition.diceSides ?? sides,
        );
    return _attackRoll(
      actor,
      rawSides,
      pending.diceCount,
      actionId: pending.id,
      fixedMaximum: pending.diceLocked,
      rerollOf: pending.diceRoll?.id,
    );
  }

  void _configuredTurnStart(CharacterInstance actor) {
    if (!actor.alive || _blocked(actor, (s) => s.blockTraits)) return;
    final steps = <void Function()>[];
    for (final trait in actor.traits) {
      if (trait.definition.mechanisms.get<DamageResourceRule>()
          case final resource?) {
        steps.add(
          () => _modifyVariable(
            actor,
            actor,
            ModifyVariable(
              resource.variable,
              operation: VariableOperation.add,
              input: VariableInput(literal: resource.turnGain),
            ),
          ),
        );
      }
      if (trait.definition.mechanisms.has<ShieldLifeCycleRule>()) {
        steps.add(() {
          if (actor.shield == 0) {
            _runAbility(
              actor,
              [actor.instanceId],
              [const ShieldEffect(1)],
              () {},
            );
          } else {
            final amount = actor.shield;
            actor.shield = 0;
            actor.temporaryShields.clear();
            _effects(actor, [actor.instanceId], [RestoreLife(amount)]);
            _event('shieldConverted', {
              'actorId': actor.instanceId,
              'amount': amount,
            });
          }
        });
      }
      if (trait.definition.mechanisms.has<SkillBorrowRule>()) {
        steps.add(() => _offerSkillLease(actor));
      }
    }
    _flowSteps(steps);
  }

  void _automaticAction(
    CharacterInstance actor,
    void Function() start, {
    void Function()? complete,
  }) {
    final parentActor = _automaticActor;
    final parentAction = _observedAction;
    final childStart = state.events.length;
    final settlingAttack = _settlingAttack;
    final diceFinal = _attackDiceFinal;
    final attackDamage = _attackDamage;
    final adjustment = _attackAdjustment;
    final powerAdjustment = _attackPowerAdjustment;
    final effectMultiplier = _attackEffectMultiplier;
    final committedBonus = _committedAttackBonus;
    final once = Set<EffectDefinition>.of(_oncePerAttackEffects);
    final declared = Map<String, int>.of(_declaredAttackPower);
    final guards = Map<String, bool>.of(_attackGuardResults);
    final reactions = Set<String>.of(_attackGuardReactions);
    final reinforcement = Map<CardInstance, bool>.of(_temporaryReinforcement);
    final prepared = _preparedSelections.toList();
    final preparedOptions = _preparedOptions.toList();
    final preparedCards = _preparedCardChoices.toList();
    final records = Map<String, RecordedAction>.of(_recordingModule.committed);
    final handChoices = Map<ChooseCards, List<CardInstance>>.of(
      _preparedHandCards,
    );
    final generatedChoices =
        Map<GenerateChosenCard, (CardDefinition, String?)>.of(
          _preparedGeneratedCards,
        );
    final bindings = Map<ChooseTargets, List<String>>.of(_preparedBindings);
    _preparedHandCards.clear();
    _preparedGeneratedCards.clear();
    _preparedBindings.clear();
    _preparedSelections.clear();
    _preparedOptions.clear();
    _preparedCardChoices.clear();
    _temporaryReinforcement.clear();
    _recordingModule.clearCommitted();
    _automaticActor = actor;
    _observedAction = null;
    _automaticRestores.add(() {
      for (final entry in _temporaryReinforcement.entries) {
        entry.key.reinforced = entry.value;
      }
      parentAction?.excludedEventRanges.add((childStart, state.events.length));
      _settlingAttack = settlingAttack;
      _attackDiceFinal = diceFinal;
      _attackDamage = attackDamage;
      _automaticActor = parentActor;
      _observedAction = parentAction;
      _attackAdjustment = adjustment;
      _attackPowerAdjustment = powerAdjustment;
      _attackEffectMultiplier = effectMultiplier;
      _committedAttackBonus = committedBonus;
      _oncePerAttackEffects
        ..clear()
        ..addAll(once);
      _declaredAttackPower
        ..clear()
        ..addAll(declared);
      _attackGuardResults
        ..clear()
        ..addAll(guards);
      _attackGuardReactions
        ..clear()
        ..addAll(reactions);
      _temporaryReinforcement
        ..clear()
        ..addAll(reinforcement);
      _preparedSelections
        ..clear()
        ..addAll(prepared);
      _preparedOptions
        ..clear()
        ..addAll(preparedOptions);
      _preparedCardChoices
        ..clear()
        ..addAll(preparedCards);
      _preparedHandCards
        ..clear()
        ..addAll(handChoices);
      _preparedGeneratedCards
        ..clear()
        ..addAll(generatedChoices);
      _preparedBindings
        ..clear()
        ..addAll(bindings);
      _recordingModule.restoreCommitted(records);
      complete?.call();
    });
    start();
  }

  void _generatedCardAction(
    CharacterInstance actor, {
    void Function()? complete,
    CardDefinition? definition,
    String? selectedTarget,
  }) {
    void done() => complete?.call();
    if (_previewMode) throw const PreviewBoundary('generatedActionRequired');
    if (_triggerBudget-- <= 0) {
      _triggerBudgetExhausted = true;
      _generatedRequests.clear();
      _event('triggerBudgetExceeded', {'limit': 256});
      done();
      return;
    }
    if (!actor.alive ||
        setup.deck.isEmpty ||
        _blocked(actor, (s) => s.blockCards)) {
      done();
      return;
    }
    definition ??= catalog.cards[setup.deck[_nextInt(setup.deck.length)]]!;
    final selectedDefinition = definition;
    final card = CardInstance(state.id('card'), selectedDefinition);
    _event('cardGenerated', {
      'actorId': actor.instanceId,
      'instanceId': card.instanceId,
      'definitionId': selectedDefinition.id,
    });
    if (selectedDefinition.tags.any((tag) => _cardTagRestricted(actor, tag)) ||
        (selectedDefinition.attacks &&
            _blocked(actor, (s) => s.blockAttack || s.blockAttackCards))) {
      state.discardPile.add(card);
      _event('generatedActionSkipped', {
        'actorId': actor.instanceId,
        'reason': 'cardBlocked',
      });
      done();
      return;
    }
    final needsTarget =
        selectedDefinition.attacks ||
        selectedDefinition.effects.any(
          (e) => e.target == EffectTarget.selected,
        );
    final targets = state.players
        .map((p) => p.character)
        .where(
          (c) =>
              c.alive &&
              (!selectedDefinition.attacks ||
                  (!identical(c, actor) &&
                      _incomingAttackTargetAllowed(actor, c) &&
                      (actor.nextAttackTargetId == null ||
                          actor.nextAttackTargetId == c.instanceId) &&
                      (actor.extraTurnAttackTarget == null ||
                          actor.extraTurnAttackTarget == c.instanceId))),
        )
        .toList();
    void play(String? target) {
      _automaticAction(actor, () {
        final before = actor.hand.length;
        actor.hand.add(card);
        _handCountIncreased(actor, before);
        final player = state.players.firstWhere((p) => p.character == actor);
        _playCards(
          player,
          PlayCardsCommand(player.id, [card.instanceId], targetId: target),
        );
      }, complete: done);
    }

    if (selectedTarget != null) {
      play(selectedTarget);
      return;
    }
    if (!needsTarget) {
      play(null);
      return;
    }
    if (targets.isEmpty) {
      state.discardPile.add(card);
      done();
      return;
    }
    _mechanismChoice(actor, [
      for (final target in targets)
        {
          'action': 'generatedTarget',
          'targetId': target.instanceId,
          'definitionId': selectedDefinition.id,
        },
    ], (o) => play(o['targetId']! as String));
  }
}
