import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/content/client_content.dart';

Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: 405);
  }
  return Response.json(body: context.read<ClientContent>().json);
}
