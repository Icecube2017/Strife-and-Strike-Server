import '../state.dart';

/// Pinned, serializable weights. A checkpoint keeps the exact rules of its game.
final class SupportScoreRules {
  const SupportScoreRules([this.overrides = const {}]);
  final Map<String, num> overrides;
  static const defaults = <String, num>{
    'actionLost': 15,
    'actionCancelled': 15,
    'redirect': 8,
    'skillLock': 9,
    'traitLock': 12,
    'handLock': 4,
    'tagLock': 4,
    'handLockCap': 16,
    'interrupt': 15,
    'cardCancelled': 6,
    'cooldown': 6,
    'mp': 8,
    'card': 6,
    'damage': .1,
    'statusLayer': 6,
    'statusIntensity': 3,
    'plainStatusLayer': 9,
    'actionGained': 15,
    'damageTakenForAlly': 1 / 15,
    'deathPrevented': 30,
    'cleanseLock': 15,
    'temporaryTrigger': 9,
    'fallback': 4,
    'maxHp': 0,
    'maxMp': 4,
    'maxHand': 4,
    'shieldRemoved': 1 / 15,
    'revealCard': 2,
    'temporaryRemoved': 8,
    'anomalyCleansed': 12,
    'revived': 15,
    'permanentStat': 1,
    'partialActionLock': 2,
  };
  double operator [](String key) =>
      (overrides[key] ?? defaults[key]!).toDouble();
  Map<String, Object?> toJson() => {...defaults, ...overrides};
  factory SupportScoreRules.fromJson(Map<String, dynamic> json) {
    if (json.keys.any((k) => !defaults.containsKey(k)) ||
        json.values.any((v) => v is! num || !v.isFinite || v < 0)) {
      throw const FormatException('Invalid support score weights');
    }
    return SupportScoreRules(Map.unmodifiable(json.cast<String, num>()));
  }
}

enum ControlScore {
  actionDenial,
  abilityRestriction,
  resourceSuppression,
  weakeningDispel,
}

enum EnhancementScore { resourceGain, damageProtection, buffCleanse }

/// An independent contribution ledger. No IO, RNG, game commands or state writes.
/// Integer millionths keep partitions and totals identical before display floors.
final class SupportScores {
  SupportScores({this.rules = const SupportScoreRules()});
  final SupportScoreRules rules;
  final Map<String, String> _teams = {};
  final Map<String, Map<String, int>> _control = {};
  final Map<String, Map<String, List<int>>> _enhancement = {};
  final Map<String, double> _caps = {};
  static const precision = 1000000;

  void register(KernelState state) {
    for (final p in state.players) {
      _teams[p.character.instanceId] = p.teamId;
    }
  }

  bool allies(String a, String b) =>
      _teams.containsKey(a) && _teams[a] == _teams[b];

  void control(
    String? source,
    String target,
    ControlScore kind,
    double points,
  ) {
    if (source == null ||
        !_teams.containsKey(target) ||
        !_teams.containsKey(source) ||
        allies(source, target) ||
        !points.isFinite ||
        points <= 0) {
      return;
    }
    final bucket = _control.putIfAbsent(source, () => {});
    bucket.update(
      kind.name,
      (n) => n + (points * precision).round(),
      ifAbsent: () => (points * precision).round(),
    );
  }

  void enhance(
    String? source,
    String target,
    EnhancementScore kind,
    double points,
  ) {
    if (source == null ||
        !allies(source, target) ||
        !points.isFinite ||
        points <= 0) {
      return;
    }
    final bucket = _enhancement.putIfAbsent(source, () => {});
    final amounts = bucket.putIfAbsent(kind.name, () => [0, 0]);
    amounts[source == target ? 0 : 1] += (points * precision).round();
  }

  /// A fixed budget shared by all effective sources, including redundant locks.
  void moveControl(
    String source,
    ControlScore from,
    ControlScore to,
    double points,
  ) {
    final bucket = _control[source];
    if (bucket == null || points <= 0) return;
    final units = (points * precision).round().clamp(0, bucket[from.name] ?? 0);
    bucket[from.name] = (bucket[from.name] ?? 0) - units;
    bucket.update(to.name, (n) => n + units, ifAbsent: () => units);
  }

