import 'package:sns_server/domain/core/enum.dart';

/// 所有游戏命令的基类
abstract class GameCommand {
  /// 幂等键，服务端用于去重
  final String commandId;
  final String playerId;
  final int clientVersion;

  const GameCommand({
    required this.commandId,
    required this.playerId,
    required this.clientVersion,
  });
}

/// 出牌命令
class PlayCardSelection {
  final String cardId;
  final int? handIndex;

  const PlayCardSelection({
    required this.cardId,
    this.handIndex,
  });

  factory PlayCardSelection.fromJson(Map<String, dynamic> json) {
    final cardId = json['cardId'];
    if (cardId is! String || cardId.isEmpty) {
      throw StateError('cardSelections[].cardId must be a non-empty string');
    }

    final handIndex = json['handIndex'];
    if (handIndex != null && handIndex is! int) {
      throw StateError('cardSelections[].handIndex must be an integer');
    }

    return PlayCardSelection(
      cardId: cardId,
      handIndex: handIndex as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'cardId': cardId,
        if (handIndex != null) 'handIndex': handIndex,
      };
}

class PlayCardCommand extends GameCommand {
  final List<PlayCardSelection> cardSelections;
  final String? targetCharacterId;

  const PlayCardCommand({
    required super.commandId,
    required super.playerId,
    required super.clientVersion,
    required this.cardSelections,
    this.targetCharacterId,
  });
}

/// 普通攻击命令
class AttackCommand extends GameCommand {
  final String attackerCharacterId;
  final String targetCharacterId;

  const AttackCommand({
    required super.commandId,
    required super.playerId,
    required super.clientVersion,
    required this.attackerCharacterId,
    required this.targetCharacterId,
  });
}

/// 使用技能命令
class UseSkillCommand extends GameCommand {
  final String characterId;
  final String skillId;
  final Map<String, dynamic> params;

  const UseSkillCommand({
    required super.commandId,
    required super.playerId,
    required super.clientVersion,
    required this.characterId,
    required this.skillId,
    this.params = const {},
  });
}

/// 使用特质命令
class UseTraitCommand extends GameCommand {
  final String characterId;
  final String traitId;
  final Map<String, dynamic> params;

  const UseTraitCommand({
    required super.commandId,
    required super.playerId,
    required super.clientVersion,
    required this.characterId,
    required this.traitId,
    this.params = const {},
  });
}

/// 结束回合命令
class EndTurnCommand extends GameCommand {
  const EndTurnCommand({
    required super.commandId,
    required super.playerId,
    required super.clientVersion,
  });
}

/// 放弃当前响应优先权命令
class PassPriorityCommand extends GameCommand {
  const PassPriorityCommand({
    required super.commandId,
    required super.playerId,
    required super.clientVersion,
  });
}

/// 工厂：从统一 DTO 转换为具体命令
GameCommand parseGameCommand({
  required String commandId,
  required String playerId,
  required int clientVersion,
  required ActionType actionType,
  required Map<String, dynamic> payload,
}) {
  List<PlayCardSelection> parseCardSelections() {
    final rawSelections = payload['cardSelections'];
    if (rawSelections is! List) {
      throw StateError('cardSelections must be a list');
    }

    return rawSelections.map((rawSelection) {
      if (rawSelection is! Map) {
        throw StateError('Each card selection must be an object');
      }
      return PlayCardSelection.fromJson(Map<String, dynamic>.from(rawSelection));
    }).toList();
  }

  switch (actionType) {
    case ActionType.playCard:
      return PlayCardCommand(
        commandId: commandId,
        playerId: playerId,
        clientVersion: clientVersion,
        cardSelections: parseCardSelections(),
        targetCharacterId: payload['targetId'] as String?,
      );
    case ActionType.attack:
      return AttackCommand(
        commandId: commandId,
        playerId: playerId,
        clientVersion: clientVersion,
        attackerCharacterId: payload['attackerCharacterId'] as String,
        targetCharacterId: payload['targetCharacterId'] as String,
      );
    case ActionType.limitedCard:
    case ActionType.attackCard:
      throw StateError('API clients must use playCard instead of ${actionType.name}');
    case ActionType.skill:
      return UseSkillCommand(
        commandId: commandId,
        playerId: playerId,
        clientVersion: clientVersion,
        characterId: payload['characterId'] as String,
        skillId: payload['skillId'] as String,
        params: (payload['params'] as Map<String, dynamic>?) ?? {},
      );
    case ActionType.trait:
      return UseTraitCommand(
        commandId: commandId,
        playerId: playerId,
        clientVersion: clientVersion,
        characterId: payload['characterId'] as String,
        traitId: payload['traitId'] as String,
        params: (payload['params'] as Map<String, dynamic>?) ?? {},
      );
    case ActionType.passPriority:
      return PassPriorityCommand(
        commandId: commandId,
        playerId: playerId,
        clientVersion: clientVersion,
      );
  }
}
