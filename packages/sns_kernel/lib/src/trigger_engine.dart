part of 'engine.dart';

/// Facts are immutable snapshots. Queue entries also capture eligible instances.
final class _TriggerFact {
  _TriggerFact(
    this.timing, {
    this.subject,
    this.source,
    this.target,
    this.skill,
    this.packetId,
    this.actionId,
    this.definitionId,
    this.amount = 0,
    this.skillCooldown = 0,
    this.baseDamage = 0,
    this.statusIntensity = 0,
    this.statusStackDelta = 0,
    this.negativeStatus = false,
    this.attack = false,
    this.independent = false,
    this.kind,
    this.data = const {},
    List<String> selected = const [],
    Map<String, int> tags = const {},
  }) : selected = List.unmodifiable(selected),
       tags = Map.unmodifiable(tags);
  final Map<String, Object?> data;
  final TriggerTiming timing;
  final String? subject;
  final String? source;
  final String? target;
  final String? skill;
  final String? packetId;
  final String? actionId;
  final String? definitionId;
  final int amount;
  final int skillCooldown;
  final int baseDamage;
  final int statusIntensity;
  final int statusStackDelta;
  final bool negativeStatus;
  final bool attack;
  final bool independent;
  final DamageKind? kind;
  final List<String> selected;
  final Map<String, int> tags;
}

final class _TriggerInvocation {
  _TriggerInvocation({
    required this.owner,
    required this.instanceId,
    required this.index,
    required this.definition,
    required this.memory,
    required this.fact,
    required this.ancestors,
    this.trait,
    this.skill,
    this.status,
    this.armed,
    this.race = false,
  }) : intensity = status?.intensity ?? armed?.multiplier ?? 1;
  final CharacterInstance owner;
  final String instanceId;
  final int index;
  final int intensity;
  final TriggerDefinition definition;
  final TriggerMemory memory;
  final _TriggerFact fact;
  final Set<String> ancestors;
  final TraitInstance? trait;
  final SkillInstance? skill;
  final StatusInstance? status;
  final ArmedTrigger? armed;
  final bool race;
  String get key => '$instanceId/$index';
}

extension _TriggerEngine on GameKernel {
  bool _hasTriggerListener(TriggerTiming timing) {
    if (state.armedTriggers.any(
      (a) => a.triggers.any((t) => t.timing == timing),
    )) {
      return true;
    }
    for (final player in state.players) {
      final c = player.character;
      if (!c.alive) continue;
      if (c.race.triggers.any((t) => t.timing == timing) ||
          c.traits.any(
            (i) => i.definition.triggers.any((t) => t.timing == timing),
          ) ||
          c.skills.any(
            (i) => i.definition.triggers.any((t) => t.timing == timing),
          ) ||
          c.statuses.any(
            (i) => i.definition.triggers.any((t) => t.timing == timing),
          )) {
        return true;
      }
    }
    return false;
  }

  EffectValue? _contextValue(EffectDefinition effect) {
    if (_queryEffectReferences(effect).any((r) => r.startsWith('event.'))) {
      return const EffectValue(field: ValueField.eventAmount);
    }
    for (final root in _effectValues(effect)) {
      for (final value in _valueTree(root)) {
        if ((value.reference?.startsWith('event.') ?? false) ||
            value.perIntensity ||
            value.field == ValueField.statusIntensity ||
            value.field == ValueField.eventAmount ||
            value.field == ValueField.eventTagCount ||
            value.field == ValueField.eventSkillCooldown ||
            value.field == ValueField.eventStatusIntensity ||
            value.field == ValueField.eventStatusStackDelta ||
            value.field == ValueField.eventAttackBaseDamage ||
            value.field == ValueField.counter) {
          return value;
        }
      }
    }
    return null;
  }

