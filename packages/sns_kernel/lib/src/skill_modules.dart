part of 'engine.dart';

extension _SkillModules on GameKernel {
  SkillInstance _ownedModuleSkill(CharacterInstance actor, String id) =>
      _usableSkill(actor, id);

  Iterable<SkillInstance> _copyCandidates(
    CharacterInstance actor,
    SkillInstance owned,
  ) => _skillCopyModule.candidates(
    actor.instanceId,
    state.publicSkillHistory.values,
    owned,
  );

  SkillInstance _executionSkill(
    CharacterInstance actor,
    SkillInstance owned,
    UseSkillCommand command,
  ) {
    if (owned.definition.mechanism != SkillMechanism.copyPublicSkill) {
      if (command.copiedSkillId != null) {
        throw StateError('This skill cannot copy another skill');
      }
      if (owned.definition.mechanism != SkillMechanism.replayRecord &&
          (command.recordId != null || command.reverse)) {
        throw StateError('This skill cannot replay records');
      }
      return owned;
    }
    final execution = _copyCandidates(
      actor,
      owned,
    ).where((s) => s.definition.id == command.copiedSkillId).firstOrNull;
    if (execution == null) {
      throw StateError('Skill is hidden, already copied, or not copyable');
    }
    if (execution.definition.mechanism != SkillMechanism.replayRecord &&
        (command.recordId != null || command.reverse)) {
      throw StateError('Copied skill cannot replay records');
    }
    return execution;
  }

  bool _canPrepareSkillCards(CharacterInstance actor, SkillDefinition skill) {
    final generatesAction = _walkEffects(
      skill.effects,
    ).any((e) => e is GenerateChosenCard && e.use == GeneratedCardUse.action);
    return generatesAction
        ? actor.actionsRemaining > 0 && !_blocked(actor, (s) => s.blockCards)
        : _canPrepareCards(actor);
  }

  void _checkExecutionCosts(CharacterInstance actor, SkillInstance skill) {
    if (!_conditionMatches(skill.definition.when, actor, actor)) {
      throw StateError('Skill requirement not met');
    }
    if (skill.definition.beforeCards &&
        !_canPrepareSkillCards(actor, skill.definition)) {
      throw StateError('Skill requires an available card action');
    }
    if (skill.definition.beforeAttack && actor.actionsRemaining <= 0) {
      throw StateError('Skill requires an available attack action');
    }
    if (_negateSkills(actor)) return;
    if (_skillLifeCost(actor, skill.definition) > 0 &&
        !actor.defenseLife &&
        actor.hp < _skillLifeCost(actor, skill.definition)) {
      throw StateError('Insufficient life resource');
    }
    for (final cost in skill.definition.statCosts.entries) {
      if (actor.value(cost.key) < cost.value) {
        throw StateError('Insufficient stat resource');
      }
    }
    _checkMp(actor, _skillMpCost(actor, skill.definition));
    if (!_canPayMarks(
      actor,
      _interactionRulesVersion >= 23
          ? _skillMarkCosts(skill.definition)
          : skill.definition.markCosts,
    )) {
      throw StateError('Insufficient marks');
    }
  }

  List<MarkCost> _skillMarkCosts(SkillDefinition definition) => [
    ...definition.markCosts,
    if (definition.numberParameter?.markCostId case final id?
        when _abilityNumber > 0)
      MarkCost(id, _abilityNumber),
  ];

  RecordedAction _ownedRecord(CharacterInstance actor, String? id) =>
      (_recordingModule.records[actor.instanceId] ?? const <RecordedAction>[])
          .where((r) => r.id == id)
          .firstOrNull ??
      (throw StateError('Record is not owned or already consumed'));

  List<CardInstance> _replayCards(RecordedAction record, bool reverse) => [
    for (final card in record.cards)
      if (!reverse || card.definition.mirrorCardId != null)
        CardInstance(
          card.instanceId,
          reverse
              ? catalog.cards[card.definition.mirrorCardId]!
              : card.definition,
        )..reinforced = card.reinforced,
  ];

  List<EffectDefinition> _modulePreparationEffects(
    CharacterInstance actor,
    SkillInstance skill,
    UseSkillCommand command,
  ) {
    if (skill.definition.mechanism != SkillMechanism.replayRecord) {
      final previous = _abilityNumber;
      _abilityNumber = command.number ?? 0;
      List<EffectDefinition> flatten(List<EffectDefinition> effects) => [
        for (final e in effects)
          ...((e is ConditionalEffect &&
                  _conditionValues(e.when).isNotEmpty &&
                  _conditionValues(e.when)
                      .expand(_valueTree)
                      .every(
                        (v) =>
                            (v.reference == null ||
                                v.reference == 'input.number') &&
                            (v.field == null ||
                                v.field == ValueField.inputNumber),
                      ))
              ? flatten(
                  _conditionMatches(e.when, actor, actor)
                      ? e.effects
                      : e.otherwise,
                )
              : [e]),
      ];
      try {
        return flatten(skill.definition.effects);
      } finally {
        _abilityNumber = previous;
      }
    }
    final record = _ownedRecord(actor, command.recordId);
    return [
      for (final card in _replayCards(record, command.reverse)) ...[
        ...card.definition.effects,
        ...card.definition.onHit,
      ],
    ];
  }

