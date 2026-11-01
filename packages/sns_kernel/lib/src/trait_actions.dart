part of 'engine.dart';

extension _TraitActions on GameKernel {
  int _cardScale(CardInstance card) => card.reinforced ? 2 : 1;
  double _scaledMultiplier(double value, int scale) =>
      (1 + (value - 1) * scale).clamp(0, double.infinity);

  bool _canPrepareCards(CharacterInstance actor) =>
      actor.actionsRemaining > 0 &&
      !_blocked(actor, (s) => s.blockCards) &&
      actor.hand.any(
        (c) =>
            !c.disabled &&
            (!c.definition.attacks ||
                !_blocked(actor, (s) => s.blockAttackCards)),
      );

  int _activeLimitWindow(CharacterInstance actor, TraitAction action) =>
      action.limitWindow == CounterReset.personalRound
      ? actor.turnsStarted
      : state.round;

  int _actionDiscount(CharacterInstance actor) =>
      actor.statuses.fold<int>(0, (n, s) => n + s.definition.actionMpDiscount) +
      (_blocked(actor, (s) => s.blockTraits)
          ? 0
          : actor.traits.fold<int>(
              0,
              (n, t) => n + t.definition.actionMpDiscount,
            ));
  int _actionCost(CharacterInstance actor, int cost) =>
      (cost - _actionDiscount(actor)).clamp(0, 1000000000);

  bool _skipOpeningMpRecovery(MpRegenPhase phase) =>
      state.round == 1 &&
      !_firstRoundMpRecovery &&
      (_interactionRulesVersion < 17 || phase == MpRegenPhase.turnStart);

  void _regenerateMp(
    CharacterInstance actor, {
    MpRegenPhase phase = MpRegenPhase.turnStart,
  }) {
    if (actor.race.regenPhase != phase) return;
    // Round one skips start recovery, but end-recovering races still recover.
    // Games pinned before v17 keep the historical prohibition at both phases.
    // A skipped recovery does not advance the recovery clock.
    if (_skipOpeningMpRecovery(phase)) return;
    if (!actor.alive) return;
    if (_blocked(actor, (s) => s.blockMpRegen)) {
      _scoreBlockedNaturalMp(actor);
      return;
    }
    final race = actor.race;
    if (race.regenMode == MpRegenMode.refillAfterExhaustion) {
      if (!actor.refillAfterExhaustionPending) return;
      actor.refillAfterExhaustionPending = false;
      final before = actor.mp;
      actor.mp = before + _mpRecovery(actor, actor.value(Stat.maxMp) - before);
      _event('mpRegenerated', {
        'actorId': actor.instanceId,
        'amount': actor.mp - before,
        'nominalAmount': actor.mp - before,
        'overflow': 0,
      });
      return;
    }
    if (race.regenInterval <= 0) return;
    actor.regenProgress++;
    if (actor.regenProgress < race.regenInterval) return;
    actor.regenProgress = 0;
    final bonus = actor.statuses.fold<int>(
      0,
      (n, s) => n + s.definition.mpRegenPerIntensity * s.intensity,
    );
    final recovery =
        _amount(race.regenMp, race.regenMpValue, actor, actor) + bonus;
    final before = actor.mp;
    final adjusted = _mpRecovery(actor, recovery);
    actor.mp = (actor.mp + (actor.noMp ? 0 : adjusted)).clamp(
      _mpFloor(actor),
      actor.value(Stat.maxMp),
    );
    _scoreNaturalMp(actor, recovery - bonus, before, actor.mp);
    _event('mpRegenerated', {
      'actorId': actor.instanceId,
      'amount': actor.mp - before,
      'nominalAmount': recovery,
      'overflow': (adjusted - (actor.mp - before)).clamp(0, 1000000),
    });
  }

  void _commitActionAllowance(CharacterInstance actor) {
    _committedAttackBonus =
        actor.actionsRemaining <= actor.bonusActions.length &&
            actor.bonusActions.isNotEmpty
        ? actor.bonusActions.removeAt(0)
        : 0;
    for (final status
        in actor.statuses.where((s) => s.definition.expireOnAction).toList()) {
      _consumeStatus(actor, status, amount: status.stacks);
    }
    actor.actionsRemaining--;
  }

  int _traitMpCost(CharacterInstance actor, TraitAction action) =>
      action.mpCost +
      actor.statuses.fold<int>(0, (n, s) => n + s.definition.traitMpSurcharge);

