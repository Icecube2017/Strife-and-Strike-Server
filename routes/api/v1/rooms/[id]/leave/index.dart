import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final playerId = context.read<AuthenticatedUser>().id.toString();
    await context.read<RoomService>().leaveRoom(
      id,
      playerId,
      validateFinished: (gameId) async {
        final games = context.read<GameService>();
        await games.requireFinishedGame(gameId);
      },
    );
    return Response.json(body: {'leftRoom': true});
    // Validation failures do not remove membership.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(
      statusCode: e.message == 'hostCannotLeaveRoom'
          ? 403
          : e.message.startsWith('Unknown')
          ? 404
          : 409,
      body: apiError(e),
    );
  }
}
