import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:sns_server/application/dto/game_dto.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';

/// 游戏持久化接口（Structure.md §6：内存状态 + 周期快照）
abstract class GameRepo {
  void saveRuntime(String gameId, GameRuntime runtime);
  GameRuntime? findRuntime(String gameId);
  void removeRuntime(String gameId);

  Future<void> saveSnapshot(String gameId, PublicGameView view);
  Future<PublicGameView?> loadSnapshot(String gameId);
}

/// 内存实现（runtime 始终在内存；快照可选落盘）
class InMemoryGameRepo implements GameRepo {
  final Map<String, GameRuntime> _runtimes = {};
  final Map<String, PublicGameView> _snapshots = {};

  @override
  void saveRuntime(String gameId, GameRuntime runtime) => _runtimes[gameId] = runtime;
  @override
  GameRuntime? findRuntime(String gameId) => _runtimes[gameId];
  @override
  void removeRuntime(String gameId) {
    _runtimes.remove(gameId);
    _snapshots.remove(gameId);
  }

  @override
  Future<void> saveSnapshot(String gameId, PublicGameView view) async =>
      _snapshots[gameId] = view;
  @override
  Future<PublicGameView?> loadSnapshot(String gameId) async => _snapshots[gameId];
}

/// Postgres 实现（runtime 仍在内存，快照存 pg）
class PgGameRepo implements GameRepo {
  PgGameRepo(this._db);
  final DbConnection _db;
  final Map<String, GameRuntime> _runtimes = {};

  @override
  void saveRuntime(String gameId, GameRuntime runtime) => _runtimes[gameId] = runtime;
  @override
  GameRuntime? findRuntime(String gameId) => _runtimes[gameId];
  @override
  void removeRuntime(String gameId) => _runtimes.remove(gameId);

  @override
  Future<void> saveSnapshot(String gameId, PublicGameView view) => _db.pool.execute(
        Sql.named('''
          INSERT INTO game_snapshots (game_id, version, snapshot)
          VALUES (@gameId, @version, @snapshot)
          ON CONFLICT (game_id) DO UPDATE
            SET version = EXCLUDED.version,
                snapshot = EXCLUDED.snapshot,
                updated_at = now()
        '''),
        parameters: {
          'gameId': gameId,
          'version': view.version,
          'snapshot': jsonEncode(view.toJson()),
        },
      );

  @override
  Future<PublicGameView?> loadSnapshot(String gameId) async {
    final result = await _db.pool.execute(
      Sql.named('SELECT snapshot FROM game_snapshots WHERE game_id = @gameId'),
      parameters: {'gameId': gameId},
    );
    if (result.isEmpty) return null;
    try {
      final m = jsonDecode(result.first[0] as String) as Map<String, dynamic>;
      return _decodeView(m);
    } catch (_) {
      return null;
    }
  }

  PublicGameView _decodeView(Map<String, dynamic> m) => PublicGameView(
        gameId: m['gameId'] as String,
        version: m['version'] as int,
        currentRound: m['currentRound'] as int,
        currentTurn: m['currentTurn'] as int,
        currentPlayerId: m['currentPlayerId'] as String,
        currentPhase: m['currentPhase'] as String,
        characters: (m['characters'] as List).map((c) {
          final cv = c as Map<String, dynamic>;
          return CharacterPublicView(
            characterId: cv['characterId'] as String,
            currentHp: cv['currentHp'] as int,
            maxHp: cv['maxHp'] as int,
            attack: cv['attack'] as int,
            defense: cv['defense'] as int,
            currentMp: cv['currentMp'] as int,
            maxMp: cv['maxMp'] as int,
            isAlive: cv['isAlive'] as bool,
            statusIds: (cv['statusIds'] as List).cast<String>(),
          );
        }).toList(),
      );
}
