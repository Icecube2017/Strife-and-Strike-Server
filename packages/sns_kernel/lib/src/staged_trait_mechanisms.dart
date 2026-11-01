part of 'engine.dart';

extension _StagedTraitMechanisms on GameKernel {
  bool _damageRollEffect(RollEffect roll) =>
      roll.damageRoll ||
      _walkEffects([
        ...roll.effects,
        ...roll.otherwise,
      ]).any((e) => e is DamageEffect);

  void _settleStatusEffect(
    CharacterInstance actor,
    List<String> selected,
    SettleStatus effect,
    void Function() complete,
  ) {
    final entries = <(CharacterInstance, StatusInstance)>[
      for (final target in _effectTargets(actor, selected, effect.target))
        if (target.alive)
          for (final status in target.statuses)
            if (status.definition.id == effect.statusId) (target, status),
    ];
    void next(int i) {
      if (i == entries.length) {
        complete();
        return;
      }
      final (owner, status) = entries[i];
      if (!owner.alive || !owner.statuses.contains(status)) {
        next(i + 1);
        return;
      }
      if (effect.phase != null) {
        final effects = effect.phase == SchedulePhase.turnEnd
            ? status.definition.turnEnd
            : status.definition.turnStart;
        final count = effect.allStacks ? status.stacks : 1;
        void settle(int layer) {
          if (layer == count || !owner.alive) {
            next(i + 1);
            return;
          }
          _runAbility(
            owner,
            [owner.instanceId],
            effects,
            () {
              _statusSettlementCompleted(owner, status);
              settle(layer + 1);
            },
            multiplier: status.intensity,
            statusOrigin: status,
          );
        }

        settle(0);
        return;
      }
      final t = status.definition.triggers[effect.triggerIndex];
      final memory = status.triggerMemory;
      _resetMemory(
        owner,
        memory,
        status.definition.counters,
        status.definition.triggers,
      );
      final uses = t.limitGroup == null
          ? memory.uses[effect.triggerIndex] ?? 0
          : memory.groupUses[t.limitGroup] ?? 0;
      if (!effect.ignoreLimits && t.maxUses != null && uses >= t.maxUses!) {
        next(i + 1);
        return;
      }
      if (_triggerBudget-- <= 0) {
        _triggerBudgetExhausted = true;
        _triggerQueue.clear();
        _event('triggerBudgetExceeded', {'limit': 256});
        complete();
        return;
      }
      if (!effect.ignoreLimits) {
        memory.uses.update(
          effect.triggerIndex,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
        if (t.limitGroup != null) {
          memory.groupUses.update(
            t.limitGroup!,
            (n) => n + 1,
            ifAbsent: () => 1,
          );
        }
      }
      final entry = _TriggerInvocation(
        owner: owner,
        instanceId: status.instanceId,
        index: effect.triggerIndex,
        definition: t,
        memory: memory,
        fact: _TriggerFact(
          t.timing,
          subject: owner.instanceId,
          source: status.sourceId,
        ),
        ancestors: {...?_currentTrigger?.ancestors, ?_currentTrigger?.key},
        status: status,
      );
      _runAbility(
        owner,
        [owner.instanceId],
        t.effects,
        () {
          _statusSettlementCompleted(owner, status);
          next(i + 1);
        },
        triggerContext: entry,
        multiplier: t.scaleWithIntensity ? status.intensity : 1,
      );
    }

    next(0);
  }
}
