import 'dart:async';
import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/room_service.dart';

Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  RoomConnection? connection;
  try {
    final rooms = context.read<RoomService>();
    final user = context.read<AuthenticatedUser>().id.toString();
    connection = await rooms.connect(id, user);
    final connected = connection;
    final current = rooms.getRoom(id, user);
    final stream = rooms.subscribe(id, user);
    StreamSubscription<Object?>? sub;
    Timer? heartbeat;
    final controller =
        StreamController<List<int>>(
          onCancel: () async {
            heartbeat?.cancel();
            await sub?.cancel();
            await connected.close();
          },
        )..add(
          utf8.encode(
            'data: ${jsonEncode(current.toJson(viewerId: user))}\n\n',
          ),
        );
    sub = stream.listen(
      (view) => controller.add(
        utf8.encode('data: ${jsonEncode(view.toJson(viewerId: user))}\n\n'),
      ),
      onDone: () {
        heartbeat?.cancel();
        unawaited(connected.close());
        unawaited(controller.close());
      },
      onError: (Object _) {
        heartbeat?.cancel();
        unawaited(connected.close());
        unawaited(controller.close());
      },
    );
    heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!controller.isClosed) {
        controller.add(utf8.encode(': heartbeat\n\n'));
      }
    });
    return Response.stream(
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Accel-Buffering': 'no',
      },
      body: controller.stream,
      bufferOutput: false,
    );
    // Room validation uses StateError.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    await connection?.close();
    return Response.json(statusCode: 404, body: apiError(e));
  } catch (_) {
    await connection?.close();
    rethrow;
  }
}
