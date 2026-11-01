import 'package:dart_frog/dart_frog.dart';

/// Draft confirmation replaces the old placeholder ready endpoint.
Response onRequest(RequestContext context, String id) =>
    Response(statusCode: 405);
