part of 'engine.dart';

extension _PublicSkillModules on GameKernel {
  void _checkSkillNumber(
    CharacterInstance actor,
    SkillDefinition skill,
    int? number,
  ) {
    final parameter = skill.numberParameter;
    if (parameter == null) {
      if (number != null) throw StateError('Skill has no numeric parameter');
      return;
    }
    if (number == null ||
        (parameter.allowedValues.isNotEmpty &&
            !parameter.allowedValues.contains(number)) ||
        number < parameter.minimum ||
        number > parameter.maximum ||
        (parameter.maximumValue != null &&
            number > _amount(0, parameter.maximumValue, actor, actor))) {
      throw StateError('Number is outside the configured range');
    }
    if (!_negateSkills(actor) &&
        parameter.markCostId != null &&
        _markCount(actor, parameter.markCostId!) < number) {
      throw StateError('Insufficient numeric mark fee');
    }
    _checkMp(actor, _skillMpCost(actor, skill, number: number));
    if (!_negateSkills(actor) &&
        !actor.defenseLife &&
        actor.hp < _skillLifeCost(actor, skill, number: number)) {
      throw StateError('Insufficient life resource');
    }
  }

  void _finishAttackSkills(
    CharacterInstance actor,
    PendingResolution pending,
    void Function() complete,
  ) {
    final effects = [
      for (final armed in pending.armedAttacks) ...armed.rule.after,
    ];
    if (effects.isEmpty) {
      _attackCaps.remove(pending.id);
      _finishAttackSkillCopies(actor, pending, complete);
      return;
    }
    final primary = pending.targets.firstOrNull;
    final amount = state.events
        .where(
          (e) =>
              e.type == 'damage' &&
              e.data['actionId'] == pending.id &&
              e.data['sourceId'] == actor.instanceId &&
              e.data['targetId'] == primary &&
              e.data['attack'] == true &&
              e.data['independent'] != true,
        )
        .fold<int>(
          0,
          (n, e) =>
              n +
              (_damageAmountVersion == 0
                  ? e.data['hpLost'] as int? ?? e.data['amount'] as int? ?? 0
                  : e.data['amount'] as int? ?? 0),
        );
    final previous = _attackDamage;
    _attackDamage = amount;
    _runAbility(actor, primary == null ? [] : [primary], effects, () {
      _attackDamage = previous;
      _attackCaps.remove(pending.id);
      _finishAttackSkillCopies(actor, pending, complete);
    });
  }

  void _finishAttackSkillCopies(
    CharacterInstance actor,
    PendingResolution pending,
    void Function() complete,
  ) {
    final primary = pending.targets.firstOrNull;
    final damageEvents = state.events
        .where(
          (e) =>
              e.type == 'damage' &&
              e.data['actionId'] == pending.id &&
              e.data['targetId'] == primary &&
              e.data['sourceId'] == actor.instanceId &&
              e.data['attack'] == true &&
              e.data['kind'] != DamageKind.lifeLoss.name,
        )
        .toList();
    final damage = damageEvents.fold<int>(
      0,
      (n, e) => n + (e.data['amount']! as int),
    );
    final main = state.events
        .where(
          (e) =>
              e.type == 'damage' &&
              e.data['actionId'] == pending.id &&
              e.data['targetId'] == primary &&
              e.data['component'] == 'main',
        )
        .firstOrNull;
    final copied = pending.armedAttacks
        .where((a) => a.rule.copyDamage && a.targetId != null)
        .toList();
    final chaseSkills = <(SkillInstance, SkillInstance)>[
      for (final owned in actor.skills.toList())
        if (owned.definition.mechanism == SkillMechanism.copyPublicSkill)
          for (final execution in _copyCandidates(actor, owned))
            (owned, execution)
        else
          (owned, owned),
    ];
    void chase(int index) {
      if (!actor.alive ||
          primary == null ||
          damage <= 0 ||
          index == chaseSkills.length) {
        complete();
        return;
      }
      final target = _character(primary);
      final (owned, skill) = chaseSkills[index];
      final checkpoint = skill.definition.checkpoint;
      if (!target.alive ||
          checkpoint?.at != SkillCheckpoint.afterAttack ||
          target.hp > checkpoint!.maximumTargetHp ||
          !_settlementUsable(actor, skill)) {
        chase(index + 1);
        return;
      }
      _offerCheckpoint(
        actor,
        owned,
        skill,
        target,
        {'damage': damage, 'targetId': primary},
        () {
          actor.extraTurns += checkpoint.extraTurns;
          actor.extraTurnTargets.addAll(
            List.filled(checkpoint.extraTurns, primary),
          );
          _event('extraTurnGranted', {
            'actorId': actor.instanceId,
            'targetId': primary,
            'count': checkpoint.extraTurns,
          });
        },
        () => chase(index + 1),
      );
    }

    void copy(int index) {
      if (index == copied.length) {
        chase(0);
        return;
      }
      final target = _character(copied[index].targetId!);
      final copiedDamage =
          _damageAmountVersion == 0 ||
              copied[index].rule.copyDamageBasis == AttackCopyBasis.actualDamage
          ? damage
          : damageEvents.fold<int>(
              0,
              (n, e) => n + (e.data['actualHpLost'] as int? ?? 0),
            );
      if (!actor.alive || !target.alive || copiedDamage <= 0 || main == null) {
        copy(index + 1);
        return;
      }
      _damageAsync(
        actor,
        target,
        copiedDamage,
        DamageKind.values.byName(main.data['kind']! as String),
        () => copy(index + 1),
        attack: true,
      );
    }

    copy(0);
  }
}
