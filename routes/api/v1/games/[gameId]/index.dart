import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/game_service.dart';

// GET /games/[gameId] — 获取玩家私有视图（需传 playerId query 参数）
Response onRequest(RequestContext context, String gameId) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final playerId = context.request.uri.queryParameters['playerId'];
  if (playerId == null) {
    return Response.json(statusCode: 400, body: {'error': 'playerId required'});
  }
  try {
    final service = context.read<GameService>();
    final view = service.getPrivateView(gameId, playerId);
    return Response.json(body: view.toJson());
  } on StateError catch (e) {
    return Response.json(statusCode: 404, body: {'error': e.message});
  }
}
