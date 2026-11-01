part of 'engine.dart';

final class _PreyKernelHost implements PreyHost {
  _PreyKernelHost(this.kernel);
  final GameKernel kernel;
  @override
  bool get previewMode => kernel._previewMode;
  @override
  bool traitsBlocked(CharacterInstance actor) =>
      kernel._blocked(actor, (s) => s.blockTraits);
  @override
  CharacterInstance character(String id) => kernel._character(id);
  @override
  CardInstance effectiveCard(CharacterInstance actor, CardInstance card) =>
      kernel._effectiveCard(actor, card);
  @override
  String nextId(String prefix) => kernel.state.id(prefix);
  @override
  HeldCard holdCard({
    required String id,
    required String actionId,
    required CharacterInstance owner,
    required CardInstance card,
    bool revealed = false,
  }) => kernel.state.cardCustody.hold(
    id: id,
    actionId: actionId,
    owner: owner,
    card: card,
    revealed: revealed,
  );
  @override
  CardInstance takeCard(HeldCard card) => kernel.state.cardCustody.take(card);
  @override
  void discardCard(CardInstance card) => kernel.state.discardPile.add(card);
  @override
  void returnCard(CharacterInstance owner, CardInstance card) {
    final before = owner.hand.length;
    owner.hand.add(card);
    kernel._handCountIncreased(owner, before);
  }

  @override
  void emit(String type, Map<String, Object?> data) =>
      kernel._event(type, data);
  @override
  void choose(
    CharacterInstance actor,
    List<Map<String, Object?>> options,
    void Function(Map<String, Object?>) resolve,
  ) => kernel._mechanismChoice(actor, options, resolve);
  @override
  void sequence(List<void Function()> steps) => kernel._flowSteps(steps);
}

extension _PreyModuleStages on GameKernel {
  void _activatePrey(
    CharacterInstance actor,
    List<String> targets,
    String actionId,
    List<CardInstance> cards,
  ) => _preyModule.activate(actor, targets, actionId, cards);
  void _offerPreyDefense(CharacterInstance actor, PendingResolution pending) =>
      _preyModule.offerDefense(actor, pending);
  void _offerPlacePrey(CharacterInstance actor, PendingResolution pending) =>
      _preyModule.offerPlacement(actor, pending);
  void _releaseDeadPrey(CharacterInstance dead) =>
      _preyModule.releaseDead(dead);
}

