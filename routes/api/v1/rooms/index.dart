import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/application/dto/room_rules.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final body = await context.request.json();
    if (body is! Map<String, dynamic>) {
      throw const FormatException('Expected an object');
    }
    if (body.containsKey('characterId')) {
      throw const FormatException(
        'Choose a character during the selection phase',
      );
    }
    final maxPlayers = body['maxPlayers'] ?? 4;
    if (maxPlayers is! int) {
      throw const FormatException('maxPlayers must be integer');
    }
    final user = context.read<AuthenticatedUser>();
    final response = await context.read<RoomService>().createRoom(
      CreateRoomRequest(
        hostPlayerId: user.id.toString(),
        hostPlayerName: user.displayName,
        maxPlayers: maxPlayers,
        rules: RoomRules.fromJson(body['rules']),
      ),
    );
    return Response.json(
      statusCode: 201,
      body: response.toJson(viewerId: user.id.toString()),
    );
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
    // Room validation uses StateError.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(statusCode: 409, body: apiError(e));
  }
}
