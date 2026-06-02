/// POST /rooms 请求体
class CreateRoomRequest {
  final String hostPlayerId;
  final String hostPlayerName;
  final int maxPlayers;

  CreateRoomRequest({
    required this.hostPlayerId,
    required this.hostPlayerName,
    this.maxPlayers = 4,
  });

  factory CreateRoomRequest.fromJson(Map<String, dynamic> json) =>
      CreateRoomRequest(
        hostPlayerId: json['hostPlayerId'] as String,
        hostPlayerName: json['hostPlayerName'] as String,
        maxPlayers: (json['maxPlayers'] as int?) ?? 4,
      );
}

/// POST /rooms/{id}/join 请求体
class JoinRoomRequest {
  final String playerId;
  final String playerName;

  JoinRoomRequest({required this.playerId, required this.playerName});

  factory JoinRoomRequest.fromJson(Map<String, dynamic> json) => JoinRoomRequest(
        playerId: json['playerId'] as String,
        playerName: json['playerName'] as String,
      );
}

/// 房间信息响应
class RoomResponse {
  final String roomId;
  final String status; // waiting / ready / in_game
  final List<String> playerIds;

  RoomResponse({
    required this.roomId,
    required this.status,
    required this.playerIds,
  });

  Map<String, dynamic> toJson() => {
        'roomId': roomId,
        'status': status,
        'playerIds': playerIds,
      };
}
