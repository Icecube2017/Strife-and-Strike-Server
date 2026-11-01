part of 'engine.dart';

/// The parent is already waiting in the flow queue. A child window resolves its
/// own reactions first, then resumes that parent exactly once.
final class _InterruptibleSkill {
  _InterruptibleSkill({
    required this.parentWindowId,
    required this.resolve,
    required this.finish,
    required this.depth,
    this.responseAttack,
  });
  final String? parentWindowId;
  final PendingResolution? responseAttack;
  final int depth;
  final void Function(void Function()) resolve;
  final void Function() finish;
}

extension _ResponseEngine on GameKernel {
  int _responseCardCost(CharacterInstance actor, CardInstance card) {
    if (!_blocked(actor, (s) => s.blockTraits) &&
        actor.traits.any(
          (t) => card.definition.tags.any(t.definition.freeCardTags.contains),
        )) {
      return 0;
    }
    final scale =
        card.reinforced ||
            actor.statuses.any((s) => s.definition.reinforceFirstCard)
        ? 2
        : 1;
    var cost =
        (card.definition.mpCost +
                card.definition.actionCostBonus * scale -
                _actionDiscount(actor))
            .clamp(0, 1000000);
    for (final status in actor.statuses) {
      final cap = status.definition.cardMpCap;
      if (cap != null && cost > cap) cost = cap;
    }
    return actor.noMp ? 0 : cost;
  }

  List<CardInstance> _responseCards(
    PlayerInstance player,
    PendingResolution pending,
  ) {
    if (_interactionRulesVersion < 10 ||
        !player.character.alive ||
        _blocked(player.character, (s) => s.blockCards)) {
      return [];
    }
    final actor = player.character;
    final attack = _interruptibleSkills[pending.id]?.responseAttack;
    final dodge =
        pending.kind == PendingKind.attack &&
        pending.targets.contains(actor.instanceId);
    final counter =
        attack != null &&
        attack.actorId == player.id &&
        pending.cards.any((c) => c.definition.response == CardResponse.dodge);
    if (!dodge && !counter) return [];
    return actor.hand
        .where(
          (card) =>
              !card.disabled &&
              !card.definition.tags.any(
                (tag) => _cardTagRestricted(actor, tag),
              ) &&
              (!counter || !_blocked(actor, (s) => s.blockAttackCards)) &&
              _effectiveCard(actor, card).definition.response ==
                  (dodge ? CardResponse.dodge : CardResponse.counterDodge) &&
              (actor.noMp ||
                  (actor.mp - _mpFloor(actor) > 0 &&
                      actor.mp - _mpFloor(actor) >=
                          _responseCardCost(actor, card))) &&
              (actor.cardLifeCost == 0 ||
                  actor.defenseLife ||
                  actor.hp >= actor.cardLifeCost),
        )
        .toList();
  }

  CardInstance _validateResponseCard(
    PlayerInstance player,
    RespondCardCommand command,
    PendingResolution pending,
  ) {
    if (command.pendingActionId != pending.windowId) {
      throw StateError('Stale response');
    }
    return _responseCards(
          player,
          pending,
        ).where((c) => c.instanceId == command.cardInstanceId).firstOrNull ??
        (throw StateError('Response card is unavailable'));
  }

  void _executeResponseCard(
    PlayerInstance player,
    CardInstance card,
    PendingResolution parent,
  ) {
    final actor = player.character;
    final attack = parent.kind == PendingKind.attack
        ? parent
        : _interruptibleSkills[parent.id]!.responseAttack!;
    final targets = card.definition.response == CardResponse.counterDodge
        ? attack.targets
        : [actor.instanceId];
    final paidCost = _responseCardCost(actor, card);
    _scoreActionFee(
      actor,
      card.definition.mpCost +
          card.definition.actionCostBonus * _cardScale(card),
      paidCost,
      cards: true,
    );
    _payMp(actor, paidCost);
    final reinforcement = actor.statuses
        .where((s) => s.definition.reinforceFirstCard)
        .firstOrNull;
    if (reinforcement != null) {
      _temporaryReinforcement.putIfAbsent(card, () => card.reinforced);
      card.reinforced = true;
      _consumeStatus(actor, reinforcement);
      _event('cardReinforced', {
        'actorId': actor.instanceId,
        'instanceId': card.instanceId,
      });
    }
    actor.hand.remove(card);
    state.discardPile.add(card);
    if (actor.cardLifeCost > 0 && !actor.defenseLife) {
      actor.hp -= actor.cardLifeCost;
      _event('actionLifePaid', {
        'actorId': actor.instanceId,
        'amount': actor.cardLifeCost,
      });
      _normalize(actor);
    }
    _recordPlayedCards(
      actor,
      targets,
      [card],
      handLossCount: 1,
      response: true,
      complete: () {
        if (!actor.alive) return;
        _openInterruptibleSkill(
          player,
          null,
          targets,
          parentWindowId: parent.windowId,
          cards: [card],
          responseAttack: attack,
          resolve: (complete) {
            if (card.definition.response == CardResponse.counterDodge) {
              attack.cards = List.unmodifiable([...attack.cards, card]);
              complete();
            } else {
              _runCardEffects(actor, [actor.instanceId], [card], complete);
            }
          },
          complete: () {},
        );
      },
    );
  }

