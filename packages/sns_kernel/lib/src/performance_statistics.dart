import 'definitions.dart';
import 'state.dart';

/// An observer only. These provisional scores never participate in game rules,
/// RNG, event journals, command validation, or victory determination.
final class PerformanceStatistics {
  final Map<String, String> _teams = {};
  final Map<String, Map<String, int>> _resources = {};
  final Map<String, Map<String, int>> _support = {};
  final Map<String, (int, int)> _deaths = {};
  final Set<int> _seen = {};
  int? _start;
  int? _end;

  void record(KernelEvent event, KernelState state) {
    if (!_seen.add(event.sequence)) return;
    for (final p in state.players) {
      final id = p.character.instanceId;
      _teams[id] = p.teamId;
      _resources.putIfAbsent(id, () => {'mpSpent': 0, 'cardsPlayed': 0});
      _support.putIfAbsent(id, () => {'control': 0, 'enhancement': 0});
    }
    final d = event.data;
    if (event.type == 'gameStarted') _start = event.sequence;
    if (event.type == 'gameFinished') _end = event.sequence;
    if (event.type == 'characterDied') {
      _deaths.putIfAbsent(
        d['instanceId']! as String,
        () => (event.round, event.sequence),
      );
    }
    if (event.type == 'mpSpent') {
      _add(
        _resources,
        d['actorId'] as String?,
        'mpSpent',
        d['amount'] as int? ?? 0,
      );
    }
    if (event.type == 'cardsPlayed') {
      _add(
        _resources,
        d['actorId'] as String?,
        'cardsPlayed',
        d['handLossCount'] as int? ?? 0,
      );
    }
  }

  void _add(
    Map<String, Map<String, int>> into,
    String? source,
    String key,
    int amount,
  ) {
    if (source == null || amount <= 0) return;
    final bucket = into.putIfAbsent(source, () => {});
    bucket.update(key, (old) => old + amount, ifAbsent: () => amount);
  }

  bool _allies(String source, String target) =>
      _teams.containsKey(source) && _teams[source] == _teams[target];

  int _statusValue(StatusDefinition status, int stacks, int intensity) {
    if (stacks <= 0) return 0;
    if (status.id.startsWith('decree_')) return 4;
    if (status.category == StatusCategory.anomaly ||
        status.id == 'mental_action_lock') {
      return 5;
    }
    return status.hasIntensity ? stacks + intensity : stacks * 3;
  }

  void statusChange(
    CharacterInstance source,
    CharacterInstance target,
    StatusDefinition status,
    int oldStacks,
    int oldIntensity,
    int stacks,
    int intensity,
  ) {
    final before = _statusValue(status, oldStacks, oldIntensity);
    final after = _statusValue(status, stacks, intensity);
    final delta = after - before;
    final negative = status.negative || status.id.startsWith('decree_');
    final allies = _allies(source.instanceId, target.instanceId);
    if (allies && ((!negative && delta > 0) || (negative && delta < 0))) {
      _add(_support, source.instanceId, 'enhancement', delta.abs());
    } else if (!allies && negative && delta > 0) {
      _add(_support, source.instanceId, 'control', delta);
    } else if (!allies && !negative && delta < 0) {
      _add(_support, source.instanceId, 'control', 2);
    }
  }

  /// Direct effect changes only; costs, opening draws, turn draws, regeneration,
  /// natural decay, and cards played/discarded by their owner are excluded.
  void resourceChange(
    CharacterInstance source,
    CharacterInstance target,
    int delta,
  ) {
    if (delta > 0 && _allies(source.instanceId, target.instanceId)) {
      _add(_support, source.instanceId, 'enhancement', delta * 2);
    } else if (delta < 0 && !_allies(source.instanceId, target.instanceId)) {
      _add(_support, source.instanceId, 'control', -delta * 2);
    }
  }

  void otherEffect(
    CharacterInstance source,
    CharacterInstance target, {
    required bool positive,
  }) {
    if (positive && _allies(source.instanceId, target.instanceId)) {
      _add(_support, source.instanceId, 'enhancement', 2);
    } else if (!positive && !_allies(source.instanceId, target.instanceId)) {
      _add(_support, source.instanceId, 'control', 2);
    }
  }

  Map<String, Object?> snapshot(
    Map<String, Object?> combat,
    KernelState state,
  ) {
    Map<String, int> sum(Map<String, Map<String, int>> data) {
      final result = <String, int>{};
      for (final bucket in data.values) {
        for (final e in bucket.entries) {
          result.update(e.key, (n) => n + e.value, ifAbsent: () => e.value);
        }
      }
      return Map.unmodifiable(result);
    }

    final sources = combat['bySource']! as Map;
    return Map.unmodifiable({
      ...combat,
      'performanceSchemaVersion': 1,
      'scoreRulesVersion': 1,
      'totals': Map<String, Object?>.unmodifiable({
        ...combat['totals']! as Map<String, Object?>,
        'resources': sum(_resources),
        'support': sum(_support),
      }),
      'bySource': Map<String, Object?>.unmodifiable({
        for (final id in {
          ...sources.keys.cast<String>(),
          ..._resources.keys,
          ..._support.keys,
        })
          id: Map<String, Object?>.unmodifiable({
            ...?sources[id] as Map<String, Object?>?,
            'resources': Map<String, int>.unmodifiable(_resources[id] ?? {}),
            'support': Map<String, int>.unmodifiable(_support[id] ?? {}),
          }),
      }),
      'survival': Map<String, Object?>.unmodifiable({
        for (final id in _teams.keys)
          id: Map<String, Object?>.unmodifiable({
            'rounds': _deaths[id]?.$1 ?? state.round,
            'startSequence': _start,
            'endSequence': _deaths[id]?.$2 ?? _end,
            'alive': !_deaths.containsKey(id),
          }),
      }),
    });
  }
}
