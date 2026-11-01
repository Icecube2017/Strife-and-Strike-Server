import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context) async {
  final user = context.read<AuthenticatedUser>();
  if (context.request.method == HttpMethod.get) {
    return Response.json(body: {'user': user.toView().toJson()});
  }
  if (context.request.method != HttpMethod.patch) {
    return Response(statusCode: 405);
  }
  try {
    final body = await context.request.json();
    if (body is! Map<String, dynamic>) {
      throw const FormatException('invalidRequest');
    }
    final view = await context.read<AuthService>().updateNickname(
      user.id,
      body['nickname'],
    );
    await context.read<RoomService>().renamePlayer(
      user.id.toString(),
      view.nickname ?? view.username,
    );
    return Response.json(body: {'user': view.toJson()});
  } on AuthException catch (e) {
    return Response.json(
      statusCode: e.statusCode,
      body: apiError(e, code: 'invalidNickname'),
    );
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
  }
}