  void _openInterruptibleSkill(
    PlayerInstance player,
    SkillInstance? skill,
    List<String> targets, {
    String? parentWindowId,
    int? number,
    bool suppressed = false,
    bool deferDeath = false,
    List<CardInstance> cards = const [],
    PendingResolution? responseAttack,
    Map<(ConditionalEffect, String), bool> branches = const {},
    required void Function(void Function()) resolve,
    required void Function() complete,
  }) {
    final parentTrigger = _currentTrigger;
    final triggerWasRunning = _triggerInProgress;
    final actorId = player.character.instanceId;
    final pending = PendingResolution(
      id: state.id('action'),
      kind: skill == null ? PendingKind.cards : PendingKind.skill,
      actorId: player.id,
      targets: targets,
      skill: skill,
      cards: cards,
      number: number,
      suppressedEffects: suppressed,
      conditionalBranches: branches,
    );
    if (deferDeath) {
      _deferredDeathSkills.update(actorId, (n) => n + 1, ifAbsent: () => 1);
    }
    final parent = _interruptibleSkills[parentWindowId];
    _interruptibleSkills[pending.id] = _InterruptibleSkill(
      parentWindowId: parentWindowId,
      responseAttack: responseAttack,
      depth: (parent?.depth ?? 0) + 1,
      resolve: (complete) {
        if (cards.isNotEmpty && pending.cards.isEmpty) {
          complete();
        } else {
          resolve(complete);
        }
      },
      finish: () {
        _currentTrigger = parentTrigger;
        _triggerInProgress = triggerWasRunning;
        if (deferDeath) {
          final remaining = _deferredDeathSkills[actorId]! - 1;
          if (remaining == 0) {
            _deferredDeathSkills.remove(actorId);
          } else {
            _deferredDeathSkills[actorId] = remaining;
          }
        }
        complete();
      },
    );
    // A dying character can be inside an automatic trait/roll continuation.
    // That context must stay suspended while peers answer the new declaration.
    _currentTrigger = null;
    _triggerInProgress = false;
    _flowSteps([
      _drainTriggers,
      () {
        if (player.character.alive) {
          _openResponse(pending);
        } else {
          _interruptibleSkills.remove(pending.id)!.finish();
        }
      },
    ]);
  }

  SkillTiming _responseTiming(PendingResolution pending) =>
      (pending.kind == PendingKind.attack || pending.kind == PendingKind.dice)
      ? SkillTiming.diceResponse
      : pending.kind == PendingKind.cards
      ? SkillTiming.actionResponse
      : SkillTiming.skillResponse;

  bool _matchesResponseTiming(
    SkillDefinition skill,
    PendingResolution pending,
  ) {
    if (pending.kind == PendingKind.dice) {
      return (skill.anytime &&
              skill.effects.isNotEmpty &&
              skill.effects.every((e) => e is TransferReceivedDamage)) ||
          (skill.timing == SkillTiming.diceResponse &&
              skill.effects.isNotEmpty &&
              skill.effects.every((e) => e is SetDiceResult));
    }
    return skill.anytime ||
        skill.timing == _responseTiming(pending) ||
        (skill.timing == SkillTiming.actionResponse &&
            pending.kind == PendingKind.attack);
  }

  int _remainingCardDice(PendingResolution pending) =>
      pending.forcedDiceSides ??
      pending.cards.fold<int>(
        pending.baseDiceSides,
        (sides, c) => _cardDiceSides(c) ?? sides,
      );

  int _responseMinTargets(SkillDefinition skill) {
    final selected = skill.effects.any(
      (e) =>
          e.target == EffectTarget.selected &&
          e is! SetDiceResult &&
          e is! CancelSkill,
    );
    return selected && skill.minTargets < 1 ? 1 : skill.minTargets;
  }

  String? _responseProblem(
    PlayerInstance player,
    SkillInstance skill,
    PendingResolution pending, {
    int? number,
  }) => _withSkillNumber(
    number,
    () => _responseProblemBody(player, skill, pending, number: number),
  );