  void _confirmModuleSkill(
    PlayerInstance player,
    SkillInstance owned,
    SkillInstance execution,
    UseSkillCommand command,
  ) {
    final suppressed = _negateSkills(player.character);
    final preparation = PendingPreparation(
      state.id('preparation'),
      player.id,
      player.character.noMp
          ? 0
          : _skillMpCost(
                  player.character,
                  execution.definition,
                  number: command.number,
                ) +
                (suppressed ? 0 : _targetSurcharge(command.targetIds)),
      {
        'kind': 'useSkill',
        'instanceId': owned.instanceId,
        'definitionId': execution.definition.id,
        'targetIds': command.targetIds,
        'copiedSkillId': command.copiedSkillId,
        'recordId': command.recordId,
        'reverse': command.reverse,
        'number': command.number,
        'lifeCost': suppressed
            ? 0
            : _skillLifeCost(
                player.character,
                execution.definition,
                number: command.number,
              ),
        'cooldown': execution.definition.cooldown,
        'markCosts': [
          for (final cost
              in suppressed ? <MarkCost>[] : execution.definition.markCosts)
            {'markId': cost.markId, 'amount': cost.amount},
        ],
      },
    )..ready = true;
    state.preparation = preparation;
    _preparationCommit = () => _useSkill(player, command);
    _event('abilityPrepared', {
      'preparationId': preparation.id,
      'playerId': player.id,
    });
  }

  void _commitModuleSkill(
    CharacterInstance actor,
    SkillInstance owned,
    SkillInstance execution,
    UseSkillCommand command,
  ) {
    _checkSkillNumber(actor, execution.definition, command.number);
    final previous = _abilityNumber;
    _abilityNumber = command.number ?? 0;
    try {
      _commitModuleSkillBody(actor, owned, execution, command);
      final index = state.events.lastIndexWhere(
        (e) =>
            e.type == 'skillUsed' &&
            e.data['actorId'] == actor.instanceId &&
            e.data['skillId'] == execution.definition.id,
      );
      _addLogDetails(index, {
        if (command.cardInstanceId != null)
          'logCardInstanceId': command.cardInstanceId,
        if (command.number != null) 'logInputNumber': command.number,
        if (command.diceResult != null) 'logDiceResult': command.diceResult,
      });
    } finally {
      _abilityNumber = previous;
    }
  }

  void _commitModuleSkillBody(
    CharacterInstance actor,
    SkillInstance owned,
    SkillInstance execution,
    UseSkillCommand command,
  ) {
    _checkExecutionCosts(actor, execution);
    if (execution.definition.mechanism == SkillMechanism.replayRecord) {
      final record = _ownedRecord(actor, command.recordId);
      _recordingModule.commit(actor.instanceId, record);
      _event('recordConsumed', {
        'actorId': actor.instanceId,
        'recordId': record.id,
      });
    }
    if (owned.definition.mechanism == SkillMechanism.copyPublicSkill) {
      _skillCopyModule.markUsed(
        actor.instanceId,
        execution.definition.id,
        allowRepeat: owned.definition.copyPolicy.allowRepeat,
      );
      owned.revealed = true;
      state.publicSkillHistory[owned.definition.id] = owned.definition;
      _commitSkill(actor, execution, command.targetIds);
      owned.cooldown = execution.cooldown;
      owned.cooldownAnchor = execution.cooldownAnchor;
      owned.uses++;
      owned.remainingUses = execution.remainingUses;
      if (owned.remainingUses == 0) actor.skills.remove(owned);
      _event('skillCopied', {
        'actorId': actor.instanceId,
        'instanceId': owned.instanceId,
        'skillId': execution.definition.id,
        'cooldown': owned.cooldown,
      });
    } else {
      _commitSkill(actor, owned, command.targetIds);
    }
  }

