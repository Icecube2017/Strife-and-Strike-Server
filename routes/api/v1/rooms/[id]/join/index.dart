import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final body = await context.request.json();
    if (body is! Map<String, dynamic>) {
      throw const FormatException('Expected an object');
    }
    if (body.isNotEmpty) {
      throw const FormatException(
        'Joining does not select a character or team',
      );
    }
    final user = context.read<AuthenticatedUser>();
    final response = await context.read<RoomService>().joinRoom(
      id,
      JoinRoomRequest(
        playerId: user.id.toString(),
        playerName: user.displayName,
      ),
    );
    return Response.json(body: response.toJson(viewerId: user.id.toString()));
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
    // Room validation uses StateError.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(statusCode: 409, body: apiError(e));
  }
}
