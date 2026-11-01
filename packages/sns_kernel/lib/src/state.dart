import 'package:sns_kernel/src/commands.dart';
import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/dice.dart';

enum GamePhase { created, opening, start, draw, action, discard, end, finished }

enum PendingKind { attack, skill, cards, dice }

final class CardInstance {
  CardInstance(this.instanceId, this.definition);
  final String instanceId;
  final CardDefinition definition;
  bool disabled = false;
  int? disabledUntilRound;
  AnchorExpiry? disabledUntilAnchor;
  bool reinforced = false;
}

/// A deadline measured in visits to one natural seat, excluding extra actions.
final class AnchorExpiry {
  const AnchorExpiry({
    required this.playerId,
    required this.turn,
    this.atEnd = false,
  });
  factory AnchorExpiry.fromJson(Map<String, dynamic> json) => AnchorExpiry(
    playerId: json['anchorPlayerId'] as String,
    turn: json['turn'] as int,
    atEnd: json['phase'] == 'turnEnd',
  );
  final String playerId;
  final int turn;
  final bool atEnd;
  Map<String, Object?> toJson() => {
    'anchorPlayerId': playerId,
    'turn': turn,
    'phase': atEnd ? 'turnEnd' : 'turnStart',
  };
}

final class TemporaryShield {
  TemporaryShield({
    required this.remaining,
    required this.expires,
    this.anchor,
  });
  int remaining;
  final int expires;
  AnchorExpiry? anchor;
}

/// A temporary physical location. Holding a card is not itself a played-card
/// or cards-lost event; the calling mechanism decides when to emit those facts.
final class HeldCard {
  HeldCard._(
    this.id,
    this.actionId,
    this.card,
    this.owner,
    this.originalIndex,
    this.revealed,
  );
  final String id;
  final String actionId;
  final CardInstance card;
  final CharacterInstance owner;
  final int originalIndex;
  final bool revealed;
}

final class CardCustodyZone {
  final Map<String, HeldCard> _entries = {};
  List<HeldCard> get entries => List.unmodifiable(_entries.values);

  HeldCard hold({
    required String id,
    required String actionId,
    required CharacterInstance owner,
    required CardInstance card,
    bool revealed = false,
  }) {
    final index = owner.hand.indexOf(card);
    if (_entries.containsKey(id) ||
        index < 0 ||
        card.disabled ||
        _entries.values.any((e) => identical(e.card, card))) {
      throw StateError('Card cannot enter temporary custody');
    }
    final held = HeldCard._(id, actionId, card, owner, index, revealed);
    owner.hand.removeAt(index);
    _entries[id] = held;
    return held;
  }

  /// Transfers the exact instance to the calling mechanism, once only.
  CardInstance take(HeldCard held) {
    if (!identical(_entries[held.id], held)) {
      throw StateError('Card is no longer in temporary custody');
    }
    _entries.remove(held.id);
    return held.card;
  }

  void restore(HeldCard held, List<CardInstance> discardPile) {
    final card = take(held);
    if (!held.owner.alive) {
      discardPile.add(card);
      return;
    }
    held.owner.hand.insert(
      held.originalIndex.clamp(0, held.owner.hand.length),
      card,
    );
  }
}

final class SkillInstance {
  SkillInstance(this.instanceId, this.definition);
  final String instanceId;
  final SkillDefinition definition;
  bool leasedOut = false;
  bool borrowed = false;
  int cooldown = 0;
  AnchorExpiry? cooldownAnchor;
  bool revealed = false;
  int uses = 0;
  int? remainingUses;
  final TriggerMemory triggerMemory = TriggerMemory();
}

final class TraitInstance {
  TraitInstance(this.instanceId, this.definition);
  final String instanceId;
  final TraitDefinition definition;
  int activeRound = -1;
  int activeUses = 0;
  final TriggerMemory triggerMemory = TriggerMemory();
  Map<String, int> get counters => triggerMemory.counters;
}