final class _TraitKernelHost
    implements
        DreamCraftHost,
        FruitAttackHost,
        NightmareHost,
        TurnSaveHost,
        ResourceReserveHost,
        CardContentHost,
        TeamMechanismHost,
        SkillBorrowHost,
        RerollHost,
        DamageRollChoiceHost,
        DamageResourceHost,
        DecreeHost,
        SummonDefenseHost {
  _TraitKernelHost(this.kernel);
  final GameKernel kernel;
  @override
  bool traitsBlocked(CharacterInstance actor, {String? exceptStatus}) =>
      kernel._blocked(actor, (s) => s.blockTraits && s.id != exceptStatus);
  @override
  void choose(
    CharacterInstance actor,
    List<Map<String, Object?>> options,
    void Function(Map<String, Object?>) resolve,
  ) => kernel._mechanismChoice(actor, options, resolve);
  @override
  void emit(String type, Map<String, Object?> data) =>
      kernel._event(type, data);
  @override
  void consumeStatus(
    CharacterInstance actor,
    StatusInstance status, {
    int amount = 1,
  }) => kernel._consumeStatus(actor, status, amount: amount);
  @override
  void applyStatus(
    CharacterInstance source,
    CharacterInstance target,
    ApplyStatus effect,
    int multiplier, {
    String? anchorPlayerId,
  }) => kernel._applyStatus(
    source,
    target,
    effect,
    multiplier,
    anchorPlayerId: anchorPlayerId,
  );
  @override
  void payMp(CharacterInstance actor, int amount) =>
      kernel._payMp(actor, amount);
  @override
  void discardCards(CharacterInstance actor, List<CardInstance> cards) {
    for (final card in cards) {
      actor.hand.remove(card);
      kernel.state.discardPile.add(card);
    }
  }

  @override
  CharacterInstance character(String id) => kernel._character(id);
  @override
  int markCount(CharacterInstance actor, String id, {String? sourceId}) =>
      kernel._markCount(actor, id, sourceId: sourceId);
  @override
  void effects(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
  ) => kernel._effects(actor, targets, effects);
  @override
  void runAbility(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
    void Function() complete, {
    bool independentDamage = false,
  }) => kernel._runAbility(
    actor,
    targets,
    effects,
    complete,
    independentDamage: independentDamage,
  );
  @override
  List<PlayerInstance> get players => List.unmodifiable(kernel.state.players);
  @override
  List<KernelEvent> get events => List.unmodifiable(kernel.state.events);
  @override
  void heal(CharacterInstance source, CharacterInstance target, int amount) =>
      kernel._heal(source, target, amount);
  @override
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  ) => kernel._modifyVariable(actor, target, effect);
  @override
  VariableState variableCell(String id, CharacterInstance owner) =>
      kernel._variableCell(id, owner);
  @override
  bool isActivePlayer(CharacterInstance actor) =>
      kernel.state.activePlayer.character == actor;
  @override
  String nextId(String prefix) => kernel.state.id(prefix);
  @override
  int mpFloor(CharacterInstance actor) => kernel._mpFloor(actor);
  @override
  StatusInstance copyStatus(StatusInstance status, {bool restoring = false}) =>
      kernel._copyStatus(status, restoring: restoring);
  @override
  void draw(CharacterInstance actor, int count) =>
      kernel._draw(actor, count, source: actor);
  @override
  void discardCard(CharacterInstance actor, CardInstance card) {
    actor.hand.remove(card);
    kernel.state.discardPile.add(card);
  }

  @override
  void enqueueFirst(void Function() continuation) =>
      kernel._flow.addFirst(continuation);
  @override
  void sequence(List<void Function()> steps) => kernel._flowSteps(steps);
  @override
  void drainTriggers() => kernel._drainTriggers();

  @override
  int get round => kernel.state.round;
  @override
  AnchorExpiry? naturalExpiry(int rounds) =>
      kernel._interactionRulesVersion >= 14
      ? kernel._newAnchorExpiry(rounds)
      : null;
  @override
  bool naturalExpiryDue(AnchorExpiry expiry, {bool atEnd = false}) => kernel
      ._anchorExpiryDue(expiry, kernel.state.activePlayer.id, atEnd: atEnd);
  @override
  int get playerCount => kernel.setup.players.length;
  @override
  bool get previewMode => kernel._previewMode;
  @override
  bool isAutomatic(CharacterInstance actor) =>
      identical(kernel._automaticActor, actor);
  @override
  bool enemy(CharacterInstance a, CharacterInstance b) => kernel._enemy(a, b);
  @override
  MarkDefinition markDefinition(String id) =>
      kernel._require(kernel.catalog.marks, id);
  @override
  void modifyMark(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyMark effect,
    int multiplier,
  ) => kernel._modifyMark(actor, target, effect, multiplier);
  @override
  CardInstance physicalCard(CharacterInstance actor, CardInstance card) =>
      [
        ...kernel.state.discardPile,
        ...actor.hand,
        ...kernel.state.cardCustody.entries.map((h) => h.card),
      ].where((c) => c.instanceId == card.instanceId).firstOrNull ??
      card;

  @override
  CharacterInstance liveTarget(String id) => kernel._target(id);
  @override
  void Function() preserveContinuation(void Function() resume) {
    final prepared = kernel._committingPrepared;
    return () {
      final previous = kernel._committingPrepared;
      kernel._committingPrepared = prepared;
      try {
        resume();
      } finally {
        kernel._committingPrepared = previous;
      }
    };
  }

  @override
  void roll(
    CharacterInstance actor,
    int sides,
    int count,
    void Function(int) complete, {
    bool damageRoll = false,
  }) =>
      kernel._rollAsync(actor, sides, count, complete, damageRoll: damageRoll);
  @override
  void rollResult(
    CharacterInstance actor,
    int sides,
    int count,
    void Function(RollResult) complete, {
    RollResult Function()? generate,
    bool damageRoll = false,
    RollContext? context,
  }) => kernel._rollResultAsync(
    actor,
    sides,
    count,
    complete,
    generate: generate,
    damageRoll: damageRoll,
    context: context,
  );
  @override
  int actionSeat(CharacterInstance actor) =>
      (kernel.state.reversedOrder ? -1 : 1) *
      kernel.state.players.indexWhere((p) => p.character == actor);
  @override
  bool attackAllowed(CharacterInstance actor, CharacterInstance target) =>
      !kernel._blocked(actor, (s) => s.blockAttack) &&
      kernel._incomingAttackTargetAllowed(actor, target);
  @override
  void automaticAttack(CharacterInstance actor, CharacterInstance target) =>
      kernel._automaticAction(actor, () {
        final player = kernel.state.players.firstWhere(
          (p) => p.character == actor,
        );
        kernel._attack(player, AttackCommand(player.id, target.instanceId));
      });
  @override
  void failMentalAction(CharacterInstance actor, CharacterInstance source) {
    kernel._performance.actionCancelled(source.instanceId, actor);
    kernel._commitActionAllowance(actor);
    if (actor.noMp || actor.mp > 0) {
      kernel._payMp(actor, 1);
    } else {
      kernel._event('mpSpent', {
        'actorId': actor.instanceId,
        'amount': 0,
        'nominalAmount': 1,
        'paid': true,
      });
    }
    kernel._event('mentalActionFailed', {
      'actorId': actor.instanceId,
      'sourceId': source.instanceId,
    });
    kernel._afterResolution();
  }

  @override
  void resetNegativeMp(CharacterInstance source, CharacterInstance target) {
    final before = target.mp;
    target.mp = 0;
    kernel._event('negativeMpReleased', {
      'sourceId': source.instanceId,
      'targetId': target.instanceId,
      'before': before,
    });
  }

  @override
  String get anchorPlayerId => kernel.state.activePlayer.id;
  @override
  int traitCost(CharacterInstance actor, TraitAction action) =>
      kernel._traitMpCost(actor, action);
  @override
  String? traitDisabled(
    CharacterInstance actor,
    TraitInstance trait, {
    TraitAction? option,
  }) => kernel._traitDisabled(actor, trait, option: option);
  @override
  void finishResolution() => kernel._afterResolution();
  @override
  void queueDamageReaction(
    CharacterInstance actor,
    CharacterInstance target,
    int amount,
    ApplyStatus status,
  ) {
    kernel._flow.addFirst(() {
      if (!target.alive) return;
      final previous = kernel._independentDamage;
      kernel._independentDamage = true;
      kernel._damageAsync(actor, target, amount, DamageKind.physical, () {
        if (target.alive) {
          kernel._applyStatus(actor, target, status, 1);
        }
      });
      kernel._independentDamage = previous;
    });
  }

  @override
  Iterable<SummonedUnitInstance> get units =>
      List.unmodifiable(kernel.state.summonedUnits);
  @override
  void createUnit(
    CharacterInstance actor,
    CharacterInstance owner,
    String kind,
  ) {
    final unit = SummonedUnitInstance(
      instanceId: kernel.state.id('summon'),
      ownerId: owner.instanceId,
      kind: kind,
    );
    kernel.state.summonedUnits.add(unit);
    kernel._event('unitSummoned', {
      'actorId': actor.instanceId,
      'ownerId': owner.instanceId,
      'instanceId': unit.instanceId,
      'kind': kind,
    });
  }

  @override
  RollResult trackRoll(RollResult result) => kernel._storeRoll(result);
}

