import 'dart:convert';
import 'dart:io';

import 'package:sns_server/development/ai/ai.dart';
import 'package:sns_server/development/ai/io.dart';

/// Persistent development protocol; stdout contains JSONL only.
Future<void> main(List<String> arguments) async {
  String option(String key, String fallback) {
    final i = arguments.indexOf('--$key');
    return i >= 0 && i + 1 < arguments.length ? arguments[i + 1] : fallback;
  }

  try {
    final scenarios = loadAiScenarios(
      option('scenario-set', 'ai/scenarios/full-match'),
      option('content', 'content/content_items.json'),
    );
    AiArena? arena;
    AiLearnerSession? session;
    var serializationMicroseconds = 0;
    var dispatchMicroseconds = 0;
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      Object? requestId;
      try {
        final request = jsonDecode(line) as Map<String, dynamic>;
        requestId = request['requestId'];
        final capacity = request['capacity'] as int? ?? 64;
        final offset = request['offset'] as int? ?? 0;
        final advanceBudget = request['advanceBudget'] as int?;
        if (advanceBudget != null &&
            (advanceBudget < 1 || advanceBudget > 4096)) {
          throw RangeError('Invalid automatic advance budget');
        }
        if (capacity < 1 || capacity > 4096 || offset < 0) {
          throw RangeError('Invalid candidate page');
        }
        final dispatch = Stopwatch()..start();
        Map<String, Object?> response;
        switch (request['method']) {
          case 'listScenarios':
            response = {'scenarios': scenarios.map((s) => s.id).toList()};
          case 'reset':
            final scenario = scenarios.singleWhere(
              (s) => s.id == request['scenarioId'],
            );
            arena = AiArena(
              scenario,
              seed: request['seed'] as int? ?? 1,
              maximumDecisions: request['maximumDecisions'] as int? ?? 10000,
            );
            session = request['learnerId'] is String
                ? AiLearnerSession(
                    arena,
                    request['learnerId']! as String,
                    opponent: request['opponent'] as String? ?? 'rules',
                    policySeed: request['policySeed'] as int? ?? 1,
                    ratingFeedback: request['ratingFeedback'] as bool? ?? false,
                  )
                : null;
            session?.advance(maximumDecisions: advanceBudget);
            response =
                session?.frame(capacity: capacity) ??
                _state(arena, capacity: capacity);
          case 'step':
            if (arena == null) throw StateError('Call reset first');
            if (session != null) {
              session.step(
                request['decisionId']! as String,
                request['candidateIndex']! as int,
                maximumOpponentDecisions: advanceBudget,
              );
            } else {
              arena.step(
                request['decisionId']! as String,
                request['candidateIndex']! as int,
              );
            }
            response =
                session?.frame(capacity: capacity) ??
                _state(arena, capacity: capacity);
          case 'advance':
            if (session == null) {
              throw StateError('Call reset with a learner first');
            }
            session.advance(maximumDecisions: advanceBudget);
            response = session.frame(capacity: capacity);
          case 'decision':
            if (arena == null) throw StateError('Call reset first');
            response =
                session?.frame(offset: offset, capacity: capacity) ??
                _state(arena, offset: offset, capacity: capacity);
          case 'checkpoint':
            if (arena == null) throw StateError('Call reset first');
            response = {
              'scenarioId': arena.scenario.id,
              'checkpoint': arena.checkpoint(),
              if (session != null) 'session': session.checkpoint(),
            };
          case 'restore':
            final scenario = scenarios.singleWhere(
              (s) => s.id == request['scenarioId'],
            );
            arena = AiArena.restore(
              scenario,
              Map<String, dynamic>.from(request['checkpoint'] as Map),
            );
            session = request['session'] is Map
                ? AiLearnerSession.restore(
                    arena,
                    Map<String, dynamic>.from(request['session'] as Map),
                  )
                : null;
            response =
                session?.frame(offset: offset, capacity: capacity) ??
                _state(arena, offset: offset, capacity: capacity);
          case 'failureCase':
            if (arena == null) throw StateError('Call reset first');
            response = arena.failureCase();
          case 'metrics':
            response = {
              'currentRss': ProcessInfo.currentRss,
              'maxRss': ProcessInfo.maxRss,
              'dartVersion': Platform.version,
              if (arena != null)
                'candidateGenerationMicroseconds': arena.decisionMicroseconds,
              'serializationMicroseconds': serializationMicroseconds,
              'dispatchMicroseconds': dispatchMicroseconds,
            };
          default:
            throw const FormatException('Unknown method');
        }
        dispatchMicroseconds += dispatch.elapsedMicroseconds;
        final encoding = Stopwatch()..start();
        final output = jsonEncode({
          'requestId': requestId,
          'ok': true,
          'backendPid': pid,
          ...response,
        });
        serializationMicroseconds += encoding.elapsedMicroseconds;
        stdout.writeln(output);
      } catch (error) {
        stdout.writeln(
          jsonEncode({'requestId': requestId, 'ok': false, 'error': '$error'}),
        );
      }
    }
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}

Map<String, Object?> _state(
  AiArena arena, {
  int offset = 0,
  int capacity = 64,
}) {
  final decision = arena.decision();
  return {
    'terminated': arena.game.state.finished,
    'truncated': arena.truncatedReason != null,
    'reason': arena.truncatedReason,
    'outcome': arena.game.publicView()['outcome'],
    'decision': decision?.toJson(offset: offset, capacity: capacity),
  };
}
