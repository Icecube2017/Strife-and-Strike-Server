import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/infrastructure/clock_rng/clock.dart';

Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  final clock = context.read<AppClock>();
  return Response.json(body: {'status': 'ok', 'time': clock.now().toIso8601String()});
}
