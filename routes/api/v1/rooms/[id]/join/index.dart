import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/domain/class/character.dart';

// POST /rooms/[id]/join
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final body = await context.request.json() as Map<String, dynamic>;
    final req = JoinRoomRequest.fromJson(body);
    final characterId = body['characterId'] as String? ?? 'empty';

    final service = context.read<RoomService>();
    final character = CharacterFactoryCreated(characterId, characterId, 'balanced', 'human', {}, [], []);
    final resp = await service.joinRoom(id, req, character);
    return Response.json(body: resp.toJson());
  } on StateError catch (e) {
    return Response.json(statusCode: 409, body: {'error': e.message});
  }
}
