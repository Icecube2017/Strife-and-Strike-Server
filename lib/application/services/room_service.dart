import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';

/// 房间状态
enum RoomStatus { waiting, ready, inGame }

/// 内存房间对象（MVP 阶段无持久化）
class Room {
  final String id;
  final List<Player> players;
  RoomStatus status;

  Room({required this.id, required this.players, this.status = RoomStatus.waiting});
}

/// 房间管理服务
class RoomService {
  final Map<String, Room> _rooms = {};

  RoomResponse createRoom(CreateRoomRequest req, Character hostCharacter) {
    final roomId = 'room_${DateTime.now().millisecondsSinceEpoch}';
    final host = Player(req.hostPlayerId, req.hostPlayerName, [hostCharacter], 0);
    _rooms[roomId] = Room(id: roomId, players: [host]);
    return _toResponse(roomId);
  }

  RoomResponse joinRoom(String roomId, JoinRoomRequest req, Character character) {
    final room = _getRoom(roomId);
    if (room.status != RoomStatus.waiting) {
      throw StateError('Room $roomId is not accepting players');
    }
    final player = Player(req.playerId, req.playerName, [character], room.players.length);
    room.players.add(player);
    return _toResponse(roomId);
  }

  /// 返回房间玩家列表，供 GameService 初始化 GameState
  List<Player> getPlayers(String roomId) => List.unmodifiable(_getRoom(roomId).players);

  void markInGame(String roomId) => _getRoom(roomId).status = RoomStatus.inGame;

  Room _getRoom(String roomId) {
    final room = _rooms[roomId];
    if (room == null) throw StateError('Room $roomId not found');
    return room;
  }

  RoomResponse _toResponse(String roomId) {
    final room = _rooms[roomId]!;
    return RoomResponse(
      roomId: roomId,
      status: room.status.name,
      playerIds: room.players.map((p) => p.id).toList(),
    );
  }
}
