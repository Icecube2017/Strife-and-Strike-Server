import 'package:sns_server/application/services/room_service.dart';

/// 房间持久化接口（MVP：内存实现，后续可换数据库）
abstract class RoomRepo {
  void save(Room room);
  Room? findById(String roomId);
  void delete(String roomId);
  List<Room> findAll();
}

class InMemoryRoomRepo implements RoomRepo {
  final Map<String, Room> _store = {};

  @override
  void save(Room room) => _store[room.id] = room;

  @override
  Room? findById(String roomId) => _store[roomId];

  @override
  void delete(String roomId) => _store.remove(roomId);

  @override
  List<Room> findAll() => List.unmodifiable(_store.values);
}
