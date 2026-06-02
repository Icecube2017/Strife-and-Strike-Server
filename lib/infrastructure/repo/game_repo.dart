import 'dart:convert';
import 'dart:io';

import 'package:sns_server/application/dto/game_dto.dart';
import 'package:sns_server/application/services/game_service.dart';

/// 游戏持久化接口（Structure.md §6：内存状态 + 周期快照）
abstract class GameRepo {
  void saveRuntime(String gameId, GameRuntime runtime);
  GameRuntime? findRuntime(String gameId);
  void removeRuntime(String gameId);

  /// 将当前 PublicGameView 序列化为 JSON 快照到磁盘
  Future<void> saveSnapshot(String gameId, PublicGameView view);
  /// 加载最近一次快照（重启恢复用）
  Future<PublicGameView?> loadSnapshot(String gameId);
}

class InMemoryGameRepo implements GameRepo {
  final Map<String, GameRuntime> _runtimes = {};

  // 快照落盘目录
  final Directory _snapshotDir;

  InMemoryGameRepo({String snapshotPath = '.snapshots'})
      : _snapshotDir = Directory(snapshotPath);

  @override
  void saveRuntime(String gameId, GameRuntime runtime) =>
      _runtimes[gameId] = runtime;

  @override
  GameRuntime? findRuntime(String gameId) => _runtimes[gameId];

  @override
  void removeRuntime(String gameId) => _runtimes.remove(gameId);

  @override
  Future<void> saveSnapshot(String gameId, PublicGameView view) async {
    if (!_snapshotDir.existsSync()) _snapshotDir.createSync(recursive: true);
    final file = File('${_snapshotDir.path}/$gameId.json');
    await file.writeAsString(jsonEncode(view.toJson()));
  }

  @override
  Future<PublicGameView?> loadSnapshot(String gameId) async {
    final file = File('${_snapshotDir.path}/$gameId.json');
    if (!file.existsSync()) return null;
    try {
      final m = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return PublicGameView(
        gameId: m['gameId'] as String,
        version: m['version'] as int,
        currentRound: m['currentRound'] as int,
        currentPlayerId: m['currentPlayerId'] as String,
        currentPhase: m['currentPhase'] as String,
        characters: (m['characters'] as List)
            .map((c) {
              final cv = c as Map<String, dynamic>;
              return CharacterPublicView(
                characterId: cv['characterId'] as String,
                name: cv['name'] as String,
                currentHp: cv['currentHp'] as int,
                maxHp: cv['maxHp'] as int,
                currentMp: cv['currentMp'] as int,
                maxMp: cv['maxMp'] as int,
                isAlive: cv['isAlive'] as bool,
                statusIds: (cv['statusIds'] as List).cast<String>(),
              );
            })
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}
