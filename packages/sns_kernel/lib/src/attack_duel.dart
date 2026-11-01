part of 'engine.dart';

extension _AttackDuels on GameKernel {
  void _runAttackDuels(CharacterInstance attacker, PendingResolution pending) {
    // Each reaction is a flow step: damage-trigger choices complete before
    // another defender reacts or the original attack builds its packets.
    _flowSteps([
      for (final targetId in pending.targets)
        for (final trait in attacker.traits.toList())
          if (trait.definition.outgoingDuel case final rule?)
            () {
              final defender = _character(targetId);
              if (!attacker.alive ||
                  !defender.alive ||
                  !attacker.traits.contains(trait) ||
                  _blocked(attacker, (s) => s.blockTraits)) {
                return;
              }
              _rollAsync(
                defender,
                pending.diceSides,
                1,
                (rolled) {
                  final won = pending.diceResult > rolled;
                  _event('outgoingDuelResolved', {
                    'actionId': pending.id,
                    'attackerId': attacker.instanceId,
                    'defenderId': defender.instanceId,
                    'traitId': trait.definition.id,
                    'diceSides': pending.diceSides,
                    'attackPoints': pending.diceResult,
                    'defenderRoll': rolled,
                    'won': won,
                  });
                  _flowSteps([
                    if (won)
                      () => _runAbility(
                        attacker,
                        [targetId],
                        rule.victory,
                        () {},
                      ),
                    () => _runAbility(attacker, [targetId], rule.after, () {}),
                  ]);
                },
                damageRoll: true,
                purpose: RollPurpose.duel,
              );
            },
      for (final targetId in pending.targets)
        for (final trait in _character(targetId).traits.toList())
          if (trait.definition.attackDuel != null)
            () {
              final defender = _character(targetId);
              if (!attacker.alive ||
                  !defender.alive ||
                  !defender.traits.contains(trait) ||
                  _blocked(defender, (s) => s.blockTraits)) {
                return;
              }
              if (_previewMode) {
                throw const PreviewBoundary('unprojectedDuelHistory');
              }
              final rule = trait.definition.attackDuel!;
              _rollAsync(
                defender,
                pending.diceSides,
                1,
                (rolled) {
                  final duel = DuelResult.compare(
                    attackPoints: pending.diceResult,
                    defenderRoll: rolled,
                    bonus: trait.counters[rule.counter] ?? 0,
                    failureBonus: rule.failureBonus,
                  );
                  trait.counters[rule.counter] = duel.nextBonus;
                  _event('duelResolved', {
                    'actionId': pending.id,
                    'attackerId': attacker.instanceId,
                    'defenderId': defender.instanceId,
                    'traitId': trait.definition.id,
                    'diceSides': pending.diceSides,
                    'attackPoints': duel.attackPoints,
                    'defenderRoll': duel.defenderRoll,
                    'bonus': duel.bonus,
                    'defenderPoints': duel.defenderPoints,
                    'won': duel.won,
                    'nextBonus': duel.nextBonus,
                  });
                  if (!duel.won) return;
                  defender.permanentModifiers.update(
                    Stat.attack,
                    (n) => n + rule.victoryAttack,
                    ifAbsent: () => rule.victoryAttack,
                  );
                  _event('duelAttackIncreased', {
                    'actionId': pending.id,
                    'actorId': defender.instanceId,
                    'amount': rule.victoryAttack,
                    'attack': defender.value(Stat.attack),
                  });
                  final amount = GameKernel.ruleDamage(
                    finalDice: duel.defenderPoints.toDouble(),
                    attack: defender.value(Stat.attack),
                    defense: attacker.value(Stat.defense),
                    useLegacyDamageFormula: rules.useLegacyDamageFormula,
                  );
                  _event('counterattack', {
                    'actionId': pending.id,
                    'sourceId': defender.instanceId,
                    'targetId': attacker.instanceId,
                    'points': duel.defenderPoints,
                    'amount': amount,
                  });
                  // Trait damage reuses only the ordinary damage formula;
                  // it is not an attack packet or another player action.
                  _damage(defender, attacker, amount, DamageKind.physical);
                },
                damageRoll: true,
                purpose: RollPurpose.duel,
              );
            },
    ]);
  }
}
