import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';

/// Free the room code and discard an unfinished match in the same transaction.
// ignore: one_member_abstracts
abstract interface class RoomExpiryStore {
  Future<void> expire(
    Room closedRoom,
    String gameId, {
    required int? expectedGameVersion,
    required bool gameFinished,
  });
}

final class SqliteRoomExpiryStore implements RoomExpiryStore {
  SqliteRoomExpiryStore(this.db);
  final DbConnection db;

  @override
  Future<void> expire(
    Room closedRoom,
    String gameId, {
    required int? expectedGameVersion,
    required bool gameFinished,
  }) async {
    final database = db.database..execute('BEGIN IMMEDIATE');
    try {
      final rows = database.select(
        'SELECT version, finished FROM game_checkpoints WHERE id = ?',
        [gameId],
      );
      if ((rows.isEmpty ? null : rows.single['version']) !=
              expectedGameVersion ||
          (rows.isNotEmpty && (rows.single['finished'] == 1) != gameFinished)) {
        throw StateError('Game changed during room expiration');
      }
      if (expectedGameVersion != null && !gameFinished) {
        database.execute(
          'DELETE FROM game_checkpoints WHERE id = ? AND version = ? AND finished = 0',
          [gameId, expectedGameVersion],
        );
        if (database.updatedRows != 1) {
          throw StateError('Game changed during room expiration');
        }
      }
      database.execute(
        r"DELETE FROM rooms WHERE id = ? AND COALESCE(json_extract(snapshot, '$.version'), 0) = ?",
        [closedRoom.id, closedRoom.version - 1],
      );
      if (database.updatedRows != 1) {
        throw StateError('Room changed during expiration');
      }
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }
}
