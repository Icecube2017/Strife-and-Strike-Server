import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/room_service.dart';

// POST /rooms/[id]/ready
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final service = context.read<RoomService>();
    final players = service.getPlayers(id);
    return Response.json(body: {
      'roomId': id,
      'playerCount': players.length,
      'ready': true,
    });
  } on StateError catch (e) {
    return Response.json(statusCode: 404, body: {'error': e.message});
  }
}
