part of 'engine.dart';

extension _AttackRules on GameKernel {
  bool _attackEffectTargetAllowed(
    CharacterInstance target,
    AttackPacket? packet,
  ) =>
      packet == null ||
      !packet.groupAttack ||
      target.instanceId == packet.sourceId ||
      _blocked(target, (s) => s.blockTraits) ||
      !target.traits.any(
        (t) => t.definition.incomingAttack?.blockGroupAttackEffects == true,
      );

  bool _incomingAttackTargetAllowed(
    CharacterInstance actor,
    CharacterInstance target,
  ) =>
      _blocked(target, (s) => s.blockTraits) ||
      target.traits.every(
        (trait) => _conditionMatches(
          trait.definition.incomingAttackTargetWhen,
          target,
          actor,
        ),
      );

  bool _hasPrimaryAttackTarget(CharacterInstance actor, Set<String> excluded) =>
      state.players.any(
        (p) =>
            p.character.alive &&
            _enemy(actor, p.character) &&
            !excluded.contains(p.character.instanceId) &&
            _incomingAttackTargetAllowed(actor, p.character) &&
            (actor.extraTurnAttackTarget == null ||
                actor.extraTurnAttackTarget == p.character.instanceId) &&
            (actor.nextAttackTargetId == null ||
                !_character(actor.nextAttackTargetId!).alive ||
                actor.nextAttackTargetId == p.character.instanceId) &&
            (actor.armedStatusTransfer?.targetId == null ||
                actor.armedStatusTransfer!.targetId == p.character.instanceId),
      );

  List<ArmedAttack> _effectiveArmedAttacks(CharacterInstance actor) {
    if (_interactionRulesVersion < 20) return actor.armedAttacks.toList();
    final surviving = actor.armedAttacks
        .where(
          (a) =>
              !a.rule.copyDamage ||
              (a.targetId != null && _character(a.targetId!).alive),
        )
        .toList();
    final copies = surviving
        .where((a) => a.rule.copyDamage)
        .map((a) => a.targetId!)
        .toSet();
    if (copies.isNotEmpty && !_hasPrimaryAttackTarget(actor, copies)) {
      surviving.removeWhere((a) => a.rule.copyDamage);
    }
    return surviving;
  }

  void _checkNewCopyAttack(
    CharacterInstance actor,
    List<EffectDefinition> effects,
    List<String> targets,
  ) {
    if (_interactionRulesVersion < 20 ||
        !effects.whereType<ArmAttack>().any((e) => e.copyDamage)) {
      return;
    }
    final excluded = {
      ..._effectiveArmedAttacks(
        actor,
      ).where((a) => a.rule.copyDamage).map((a) => a.targetId!),
      ...targets,
    };
    if (!_hasPrimaryAttackTarget(actor, excluded)) {
      throw StateError('Damage copy requires another legal attack target');
    }
  }

  void _expireUnusableAttackCopies() {
    if (_interactionRulesVersion < 20) return;
    for (final player in state.players) {
      final actor = player.character;
      final effective = _effectiveArmedAttacks(actor);
      actor.armedAttacks.removeWhere((a) => !effective.contains(a));
    }
  }

  void _checkArmedAttackTarget(CharacterInstance actor, List<String> targets) {
    for (final id in targets) {
      if (!_incomingAttackTargetAllowed(actor, _character(id))) {
        throw StateError('Attack target is restricted by its trait');
      }
    }
    if (actor.extraTurnAttackTarget != null &&
        (targets.length != 1 ||
            targets.single != actor.extraTurnAttackTarget)) {
      throw StateError('Extra turn attack is restricted to its chased target');
    }
    if (_effectiveArmedAttacks(
      actor,
    ).any((a) => a.rule.copyDamage && targets.contains(a.targetId))) {
      throw StateError(
        'Copied damage target must differ from the attack target',
      );
    }
    if (actor.nextAttackTargetId != null &&
        _character(actor.nextAttackTargetId!).alive &&
        (targets.length != 1 || targets.single != actor.nextAttackTargetId)) {
      throw StateError('Attack must use its required next target');
    }
    if (actor.armedStatusTransfer?.targetId case final targetId?
        when !targets.contains(targetId)) {
      throw StateError('Attack must use the armed transfer target');
    }
  }