extension _StagedModuleStages on GameKernel {
  void _convertCraftDream(CharacterInstance actor) =>
      _dreamCraftModule.convert(actor);
  void _craftDreamAtStart(CharacterInstance actor) =>
      _dreamCraftModule.atStart(actor);
  void _offerDreamRemoval(CharacterInstance actor) =>
      _dreamCraftModule.offerRemoval(actor);
  void _offerFruitAttacks(CharacterInstance actor, PendingResolution pending) =>
      _fruitAttackModule.offer(actor, pending);
  int _nightmareDamageBonus(StatusInstance? status) =>
      _nightmareModule.damageBonus(status);
  void _healNightmareDamage(
    StatusInstance? status,
    CharacterInstance target,
    int start,
  ) => _nightmareModule.healDamage(status, target, start);
  void _statusSettlementCompleted(
    CharacterInstance owner,
    StatusInstance status,
  ) {
    _nightmareModule.settlementCompleted(owner, status);
    if (!_hasTriggerListener(TriggerTiming.statusSettled)) return;
    _enqueueTrigger(
      _TriggerFact(
        TriggerTiming.statusSettled,
        subject: owner.instanceId,
        target: owner.instanceId,
        source: status.sourceId,
        definitionId: status.definition.id,
        statusIntensity: status.intensity,
        amount: 1,
      ),
    );
  }
}

