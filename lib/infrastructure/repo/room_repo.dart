import 'package:postgres/postgres.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';

abstract class RoomRepo {
  Future<void> save(Room room);
  Future<Room?> findById(String roomId);
  Future<void> delete(String roomId);
}

class InMemoryRoomRepo implements RoomRepo {
  final Map<String, Room> _store = {};

  @override
  Future<void> save(Room room) async => _store[room.id] = room;

  @override
  Future<Room?> findById(String roomId) async => _store[roomId];

  @override
  Future<void> delete(String roomId) async => _store.remove(roomId);
}

class PgRoomRepo implements RoomRepo {
  PgRoomRepo(this._db);
  final DbConnection _db;

  @override
  Future<void> save(Room room) => _db.pool.execute(
        Sql.named('''
          INSERT INTO rooms (id, status)
          VALUES (@id, @status)
          ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status
        '''),
        parameters: {'id': room.id, 'status': room.status.name},
      );

  @override
  Future<Room?> findById(String roomId) async {
    final result = await _db.pool.execute(
      Sql.named('SELECT id, status FROM rooms WHERE id = @id'),
      parameters: {'id': roomId},
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return Room(
      id: row[0]! as String,
      players: [], // 玩家从内存恢复，不持久化
      status: RoomStatus.values.byName(row[1]! as String),
    );
  }

  @override
  Future<void> delete(String roomId) => _db.pool.execute(
        Sql.named('DELETE FROM rooms WHERE id = @id'),
        parameters: {'id': roomId},
      );
}
