import 'dart:async';
import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context, String gameId) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  RoomConnection? connection;
  try {
    await context.read<GameService>().ensureGameLoaded(gameId);
    final service = context.read<GameService>();
    final private = context.request.uri.queryParameters['private'] == 'true';
    final authenticatedId = context.read<AuthenticatedUser>().id.toString();
    final playerId = private ? authenticatedId : null;
    var current = playerId == null
        ? service.getState(gameId)
        : service.getPlayerState(gameId, playerId);
    if (current['outcome'] == null) {
      connection = await service.connectGamePlayer(gameId, authenticatedId);
      // Presence persistence yields. Capture a fresh state afterwards, then
      // attach synchronously so no committed update is lost in that gap.
      current = playerId == null
          ? service.getState(gameId)
          : service.getPlayerState(gameId, playerId);
    }
    final stream = playerId == null
        ? service.subscribe(gameId)
        : service.subscribeForPlayer(gameId, playerId);
    final connected = connection;
    StreamSubscription<Map<String, Object?>>? subscription;
    Timer? heartbeat;
    final ctrl = StreamController<List<int>>(
      onCancel: () async {
        heartbeat?.cancel();
        await subscription?.cancel();
        await connected?.close();
      },
    )..add(utf8.encode('data: ${jsonEncode(current)}\n\n'));
    if (current['outcome'] != null) {
      unawaited(ctrl.close());
    } else {
      subscription = stream.listen(
        (view) => ctrl.add(utf8.encode('data: ${jsonEncode(view)}\n\n')),
        onDone: () {
          heartbeat?.cancel();
          if (connected != null) unawaited(connected.close());
          unawaited(ctrl.close());
        },
        onError: (Object _) {
          heartbeat?.cancel();
          if (connected != null) unawaited(connected.close());
          unawaited(ctrl.close());
        },
      );
      heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!ctrl.isClosed) ctrl.add(utf8.encode(': heartbeat\n\n'));
      });
    }
    return Response.stream(
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Accel-Buffering': 'no',
        'Connection': 'keep-alive',
      },
      body: ctrl.stream,
      bufferOutput: false,
    );
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    await connection?.close();
    return Response.json(
      statusCode: e.message == 'gameRecoveryFailed' ? 503 : 404,
      body: apiError(e),
    );
  } catch (_) {
    await connection?.close();
    rethrow;
  }
}