  String? _traitDisabled(
    CharacterInstance actor,
    TraitInstance trait, {
    TraitAction? option,
  }) {
    final a = option ?? trait.definition.active;
    if (a == null) return 'noActiveOption';
    if (a.options.isNotEmpty) {
      final reasons = a.options.values
          .map((o) => _traitDisabled(actor, trait, option: o))
          .toList();
      return reasons.contains(null) ? null : reasons.first;
    }
    if (!actor.alive ||
        (!a.anytime && state.activePlayer.character != actor) ||
        state.phase != GamePhase.action ||
        state.pending != null ||
        state.choice != null ||
        state.preparation != null) {
      return 'notActionWindow';
    }
    if (_blocked(actor, (s) => s.blockTraits)) return 'traitsBlocked';
    if (trait.definition.mechanisms.get<TimeReserveRule>() case final rule?
        when rule.manualUse) {
      final reason = _reserveModule.manualDisabledReason(actor, rule);
      if (reason != null) return reason;
    }
    if (trait.definition.mechanisms.get<DecreeRule>() case final decree?) {
      if (actor.statuses.any((s) => s.definition.id == decree.blockedBy)) {
        return 'decreeBlocked';
      }
      if (_decreeChoices(actor, decree).isEmpty) return 'noChoiceCandidates';
    }
    if (trait.definition.mechanisms.get<SummonDefenseRule>() case final r?
        when !r.blockHealing) {
      if (_summonCount(actor, r.kind) >= _summonCap(actor, r)) {
        return 'summonCapacity';
      }
    }
    if (a.maxUsesPerRound != null &&
        trait.activeRound == _activeLimitWindow(actor, a) &&
        trait.activeUses >= a.maxUsesPerRound!) {
      return 'usageLimit';
    }
    if (a.requireFullMp && actor.mp < actor.value(Stat.maxMp)) {
      return 'requiresFullMp';
    }
    if (!actor.noMp && actor.mp - _mpFloor(actor) < _traitMpCost(actor, a)) {
      return 'insufficientMp';
    }
    if (!_canPayMarks(actor, a.markCosts)) return 'insufficientMarks';
    if (!_leadingSelectionAvailable(actor, [actor.instanceId], a.effects)) {
      return 'noChoiceCandidates';
    }
    if (actor.hand.length < a.discardCount) return 'insufficientCards';
    if (a.markLayers != null &&
        _markCount(actor, a.markLayers!, sourceId: actor.instanceId) +
                _markCount(
                  actor,
                  a.markIntensity!,
                  sourceId: actor.instanceId,
                ) ==
            0) {
      return 'insufficientMarks';
    }
    return null;
  }

  List<Map<String, Object?>> _traitActionView(CharacterInstance actor) => [
    for (final t in actor.traits)
      if (t.definition.active != null)
        {
          'instanceId': t.instanceId,
          'definitionId': t.definition.id,
          'disabledReason': _traitDisabled(actor, t),
          'mpCost': actor.noMp ? 0 : _traitMpCost(actor, t.definition.active!),
          'limitWindow': t.definition.active!.limitWindow.name,
          'maxUses': _traitUseLimit(t),
          'uses': _traitUseCount(actor, t),
          'discardCount': t.definition.active!.discardCount,
          'cardCandidates': actor.hand.map((c) => c.instanceId).toList(),
          'markCosts': [
            for (final c in t.definition.active!.markCosts)
              {'markId': c.markId, 'amount': c.amount},
          ],
          'options': [
            for (final entry in t.definition.active!.options.entries)
              {
                'mode': entry.key,
                'mpCost': actor.noMp ? 0 : _traitMpCost(actor, entry.value),
                'discardCount': entry.value.discardCount,
                'markCosts': [
                  for (final c in entry.value.markCosts)
                    {'markId': c.markId, 'amount': c.amount},
                ],
                'disabledReason': _traitDisabled(actor, t, option: entry.value),
              },
          ],
          'modes': t.definition.active!.options.isNotEmpty
              ? t.definition.active!.options.keys.toList()
              : t.definition.active!.markLayers == null
              ? ['self']
              : ['self', 'attack'],
        },
  ];

  int? _traitUseLimit(TraitInstance trait) {
    final reserve = trait.definition.mechanisms.get<TimeReserveRule>();
    return reserve?.manualUse == true
        ? reserve!.maxUsesPerRound
        : trait.definition.active!.maxUsesPerRound;
  }

