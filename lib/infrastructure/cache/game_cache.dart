import 'dart:convert';

import 'package:sns_server/application/dto/game_dto.dart';
import 'package:sns_server/application/services/game_service.dart';

/// 内存缓存：存储 GameRuntime 引用和状态快照
/// MVP阶段纯内存，后续可替换为 Redis 实现
class GameCache {
  final Map<String, GameRuntime> _runtimes = {};
  // gameId -> (version -> snapshot JSON)
  final Map<String, Map<int, String>> _snapshots = {};

  void putRuntime(String gameId, GameRuntime runtime) {
    _runtimes[gameId] = runtime;
  }

  GameRuntime? getRuntime(String gameId) => _runtimes[gameId];

  void removeRuntime(String gameId) {
    _runtimes.remove(gameId);
    _snapshots.remove(gameId);
  }

  /// 保存当前公开视图快照（周期性调用）
  void snapshot(String gameId) {
    final runtime = _runtimes[gameId];
    if (runtime == null) return;
    final view = runtime.getPublicView();
    (_snapshots[gameId] ??= {})[view.version] = jsonEncode(view.toJson());
  }

  /// 获取 >= sinceVersion 的最近快照；找不到则返回 null
  PublicGameView? getSnapshotSince(String gameId, int sinceVersion) {
    final snaps = _snapshots[gameId];
    if (snaps == null) return null;
    // 找最小的 version >= sinceVersion
    final keys = snaps.keys.where((v) => v >= sinceVersion).toList()..sort();
    if (keys.isEmpty) return null;
    return _decodeView(snaps[keys.first]!);
  }

  PublicGameView? _decodeView(String json) {
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      return PublicGameView(
        gameId: m['gameId'] as String,
        version: m['version'] as int,
        currentRound: m['currentRound'] as int,
        currentPlayerId: m['currentPlayerId'] as String,
        currentPhase: m['currentPhase'] as String,
        characters: (m['characters'] as List)
            .map((c) => _decodeCharView(c as Map<String, dynamic>))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  CharacterPublicView _decodeCharView(Map<String, dynamic> m) =>
      CharacterPublicView(
        characterId: m['characterId'] as String,
        name: m['name'] as String,
        currentHp: m['currentHp'] as int,
        maxHp: m['maxHp'] as int,
        currentMp: m['currentMp'] as int,
        maxMp: m['maxMp'] as int,
        isAlive: m['isAlive'] as bool,
        statusIds: (m['statusIds'] as List).cast<String>(),
      );
}
