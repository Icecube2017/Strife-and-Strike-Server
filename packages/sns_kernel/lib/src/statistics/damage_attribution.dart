import 'support_scores.dart';

enum ContributionRoute { enhancement, protection, weakening }

final class ContributionOwner {
  const ContributionOwner(
    this.source,
    this.target,
    this.route, {
    this.increases,
  });
  final String source, target;
  final ContributionRoute route;
  final bool? increases;
  bool get expectsIncrease =>
      increases ?? route != ContributionRoute.protection;
  String get key => '$source/$target/${route.name}/$expectsIncrease';
}

/// A frozen local calculation with the same committed roll/choices. It never
/// retries commands, samples randomness, or edits live characters for ablation.
final class DamageAttribution {
  DamageAttribution(int amount) : _calculate = ((_) => amount);
  DamageAttribution.formula(
    this._calculate,
    Iterable<ContributionOwner> owners,
  ) {
    for (final owner in owners) {
      _owners[owner.key] = owner;
    }
  }
  int Function(Set<String>) _calculate;
  final Map<String, ContributionOwner> _owners = {};
  bool _settled = false;
  DamageAttribution copy() {
    final result = DamageAttribution.formula(_calculate, _owners.values);
    return result;
  }

  void transform(int Function(int) apply, {ContributionOwner? owner}) {
    final before = _calculate;
    if (owner != null) _owners[owner.key] = owner;
    _calculate = (excluded) => owner != null && excluded.contains(owner.key)
        ? before(excluded)
        : apply(before(excluded));
  }

  void transformGroup(
    int Function(int, Set<String>) apply,
    Iterable<ContributionOwner> owners,
  ) {
    final before = _calculate;
    for (final owner in owners) {
      _owners[owner.key] = owner;
    }
    _calculate = (excluded) => apply(before(excluded), excluded);
  }

  int get amount => _calculate(const {});

  /// A source's leave-one-out effect supplies its weight, while joint removal
  /// defines the fixed budget. Overkill is clipped consistently in both worlds.
  void settle(
    SupportScores scores, {
    required int observed,
    required int effectiveLimit,
  }) {
    if (_settled) return;
    _settled = true;
    final actual = _calculate(const {});
    if (actual != observed || effectiveLimit <= 0) return;
    int effective(int value) => value.clamp(0, effectiveLimit);
    final full = effective(actual);
    final positive = <String, double>{}, negative = <String, double>{};
    for (final owner in _owners.values) {
      final without = effective(_calculate({owner.key}));
      final delta = full - without;
      if ((delta > 0) != owner.expectsIncrease) continue;
      if (delta > 0) positive[owner.key] = delta.toDouble();
      if (delta < 0) negative[owner.key] = -delta.toDouble();
    }
    if (positive.isEmpty) {
      final candidates = _owners.values
          .where((o) => o.expectsIncrease)
          .map((o) => o.key)
          .toSet();
      if (full > effective(_calculate(candidates))) {
        for (final key in candidates) {
          positive[key] = 1;
        }
      }
    }
    if (negative.isEmpty) {
      final candidates = _owners.values
          .where((o) => !o.expectsIncrease)
          .map((o) => o.key)
          .toSet();
      if (effective(_calculate(candidates)) > full) {
        for (final key in candidates) {
          negative[key] = 1;
        }
      }
    }
    void award(Map<String, double> weights, int budget) {
      if (weights.isEmpty || budget <= 0) return;
      final total = weights.values.fold<double>(0, (a, b) => a + b);
      final units = (budget * scores.rules['damage'] * SupportScores.precision)
          .round();
      var remaining = units;
      final keys = weights.keys.toList()..sort();
      for (final key in keys) {
        final share = key == keys.last
            ? remaining
            : (units * weights[key]! / total).floor();
        remaining -= share;
        final owner = _owners[key]!;
        final points = share / SupportScores.precision;
        switch (owner.route) {
          case ContributionRoute.enhancement:
            scores.enhance(
              owner.source,
              owner.target,
              EnhancementScore.buffCleanse,
              points,
            );
          case ContributionRoute.protection:
            scores.enhance(
              owner.source,
              owner.target,
              EnhancementScore.damageProtection,
              points,
            );
          case ContributionRoute.weakening:
            scores.control(
              owner.source,
              owner.target,
              ControlScore.weakeningDispel,
              points,
            );
        }
      }
    }

    if (positive.isNotEmpty) {
      award(
        positive,
        (full - effective(_calculate(positive.keys.toSet()))).clamp(
          0,
          effectiveLimit,
        ),
      );
    }
    if (negative.isNotEmpty) {
      award(
        negative,
        (effective(_calculate(negative.keys.toSet())) - full).clamp(
          0,
          effectiveLimit,
        ),
      );
    }
  }
}
