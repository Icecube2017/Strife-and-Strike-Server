import 'package:sns_kernel/src/definitions.dart';

final class DamageResourceRule {
  const DamageResourceRule({
    required this.variable,
    this.turnGain = 0,
    this.factor = 0,
    this.threshold = 0,
    required this.targetStatusId,
    this.targetStatusStacks = 2,
    this.targetStatusIntensity = 1,
    required this.selfStatusId,
    this.selfStatusStacks = 1,
    this.selfStatusIntensity = 3,
    this.reactionLockStatusId,
    this.reactionLockRounds = 1,
  });
  final String variable;
  final int turnGain;
  final double factor;
  final int threshold;
  final String targetStatusId;
  final int targetStatusStacks, targetStatusIntensity;
  final String selfStatusId;
  final int selfStatusStacks, selfStatusIntensity;
  final String? reactionLockStatusId;
  final int reactionLockRounds;
}

final class DecreeRule {
  const DecreeRule({
    required this.statusIds,
    required this.roundVariable,
    required this.lastVariable,
    required this.blockedBy,
    this.statusStacks = 1,
    this.statusIntensity = 1,
    this.maxUsesPerTargetPerRound = 1,
    this.usesVariable,
  });
  final List<String> statusIds;
  final String roundVariable;
  final String lastVariable;
  final String blockedBy;
  final int statusStacks, statusIntensity, maxUsesPerTargetPerRound;
  final String? usesVariable;
}

final class DamageShareRule {
  const DamageShareRule({
    this.factor = .5,
    required this.sourceStatusId,
    this.intensityGain = 2,
  });
  final double factor;
  final String sourceStatusId;
  final int intensityGain;
}

final class SupportStanceRule {
  const SupportStanceRule({
    required this.statusId,
    required this.defenseVariable,
    required this.attackVariable,
    required this.currentVariable,
    required this.previousVariable,
    this.damageThreshold = 300,
    this.rollSides = 4,
    this.rollCount = 1,
    this.statusStacks = 1,
    this.previousHitsBelow = 2,
    this.defenseUses = 1,
    this.attackUses = 1,
    this.cooldownReduction = 1,
    this.startRound = 2,
  });
  final String statusId,
      defenseVariable,
      attackVariable,
      currentVariable,
      previousVariable;
  final int damageThreshold;
  final int rollSides,
      rollCount,
      statusStacks,
      previousHitsBelow,
      defenseUses,
      attackUses,
      cooldownReduction,
      startRound;
}

final class BuddyBlockRule {
  const BuddyBlockRule({
    this.surcharge = 1,
    this.recovery = 1,
    this.includeAnomalies = true,
    this.drainAmount = 1,
  });
  final int surcharge, recovery;
  final int drainAmount;
  final bool includeAnomalies;
}

final class DiscardReserveRule {
  const DiscardReserveRule({
    required this.variable,
    this.shieldPerCard = 30,
    this.shieldPerMp = 30,
  });
  final String variable;
  final int shieldPerCard, shieldPerMp;
}

final class TimeReserveRule {
  const TimeReserveRule({
    required this.markId,
    required this.statusId,
    required this.variable,
    this.strength = 4,
    this.manualUse = false,
    this.recoveryMpCost = 1,
    this.recoveryMarkGain = 1,
    this.overflowMarkGain = 1,
    this.mpPerMark = 1,
    this.intensityPerMark = 1,
    this.statusStacks = 1,
    this.maxUsesPerRound = 1,
    this.usesVariable,
  });
  final String markId, statusId, variable;
  final int strength;
  final bool manualUse;
  final int recoveryMpCost,
      recoveryMarkGain,
      overflowMarkGain,
      mpPerMark,
      intensityPerMark,
      statusStacks,
      maxUsesPerRound;
  final String? usesVariable;
}

final class RotatingCardEffect {
  RotatingCardEffect({
    required Set<String> suppressedTags,
    required List<EffectDefinition> effects,
  }) : suppressedTags = Set.unmodifiable(suppressedTags),
       effects = List.unmodifiable(effects);
  final Set<String> suppressedTags;
  final List<EffectDefinition> effects;
}

