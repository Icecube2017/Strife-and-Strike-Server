import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';

Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final playerId = context.read<AuthenticatedUser>().id.toString();
    final closedRoom = await context.read<GameService>().abortGame(
      gameId,
      playerId,
    );
    return Response.json(
      body: {
        'success': true,
        'gameId': gameId,
        'saved': closedRoom.closeReason == 'completed',
        'termination': {
          'reason': closedRoom.closeReason == 'completed'
              ? 'completed'
              : 'aborted',
          'endedBy': playerId,
        },
        'room': closedRoom.toJson(viewerId: playerId),
      },
    );
    // Lifecycle validation uses StateError, consistent with other game routes.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    final message = e.message;
    final status = message == 'Only the host can abort'
        ? 403
        : message == 'gameRecoveryFailed'
        ? 503
        : message.startsWith('Unknown')
        ? 404
        : 409;
    return Response.json(
      statusCode: status,
      body: apiError(e),
    );
  }
}