  String? _responseProblemBody(
    PlayerInstance player,
    SkillInstance skill,
    PendingResolution pending, {
    int? number,
  }) {
    final actor = player.character;
    if (_interactionRulesVersion >= 2 &&
        pending.kind != PendingKind.dice &&
        player.id == pending.actorId) {
      return 'requiresOtherActor';
    }
    if (skill.definition.passive) return 'passiveSkill';
    if (skill.definition.effects.any((e) => e is RedirectAttack) &&
        pending.kind != PendingKind.attack) {
      return 'requiresAttack';
    }
    if (pending.diceLocked &&
        _walkEffects(skill.definition.effects).any((e) => e is SetDiceResult)) {
      return 'diceLocked';
    }
    if (!actor.alive) return 'playerDead';
    if (skill.leasedOut) return 'skillBorrowed';
    if (skill.definition.mechanism == SkillMechanism.copyPublicSkill) {
      if (skill.cooldown > 0) return 'cooldown';
      if (skill.remainingUses == 0) return 'exhausted';
      return _copyCandidates(actor, skill).any(
            (s) => _responseProblem(player, s, pending, number: number) == null,
          )
          ? null
          : 'noCopyCandidates';
    }
    if (!_matchesResponseTiming(skill.definition, pending)) {
      return 'wrongTiming';
    }
    if (skill.definition.effects.whereType<CancelSkill>().any(
          (e) => e.othersOnly,
        ) &&
        pending.actorId == player.id) {
      return 'requiresOtherActor';
    }
    if (skill.definition.effects.any((e) => e is CancelCard) &&
        pending.cards.isEmpty) {
      return 'noAttachedCards';
    }
    if (_blocked(actor, (s) => s.blockSkills)) return 'skillsBlocked';
    if (!_negateSkills(actor) &&
        !actor.defenseLife &&
        actor.hp <
            (_interactionRulesVersion >= 23
                ? _skillLifeCost(actor, skill.definition)
                : skill.definition.lifeCost)) {
      return 'insufficientLife';
    }
    if (!_conditionMatches(skill.definition.when, actor, actor)) {
      return 'requirementsNotMet';
    }
    if (!_negateSkills(actor) &&
        skill.definition.statCosts.entries.any(
          (c) => actor.value(c.key) < c.value,
        )) {
      return 'insufficientStatResource';
    }
    if (!_negateSkills(actor) &&
        !_canPayMarks(actor, skill.definition.markCosts)) {
      return 'insufficientMarks';
    }
    if (skill.remainingUses == 0) return 'exhausted';
    if (skill.cooldown > 0) return 'cooldown';
    if (!actor.noMp &&
        actor.mp - _mpFloor(actor) < _skillMpCost(actor, skill.definition)) {
      return 'insufficientMp';
    }
    final minimum = _responseMinTargets(skill.definition);
    if (minimum > skill.definition.maxTargets ||
        state.players
                .where(
                  (p) =>
                      _skillTargetAllowed(actor, skill.definition, p.character),
                )
                .length <
            minimum) {
      return 'notEnoughTargets';
    }
    return null;
  }

  TraitInstance? _recordingTrait(
    PlayerInstance player,
    PendingResolution pending,
  ) {
    if (_interactionRulesVersion < 1 ||
        (pending.kind != PendingKind.attack &&
            pending.kind != PendingKind.cards) ||
        _observedAction?.recordable != true ||
        !player.character.alive ||
        _blocked(player.character, (s) => s.blockTraits)) {
      return null;
    }
    return player.character.traits.where((t) {
      final rule = t.definition.mechanisms.get<ActionRecordingRule>();
      return rule != null &&
          _recordingModule.canRecord(
            player.character.instanceId,
            state.round,
            rule: rule,
          );
    }).firstOrNull;
  }

  void _validateRecording(
    PlayerInstance player,
    RecordActionCommand command,
    PendingResolution pending,
  ) {
    final trait = _recordingTrait(player, pending);
    if (command.pendingActionId != pending.windowId ||
        trait == null ||
        trait.instanceId != command.traitInstanceId) {
      throw StateError('Recording response is unavailable');
    }
    if (pending.cards.isNotEmpty
        ? !pending.cards.any((c) => c.instanceId == command.cardInstanceId)
        : command.cardInstanceId != null) {
      throw StateError('Choose exactly one card attached to this action');
    }
  }

  void _openResponse(PendingResolution pending) {
    state.pending = pending;
    pending.openedVersion = state.version + 1;
    final actorIndex = state.players.indexWhere((p) => p.id == pending.actorId);
    for (var offset = 1; offset <= state.players.length; offset++) {
      final player =
          state.players[(actorIndex + offset) % state.players.length];
      if (_interactionRulesVersion >= 2 &&
          pending.kind != PendingKind.dice &&
          player.id == pending.actorId) {
        if (_recordingTrait(player, pending) != null ||
            _responseCards(player, pending).isNotEmpty) {
          pending.responders.add(player.id);
        }
        continue;
      }
      if (player.character.alive &&
          ((rules.requireAllResponses &&
                  pending.kind != PendingKind.dice &&
                  !_interruptibleSkills.containsKey(pending.id)) ||
              _recordingTrait(player, pending) != null ||
              _responseCards(player, pending).isNotEmpty ||
              player.character.skills.any(
                (s) => _responseProblem(player, s, pending) == null,
              ))) {
        pending.responders.add(player.id);
      }
    }
    _event('responseWindowOpened', {
      'windowId': pending.windowId,
      'participants': List<String>.unmodifiable(pending.responders),
    });
    _finishResponsesIfReady();
  }

