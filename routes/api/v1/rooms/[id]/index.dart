import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/room_service.dart';

// GET /rooms/[id] — 查询房间信息
Response onRequest(RequestContext context, String id) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  try {
    final service = context.read<RoomService>();
    final players = service.getPlayers(id);
    return Response.json(body: {
      'roomId': id,
      'playerIds': players.map((p) => p.id).toList(),
    });
  } on StateError catch (e) {
    return Response.json(statusCode: 404, body: {'error': e.message});
  }
}