extension _SaveModuleStages on GameKernel {
  void _captureSave(CharacterInstance actor) => _turnSaveModule.capture(actor);
  bool _restoreSave(CharacterInstance actor) {
    final previousLimits = _resourceLimits(actor);
    final restored = _turnSaveModule.restore(actor);
    if (restored) {
      _logResourceLimitChanges(actor, previousLimits, source: actor);
    }
    return restored;
  }
}

extension _ReserveModuleStages on GameKernel {
  bool _discardReserve(CharacterInstance actor) {
    final handled = _reserveModule.discard(actor);
    if (handled) _flowSteps([_drainTriggers, _closeTurn]);
    return handled;
  }

  int _claimDiscardReserve(CharacterInstance actor) =>
      _reserveModule.claim(actor);
  void _collectReserveOverflow(String type, Map<String, Object?> data) =>
      _reserveModule.collectOverflow(type, data);
  bool _offerTimeReserve(CharacterInstance actor, void Function() resume) =>
      _reserveModule.offer(actor, resume);
}

extension _CardContentModuleStages on GameKernel {
  bool _cardSuppressed(CharacterInstance actor, CardInstance card) =>
      _cardContentModule.suppressed(actor, card);
  CardInstance _effectiveCard(
    CharacterInstance actor,
    CardInstance card, {
    Set<String> blockedTags = const {},
  }) => _cardContentModule.effectiveCard(actor, card, blockedTags: blockedTags);
  List<CardInstance> _projectCardGroup(
    CharacterInstance actor,
    List<CardInstance> cards,
  ) => _cardContentModule.project(actor, cards);
  List<CardInstance> _assembleRotatingCards(
    CharacterInstance actor,
    String actionId,
    List<CardInstance> cards,
  ) => _cardContentModule.assemble(actor, actionId, cards);
  void _checkLifeThresholds(CharacterInstance actor) =>
      _cardContentModule.checkLife(actor);
  void _runCardTraitRules(
    CharacterInstance actor,
    List<String> targets,
    CardInstance card,
    List<CardInstance> group,
    String? actionId,
    void Function() complete,
  ) => _cardContentModule.runCardRules(
    actor,
    targets,
    card,
    group,
    actionId,
    complete,
  );
}

extension _TeamModuleStages on GameKernel {
  void _supportStanceStart(CharacterInstance actor) => _supportModule.atStart(
    actor,
    round: state.round,
    enforceStartRound: _interactionRulesVersion >= 5,
  );
  void _supportDamageFact(String type, Map<String, Object?> data) =>
      _supportModule.onFact(type, data);
  void _redirectSupportAttack(
    CharacterInstance actor,
    PendingResolution pending,
  ) => _supportModule.redirect(actor, pending);
  void _offerSupportAttack(_ObservedAction action) => _supportModule
      .offerAttack(action.actor, action.targets, recordable: action.recordable);
  int _targetSurcharge(List<String> targets) => _buddyModule.surcharge(targets);
  void _rewardTargetFees(List<String> targets) => _buddyModule.reward(targets);
  void _buddyMpBoundary(String type, Map<String, Object?> data) =>
      _buddyModule.onFact(type, data);
  void _releaseNegativeMp(CharacterInstance actor) =>
      _mentalGateModule.releaseDead(actor);
  int _mpFloor(CharacterInstance actor) => _mentalGateModule.floor(actor);
  bool _mentalActionGate(CharacterInstance actor, void Function() resume) =>
      _mentalGateModule.gate(actor, resume);
}

extension _SkillBorrowModuleStages on GameKernel {
  void _offerSkillLease(CharacterInstance actor) =>
      _skillBorrowModule.offer(actor);
  void _expireSkillLeases() => _skillBorrowModule.expire();
}

extension _RerollModuleStages on GameKernel {
  void _offerReroll(
    CharacterInstance roller,
    int sides,
    int count,
    RollResult original,
    void Function(RollResult) complete, {
    RollResult Function()? generate,
    bool damageRoll = false,
    bool locked = false,
  }) => _rerollModule.offer(
    roller,
    sides,
    count,
    original,
    complete,
    generate: generate,
    damageRoll: damageRoll,
    locked: locked,
  );
}

