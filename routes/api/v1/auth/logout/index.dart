import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/user_dto.dart';
import 'package:sns_server/application/services/auth_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  try {
    final body = await context.request.json() as Map<String, dynamic>;
    final request = RefreshTokenRequest.fromJson(body);
    await context.read<AuthService>().logout(request);
    return Response.json(body: {'success': true});
  } on AuthException catch (e) {
    return Response.json(statusCode: e.statusCode, body: {'error': e.message});
  } on Object {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Invalid logout request'},
    );
  }
}