  void _checkTriggers(
    List<CounterDefinition> counters,
    List<TriggerDefinition> triggers, {
    bool status = false,
  }) {
    final names = counters.map((c) => c.id).toSet();
    if (names.length != counters.length ||
        counters.any(
          (c) =>
              c.id.isEmpty ||
              c.initial < 0 ||
              (c.maximum != null && c.maximum! < c.initial),
        )) {
      throw StateError('Invalid counter definitions');
    }
    for (final t in triggers) {
      _checkChoiceCondition(t.when);
      _checkChoiceCondition(t.guard);
      for (final root in [
        ..._conditionValues(t.when),
        ..._conditionValues(t.guard),
        for (final update in t.counterUpdates)
          if (update.value != null) update.value!,
      ]) {
        if (_valueTree(
          root,
        ).any((v) => v.reference?.startsWith('local.') ?? false)) {
          throw StateError(
            'Trigger eligibility and counters cannot read effect-local bindings',
          );
        }
      }
      _checkEffects(t.effects);
      _validateNamedResults(t.effects);
      for (final update in t.counterUpdates) {
        if (update.value != null) _checkValue(update.value!);
      }
      if (t.recordOnly &&
          (t.effects.any((e) => e is! ModifyVariable) ||
              (t.counterUpdates.isEmpty && t.effects.isEmpty))) {
        throw StateError(
          'Record-only trigger must only update counters or variables',
        );
      }
      _validateAbilityTargets(t.effects, ['eventTarget']);
      final selectsStatus = _walkEffects(
        t.effects,
      ).whereType<ChooseEffect>().any((e) => e.kind == ChoiceKind.status);
      if ((t.maxUses != null && t.maxUses! <= 0) ||
          t.counterUpdates.any((u) => !names.contains(u.counter)) ||
          (t.threshold != null &&
              (!names.contains(t.threshold!.counter) ||
                  t.threshold!.every <= 0))) {
        throw StateError('Invalid trigger counter, threshold or limit');
      }
      for (final e in _walkEffects(t.effects)) {
        _checkVariableContext(e, allowEvent: true);
        if (e is ModifyStat &&
            _walkEffects(
              e.onClamp,
            ).any((e) => e is ChooseEffect || e is SelectOptionEffect)) {
          throw StateError('onClamp must remain atomic');
        }
        for (final root in _effectValues(e)) {
          for (final v in _valueTree(root)) {
            if ((v.field == ValueField.eventStatusStackDelta &&
                    ![
                      TriggerTiming.statusApplied,
                      TriggerTiming.statusIncreased,
                    ].contains(t.timing)) ||
                (v.field == ValueField.eventSkillCooldown &&
                    t.timing != TriggerTiming.skillUsed) ||
                (v.field == ValueField.eventAttackBaseDamage &&
                    t.timing != TriggerTiming.attackDamageDealt)) {
              throw StateError(
                'Event snapshot field does not match trigger timing',
              );
            }
            if (v.field == ValueField.cardCount ||
                v.field == ValueField.cardTagCount ||
                ((v.field == ValueField.statusStacks ||
                        v.field == ValueField.statusStrength) &&
                    v.statusId == null &&
                    !selectsStatus)) {
              throw StateError(
                'Trigger expressions require explicit state, not an ability selection',
              );
            }
            if ((v.field == ValueField.counter && !names.contains(v.counter)) ||
                (!status &&
                    (v.perIntensity ||
                        v.field == ValueField.statusIntensity))) {
              throw StateError('Invalid nested contextual expression');
            }
          }
        }
        if ((e is ModifyAttackPower &&
                (t.timing != TriggerTiming.attackPreparing &&
                    !(t.timing == TriggerTiming.cardsPlayed &&
                        _requiresAttack(t.when)))) ||
            (e is ModifyAttack && t.timing != TriggerTiming.attackPreparing) ||
            (e is SetCounter && !names.contains(e.counter)) ||
            (e is ConditionalEffect &&
                e.when is CounterEqualsCondition &&
                !names.contains((e.when as CounterEqualsCondition).counter)) ||
            (e is RollEffect &&
                [e.atMost, e.atLeast].any(
                  (v) =>
                      v?.field == ValueField.counter &&
                      !names.contains(v!.counter),
                ))) {
          throw StateError('Invalid trigger choice or counter');
        }
        if ((e is DamageEffect && e.fromStatusSource && !status) ||
            (e is StealLife && e.fromStatusSource && !status) ||
            ((_contextValue(e)?.perIntensity ?? false) && !status) ||
            (_contextValue(e)?.field == ValueField.statusIntensity &&
                !status) ||
            e is SetDiceResult ||
            e is CancelSkill ||
            ((e is ModifyOwnStatus || e.target == EffectTarget.statusSource) &&
                !status) ||
            (e is ModifyCooldown &&
                e.usedSkillOnly &&
                t.timing != TriggerTiming.skillUsed) ||
            (_contextValue(e)?.field == ValueField.counter &&
                !names.contains(_contextValue(e)!.counter))) {
          throw StateError('Invalid contextual trigger operator');
        }
      }
    }
  }

