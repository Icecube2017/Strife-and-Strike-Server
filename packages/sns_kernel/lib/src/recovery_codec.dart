import 'commands.dart';
import 'definitions.dart';

/// Internal durable format; never accepts client state or effect patches.
final class KernelRecoveryCodec {
  static Map<String, Object?> setup(GameSetup value) => {
    'gameId': value.gameId,
    'seed': value.seed,
    'players': [
      for (final p in value.players)
        {'id': p.id, 'characterId': p.characterId, 'teamId': p.teamId},
    ],
    'deck': value.deck,
    'skillPool': value.skillPool,
    'rules': {
      'useLegacyDamageFormula': value.rules.useLegacyDamageFormula,
      'actionsPerTurn': value.rules.actionsPerTurn,
      'enforceSkillUniqueness': value.rules.enforceSkillUniqueness,
      'anomalyConflict': value.rules.anomalyConflict.name,
      'requireAllResponses': value.rules.requireAllResponses,
      'responseTimeoutSeconds': value.rules.responseTimeoutSeconds,
      'openingCards': value.rules.openingCards,
      'openingSkills': value.rules.openingSkills,
      'cardsPerTurn': value.rules.cardsPerTurn,
      'maxHand': value.rules.maxHand,
      'normalAttackCost': value.rules.normalAttackCost,
      'defaultDiceSides': value.rules.defaultDiceSides,
      'revealRound': value.rules.revealRound,
      'duelEnabled': value.rules.duelEnabled,
      'duelRound': value.rules.duelRound,
      'duelAttackBonus': value.rules.duelAttackBonus,
      'duelHealingMultiplier': value.rules.duelHealingMultiplier,
      'duelDamageMultiplier': value.rules.duelDamageMultiplier,
      'shuffleDeck': value.rules.shuffleDeck,
      'shuffleSkillPool': value.rules.shuffleSkillPool,
      'emptyDeckPolicy': value.rules.emptyDeckPolicy.name,
    },
  };
  static GameSetup readSetup(Map<String, dynamic> json) {
    final r = json['rules'] as Map<String, dynamic>;
    return GameSetup(
      gameId: json['gameId'] as String,
      seed: json['seed'] as int,
      players: [
        for (final p in json['players'] as List)
          PlayerSetup(
            id: p['id'] as String,
            characterId: p['characterId'] as String,
            teamId: p['teamId'] as String,
          ),
      ],
      deck: (json['deck'] as List).cast<String>(),
      skillPool: (json['skillPool'] as List).cast<String>(),
      rules: GameRules(
        useLegacyDamageFormula: r['useLegacyDamageFormula'] as bool,
        actionsPerTurn: r['actionsPerTurn'] as int,
        enforceSkillUniqueness: r['enforceSkillUniqueness'] as bool,
        anomalyConflict: AnomalyConflict.values.byName(
          r['anomalyConflict'] as String,
        ),
        requireAllResponses: r['requireAllResponses'] as bool,
        responseTimeoutSeconds: r['responseTimeoutSeconds'] as int,
        openingCards: r['openingCards'] as int,
        openingSkills: r['openingSkills'] as int,
        cardsPerTurn: r['cardsPerTurn'] as int,
        maxHand: r['maxHand'] as int,
        normalAttackCost: r['normalAttackCost'] as int,
        defaultDiceSides: r['defaultDiceSides'] as int,
        revealRound: r['revealRound'] as int,
        duelEnabled: r['duelEnabled'] as bool,
        duelRound: r['duelRound'] as int,
        duelAttackBonus: r['duelAttackBonus'] as int,
        duelHealingMultiplier: (r['duelHealingMultiplier'] as num).toDouble(),
        // Missing only in games created under the original attack/heal duel.
        duelDamageMultiplier: (r['duelDamageMultiplier'] as num? ?? 1)
            .toDouble(),
        shuffleDeck: r['shuffleDeck'] as bool,
        shuffleSkillPool: r['shuffleSkillPool'] as bool,
        emptyDeckPolicy: EmptyDeckPolicy.values.byName(
          r['emptyDeckPolicy'] as String,
        ),
      ),
    );
  }

