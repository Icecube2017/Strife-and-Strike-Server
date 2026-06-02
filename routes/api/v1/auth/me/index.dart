import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/auth_service.dart';

Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }

  final user = context.read<AuthenticatedUser>();
  return Response.json(body: {'user': user.toView().toJson()});
}