  int _window(CounterReset reset, CharacterInstance owner) => switch (reset) {
    CounterReset.never => 0,
    CounterReset.turn => state.turn,
    CounterReset.round => state.round,
    CounterReset.ownerTurn => owner.turnsStarted,
    CounterReset.personalRound => owner.turnsClosed,
  };

  void _resetMemory(
    CharacterInstance owner,
    TriggerMemory memory,
    List<CounterDefinition> counters,
    List<TriggerDefinition> triggers,
  ) {
    for (final c in counters) {
      final window = _window(c.reset, owner);
      if (memory.counterWindows[c.id] != window) {
        memory.counterWindows[c.id] = window;
        memory.counters[c.id] = c.initial;
      }
    }
    for (var i = 0; i < triggers.length; i++) {
      final window = _window(triggers[i].limitWindow, owner);
      if (memory.useWindows[i] != window) {
        memory.useWindows[i] = window;
        memory.uses[i] = 0;
      }
    }
  }

  void _resetTriggerWindows() {
    _resetVariableWindows();
    for (final p in state.players) {
      _resetMemory(
        p.character,
        p.character.raceTriggerMemory,
        p.character.race.counters,
        p.character.race.triggers,
      );
      for (final t in p.character.traits) {
        _resetMemory(
          p.character,
          t.triggerMemory,
          t.definition.counters,
          t.definition.triggers,
        );
      }
      for (final s in p.character.skills) {
        _resetMemory(
          p.character,
          s.triggerMemory,
          s.definition.counters,
          s.definition.triggers,
        );
      }
      for (final s in p.character.statuses) {
        _resetMemory(
          p.character,
          s.triggerMemory,
          s.definition.counters,
          s.definition.triggers,
        );
      }
    }
  }