  SkillInstance _validateResponse(
    PlayerInstance player,
    UseSkillCommand command,
    PendingResolution pending,
  ) => _withCommandNumber(
    command,
    () => _validateResponseBody(player, command, pending),
  );

  SkillInstance _validateResponseBody(
    PlayerInstance player,
    UseSkillCommand command,
    PendingResolution pending,
  ) {
    if (command.pendingActionId != pending.windowId) {
      throw StateError('Stale response');
    }
    final skill = player.character.skills
        .where((s) => s.instanceId == command.skillInstanceId)
        .firstOrNull;
    if (skill == null) throw StateError('Skill instance is not owned');
    if (_interactionRulesVersion >= 23) {
      final ownedProblem = _responseProblem(
        player,
        skill,
        pending,
        number: command.number,
      );
      if (ownedProblem != null) throw StateError(ownedProblem);
    }
    final execution = _executionSkill(player.character, skill, command);
    if (_previewMode &&
        (execution.definition.markCosts.isNotEmpty ||
            execution.definition.mechanism == SkillMechanism.replayRecord)) {
      throw const PreviewBoundary('unprojectedResponseResource');
    }
    _checkSkillNumber(player.character, execution.definition, command.number);
    final problem = _responseProblem(
      player,
      execution,
      pending,
      number: command.number,
    );
    if (problem != null) throw StateError(problem);
    if (_interactionRulesVersion >= 23) {
      _checkExecutionCosts(player.character, execution);
      if (execution.definition.numberParameter?.countTargets == true &&
          command.targetIds.length != command.number) {
        throw StateError('Number must equal selected target count');
      }
      final effects = _negateSkills(player.character)
          ? <EffectDefinition>[]
          : _modulePreparationEffects(player.character, execution, command);
      _checkHarmfulSkillTargets(
        player.character,
        effects,
        command.targetIds,
        replayDamage:
            execution.definition.mechanism == SkillMechanism.replayRecord &&
            !command.reverse &&
            _ownedRecord(player.character, command.recordId).damage > 0,
      );
      _validateAbilityTargets(effects, command.targetIds);
      _checkNewCopyAttack(player.character, effects, command.targetIds);
    }
    _checkEffects(execution.definition.effects);
    _validateTargets(
      execution.definition,
      command.targetIds,
      actor: player.character,
    );
    _checkMp(
      player.character,
      _skillMpCost(player.character, execution.definition) +
          (_negateSkills(player.character)
              ? 0
              : _targetSurcharge(command.targetIds)),
    );
    final needsDice = execution.definition.effects.any(
      (e) => e is SetDiceResult,
    );
    if (needsDice) {
      final result = command.diceResult;
      if (result == null || result < 1 || result > pending.maximumDiceResult) {
        throw StateError('Dice result is outside the die');
      }
    } else if (command.diceResult != null) {
      throw StateError('This response does not accept a dice result');
    }
    final needsCard = execution.definition.effects.any((e) => e is CancelCard);
    if (needsCard &&
        !pending.cards.any((c) => c.instanceId == command.cardInstanceId)) {
      throw StateError('Choose a card attached to this action');
    }
    if (!needsCard && command.cardInstanceId != null) {
      throw StateError('This response does not accept a card selection');
    }
    return execution;
  }

  void _submitResponse(
    PlayerInstance player,
    KernelCommand command, {
    bool validateOnly = false,
  }) {
    final pending = state.pending!;
    if (!pending.responders.contains(player.id)) {
      throw StateError('Not a response participant');
    }
    if (pending.submissions.containsKey(player.id)) {
      throw StateError('Response already submitted');
    }
    if (command is BeginResponseCommand) {
      if (_interactionRulesVersion < 9 ||
          command.pendingActionId != pending.windowId ||
          pending.responseExpired) {
        throw StateError('Stale response');
      }
      if (_interactionRulesVersion >= 23 &&
          pending.responseSelections.containsKey(player.id)) {
        throw StateError('Response is already reserved');
      }
      final options = _privateResponseWindow(player.id)!['options']! as List;
      if (command.optionId == 'pass' ||
          !options.cast<Map>().any(
            (o) => o['optionId'] == command.optionId && o['enabled'] == true,
          )) {
        throw StateError('Response option is unavailable');
      }
      if (validateOnly) return;
      pending.responseSelections[player.id] = command.optionId;
      // Only participation is public. The selected ability stays private.
      _event('responsePreparationStarted', {
        'windowId': pending.windowId,
        'playerId': player.id,
      });
      return;
    }
    final selectedOption = pending.responseSelections[player.id];
    final commandOption = switch (command) {
      RespondCardCommand() => 'card:${command.cardInstanceId}',
      UseSkillCommand() => 'skill:${command.skillInstanceId}',
      RecordActionCommand() => 'record:${command.traitInstanceId}',
      PassCommand() => 'pass',
      _ => null,
    };
    if (_interactionRulesVersion >= 9 &&
        selectedOption != null &&
        commandOption != 'pass' &&
        commandOption != selectedOption) {
      throw StateError('Response option differs from reservation');
    }
    switch (command) {
      case PassCommand():
        if (command.pendingActionId != pending.windowId) {
          throw StateError('Stale response');
        }
      case RecordActionCommand():
        _validateRecording(player, command, pending);
      case UseSkillCommand():
        _validateResponse(player, command, pending);
      case RespondCardCommand():
        _validateResponseCard(player, command, pending);
      default:
        throw StateError('Only response skills or passing are allowed');
    }
    if (validateOnly) return;
    pending.submissions[player.id] = command;
    // Do not disclose the choice until execution, including skill identity.
    _event('responseSubmitted', {
      'windowId': pending.windowId,
      'playerId': player.id,
    });
    _finishResponsesIfReady();
  }