final class StatusInstance {
  StatusInstance({
    required this.instanceId,
    required this.definition,
    required this.ownerId,
    required this.sourceId,
    required this.anchorPlayerId,
    required this.stacks,
    required this.intensity,
    this.damageLimit,
    this.decayAtAnchorEnd = false,
  });
  final String instanceId;
  final StatusDefinition definition;
  final TriggerMemory triggerMemory = TriggerMemory();
  Map<String, int> get counters => triggerMemory.counters;
  final Set<int> usedDamageGuards = {};
  String ownerId;
  String? sourceId;
  String anchorPlayerId;
  bool decayAtAnchorEnd;
  int stacks;
  int intensity;
  int? damageLimit;
  int damageTaken = 0;
}

final class StatusTransferPlan {
  const StatusTransferPlan(this.statusInstanceId, this.targetId);
  final String statusInstanceId;
  final String? targetId;
}

final class ArmedAttack {
  const ArmedAttack(this.rule, this.targetId);
  final ArmAttack rule;
  final String? targetId;
}

final class CharacterInstance {
  final Map<String, int> restrictedCardTags = {};
  final Map<String, List<AnchorExpiry>> anchoredCardTags = {};
  CharacterInstance({
    required this.instanceId,
    required this.definition,
    required this.template,
    required this.race,
    required this.maxHand,
    required this.traits,
    required this.skills,
  }) : _hp = template.hp,
       mp = race.initialMp;
  final String instanceId;
  final CharacterDefinition definition;
  final TemplateDefinition template;
  final RaceDefinition race;
  int _hp;
  int get hp => _hp;
  bool get lifeLocked => alive && _hp <= 0 && continuesBattle;
  set hp(int value) {
    if (lifeLocked) return;
    _hp = value;
    if (alive && value <= 0 && continuesBattle) continuationEntered = true;
  }

  /// Only an explicitly bypassing damage or recovery mechanism may use this.
  void setLifeIgnoringContinuation(int value) => _hp = value;
  int battleRound = 1;
  bool continuationEntered = false;
  int mp;
  int shield = 0;
  final List<TemporaryShield> temporaryShields = [];
  String? nextAttackTargetId;
  final List<ArmedAttack> armedAttacks = [];
  final List<CardInstance> preparedCards = [];
  final Map<String, int> reciprocalDice = {};
  final List<String?> extraTurnTargets = [];
  String? extraTurnAttackTarget;
  int maxHand;
  int actionsRemaining = 0;
  int normalTurnsEnded = 0;
  int regenProgress = 0;
  bool refillAfterExhaustionPending = false;
  int extraTurns = 0;
  final List<int> bonusActions = [];
  TraitAction? armedMarkAction;
  int turnsStarted = 0;
  int turnsClosed = 0;
  StatusTransferPlan? armedStatusTransfer;
  bool alive = true;
  final TriggerMemory raceTriggerMemory = TriggerMemory();
  final List<TraitInstance> traits;
  final List<SkillInstance> skills;
  final List<CardInstance> hand = [];
  final List<StatusInstance> statuses = [];
  final List<MarkInstance> marks = [];
  final Map<Stat, int> permanentModifiers = {};
  int damageThisTurn = 0;
  int damageThisRound = 0;
  int damageTotal = 0;
  int receivedDamageThisGlobalRound = 0;
  int receivedHpLostThisGlobalRound = 0;
  int transferredHpLostThisGlobalRound = 0;
  int transferredDamageThisGlobalRound = 0;
  int dealtDamageThisGlobalRound = 0;
  int healedThisGlobalRound = 0;
  int healedPreviousGlobalRound = 0;