  void _queueFact(String type, Map<String, Object?> d) {
    final actor = d['actorId'] as String?;
    final source = d['sourceId'] as String?;
    final target = d['targetId'] as String?;
    final amount = (d['amount'] ?? d['count'] ?? 0) as int;
    final tags = (d['tagCounts'] as Map<String, int>?) ?? const <String, int>{};
    void emit(
      TriggerTiming timing,
      String? subject, {
      int? value,
      DamageKind? kind,
      String? from,
      String? to,
    }) {
      _enqueueTrigger(
        _TriggerFact(
          timing,
          data: _freezeEventData(d),
          subject: subject,
          source: from ?? source ?? actor,
          target: to ?? target,
          packetId: d['packetId'] as String?,
          actionId: d['actionId'] as String?,
          skill: type == 'skillUsed' ? d['instanceId'] as String? : null,
          definitionId:
              (d['skillId'] ?? d['cardId'] ?? d['statusId']) as String?,
          selected: (d['targets'] as List<String>?) ?? const [],
          amount: value ?? amount,
          skillCooldown: (d['cooldown'] as int? ?? 0).clamp(0, 1000000000),
          baseDamage: d['baseDamage'] as int? ?? 0,
          statusIntensity: d['intensity'] as int? ?? 0,
          statusStackDelta: d['stackDelta'] as int? ?? 0,
          negativeStatus:
              d['negative'] == true ||
              (_interactionRulesVersion >= 11 &&
                  type == 'damage' &&
                  catalog.statuses[d['statusId']]?.negative == true &&
                  _isStatusEffect(catalog.statuses[d['statusId']])),
          attack: d['attack'] == true || type == 'attackPacketResolved',
          independent: d['independent'] == true,
          kind: kind,
          tags: tags,
        ),
      );
    }

    switch (type) {
      case 'damage':
        if (amount <= 0) return;
        final kind = DamageKind.values.byName(d['kind']! as String);
        if (kind != DamageKind.lifeLoss) {
          emit(TriggerTiming.damageReceived, target, kind: kind);
        }
        final hpLost = d['hpLost'] as int? ?? amount;
        if (hpLost > 0) {
          emit(TriggerTiming.hpLost, target, kind: kind, value: hpLost);
        }
        if (source != null && kind != DamageKind.lifeLoss) {
          emit(TriggerTiming.damageDealt, source, kind: kind);
        }
      case 'observedActionResolved':
        emit(TriggerTiming.actionResolved, actor);
      case 'attackDamageReceived':
        emit(TriggerTiming.attackDamageReceived, target);
      case 'attackDamageSettled':
        emit(TriggerTiming.attackDamageSettled, target);
      case 'attackDamageDealt':
        emit(TriggerTiming.attackDamageDealt, source);
      case 'cardsPlayed':
        final count = (d['cards']! as List).length;
        final lost = d['handLossCount'] as int? ?? count;
        if (lost > 0) emit(TriggerTiming.cardsLost, actor, value: lost);
        emit(TriggerTiming.cardsPlayed, actor, value: count);
      case 'cardsLost':
        if (amount > 0) emit(TriggerTiming.cardsLost, actor);
      case 'cardsDiscarded':
        emit(
          TriggerTiming.cardsLost,
          actor,
          value: (d['cards']! as List).length,
        );
      case 'cardPlayed':
        emit(TriggerTiming.cardPlayed, actor, value: 1);
      case 'cardsDrawn':
        if (amount > 0) emit(TriggerTiming.cardsDrawn, actor);
      case 'healed':
        if (amount > 0) emit(TriggerTiming.healed, target);
      case 'mpSpent':
        if (amount > 0) emit(TriggerTiming.actualMpSpent, actor, value: amount);
        final nominal = d['nominalAmount'] as int? ?? amount;
        if (nominal > 0) {
          emit(TriggerTiming.mpSpent, actor, value: nominal);
          emit(TriggerTiming.mpChanged, actor, value: -nominal, to: actor);
        }
      case 'diceRolled':
        emit(TriggerTiming.diceRolled, actor, value: d['result']! as int);
      case 'skillDrawn':
        emit(TriggerTiming.skillDrawn, actor, value: 1);
      case 'negativeMpEntered':
        emit(TriggerTiming.negativeMpEntered, target);
      case 'mpChanged':
        if (amount < 0) {
          emit(TriggerTiming.actualMpSpent, target, value: -amount);
        }
        final nominal = d['nominalAmount'] as int? ?? amount;
        final semantic =
            amount == 0 &&
                nominal < 0 &&
                target != null &&
                _character(target).noMp
            ? nominal
            : amount;
        if (semantic != 0) {
          emit(TriggerTiming.mpChanged, target, value: semantic);
        }
        final overflow = d['overflow'] as int? ?? 0;
        if (overflow > 0) {
          emit(TriggerTiming.mpOverflow, target, value: overflow);
        }
      case 'mpRegenerated':
        if (amount != 0) emit(TriggerTiming.mpChanged, actor, to: actor);
        final overflow = d['overflow'] as int? ?? 0;
        if (overflow > 0) {
          emit(TriggerTiming.mpOverflow, actor, value: overflow, to: actor);
        }
      case 'attackPacketResolved':
        if (d['outcome'] == 'hit') {
          emit(
            TriggerTiming.attackHit,
            source,
            value: 1,
            kind: DamageKind.values.byName(d['kind']! as String),
          );
        }
        if (d['outcome'] == 'dodged') {
          emit(TriggerTiming.attackDodged, target, value: 1);
        }
      case 'attackDeclared':
        emit(TriggerTiming.attackDeclared, actor);
        for (final id in (d['targets'] as List<String>? ?? const <String>[])) {
          emit(TriggerTiming.attackTargetDeclared, id, from: actor, to: id);
        }
      case 'actionCommitted':
        emit(TriggerTiming.actionCommitted, actor);
      case 'traitTriggered':
        emit(TriggerTiming.traitTriggered, actor);
      case 'impact':
        emit(TriggerTiming.impact, target);
      case 'lifeStolen':
        if (amount > 0) {
          emit(TriggerTiming.hpLost, target, kind: DamageKind.lifeLoss);
        }
      case 'lifePaid':
      case 'actionLifePaid':
        if (amount > 0) {
          emit(
            TriggerTiming.lifePaid,
            actor,
            kind: DamageKind.lifeLoss,
            to: actor,
          );
        }
      case 'attackReceived':
        emit(TriggerTiming.attackReceived, target);
      case 'attackPreparing':
        emit(TriggerTiming.attackPreparing, actor);
      case 'skillUsed':
        emit(TriggerTiming.skillUsed, actor);
      case 'statusApplied':
        if (!_isStatusEffect(catalog.statuses[d['statusId']])) return;
        emit(TriggerTiming.statusApplied, target);
        if ((d['stackDelta'] as int? ?? 0) > 0 ||
            (d['intensityDelta'] as int? ?? 0) > 0) {
          emit(
            TriggerTiming.statusIncreased,
            target,
            value:
                (d['stackDelta'] as int? ?? 0).clamp(0, 1000000) +
                (d['intensityDelta'] as int? ?? 0).clamp(0, 1000000),
          );
        }
      case 'statusModified':
        if (!_isStatusEffect(catalog.statuses[d['statusId']])) return;
        if ((d['stackDelta'] as int? ?? 0) > 0 ||
            (d['intensityDelta'] as int? ?? 0) > 0) {
          emit(
            TriggerTiming.statusIncreased,
            target,
            value:
                (d['stackDelta'] as int? ?? 0).clamp(0, 1000000) +
                (d['intensityDelta'] as int? ?? 0).clamp(0, 1000000),
          );
        }
      case 'statusRemoved':
        if (!_isStatusEffect(catalog.statuses[d['statusId']])) return;
        emit(
          TriggerTiming.statusRemoved,
          d['ownerId'] as String?,
          to: d['ownerId'] as String?,
        );
      case 'shieldGained':
        if (amount > 0) emit(TriggerTiming.shieldGained, target);
      case 'shieldBroken':
        emit(TriggerTiming.shieldBroken, target);
      case 'characterDied':
        emit(
          TriggerTiming.characterDied,
          d['instanceId'] as String?,
          to: d['instanceId'] as String?,
        );
      case 'roundEnding':
        emit(TriggerTiming.roundEnd, null);
      case 'strengthenedAttack':
        emit(TriggerTiming.strengthenedAttack, source);
      case 'roundStarted':
        emit(TriggerTiming.roundStart, null);
    }
  }

