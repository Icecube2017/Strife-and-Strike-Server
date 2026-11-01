import 'package:sns_kernel/src/definitions.dart';

/// Module validation depends on a catalog and generic IR validation services.
/// Adding a dedicated mechanism does not add a branch to GameKernel.
final class MechanismValidator {
  MechanismValidator(this.catalog, this.checkEffects, this.walkEffects);
  final ContentCatalog catalog;
  final void Function(List<EffectDefinition>) checkEffects;
  final Iterable<EffectDefinition> Function(List<EffectDefinition>) walkEffects;
  T _require<T>(Map<String, T> entries, String id) =>
      entries[id] ?? (throw StateError('Unknown definition: $id'));
  void validate(TraitDefinition trait) {
    final save = trait.mechanisms.get<TurnSaveRule>();
    if (save != null && save.maxUses < 1) {
      throw StateError('Invalid save use limit');
    }
    final record = trait.mechanisms.get<ActionRecordingRule>();
    if (record != null && (record.capacity < 1 || record.perRound < 1)) {
      throw StateError('Invalid recording limits');
    }

    if (trait.mechanisms.get<DamageResourceRule>() case final rule?) {
      final variable = _require(catalog.variables, rule.variable);
      if (variable.type != VariableType.number ||
          variable.scope != VariableScope.owner ||
          rule.turnGain < 0 ||
          !rule.factor.isFinite ||
          rule.factor < 0 ||
          rule.threshold <= 0 ||
          rule.targetStatusStacks < 0 ||
          rule.selfStatusStacks < 0 ||
          rule.targetStatusIntensity < 1 ||
          rule.selfStatusIntensity < 1 ||
          rule.reactionLockRounds < 0) {
        throw StateError('Invalid damage resource rule');
      }
      _require(catalog.statuses, rule.targetStatusId);
      _require(catalog.statuses, rule.selfStatusId);
      if (rule.reactionLockStatusId case final id?) {
        final lock = _require(catalog.statuses, id);
        if (lock.isStatusEffect ||
            lock.hasIntensity ||
            (lock.maxStacks != null &&
                lock.maxStacks! < rule.reactionLockRounds) ||
            lock.decay != StatusDecay.anchoredRound ||
            !lock.followApplicationPhase) {
          throw StateError(
            'Reaction lock requires an anchored internal timer with sufficient stack capacity',
          );
        }
      }
    }
    if (trait.mechanisms.get<DecreeRule>() case final rule?) {
      if (trait.active == null ||
          rule.statusStacks < 1 ||
          rule.statusIntensity < 1 ||
          rule.maxUsesPerTargetPerRound < 1 ||
          (rule.maxUsesPerTargetPerRound > 1 && rule.usesVariable == null) ||
          rule.statusIds.isEmpty ||
          rule.statusIds.toSet().length != rule.statusIds.length) {
        throw StateError('Invalid decree rule');
      }
      for (final id in rule.statusIds) {
        _require(catalog.statuses, id);
      }
      _require(catalog.statuses, rule.blockedBy);
      final histories = [
        rule.roundVariable,
        rule.lastVariable,
        ?rule.usesVariable,
      ];
      if (histories.toSet().length != histories.length) {
        throw StateError('Decree history variables must differ');
      }
      for (final id in [
        rule.roundVariable,
        rule.lastVariable,
        ?rule.usesVariable,
      ]) {
        final variable = _require(catalog.variables, id);
        if (variable.type != VariableType.map ||
            variable.scope != VariableScope.game) {
          throw StateError('Decree history requires game-scoped map variables');
        }
      }
    }

    if (trait.mechanisms.get<DreamCraftRule>() case final r?) {
      _require(catalog.statuses, r.fromStatus);
      _require(catalog.statuses, r.toStatus);
      if (r.mpCost < 0 ||
          r.discardCount < 1 ||
          r.statusStacks < 1 ||
          r.statusIntensity < 1) {
        throw StateError('Invalid dream craft rule');
      }
    }
    if (trait.mechanisms.get<FruitAttackRule>() case final r?) {
      _require(catalog.marks, r.markId);
      _require(catalog.statuses, r.clearStatus);
      if (r.damage < 0 || r.diceDelta < 0 || r.markCost < 0) {
        throw StateError('Invalid fruit rule');
      }
    }
    if (trait.mechanisms.get<NightmareRule>() case final r?) {
      _require(catalog.statuses, r.statusId);
      _require(catalog.traits, r.fruitTraitId);
      if (r.healingTraitId != null) _require(catalog.traits, r.healingTraitId!);
      _require(catalog.marks, r.fruitMarkId);
      for (final id in [r.intensityVariable, r.countVariable]) {
        if (_require(catalog.variables, id).type != VariableType.number) {
          throw StateError('Expected number variable');
        }
      }
      if (r.every < 1 ||
          r.intensityGain < 0 ||
          r.damagePerFruit < 0 ||
          !r.healingFactor.isFinite ||
          r.healingFactor < 0) {
        throw StateError('Invalid nightmare rule');
      }
    }
    if (trait.mechanisms.get<SummonDefenseRule>() case final r?) {
      _require(catalog.variables, r.historyVariable);
      if (r.kind.isEmpty ||
          r.hpPerSlot < 1 ||
          r.rollSides < 1 ||
          r.baseCap < 0 ||
          r.maxCap < r.baseCap) {
        throw StateError('Invalid summon rule');
      }
    }
    void persistentNumber(String id) {
      final v = _require(catalog.variables, id);
      if (v.type != VariableType.number ||
          v.scope != VariableScope.owner ||
          v.reset != CounterReset.never) {
        throw StateError(
          'Mechanism requires a persistent owner number variable',
        );
      }
    }

    if (trait.mechanisms.get<DamageShareRule>() case final r?) {
      _require(catalog.statuses, r.sourceStatusId);
      if (!r.factor.isFinite ||
          r.factor < 0 ||
          r.factor > 1 ||
          r.intensityGain < 0) {
        throw StateError('Invalid damage share rule');
      }
    }
    if ((trait.mechanisms.get<SkillRefundRule>()?.divisor ?? 1) <= 0) {
      throw StateError('Invalid skill refund divisor');
    }
    if (trait.mechanisms.get<DiscardReserveRule>() case final r?) {
      persistentNumber(r.variable);
      if (r.shieldPerCard < 0 || r.shieldPerMp < 0) {
        throw StateError('Invalid discard reserve');
      }
    }
    if (trait.mechanisms.get<TimeReserveRule>() case final r?) {
      persistentNumber(r.variable);
      if (r.usesVariable != null) {
        if (r.usesVariable == r.variable) {
          throw StateError('Reserve use and round variables must differ');
        }
        persistentNumber(r.usesVariable!);
      }
      _require(catalog.marks, r.markId);
      _require(catalog.statuses, r.statusId);
      if (r.strength < 0 ||
          r.recoveryMpCost < 1 ||
          r.recoveryMarkGain < 1 ||
          r.overflowMarkGain < 0 ||
          r.mpPerMark < 1 ||
          r.intensityPerMark < 0 ||
          r.statusStacks < 1 ||
          r.maxUsesPerRound < 1 ||
          (r.maxUsesPerRound > 1 && r.usesVariable == null)) {
        throw StateError('Invalid time reserve parameters');
      }
    }
    if (trait.mechanisms.get<BuddyBlockRule>() case final r?) {
      if (r.surcharge < 0 || r.recovery < 0 || r.drainAmount < 0) {
        throw StateError('Invalid target fee rule');
      }
    }
    if (trait.mechanisms.get<SupportStanceRule>() case final r?) {
      for (final id in [
        r.defenseVariable,
        r.attackVariable,
        r.currentVariable,
        r.previousVariable,
      ]) {
        persistentNumber(id);
      }
      _require(catalog.statuses, r.statusId);
      if (r.damageThreshold < 0 ||
          r.rollSides < 1 ||
          r.rollSides > 1000 ||
          r.rollCount < 1 ||
          r.rollCount > 32 ||
          r.statusStacks < 1 ||
          r.previousHitsBelow < 0 ||
          r.defenseUses < 0 ||
          r.attackUses < 0 ||
          r.cooldownReduction < 0 ||
          r.startRound < 1) {
        throw StateError('Invalid support damage threshold');
      }
    }

    final choices = trait.mechanisms.get<DamageRollChoiceRule>();
    if (choices != null && (choices.rollCount < 1 || choices.rollCount > 32)) {
      throw StateError('Invalid damage roll choice count');
    }
    if (trait.endMarkCount < 0) throw StateError('Invalid end mark count');

    if (trait.mechanisms.get<RotatingCardEffects>() case final rule?) {
      final variable = _require(catalog.variables, rule.variable);
      if (rule.entries.isEmpty ||
          rule.suppressFirst < 0 ||
          variable.type != VariableType.number ||
          variable.scope != VariableScope.owner ||
          variable.reset != CounterReset.never) {
        throw StateError('Invalid rotating card effects');
      }
      for (final entry in rule.entries) {
        checkEffects(entry.effects);
      }
    }

    if (trait.suppressedCardMinTags != null &&
        trait.suppressedCardMinTags! < 1) {
      throw StateError('Invalid card suppression tag threshold');
    }
    if (trait.mechanisms.get<NegativeMpAura>() case final r?) {
      if (r.floor >= 0 || r.sides < 1 || r.failure < 1 || r.failure > r.sides) {
        throw StateError('Invalid negative MP aura');
      }
    }
    if (trait.mechanisms.get<LifeThresholdRule>() case final r?) {
      final v = _require(catalog.variables, r.variable);
      if (r.below < 1 ||
          v.type != VariableType.number ||
          v.scope != VariableScope.owner ||
          v.reset != CounterReset.never) {
        throw StateError(
          'Life threshold needs a persistent owner number variable',
        );
      }
      if (walkEffects(r.effects).any(
        (e) =>
            e is! ShieldEffect &&
            e is! ApplyStatus &&
            e is! ModifyStat &&
            e is! ModifyVariable,
      )) {
        throw StateError('Life threshold effects must be immediate and atomic');
      }
      checkEffects(r.effects);
    }
    if (trait.mechanisms.get<CardLifeRule>() case final r?) {
      if (r.threshold < 1 || r.highTags.isEmpty || r.lowTags.isEmpty) {
        throw StateError('Invalid card life rule');
      }
      checkEffects(r.highEffects);
      checkEffects(r.lowEffects);
    }
    if (trait.mechanisms.get<TagRewards>() case final r?) {
      if (r.threshold < 1 ||
          r.effects.isEmpty ||
          !r.effects.keys.toSet().containsAll(r.boostedEffects.keys)) {
        throw StateError('Invalid tag reward table');
      }
      for (final effects in [...r.effects.values, ...r.boostedEffects.values]) {
        checkEffects(effects);
        if (walkEffects(
          effects,
        ).any((e) => e is ModifyActionDice && !effects.contains(e))) {
          throw StateError('Action dice rewards must be direct tag effects');
        }
      }
    }
    if (trait.mechanisms.get<PreyRule>() case final r?) {
      if (!r.outgoingFactor.isFinite ||
          !r.incomingFactor.isFinite ||
          r.outgoingFactor < 0 ||
          r.incomingFactor < 0) {
        throw StateError('Invalid prey damage factors');
      }
    }
  }
}