  int get cardLifeCost =>
      traits.fold(0, (n, t) => n + t.definition.resourceAbilities.cardLifeCost);
  int get idleDrawCount => traits.fold(
    0,
    (n, t) => n + t.definition.resourceAbilities.idleDrawCount,
  );
  int get idleTakeCount => traits
      .where((t) => t.definition.resourceAbilities.idleDrawCount > 0)
      .fold(0, (n, t) => n + t.definition.resourceAbilities.idleTakeCount);
  double get defenseLossPerDamage =>
      traits
          .where(
            (t) => t.definition.resourcePolicy == ResourcePolicy.defenseLife,
          )
          .map((t) => t.definition.resourceAbilities.defenseLossPerDamage)
          .firstOrNull ??
      .02;
  bool get hasDamageHealing => traits.any(
    (t) => t.definition.resourceAbilities.damageHealing.isNotEmpty,
  );

  bool get noMp => traits.any(
    (t) => t.definition.resourcePolicy == ResourcePolicy.healthActions,
  );
  bool get defenseLife => traits.any(
    (t) => t.definition.resourcePolicy == ResourcePolicy.defenseLife,
  );
  bool get depleted => defenseLife ? value(Stat.defense) <= 0 : hp <= 0;
  final List<({int amount, int expires})> temporaryDefense = [];

  int value(Stat stat) {
    if ((stat == Stat.maxHp && defenseLife) || (stat == Stat.maxMp && noMp)) {
      return 0;
    }
    final mirrored = statuses.any((s) => s.definition.swapBaseAttackDefense);
    final base = switch (stat) {
      Stat.attack => mirrored ? template.defense : template.attack,
      Stat.defense => mirrored ? template.attack : template.defense,
      Stat.maxHp => template.hp,
      Stat.maxMp => race.maxMp,
      Stat.maxHand => maxHand,
    };
    var result = base + (permanentModifiers[stat] ?? 0);
    for (final trait in traits) {
      result += trait.definition.modifiers[stat] ?? 0;
      if (!statuses.any((s) => s.definition.blockTraits)) {
        for (final bonus in trait.definition.markStatBonuses) {
          final count = marks
              .where(
                (m) =>
                    m.definition.id == bonus.markId &&
                    (!bonus.fromSelf ||
                        !m.definition.sourceScoped ||
                        m.sourceId == instanceId),
              )
              .fold<int>(0, (n, m) => n + m.count);
          result += (bonus.modifiersPerCount[stat] ?? 0) * count;
        }
        for (final bonus in trait.definition.statusStatBonuses) {
          if (bonus.allStatuses.every(
            (id) => statuses.any((s) => s.definition.id == id),
          )) {
            result += bonus.modifiers[stat] ?? 0;
          }
        }
      }
    }
    for (final status in statuses) {
      result +=
          (status.definition.modifiersPerIntensity[stat] ?? 0) *
          status.intensity;
    }
    if (stat == Stat.defense) {
      for (final bonus in temporaryDefense) {
        result += bonus.amount;
      }
    }
    if (stat == Stat.attack) {
      for (final status in statuses) {
        result = (result * status.definition.attackFactor).floor();
      }
    }
    if (stat == Stat.maxHand) {
      for (final status in statuses) {
        final cap = status.definition.maxHandCap;
        if (cap != null && result > cap) result = cap;
      }
    }
    return result < 0 ? 0 : result;
  }

  bool get continuesBattle =>
      traits.any(
        (t) =>
            t.definition.battleContinuation &&
            (t.definition.battleContinuationThroughRound == null ||
                battleRound <= t.definition.battleContinuationThroughRound!),
      ) ||
      statuses.any((s) => s.definition.battleContinuation);
}

final class PlayerInstance {
  PlayerInstance(this.id, this.teamId, this.character);
  final String id;
  final String teamId;
  final CharacterInstance character;
}

