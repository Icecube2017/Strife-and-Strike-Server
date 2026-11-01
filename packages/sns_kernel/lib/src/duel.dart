/// Pure comparison for a defender rolling against an existing attack roll.
/// The caller owns RNG, trait lifetime, permanent stat changes and reactions.
final class DuelResult {
  const DuelResult._({
    required this.attackPoints,
    required this.defenderRoll,
    required this.bonus,
    required this.defenderPoints,
    required this.won,
    required this.nextBonus,
  });

  factory DuelResult.compare({
    required int attackPoints,
    required int defenderRoll,
    required int bonus,
    int failureBonus = 1,
  }) {
    if (defenderRoll < 1 || bonus < 0 || failureBonus < 0) {
      throw ArgumentError('Invalid duel roll or bonus');
    }
    final points = defenderRoll + bonus;
    final won = points > attackPoints;
    return DuelResult._(
      attackPoints: attackPoints,
      defenderRoll: defenderRoll,
      bonus: bonus,
      defenderPoints: points,
      won: won,
      nextBonus: won ? 0 : bonus + failureBonus,
    );
  }

  final int attackPoints;
  final int defenderRoll;
  final int bonus;
  final int defenderPoints;
  final bool won;
  final int nextBonus;
}
