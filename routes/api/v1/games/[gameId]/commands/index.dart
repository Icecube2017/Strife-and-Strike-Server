import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/commands/kernel_command_request.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';

Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final body = await context.request.json();
    if (body is! Map<String, dynamic>) {
      throw const FormatException('Expected an object');
    }
    final request = KernelCommandRequest.fromJson(
      body,
      playerId: context.read<AuthenticatedUser>().id.toString(),
    );
    await context.read<GameService>().ensureGameLoaded(gameId);
    final version = await context.read<GameService>().handleCommandPersisted(
      gameId,
      request,
    );
    return Response.json(body: {'success': true, 'newVersion': version});
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
    // Kernel contracts use StateError for rejected transitions.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(
      statusCode: e.message == 'gameRecoveryFailed' ? 503 : 409,
      body: apiError(e),
    );
  }
}