  static Map<String, Object?> command(KernelCommand c) => {
    'playerId': c.playerId,
    ...switch (c) {
      AttackCommand() => {'type': 'attack', 'targetId': c.targetId},
      PlayCardsCommand() => {
        'type': 'playCards',
        'cardInstanceIds': c.cardInstanceIds,
        'targetId': c.targetId,
      },
      UseSkillCommand() => {
        'type': 'useSkill',
        'skillInstanceId': c.skillInstanceId,
        'targetIds': c.targetIds,
        'diceResult': c.diceResult,
        'number': c.number,
        'cardInstanceId': c.cardInstanceId,
        'pendingActionId': c.pendingActionId,
        'copiedSkillId': c.copiedSkillId,
        'recordId': c.recordId,
        'reverse': c.reverse,
      },
      EndTurnCommand() => {'type': 'endTurn'},
      DiscardCommand() => {
        'type': 'discard',
        'cardInstanceIds': c.cardInstanceIds,
      },
      RecordActionCommand() => {
        'type': 'recordAction',
        'pendingActionId': c.pendingActionId,
        'traitInstanceId': c.traitInstanceId,
        'cardInstanceId': c.cardInstanceId,
      },
      PassCommand() => {'type': 'pass', 'pendingActionId': c.pendingActionId},
      BeginResponseCommand() => {
        'type': 'beginResponse',
        'pendingActionId': c.pendingActionId,
        'optionId': c.optionId,
      },
      RespondCardCommand() => {
        'type': 'respondCard',
        'pendingActionId': c.pendingActionId,
        'cardInstanceId': c.cardInstanceId,
      },
      ChooseCommand() => {
        'type': 'choose',
        'choiceId': c.choiceId,
        'optionId': c.optionId,
      },
      ActivateStatusCommand() => {
        'type': 'activateStatus',
        'statusInstanceId': c.statusInstanceId,
      },
      ActivateTraitCommand() => {
        'type': 'activateTrait',
        'traitInstanceId': c.traitInstanceId,
        'cardInstanceIds': c.cardInstanceIds,
        'mode': c.mode,
      },
      ConfirmAbilityCommand() => {
        'type': 'confirmAbility',
        'preparationId': c.preparationId,
      },
      CancelAbilityCommand() => {
        'type': 'cancelAbility',
        'preparationId': c.preparationId,
      },
    },
  };
  static KernelCommand readCommand(Map<String, dynamic> j) {
    final p = j['playerId'] as String;
    return switch (j['type']) {
      'recordAction' => RecordActionCommand(
        p,
        j['pendingActionId'] as String,
        j['traitInstanceId'] as String,
        cardInstanceId: j['cardInstanceId'] as String?,
      ),
      'attack' => AttackCommand(p, j['targetId'] as String),
      'playCards' => PlayCardsCommand(
        p,
        (j['cardInstanceIds'] as List).cast<String>(),
        targetId: j['targetId'] as String?,
      ),
      'useSkill' => UseSkillCommand(
        p,
        j['skillInstanceId'] as String,
        targetIds: (j['targetIds'] as List).cast<String>(),
        diceResult: j['diceResult'] as int?,
        number: j['number'] as int?,
        cardInstanceId: j['cardInstanceId'] as String?,
        pendingActionId: j['pendingActionId'] as String?,
        copiedSkillId: j['copiedSkillId'] as String?,
        recordId: j['recordId'] as String?,
        reverse: j['reverse'] as bool,
      ),
      'endTurn' => EndTurnCommand(p),
      'discard' => DiscardCommand(
        p,
        (j['cardInstanceIds'] as List).cast<String>(),
      ),
      'pass' => PassCommand(p, j['pendingActionId'] as String),
      'beginResponse' => BeginResponseCommand(
        p,
        j['pendingActionId'] as String,
        j['optionId'] as String,
      ),
      'respondCard' => RespondCardCommand(
        p,
        j['pendingActionId'] as String,
        j['cardInstanceId'] as String,
      ),
      'choose' => ChooseCommand(
        p,
        j['choiceId'] as String,
        j['optionId'] as String,
      ),
      'activateStatus' => ActivateStatusCommand(
        p,
        j['statusInstanceId'] as String,
      ),
      'activateTrait' => ActivateTraitCommand(
        p,
        j['traitInstanceId'] as String,
        cardInstanceIds: (j['cardInstanceIds'] as List).cast<String>(),
        mode: j['mode'] as String,
      ),
      'confirmAbility' => ConfirmAbilityCommand(
        p,
        j['preparationId'] as String,
      ),
      'cancelAbility' => CancelAbilityCommand(p, j['preparationId'] as String),
      _ => throw const FormatException('Unknown persisted command'),
    };
  }
}