  void _enqueueTrigger(_TriggerFact fact) {
    if (_triggerBudgetExhausted) return;
    final subjectTeam = fact.subject == null
        ? null
        : state.players
              .firstWhere((p) => p.character.instanceId == fact.subject)
              .teamId;
    for (final p in state.players) {
      final owner = p.character;
      void add(
        String id,
        TriggerMemory memory,
        List<CounterDefinition> counters,
        List<TriggerDefinition> triggers, {
        TraitInstance? trait,
        SkillInstance? skill,
        StatusInstance? status,
        ArmedTrigger? armed,
        bool race = false,
      }) {
        if (!(skill != null && _blocked(owner, (s) => s.blockSkills))) {
          _resetMemory(owner, memory, counters, triggers);
        }
        for (var i = 0; i < triggers.length; i++) {
          final t = triggers[i];
          if (t.timing != fact.timing) continue;
          final suppressed =
              !t.recordOnly &&
              !t.ignoreSuppression &&
              ((trait != null && _blocked(owner, (s) => s.blockTraits)) ||
                  (skill != null && _blocked(owner, (s) => s.blockSkills)));
          if (suppressed && (_statisticsRulesVersion < 2 || _previewMode)) {
            continue;
          }
          final scopeMatches =
              fact.subject == null ||
              switch (t.scope) {
                TriggerScope.self => owner.instanceId == fact.subject,
                TriggerScope.allies => p.teamId == subjectTeam,
                TriggerScope.enemies => p.teamId != subjectTeam,
                TriggerScope.all => true,
              };
          if (!scopeMatches) continue;
          if (_previewMode) {
            throw const PreviewBoundary('unprojectedTriggerHistory');
          }
          final ancestors = {
            ...?_currentTrigger?.ancestors,
            if (_currentTrigger != null) _currentTrigger!.key,
          };
          if (ancestors.contains('$id/$i')) continue;
          final invocation = _TriggerInvocation(
            owner: owner,
            instanceId: id,
            index: i,
            definition: t,
            memory: memory,
            fact: fact,
            ancestors: Set.unmodifiable(ancestors),
            trait: trait,
            skill: skill,
            status: status,
            armed: armed,
            race: race,
          );
          if (!_triggerCondition(t.when, invocation)) continue;
          if (suppressed) {
            final group = t.limitGroup;
            final uses = group == null
                ? (memory.uses[i] ?? 0)
                : memory.groupWindows[group] == _window(t.limitWindow, owner)
                ? (memory.groupUses[group] ?? 0)
                : 0;
            if ((t.maxUses == null || uses < t.maxUses!) &&
                _triggerCondition(t.guard, invocation) &&
                (t.threshold == null ||
                    (memory.counters[t.threshold!.counter] ?? 0) >=
                        t.threshold!.every)) {
              if (trait != null) _performance.traitSuppressed(owner);
              if (skill != null) _performance.skillSuppressed(owner);
            }
            continue;
          }
          _triggerQueue.add(invocation);
        }
      }

      for (final armed in state.armedTriggers.where(
        (a) => a.ownerId == owner.instanceId,
      )) {
        add(armed.id, armed.memory, const [], armed.triggers, armed: armed);
      }
      if (!owner.alive) continue;
      add(
        '${owner.instanceId}/race',
        owner.raceTriggerMemory,
        owner.race.counters,
        owner.race.triggers,
        race: true,
      );
      for (final t in owner.traits) {
        add(
          t.instanceId,
          t.triggerMemory,
          t.definition.counters,
          t.definition.triggers,
          trait: t,
        );
      }
      for (final skill in owner.skills) {
        if (!skill.leasedOut &&
            (!_blocked(owner, (s) => s.blockSkills) ||
                (_statisticsRulesVersion >= 2 && !_previewMode))) {
          add(
            skill.instanceId,
            skill.triggerMemory,
            skill.definition.counters,
            skill.definition.triggers,
            skill: skill,
          );
        }
      }
      for (final s in owner.statuses) {
        if (fact.timing == TriggerTiming.attackDamageSettled &&
            !((fact.data['eligibleStatuses'] as List?)?.contains(
                  s.instanceId,
                ) ??
                false)) {
          continue;
        }
        add(
          s.instanceId,
          s.triggerMemory,
          s.definition.counters,
          s.definition.triggers,
          status: s,
        );
      }
    }
  }

