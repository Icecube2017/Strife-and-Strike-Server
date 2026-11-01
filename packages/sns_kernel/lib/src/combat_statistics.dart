import 'package:sns_kernel/src/damage_amounts.dart';
import 'package:sns_kernel/src/state.dart';

/// Per-match observer of committed facts. No callbacks, IO, scoring or writes
/// to characters: changing statistics cannot affect settlement.
final class CombatStatistics {
  final Set<int> _seen = {};
  final _StatisticsGroup _total = _StatisticsGroup();
  final Map<int, _StatisticsGroup> _rounds = {};

  /// Replay the same event once; attack main/attachments are separate facts,
  /// while attackDamageDealt is a summary and is deliberately not counted.
  void record(KernelEvent event) {
    if (event.type != 'damage' && event.type != 'healed') return;
    if (!_seen.add(event.sequence)) return;
    _total.record(event);
    _rounds.putIfAbsent(event.round, _StatisticsGroup.new).record(event);
  }

  Map<String, Object?> snapshot() => Map.unmodifiable({
    'schemaVersion': 1,
    ..._total.snapshot(),
    'rounds': Map<String, Object?>.unmodifiable({
      for (final entry in _rounds.entries)
        entry.key.toString(): entry.value.snapshot(),
    }),
  });
}

final class _StatisticsGroup {
  final _CombatTotals _totals = _CombatTotals();
  final Map<String, _CombatTotals> _sources = {};
  final Map<String, _CombatTotals> _targets = {};
  final Map<(String?, String), _CombatTotals> _pairs = {};
  void record(KernelEvent event) {
    final d = event.data;
    final source = (d['statisticsSourceId'] ?? d['sourceId']) as String?;
    final target = d['targetId']! as String;
    final buckets = [
      _totals,
      _sources.putIfAbsent(source ?? '@environment', _CombatTotals.new),
      _targets.putIfAbsent(target, _CombatTotals.new),
      _pairs.putIfAbsent((source, target), _CombatTotals.new),
    ];
    for (final bucket in buckets) {
      bucket.record(event);
    }
  }

  Map<String, Object?> snapshot() => Map.unmodifiable({
    'totals': _totals.snapshot(),
    'bySource': Map<String, Object?>.unmodifiable({
      for (final e in _sources.entries) e.key: e.value.snapshot(),
    }),
    'byTarget': Map<String, Object?>.unmodifiable({
      for (final e in _targets.entries) e.key: e.value.snapshot(),
    }),
    'pairs': List<Map<String, Object?>>.unmodifiable([
      for (final e in _pairs.entries)
        Map<String, Object?>.unmodifiable({
          'sourceId': e.key.$1,
          'targetId': e.key.$2,
          ...e.value.snapshot(),
        }),
    ]),
  });
}

final class _CombatTotals {
  final Map<String, int> _damage = {for (final k in _damageKeys) k: 0};
  final Map<String, int> _healing = {for (final k in _healingKeys) k: 0};
  final Map<String, int> _lifeLoss = {for (final k in _lifeLossKeys) k: 0};
  final Map<String, Map<String, int>> _kinds = {};
  final Map<String, Map<String, int>> _categories = {};
  static const _damageKeys = [
    'events',
    'requested',
    'resolved',
    'effective',
    'hpLost',
    'shieldAbsorbed',
    'overkill',
    'convertedToDefense',
    'defenseLost',
  ];
  static const _healingKeys = [
    'events',
    'requested',
    'resolved',
    'effective',
    'overheal',
    'ignored',
  ];
  static const _lifeLossKeys = ['events', 'resolved', 'hpLost', 'overkill'];
  int value(Map<String, Object?> d, String k, [int fallback = 0]) =>
      d[k] as int? ?? fallback;
  void add(Map<String, int> into, Map<String, int> values) {
    for (final e in values.entries) {
      into.update(e.key, (v) => v + e.value, ifAbsent: () => e.value);
    }
  }

  void record(KernelEvent event) {
    final d = event.data;
    if (event.type == 'healed') {
      final actual = value(d, 'amount');
      add(_healing, {
        'events': 1,
        'requested': value(d, 'requestedAmount', actual),
        'resolved': value(d, 'resolvedAmount', actual),
        'effective': actual,
        'overheal': value(d, 'overheal'),
        'ignored': value(d, 'ignoredHealing'),
      });
      return;
    }
    final amount = damageAfterShield(d);
    final hp = value(d, 'actualHpLost', value(d, 'hpLost', amount));
    if (d['kind'] == 'lifeLoss') {
      add(_lifeLoss, {
        'events': 1,
        'resolved': amount,
        'hpLost': hp,
        'overkill': value(d, 'overkill'),
      });
      return;
    }
    final shield = value(d, 'shieldAbsorbed');
    final metrics = {
      'events': 1,
      'requested': value(d, 'requestedAmount', amount + shield),
      'resolved': amount + shield,
      'effective': hp + shield,
      'hpLost': hp,
      'shieldAbsorbed': shield,
      'overkill': value(d, 'overkill'),
      'convertedToDefense': value(d, 'convertedToDefense'),
      'defenseLost': value(d, 'defenseLost'),
    };
    add(_damage, metrics);
    add(_kinds.putIfAbsent(d['kind']! as String, () => {}), metrics);
    final category = d['statusId'] != null
        ? 'status'
        : d['attack'] == true
        ? (d['component'] == 'onHit' ? 'attackAttachment' : 'attackMain')
        : 'independent';
    add(_categories.putIfAbsent(category, () => {}), metrics);
  }

  Map<String, Object?> snapshot() => Map.unmodifiable({
    'damage': Map<String, int>.unmodifiable(_damage),
    'healing': Map<String, int>.unmodifiable(_healing),
    'lifeLoss': Map<String, int>.unmodifiable(_lifeLoss),
    'damageByKind': Map<String, Object?>.unmodifiable({
      for (final e in _kinds.entries)
        e.key: Map<String, int>.unmodifiable(e.value),
    }),
    'damageByCategory': Map<String, Object?>.unmodifiable({
      for (final e in _categories.entries)
        e.key: Map<String, int>.unmodifiable(e.value),
    }),
  });
}
