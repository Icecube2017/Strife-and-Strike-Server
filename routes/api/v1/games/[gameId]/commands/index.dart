import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/commands/game_command.dart';
import 'package:sns_server/application/dto/game_dto.dart';
import 'package:sns_server/application/services/game_service.dart';

// POST /games/[gameId]/commands — 提交动作命令
Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  try {
    final body = await context.request.json() as Map<String, dynamic>;
    final req = GameCommandRequest.fromJson(body);
    final cmd = parseGameCommand(
      commandId: req.commandId,
      playerId: req.playerId,
      clientVersion: req.clientVersion,
      actionType: req.actionType,
      payload: req.payload,
    );
    final service = context.read<GameService>();
    final result = await service.handleCommand(gameId, cmd);
    final statusCode = result.success ? 200 : 409;
    return Response.json(statusCode: statusCode, body: result.toJson());
  } on StateError catch (e) {
    return Response.json(statusCode: 400, body: {'error': e.message});
  } on FormatException catch (e) {
    return Response.json(statusCode: 400, body: {'error': e.message});
  }
}