extension _DamageRollChoiceModuleStages on GameKernel {
  void _chooseDamageRoll(
    CharacterInstance actor,
    RollResult Function() generate,
    void Function(RollResult) complete, {
    bool locked = false,
  }) =>
      _damageRollChoiceModule.choose(actor, generate, complete, locked: locked);
}

MechanismRuntime _createMechanismModules(GameKernel kernel) {
  final host = _TraitKernelHost(kernel);
  final runtime = MechanismRuntime();
  runtime.register(PreyModule(_PreyKernelHost(kernel)));
  runtime.register(DreamCraftModule(host));
  runtime.register(FruitAttackModule(host));
  runtime.register(NightmareModule(host));
  runtime.register(TurnSaveModule(host));
  runtime.register(ActionRecordingModule());
  runtime.register(ResourceReserveModule(host));
  runtime.register(CardContentModule(host));
  runtime.register(SupportStanceModule(host));
  runtime.register(BuddyBlockModule(host));
  runtime.register(MentalGateModule(host));
  runtime.register(SkillBorrowModule(host));
  runtime.register(RerollModule(host));
  runtime.register(DamageRollChoiceModule(host));
  runtime.register(
    MechanismValidator(
      kernel.catalog,
      kernel._checkEffects,
      kernel._walkEffects,
    ),
  );
  runtime.register(DamageResourceModule(host));
  runtime.register(DecreeModule(host));
  runtime.register(SummonDefenseModule(host));
  runtime.register(SkillCopyModule());
  return runtime;
}

extension _MechanismModuleLookup on GameKernel {
  SkillCopyModule get _skillCopyModule => _modules.require<SkillCopyModule>();
  PreyModule get _preyModule => _modules.require<PreyModule>();
  DreamCraftModule get _dreamCraftModule =>
      _modules.require<DreamCraftModule>();
  FruitAttackModule get _fruitAttackModule =>
      _modules.require<FruitAttackModule>();
  NightmareModule get _nightmareModule => _modules.require<NightmareModule>();
  TurnSaveModule get _turnSaveModule => _modules.require<TurnSaveModule>();
  ActionRecordingModule get _recordingModule =>
      _modules.require<ActionRecordingModule>();
  ResourceReserveModule get _reserveModule =>
      _modules.require<ResourceReserveModule>();
  CardContentModule get _cardContentModule =>
      _modules.require<CardContentModule>();
  SupportStanceModule get _supportModule =>
      _modules.require<SupportStanceModule>();
  BuddyBlockModule get _buddyModule => _modules.require<BuddyBlockModule>();
  MentalGateModule get _mentalGateModule =>
      _modules.require<MentalGateModule>();
  SkillBorrowModule get _skillBorrowModule =>
      _modules.require<SkillBorrowModule>();
  RerollModule get _rerollModule => _modules.require<RerollModule>();
  DamageRollChoiceModule get _damageRollChoiceModule =>
      _modules.require<DamageRollChoiceModule>();
  MechanismValidator get _mechanismValidator =>
      _modules.require<MechanismValidator>();
}

extension _RemainingModuleStages on GameKernel {
  int _summonCap(CharacterInstance owner, SummonDefenseRule rule) =>
      _summonDefenseModule.cap(owner, rule);
  DamageResourceModule get _damageResourceModule =>
      _modules.require<DamageResourceModule>();
  DecreeModule get _decreeModule => _modules.require<DecreeModule>();
  SummonDefenseModule get _summonDefenseModule =>
      _modules.require<SummonDefenseModule>();
  void _damageResourceFact(String type, Map<String, Object?> data) =>
      _damageResourceModule.onFact(type, data);
  List<Map<String, Object?>> _decreeChoices(
    CharacterInstance actor,
    DecreeRule rule,
  ) => _decreeModule.choices(actor, rule);
  void _offerDecree(
    CharacterInstance actor,
    TraitInstance trait,
    TraitAction action,
    DecreeRule rule,
  ) => _decreeModule.offer(actor, trait, action, rule);
  int _summonCount(CharacterInstance owner, String kind) =>
      _summonDefenseModule.count(owner, kind);
  void _summonUnit(
    CharacterInstance actor,
    CharacterInstance owner,
    SummonUnit effect,
  ) => _summonDefenseModule.summon(actor, owner, effect);
  bool _summonHealingBlocked(CharacterInstance owner) =>
      _summonDefenseModule.healingBlocked(owner);
}