  int _incomingDamageReduction(
    CharacterInstance source,
    CharacterInstance target, {
    bool attachment = false,
  }) {
    if (_blocked(target, (s) => s.blockTraits)) return 0;
    return target.traits.fold<int>(0, (n, trait) {
      final rule = trait.definition.incomingAttack;
      if (rule == null || (attachment && !rule.reduceAttachments)) return n;
      return n +
          _amount(
            0,
            rule.finalDamageReductionValue,
            source,
            target,
          ).clamp(0, 1000000000);
    });
  }

  int _statusStackGain(CharacterInstance target, String id, int amount) =>
      amount <= 0 || _blocked(target, (s) => s.blockTraits)
      ? amount
      : target.traits.fold<int>(
          amount,
          (n, t) => n * (t.definition.statusGainMultipliers[id] ?? 1),
        );
  int _attackDiceBonus(CharacterInstance actor) =>
      actor.statuses.fold<int>(
        0,
        (n, s) => n + s.definition.attackDicePerIntensity * s.intensity,
      ) +
      (_blocked(actor, (s) => s.blockTraits)
          ? 0
          : actor.traits.fold<int>(
              0,
              (n, t) =>
                  n +
                  _amount(0, t.definition.attackDiceBonusValue, actor, actor),
            ));

  void _stealLife(
    CharacterInstance actor,
    CharacterInstance target,
    int amount, {
    bool healNominal = false,
  }) {
    if (actor == target || !actor.alive || !target.alive || amount <= 0) return;
    final actual = target.defenseLife
        ? 0
        : amount.clamp(0, target.hp.clamp(0, 1000000000));
    target.hp -= actual;
    _event('lifeStolen', {
      'sourceId': actor.instanceId,
      'targetId': target.instanceId,
      'amount': actual,
      'nominalAmount': amount,
    });
    _heal(actor, actor, healNominal ? amount : actual);
    _normalize(target);
  }

  void _checkGuardRoll(DamageGuard guard) {
    if ((guard.rollSides == null && guard.success.isNotEmpty) ||
        (guard.rollSides != null &&
            (guard.rollSides! <= 0 ||
                guard.success.isEmpty ||
                guard.success.any((n) => n <= 0 || n > guard.rollSides!)))) {
      throw StateError('Invalid guard dice');
    }
  }

  void _checkAttackDiceSequences() {
    for (final trait in catalog.traits.values) {
      if (trait.attackDiceRule case final r?) {
        if (r.offset.abs() > 1023) throw StateError('Invalid dice offset');
      }
      if (trait.attackAura case final a?) {
        if (![
              EffectTarget.self,
              EffectTarget.all,
              EffectTarget.allies,
              EffectTarget.enemies,
              EffectTarget.others,
            ].contains(a.scope) ||
            !a.finalDamageMultiplier.isFinite ||
            a.finalDamageMultiplier < 0) {
          throw StateError('Invalid attack aura');
        }
      }
      if (trait.incomingAttack?.diceCap case final cap?) {
        if (cap < 0) throw StateError('Invalid incoming dice cap');
      }

      final rule = trait.attackDiceSequence;
      if (rule == null) continue;
      final variable = _require(catalog.variables, rule.positionVariable);
      if (rule.values.isEmpty ||
          rule.values.length > 1024 ||
          rule.values.any((v) => v <= 0) ||
          rule.diceSides <= 0 ||
          variable.type != VariableType.number ||
          variable.scope != VariableScope.owner ||
          variable.reset != CounterReset.never ||
          variable.minimum != null ||
          variable.maximum != null ||
          (variable.initial != null && variable.initial is! int)) {
        throw StateError('Invalid attack dice sequence: ${trait.id}');
      }
    }
    for (final character in catalog.characters.values) {
      final defaults = character.traits
          .map((id) => _require(catalog.traits, id).defaultAttackDiceSides)
          .whereType<int>()
          .toSet();
      if (defaults.length > 1) {
        throw StateError('Character has conflicting default attack dice');
      }
      if (character.traits
              .where(
                (id) =>
                    _require(catalog.traits, id).attackDiceSequence != null ||
                    _require(catalog.traits, id).attackDiceRule != null,
              )
              .length >
          1) {
        throw StateError('Character has conflicting attack dice sequences');
      }
    }
  }

