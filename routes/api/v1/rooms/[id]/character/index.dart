import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final user = context.read<AuthenticatedUser>().id.toString();
    final body = await context.request.json();
    if (body is! Map<String, dynamic> ||
        body['characterId'] is! String ||
        body.keys.any((k) => k != 'characterId')) {
      throw const FormatException('Invalid request body');
    }
    final view = await context.read<GameService>().confirmCharacter(
      id,
      user,
      body['characterId'] as String,
    );
    return Response.json(body: view.toJson(viewerId: user));
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
    // Room validation uses StateError.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(statusCode: 409, body: apiError(e));
  }
}
