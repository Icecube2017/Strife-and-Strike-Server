import '../commands.dart';
import '../recovery_codec.dart';

Object? _immutable(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final e in value.entries) e.key as String: _immutable(e.value),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_immutable));
  return value;
}

final class AiCandidate {
  AiCandidate(
    this.command, {
    this.adapterAction,
    Map<String, Object?> features = const {},
  }) : features = _immutable(features)! as Map<String, Object?>;
  final KernelCommand? command;
  final String? adapterAction;
  final Map<String, Object?> features;
  String get kind =>
      adapterAction ??
      (command == null
          ? 'yield'
          : KernelRecoveryCodec.command(command!)['type']! as String);
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (command != null) 'command': KernelRecoveryCodec.command(command!),
    'features': features,
  };
}

final class AiDecision {
  AiDecision({
    required this.decisionId,
    required this.gameVersion,
    required this.actorId,
    required this.phase,
    required Map<String, Object?> observation,
    required List<AiCandidate> candidates,
  }) : candidates = List.unmodifiable(candidates),
       observation = _immutable(observation)! as Map<String, Object?>;
  AiDecision.reidentified(AiDecision source, this.decisionId)
    : gameVersion = source.gameVersion,
      actorId = source.actorId,
      phase = source.phase,
      observation = source.observation,
      candidates = source.candidates;
  final String decisionId, actorId, phase;
  final int gameVersion;
  final Map<String, Object?> observation;
  final List<AiCandidate> candidates;

  /// Paging preserves every candidate; it is not an action-space truncation.
  Map<String, Object?> toJson({int offset = 0, int capacity = 64}) {
    if (offset < 0 ||
        offset > candidates.length ||
        capacity < 1 ||
        capacity > 4096) {
      throw RangeError('Invalid candidate page');
    }
    final page = candidates.skip(offset).take(capacity).toList();
    return {
      'observationSchema': 1,
      'actionSchema': 1,
      'decisionId': decisionId,
      'gameVersion': gameVersion,
      'actorId': actorId,
      'phase': phase,
      'requiredCapabilities':
          candidates.map((c) => '${c.kind}.v1').toSet().toList()..sort(),
      'observation': observation,
      'candidateOffset': offset,
      'candidateCount': candidates.length,
      'candidates': [for (final c in page) c.toJson()],
      'actionMask': [for (final _ in page) true],
      'nextOffset': offset + page.length < candidates.length
          ? offset + page.length
          : null,
    };
  }
}

final class AiCoverageError implements Exception {
  const AiCoverageError(this.reason);
  final String reason;
  @override
  String toString() => 'AiCoverageError: $reason';
}

Iterable<List<T>> aiSelections<T>(
  List<T> items,
  int minimum,
  int maximum, {
  bool ordered = false,
}) sync* {
  if (minimum == 0) yield <T>[];
  Iterable<List<T>> visit(
    List<T> selected,
    List<int> indices,
    int start,
  ) sync* {
    if (selected.length >= maximum) return;
    for (var i = ordered ? 0 : start; i < items.length; i++) {
      if (indices.contains(i)) continue;
      final next = [...selected, items[i]];
      if (next.length >= minimum) yield next;
      yield* visit(next, [...indices, i], i + 1);
    }
  }

  yield* visit(<T>[], [], 0);
}