  void _executeResponse(
    PlayerInstance player,
    UseSkillCommand command,
    SkillInstance skill,
    PendingResolution pending,
  ) => _withCommandNumber(
    command,
    () => _executeResponseBody(player, command, skill, pending),
  );

  void _executeResponseBody(
    PlayerInstance player,
    UseSkillCommand command,
    SkillInstance skill,
    PendingResolution pending,
  ) {
    final conditionalBranches = _captureConditionalBranches(
      player.character,
      command.targetIds,
      skill.definition.effects,
    );
    final owned = _ownedModuleSkill(player.character, command.skillInstanceId);
    final suppressed = _negateSkills(player.character);
    _commitModuleSkill(player.character, owned, skill, command);
    if (_interactionRulesVersion >= 4) {
      _openInterruptibleSkill(
        player,
        skill,
        command.targetIds,
        parentWindowId: pending.windowId,
        number: command.number,
        suppressed: suppressed,
        branches: conditionalBranches,
        resolve: (complete) => _resolveResponseEffects(
          player,
          command,
          skill,
          pending,
          suppressed,
          conditionalBranches,
          complete: complete,
        ),
        complete: () {},
      );
      return;
    }
    _resolveResponseEffects(
      player,
      command,
      skill,
      pending,
      suppressed,
      conditionalBranches,
    );
  }

  void _resolveResponseEffects(
    PlayerInstance player,
    UseSkillCommand command,
    SkillInstance skill,
    PendingResolution pending,
    bool suppressed,
    Map<(ConditionalEffect, String), bool> conditionalBranches, {
    void Function()? complete,
  }) {
    _flowSteps([
      _drainTriggers,
      for (final effect
          in suppressed ? <EffectDefinition>[] : skill.definition.effects)
        () {
          if (!player.character.alive) return;
          switch (effect) {
            case RedirectAttack():
              final from = pending.targets;
              _performance.redirectAttack(
                pending.id,
                player.character,
                _player(pending.actorId).character,
                from,
              );
              pending.targets = List.unmodifiable([
                player.character.instanceId,
              ]);
              _attackCaps[pending.id] = _AttackCap(player.character, effect);
              _event('attackRedirected', {
                'actorId': player.character.instanceId,
                'actionId': pending.id,
                'previousTargets': from,
                'targetId': player.character.instanceId,
              });
            case SetDiceResult():
              _setPendingDice(
                pending,
                command.diceResult!,
                sourceId: skill.definition.id,
              );
              _event('diceChanged', {
                'actionId': pending.id,
                'result': pending.diceResult,
                if (pending.diceRoll != null)
                  'roll': pending.diceRoll!.toJson(),
              });
            case CancelCard():
              _performance.otherEffect(
                player.character,
                _player(pending.actorId).character,
                positive: false,
                kind: 'cancelCard',
              );
              final oldSides = _remainingCardDice(pending);
              pending.cards = List.unmodifiable(
                pending.cards.where(
                  (c) => c.instanceId != command.cardInstanceId,
                ),
              );
              _performance.countered(
                player.character,
                _player(pending.actorId).character,
                card: true,
                action: pending.id,
                wholeAction:
                    pending.kind == PendingKind.cards && pending.cards.isEmpty,
              );
              _event('cardCancelled', {
                'actionId': pending.id,
                'instanceId': command.cardInstanceId,
                'logActorId': player.character.instanceId,
                'logSkillId': skill.definition.id,
              });
              final newSides = _remainingCardDice(pending);
              if (pending.kind == PendingKind.attack && oldSides != newSides) {
                final roller = _player(pending.actorId).character;
                var diceSides = newSides;
                _chooseDamageRoll(
                  roller,
                  () {
                    final roll = _attackRoll(
                      roller,
                      newSides,
                      pending.diceCount,
                      actionId: pending.id,
                      fixedMaximum: pending.diceLocked,
                      rerollOf: pending.diceRoll?.id,
                    );
                    diceSides = roll.spec.nominalSides;
                    _event('diceRolled', {
                      'actorId': roller.instanceId,
                      'actionId': pending.id,
                      'sides': diceSides,
                      'result': roll.finalTotal,
                      'rollId': roll.id,
                      'roll': roll.toJson(),
                      'reroll': true,
                    });
                    return roll;
                  },
                  (roll) {
                    final result = roll.finalTotal;
                    pending.setDiceRoll(_storeRoll(roll));
                    pending.deferredDiceBonus += _growAttackDice(
                      _player(pending.actorId).character,
                      result,
                    );
                    pending
                      ..diceSides = diceSides
                      ..diceResult = result
                      ..rerolled = true;
                  },
                  locked: pending.diceLocked,
                );
              }
            case CancelSkill():
              if (_interactionRulesVersion >= 4 && !pending.cancelled) {
                _performance.otherEffect(
                  player.character,
                  _player(pending.actorId).character,
                  positive: false,
                  kind: 'cancelSkill',
                );
                _performance.countered(
                  player.character,
                  _player(pending.actorId).character,
                );
              }
              pending.cancelled = true;
              if (effect.discardCount > 0) {
                _effects(
                  player.character,
                  [_player(pending.actorId).character.instanceId],
                  [RandomDiscard(effect.discardCount)],
                );
              }
            default:
              final previous = _independentDamage;
              _independentDamage = true;
              final previousBranches = _conditionSnapshots;
              _conditionSnapshots = conditionalBranches;
              try {
                _runAbility(
                  player.character,
                  command.targetIds,
                  [effect],
                  () {},
                  skillTargeting: true,
                  conditionalBranches: conditionalBranches,
                  number: _interactionRulesVersion >= 23
                      ? command.number
                      : null,
                  rollOrigin: RollContext(
                    actorId: player.character.instanceId,
                    purpose: RollPurpose.skill,
                    actionId: pending.id,
                    definitionId: skill.definition.id,
                  ),
                );
              } finally {
                _independentDamage = previous;
                _conditionSnapshots = previousBranches;
              }
          }
        },
      if (complete != null) complete,
    ]);
  }

