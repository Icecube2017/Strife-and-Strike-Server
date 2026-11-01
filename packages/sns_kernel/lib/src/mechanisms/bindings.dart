import 'package:sns_kernel/src/timing.dart';

/// Immutable typed module configuration. No character IDs or runtime state.
final class MechanismBindings {
  MechanismBindings(Iterable<Object> configurations) {
    final entries = <Type, Object>{};
    for (final configuration in configurations) {
      if (entries.containsKey(configuration.runtimeType)) {
        throw ArgumentError(
          'Duplicate mechanism type: ${configuration.runtimeType}',
        );
      }
      entries[configuration.runtimeType] = configuration;
    }
    _entries = Map.unmodifiable(entries);
  }
  late final Map<Type, Object> _entries;
  T? get<T extends Object>() => _entries[T] as T?;
  bool has<T extends Object>() => _entries.containsKey(T);
  Iterable<Object> get configurations => _entries.values;
}

final class SkillRefundRule {
  const SkillRefundRule(this.divisor);
  final int divisor;
}

final class TurnSaveRule {
  const TurnSaveRule({
    this.automaticCapture = true,
    this.allowOwnTurn = false,
    this.maxUses = 1,
    this.restoreMp = true,
    this.restoreHand = true,
    this.restoreStatuses = true,
    this.restoreCooldowns = true,
  });
  final bool automaticCapture,
      allowOwnTurn,
      restoreMp,
      restoreHand,
      restoreStatuses,
      restoreCooldowns;
  final int maxUses;
}

final class ActionRecordingRule {
  const ActionRecordingRule({this.capacity = 5, this.perRound = 2});
  final int capacity, perRound;
}

final class SkillBorrowRule {
  const SkillBorrowRule({
    this.drawCount = 1,
    this.durationRounds = 1,
    this.clock = DurationClock.globalRound,
    this.revealedOnly = true,
    this.allowExclusive = false,
  });
  final int drawCount, durationRounds;
  final DurationClock clock;
  final bool revealedOnly, allowExclusive;
}

final class ShieldLifeCycleRule {
  const ShieldLifeCycleRule();
}

final class GeneratedShieldActionRule {
  const GeneratedShieldActionRule();
}

final class DamageRollChoiceRule {
  const DamageRollChoiceRule({this.rollCount = 2});
  final int rollCount;
}
