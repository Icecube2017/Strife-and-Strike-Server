/// Immutable, in-memory content. Loading JSON and syncing text are adapter jobs.
library;

import 'package:sns_kernel/src/mechanisms/bindings.dart';
import 'package:sns_kernel/src/mechanisms/configurations.dart';
import 'package:sns_kernel/src/timing.dart';

export 'package:sns_kernel/src/mechanisms/bindings.dart';
export 'package:sns_kernel/src/mechanisms/configurations.dart';
export 'package:sns_kernel/src/mechanisms/legacy_trait_adapter.dart';
export 'package:sns_kernel/src/timing.dart';

part 'query_definitions.dart';

enum Stat { attack, defense, maxHp, maxMp, maxHand }

enum DamageKind { physical, magical, real, lifeLoss }

enum EffectTarget {
  self,
  selected,
  all,
  allies,
  enemies,
  eventSource,
  eventTarget,
  statusSource,
  highestHp,
  lowestHp,
  others,
  selfOrSelected,
}

enum ValueSubject { self, selected, previousPlayer }

enum TriggerTiming {
  turnStartEarly,
  turnStartBeforeRecovery,
  turnStartEnd,
  gameStart,
  roundStart,
  roundEnd,
  roundEndFinal,
  strengthenedAttack,
  turnStart,
  turnEnd,
  skillUsed,
  skillDrawn,
  attackDeclared,
  attackTargetDeclared,
  attackResolved,
  attackDamageDealt,
  attackDamageReceived,
  attackDamageSettled,
  actionResolved,
  attackPreparing,
  attackReceived,
  actionCommitted,
  traitTriggered,
  impact,
  attackHit,
  attackDodged,
  cardsPlayed,
  cardPlayed,
  cardsDrawn,
  cardsGained,
  cardsLost,
  diceRolled,
  damageDealt,
  damageReceived,
  hpLost,
  healed,
  mpSpent,
  statusApplied,
  statusIncreased,
  statusRemoved,
  statusSettled,
  shieldBroken,
  shieldGained,
  characterDied,
  mpChanged,
  actualMpSpent,
  mpOverflow,
  negativeMpEntered,
  lifePaid,
}

enum TriggerScope { self, allies, enemies, all }

enum CounterReset { never, turn, round, ownerTurn, personalRound }

enum VariableType { number, set, map, list }

enum VariableScope { owner, team, game }

enum VariableVisibility { hidden, owner, team, public }

enum VariableOperation {
  assign,
  add,
  setAdd,
  setRemove,
  mapSet,
  mapAdd,
  mapRemove,
  append,
  listSet,
  listInsert,
  listRemove,
  clear,
}

enum VariableSource {
  variable,
  literal,
  expression,
  selfId,
  selectedId,
  eventAmount,
  eventTags,
  eventSource,
  eventTarget,
  eventDefinition,
  eventRecord,
}

enum VariableComparison {
  equals,
  atLeast,
  atMost,
  contains,
  intersects,
  disjoint,
}

final class VariableDefinition {
  const VariableDefinition({
    required this.id,
    required this.namespace,
    required this.type,
    this.scope = VariableScope.owner,
    this.visibility = VariableVisibility.owner,
    this.reset = CounterReset.never,
    this.initial,
    this.maxEntries = 128,
    this.minimum,
    this.maximum,
  });
  final String id;
  final String namespace;
  final VariableType type;
  final VariableScope scope;
  final VariableVisibility visibility;
  final CounterReset reset;
  final Object? initial;
  final int maxEntries;
  final num? minimum;
  final num? maximum;
}

final class VariableInput {
  const VariableInput({
    this.source = VariableSource.literal,
    this.variable,
    this.subject = ValueSubject.self,
    this.literal,
    this.value,
  });
  final VariableSource source;
  final String? variable;
  final ValueSubject subject;
  final Object? literal;
  final EffectValue? value;
}

