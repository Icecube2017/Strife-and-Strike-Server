import 'package:sns_kernel/src/definitions.dart';

/// Read-only source compatibility for older Dart callers. New execution code
/// reads typed bindings; new mechanism fields do not belong to TraitDefinition.
extension LegacyTraitMechanisms on TraitDefinition {
  bool get saveAtTurnStart => mechanisms.has<TurnSaveRule>();
  bool get recordActions => mechanisms.has<ActionRecordingRule>();
  bool get chooseDamageRoll => mechanisms.has<DamageRollChoiceRule>();
  LifeThresholdRule? get lifeThreshold => mechanisms.get<LifeThresholdRule>();
  CardLifeRule? get cardLifeRule => mechanisms.get<CardLifeRule>();
  NegativeMpAura? get negativeMpAura => mechanisms.get<NegativeMpAura>();
  TagRewards? get tagRewards => mechanisms.get<TagRewards>();
  PreyRule? get prey => mechanisms.get<PreyRule>();
  RotatingCardEffects? get rotatingCardEffects =>
      mechanisms.get<RotatingCardEffects>();
  TimeReserveRule? get timeReserve => mechanisms.get<TimeReserveRule>();
  BuddyBlockRule? get buddyBlock => mechanisms.get<BuddyBlockRule>();
  SupportStanceRule? get supportStance => mechanisms.get<SupportStanceRule>();
  DamageShareRule? get damageShare => mechanisms.get<DamageShareRule>();
  DiscardReserveRule? get discardReserve =>
      mechanisms.get<DiscardReserveRule>();
  int? get skillRefundDivisor => mechanisms.get<SkillRefundRule>()?.divisor;
  DreamCraftRule? get dreamCraft => mechanisms.get<DreamCraftRule>();
  FruitAttackRule? get fruitAttack => mechanisms.get<FruitAttackRule>();
  NightmareRule? get nightmare => mechanisms.get<NightmareRule>();
  SummonDefenseRule? get summonDefense => mechanisms.get<SummonDefenseRule>();
  bool get borrowSkillAtTurnStart => mechanisms.has<SkillBorrowRule>();
  bool get shieldLifeCycle => mechanisms.has<ShieldLifeCycleRule>();
  bool get generatedActionOnShield =>
      mechanisms.has<GeneratedShieldActionRule>();
  DamageResourceRule? get damageResource =>
      mechanisms.get<DamageResourceRule>();
  DecreeRule? get decree => mechanisms.get<DecreeRule>();
}