  void _runSkillResolution(
    CharacterInstance actor,
    PendingResolution pending,
    void Function() complete,
  ) {
    final logIndex = state.events.lastIndexWhere(
      (event) =>
          event.type == 'skillUsed' &&
          event.data['actorId'] == actor.instanceId &&
          event.data['skillId'] == pending.skill!.definition.id,
    );
    final effectStart = state.events.length;
    void finish() {
      _finishAbilityLog(logIndex, effectStart, pending.targets);
      complete();
    }

    if (pending.suppressedEffects) {
      finish();
      return;
    }
    if (pending.skill!.definition.mechanism != SkillMechanism.replayRecord) {
      _runAbility(
        actor,
        pending.targets,
        pending.skill!.definition.effects,
        () => _settleDeaths(finish),
        conditionalBranches: pending.conditionalBranches,
        skillTargeting: true,
        number: pending.number,
        rollOrigin: RollContext(
          actorId: actor.instanceId,
          purpose: RollPurpose.skill,
          actionId: pending.id,
          definitionId: pending.skill!.definition.id,
        ),
      );
      return;
    }
    final record = _recordingModule.takeCommitted(pending.replayRecord)!;
    final cards = _replayCards(record, pending.reverseReplay);
    _attackDamage = pending.reverseReplay
        ? 0
        : (record.damage * pending.skill!.definition.replayPolicy.damageFactor)
              .floor();
    _discardedCount = 0;
    _attackAdjustment = 0;
    _attackEffectMultiplier = 1;
    final target = _character(pending.targets.single);
    _flowSteps([
      () {
        if (pending.reverseReplay) {
          _heal(
            actor,
            target,
            (record.damage *
                    pending.skill!.definition.replayPolicy.healingFactor)
                .floor(),
          );
        } else {
          _damage(
            actor,
            target,
            (record.damage *
                    pending.skill!.definition.replayPolicy.damageFactor)
                .floor(),
            DamageKind.physical,
          );
        }
        _event('recordReplayed', {
          'actorId': actor.instanceId,
          'targetId': target.instanceId,
          'recordId': record.id,
          'reverse': pending.reverseReplay,
          if (_interactionRulesVersion >= 1) ...{
            'damage': record.damage,
            'cards': [for (final card in record.cards) card.definition.id],
          },
        });
      },
      () {
        void next(int index) {
          if (!actor.alive || index == cards.length) {
            finish();
            return;
          }
          final card = cards[index];
          _discardedCount = 0;
          _runAbility(
            actor,
            pending.targets,
            [...card.definition.effects, ...card.definition.onHit],
            () => next(index + 1),
            multiplier: card.reinforced ? 2 : 1,
            skillTargeting: true,
            cards: cards,
          );
        }

        next(0);
      },
    ]);
  }

  Map<String, Object?> _copyOption(
    SkillInstance skill,
    CharacterInstance actor, {
    PendingResolution? pending,
  }) => {
    'copiedSkillId': skill.definition.id,
    'timing': skill.definition.timing.name,
    'mpCost': skill.definition.mpCost,
    'cooldown': skill.definition.cooldown,
    'minTargets': _responseMinTargets(skill.definition),
    'maxTargets': skill.definition.maxTargets,
    'requiresDiceResult': skill.definition.effects.any(
      (e) => e is SetDiceResult,
    ),
    if (_interactionRulesVersion >= 23) ...{
      'input': {
        'targets': {
          'min': _responseMinTargets(skill.definition),
          'max': skill.definition.maxTargets,
          'candidateIds': _skillTargetCandidates(actor, skill.definition),
        },
        if (pending != null &&
            skill.definition.effects.any((e) => e is SetDiceResult))
          'diceResult': {'min': 1, 'max': pending.maximumDiceResult},
        if (pending != null &&
            skill.definition.effects.any((e) => e is CancelCard))
          'cards': [
            for (final card in pending.cards)
              {
                'instanceId': card.instanceId,
                'definitionId': card.definition.id,
              },
          ],
      },
      if (skill.definition.numberParameter case final parameter?)
        'numberParameter': {
          'minimum': parameter.minimum,
          'maximum': parameter.maximumValue == null
              ? parameter.maximum
              : _amount(
                  0,
                  parameter.maximumValue,
                  actor,
                  actor,
                ).clamp(0, parameter.maximum),
          'allowedValues': parameter.allowedValues,
        },
    },
    'markCosts': [
      for (final cost in skill.definition.markCosts)
        {'markId': cost.markId, 'amount': cost.amount},
    ],
  };

  List<Map<String, Object?>> _moduleOptions(CharacterInstance actor) => [
    for (final owned in actor.skills)
      if (owned.definition.mechanism != SkillMechanism.ordinary)
        {
          'instanceId': owned.instanceId,
          'mechanism': owned.definition.mechanism.name,
          if (owned.definition.mechanism == SkillMechanism.copyPublicSkill)
            'copyOptions': [
              for (final copy in _copyCandidates(actor, owned))
                _copyOption(copy, actor),
            ],
          if (_interactionRulesVersion >= 1)
            'records': [
              for (final r
                  in _recordingModule.records[actor.instanceId] ??
                      const <RecordedAction>[])
                {
                  'id': r.id,
                  'damage': r.damage,
                  'cards': [for (final c in r.cards) c.definition.id],
                },
            ],
          'recordIds': [
            for (final r
                in _recordingModule.records[actor.instanceId] ??
                    const <RecordedAction>[])
              r.id,
          ],
        },
  ];
}
