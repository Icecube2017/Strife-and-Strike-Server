import 'package:sns_server/application/dto/room_rules.dart';

/// POST /rooms 请求体
class CreateRoomRequest {
  final String hostPlayerId;
  final String hostPlayerName;
  final int maxPlayers;
  final RoomRules rules;

  CreateRoomRequest({
    required this.hostPlayerId,
    required this.hostPlayerName,
    this.maxPlayers = 4,
    this.rules = const RoomRules(),
  });

  factory CreateRoomRequest.fromJson(Map<String, dynamic> json) =>
      CreateRoomRequest(
        hostPlayerId: json['hostPlayerId'] as String,
        hostPlayerName: json['hostPlayerName'] as String,
        maxPlayers: (json['maxPlayers'] as int?) ?? 4,
        rules: RoomRules.fromJson(json['rules']),
      );
}

/// POST /rooms/{id}/join 请求体
class JoinRoomRequest {
  final String playerId;
  final String playerName;

  JoinRoomRequest({required this.playerId, required this.playerName});

  factory JoinRoomRequest.fromJson(Map<String, dynamic> json) =>
      JoinRoomRequest(
        playerId: json['playerId'] as String,
        playerName: json['playerName'] as String,
      );
}

/// 房间信息响应
class RoomResponse {
  final String roomId;
  final String status; // Compatibility field; clients should read phase.
  final List<String> playerIds;
  final RoomRules rules;
  final String? roomCode;
  final String? hostPlayerId;
  final String? gameId;
  final String phase;
  final String? closeReason;
  final List<String> characterPool;
  final List<String> fullCharacterPool;
  final List<String> banSubmittedPlayerIds;
  final List<String> bannedCharacterIds;
  final int version;
  final int maxPlayers;
  final List<Map<String, Object?>> players;
  // Internal projection input. Never expose the observer IDs over HTTP/SSE.
  final Set<String> spectatorIds;

  RoomResponse({
    required this.roomId,
    required this.status,
    required this.playerIds,
    this.roomCode,
    this.hostPlayerId,
    this.gameId,
    this.phase = 'lobby',
    this.closeReason,
    this.characterPool = const [],
    this.fullCharacterPool = const [],
    this.banSubmittedPlayerIds = const [],
    this.bannedCharacterIds = const [],
    this.version = 0,
    this.maxPlayers = 4,
    this.players = const [],
    this.rules = const RoomRules(),
    this.spectatorIds = const {},
  });

  Map<String, dynamic> toJson({String? viewerId}) => {
    if (viewerId != null) 'spectating': spectatorIds.contains(viewerId),
    'roomId': roomId,
    'roomCode': roomCode,
    'hostPlayerId': hostPlayerId,
    'gameId': gameId,
    'phase': phase,
    if (closeReason != null) 'closeReason': closeReason,
    'characterPool': characterPool,
    'fullCharacterPool': fullCharacterPool,
    'banSubmittedPlayerIds': banSubmittedPlayerIds,
    'bannedCharacterIds': bannedCharacterIds,
    'version': version,
    'maxPlayers': maxPlayers,
    'players': players,
    'status': status,
    'playerIds': playerIds,
    'rules': rules.toJson(),
  };
}
