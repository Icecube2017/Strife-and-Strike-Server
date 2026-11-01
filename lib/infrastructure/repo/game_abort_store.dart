import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';

/// Match deletion and room closure must commit together.
// ignore: one_member_abstracts
abstract interface class GameAbortStore {
  Future<void> abort(String gameId, int expectedGameVersion, Room closedRoom);
}

final class SqliteGameAbortStore implements GameAbortStore {
  SqliteGameAbortStore(this.db);
  final DbConnection db;
  @override
  Future<void> abort(
    String gameId,
    int expectedGameVersion,
    Room closedRoom,
  ) async {
    final database = db.database..execute('BEGIN IMMEDIATE');
    try {
      database.execute(
        'DELETE FROM game_checkpoints WHERE id = ? AND version = ? AND finished = 0',
        [gameId, expectedGameVersion],
      );
      if (database.updatedRows != 1) {
        throw StateError('Game changed or already finished');
      }
      database.execute(
        r"DELETE FROM rooms WHERE id = ? AND COALESCE(json_extract(snapshot, '$.version'), 0) = ?",
        [closedRoom.id, closedRoom.version - 1],
      );
      if (database.updatedRows != 1) {
        throw StateError('Room changed during abort');
      }
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }
}