final class PendingResolution {
  PendingResolution({
    required this.id,
    required this.kind,
    required this.actorId,
    required List<String> targets,
    this.skill,
    this.replayRecord,
    this.reverseReplay = false,
    this.suppressedEffects = false,
    this.constraintAction = false,
    this.conditionalBranches = const {},
    List<CardInstance> cards = const [],
    this.diceSides = 4,
    int diceResult = 1,
    this.diceRoll,
    this.diceCount = 1,
    this.deferredDiceBonus = 0,
    this.number,
    this.armedAttacks = const [],
    this.attackPowerBonus = 0,
    this.baseDiceSides = 4,
    this.forcedDiceSides,
  }) : targets = List.unmodifiable(targets),
       _diceResult = diceRoll?.finalTotal ?? diceResult,
       cards = List.unmodifiable(cards);
  final String id;
  final PendingKind kind;
  final bool constraintAction;
  final String actorId;
  List<String> targets;
  final SkillInstance? skill;
  final String? replayRecord;
  final bool reverseReplay;
  final bool suppressedEffects;
  final Map<(ConditionalEffect, String), bool> conditionalBranches;
  List<CardInstance> cards;
  int diceSides;
  final int baseDiceSides;
  final int? forcedDiceSides;
  String? responseWindowId;
  String get windowId => responseWindowId ?? id;
  bool rerolled = false;
  int _diceResult;
  RollResult? diceRoll;
  int get diceResult => diceRoll?.finalTotal ?? _diceResult;
  set diceResult(int value) {
    _diceResult = value;
    if (diceRoll != null && diceRoll!.finalTotal != value) {
      diceRoll = diceRoll!.modified(
        RollModification(DiceAdjustment.replace, value),
      );
    }
  }

  void setDiceRoll(RollResult value) {
    diceRoll = value;
    _diceResult = value.finalTotal;
    diceSides = value.spec.nominalSides;
  }

  final int diceCount;
  int deferredDiceBonus;
  final int? number;
  final List<ArmedAttack> armedAttacks;
  bool get diceLocked => armedAttacks.any((a) => a.rule.fixedMaximum);
  int get maximumDiceResult => diceSides * diceCount;
  final int attackPowerBonus;
  final List<String> responders = [];
  int openedVersion = 0;
  final Map<String, KernelCommand> submissions = {};
  final Map<String, String> responseSelections = {};
  bool responseExpired = false;
  bool cancelled = false;
  List<String> get waitingPlayerIds =>
      responders.where((id) => !submissions.containsKey(id)).toList();
  String? get waitingPlayerId => waitingPlayerIds.firstOrNull;
}

/// Facts contain IDs and values, never references to mutable game objects.
final class KernelEvent {
  KernelEvent(
    this.sequence,
    this.type,
    Map<String, Object?> data, {
    this.round = 0,
    this.turn = 0,
    this.phase,
    this.extraTurn = false,
  }) : data = Map.unmodifiable(data);
  final int sequence;
  final int round;
  final int turn;
  final String? phase;
  final bool extraTurn;
  final String type;
  final Map<String, Object?> data;
}

final class GameOutcome {
  const GameOutcome({
    this.winnerTeamId,
    this.winnerPlayerId,
    this.draw = false,
  });
  final String? winnerTeamId;
  final String? winnerPlayerId;
  final bool draw;
}

