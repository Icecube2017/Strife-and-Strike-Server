import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/dto/user_dto.dart';
import 'package:sns_server/application/services/auth_service.dart';

// POST /auth - 兼容登录入口；推荐使用 POST /auth/login。
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    return Response.json(
      body: {
        'endpoints': {
          'register': 'POST /api/v1/auth/register',
          'login': 'POST /api/v1/auth/login',
          'refresh': 'POST /api/v1/auth/refresh',
          'logout': 'POST /api/v1/auth/logout',
          'me': 'GET /api/v1/auth/me',
        },
      },
    );
  }

  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }

  try {
    final body = await context.request.json() as Map<String, dynamic>;
    final request = LoginUserRequest.fromJson(body);
    final response = await context.read<AuthService>().login(request);
    return Response.json(body: response.toJson());
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
