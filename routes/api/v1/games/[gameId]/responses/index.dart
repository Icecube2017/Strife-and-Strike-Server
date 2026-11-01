import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';

/// Private options are derived for the authenticated player, never a query ID.
Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  try {
    await context.read<GameService>().ensureGameLoaded(gameId);
    final playerId = context.read<AuthenticatedUser>().id.toString();
    final view = context.read<GameService>().getPrivateView(gameId, playerId);
    return Response.json(
      body: {
        'version': view['version'],
        'serverTime': view['serverTime'],
        'responseWindow': view['responseWindow'],
      },
    );
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(
      statusCode: e.message == 'gameRecoveryFailed' ? 503 : 404,
      body: apiError(e),
    );
  }
}
