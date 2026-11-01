import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get &&
      context.request.method != HttpMethod.patch &&
      context.request.method != HttpMethod.delete) {
    return Response(statusCode: 405);
  }
  try {
    final rooms = context.read<RoomService>();
    final user = context.read<AuthenticatedUser>().id.toString();
    if (context.request.method == HttpMethod.delete) {
      final closed = await context.read<GameService>().closeRoom(id, user);
      return Response.json(body: closed.toJson(viewerId: user));
    }
    var view = rooms.getRoom(id, user);
    if (context.request.method == HttpMethod.patch) {
      final body = await context.request.json();
      if (body is! Map<String, dynamic> ||
          body.isEmpty ||
          body.keys.any((k) => !{'rules', 'maxPlayers'}.contains(k))) {
        throw const FormatException('Expected rules and/or maxPlayers');
      }
      final max = body['maxPlayers'];
      if (max != null && max is! int) {
        throw const FormatException('maxPlayers must be integer');
      }
      final rawRules = body['rules'];
      if (body.containsKey('rules') && rawRules is! Map<String, dynamic>) {
        throw const FormatException('rules must be object');
      }
      view = await rooms.updateSettings(
        id,
        user,
        maxPlayers: max as int?,
        ruleChanges: rawRules as Map<String, dynamic>?,
      );
    }
    return Response.json(body: view.toJson(viewerId: user));
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
    // Room validation uses StateError.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    final status = context.request.method != HttpMethod.delete
        ? 409
        : e.message == 'Only the host can close'
        ? 403
        : e.message.startsWith('Unknown')
        ? 404
        : 409;
    return Response.json(statusCode: status, body: apiError(e));
  }
}