  int _traitUseCount(CharacterInstance actor, TraitInstance trait) {
    final reserve = trait.definition.mechanisms.get<TimeReserveRule>();
    if (reserve?.manualUse == true) {
      return _reserveModule.usesThisRound(actor, reserve!);
    }
    return trait.activeRound ==
            _activeLimitWindow(actor, trait.definition.active!)
        ? trait.activeUses
        : 0;
  }

  void _activateTrait(
    CharacterInstance actor,
    ActivateTraitCommand command, {
    bool validateOnly = false,
  }) {
    final trait = actor.traits
        .where((t) => t.instanceId == command.traitInstanceId)
        .firstOrNull;
    if (trait == null) throw StateError('Unknown trait instance');
    final base = trait.definition.active;
    final action = (base?.options.isNotEmpty ?? false)
        ? base!.options[command.mode]
        : base;
    if (action == null) throw StateError('Invalid trait mode');
    final reason = _traitDisabled(actor, trait, option: action);
    if (reason != null) throw StateError(reason);
    if (trait.definition.mechanisms.get<DecreeRule>() case final decree?) {
      if (command.cardInstanceIds.isNotEmpty || command.mode != 'self') {
        throw StateError('Invalid decree input');
      }
      if (validateOnly) return;
      _offerDecree(actor, trait, action, decree);
      return;
    }
    if (command.cardInstanceIds.length != action.discardCount) {
      throw StateError('Incorrect trait discard count');
    }
    final cards = command.cardInstanceIds.isEmpty
        ? <CardInstance>[]
        : _selectCards(actor, command.cardInstanceIds);
    if (base!.options.isEmpty &&
        command.mode != 'self' &&
        !(action.markLayers != null && command.mode == 'attack')) {
      throw StateError('Invalid trait mode');
    }
    if (_walkEffects(action.effects).any((e) => e is ArmAttackTransfer) &&
        actor.armedStatusTransfer != null) {
      throw StateError('Transfer is already armed');
    }
    if (action.markLayers != null) {
      if (command.mode == 'attack' && actor.armedMarkAction != null) {
        throw StateError('Attack enhancement already armed');
      }
      if (command.mode == 'self' &&
          _latestStatus(actor, negative: false) == null) {
        throw StateError('No eligible positive status');
      }
    }
    _validateAbilityTargets(action.effects, [actor.instanceId]);
    if (validateOnly) return;
    if (_prepareAbility(
      actor,
      action.effects,
      [actor.instanceId],
      _traitMpCost(actor, action),
      () => _activateTrait(actor, command),
      input: {
        'kind': 'activateTrait',
        'instanceId': trait.instanceId,
        'definitionId': trait.definition.id,
        'discardCardInstanceIds': command.cardInstanceIds,
        'mode': command.mode,
        'markCosts': [
          for (final c in action.markCosts)
            {'markId': c.markId, 'amount': c.amount},
        ],
      },
    )) {
      return;
    }
    _payMp(actor, _traitMpCost(actor, action));
    _scoreAbilityFee(actor, trait: action);
    _payMarkCosts(actor, action.markCosts);
    for (final card in cards) {
      actor.hand.remove(card);
      state.discardPile.add(card);
    }
    if (cards.isNotEmpty) {
      _event('cardsLost', {
        'actorId': actor.instanceId,
        'count': cards.length,
        'reason': 'traitCost',
        if (_interactionRulesVersion >= 5)
          'cards': cards.map((c) => c.instanceId).toList(),
      });
    }
    if (trait.activeRound != _activeLimitWindow(actor, action)) {
      trait
        ..activeRound = _activeLimitWindow(actor, action)
        ..activeUses = 0;
    }
    trait.activeUses++;
    actor.actionsRemaining += action.extraActions;
    actor.bonusActions.addAll(
      List.filled(action.extraActions, action.attackBonus),
    );
    if (action.markLayers != null) {
      if (command.mode == 'attack') {
        actor.armedMarkAction = action;
      } else {
        _enhanceWithMarks(actor, actor, action, negative: false);
      }
    }
    final logIndex = state.events.length;
    _event('traitTriggered', {
      'actorId': actor.instanceId,
      'traitId': trait.definition.id,
      'logMode': command.mode,
    });
    final effectStart = state.events.length;
    _runAbility(
      actor,
      [actor.instanceId],
      action.effects,
      () {
        _finishAbilityLog(logIndex, effectStart, [actor.instanceId]);
        _afterResolution();
      },
      cards: cards,
      rollOrigin: RollContext(
        actorId: actor.instanceId,
        purpose: RollPurpose.trait,
        definitionId: trait.definition.id,
      ),
    );
  }