final class ModifyVariable extends EffectDefinition {
  const ModifyVariable(
    this.variable, {
    required this.operation,
    this.storageSubject = ValueSubject.selected,
    this.input = const VariableInput(),
    this.key = const VariableInput(),
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final String variable;
  final VariableOperation operation;
  final ValueSubject storageSubject;
  final VariableInput input;
  final VariableInput key;
}

final class VariableCondition extends ConditionDefinition {
  const VariableCondition(
    this.variable, {
    required this.comparison,
    this.input = const VariableInput(),
    this.key,
    this.keySource = VariableSource.literal,
    this.subject = ValueSubject.self,
  });
  final String variable;
  final VariableComparison comparison;
  final VariableInput input;
  final String? key;
  final VariableSource keySource;
  final ValueSubject subject;
}

final class CounterDefinition {
  const CounterDefinition({
    required this.id,
    this.initial = 0,
    this.reset = CounterReset.never,
    this.maximum,
  });
  final String id;
  final int initial;
  final CounterReset reset;
  final int? maximum;
}

final class CounterUpdate {
  const CounterUpdate(
    this.counter, {
    this.amount = 0,
    this.eventAmountFactor = 0,
    this.value,
  });
  final EffectValue? value;
  final String counter;
  final int amount;
  final int eventAmountFactor;
}

final class CounterThreshold {
  const CounterThreshold(this.counter, this.every);
  final String counter;
  final int every;
}

enum ValueField {
  hp,
  missingHp,
  maxHp,
  maxMp,
  attack,
  defense,
  mp,
  handCount,
  shield,
  globalRound,
  markTotal,
  statusTotalStacks,
  statusTotalIntensity,
  statusCharacterCount,
  damageThisTurn,
  damageThisRound,
  damageDealtThisGlobalRound,
  damageReceivedThisGlobalRound,
  healedPreviousGlobalRound,
  eventTagCount,
  eventAmount,
  eventSkillCooldown,
  eventAttackBaseDamage,
  eventStatusIntensity,
  eventStatusStackDelta,
  livingCount,
  summonedCount,
  counter,
  rolled,
  inputNumber,
  discardedCount,
  attackDamage,
  attackDice,
  statusIntensity,
  markCount,
  cardCount,
  cardTagCount,
  statusStacks,
  statusStrength,
  variableNumber,
  variableSize,
  variableMapValue,
  variableNewTagCount,
  variableListValue,
  collection,
}

/// A bounded numeric expression: constant + one runtime value * factor.
final class EffectValue {
  const EffectValue({
    this.reference,
    this.collection,
    this.among = EffectTarget.enemies,
    this.includeDead = false,
    this.includeSummoned = false,
    this.markIds = const [],
    this.variable,
    this.variableKey,
    this.variableKeySource = VariableSource.literal,
    this.variableIndex,
    this.variableProperty,
    this.counter,
    this.operation,
    this.arguments = const [],
    this.statusId,
    this.summonKind,
    this.tags = const [],
    this.markId,
    this.markFromSelf = true,
    this.perIntensity = false,
    this.constant = 0,
    this.field,
    this.subject = ValueSubject.self,
    this.factor = 1,
  });
  final String? reference;
  final CollectionQuery? collection;
  final EffectTarget among;
  final bool includeDead;
  final bool includeSummoned;
  final List<String> markIds;
  final String? counter;
  final String? variable;
  final String? variableKey;
  final VariableSource variableKeySource;
  final EffectValue? variableIndex;
  final String? variableProperty;
  final ValueOperation? operation;
  final List<EffectValue> arguments;
  final String? statusId;
  final String? summonKind;
  final List<String> tags;
  final String? markId;
  final bool markFromSelf;
  final bool perIntensity;
  final double constant;
  final ValueField? field;
  final ValueSubject subject;
  final double factor;
}

sealed class ConditionDefinition {
  const ConditionDefinition();
}

/// A literal, numeric expression, or named reference used by predicates.
final class RuleOperand {
  const RuleOperand({this.literal, this.reference, this.expression});
  final Object? literal;
  final String? reference;
  final EffectValue? expression;
}

final class PredicateCondition extends ConditionDefinition {
  const PredicateCondition(this.op, this.arguments);
  final String op;
  final List<RuleOperand> arguments;
}

final class AllCondition extends ConditionDefinition {
  const AllCondition(this.conditions);
  final List<ConditionDefinition> conditions;
}

final class NotCondition extends ConditionDefinition {
  const NotCondition(this.condition);
  final ConditionDefinition condition;
}

enum NumericComparison { equals, greaterThan, atLeast, atMost, lessThan }

final class ValueCondition extends ConditionDefinition {
  const ValueCondition(
    this.left,
    this.right, {
    this.comparison = NumericComparison.equals,
  });
  final EffectValue left;
  final EffectValue right;
  final NumericComparison comparison;
}

final class RelationCondition extends ConditionDefinition {
  const RelationCondition({this.among = EffectTarget.allies});
  final EffectTarget among;
}

final class LivingCountCondition extends ConditionDefinition {
  const LivingCountCondition({
    this.among = EffectTarget.allies,
    this.excludeSelf = false,
    this.selectedOnly = false,
    this.atLeast = 1,
    this.when,
  });
  final EffectTarget among;
  final bool excludeSelf;
  final bool selectedOnly;
  final int atLeast;
  final ConditionDefinition? when;
}

final class AnyCondition extends ConditionDefinition {
  AnyCondition(List<ConditionDefinition> conditions)
    : conditions = List.unmodifiable(conditions);
  final List<ConditionDefinition> conditions;
}

/// Equal extrema satisfy the condition; subject must belong to the candidate set.
final class StatExtremumCondition extends ConditionDefinition {
  const StatExtremumCondition({
    required this.stat,
    this.highest = false,
    this.subject = EffectTarget.selected,
    this.among = EffectTarget.enemies,
  });
  final Stat stat;
  final bool highest;
  final EffectTarget subject;
  final EffectTarget among;
}

/// Matches at least one definition in the current played-card group.
final class PlayedCardCondition extends ConditionDefinition {
  PlayedCardCondition(Set<String> cardIds)
    : cardIds = Set.unmodifiable(cardIds);
  final Set<String> cardIds;
}

final class HasStatusQueryCondition extends ConditionDefinition {
  const HasStatusQueryCondition(this.query);
  final StatusQuery query;
}

final class HasStatusCondition extends ConditionDefinition {
  const HasStatusCondition(this.statusId);
  final String statusId;
}

final class CounterEqualsCondition extends ConditionDefinition {
  const CounterEqualsCondition(this.counter, this.amount);
  final String counter;
  final int amount;
}

final class MarkCondition extends ConditionDefinition {
  const MarkCondition(
    this.markId, {
    this.minimum = 1,
    this.subject = EffectTarget.selected,
    this.fromSelf = true,
    this.negate = false,
  });
  final String markId;
  final int minimum;
  final EffectTarget subject;
  final bool fromSelf;
  final bool negate;
}

final class HpRatioCondition extends ConditionDefinition {
  const HpRatioCondition(this.fraction, {this.subject = ValueSubject.self});
  final double fraction;
  final ValueSubject subject;
}

final class HasShieldCondition extends ConditionDefinition {
  const HasShieldCondition();
}

/// Evaluated per attack target after card effects and before damage calculation.
final class AttackModifier {
  const AttackModifier({
    this.when,
    this.attackBonus = 0,
    this.finalDamageBonus = 0,
    this.finalDamageValue,
    this.finalDamageMultiplier = 1,
    this.ignoreDefenseAmount = 0,
    this.ignoreDefenseRatio = 0.0,
    this.clearDodge = false,
    this.ignoreShield = false,
    this.ignoreDodge = false,
  });
  final ConditionDefinition? when;
  final int ignoreDefenseAmount;

  /// Fraction of panel defense ignored before flat penetration; 0.5 means 50%.
  final double ignoreDefenseRatio;
  final bool clearDodge;
  final bool ignoreShield;
  final bool ignoreDodge;
  final int attackBonus;
  final int finalDamageBonus;
  final EffectValue? finalDamageValue;
  final double finalDamageMultiplier;
}

final class TriggerDefinition {
  TriggerDefinition({
    required this.timing,
    required List<EffectDefinition> effects,
    ConditionDefinition? when,
    ConditionDefinition? guard,
    this.scope = TriggerScope.self,
    this.recordOnly = false,
    this.ignoreSuppression = false,
    this.maxUses,
    this.limitWindow = CounterReset.never,
    this.threshold,
    this.repeatPerAmount = false,
    this.scaleWithIntensity = true,
    this.oncePerPacket = false,
    this.limitGroup,
    List<CounterUpdate> counterUpdates = const [],
    // Constructor compatibility is compiled once. Execution only sees when/guard.
    int? minimumAmount,
    int? maximumAmount,
    int? maximumDamageThisRound,
    int? maximumHandCount,
    double? maximumHpFraction,
    int? minimumHp,
    bool attackOnly = false,
    bool excludeIndependent = false,
    bool ownerTurnOnly = false,
    bool otherSourceOnly = false,
    bool negativeStatusOnly = false,
    String? tag,
    int? minimumSharedTagCount,
    String? definitionId,
    DamageKind? damageKind,
  }) : effects = List.unmodifiable(effects),
       counterUpdates = List.unmodifiable(counterUpdates),
       when = _combineConditions([
         if (when != null) when,
         if (minimumAmount != null)
           _compareReference('gte', 'event.amount', minimumAmount),
         if (maximumAmount != null)
           _compareReference('lte', 'event.amount', maximumAmount),
         if (maximumDamageThisRound != null)
           _compareReference(
             'lte',
             'self.damageThisRound',
             maximumDamageThisRound,
           ),
         if (maximumHandCount != null)
           _compareReference('lte', 'self.handCount', maximumHandCount),
         if (definitionId != null)
           _compareReference('eq', 'event.definition', definitionId),
         if (damageKind != null)
           _compareReference('eq', 'event.damageKind', damageKind.name),
         if (attackOnly) _compareReference('eq', 'event.attack', true),
         if (excludeIndependent)
           _compareReference('eq', 'event.independent', false),
         if (ownerTurnOnly) _compareReference('eq', 'self.activeTurn', true),
         if (negativeStatusOnly)
           _compareReference('eq', 'event.negativeStatus', true),
         if (otherSourceOnly) _compareReference('ne', 'event.source', null),
         if (otherSourceOnly)
           const PredicateCondition('ne', [
             RuleOperand(reference: 'event.source'),
             RuleOperand(reference: 'self.id'),
           ]),
         if (tag != null) _compareReference('contains', 'event.tags', tag),
         if (minimumSharedTagCount != null)
           PredicateCondition('gte', [
             RuleOperand(
               expression: EffectValue(
                 field: ValueField.eventTagCount,
                 tags: tag == null ? const [] : [tag],
               ),
             ),
             RuleOperand(literal: minimumSharedTagCount),
           ]),
       ]),
       guard = _combineConditions([
         if (guard != null) guard,
         if (minimumHp != null) _compareReference('gte', 'self.hp', minimumHp),
         if (maximumHpFraction != null)
           PredicateCondition('lte', [
             const RuleOperand(reference: 'self.hp'),
             RuleOperand(
               expression: EffectValue(
                 field: ValueField.maxHp,
                 factor: maximumHpFraction,
               ),
             ),
           ]),
       ]) {
    if ((minimumAmount != null &&
            maximumAmount != null &&
            minimumAmount > maximumAmount) ||
        (minimumSharedTagCount != null && minimumSharedTagCount <= 0)) {
      throw StateError('Invalid legacy trigger range');
    }
  }
  final TriggerTiming timing;
  final ConditionDefinition? when;
  final ConditionDefinition? guard;
  final TriggerScope scope;
  final List<EffectDefinition> effects;
  final bool recordOnly;
  final bool ignoreSuppression;
  final int? maxUses;
  final CounterReset limitWindow;
  final CounterThreshold? threshold;
  final bool repeatPerAmount;
  final bool scaleWithIntensity;
  final bool oncePerPacket;
  final String? limitGroup;
  final List<CounterUpdate> counterUpdates;
}

ConditionDefinition? _combineConditions(List<ConditionDefinition> conditions) =>
    conditions.isEmpty
    ? null
    : conditions.length == 1
    ? conditions.single
    : AllCondition(List.unmodifiable(conditions));
PredicateCondition _compareReference(String op, String ref, Object? value) =>
    PredicateCondition(op, [
      RuleOperand(reference: ref),
      RuleOperand(literal: value),
    ]);

enum SkillTiming {
  main,
  diceResponse,
  skillResponse,
  actionResponse,
  settlement,
}

enum AnomalyConflict { reject, replace }

enum StatusCategory { normal, anomaly }

enum SchedulePhase { turnStart, turnEnd, roundStart, roundEnd }

enum StatusDecay {
  globalRound,
  anchoredRound,
  onAttackHit,
  onAttack,
  none,
  ownerTurnStartEnd,
  anchorMpRecovery,
}

enum EmptyDeckPolicy { stopDrawing, recycleDiscards }

final class TemplateDefinition {
  const TemplateDefinition({
    required this.id,
    required this.hp,
    required this.attack,
    required this.defense,
  });
  final String id;
  final int hp;
  final int attack;
  final int defense;
}

enum MpRegenMode { periodic, refillAfterExhaustion }

enum MpRegenPhase { turnStart, turnEnd }

final class RaceDefinition {
  const RaceDefinition({
    required this.id,
    required this.initialMp,
    required this.maxMp,
    required this.regenMp,
    this.regenInterval = 1,
    this.regenMode = MpRegenMode.periodic,
    this.regenPhase = MpRegenPhase.turnStart,
    this.initialMpValue,
    this.regenMpValue,
    this.counters = const [],
    this.triggers = const [],
  });
  final String id;
  final int initialMp;
  final int maxMp;
  final int regenMp;

  /// Eligible configured phases; start includes extra starts, end occurs once per suite.
  /// Blocked recovery freezes progress.
  final int regenInterval;
  final MpRegenMode regenMode;
  final MpRegenPhase regenPhase;
  final EffectValue? initialMpValue;
  final EffectValue? regenMpValue;
  final List<CounterDefinition> counters;
  final List<TriggerDefinition> triggers;
}

/// A defender's persistent duel bonus is stored on its trait instance.
final class AttackDuelDefinition {
  const AttackDuelDefinition({
    this.counter = 'duel_bonus',
    this.failureBonus = 1,
    this.victoryAttack = 5,
  });
  final String counter;
  final int failureBonus;
  final int victoryAttack;
}

final class MarkStatBonus {
  MarkStatBonus({
    required this.markId,
    required Map<Stat, int> modifiersPerCount,
    this.fromSelf = true,
  }) : modifiersPerCount = Map.unmodifiable(modifiersPerCount);
  final String markId;
  final Map<Stat, int> modifiersPerCount;
  final bool fromSelf;
}

final class StatusStatBonus {
  StatusStatBonus({
    required List<String> allStatuses,
    required Map<Stat, int> modifiers,
  }) : allStatuses = List.unmodifiable(allStatuses),
       modifiers = Map.unmodifiable(modifiers);
  final List<String> allStatuses;
  final Map<Stat, int> modifiers;
}

enum ResourcePolicy { normal, healthActions, defenseLife }

enum AttackDiceMode { facesOffset, binarySum }

final class AttackDiceRule {
  const AttackDiceRule({
    required this.mode,
    this.offset = 0,
    this.roundUp = false,
    this.oddRemainderFixedOne = false,
  });
  final AttackDiceMode mode;
  final int offset;
  final bool roundUp;
  final bool oddRemainderFixedOne;
}

final class AttackFormula {
  const AttackFormula({this.kind = DamageKind.real, this.attackOffset = 0});
  final DamageKind kind;
  final int attackOffset;
}

final class IncomingAttackRule {
  const IncomingAttackRule({
    this.ignoreCardFinalDamage = false,
    this.finalDamageReductionValue,
    this.reduceAttachments = false,
    this.blockGroupAttackEffects = false,
    this.useBaseDice = false,
    this.diceCap,
  });
  final bool ignoreCardFinalDamage;
  final EffectValue? finalDamageReductionValue;
  final bool reduceAttachments;
  final bool blockGroupAttackEffects;
  final bool useBaseDice;
  final int? diceCap;
}

final class AttackAura {
  const AttackAura({
    this.scope = EffectTarget.allies,
    this.strengthenedOnly = false,
    this.thresholdReduction = 0,
    this.attackModifiers = const [],
    this.onHit = const [],
    this.finalDamageMultiplier = 1,
  });
  final EffectTarget scope;
  final bool strengthenedOnly;
  final int thresholdReduction;
  final List<AttackModifier> attackModifiers;
  final List<EffectDefinition> onHit;
  final double finalDamageMultiplier;
}

final class DamageAura {
  const DamageAura({
    this.scope = EffectTarget.all,
    this.when,
    this.factor = 1,
    this.flat = 0,
  });
  final EffectTarget scope;
  final ConditionDefinition? when;
  final double factor;
  final int flat;
}

final class OutgoingDuel {
  OutgoingDuel({
    List<EffectDefinition> victory = const [],
    List<EffectDefinition> after = const [],
  }) : victory = List.unmodifiable(victory),
       after = List.unmodifiable(after);
  final List<EffectDefinition> victory;
  final List<EffectDefinition> after;
}

final class FlipMarks extends EffectDefinition {
  const FlipMarks(
    this.first,
    this.second, {
    this.mode = 'toggle',
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final String first;
  final String second;
  final String mode;
}

final class ForceNextAttackTarget extends EffectDefinition {
  const ForceNextAttackTarget({EffectTarget target = EffectTarget.selected})
    : super(target);
}

/// Persistent resource accrued from actual HP damage, with a threshold reaction.
/// Independent resource-related abilities. None are implied by ResourcePolicy.
final class ResourceAbilities {
  ResourceAbilities({
    this.cardLifeCost = 0,
    Map<int, double> damageHealing = const {},
    this.idleDrawCount = 0,
    this.idleTakeCount = 1,
    this.defenseLossPerDamage = .02,
    this.shieldDefenseFactor = 0,
    this.shieldDefenseTurns = 1,
    this.legacyDefenseDiscard = false,
  }) : damageHealing = Map.unmodifiable(damageHealing) {
    if (cardLifeCost < 0 ||
        idleDrawCount < 0 ||
        idleTakeCount < 0 ||
        !defenseLossPerDamage.isFinite ||
        defenseLossPerDamage < 0 ||
        shieldDefenseTurns < 1 ||
        !shieldDefenseFactor.isFinite ||
        shieldDefenseFactor < 0 ||
        damageHealing.entries.any(
          (e) => e.key < 1 || !e.value.isFinite || e.value < 0,
        )) {
      throw ArgumentError('Invalid resource ability parameters');
    }
  }
  final int cardLifeCost;
  final Map<int, double> damageHealing;
  final int idleDrawCount;
  final int idleTakeCount;
  final double defenseLossPerDamage;
  final double shieldDefenseFactor;
  final int shieldDefenseTurns;
  // Only the legacy content decoder may opt into the historical choice protocol.
  final bool legacyDefenseDiscard;
}

final class TraitDefinition {
  TraitDefinition({
    required this.id,
    MechanismBindings? mechanisms,
    this.attackDiceBonusValue,
    this.defaultAttackDiceSides,
    this.attackDiceGrowth,
    this.cardEffectOverrides = const {},
    this.freeCardTags = const {},
    this.refundNonDamagingAction = false,
    this.statusGainMultipliers = const {},
    this.attackDiceSequence,
    this.attackDiceRule,
    this.attackFormula,
    this.incomingAttack,
    this.incomingAttackTargetWhen,
    this.attackAura,
    this.attackHpThreshold,
    this.attackDamageMultiplier = 1,
    this.damageRewrite,
    this.healingRewrite,
    this.healingRewriteIgnoresModifiers = false,
    this.healingRewriteBlockedBy,
    this.damageAura,
    this.outgoingDuel,
    this.active,
    this.borrowAttackCard = false,
    this.cardMaxTagDiscount = false,
    this.actionMpDiscount = 0,
    this.openingSkillBonus = 0,
    this.waiveSkillSurcharge = false,
    List<DamageGuard> damageGuards = const [],
    List<AttackModifier> attackModifiers = const [],
    this.resourcePolicy = ResourcePolicy.normal,
    ResourceAbilities? resourceAbilities,
    bool saveAtTurnStart = false,
    bool recordActions = false,
    List<MarkStatBonus> markStatBonuses = const [],
    List<StatusStatBonus> statusStatBonuses = const [],
    this.attackDuel,
    List<String> immuneStatuses = const [],
    List<String> endMarkChoices = const [],
    this.endMarkCount = 1,
    List<AttackStatusRule> attackStatuses = const [],
    List<EffectDefinition> onHit = const [],
    Map<Stat, int> modifiers = const {},
    this.battleContinuation = false,
    this.battleContinuationThroughRound,
    this.incomingDamageMultiplier = 1,
    this.rerollOfferCost,
    bool chooseDamageRoll = false,
    Set<String> suppressedCardTags = const {},
    this.suppressedCardMinTags,
    Set<String> attackCompanionTags = const {},
    this.healingForbidden = false,
    LifeThresholdRule? lifeThreshold,
    CardLifeRule? cardLifeRule,
    NegativeMpAura? negativeMpAura,
    TagRewards? tagRewards,
    PreyRule? prey,
    RotatingCardEffects? rotatingCardEffects,
    TimeReserveRule? timeReserve,
    BuddyBlockRule? buddyBlock,
    SupportStanceRule? supportStance,
    DamageShareRule? damageShare,
    DiscardReserveRule? discardReserve,
    int? skillRefundDivisor,
    DreamCraftRule? dreamCraft,
    FruitAttackRule? fruitAttack,
    NightmareRule? nightmare,
    SummonDefenseRule? summonDefense,
    bool borrowSkillAtTurnStart = false,
    bool shieldLifeCycle = false,
    bool generatedActionOnShield = false,
    DamageResourceRule? damageResource,
    DecreeRule? decree,
    this.continuationRecoverySides,
    this.continuationRecoverySuccess = const [],
    List<TriggerDefinition> triggers = const [],
    List<CounterDefinition> counters = const [],
  }) : resourceAbilities = resourceAbilities ?? ResourceAbilities(),
       mechanisms = MechanismBindings([
         ...?mechanisms?.configurations,
         if (lifeThreshold != null) lifeThreshold,
         if (cardLifeRule != null) cardLifeRule,
         if (negativeMpAura != null) negativeMpAura,
         if (tagRewards != null) tagRewards,
         if (prey != null) prey,
         if (rotatingCardEffects != null) rotatingCardEffects,
         if (timeReserve != null) timeReserve,
         if (buddyBlock != null) buddyBlock,
         if (supportStance != null) supportStance,
         if (damageShare != null) damageShare,
         if (discardReserve != null) discardReserve,
         if (dreamCraft != null) dreamCraft,
         if (fruitAttack != null) fruitAttack,
         if (nightmare != null) nightmare,
         if (summonDefense != null) summonDefense,
         if (damageResource != null) damageResource,
         if (decree != null) decree,
         if (saveAtTurnStart) const TurnSaveRule(),
         if (recordActions) const ActionRecordingRule(),
         if (borrowSkillAtTurnStart) const SkillBorrowRule(),
         if (shieldLifeCycle) const ShieldLifeCycleRule(),
         if (generatedActionOnShield) const GeneratedShieldActionRule(),
         if (chooseDamageRoll) const DamageRollChoiceRule(),
         if (skillRefundDivisor != null) SkillRefundRule(skillRefundDivisor),
       ]),
       suppressedCardTags = Set.unmodifiable(suppressedCardTags),
       attackCompanionTags = Set.unmodifiable(attackCompanionTags),
       attackModifiers = List.unmodifiable(attackModifiers),
       damageGuards = List.unmodifiable(damageGuards),
       markStatBonuses = List.unmodifiable(markStatBonuses),
       statusStatBonuses = List.unmodifiable(statusStatBonuses),
       immuneStatuses = List.unmodifiable(immuneStatuses),
       endMarkChoices = List.unmodifiable(endMarkChoices),
       attackStatuses = List.unmodifiable(attackStatuses),
       counters = List.unmodifiable(counters),
       onHit = List.unmodifiable(onHit),
       triggers = List.unmodifiable(triggers),
       modifiers = Map.unmodifiable(modifiers);
  final MechanismBindings mechanisms;
  final List<CounterDefinition> counters;
  final EffectValue? attackDiceBonusValue;
  final int? defaultAttackDiceSides;
  final AttackDiceGrowth? attackDiceGrowth;
  final Map<String, List<EffectDefinition>> cardEffectOverrides;
  final Set<String> freeCardTags;
  final bool refundNonDamagingAction;
  final Map<String, int> statusGainMultipliers;
  final AttackDiceSequence? attackDiceSequence;
  final AttackDiceRule? attackDiceRule;
  final AttackFormula? attackFormula;
  final IncomingAttackRule? incomingAttack;
  final ConditionDefinition? incomingAttackTargetWhen;
  final AttackAura? attackAura;
  final double? attackHpThreshold;
  final double attackDamageMultiplier;
  final int? damageRewrite;
  final int? healingRewrite;
  final bool healingRewriteIgnoresModifiers;
  final StatusQuery? healingRewriteBlockedBy;
  final DamageAura? damageAura;
  final OutgoingDuel? outgoingDuel;
  final TraitAction? active;
  final bool borrowAttackCard;
  final List<AttackModifier> attackModifiers;
  final bool cardMaxTagDiscount;
  final int actionMpDiscount;
  final int openingSkillBonus;
  final bool waiveSkillSurcharge;
  final List<DamageGuard> damageGuards;
  final ResourcePolicy resourcePolicy;
  final ResourceAbilities resourceAbilities;
  final List<MarkStatBonus> markStatBonuses;
  final List<StatusStatBonus> statusStatBonuses;
  final AttackDuelDefinition? attackDuel;
  final List<String> immuneStatuses;
  final List<String> endMarkChoices;
  final int endMarkCount;
  final List<AttackStatusRule> attackStatuses;
  final String id;
  final List<EffectDefinition> onHit;
  final Map<Stat, int> modifiers;
  final bool battleContinuation;
  final int? battleContinuationThroughRound;
  final double incomingDamageMultiplier;
  final int? rerollOfferCost;
  final Set<String> suppressedCardTags, attackCompanionTags;
  final int? suppressedCardMinTags;
  final bool healingForbidden;
  final int? continuationRecoverySides;
  final List<int> continuationRecoverySuccess;
  final List<TriggerDefinition> triggers;
}

/// Staged mechanisms configure IDs and constants; runtime contains no role names.

final class ModifyActionDice extends EffectDefinition {
  const ModifyActionDice(this.amount) : super(EffectTarget.self);
  final int amount;
}

final class ClearProtection extends EffectDefinition {
  const ClearProtection({
    this.shield = true,
    this.dodge = true,
    this.positive = false,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final bool shield, dodge, positive;
}

/// Explicitly settle one representative status trigger, without automatic decay.
final class SettleStatus extends EffectDefinition {
  const SettleStatus(
    this.statusId, {
    this.triggerIndex = 0,
    this.ignoreLimits = false,
    this.phase,
    this.allStacks = false,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final String statusId;
  final int triggerIndex;
  final bool ignoreLimits;
  final SchedulePhase? phase;
  final bool allStacks;
}

final class SummonUnit extends EffectDefinition {
  const SummonUnit(
    this.kind, {
    this.count = 1,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final String kind;
  final int count;
}

final class CharacterDefinition {
  CharacterDefinition({
    required this.id,
    required this.templateId,
    required this.raceId,
    List<String> traits = const [],
    List<String> skills = const [],
  }) : traits = List.unmodifiable(traits),
       skills = List.unmodifiable(skills);
  final String id;
  final String templateId;
  final String raceId;
  final List<String> traits;
  final List<String> skills;
}

/// Typed operators shared by cards, skills, statuses and trait triggers.
/// More complex choices and event-dependent operators extend this vocabulary.
enum EffectPhase { ruleSetup, resolve }

sealed class EffectDefinition {
  const EffectDefinition(
    this.target, {
    this.executionPhase = EffectPhase.resolve,
  });
  final EffectTarget target;
  final EffectPhase executionPhase;
}

final class ModifyStat extends EffectDefinition {
  const ModifyStat(
    this.stat,
    this.amount, {
    this.onClamp = const [],
    this.value,
    this.oncePerAction = false,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final EffectValue? value;
  final bool oncePerAction;
  final List<EffectDefinition> onClamp;
  final Stat stat;
  final int amount;
}

final class HealEffect extends EffectDefinition {
  final EffectValue? value;
  const HealEffect(
    this.amount, {
    this.value,
    this.sourceTraitId,
    this.targetTraitId,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int amount;
  final String? sourceTraitId, targetTraitId;
}

final class DamageEffect extends EffectDefinition {
  const DamageEffect(
    this.amount, {
    this.kind = DamageKind.physical,
    this.value,
    this.sourceless = false,
    this.fromStatusSource = false,
    this.onDamage = const [],
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final int amount;
  final DamageKind kind;
  final EffectValue? value;
  final bool sourceless;
  final bool fromStatusSource;
  final List<EffectDefinition> onDamage;
}

/// Consume this round's settled incoming damage, refund HP without healing,
/// and deal the consumed amount to the selected target.
final class TransferShield extends EffectDefinition {
  const TransferShield(
    this.limit, {
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final int limit;
}

final class RemoveSummons extends EffectDefinition {
  const RemoveSummons(this.kind, {EffectTarget target = EffectTarget.self})
    : super(target);
  final String kind;
}

final class TransferReceivedDamage extends EffectDefinition {
  const TransferReceivedDamage({EffectTarget target = EffectTarget.selected})
    : super(target);
}

final class StealLife extends EffectDefinition {
  const StealLife(
    this.amount, {
    this.value,
    this.healNominal = false,
    this.fromStatusSource = false,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final int amount;
  final EffectValue? value;
  final bool healNominal;
  final bool fromStatusSource;
}

final class ShieldEffect extends EffectDefinition {
  const ShieldEffect(
    this.amount, {
    this.value,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int amount;
  final EffectValue? value;
}

final class ScheduleEffect extends EffectDefinition {
  ScheduleEffect({
    required this.phase,
    required List<EffectDefinition> effects,
    this.after = 1,
    this.captureValues = false,
    EffectTarget target = EffectTarget.self,
  }) : effects = List.unmodifiable(effects),
       super(target);
  final bool captureValues;
  final SchedulePhase phase;
  final int after;
  final List<EffectDefinition> effects;
}

final class ReverseTurnOrder extends EffectDefinition {
  const ReverseTurnOrder() : super(EffectTarget.self);
}

final class GrantActions extends EffectDefinition {
  const GrantActions(
    this.count, {
    this.value,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int count;
  final EffectValue? value;
}

final class DrawEffect extends EffectDefinition {
  const DrawEffect(
    this.count, {
    this.value,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int count;
  final EffectValue? value;
}

final class ApplyStatus extends EffectDefinition {
  const ApplyStatus(
    this.statusId, {
    this.stacks = 1,
    this.stacksValue,
    this.intensity = 1,
    this.intensityValue,
    this.refreshSource = false,
    this.ignoreNegativeProtection = const [],
    this.damageLimit,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final String statusId;
  final int stacks;
  final EffectValue? stacksValue;
  final int intensity;
  final EffectValue? intensityValue;
  final bool refreshSource;
  final List<String> ignoreNegativeProtection;
  final int? damageLimit;
}

final class PayLife extends EffectDefinition {
  const PayLife(this.value) : super(EffectTarget.self);
  final EffectValue value;
}

final class PayMp extends EffectDefinition {
  const PayMp(
    this.amount, {
    this.value,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int amount;
  final EffectValue? value;
}

final class ArmAttackTransfer extends EffectDefinition {
  const ArmAttackTransfer({this.followAttackTarget = false})
    : super(followAttackTarget ? EffectTarget.self : EffectTarget.selected);

  final bool followAttackTarget;
}

final class UseTimeReserve extends EffectDefinition {
  const UseTimeReserve() : super(EffectTarget.selected);
}

final class ModifyMp extends EffectDefinition {
  const ModifyMp(
    this.amount, {
    this.value,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int amount;
  final EffectValue? value;
}

/// Transfers only MP the donor actually has; MP-less policies still apply.
final class TransferMp extends EffectDefinition {
  const TransferMp(this.amount, {EffectTarget target = EffectTarget.selected})
    : super(target);
  final int amount;
}

final class ModifyCooldown extends EffectDefinition {
  final bool usedSkillOnly;
  const ModifyCooldown(
    this.amount, {
    this.usedSkillOnly = false,
    this.skillId,
    this.value,
    this.query = const SkillQuery(),
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int amount;
  final String? skillId;
  final EffectValue? value;
  final SkillQuery query;
}

final class ModifyOwnStatus extends EffectDefinition {
  const ModifyOwnStatus({this.stacks = 0, this.intensity = 0})
    : super(EffectTarget.self);
  final int stacks;
  final int intensity;
}

final class RemoveStatuses extends EffectDefinition {
  const RemoveStatuses({
    this.negativeOnly = false,
    this.includeAnomalies = true,
    this.statusId,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final bool negativeOnly;
  final bool includeAnomalies;
  final String? statusId;
}

final class RedirectAttack extends EffectDefinition {
  const RedirectAttack({
    required this.cap,
    required this.overflowUnit,
    required this.markId,
  }) : super(EffectTarget.self);
  final int cap;
  final int overflowUnit;
  final String markId;
}

final class SetDiceResult extends EffectDefinition {
  const SetDiceResult() : super(EffectTarget.selected);
}

final class CancelCard extends EffectDefinition {
  const CancelCard() : super(EffectTarget.self);
}

final class CancelSkill extends EffectDefinition {
  const CancelSkill({this.discardCount = 0, this.othersOnly = false})
    : super(EffectTarget.selected);
  final int discardCount;
  final bool othersOnly;
}

enum ChoiceKind {
  abilityOption,
  discardPileCard,
  deckCard,
  attackCard,
  mechanism,
  takeCard,
  discardCard,
  returnCardToDeck,
  extendStatus,
  resetCooldown,
  mark,
  character,
  status,
}

/// Choices are resolved by the card user; hidden cards use opaque option IDs.
final class ChooseEffect extends EffectDefinition {
  const ChooseEffect(
    this.kind, {
    this.reveal = false,
    this.minimumDeckCopies = 0,
    this.random = false,
    this.amount = 1,
    this.chooser = ChoiceChooser.actor,
    this.optional = false,
    this.preserveSelected = false,
    this.excludeSelected = false,
    this.when,
    this.statusQuery = const StatusQuery(),
    this.statusQueryFromAlias = false,
    this.cardQuery = const CardQuery(),
    this.skillQuery = const SkillQuery(),
    this.includeMissing = false,
    this.effects = const [],
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final ChoiceChooser chooser;
  final bool optional;
  final bool preserveSelected;
  final bool excludeSelected;
  final ConditionDefinition? when;
  final StatusQuery statusQuery;
  // Retain the source spelling so recovery can reproduce the old ignored alias.
  final bool statusQueryFromAlias;
  final CardQuery cardQuery;
  final SkillQuery skillQuery;
  final bool includeMissing;
  final List<EffectDefinition> effects;
  final ChoiceKind kind;
  final int minimumDeckCopies;
  final bool random;
  final bool reveal;
  final int amount;
}

/// Select distinct characters without mutating the selected objects.
enum GeneratedCardUse { nextAttack, action }

final class GenerateChosenCard extends EffectDefinition {
  const GenerateChosenCard({
    this.use = GeneratedCardUse.nextAttack,
    this.exclude = const [],
    this.consumeAction = false,
    this.query = const CardQuery(),
  }) : super(EffectTarget.self);
  final GeneratedCardUse use;
  final List<String> exclude;
  final bool consumeAction;
  final CardQuery query;
}

enum CardDestination { discard, hand, deck }

final class ChooseCards extends EffectDefinition {
  const ChooseCards({
    required this.minimum,
    required this.maximum,
    this.minimumTags = 0,
    this.anyTags = const [],
    this.query = const CardQuery(),
    this.bind,
    this.destination = CardDestination.discard,
    this.recipient = EffectTarget.selected,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final EffectValue minimum;
  final EffectValue maximum;
  final int minimumTags;
  final List<String> anyTags;
  final CardQuery query;
  final String? bind;
  final CardDestination destination;
  final EffectTarget recipient;
}

final class ChooseTargets extends EffectDefinition {
  const ChooseTargets({
    required this.bind,
    this.minimum = 1,
    this.maximum = 1,
    this.minimumValue,
    this.maximumValue,
    this.when,
    EffectTarget from = EffectTarget.all,
  }) : super(from);
  final String bind;
  final int minimum;
  final int maximum;
  final EffectValue? minimumValue;
  final EffectValue? maximumValue;
  final ConditionDefinition? when;
}

final class WithTargets extends EffectDefinition {
  const WithTargets(this.reference, this.effects) : super(EffectTarget.self);
  final String reference;
  final List<EffectDefinition> effects;
}

final class AbilityOption {
  AbilityOption({
    required this.id,
    this.label = '',
    this.when,
    required List<EffectDefinition> effects,
  }) : effects = List.unmodifiable(effects);
  final String id;
  final String label;
  final ConditionDefinition? when;
  final List<EffectDefinition> effects;
}

final class SelectOptionEffect extends EffectDefinition {
  SelectOptionEffect(
    List<AbilityOption> options, {
    this.chooser = ChoiceChooser.actor,
  }) : options = List.unmodifiable(options),
       super(EffectTarget.self);
  final List<AbilityOption> options;
  final ChoiceChooser chooser;
}

final class ArmTrigger extends EffectDefinition {
  ArmTrigger(List<TriggerDefinition> triggers)
    : triggers = List.unmodifiable(triggers),
      super(EffectTarget.self);
  final List<TriggerDefinition> triggers;
}

final class RandomDiscard extends EffectDefinition {
  const RandomDiscard(
    this.count, {
    this.value,
    this.query = const CardQuery(),
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final int count;
  final EffectValue? value;
  final CardQuery query;
}

final class DiscardHand extends EffectDefinition {
  const DiscardHand() : super(EffectTarget.self);
}

final class StealEffect extends EffectDefinition {
  const StealEffect({this.hp = 0, this.attack = 0})
    : super(EffectTarget.selected);
  final int hp;
  final int attack;
}

final class SwapResources extends EffectDefinition {
  const SwapResources({
    this.hp = true,
    this.mp = true,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final bool hp;
  final bool mp;
}

final class EqualizeHand extends EffectDefinition {
  const EqualizeHand({EffectTarget target = EffectTarget.selected})
    : super(target);
}

final class SwapHands extends EffectDefinition {
  const SwapHands() : super(EffectTarget.selected);
}

final class SwapStatuses extends EffectDefinition {
  const SwapStatuses() : super(EffectTarget.selected);
}

final class DrawSkill extends EffectDefinition {
  const DrawSkill({this.uses = 1, this.count = 1}) : super(EffectTarget.self);
  final int uses;
  final int count;
}

final class BlockStatusApplication extends EffectDefinition {
  const BlockStatusApplication(
    this.rounds, {
    EffectPhase phase = EffectPhase.resolve,
  }) : super(EffectTarget.self, executionPhase: phase);
  final int rounds;
}

final class ModifyAttack extends EffectDefinition {
  const ModifyAttack(this.amount, {this.multiplier = 1, this.value})
    : super(EffectTarget.self);
  final int amount;
  final double multiplier;
  final EffectValue? value;
}

/// Adds to the attack stat used by this action's formula, not final damage.
final class ModifyAttackPower extends EffectDefinition {
  const ModifyAttackPower(this.amount, {this.value}) : super(EffectTarget.self);
  final int amount;
  final EffectValue? value;
}

final class AttackDiceSequence {
  AttackDiceSequence({
    required List<int> values,
    required this.positionVariable,
    this.diceSides = 4,
    this.replaceDiceSides = true,
  }) : values = List.unmodifiable(values);
  final List<int> values;
  final String positionVariable;
  final int diceSides;
  final bool replaceDiceSides;
}

final class SetCounter extends EffectDefinition {
  const SetCounter(this.counter, this.amount, {this.add = false})
    : super(EffectTarget.self);
  final String counter;
  final int amount;
  final bool add;
}

final class ConditionalEffect extends EffectDefinition {
  ConditionalEffect(
    this.when,
    List<EffectDefinition> effects, {
    List<EffectDefinition> otherwise = const [],
    this.eachTarget = false,
    this.snapshot = false,
    EffectTarget target = EffectTarget.selected,
  }) : effects = List.unmodifiable(effects),
       otherwise = List.unmodifiable(otherwise),
       super(target);
  final bool eachTarget;
  final bool snapshot;
  final ConditionDefinition when;
  final List<EffectDefinition> effects;
  final List<EffectDefinition> otherwise;
}

/// Roll once per target; branches retain the original selected target(s).
final class RollEffect extends EffectDefinition {
  RollEffect({
    required this.sides,
    this.bind,
    this.damageRoll = false,
    this.count = 1,
    List<int> success = const [],
    this.atMost,
    this.atLeast,
    this.eachTarget = false,
    this.roller = ChoiceChooser.target,
    List<EffectDefinition> effects = const [],
    List<EffectDefinition> otherwise = const [],
    EffectTarget target = EffectTarget.self,
  }) : success = List.unmodifiable(success),
       effects = List.unmodifiable(effects),
       otherwise = List.unmodifiable(otherwise),
       super(target);
  final String? bind;
  final bool damageRoll;
  final int sides;
  final int count;
  final List<int> success;
  final EffectValue? atMost;
  final EffectValue? atLeast;
  final bool eachTarget;
  final ChoiceChooser roller;
  final List<EffectDefinition> effects;
  final List<EffectDefinition> otherwise;
}

final class DiceContest extends EffectDefinition {
  const DiceContest({this.sides = 4, this.factor = 50, this.bonus = 1})
    : super(EffectTarget.self);
  final int sides;
  final int factor;
  final int bonus;
}

enum CardResponse { dodge, counterDodge }

final class CardDefinition {
  CardDefinition({
    required this.id,
    this.response,
    List<EffectDefinition> onHit = const [],
    this.mpCost = 1,
    this.mirrorCardId,
    this.actionCostBonus = 0,
    this.attacks = true,
    this.isLimited = false,
    Set<String> attacksWithCardIds = const {},
    Map<String, int> statusStackMultipliers = const {},
    List<EffectDefinition> effects = const [],
    List<AttackModifier> attackModifiers = const [],
    Set<String> tags = const {},
    this.attackBonus = 0,
    this.defenseBonus = 0,
    this.attackMultiplier = 1,
    this.defenseMultiplier = 1,
    this.finalDamageBonus = 0,
    this.finalDamageMultiplier = 1,
    this.diceSides,
    this.reinforcedDiceSides,
    this.diceBonus = 0,
    this.ignoreDefense = false,
    this.ignoreDodge = false,
    this.clearDodge = false,
    this.clearShield = false,
    this.damageKind = DamageKind.physical,
    this.piercesContinuation = false,
  }) : attacksWithCardIds = Set.unmodifiable(attacksWithCardIds),
       statusStackMultipliers = Map.unmodifiable(statusStackMultipliers),
       onHit = List.unmodifiable(onHit),
       attackModifiers = List.unmodifiable(attackModifiers),
       effects = List.unmodifiable(effects),
       tags = Set.unmodifiable(tags);
  final String id;
  final String? mirrorCardId;
  final CardResponse? response;
  final List<EffectDefinition> onHit;
  final int mpCost;
  final int actionCostBonus;
  final List<AttackModifier> attackModifiers;
  final bool attacks;

  /// Wiki green-card classification; separate from attack participation.
  final bool isLimited;
  final Set<String> attacksWithCardIds;
  final Map<String, int> statusStackMultipliers;
  final List<EffectDefinition> effects;
  final Set<String> tags;
  final int attackBonus;
  final int defenseBonus;
  final double attackMultiplier;
  final double defenseMultiplier;
  final int finalDamageBonus;
  final double finalDamageMultiplier;
  final int? diceSides;
  final int? reinforcedDiceSides;
  final int diceBonus;
  final bool ignoreDefense;
  final bool ignoreDodge;
  final bool clearDodge;
  final bool clearShield;
  final DamageKind damageKind;
  final bool piercesContinuation;
}

final class SkillCopyPolicy {
  const SkillCopyPolicy({this.allowExclusive = true, this.allowRepeat = false});
  final bool allowExclusive, allowRepeat;
}

final class ReplayPolicy {
  const ReplayPolicy({this.damageFactor = .5, this.healingFactor = .25});
  final double damageFactor, healingFactor;
}

enum SkillMechanism { ordinary, copyPublicSkill, replayRecord }

enum SkillCheckpoint {
  damageDealt,
  damageReceived,
  beforeDeath,
  afterAttack,
  otherDamageThreshold,
}

/// Conditions and mutations at a settlement boundary. Other-damage thresholds
/// observe committed global-round totals; damage guards run before HP commit.
final class CheckpointRule {
  CheckpointRule({
    required this.at,
    this.minimumDamage = 0,
    this.maximumTargetHp = 300,
    this.extraTurns = 1,
    this.attackOnly = false,
    this.damageFactor = 1,
    this.restoreHp,
    this.shield = 0,
    this.shieldRounds = 0,
    this.shieldClock = DurationClock.globalRound,
    List<DamageKind> kinds = const [
      DamageKind.physical,
      DamageKind.magical,
      DamageKind.real,
    ],
  }) : kinds = List.unmodifiable(kinds);
  final SkillCheckpoint at;
  final int minimumDamage;
  final int maximumTargetHp, extraTurns;
  final bool attackOnly;
  final double damageFactor;
  final int? restoreHp;
  final int shield;
  final int shieldRounds;
  final DurationClock shieldClock;
  final List<DamageKind> kinds;
}

final class NumberParameter {
  const NumberParameter({
    this.minimum = 1,
    this.maximum = 10000,
    this.lifeCostPerUnit = 0,
    this.mpCostPerUnit = 0,
    this.maximumValue,
    this.countTargets = false,
    this.allowedValues = const [],
    this.markCostId,
  });
  final int minimum;
  final int maximum;
  final int lifeCostPerUnit;
  final int mpCostPerUnit;
  final EffectValue? maximumValue;
  final bool countTargets;
  final List<int> allowedValues;
  final String? markCostId;
}

/// Consumed at the next attack roll, never by a utility-card action.
enum AttackCopyBasis { actualDamage, actualHpLost }

final class ArmAttack extends EffectDefinition {
  const ArmAttack({
    this.damageMultiplier = 1,
    this.fixedMaximum = false,
    this.onHit = const [],
    this.after = const [],
    this.rotationBonus = const {},
    this.rotationTake = 2,
    this.diceCount = 1,
    this.copyDamage = false,
    this.copyDamageBasis = AttackCopyBasis.actualDamage,
    this.reciprocalDice = false,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final double damageMultiplier;
  final bool fixedMaximum;
  final List<EffectDefinition> onHit;
  final List<EffectDefinition> after;
  final Map<int, List<EffectDefinition>> rotationBonus;
  final int rotationTake;
  final int diceCount;
  final bool copyDamage;
  final AttackCopyBasis copyDamageBasis;
  final bool reciprocalDice;
}

final class CooldownBranch {
  const CooldownBranch(this.when, this.cooldown);
  final ConditionDefinition when;
  final int cooldown;
}

final class SkillDefinition {
  SkillDefinition({
    required this.id,
    this.copyPolicy = const SkillCopyPolicy(),
    this.replayPolicy = const ReplayPolicy(),
    this.cooldown = 0,
    this.cooldownValue,
    this.cooldownBranches = const [],
    this.anytime = false,
    this.preselectAll = false,
    this.beforeAttack = false,
    this.beforeCards = false,
    this.excludeSelfTarget = false,
    this.lifeCost = 0,
    this.lifeCostValue,
    this.checkpoint,
    this.numberParameter,
    this.mpCost = 0,
    this.mpSurcharge = 0,
    this.when,
    this.targetWhen,
    Map<Stat, int> statCosts = const {},
    this.exclusive = false,
    this.passive = false,
    List<TriggerDefinition> triggers = const [],
    List<CounterDefinition> counters = const [],
    this.mechanism = SkillMechanism.ordinary,
    this.timing = SkillTiming.main,
    this.minTargets = 0,
    this.maxTargets = 1,
    List<EffectDefinition> effects = const [],
    List<MarkCost> markCosts = const [],
  }) : triggers = List.unmodifiable(triggers),
       counters = List.unmodifiable(counters),
       markCosts = List.unmodifiable(markCosts),
       statCosts = Map.unmodifiable(statCosts),
       effects = List.unmodifiable(effects);
  final List<MarkCost> markCosts;
  final String id;
  final SkillCopyPolicy copyPolicy;
  final ReplayPolicy replayPolicy;
  final int cooldown;
  final EffectValue? cooldownValue;
  final List<CooldownBranch> cooldownBranches;
  final int mpCost;
  final int mpSurcharge;
  final bool anytime;
  final bool preselectAll;
  final bool beforeAttack;
  final bool beforeCards;
  final bool excludeSelfTarget;
  final int lifeCost;
  final EffectValue? lifeCostValue;
  final CheckpointRule? checkpoint;
  final NumberParameter? numberParameter;
  final ConditionDefinition? when;
  final ConditionDefinition? targetWhen;
  final Map<Stat, int> statCosts;
  final bool exclusive;
  final bool passive;
  final List<TriggerDefinition> triggers;
  final List<CounterDefinition> counters;
  final SkillMechanism mechanism;
  final SkillTiming timing;
  final int minTargets;
  final int maxTargets;
  final List<EffectDefinition> effects;
}

enum MarkVisibility { public, owner }

/// Data only: no triggers, modifiers, automatic decay or status immunity.
final class MarkDefinition {
  const MarkDefinition({
    required this.id,
    this.maxCount,
    this.playerCountBonus,
    this.sourceScoped = true,
    this.visibility = MarkVisibility.public,
    this.group,
    this.groupLimit,
  });
  final String id;
  final int? maxCount;
  final int? playerCountBonus;
  final bool sourceScoped;
  final MarkVisibility visibility;
  final String? group;
  final int? groupLimit;
}

final class ModifyMark extends EffectDefinition {
  ModifyMark(
    this.markId, {
    this.amount = 1,
    this.value,
    this.set = false,
    Map<String, String> references = const {},
    EffectTarget target = EffectTarget.self,
  }) : references = Map.unmodifiable(references),
       super(target);
  final String markId;
  final int amount;
  final EffectValue? value;
  final bool set;
  final Map<String, String> references;
}

final class MarkCost {
  const MarkCost(this.markId, this.amount);
  final String markId;
  final int amount;
}

final class ImpactEffect extends EffectDefinition {
  const ImpactEffect({EffectTarget target = EffectTarget.selected})
    : super(target);
}

final class DamageGuard {
  DamageGuard({
    this.when,
    this.traitBlockExceptions = const [],
    List<DamageKind> kinds = const [DamageKind.physical, DamageKind.magical],
    this.flatPerIntensity = 0,
    this.rollSides,
    this.oncePerAttack = false,
    this.effectsOncePerAttack = false,
    this.groupAttackOnly = false,
    List<int> success = const [],
    this.factor = 1,
    this.consumeStacks = 0,
    this.perDamageInstance = false,
    this.once = false,
    List<EffectDefinition> effects = const [],
  }) : success = List.unmodifiable(success),
       kinds = List.unmodifiable(kinds),
       effects = List.unmodifiable(effects);
  final ConditionDefinition? when;
  final List<String> traitBlockExceptions;
  final int? rollSides;
  final bool oncePerAttack;
  final bool effectsOncePerAttack;
  final bool groupAttackOnly;
  final List<int> success;
  final List<DamageKind> kinds;
  final int flatPerIntensity;
  final double factor;
  final int consumeStacks;

  /// Consume independently for each damage component instead of sharing a layer
  /// within an attack packet. Other guards keep their original packet policy.
  final bool perDamageInstance;
  final bool once;
  final List<EffectDefinition> effects;
}

final class StatusAction {
  StatusAction({
    this.lifeCostPerIntensity = 0,
    this.removeSelf = true,
    List<EffectDefinition> effects = const [],
  }) : effects = List.unmodifiable(effects);
  final int lifeCostPerIntensity;
  final bool removeSelf;
  final List<EffectDefinition> effects;
}

final class StatusDefinition {
  StatusDefinition({
    required this.id,
    this.neutral = false,
    this.isStatusEffect = true,
    this.exclusiveGroup,
    this.expireOnAction = false,
    this.category = StatusCategory.normal,
    this.hasIntensity = true,
    this.swapBaseAttackDefense = false,
    this.blockNegative = false,
    this.consumeOnNegative = false,
    this.cleanseNegativeOnApply = false,
    this.redirectAllies = false,
    this.attackDicePerIntensity = 0,
    this.attackFlatPerIntensity = 0,
    this.incomingDefenseBonusPerIntensity = 0,
    this.outgoingPhysicalFlatPerIntensity = 0,
    this.mpRecoveryFlatPerIntensity = 0,
    this.actionMpDiscount = 0,
    this.skillMpSurcharge = 0,
    this.traitMpSurcharge = 0,
    this.maxHandCap,
    this.cardMpCap,
    this.attackDiceSides,
    this.consumeOnAttackRoll = false,
    this.reinforceFirstCard = false,
    this.active,
    List<DamageGuard> damageGuards = const [],
    List<CounterDefinition> counters = const [],
    List<TriggerDefinition> triggers = const [],
    List<EffectDefinition> onHit = const [],
    this.decay = StatusDecay.anchoredRound,
    this.settleAtAnchor = false,
    this.followApplicationPhase = false,
    this.maxStacks,
    this.maxIntensity,
    this.opposingStatusId,
    this.negative = false,
    this.blockDrawPhase = false,
    this.blockAttackCards = false,
    this.blockStatus = false,
    this.ignoreShield = false,
    this.shieldOverflowBarrier = false,
    this.attackFactor = 1,
    this.healingBonusPerIntensity = 0,
    this.incomingDamageBonusPerIntensity = 0,
    this.incomingAttackBonusPerIntensity = 0,
    this.outgoingAttackBonusPerIntensity = 0,
    this.mpRegenPerIntensity = 0,
    this.addIntensity = false,
    this.dodge = false,
    this.actionFailureSides,
    this.invulnerable = false,
    this.battleContinuation = false,
    this.blockAttack = false,
    this.blockCards = false,
    this.blockSkills = false,
    this.blockTraits = false,
    this.blockDraw = false,
    this.blockMpRegen = false,
    this.skipTurn = false,
    Map<Stat, int> modifiersPerIntensity = const {},
    List<EffectDefinition> turnStart = const [],
    List<EffectDefinition> turnEnd = const [],
  }) : damageGuards = List.unmodifiable(damageGuards),
       counters = List.unmodifiable(counters),
       triggers = List.unmodifiable(triggers),
       onHit = List.unmodifiable(onHit),
       modifiersPerIntensity = Map.unmodifiable(modifiersPerIntensity),
       turnStart = List.unmodifiable(turnStart),
       turnEnd = List.unmodifiable(turnEnd);

  /// False for ability bookkeeping and temporary buffs, even when they share
  /// the status runtime for duration, formulas and attack consumption.
  final bool isStatusEffect;
  final bool neutral;
  final bool swapBaseAttackDefense;
  final bool blockNegative;
  final bool consumeOnNegative;
  final bool cleanseNegativeOnApply;
  final bool redirectAllies;
  final int attackDicePerIntensity;
  final int attackFlatPerIntensity;

  /// Formula defense bonus for the receiving attack, never a persistent stat.
  final int incomingDefenseBonusPerIntensity;
  final int outgoingPhysicalFlatPerIntensity;
  final int mpRecoveryFlatPerIntensity;
  final int actionMpDiscount;
  final int skillMpSurcharge;
  final int traitMpSurcharge;
  final int? maxHandCap;
  final int? cardMpCap;
  final int? attackDiceSides;
  final bool consumeOnAttackRoll;
  final bool reinforceFirstCard;
  final StatusAction? active;
  final List<DamageGuard> damageGuards;
  final List<CounterDefinition> counters;
  final List<TriggerDefinition> triggers;
  final StatusCategory category;
  final bool hasIntensity;
  final String id;
  final String? exclusiveGroup;
  final bool expireOnAction;
  final List<EffectDefinition> onHit;
  final StatusDecay decay;

  /// Settle at the attachment seat before decay instead of at the owner's turn.
  final bool settleAtAnchor;

  /// Internal buffs can opt into the same end-phase timing as formal states.
  final bool followApplicationPhase;
  final int? maxStacks;
  final int? maxIntensity;
  final String? opposingStatusId;
  final bool negative;
  final bool blockDrawPhase;
  final bool blockAttackCards;
  final bool blockStatus;
  final bool ignoreShield;
  final bool shieldOverflowBarrier;
  final double attackFactor;
  final double healingBonusPerIntensity;
  final double incomingDamageBonusPerIntensity;
  final double incomingAttackBonusPerIntensity;
  final double outgoingAttackBonusPerIntensity;
  final int mpRegenPerIntensity;
  final bool addIntensity;
  final bool dodge;
  final int? actionFailureSides;
  final bool invulnerable;
  final bool battleContinuation;
  final bool blockAttack;
  final bool blockCards;
  final bool blockSkills;
  final bool blockTraits;
  final bool blockDraw;
  final bool blockMpRegen;
  final bool skipTurn;
  final Map<Stat, int> modifiersPerIntensity;
  final List<EffectDefinition> turnStart;
  final List<EffectDefinition> turnEnd;
}

final class ContentCatalog {
  ContentCatalog({
    required this.version,
    Iterable<TemplateDefinition> templates = const [],
    Iterable<RaceDefinition> races = const [],
    Iterable<CharacterDefinition> characters = const [],
    Iterable<TraitDefinition> traits = const [],
    Iterable<CardDefinition> cards = const [],
    Iterable<SkillDefinition> skills = const [],
    Iterable<StatusDefinition> statuses = const [],
    Iterable<MarkDefinition> marks = const [],
    Iterable<VariableDefinition> variables = const [],
  }) : variables = _variableDefinitions(variables),
       marks = Map.unmodifiable({for (final d in marks) d.id: d}),
       templates = Map.unmodifiable({for (final d in templates) d.id: d}),
       races = Map.unmodifiable({for (final d in races) d.id: d}),
       characters = Map.unmodifiable({for (final d in characters) d.id: d}),
       traits = Map.unmodifiable({for (final d in traits) d.id: d}),
       cards = Map.unmodifiable({for (final d in cards) d.id: d}),
       skills = Map.unmodifiable({for (final d in skills) d.id: d}),
       statuses = Map.unmodifiable({for (final d in statuses) d.id: d});
  final String version;
  final Map<String, TemplateDefinition> templates;
  final Map<String, RaceDefinition> races;
  final Map<String, CharacterDefinition> characters;
  final Map<String, TraitDefinition> traits;
  final Map<String, CardDefinition> cards;
  final Map<String, SkillDefinition> skills;
  final Map<String, StatusDefinition> statuses;
  final Map<String, MarkDefinition> marks;
  final Map<String, VariableDefinition> variables;
}

Map<String, VariableDefinition> _variableDefinitions(
  Iterable<VariableDefinition> definitions,
) {
  final result = <String, VariableDefinition>{};
  for (final definition in definitions) {
    if (result.containsKey(definition.id)) {
      throw StateError('Duplicate variable: ${definition.id}');
    }
    result[definition.id] = definition;
  }
  return Map.unmodifiable(result);
}

final class GameRules {
  const GameRules({
    this.useLegacyDamageFormula = false,
    this.actionsPerTurn = 1,
    this.enforceSkillUniqueness = true,
    this.anomalyConflict = AnomalyConflict.reject,
    this.requireAllResponses = true,
    this.responseTimeoutSeconds = 30,
    this.openingCards = 2,
    this.openingSkills = 2,
    this.cardsPerTurn = 2,
    this.maxHand = 6,
    this.normalAttackCost = 1,
    this.defaultDiceSides = 4,
    this.revealRound = 6,
    this.duelEnabled = false,
    this.duelRound = 12,
    this.duelAttackBonus = 0,
    this.duelHealingMultiplier = 1,
    this.duelDamageMultiplier = 1.5,
    this.shuffleDeck = true,
    this.shuffleSkillPool = true,
    this.emptyDeckPolicy = EmptyDeckPolicy.stopDrawing,
  });
  final bool useLegacyDamageFormula;
  final int actionsPerTurn;
  final bool enforceSkillUniqueness;
  final AnomalyConflict anomalyConflict;
  final bool requireAllResponses;
  final int responseTimeoutSeconds;
  final int openingCards;
  final int openingSkills;
  final int cardsPerTurn;
  final int maxHand;
  final int normalAttackCost;
  final int defaultDiceSides;
  final int revealRound;
  final bool duelEnabled;
  final int duelRound;
  final int duelAttackBonus;
  final double duelHealingMultiplier;
  final double duelDamageMultiplier;
  final bool shuffleDeck;
  final bool shuffleSkillPool;
  final EmptyDeckPolicy emptyDeckPolicy;

  GameRules withLegacyDamageFormula({
    required bool enabled,
    int? responseTimeoutSeconds,
    bool? duelEnabled,
    int? duelRound,
    int? duelAttackBonus,
    double? duelHealingMultiplier,
    double? duelDamageMultiplier,
  }) => GameRules(
    useLegacyDamageFormula: enabled,
    actionsPerTurn: actionsPerTurn,
    enforceSkillUniqueness: enforceSkillUniqueness,
    anomalyConflict: anomalyConflict,
    requireAllResponses: requireAllResponses,
    responseTimeoutSeconds:
        responseTimeoutSeconds ?? this.responseTimeoutSeconds,
    openingCards: openingCards,
    openingSkills: openingSkills,
    cardsPerTurn: cardsPerTurn,
    maxHand: maxHand,
    normalAttackCost: normalAttackCost,
    defaultDiceSides: defaultDiceSides,
    revealRound: revealRound,
    duelEnabled: duelEnabled ?? this.duelEnabled,
    duelRound: duelRound ?? this.duelRound,
    duelAttackBonus: duelAttackBonus ?? this.duelAttackBonus,
    duelHealingMultiplier: duelHealingMultiplier ?? this.duelHealingMultiplier,
    duelDamageMultiplier: duelDamageMultiplier ?? this.duelDamageMultiplier,
    shuffleDeck: shuffleDeck,
    shuffleSkillPool: shuffleSkillPool,
    emptyDeckPolicy: emptyDeckPolicy,
  );
}

final class PlayerSetup {
  const PlayerSetup({
    required this.id,
    required this.characterId,
    required this.teamId,
  });
  final String id;
  final String characterId;
  final String teamId;
}

final class GameSetup {
  GameSetup({
    required this.gameId,
    required List<PlayerSetup> players,
    required List<String> deck,
    required List<String> skillPool,
    this.rules = const GameRules(),
    this.seed = 1,
  }) : players = List.unmodifiable(players),
       deck = List.unmodifiable(deck),
       skillPool = List.unmodifiable(skillPool);
  final String gameId;
  final List<PlayerSetup> players;
  final List<String> deck;
  final List<String> skillPool;
  final GameRules rules;
  final int seed;
}

/// Generic action-stage trait option. IDs identify options, never character code.
final class TraitAction {
  const TraitAction({
    this.anytime = false,
    this.options = const {},
    this.markCosts = const [],
    this.mpCost = 0,
    this.requireFullMp = false,
    this.discardCount = 0,
    this.maxUsesPerRound,
    this.limitWindow = CounterReset.round,
    this.extraActions = 0,
    this.attackBonus = 0,
    this.markLayers,
    this.markIntensity,
    this.layersPerMark = 1,
    this.intensityPerMark = 2,
    this.fallbackLayersPerMark = 1,
    this.effects = const [],
  });
  final bool anytime;
  final int mpCost;
  final Map<String, TraitAction> options;
  final List<MarkCost> markCosts;
  final bool requireFullMp;
  final int discardCount;
  final int extraActions;
  final int attackBonus;
  final int? maxUsesPerRound;
  final CounterReset limitWindow;
  final List<EffectDefinition> effects;
  final String? markLayers;
  final String? markIntensity;
  final int layersPerMark, intensityPerMark, fallbackLayersPerMark;
}

final class AttackStatusRule {
  const AttackStatusRule({
    required this.statusId,
    this.stacks = 1,
    this.intensity = 1,
    this.tags = const [],
    this.tagStacks = 0,
    this.tagIntensity = 0,
  });
  final String statusId;
  final int stacks;
  final int intensity;
  final int tagStacks;
  final int tagIntensity;
  final List<String> tags;
}

final class GrantExtraTurns extends EffectDefinition {
  const GrantExtraTurns(this.count, {EffectTarget target = EffectTarget.self})
    : super(target);
  final int count;
}

final class HealToFraction extends EffectDefinition {
  const HealToFraction(this.fraction, {EffectTarget target = EffectTarget.self})
    : super(target);
  final double fraction;
}

final class ModifyAppliedStatus extends EffectDefinition {
  const ModifyAppliedStatus(
    this.statusId, {
    this.stacks = 0,
    this.intensity = 0,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final String statusId;
  final int stacks;
  final int intensity;
}

enum ValueOperation {
  add,
  subtract,
  multiply,
  divide,
  modulo,
  min,
  max,
  floor,
  ceil,
}

enum ChoiceChooser { actor, target }

final class StatusQuery {
  const StatusQuery({
    this.statusId,
    this.negative,
    this.hasIntensity,
    this.statusIds = const [],
    this.excludeStatusIds = const [],
    this.decayingOnly = false,
    this.extendableOnly = false,
    this.instanceId,
    this.includeAnomalies = false,
    this.minimumIntensity,
    this.minimumIntensityValue,
    this.minimumStacks,
    this.maximumStacks,
    this.maximumIntensity,
    this.source,
    this.selection,
    this.latest = false,
    this.chosen = false,
  });
  final String? statusId;
  final bool? negative;
  final bool? hasIntensity;
  final List<String> statusIds;
  final List<String> excludeStatusIds;
  final bool decayingOnly;
  final bool extendableOnly;
  final String? instanceId;
  final bool includeAnomalies;
  final int? minimumIntensity;
  final EffectValue? minimumIntensityValue;
  final EffectValue? minimumStacks;
  final EffectValue? maximumStacks;
  final EffectValue? maximumIntensity;
  final String? source;
  final String? selection;
  final bool latest;
  final bool chosen;
}

enum StatusEditMode { add, set, remove }

final class EditStatus extends EffectDefinition {
  const EditStatus({
    this.query = const StatusQuery(),
    this.mode = StatusEditMode.add,
    this.stacks,
    this.intensity,
    this.createIfMissing = false,
    this.initialStacks,
    this.initialIntensity,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final StatusQuery query;
  final StatusEditMode mode;
  final EffectValue? stacks;
  final EffectValue? intensity;
  final bool createIfMissing;
  final EffectValue? initialStacks;
  final EffectValue? initialIntensity;
}

final class TransferStatus extends EffectDefinition {
  const TransferStatus({
    this.query = const StatusQuery(),
    this.to = EffectTarget.self,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final StatusQuery query;
  final EffectTarget to;
}

/// Roll-time permanent growth is excluded from the attack that grants it.
final class AttackDiceGrowth {
  const AttackDiceGrowth({required this.variable, required this.threshold});
  final String variable;
  final int threshold;
}

final class ConvertStatus extends EffectDefinition {
  const ConvertStatus({
    this.fromStatusId,
    required this.toStatusId,
    required this.count,
    this.intensity = 1,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final String? fromStatusId;
  final String toStatusId;
  final EffectValue count;
  final int intensity;
}

/// Choose one executable tag, then prohibit it until the configured deadline.
final class RestrictCardTag extends EffectDefinition {
  const RestrictCardTag({
    this.rounds = 1,
    this.clock = DurationClock.globalRound,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final int rounds;
  final DurationClock clock;
}

/// Blind, sequential selection of exact hand instances without moving them.
final class DisableHandCards extends EffectDefinition {
  const DisableHandCards({
    this.count = 2,
    this.rounds = 1,
    this.otherwise = const [],
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final int count;
  final int rounds;
  final List<EffectDefinition> otherwise;
}

/// Direct life restoration is not healing and cannot revive a dead character.
final class RestoreLife extends EffectDefinition {
  const RestoreLife(
    this.amount, {
    this.value,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int amount;
  final EffectValue? value;
}

/// Set an alive character's HP exactly, bounded by maximum HP.
final class SetLife extends EffectDefinition {
  const SetLife(
    this.amount, {
    this.value,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final int amount;
  final EffectValue? value;
}

/// Generic entry points for stateful mechanisms; scheduling belongs to content.
final class ConvertShieldToLife extends EffectDefinition {
  const ConvertShieldToLife({
    this.factor = 1,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final double factor;
}

final class GenerateRandomAction extends EffectDefinition {
  const GenerateRandomAction() : super(EffectTarget.self);
}

final class BorrowSkillEffect extends EffectDefinition {
  const BorrowSkillEffect({this.rule = const SkillBorrowRule()})
    : super(EffectTarget.self);
  final SkillBorrowRule rule;
}

final class CaptureSave extends EffectDefinition {
  const CaptureSave() : super(EffectTarget.self);
}

final class CheckContinuation extends EffectDefinition {
  CheckContinuation({
    required this.sides,
    required List<int> success,
    this.restoreHp = 1,
  }) : success = List.unmodifiable(success),
       super(EffectTarget.self);
  final int sides, restoreHp;
  final List<int> success;
}
