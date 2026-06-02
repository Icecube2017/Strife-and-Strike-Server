import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/infrastructure/repo/room_repo.dart';

/// 房间状态
enum RoomStatus { waiting, ready, inGame }

/// 内存房间对象
class Room {
  final String id;
  final List<Player> players;
  RoomStatus status;

  Room({required this.id, required this.players, this.status = RoomStatus.waiting});
}

/// 房间管理服务
class RoomService {
  RoomService(this._repo);
  final RoomRepo _repo;

  // 内存中维护玩家列表（players 不持久化到 pg）
  final Map<String, List<Player>> _playersByRoom = {};

  Future<RoomResponse> createRoom(CreateRoomRequest req, Character hostCharacter) async {
    final roomId = 'room_${DateTime.now().millisecondsSinceEpoch}';
    final host = Player(req.hostPlayerId, req.hostPlayerName, [hostCharacter], 0);
    final room = Room(id: roomId, players: [host]);
    _playersByRoom[roomId] = room.players;
    await _repo.save(room);
    return _toResponse(roomId, room);
  }

  Future<RoomResponse> joinRoom(String roomId, JoinRoomRequest req, Character character) async {
    final room = await _getRoom(roomId);
    if (room.status != RoomStatus.waiting) {
      throw StateError('Room $roomId is not accepting players');
    }
    final players = _playersByRoom[roomId] ??= [];
    final player = Player(req.playerId, req.playerName, [character], players.length);
    players.add(player);
    room.players.addAll(players.where((p) => p.id == player.id));
    await _repo.save(room);
    return _toResponse(roomId, room);
  }

  List<Player> getPlayers(String roomId) =>
      List.unmodifiable(_playersByRoom[roomId] ?? []);

  Future<void> markInGame(String roomId) async {
    final room = await _getRoom(roomId);
    room.status = RoomStatus.inGame;
    await _repo.save(room);
  }

  Future<Room> _getRoom(String roomId) async {
    final room = await _repo.findById(roomId);
    if (room == null) throw StateError('Room $roomId not found');
    return room;
  }

  RoomResponse _toResponse(String roomId, Room room) => RoomResponse(
        roomId: roomId,
        status: room.status.name,
        playerIds: (_playersByRoom[roomId] ?? []).map((p) => p.id).toList(),
      );
}
