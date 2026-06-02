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
class PlayCardCommand extends GameCommand {
  final String cardId;
  final String? targetCharacterId;

  const PlayCardCommand({
    required super.commandId,
    required super.playerId,
    required super.clientVersion,
    required this.cardId,
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

/// 结束回合命令
class EndTurnCommand extends GameCommand {
  const EndTurnCommand({
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
  switch (actionType) {
    case ActionType.attackCard:
      return PlayCardCommand(
        commandId: commandId,
        playerId: playerId,
        clientVersion: clientVersion,
        cardId: payload['cardId'] as String,
        targetCharacterId: payload['targetCharacterId'] as String?,
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
      return UseSkillCommand(
        commandId: commandId,
        playerId: playerId,
        clientVersion: clientVersion,
        characterId: payload['characterId'] as String,
        skillId: payload['skillId'] as String,
        params: (payload['params'] as Map<String, dynamic>?) ?? {},
      );
  }
}
