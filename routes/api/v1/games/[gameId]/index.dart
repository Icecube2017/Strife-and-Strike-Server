import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';

Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final playerId = context.read<AuthenticatedUser>().id.toString();
  final requested = context.request.uri.queryParameters['playerId'];
  if (requested != null && requested != playerId) {
    return Response.json(
      statusCode: 403,
      body: apiError(StateError('forbidden'), code: 'forbidden'),
    );
  }
  try {
    await context.read<GameService>().ensureGameLoaded(gameId);
    return Response.json(
      body: context.read<GameService>().getPrivateView(gameId, playerId),
    );
    // Kernel contracts use StateError for rejected transitions.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(
      statusCode: e.message == 'gameRecoveryFailed' ? 503 : 404,
      body: apiError(e),
    );
  }
}
