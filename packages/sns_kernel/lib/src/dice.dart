/// Immutable dice data. Random generation and execution order belong to the kernel.
enum RollPurpose {
  attack,
  effect,
  skill,
  card,
  status,
  trait,
  damageGuard,
  duel,
}

enum DiceAdjustment { add, replace, capMaximum, capMinimum }

final class DieSpec {
  DieSpec({this.sides, this.fixedValue}) {
    if ((sides == null && fixedValue == null) ||
        (sides != null && sides! < 1) ||
        (fixedValue != null && fixedValue! < 0)) {
      throw ArgumentError('Invalid die specification');
    }
  }
  final int? sides;
  final int? fixedValue;
  bool get isFixed => fixedValue != null;
  int get maximum => fixedValue ?? sides!;
  Map<String, Object?> toJson() => {
    if (sides != null) 'sides': sides,
    if (fixedValue != null) 'fixed_value': fixedValue,
  };
  factory DieSpec.fromJson(Map<String, dynamic> json) => DieSpec(
    sides: json['sides'] as int?,
    fixedValue: json['fixed_value'] as int?,
  );
}

final class DiceSpec {
  DiceSpec({
    required this.nominalSides,
    this.nominalCount = 1,
    required List<DieSpec> dice,
  }) : dice = List.unmodifiable(dice) {
    if (nominalSides < 1 || nominalCount < 1 || dice.isEmpty) {
      throw ArgumentError('Invalid dice specification');
    }
  }
  factory DiceSpec.uniform(int sides, {int count = 1}) => DiceSpec(
    nominalSides: sides,
    nominalCount: count,
    dice: List.generate(count, (_) => DieSpec(sides: sides)),
  );
  final int nominalSides;
  final int nominalCount;
  final List<DieSpec> dice;
  int get nominalMaximum => nominalSides * nominalCount;
  int get maximumTotal => dice.fold(0, (sum, die) => sum + die.maximum);
  Map<String, Object?> toJson() => {
    'nominal_sides': nominalSides,
    'nominal_count': nominalCount,
    'dice': [for (final die in dice) die.toJson()],
  };
  factory DiceSpec.fromJson(Map<String, dynamic> json) => DiceSpec(
    nominalSides: json['nominal_sides'] as int,
    nominalCount: json['nominal_count'] as int,
    dice: [
      for (final die in json['dice'] as List)
        DieSpec.fromJson(Map<String, dynamic>.from(die as Map)),
    ],
  );
}

final class RollContext {
  const RollContext({
    required this.actorId,
    required this.purpose,
    this.actionId,
    this.definitionId,
  });
  final String actorId;
  final RollPurpose purpose;
  final String? actionId;
  final String? definitionId;
  Map<String, Object?> toJson() => {
    'actor_id': actorId,
    'purpose': purpose.name,
    if (actionId != null) 'action_id': actionId,
    if (definitionId != null) 'definition_id': definitionId,
  };
  factory RollContext.fromJson(Map<String, dynamic> json) => RollContext(
    actorId: json['actor_id'] as String,
    purpose: RollPurpose.values.byName(json['purpose'] as String),
    actionId: json['action_id'] as String?,
    definitionId: json['definition_id'] as String?,
  );
}

final class RollModification {
  const RollModification(this.operation, this.value, {this.sourceId});
  final DiceAdjustment operation;
  final int value;
  final String? sourceId;
  int apply(int current) => switch (operation) {
    DiceAdjustment.add => current + value,
    DiceAdjustment.replace => value,
    DiceAdjustment.capMaximum => current > value ? value : current,
    DiceAdjustment.capMinimum => current < value ? value : current,
  };
  Map<String, Object?> toJson() => {
    'operation': operation.name,
    'value': value,
    if (sourceId != null) 'source_id': sourceId,
  };
  factory RollModification.fromJson(Map<String, dynamic> json) =>
      RollModification(
        DiceAdjustment.values.byName(json['operation'] as String),
        json['value'] as int,
        sourceId: json['source_id'] as String?,
      );
}

final class RollResult {
  RollResult({
    required this.id,
    required this.context,
    required this.spec,
    required List<int> values,
    List<RollModification> modifications = const [],
    this.rerollOf,
    this.replacesRollId,
  }) : values = List.unmodifiable(values),
       modifications = List.unmodifiable(modifications) {
    if (values.length != spec.dice.length) {
      throw ArgumentError('Dice result length mismatch');
    }
    for (var i = 0; i < values.length; i++) {
      final die = spec.dice[i], value = values[i];
      if (die.isFixed
          ? value != die.fixedValue
          : value < 1 || value > die.sides!) {
        throw ArgumentError('Invalid die result');
      }
    }
  }
  final String id;
  final RollContext context;
  final DiceSpec spec;
  final List<int> values;
  final List<RollModification> modifications;
  final String? rerollOf;
  final String? replacesRollId;
  int get rawTotal => values.fold(0, (sum, value) => sum + value);
  int get finalTotal =>
      modifications.fold(rawTotal, (current, change) => change.apply(current));
  RollResult modified(RollModification change) => RollResult(
    id: id,
    context: context,
    spec: spec,
    values: values,
    modifications: [...modifications, change],
    rerollOf: rerollOf,
    replacesRollId: replacesRollId,
  );
  RollResult linked({String? rerollOf, String? replacesRollId}) => RollResult(
    id: id,
    context: context,
    spec: spec,
    values: values,
    modifications: modifications,
    rerollOf: rerollOf ?? this.rerollOf,
    replacesRollId: replacesRollId ?? this.replacesRollId,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'context': context.toJson(),
    'spec': spec.toJson(),
    'values': values,
    'raw_total': rawTotal,
    'final_total': finalTotal,
    'modifications': [for (final change in modifications) change.toJson()],
    if (rerollOf != null) 'reroll_of': rerollOf,
    if (replacesRollId != null) 'replaces_roll_id': replacesRollId,
  };
  factory RollResult.fromJson(Map<String, dynamic> json) {
    final result = RollResult(
      id: json['id'] as String,
      context: RollContext.fromJson(
        Map<String, dynamic>.from(json['context'] as Map),
      ),
      spec: DiceSpec.fromJson(Map<String, dynamic>.from(json['spec'] as Map)),
      values: (json['values'] as List).cast<int>(),
      modifications: [
        for (final change in json['modifications'] as List)
          RollModification.fromJson(Map<String, dynamic>.from(change as Map)),
      ],
      rerollOf: json['reroll_of'] as String?,
      replacesRollId: json['replaces_roll_id'] as String?,
    );
    if (json['raw_total'] != result.rawTotal ||
        json['final_total'] != result.finalTotal) {
      throw const FormatException('Inconsistent dice totals');
    }
    return result;
  }
}
