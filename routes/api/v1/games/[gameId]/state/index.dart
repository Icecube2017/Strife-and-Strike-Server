import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/infrastructure/cache/game_cache.dart';

// GET /games/[gameId]/state?sinceVersion=N
Response onRequest(RequestContext context, String gameId) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  try {
    final sinceParam = context.request.uri.queryParameters['sinceVersion'];
    final sinceVersion = sinceParam != null ? int.tryParse(sinceParam) : null;

    // 优先从缓存快照响应
    if (sinceVersion != null) {
      final cache = context.read<GameCache>();
      final cached = cache.getSnapshotSince(gameId, sinceVersion);
      if (cached != null) return Response.json(body: cached.toJson());
    }

    final service = context.read<GameService>();
    final view = service.getState(gameId);
    return Response.json(body: view.toJson());
  } on StateError catch (e) {
    return Response.json(statusCode: 404, body: {'error': e.message});
  }
}
