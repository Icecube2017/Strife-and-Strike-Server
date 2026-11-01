import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/dto/user_dto.dart';
import 'package:sns_server/application/services/auth_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  try {
    final body = await context.request.json() as Map<String, dynamic>;
    final request = RegisterUserRequest.fromJson(body);
    final response = await context.read<AuthService>().register(request);
    return Response.json(statusCode: 201, body: response.toJson());
  } on AuthException catch (e) {
    return Response.json(
      statusCode: e.statusCode,
      body: apiError(
        e,
        code: e.statusCode == 401
            ? 'authenticationFailed'
            : 'authenticationRejected',
      ),
    );
  } on Object {
    return Response.json(
      statusCode: 400,
      body: apiError(const FormatException('invalidRequest')),
    );
  }
}