  StatusInstance? _latestStatus(
    CharacterInstance target, {
    required bool negative,
  }) => target.statuses.reversed
      .where(
        (s) =>
            _isStatusEffect(s.definition) &&
            (_interactionRulesVersion < 10 ||
                negative ||
                !s.definition.neutral) &&
            s.definition.negative == negative &&
            s.definition.category != StatusCategory.anomaly,
      )
      .firstOrNull;

  void _increaseStatus(
    StatusInstance status,
    int stacks,
    int intensity, {
    CharacterInstance? source,
  }) {
    final holder = _character(status.ownerId);
    final oldStacks = status.stacks;
    final oldIntensity = status.intensity;
    final gainedStacks = _statusStackGain(holder, status.definition.id, stacks);

    if (status.definition.category == StatusCategory.anomaly) return;
    status.stacks = (status.stacks + gainedStacks).clamp(
      1,
      status.definition.maxStacks ?? 1000000,
    );
    if (status.definition.hasIntensity) {
      status.intensity = (status.intensity + intensity).clamp(
        1,
        status.definition.maxIntensity ?? 1000000,
      );
    }
    _performance.statusChange(
      source ?? holder,
      holder,
      status.definition,
      oldStacks,
      oldIntensity,
      status.stacks,
      status.intensity,
    );
    _event('statusModified', {
      'sourceId': (source ?? holder).instanceId,
      'targetId': holder.instanceId,
      'statusId': status.definition.id,
      'negative': status.definition.negative,
      'stackDelta': status.stacks - oldStacks,
      'intensityDelta': status.intensity - oldIntensity,
      'instanceId': status.instanceId,
      'stacks': status.stacks,
      'intensity': status.intensity,
    });
  }

  bool _enhanceWithMarks(
    CharacterInstance actor,
    CharacterInstance target,
    TraitAction action, {
    required bool negative,
  }) {
    if (!target.alive) return false;
    final status = _latestStatus(target, negative: negative);
    if (status == null) return false;
    final layers = _markCount(
      actor,
      action.markLayers!,
      sourceId: actor.instanceId,
    );
    final intensity = _markCount(
      actor,
      action.markIntensity!,
      sourceId: actor.instanceId,
    );
    if (layers + intensity == 0) return false;
    _increaseStatus(
      status,
      layers * action.layersPerMark +
          (status.definition.hasIntensity
              ? 0
              : intensity * action.fallbackLayersPerMark),
      intensity * action.intensityPerMark,
      source: actor,
    );
    _effects(
      actor,
      [actor.instanceId],
      [
        ModifyMark(action.markLayers!, amount: -layers),
        ModifyMark(action.markIntensity!, amount: -intensity),
      ],
    );
    return true;
  }

  void _chooseEndMarks(CharacterInstance actor, void Function() complete) {
    final traits = !_blocked(actor, (s) => s.blockTraits)
        ? actor.traits
              .where(
                (t) =>
                    t.definition.endMarkChoices.isNotEmpty &&
                    t.definition.endMarkCount > 0,
              )
              .toList()
        : <TraitInstance>[];
    void next(int index) {
      if (!actor.alive || index == traits.length) {
        complete();
        return;
      }
      final trait = traits[index];
      final options = [
        for (final id in trait.definition.endMarkChoices)
          {'optionId': id, 'markId': id},
      ];
      state.choice = PendingChoice(
        id: state.id('choice'),
        playerId: state.activePlayer.id,
        kind: ChoiceKind.mark,
        options: options,
      );
      _choiceContinuation = (id) {
        _effects(
          actor,
          [actor.instanceId],
          [ModifyMark(id, amount: trait.definition.endMarkCount)],
        );
        _event('traitTriggered', {
          'actorId': actor.instanceId,
          'traitId': trait.definition.id,
          'logTargetIds': List<String>.unmodifiable([actor.instanceId]),
        });
        _flowSteps([_drainTriggers, () => next(index + 1)]);
      };
      _event('choiceOpened', {
        'choiceId': state.choice!.id,
        'playerId': state.activePlayer.id,
        'kind': 'mark',
      });
    }

    next(0);
  }
}