  bool _stillEligible(_TriggerInvocation entry) =>
      (entry.owner.alive || entry.armed != null) &&
      (entry.armed == null || state.armedTriggers.contains(entry.armed)) &&
      (entry.trait == null ||
          (entry.owner.traits.contains(entry.trait) &&
              (entry.definition.recordOnly ||
                  entry.definition.ignoreSuppression ||
                  !_blocked(entry.owner, (s) => s.blockTraits)))) &&
      (entry.status == null || entry.owner.statuses.contains(entry.status)) &&
      (entry.skill == null ||
          (entry.owner.skills.contains(entry.skill) &&
              !entry.skill!.leasedOut &&
              !_blocked(entry.owner, (s) => s.blockSkills)));

  void _drainTriggers() {
    if (_drainingTriggers ||
        _triggerInProgress ||
        state.choice != null ||
        state.pending != null ||
        (_settlingAttack && _packetSettlementDepth == 0) ||
        _damageDepth > 0) {
      return;
    }
    _drainingTriggers = true;
    try {
      while (_triggerQueue.isNotEmpty &&
          !_triggerInProgress &&
          state.choice == null) {
        final entry = _triggerQueue.removeFirst();
        if (!_stillEligible(entry) ||
            !_triggerCondition(entry.definition.guard, entry)) {
          continue;
        }
        final t = entry.definition;
        final memory = entry.memory;
        final counters =
            entry.trait?.definition.counters ??
            entry.status?.definition.counters ??
            entry.skill?.definition.counters ??
            (entry.race
                ? entry.owner.race.counters
                : const <CounterDefinition>[]);
        for (final update in t.counterUpdates) {
          final definition = counters.firstWhere((c) => c.id == update.counter);
          final next =
              memory.counters[update.counter]! + _counterDelta(update, entry);
          memory.counters[update.counter] = next < 0
              ? 0
              : (definition.maximum != null && next > definition.maximum!
                    ? definition.maximum!
                    : next);
        }
        final threshold = t.threshold;
        final count = threshold == null
            ? (t.repeatPerAmount ? entry.fact.amount : 1)
            : memory.counters[threshold.counter]! ~/ threshold.every;
        final group = t.limitGroup;
        if (group != null &&
            memory.groupWindows[group] != _window(t.limitWindow, entry.owner)) {
          memory.groupWindows[group] = _window(t.limitWindow, entry.owner);
          memory.groupUses[group] = 0;
        }
        final packetKey = entry.fact.packetId == null
            ? null
            : '${entry.index}/${entry.fact.packetId}';
        void run(int i) {
          if (i >= count) {
            _triggerInProgress = false;
            return;
          }
          if ((t.oncePerPacket &&
                  packetKey != null &&
                  memory.packetUses.contains(packetKey)) ||
              !_stillEligible(entry) ||
              (t.maxUses != null &&
                  (group == null
                          ? (memory.uses[entry.index] ?? 0)
                          : (memory.groupUses[group] ?? 0)) >=
                      t.maxUses!)) {
            _triggerInProgress = false;
            return;
          }
          if (_triggerBudget-- <= 0) {
            _triggerBudgetExhausted = true;
            _triggerQueue.clear();
            _event('triggerBudgetExceeded', {'limit': 256});
            _triggerInProgress = false;
            return;
          }
          if (threshold != null) {
            memory.counters[threshold.counter] =
                memory.counters[threshold.counter]! - threshold.every;
          }
          memory.uses[entry.index] = (memory.uses[entry.index] ?? 0) + 1;
          if (group != null) {
            memory.groupUses[group] = (memory.groupUses[group] ?? 0) + 1;
          }
          if (t.oncePerPacket && packetKey != null) {
            memory.packetUses.add(packetKey);
          }
          final effectStart = state.events.length;
          _runAbility(
            entry.owner,
            entry.fact.selected,
            t.effects,
            () {
              if (entry.status != null) {
                _statusSettlementCompleted(entry.owner, entry.status!);
              }
              final previousTrigger = _currentTrigger;
              _currentTrigger = entry;
              if (entry.trait != null && !t.recordOnly) {
                _event('traitTriggered', {
                  'actorId': entry.owner.instanceId,
                  'traitId': entry.trait!.definition.id,
                  if (_interactionRulesVersion >= 2)
                    'logStartSequence': effectStart + 1,
                  'logTargetIds': _abilityLogTargets(effectStart, [
                    entry.owner.instanceId,
                  ]),
                });
              }
              if (entry.skill != null && !t.recordOnly) {
                entry.skill!.revealed = true;
                state.publicSkillHistory[entry.skill!.definition.id] =
                    entry.skill!.definition;
                _event('skillTriggered', {
                  'actorId': entry.owner.instanceId,
                  'skillId': entry.skill!.definition.id,
                  if (_interactionRulesVersion >= 2)
                    'logStartSequence': effectStart + 1,
                  'logTargetIds': _abilityLogTargets(effectStart, [
                    entry.owner.instanceId,
                  ]),
                });
              }
              if (entry.race && !t.recordOnly) {
                _event('raceTriggered', {
                  'actorId': entry.owner.instanceId,
                  'raceId': entry.owner.race.id,
                });
              }
              final armed = entry.armed;
              if (armed != null &&
                  armed.triggers.indexed.every(
                    (pair) =>
                        pair.$2.maxUses != null &&
                        (armed.memory.uses[pair.$1] ?? 0) >= pair.$2.maxUses!,
                  )) {
                state.armedTriggers.remove(armed);
              }
              _currentTrigger = previousTrigger;
              run(i + 1);
              if (!_triggerInProgress) _drainTriggers();
            },
            multiplier: t.scaleWithIntensity ? entry.intensity : 1,
            triggerContext: entry,
          );
        }

        _triggerInProgress = true;
        run(0);
      }
    } finally {
      _currentTrigger = null;
      _drainingTriggers = false;
    }
  }
}
