import '../dice.dart';
import '../state.dart';

/// Expose final attack dice without adding combat facts or changing replays.
/// The roll prefix already includes player replacements; only the calculation
/// suffix (bonuses, target caps and fixed maximum) is reported as a new change.
KernelEvent projectAttackDiceLogEvent(KernelEvent event) {
  if (event.type != 'damageCalculated') return event;
  final numbers = publicFinalAttackDiceNumbers(event.data);
  if (numbers.isEmpty) return event;
  return KernelEvent(
    event.sequence,
    'attackDiceFinalized',
    {
      'sourceId': event.data['sourceId'],
      'targetId': event.data['targetId'],
      ...numbers,
    },
    round: event.round,
    turn: event.turn,
    phase: event.phase,
    extraTurn: event.extraTurn,
  );
}

Map<String, Object?> publicFinalAttackDiceNumbers(Map<String, Object?> data) {
  final result = data['finalDice'];
  if (result is! num || !result.isFinite) return const {};
  final fallback = <String, Object?>{'result': result};
  final raw = data['diceRoll'];
  if (raw is! Map) return fallback;
  try {
    final roll = RollResult.fromJson(Map<String, dynamic>.from(raw));
    if (roll.finalTotal != result) return fallback;
    final start = roll.modifications.lastIndexWhere(
      (m) => m.sourceId == 'attack_modifiers',
    );
    if (start < 0) return fallback;
    final before = roll.modifications
        .take(start)
        .fold<int>(roll.rawTotal, (value, change) => change.apply(value));
    if (before == result) return const {};
    return {'before': before, 'amount': result - before, 'result': result};
  } on FormatException {
    return fallback;
  } on ArgumentError {
    return fallback;
  } on TypeError {
    return fallback;
  }
}

/// Numeric presentation facts only; the immutable combat event is unchanged.
Map<String, Object?> publicDiceChangeNumbers(Map<String, Object?> data) {
  final result = data['result'];
  final before = data['before'];
  if (result is num && before is num) {
    return {'before': before, 'amount': result - before};
  }
  final raw = data['roll'];
  if (raw is! Map || result is! num) return const {};
  try {
    final roll = RollResult.fromJson(Map<String, dynamic>.from(raw));
    if (roll.modifications.isEmpty || roll.finalTotal != result) {
      return const {};
    }
    final previous = roll.modifications
        .take(roll.modifications.length - 1)
        .fold<int>(roll.rawTotal, (value, change) => change.apply(value));
    return {'before': previous, 'amount': result - previous};
  } on FormatException {
    return const {};
  } on ArgumentError {
    return const {};
  } on TypeError {
    return const {};
  }
}

/// Zero-cost internal facts remain available to recovery and rule triggers.
bool hasPublicMpCost(Map<String, Object?> data) =>
    data['amount'] is num && (data['amount']! as num) > 0;

/// Public log protocol. Unknown types and fields are never exposed.
const publicLogTargetEventTypes = {
  'skillUsed',
  'skillTriggered',
  'traitTriggered',
  'cardPlayed',
};
const publicLogCardDetailEventTypes = {
  'skillUsed',
  'cardCancelled',
  'cardReinforced',
  'cardPlayed',
};

const publicLogEventTypes = {
  'attackDiceFinalized',
  'damageDiceSelected',
  'attackDiceAdjusted',
  'statusSettled',
  'statusIntensityGrowth',
  'unitSummoned',
  'statModified',
  'cardPlayed',
  'gameStarted',
  'roundStarted',
  'roundEnding',
  'turnStarted',
  'turnEnded',
  'extraTurnStarted',
  'extraTurnGranted',
  'gameFinished',
  'attackDeclared',
  'diceRolled',
  'diceChanged',
  'attackDodged',
  'attackPacketResolved',
  'damage',
  'healed',
  'shieldGained',
  'shieldBroken',
  'lifePaid',
  'actionLifePaid',
  'lifeRestored',
  'lifeSet',
  'continuationExpired',
  'continuationFailed',
  'diceReplaced',
  'shieldConverted',
  'cardGenerated',
  'generatedActionSkipped',
  'skillBorrowed',
  'skillReturned',
  'resourceReaction',
  'lifeStolen',
  'damageRefunded',
  'statusApplied',
  'statusModified',
  'statusRemoved',
  'statusRejected',
  'statusStacksCancelled',
  'statusDamageLimitReached',
  'mpSpent',
  'mpChanged',
  'mpRegenerated',
  'cardsDrawn',
  'handRevealed',
  'cardsLost',
  'attackDiceGrowth',
  'actionMpRefunded',
  'cardTagRestricted',
  'handCardsDisabled',
  'handCardEnabled',
  'skillDrawn',
  'skillUsed',
  'traitTriggered',
  'characterDied',
  'deathAnnounced',
  'saveCreated',
  'saveRestored',
  'markChanged',
  'counterattack',
  'duelResolved',
  'outgoingDuelResolved',
  'duelAttackIncreased',
  'damageRedirected',
  'damageShared',
  'shieldTransferred',
  'handCardMoved',
  'attackRedirected',
  'attackDamageCapped',
  'skillTriggered',
  'summonsRemoved',
  'damageGuardRolled',
  'defenseLifeLost',
  'defenseIncreased',
  'handsSwapped',
  'resourcesSwapped',
  'cardTaken',
  'cardBorrowed',
  'cardReturned',
  'mentalActionFailed',
  'negativeMpEntered',
  'negativeMpReleased',
  'attackEffectsRotated',
  'mpConvertedToReserve',
  'timeReserveUsed',
  'discardReserveStored',
  'skillEffectsNegated',
  'targetFeeApplied',
  'buddyFullMpReleased',
  'supportStanceEntered',
  'attackTargetRedirected',
  'supportAttackStarted',

  'lifeThresholdActivated',
  'shieldCleared',
  'preyPlaced',
  'preyActivated',
  'preyDefended',
  'preyReleased',
  'cardCancelled',
  'cardReinforced',
  'cardsPlayed',
  'cardsDiscarded',
  'choiceOpened',
  'choiceResolved',
  'abilityPrepared',
  'abilityPreparationCancelled',
  'responseWindowOpened',
  'responseSubmitted',
  'responseWindowClosed',
  'responseWindowExpired',
  'responseSkipped',
  'actionCancelled',
  'actionFailed',
  'actionResolved',
  'recordReplayed',
  'recordConsumed',
  'actionRecorded',
  'statusActivated',
  'skillsRevealed',
  'duelStarted',
  'scheduledEffectResolved',
  'triggerBudgetExceeded',
  'attackTargetForced',
};

const publicLogScalarFields = {
  'stat',
  'actorId',
  'sourceId',
  'targetId',
  'ownerId',
  'playerId',
  'attackerId',
  'defenderId',
  'fromId',
  'amount',
  'nominalAmount',
  'count',
  'stacks',
  'intensity',
  'stackDelta',
  'intensityDelta',
  'round',
  'turn',
  'actualTurn',
  'sides',
  'result',
  'kind',
  'shieldAbsorbed',
  'hpLost',
  'before',
  'hp',
  'overflow',
  'attackPoints',
  'defenderRoll',
  'defenderPoints',
  'nextBonus',
  'won',
  'bonus',
  'attack',
  'skipped',
  'draw',
  'winnerTeamId',
  'reason',
  'outcome',
  'transferredAmount',
  'damage',
  'restoring',
  'tag',
  'untilRound',
  'anchorPlayerId',
  'durationRounds',
  'decayPhase',
  'threshold',
  'destination',
};
