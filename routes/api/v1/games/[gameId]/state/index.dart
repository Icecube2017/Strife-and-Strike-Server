import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/game_service.dart';

Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  try {
    await context.read<GameService>().ensureGameLoaded(gameId);
    // Always use the authoritative current kernel view, never legacy snapshots.
    return Response.json(body: context.read<GameService>().getState(gameId));
    // Kernel contracts use StateError for rejected transitions.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(
      statusCode: e.message == 'gameRecoveryFailed' ? 503 : 404,
      body: apiError(e),
    );
  }
}
