import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/development/ai/arena.dart';
import 'package:sns_server/development/ai/policies.dart';
import 'package:sns_server/development/ai/rating_feedback.dart';

/// One learner; all other decisions use isolated fixed-policy state.
final class AiLearnerSession {
  AiLearnerSession(
    this.arena,
    this.learnerId, {
    String opponent = 'rules',
    int policySeed = 1,
    this.ratingFeedback = false,
  }) {
    if (!arena.game.state.players.any((p) => p.id == learnerId)) {
      throw const FormatException('Unknown learner player');
    }
    for (final player in arena.game.state.players.where(
      (p) => p.id != learnerId,
    )) {
      final seed =
          policySeed + player.id.codeUnits.fold<int>(0, (a, b) => a + b);
      opponents[player.id] = switch (opponent) {
        'rules' => AiRulePolicy(seed),
        'random' => AiRandomPolicy(seed),
        _ => throw const FormatException('Unknown opponent policy'),
      };
    }
  }
  AiLearnerSession.restore(this.arena, Map<String, dynamic> saved)
    : learnerId = saved['learnerId']! as String,
      ratingFeedback = saved['ratingFeedback'] as bool? ?? false {
    if (saved['sessionVersion'] != 1) {
      throw const FormatException('Unsupported learner session');
    }
    for (final e in (saved['opponents']! as Map).entries) {
      opponents[e.key as String] = restoreAiPolicy(
        Map<String, dynamic>.from(e.value as Map),
      );
    }
    opponentDecisions = saved['opponentDecisions']! as int;
  }
  final AiArena arena;
  final String learnerId;
  final bool ratingFeedback;
  int _ratingVersion = -1;
  Map<String, Object?>? _rating;
  int ratingMicroseconds = 0;
  final Map<String, AiPolicy> opponents = {};
  int opponentDecisions = 0;
  int driverMicroseconds = 0;

  void advance({int? maximumDecisions}) {
    if (maximumDecisions != null && maximumDecisions < 1) {
      throw RangeError('Advance budget must be positive');
    }
    var advanced = 0;
    final timer = Stopwatch()..start();
    try {
      while (!arena.game.state.finished && arena.truncatedReason == null) {
        if (maximumDecisions != null && advanced >= maximumDecisions) break;
        final d = arena.decision();
        if (d == null || d.actorId == learnerId) break;
        final policy = opponents[d.actorId];
        if (policy == null) throw StateError('Missing opponent policy');
        final selected = policy.select(d);
        arena.step(d.decisionId, selected.index);
        opponentDecisions++;
        advanced++;
      }
    } catch (error, stack) {
      fail(error, stack);
    }
    driverMicroseconds += timer.elapsedMicroseconds;
  }

  void fail(Object error, StackTrace stack) {
    arena.truncatedReason = 'technicalFailure';
    arena.failure = error;
    arena.failureStack = '$stack';
  }

  void step(String decisionId, int index, {int? maximumOpponentDecisions}) {
    final d = arena.decision();
    if (d == null ||
        d.actorId != learnerId ||
        d.decisionId != decisionId ||
        index < 0 ||
        index >= d.candidates.length) {
      throw StateError('Invalid learner decision or candidate');
    }
    try {
      arena.step(decisionId, index);
    } catch (error, stack) {
      fail(error, stack);
    }
    advance(maximumDecisions: maximumOpponentDecisions);
  }

  Map<String, Object?> frame({int offset = 0, int capacity = 64}) {
    final d = arena.decision();
    if (d != null && d.actorId != learnerId) {
      return {
        'advancing': true,
        'terminated': false,
        'truncated': false,
        'reason': null,
        'metrics': {
          'kernelCommands': arena.commandCount,
          'decisions': arena.decisionCount,
          'opponentDecisions': opponentDecisions,
        },
      };
    }
    final terminated =
        arena.game.state.finished && arena.truncatedReason == null;
    final decision = d?.toJson(offset: offset, capacity: capacity);
    decision?.remove('observation');
    if (ratingFeedback && _ratingVersion != arena.game.state.version) {
      final timer = Stopwatch()..start();
      _rating = aiRatingFeedback(arena.game, learnerId);
      ratingMicroseconds += timer.elapsedMicroseconds;
      _ratingVersion = arena.game.state.version;
    }
    return {
      'terminated': terminated,
      'truncated': arena.truncatedReason != null,
      'reason': arena.truncatedReason,
      'outcome': terminated ? arena.game.publicView()['outcome'] : null,
      'learnerId': learnerId,
      'learnerTeamId': arena.game.state.players
          .singleWhere((p) => p.id == learnerId)
          .teamId,
      'learnerObservation':
          d?.observation ?? arena.game.aiObservation(learnerId),
      'decision': decision,
      if (ratingFeedback) 'trainingFeedback': _rating,
      'metrics': {
        'kernelCommands': arena.commandCount,
        'decisions': arena.decisionCount,
        'opponentDecisions': opponentDecisions,
        'driverMicroseconds': driverMicroseconds,
        'ratingMicroseconds': ratingMicroseconds,
      },
    };
  }

  Map<String, Object?> checkpoint() => {
    'sessionVersion': 1,
    'learnerId': learnerId,
    'ratingFeedback': ratingFeedback,
    'opponentDecisions': opponentDecisions,
    'opponents': {
      for (final e in opponents.entries) e.key: e.value.checkpoint(),
    },
  };
}