  /// A fixed budget shared by all effective sources, including redundant locks.
  void distributeControl(
    Map<String, double> weights,
    String target,
    ControlScore kind,
    double points, {
    String? capKey,
    double? cap,
  }) {
    final valid = Map<String, double>.fromEntries(
      weights.entries.where(
        (e) =>
            _teams.containsKey(e.key) && !allies(e.key, target) && e.value > 0,
      ),
    );
    if (valid.isEmpty || points <= 0) return;
    if (capKey != null && cap != null) {
      final before = _caps[capKey] ?? 0;
      points = points.clamp(0, (cap - before).clamp(0, double.infinity));
      _caps[capKey] = before + points;
    }
    _allocate(
      valid,
      points,
      (source, amount) => control(source, target, kind, amount),
    );
  }

  void distributeEnhancement(
    Map<String, double> weights,
    String target,
    EnhancementScore kind,
    double points,
  ) {
    final valid = Map<String, double>.fromEntries(
      weights.entries.where((e) => allies(e.key, target) && e.value > 0),
    );
    _allocate(
      valid,
      points,
      (source, amount) => enhance(source, target, kind, amount),
    );
  }

  void _allocate(
    Map<String, double> weights,
    double points,
    void Function(String, double) record,
  ) {
    if (weights.isEmpty || points <= 0 || !points.isFinite) return;
    final total = weights.values.fold<double>(0, (a, b) => a + b);
    final budget = (points * precision).round();
    var remaining = budget;
    final ids = weights.keys.toList()..sort();
    for (final id in ids) {
      final share = id == ids.last
          ? remaining
          : (budget * weights[id]! / total).floor();
      remaining -= share;
      record(id, share / precision);
    }
  }

  double _number(int units) => units / precision;
  Map<String, Object?> forSource(String source) {
    final control = {
      for (final k in ControlScore.values)
        k.name: _control[source]?[k.name] ?? 0,
    };
    final enhancement = {
      for (final k in EnhancementScore.values)
        k.name: _enhancement[source]?[k.name] ?? const [0, 0],
    };
    final self = enhancement.values.fold<int>(0, (n, v) => n + v[0]);
    final ally = enhancement.values.fold<int>(0, (n, v) => n + v[1]);
    return {
      'control': _number(control.values.fold<int>(0, (a, b) => a + b)),
      'enhancement': _number(self + ally),
      'controlBreakdown': {
        for (final e in control.entries) e.key: _number(e.value),
      },
      'enhancementBreakdown': {
        for (final e in enhancement.entries)
          e.key: _number(e.value[0] + e.value[1]),
      },
      'selfEnhancement': _number(self),
      'allySupport': _number(ally),
    };
  }

  Map<String, Object?> totals() {
    final control = {for (final k in ControlScore.values) k.name: 0};
    final enhancement = {for (final k in EnhancementScore.values) k.name: 0};
    var self = 0, ally = 0;
    for (final id in _teams.keys) {
      for (final k in ControlScore.values) {
        control[k.name] = control[k.name]! + (_control[id]?[k.name] ?? 0);
      }
      for (final k in EnhancementScore.values) {
        final values = _enhancement[id]?[k.name] ?? const [0, 0];
        enhancement[k.name] = enhancement[k.name]! + values[0] + values[1];
        self += values[0];
        ally += values[1];
      }
    }
    return {
      'control': _number(control.values.fold<int>(0, (a, b) => a + b)),
      'enhancement': _number(self + ally),
      'controlBreakdown': {
        for (final e in control.entries) e.key: _number(e.value),
      },
      'enhancementBreakdown': {
        for (final e in enhancement.entries) e.key: _number(e.value),
      },
      'selfEnhancement': _number(self),
      'allySupport': _number(ally),
    };
  }
}
