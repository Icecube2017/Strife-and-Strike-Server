import 'dart:async';
import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/game_service.dart';

// GET /games/[gameId]/events — SSE 事件流（Structure.md §4）
Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  try {
    final service = context.read<GameService>();
    final current = service.getState(gameId);

    final ctrl = StreamController<List<int>>()
    // 立即推送当前完整状态
    ..add(utf8.encode('data: ${jsonEncode(current.toJson())}\n\n'));
    // 订阅后续增量更新
    service.subscribe(gameId).listen(
      (view) => ctrl.add(utf8.encode('data: ${jsonEncode(view.toJson())}\n\n')),
      onDone: ctrl.close,
      onError: (_) => ctrl.close(),
    );

    return Response.stream(
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
      body: ctrl.stream,
      bufferOutput: false,
    );
  } on StateError catch (e) {
    return Response.json(statusCode: 404, body: {'error': e.message});
  }
}
