import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/application/content/client_protocol.dart';

/// The same validated executable definitions loaded by the running server.
/// Contains definitions only, never live game state or credentials.
final class ClientContent {
  ClientContent(String source, {String? deckId})
    : json = {
        'protocol': clientProtocol,
        'contentSchemaVersion': clientContentSchemaVersion,
        'requiredFeatures': requiredClientFeatures,
        if (deckId != null) 'deckId': deckId,
        'content': clientExecutionContent(source),
      };
  final Map<String, Object?> json;
}