final class RotatingCardEffects {
  RotatingCardEffects({
    required this.variable,
    required List<RotatingCardEffect> entries,
    this.suppressFirst = 2,
  }) : entries = List.unmodifiable(entries);
  final String variable;
  final List<RotatingCardEffect> entries;
  final int suppressFirst;
}

final class LifeThresholdRule {
  LifeThresholdRule({
    required this.below,
    required this.variable,
    required List<EffectDefinition> effects,
  }) : effects = List.unmodifiable(effects);
  final int below;
  final String variable;
  final List<EffectDefinition> effects;
}

final class CardLifeRule {
  CardLifeRule({
    required this.threshold,
    required Set<String> highTags,
    required Set<String> lowTags,
    required List<EffectDefinition> highEffects,
    required List<EffectDefinition> lowEffects,
    this.lowOptional = true,
  }) : highTags = Set.unmodifiable(highTags),
       lowTags = Set.unmodifiable(lowTags),
       highEffects = List.unmodifiable(highEffects),
       lowEffects = List.unmodifiable(lowEffects);
  final int threshold;
  final Set<String> highTags, lowTags;
  final List<EffectDefinition> highEffects, lowEffects;
  final bool lowOptional;
}

final class NegativeMpAura {
  const NegativeMpAura({this.floor = -2, this.sides = 6, this.failure = 3});
  final int floor, sides, failure;
}

final class TagRewards {
  TagRewards({
    required Map<String, List<EffectDefinition>> effects,
    required Map<String, List<EffectDefinition>> boostedEffects,
    this.threshold = 5,
  }) : effects = Map.unmodifiable(
         effects.map(
           (k, v) => MapEntry(k, List<EffectDefinition>.unmodifiable(v)),
         ),
       ),
       boostedEffects = Map.unmodifiable(
         boostedEffects.map(
           (k, v) => MapEntry(k, List<EffectDefinition>.unmodifiable(v)),
         ),
       );
  final Map<String, List<EffectDefinition>> effects, boostedEffects;
  final int threshold;
}

final class PreyRule {
  const PreyRule({this.outgoingFactor = 1.2, this.incomingFactor = .8});
  final double outgoingFactor, incomingFactor;
}

final class DreamCraftRule {
  const DreamCraftRule({
    required this.fromStatus,
    required this.toStatus,
    this.mpCost = 2,
    this.discardCount = 1,
    this.statusStacks = 1,
    this.statusIntensity = 1,
  });
  final String fromStatus, toStatus;
  final int mpCost, discardCount;
  final int statusStacks, statusIntensity;
}

final class FruitAttackRule {
  const FruitAttackRule({
    required this.markId,
    required this.clearStatus,
    this.damage = 75,
    this.diceDelta = 2,
    this.markCost = 1,
  });
  final String markId, clearStatus;
  final int damage, diceDelta;
  final int markCost;
}

final class NightmareRule {
  const NightmareRule({
    required this.statusId,
    required this.fruitTraitId,
    required this.fruitMarkId,
    required this.intensityVariable,
    required this.countVariable,
    this.damagePerFruit = 30,
    this.healingFactor = .6,
    this.healingTraitId,
    this.healFromRuleOwner = false,
    this.every = 9,
    this.intensityGain = 1,
  });
  final String statusId,
      fruitTraitId,
      fruitMarkId,
      intensityVariable,
      countVariable;
  final int damagePerFruit, every;
  final int intensityGain;
  final double healingFactor;
  final String? healingTraitId;
  final bool healFromRuleOwner;
}

final class SummonDefenseRule {
  const SummonDefenseRule({
    required this.kind,
    required this.historyVariable,
    this.baseCap = 2,
    this.maxCap = 5,
    this.hpPerSlot = 200,
    this.rollSides = 10,
    this.blockHealing = false,
  });
  final String kind, historyVariable;
  final int baseCap, maxCap, hpPerSlot, rollSides;
  final bool blockHealing;
}
