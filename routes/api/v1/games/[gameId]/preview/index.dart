import 'package:dart_frog/dart_frog.dart';
import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';

Future<Response> onRequest(RequestContext context, String gameId) async {
  final playerId = context.read<AuthenticatedUser>().id.toString();
  final service = context.read<GameService>();
  try {
    await context.read<GameService>().ensureGameLoaded(gameId);
    if (context.request.method == HttpMethod.get) {
      return Response.json(body: service.getPreviewState(gameId, playerId));
    }
    if (context.request.method != HttpMethod.post) {
      return Response(statusCode: 405);
    }
    final body = await context.request.json();
    if (body is! Map<String, dynamic>) {
      throw const FormatException('invalidPreviewRequest');
    }
    if (body['playerId'] != null && body['playerId'] != playerId) {
      return Response.json(
        statusCode: 403,
        body: apiError(StateError('forbidden'), code: 'forbidden'),
      );
    }
    return Response.json(
      body: service.preview(
        gameId,
        PreviewRequest.fromJson(body, playerId: playerId),
      ),
    );
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
    // Branch budget validation uses ArgumentError.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    return Response.json(
      statusCode: 400,
      body: apiError(e),
    );
    // Kernel validation uses StateError; map it to the existing HTTP contract.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(
      statusCode: e.message == 'gameRecoveryFailed' ? 503 : 409,
      body: apiError(e),
    );
  }
}
