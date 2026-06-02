import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/game_service.dart';

// POST /rooms/[id]/start — 开局
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final service = context.read<GameService>();
    // TODO: 构造牌堆；此处传空列表，后续从 assets 加载
    final gameId = await service.startGame(id, []);
    return Response.json(statusCode: 201, body: {'gameId': gameId});
  } on StateError catch (e) {
    return Response.json(statusCode: 409, body: {'error': e.message});
  }
}