  void _finishResponsesIfReady() {
    final pending = state.pending!;
    if (pending.waitingPlayerIds.isNotEmpty) return;
    _event('responseWindowClosed', {
      'windowId': pending.windowId,
      'hadOperations': pending.submissions.values.any(
        (command) =>
            command is UseSkillCommand ||
            command is RecordActionCommand ||
            command is RespondCardCommand,
      ),
    });
    state.pending = null;
    if (pending.kind == PendingKind.dice) {
      final hasTransfer = pending.submissions.values
          .whereType<UseSkillCommand>()
          .any(
            (command) => _executionSkill(
              _player(command.playerId).character,
              _ownedModuleSkill(
                _player(command.playerId).character,
                command.skillInstanceId,
              ),
              command,
            ).definition.effects.any((e) => e is TransferReceivedDamage),
          );
      if (!hasTransfer && _interactionRulesVersion < 4) {
        // The parent may itself be a suspended automatic trigger. Pure dice
        // modifiers are synchronous and must not wait behind that trigger.
        for (final id in pending.responders) {
          final command = pending.submissions[id];
          if (command is! UseSkillCommand) continue;
          final skill = _validateResponse(_player(id), command, pending);
          final actor = _player(id).character;
          final suppressed = _negateSkills(actor);
          _commitModuleSkill(
            actor,
            _ownedModuleSkill(actor, command.skillInstanceId),
            skill,
            command,
          );
          if (suppressed) continue;
          _setPendingDice(
            pending,
            command.diceResult!,
            sourceId: skill.definition.id,
          );
          _event('diceChanged', {
            'actionId': pending.id,
            'result': pending.diceResult,
            if (pending.diceRoll != null) 'roll': pending.diceRoll!.toJson(),
          });
        }
        final continuation = _diceContinuation!;
        _diceContinuation = null;
        continuation(pending.diceRoll!);
        return;
      }
      // Damage transfer can suspend for another choice; detach the parent's
      // trigger and roll until its response flow has completed.
      final continuation = _diceContinuation!;
      _diceContinuation = null;
      final trigger = _currentTrigger;
      final triggerWasRunning = _triggerInProgress;
      _currentTrigger = null;
      _triggerInProgress = false;
      _flowSteps([
        for (final id in pending.responders)
          () {
            final command = pending.submissions[id];
            if (command is! UseSkillCommand) return;
            SkillInstance skill;
            try {
              skill = _validateResponse(_player(id), command, pending);
            } on StateError catch (e) {
              _event('responseSkipped', {
                'windowId': pending.windowId,
                'playerId': id,
                'reason': e.message,
              });
              return;
            }
            _executeResponse(_player(id), command, skill, pending);
          },
        () {
          _currentTrigger = trigger;
          _triggerInProgress = triggerWasRunning;
          continuation(pending.diceRoll!);
        },
      ]);
      return;
    }

    _flowSteps([
      for (final id in pending.responders)
        () {
          final command = pending.submissions[id];
          if (command is RecordActionCommand) {
            _observedAction?.recordingSelections[id] = command;
            return;
          }
          if (command is RespondCardCommand) {
            if (pending.cancelled ||
                !_player(pending.actorId).character.alive) {
              return;
            }
            CardInstance card;
            try {
              card = _validateResponseCard(_player(id), command, pending);
            } on StateError catch (e) {
              _event('responseSkipped', {
                'windowId': pending.windowId,
                'playerId': id,
                'reason': e.message,
              });
              return;
            }
            _executeResponseCard(_player(id), card, pending);
            return;
          }
          if (command is! UseSkillCommand) return;
          if (pending.cancelled || !_player(pending.actorId).character.alive) {
            _event('responseSkipped', {
              'windowId': pending.windowId,
              'playerId': id,
              'reason': 'actionUnavailable',
            });
            return;
          }
          SkillInstance skill;
          try {
            skill = _validateResponse(_player(id), command, pending);
            // Kernel validation uses StateError; catch only the pre-payment check.
            // ignore: avoid_catching_errors
          } on StateError catch (e) {
            _event('responseSkipped', {
              'windowId': pending.windowId,
              'playerId': id,
              'reason': e.message,
            });
            return;
          }
          _executeResponse(_player(id), command, skill, pending);
        },
      () {
        final actor = _player(pending.actorId).character;
        final interruptible = _interruptibleSkills.remove(pending.id);
        if (interruptible != null) {
          void finish() {
            _event(
              pending.cancelled || !actor.alive
                  ? 'actionCancelled'
                  : 'actionResolved',
              {'actionId': pending.id},
            );
            interruptible.finish();
          }

          if (actor.alive && !pending.cancelled) {
            interruptible.resolve(finish);
          } else {
            finish();
          }
          return;
        }
        if (actor.alive && !pending.cancelled) {
          if (pending.rerolled) {
            pending
              ..rerolled = false
              ..responseWindowId = state.id('response')
              ..responders.clear()
              ..responseSelections.clear()
              ..responseExpired = false
              ..submissions.clear();
            _offerReroll(
              actor,
              pending.diceSides,
              pending.diceCount,
              pending.diceRoll!,
              (result) {
                pending.setDiceRoll(_storeRoll(result));
                _openResponse(pending);
              },
              generate: () => _rerollPendingAttack(actor, pending),
              damageRoll: true,
              locked: pending.diceLocked,
            );
            return;
          }
          if (pending.kind == PendingKind.cards) {
            _runCardEffects(actor, pending.targets, pending.cards, () {
              _event('actionResolved', {'actionId': pending.id});
              _afterResolution();
            }, includeNonAttackOnHit: pending.constraintAction);
            return;
          }
          if (pending.kind == PendingKind.skill) {
            _runSkillResolution(actor, pending, () {
              _event(actor.alive ? 'actionResolved' : 'actionCancelled', {
                'actionId': pending.id,
              });
              _afterResolution();
            });
            return;
          } else {
            _resolveAttack(actor, pending);
            return;
          }
        }
        _event(
          pending.cancelled || !actor.alive
              ? 'actionCancelled'
              : 'actionResolved',
          {'actionId': pending.id},
        );
        _returnAttackCards(pending.id);
        _afterResolution();
      },
    ]);
  }

