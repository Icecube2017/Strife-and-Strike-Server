import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  final method = context.request.method;
  if (method != HttpMethod.put && method != HttpMethod.delete) {
    return Response(statusCode: 405);
  }
  try {
    final user = context.read<AuthenticatedUser>();
    final viewerId = user.id.toString();
    final rooms = context.read<RoomService>();
    if (method == HttpMethod.delete) {
      await rooms.leaveSpectating(id, viewerId);
      return Response.json(body: {'leftRoom': true});
    }
    final body = await context.request.json();
    if (body is! Map<String, dynamic> ||
        body.length != 1 ||
        body['spectating'] is! bool) {
      throw const FormatException('Expected spectating boolean');
    }
    final view = await rooms.setSpectating(
      id,
      JoinRoomRequest(playerId: viewerId, playerName: user.displayName),
      spectating: body['spectating'] as bool,
    );
    return Response.json(body: view.toJson(viewerId: viewerId));
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: apiError(e));
    // Room validation uses StateError.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    return Response.json(statusCode: 409, body: apiError(e));
  }
}