final class KernelState {
  final Map<String, RollResult> diceHistory = {};
  KernelState(
    this.gameId,
    this.contentVersion,
    this.players,
    this.drawPile,
    this.skillPool,
    this.randomState,
  );
  final String gameId;
  final String contentVersion;
  final List<PlayerInstance> players;
  final List<SummonedUnitInstance> summonedUnits = [];
  final List<CardInstance> drawPile;
  final List<CardInstance> discardPile = [];
  final CardCustodyZone cardCustody = CardCustodyZone();
  final List<SkillInstance> skillPool;
  final List<KernelEvent> events = [];
  final Map<String, SkillDefinition> publicSkillHistory = {};
  final Map<(String, String), VariableState> variables = {};
  GamePhase phase = GamePhase.created;
  int round = 0;
  int turn = 0;
  int actualTurn = 0;
  bool extraTurn = false;
  int activeIndex = 0;
  int version = 0;
  int randomState;
  int nextInstance = 0;
  bool duel = false;
  bool reversedOrder = false;
  bool reverseNextRound = false;
  int roundSeatPosition = 0;
  final List<ScheduledEffect> scheduledEffects = [];
  final List<ArmedTrigger> armedTriggers = [];
  final Map<String, List<Map<String, Object?>>> revealedHands = {};
  final Map<String, String> revealedCards = {};
  int blockStatusUntilRound = 0;
  final Map<String, int> statusApplicationBlocks = {};
  PendingChoice? choice;
  PendingPreparation? preparation;
  PendingResolution? pending;
  GameOutcome? outcome;
  PlayerInstance get activePlayer => players[activeIndex];
  bool get finished => outcome != null;
  String id(String kind) => '$gameId/$kind/${++nextInstance}';
}

/// Values are immutable snapshots; all writes go through variable operators.
final class VariableState {
  VariableState(this.value, this.window);
  Object value;
  int window;
}

/// Private, per-instance execution state; never shared by content definitions.
final class TriggerMemory {
  final Map<String, int> counters = {};
  final Map<String, int> counterWindows = {};
  final Map<int, int> uses = {};
  final Map<int, int> useWindows = {};
  final Map<String, int> groupUses = {};
  final Map<String, int> groupWindows = {};
  final Set<String> packetUses = {};
}

final class ScheduledEffect {
  ScheduledEffect({
    required this.id,
    required this.sourceId,
    required this.anchorId,
    required this.phase,
    required this.due,
    required this.effects,
    required this.multiplier,
    Map<(EffectValue, String), double> capturedValues = const {},
  }) : capturedValues = Map.unmodifiable(capturedValues);
  final Map<(EffectValue, String), double> capturedValues;
  final String id;
  final String sourceId;
  final String anchorId;
  final SchedulePhase phase;
  final int due;
  final int multiplier;
  final List<EffectDefinition> effects;
}

final class PendingChoice {
  PendingChoice({
    required this.id,
    required this.playerId,
    required this.kind,
    required List<Map<String, Object?>> options,
    this.details = const {},
  }) : options = List.unmodifiable(
         options.map(Map<String, Object?>.unmodifiable),
       );
  final String id;
  final String playerId;
  final ChoiceKind kind;
  final List<Map<String, Object?>> options;
  final Map<String, Object?> details;
}

final class ArmedTrigger {
  ArmedTrigger(this.id, this.ownerId, this.triggers, this.multiplier);
  final String id;
  final String ownerId;
  final List<TriggerDefinition> triggers;
  final int multiplier;
  final TriggerMemory memory = TriggerMemory();
}

final class MarkInstance {
  MarkInstance({
    required this.instanceId,
    required this.definition,
    required this.ownerId,
    required this.sourceId,
    required this.count,
    Map<String, String> references = const {},
  }) : references = Map.of(references);
  final String instanceId;
  final MarkDefinition definition;
  final String ownerId;
  final String? sourceId;
  int count;
  final Map<String, String> references;
}

final class PendingPreparation {
  PendingPreparation(
    this.id,
    this.playerId,
    this.mpCost,
    Map<String, Object?> input,
  ) : input = Map.unmodifiable(input);
  final Map<String, Object?> input;
  final String id;
  final String playerId;
  final int mpCost;
  bool ready = false;
  final List<Map<String, Object?>> selections = [];
}

/// Presence registry for summon mechanisms; no implicit player seat or turn.
final class SummonedUnitInstance {
  SummonedUnitInstance({
    required this.instanceId,
    required this.ownerId,
    this.alive = true,
    this.kind = 'presence',
  });
  final String instanceId;
  final String ownerId;
  final String kind;
  bool alive;
}
