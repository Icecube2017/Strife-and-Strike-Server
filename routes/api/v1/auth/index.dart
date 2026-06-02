import 'package:dart_frog/dart_frog.dart';

// TODO: 实现真实鉴权（JWT签发/验证）
// 目前仅返回一个固定 token 供开发调试
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: 405);
  }
  final body = await context.request.json() as Map<String, dynamic>;
  final playerId = body['playerId'] as String?;
  if (playerId == null || playerId.isEmpty) {
    return Response.json(statusCode: 400, body: {'error': 'playerId required'});
  }
  return Response.json(body: {'token': 'dev.$playerId'});
}