  RollResult _attackRoll(
    CharacterInstance actor,
    int sides,
    int count, {
    String? actionId,
    bool fixedMaximum = false,
    String? rerollOf,
  }) {
    var faces = sides;
    final dice = <DieSpec>[];
    final values = <int>[];
    for (var i = 0; i < count; i++) {
      if (fixedMaximum) {
        dice.add(DieSpec(sides: sides, fixedValue: sides));
        values.add(sides);
        continue;
      }
      final enabled = !_blocked(actor, (s) => s.blockTraits);
      final transform = enabled
          ? actor.traits
                .map((t) => t.definition.attackDiceRule)
                .whereType<AttackDiceRule>()
                .firstOrNull
          : null;
      if (transform != null) {
        if (transform.mode == AttackDiceMode.facesOffset) {
          faces = (sides + transform.offset).clamp(1, 1024);
          dice.add(DieSpec(sides: faces));
          values.add(_nextInt(faces) + 1);
          continue;
        }
        final amount = (transform.roundUp ? (sides / 2).ceil() : sides ~/ 2)
            .clamp(transform.oddRemainderFixedOne ? 0 : 1, 512);
        final rolls = List<int>.generate(amount, (_) => _nextInt(2) + 1);
        dice.addAll(List.generate(amount, (_) => DieSpec(sides: 2)));
        if (transform.oddRemainderFixedOne && sides.isOdd) {
          rolls.add(1);
          dice.add(DieSpec(fixedValue: 1));
        }
        values.addAll(rolls);
        _event('attackDiceComponentsRolled', {
          'ownerId': actor.instanceId,
          'sides': 2,
          'rolls': rolls,
          'nominalSides': sides,
        });
        continue;
      }
      final sequence = enabled
          ? actor.traits
                .map((t) => t.definition.attackDiceSequence)
                .whereType<AttackDiceSequence>()
                .firstOrNull
          : null;
      if (sequence != null) {
        final cell = _variableCell(sequence.positionVariable, actor);
        final index = (cell.value as num).toInt() % sequence.values.length;
        cell.value = (index + 1) % sequence.values.length;
        faces = sequence.replaceDiceSides ? sequence.diceSides : sides;
        final value = sequence.values[index];
        dice.add(DieSpec(fixedValue: value));
        values.add(value);
        continue;
      }
      dice.add(DieSpec(sides: sides));
      values.add(_nextInt(sides) + 1);
    }
    return _storeRoll(
      RollResult(
        id: _nextRollId(),
        context: _rollContext(
          actor,
          purpose: RollPurpose.attack,
          actionId: actionId,
        ),
        spec: DiceSpec(nominalSides: faces, nominalCount: count, dice: dice),
        values: values,
        rerollOf: rerollOf,
      ),
    );
  }

  void _modifyAttackPower(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyAttackPower effect,
    int multiplier,
  ) {
    final amount =
        _amount(effect.amount, effect.value, actor, target) * multiplier;
    final fact = _currentTrigger?.fact;
    if (fact?.timing == TriggerTiming.cardsPlayed) {
      final id = fact!.actionId;
      if (!fact.attack || id == null) {
        throw StateError('Attack power requires committed attack');
      }
      _declaredAttackPower.update(
        id,
        (n) => n + amount,
        ifAbsent: () => amount,
      );
    } else {
      _attackPowerAdjustment += amount;
    }
  }
}
