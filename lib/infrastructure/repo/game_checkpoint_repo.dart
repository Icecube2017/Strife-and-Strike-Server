import 'dart:convert';

import 'package:sns_server/infrastructure/db/db_connection.dart';

/// Entire private save. This is never returned by a public HTTP projection.
abstract class GameCheckpointRepo {
  Future<void> save(
    String gameId,
    Map<String, Object?> checkpoint, {
    required int? expectedVersion,
  });
  Future<List<Map<String, dynamic>>> loadAll();
  Future<Map<String, dynamic>?> findById(String gameId);
  Future<void> delete(String gameId);
}

class InMemoryGameCheckpointRepo implements GameCheckpointRepo {
  final Map<String, Map<String, dynamic>> _store = {};
  @override
  Future<void> save(
    String gameId,
    Map<String, Object?> checkpoint, {
    required int? expectedVersion,
  }) async {
    if (_store[gameId]?['version'] != expectedVersion) {
      throw StateError('Persisted game version conflict');
    }
    _store[gameId] = jsonDecode(jsonEncode(checkpoint)) as Map<String, dynamic>;
  }

  @override
  Future<List<Map<String, dynamic>>> loadAll() async => [
    for (final v in _store.values)
      jsonDecode(jsonEncode(v)) as Map<String, dynamic>,
  ];
  @override
  Future<Map<String, dynamic>?> findById(String id) async => _store[id] == null
      ? null
      : jsonDecode(jsonEncode(_store[id])) as Map<String, dynamic>;
  @override
  Future<void> delete(String gameId) async {
    _store.remove(gameId);
  }
}

class SqliteGameCheckpointRepo implements GameCheckpointRepo {
  SqliteGameCheckpointRepo(this._db);
  final DbConnection _db;
  @override
  Future<void> save(
    String gameId,
    Map<String, Object?> checkpoint, {
    required int? expectedVersion,
  }) async {
    final values = <Object?>[
      checkpoint['version'],
      if (checkpoint['finished'] == true) 1 else 0,
      jsonEncode(checkpoint),
      DateTime.now().toUtc().toIso8601String(),
      gameId,
    ];
    if (expectedVersion == null) {
      _db.database.execute(
        'INSERT INTO game_checkpoints (version, finished, checkpoint, updated_at, id) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING',
        values,
      );
    } else {
      _db.database.execute(
        'UPDATE game_checkpoints SET version = ?, finished = ?, checkpoint = ?, updated_at = ? WHERE id = ? AND version = ?',
        [...values, expectedVersion],
      );
    }
    if (_db.database.updatedRows != 1) {
      throw StateError('Persisted game version conflict');
    }
  }

  Map<String, dynamic> _read(Map<String, Object?> row) =>
      jsonDecode(row['checkpoint']! as String) as Map<String, dynamic>;
  @override
  Future<List<Map<String, dynamic>>> loadAll() async => [
    for (final row in _db.database.select(
      'SELECT checkpoint FROM game_checkpoints ORDER BY id',
    ))
      _read(row),
  ];
  @override
  Future<Map<String, dynamic>?> findById(String gameId) async {
    final rows = _db.database.select(
      'SELECT checkpoint FROM game_checkpoints WHERE id = ?',
      [gameId],
    );
    return rows.isEmpty ? null : _read(rows.first);
  }

  @override
  Future<void> delete(String gameId) async {
    _db.database.execute('DELETE FROM game_checkpoints WHERE id = ?', [gameId]);
  }
}
