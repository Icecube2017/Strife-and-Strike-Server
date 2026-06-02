import 'package:sns_server/domain/core/enum.dart';

/// POST /games/{id}/commands 统一命令格式（Structure.md §4）
class GameCommandRequest {
  final String commandId;   // 幂等键
  final String playerId;
  final ActionType actionType;
  final Map<String, dynamic> payload;
  final int clientVersion;  // 用于乐观锁冲突检测

  GameCommandRequest({
    required this.commandId,
    required this.playerId,
    required this.actionType,
    required this.payload,
    required this.clientVersion,
  });

  factory GameCommandRequest.fromJson(Map<String, dynamic> json) =>
      GameCommandRequest(
        commandId: json['commandId'] as String,
        playerId: json['playerId'] as String,
        actionType: ActionType.values.byName(json['actionType'] as String),
        payload: (json['payload'] as Map<String, dynamic>?) ?? {},
        clientVersion: json['clientVersion'] as int,
      );
}

/// GET /games/{id}/state 公开视图（Structure.md §5）
class PublicGameView {
  final String gameId;
  final int version;
  final int currentRound;
  final String currentPlayerId;
  final String currentPhase;
  final List<CharacterPublicView> characters;

  PublicGameView({
    required this.gameId,
    required this.version,
    required this.currentRound,
    required this.currentPlayerId,
    required this.currentPhase,
    required this.characters,
  });

  Map<String, dynamic> toJson() => {
        'gameId': gameId,
        'version': version,
        'currentRound': currentRound,
        'currentPlayerId': currentPlayerId,
        'currentPhase': currentPhase,
        'characters': characters.map((c) => c.toJson()).toList(),
      };
}

/// 玩家私有视图（含手牌）
class PlayerPrivateView {
  final String playerId;
  final List<String> handCardIds;

  PlayerPrivateView({required this.playerId, required this.handCardIds});

  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'handCardIds': handCardIds,
      };
}

/// 单个角色公开状态
class CharacterPublicView {
  final String characterId;
  final String name;
  final int currentHp;
  final int maxHp;
  final int currentMp;
  final int maxMp;
  final bool isAlive;
  final List<String> statusIds;

  CharacterPublicView({
    required this.characterId,
    required this.name,
    required this.currentHp,
    required this.maxHp,
    required this.currentMp,
    required this.maxMp,
    required this.isAlive,
    required this.statusIds,
  });

  Map<String, dynamic> toJson() => {
        'characterId': characterId,
        'name': name,
        'currentHp': currentHp,
        'maxHp': maxHp,
        'currentMp': currentMp,
        'maxMp': maxMp,
        'isAlive': isAlive,
        'statusIds': statusIds,
      };
}

/// 命令执行结果
class CommandResult {
  final bool success;
  final String? error;
  final int newVersion;

  CommandResult({required this.success, this.error, required this.newVersion});

  Map<String, dynamic> toJson() => {
        'success': success,
        if (error != null) 'error': error,
        'newVersion': newVersion,
      };
}
