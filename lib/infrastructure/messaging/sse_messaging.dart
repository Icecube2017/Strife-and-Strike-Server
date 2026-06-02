import 'dart:async';
import 'dart:convert';

import 'package:sns_server/application/dto/game_dto.dart';

/// SSE 事件推送（Structure.md §3 subscribers）
/// 每个 gameId 持有一组订阅者 StreamController
class SseMessaging {
  final Map<String, List<StreamController<String>>> _subs = {};

  /// 新客户端订阅，返回 SSE 字节流（dart_frog 直接用作 Response body）
  Stream<List<int>> subscribe(String gameId) {
    final ctrl = StreamController<String>();
    (_subs[gameId] ??= []).add(ctrl);
    ctrl.onCancel = () => _subs[gameId]?.remove(ctrl);
    // 将文本事件编码为 UTF-8 字节
    return ctrl.stream.map(utf8.encode);
  }

  /// 向某局游戏的所有订阅者广播状态更新
  void broadcast(String gameId, PublicGameView view) {
    final subs = _subs[gameId];
    if (subs == null || subs.isEmpty) return;
    final data = 'data: ${jsonEncode(view.toJson())}\n\n';
    for (final ctrl in List.of(subs)) {
      if (!ctrl.isClosed) ctrl.add(data);
    }
  }

  /// 游戏结束时关闭所有连接
  void close(String gameId) {
    final subs = _subs.remove(gameId);
    if (subs == null) return;
    for (final ctrl in subs) {
      ctrl.close();
    }
  }
}