  Map<String, Object?>? _publicResponseWindow() {
    final pending = state.pending;
    if (pending == null) return null;
    return {
      'windowId': pending.windowId,
      if (_interruptibleSkills[pending.id] case final frame?) ...{
        'depth': frame.depth,
        'parentWindowId': frame.parentWindowId,
      },
      'kind': pending.kind.name,
      'openedVersion': pending.openedVersion,
      'timeoutSeconds': rules.responseTimeoutSeconds,
      'participantIds': pending.responders.toList(),
      'submittedPlayerIds': pending.responders
          .where(pending.submissions.containsKey)
          .toList(),
      'waitingPlayerIds': pending.waitingPlayerIds,
      if (_interactionRulesVersion >= 9) ...{
        'preparingPlayerIds': pending.responseSelections.keys
            .where((id) => !pending.submissions.containsKey(id))
            .toList(),
        'expired': pending.responseExpired,
      },
    };
  }

  Map<String, Object?>? _privateResponseWindow(String playerId) {
    final pending = state.pending;
    if (pending == null) return null;
    if (_interactionRulesVersion >= 2 &&
        !pending.responders.contains(playerId)) {
      return null;
    }
    final player = _player(playerId);
    final submitted = pending.submissions[playerId];
    final canSubmit =
        player.character.alive &&
        pending.responders.contains(playerId) &&
        submitted == null;
    final unavailable = !player.character.alive
        ? 'playerDead'
        : (!pending.responders.contains(playerId)
              ? 'notParticipant'
              : 'alreadySubmitted');
    bool available(String optionId) =>
        canSubmit &&
        (!pending.responseExpired ||
            pending.responseSelections[playerId] == optionId);
    return {
      'windowId': pending.windowId,
      'stateVersion': state.version,
      'openedVersion': pending.openedVersion,
      'canSubmit': canSubmit,
      'submitted': submitted != null,
      if (_interactionRulesVersion >= 9) ...{
        'canBeginResponse':
            canSubmit &&
            !pending.responseExpired &&
            (_interactionRulesVersion < 23 ||
                pending.responseSelections[playerId] == null),
        'preparingOptionId': pending.responseSelections[playerId],
        'expired': pending.responseExpired,
      },
      'selection': switch (submitted) {
        RespondCardCommand() => {
          'optionId': 'card:${submitted.cardInstanceId}',
        },
        RecordActionCommand() => {
          'optionId': 'record:${submitted.traitInstanceId}',
          'cardInstanceId': submitted.cardInstanceId,
        },
        PassCommand() => {'optionId': 'pass'},
        UseSkillCommand() => {
          'optionId': 'skill:${submitted.skillInstanceId}',
          'targetIds': submitted.targetIds.toList(),
          'diceResult': submitted.diceResult,
          'copiedSkillId': submitted.copiedSkillId,
        },
        _ => null,
      },
      'options': [
        for (final card in _responseCards(player, pending))
          {
            'optionId': 'card:${card.instanceId}',
            'kind': 'playCard',
            'instanceId': card.instanceId,
            'definitionId': card.definition.id,
            'enabled': available('card:${card.instanceId}'),
            'cost': {'mp': _responseCardCost(player.character, card)},
          },
        {
          'optionId': 'pass',
          'kind': 'pass',
          'enabled': canSubmit,
          'disabledReason': canSubmit ? null : unavailable,
        },
        if (_recordingTrait(player, pending) case final trait?)
          {
            'optionId': 'record:${trait.instanceId}',
            'kind': 'recordAction',
            'instanceId': trait.instanceId,
            'definitionId': trait.definition.id,
            'enabled': available('record:${trait.instanceId}'),
            'disabledReason': canSubmit ? null : unavailable,
            'cards': [
              for (final card in pending.cards)
                {
                  'instanceId': card.instanceId,
                  'definitionId': card.definition.id,
                },
            ],
          },
        for (final skill in player.character.skills)
          if (_interactionRulesVersion < 2 ||
              pending.kind == PendingKind.dice ||
              playerId != pending.actorId)
            {
              'optionId': 'skill:${skill.instanceId}',
              'kind': 'useSkill',
              if (skill.definition.mechanism == SkillMechanism.copyPublicSkill)
                'copyOptions': [
                  for (final copy in _copyCandidates(player.character, skill))
                    if (_matchesResponseTiming(copy.definition, pending))
                      {
                        ..._copyOption(
                          copy,
                          player.character,
                          pending: pending,
                        ),
                        'enabled':
                            canSubmit &&
                            _responseProblem(player, copy, pending) == null,
                        'disabledReason': canSubmit
                            ? _responseProblem(player, copy, pending)
                            : unavailable,
                      },
                ],
              'instanceId': skill.instanceId,
              'definitionId': skill.definition.id,
              'enabled':
                  available('skill:${skill.instanceId}') &&
                  _responseProblem(player, skill, pending) == null,
              'disabledReason': canSubmit
                  ? _responseProblem(player, skill, pending)
                  : unavailable,
              'cost': {
                if (skill.definition.lifeCost > 0)
                  'life': skill.definition.lifeCost,
                if (skill.definition.statCosts.isNotEmpty)
                  'stats': {
                    for (final c in skill.definition.statCosts.entries)
                      c.key.name: c.value,
                  },
                'mp': player.character.noMp
                    ? 0
                    : _skillMpCost(player.character, skill.definition),
                if (player.character.noMp)
                  'nominalMp': _skillMpCost(player.character, skill.definition),
                if (skill.definition.markCosts.isNotEmpty)
                  'marks': [
                    for (final cost in _markCosts(
                      skill.definition.markCosts,
                    ).entries)
                      {
                        'markId': cost.key,
                        'amount': cost.value,
                        'available': _markCount(
                          player.character,
                          cost.key,
                          sourceId: player.character.instanceId,
                        ),
                      },
                  ],
              },
              'cooldown': skill.cooldown,
              'input': {
                'targets': {
                  'min': _responseMinTargets(skill.definition),
                  'max': skill.definition.maxTargets,
                  'candidateIds': state.players
                      .where(
                        (p) => _skillTargetAllowed(
                          player.character,
                          skill.definition,
                          p.character,
                        ),
                      )
                      .map((p) => p.character.instanceId)
                      .toList(),
                },
                if (skill.definition.effects.any((e) => e is CancelCard))
                  'cards': [
                    for (final c in pending.cards)
                      {
                        'instanceId': c.instanceId,
                        'definitionId': c.definition.id,
                      },
                  ],
                if (skill.definition.effects.any((e) => e is SetDiceResult))
                  'diceResult': {'min': 1, 'max': pending.maximumDiceResult},
              },
            },
      ],
    };
  }
}
