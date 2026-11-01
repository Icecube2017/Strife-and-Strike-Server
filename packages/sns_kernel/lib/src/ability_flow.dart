part of 'engine.dart';

/// Continuations own their selection, roll and card context across commands.
/// Atomic damage/trigger settlement deliberately does not suspend mid-write.
extension _AbilityFlow on GameKernel {
  Map<(ConditionalEffect, String), bool> _captureConditionalBranches(
    CharacterInstance actor,
    List<String> selected,
    List<EffectDefinition> effects,
  ) {
    final result = <(ConditionalEffect, String), bool>{};
    void visit(List<EffectDefinition> list, List<String> targets) {
      for (final effect in list) {
        if (effect is ConditionalEffect && effect.snapshot) {
          for (final target in _effectTargets(
            actor,
            targets,
            effect.target,
          ).where((c) => c.alive)) {
            final match = _conditionMatches(effect.when, actor, target);
            result[(effect, target.instanceId)] = match;
            visit(
              match ? effect.effects : effect.otherwise,
              effect.eachTarget ? [target.instanceId] : targets,
            );
          }
        }
      }
    }

    visit(effects, selected);
    return Map.unmodifiable(result);
  }

  void _flowSteps(List<void Function()> steps) {
    for (final step in steps.reversed) {
      _flow.addFirst(step);
    }
    _pumpFlow();
  }

  void _pumpFlow() {
    if (_pumpingFlow ||
        _drainingTriggers ||
        _triggerInProgress ||
        state.choice != null ||
        state.pending != null ||
        state.preparation != null) {
      return;
    }
    _pumpingFlow = true;
    try {
      if (_generatedRequests.isNotEmpty) {
        final request = _generatedRequests.removeFirst();
        _flow.addFirst(() => _generatedCardAction(request));
      }
      while (_flow.isNotEmpty &&
          state.choice == null &&
          state.pending == null &&
          state.preparation == null &&
          !_triggerInProgress &&
          !state.finished) {
        _flow.removeFirst()();
        _drainTriggers();
      }
      if (state.finished) _flow.clear();
    } finally {
      _pumpingFlow = false;
    }
  }

  void _validateAbilityTargets(
    List<EffectDefinition> effects,
    List<String> targets,
  ) {
    for (final e in effects) {
      if (e is SelectOptionEffect) {
        for (final option in e.options) {
          _validateAbilityTargets(option.effects, targets);
        }
      } else if (e is WithTargets) {
        _validateAbilityTargets(e.effects, ['boundTarget']);
      } else if (e is ChooseEffect) {
        if (e.chooser == ChoiceChooser.target &&
            (e.target != EffectTarget.self &&
                (e.target != EffectTarget.selected || targets.length != 1))) {
          throw StateError(
            'Target chooser requires exactly one selected owner',
          );
        }
        _validateAbilityTargets(
          e.effects,
          e.kind == ChoiceKind.character || e.kind == ChoiceKind.status
              ? ['selection']
              : targets,
        );
      } else if (e is ConditionalEffect) {
        _validateAbilityTargets(e.effects, targets);
        _validateAbilityTargets(e.otherwise, targets);
      } else if (e is RollEffect) {
        _validateAbilityTargets(
          e.effects,
          e.eachTarget ? ['selection'] : targets,
        );
        _validateAbilityTargets(
          e.otherwise,
          e.eachTarget ? ['selection'] : targets,
        );
      }
    }
  }

  void _runAbility(
    CharacterInstance actor,
    List<String> selected,
    List<EffectDefinition> effects,
    void Function() complete, {
    int multiplier = 1,
    List<CardInstance> cards = const [],
    StatusInstance? chosenStatus,
    int? rolled,
    int? number,
    bool skillTargeting = false,
    _TriggerInvocation? triggerContext,
    StatusInstance? statusOrigin,
    RollContext? rollOrigin,
    AttackPacket? attackPacket,
    bool allowDeadActor = false,
    bool? independentDamage,
    Map<(ConditionalEffect, String), bool>? conditionalBranches,
    Map<String, Object?>? locals,
  }) {
    final independentSnapshot = independentDamage ?? _independentDamage;
    final localsSnapshot = locals ?? Map<String, Object?>.of(_abilityLocals);
    final inheritedTriggerInProgress = _triggerInProgress;
    final numberSnapshot = number ?? _abilityNumber;
    final branchSnapshot = conditionalBranches ?? _conditionSnapshots;
    final triggerSnapshot = triggerContext ?? _currentTrigger;
    final statusSnapshot = statusOrigin ?? _effectStatus;
    final originSnapshot =
        rollOrigin ??
        (triggerContext != null
            ? RollContext(
                actorId: actor.instanceId,
                purpose: triggerContext.status != null
                    ? RollPurpose.status
                    : triggerContext.trait != null
                    ? RollPurpose.trait
                    : triggerContext.skill != null
                    ? RollPurpose.skill
                    : RollPurpose.effect,
                actionId: triggerContext.fact.actionId,
                definitionId:
                    triggerContext.status?.definition.id ??
                    triggerContext.trait?.definition.id ??
                    triggerContext.skill?.definition.id,
              )
            : statusOrigin != null
            ? RollContext(
                actorId: actor.instanceId,
                purpose: RollPurpose.status,
                definitionId: statusOrigin.definition.id,
              )
            : _rollOrigin);
    final scheduledSnapshot = _scheduledValues;
    bool canRun() =>
        actor.alive || allowDeadActor || triggerSnapshot?.armed != null;
    void proceed(void Function() next) {
      if (_generatedRequests.isNotEmpty) {
        final triggerWasRunning = _triggerInProgress;
        _triggerInProgress = false;
        final request = _generatedRequests.removeFirst();
        _generatedCardAction(
          request,
          complete: () {
            _triggerInProgress = triggerWasRunning;
            proceed(next);
          },
        );
        return;
      }
      if (triggerSnapshot != null || inheritedTriggerInProgress) {
        next();
      } else {
        _flowSteps([next]);
      }
    }

    final rollSnapshot = rolled ?? _rolled;
    void context(void Function() action) {
      final oldOrigin = _rollOrigin;
      _rollOrigin = originSnapshot;
      final oldIndependent = _independentDamage;
      _independentDamage = independentSnapshot;
      final oldLocals = _abilityLocals;
      _abilityLocals = localsSnapshot;
      final oldNumber = _abilityNumber;
      _abilityNumber = numberSnapshot;
      final oldCards = _effectCards;
      final oldStatus = _chosenStatus;
      final oldRoll = _rolled;
      final oldTrigger = _currentTrigger;
      final oldBranches = _conditionSnapshots;
      final oldStatusOrigin = _effectStatus;
      final oldScheduled = _scheduledValues;
      _effectStatus = statusSnapshot;
      _scheduledValues = scheduledSnapshot;
      _conditionSnapshots = branchSnapshot;
      _currentTrigger = triggerSnapshot;
      _effectCards = cards;
      _chosenStatus = chosenStatus;
      _rolled = rollSnapshot;
      try {
        action();
      } finally {
        _rollOrigin = oldOrigin;
        _independentDamage = oldIndependent;
        _abilityLocals = oldLocals;
        _abilityNumber = oldNumber;
        _effectCards = oldCards;
        _chosenStatus = oldStatus;
        _rolled = oldRoll;
        _currentTrigger = oldTrigger;
        _conditionSnapshots = oldBranches;
        _effectStatus = oldStatusOrigin;
        _scheduledValues = oldScheduled;
      }
    }

    void run(int index) {
      if (!canRun() || state.finished || index == effects.length) {
        complete();
        return;
      }
      final effect = effects[index];
      _checkPreviewEffect(effect);

      void next() => run(index + 1);
      if (effect is GenerateChosenCard) {
        context(() {
          void generate(CardDefinition definition, String? target) {
            if (effect.use == GeneratedCardUse.nextAttack) {
              actor.preparedCards.add(
                CardInstance(state.id('card'), definition),
              );
              next();
            } else {
              if (effect.consumeAction) {
                if (actor.actionsRemaining <= 0) {
                  throw StateError('No available action');
                }
                actor.actionsRemaining--;
              }
              _generatedCardAction(
                actor,
                definition: definition,
                selectedTarget: target,
                complete: next,
              );
            }
          }

          final prepared = _preparedGeneratedCards.remove(effect);
          if (prepared != null) {
            generate(prepared.$1, prepared.$2);
          } else {
            _openGeneratedChoice(actor, effect, generate);
          }
        });
        return;
      }
      if (effect is ChooseCards) {
        if (_previewMode) throw const PreviewBoundary('hiddenHandChoice');
        context(() {
          final prepared = _preparedHandCards.remove(effect);
          void commit(List<CardInstance> cards) {
            context(() {
              if (effect.bind != null) {
                _bindObjects(
                  effect.bind!,
                  CollectionKind.cards,
                  cards.map((c) => _cardQueryData(c, _cardOwnerId(c))).toList(),
                );
              }
              _commitHandCards(actor, selected, effect, cards);
            });
            next();
          }

          if (prepared != null) {
            commit(prepared);
          } else {
            _openHandChoice(actor, selected, effect, commit);
          }
        });
        return;
      }
      if (effect is ChooseObjects) {
        context(() {
          void commit(List<Map<String, Object?>> rows) {
            context(() => _bindObjects(effect.bind, effect.query.kind, rows));
            next();
          }

          final prepared = _preparedObjectChoices.remove(effect);
          if (prepared != null) {
            commit(prepared);
          } else {
            _openObjectChoice(
              actor,
              selected,
              effect,
              commit,
              enemiesOnly:
                  _interactionRulesVersion >= 23 &&
                  skillTargeting &&
                  _boundTargetsHarm(effect.bind, effects.skip(index + 1)),
            );
          }
        });
        return;
      }
      if (effect is ChooseTargets) {
        context(() {
          final prepared = _preparedBindings.remove(effect);
          if (prepared != null) {
            localsSnapshot[effect.bind] = List<String>.unmodifiable(prepared);
            next();
          } else {
            _openBoundChoice(
              actor,
              selected,
              effect,
              (targets) {
                localsSnapshot[effect.bind] = List<String>.unmodifiable(
                  targets,
                );
                context(next);
              },
              attackPacket: attackPacket,
              enemiesOnly:
                  _interactionRulesVersion >= 23 &&
                  skillTargeting &&
                  _boundTargetsHarm(effect.bind, effects.skip(index + 1)),
            );
          }
        });
        return;
      }
      if (effect is WithTargets) {
        context(() {
          final resolved = _referenceValue(
            effect.reference,
            actor,
            selected.isEmpty ? actor : _character(selected.first),
          );
          final resolvedTargets =
              resolved is Map && resolved['kind'] == 'characters'
              ? (resolved['items'] as List)
                    .map((r) => (r as Map)['instanceId'])
                    .toList()
              : resolved;
          final ids = resolvedTargets is String
              ? [resolvedTargets]
              : resolvedTargets is List
              ? resolvedTargets.cast<String>()
              : throw StateError('Target reference must contain character IDs');
          for (final id in ids) {
            _character(id);
          }
          _runAbility(
            actor,
            ids,
            effect.effects,
            next,
            multiplier: multiplier,
            cards: cards,
            chosenStatus: chosenStatus,
            rolled: rollSnapshot,
            triggerContext: triggerSnapshot,
            statusOrigin: statusSnapshot,
            attackPacket: attackPacket,
            allowDeadActor: allowDeadActor,
            conditionalBranches: branchSnapshot,
            number: numberSnapshot,
            skillTargeting: skillTargeting,
            locals: localsSnapshot,
          );
        });
        return;
      }
      if (effect is SelectOptionEffect) {
        context(
          () => _openAbilityOption(actor, selected, effect, (option) {
            _runAbility(
              actor,
              selected,
              option.effects,
              next,
              multiplier: multiplier,
              cards: cards,
              chosenStatus: chosenStatus,
              rolled: rollSnapshot,
              triggerContext: triggerSnapshot,
              conditionalBranches: branchSnapshot,
              locals: localsSnapshot,
              allowDeadActor: allowDeadActor,
              attackPacket: attackPacket,
              number: numberSnapshot,
              skillTargeting: skillTargeting,
            );
          }, next),
        );
        return;
      }
      if (effect is DisableHandCards || effect is RestrictCardTag) {
        context(
          () => _interactiveContentOperation(actor, selected, effect, next),
        );
        return;
      }
      if (effect is ChooseEffect) {
        if (effect.kind == ChoiceKind.character ||
            effect.kind == ChoiceKind.status) {
          context(
            () => _openSelection(
              actor,
              selected,
              effect,
              multiplier,
              cards,
              chosenStatus,
              rollSnapshot,
              next,
              number: numberSnapshot,
              skillTargeting: skillTargeting,
              attackPacket: attackPacket,
              statusOrigin: statusSnapshot,
            ),
          );
        } else {
          context(
            () => _openChoice(actor, selected, effect, multiplier, ({
              required bool didChoose,
            }) {
              if (!didChoose) {
                next();
                return;
              }
              _runAbility(
                actor,
                selected,
                effect.effects,
                next,
                multiplier: multiplier,
                cards: cards,
                chosenStatus: chosenStatus,
                rolled: rollSnapshot,
                triggerContext: triggerSnapshot,
                conditionalBranches: branchSnapshot,
                locals: localsSnapshot,
                allowDeadActor: allowDeadActor,
                attackPacket: attackPacket,
                number: numberSnapshot,
                skillTargeting: skillTargeting,
              );
            }),
          );
        }
        return;
      }
      if (effect is UseTimeReserve) {
        context(
          () => _reserveModule.useManual(
            actor,
            _effectTargets(actor, selected, effect.target).single,
            next,
          ),
        );
        return;
      }
      if (effect is SettleStatus) {
        context(() => _settleStatusEffect(actor, selected, effect, next));
        return;
      }
      if (effect is ConditionalEffect || effect is RollEffect) {
        var targets = <CharacterInstance>[];
        context(() {
          targets = _effectTargets(
            actor,
            selected,
            effect.target,
            attackPacket: attackPacket,
          ).where((c) => c.alive).toList();
        });
        void each(int i) {
          if (!canRun() || i == targets.length) {
            next();
            return;
          }
          final target = targets[i];
          if (!target.alive) {
            each(i + 1);
            return;
          }
          void branch(
            List<EffectDefinition> effects,
            List<String> branchTargets,
            int branchRoll,
          ) {
            _runAbility(
              actor,
              branchTargets,
              effects,
              () => each(i + 1),
              multiplier: multiplier,
              cards: cards,
              chosenStatus: chosenStatus,
              rolled: branchRoll,
              triggerContext: triggerSnapshot,
              conditionalBranches: branchSnapshot,
              locals: localsSnapshot,
              allowDeadActor: allowDeadActor,
              attackPacket: attackPacket,
              number: numberSnapshot,
              skillTargeting: skillTargeting,
            );
          }

          if (effect is ConditionalEffect) {
            context(
              () => branch(
                (branchSnapshot[(effect, target.instanceId)] ??
                        _conditionMatches(effect.when, actor, target))
                    ? effect.effects
                    : effect.otherwise,
                effect.eachTarget ? [target.instanceId] : selected,
                rollSnapshot,
              ),
            );
          } else {
            final roll = effect as RollEffect;
            context(
              () => _rollAsync(
                roll.roller == ChoiceChooser.actor ? actor : target,
                roll.sides,
                roll.count,
                (result) {
                  context(() {
                    _rolled = result;
                    if (roll.bind != null) localsSnapshot[roll.bind!] = result;
                    final success =
                        (roll.success.isEmpty ||
                            roll.success.contains(result)) &&
                        (roll.atMost == null ||
                            result <= _amount(0, roll.atMost, actor, target)) &&
                        (roll.atLeast == null ||
                            result >= _amount(0, roll.atLeast, actor, target));
                    branch(
                      success ? roll.effects : roll.otherwise,
                      roll.eachTarget ? [target.instanceId] : selected,
                      result,
                    );
                  });
                },
                damageRoll: _damageRollEffect(roll),
              ),
            );
          }
        }

        each(0);
        return;
      }
      if (effect is DamageEffect || effect is TransferReceivedDamage) {
        var targets = <CharacterInstance>[];
        context(() {
          targets = _effectTargets(
            actor,
            selected,
            effect.target,
            attackPacket: attackPacket,
          ).where((c) => c.alive).toList();
        });
        void damage(int i) {
          if (i == targets.length || !canRun()) {
            if (_settlingAttack) {
              proceed(next);
            } else {
              _settleDeaths(() => proceed(next));
            }
            return;
          }
          final target = targets[i];
          context(() {
            if (effect is TransferReceivedDamage) {
              final consumed = _consumeReceivedDamage(actor);
              final amount = consumed.amount;
              final before = actor.hp;
              if (!actor.defenseLife) {
                actor.hp = (actor.hp + consumed.lifeRefund).clamp(
                  0,
                  actor.value(Stat.maxHp),
                );
              }
              _event('damageRefunded', {
                'actorId': actor.instanceId,
                'amount': actor.hp - before,
                'transferredAmount': amount,
                'round': state.round,
              });
              _damageAsync(
                actor,
                target,
                amount,
                DamageKind.physical,
                () => damage(i + 1),
              );
            } else {
              final e = effect as DamageEffect;
              final eventStart = state.events.length;
              final sourceId =
                  triggerSnapshot?.status?.sourceId ?? statusSnapshot?.sourceId;
              final source = e.sourceless
                  ? null
                  : e.fromStatusSource
                  ? (sourceId == null ? null : _character(sourceId))
                  : actor;
              _damageAsync(
                source,
                target,
                _amount(e.amount, e.value, actor, target) * multiplier +
                    _nightmareDamageBonus(
                      triggerSnapshot?.status ?? statusSnapshot,
                    ),
                e.kind,
                () {
                  _healNightmareDamage(
                    triggerSnapshot?.status ?? statusSnapshot,
                    target,
                    eventStart,
                  );
                  final caused = state.events
                      .skip(eventStart)
                      .any(
                        (event) =>
                            event.type == 'damage' &&
                            event.data['targetId'] == target.instanceId &&
                            (event.data['amount']! as int) > 0,
                      );
                  if (caused && e.onDamage.isNotEmpty) {
                    _runAbility(
                      actor,
                      [target.instanceId],
                      e.onDamage,
                      () => damage(i + 1),
                      triggerContext: triggerSnapshot,
                      statusOrigin: statusSnapshot,
                      attackPacket: attackPacket,
                      number: numberSnapshot,
                      skillTargeting: skillTargeting,
                      cards: cards,
                      allowDeadActor: allowDeadActor,
                    );
                  } else {
                    damage(i + 1);
                  }
                },
                attack: attackPacket != null,
                packet: attackPacket,
                secondary: attackPacket != null,
                deferDeaths: true,
              );
            }
          });
        }

        damage(0);
        return;
      }
      if (effect is ModifyStat && effect.stat == Stat.maxHp) {
        var targets = <CharacterInstance>[];
        context(() {
          targets = _effectTargets(
            actor,
            selected,
            effect.target,
            attackPacket: attackPacket,
          ).where((c) => c.alive).toList();
        });
        void modify(int index) {
          if (index == targets.length) {
            proceed(next);
            return;
          }
          final target = targets[index];
          if (attackPacket != null &&
              effect.oncePerAction &&
              !_oncePerAttackEffects.add(effect)) {
            modify(index + 1);
            return;
          }
          context(() {
            final change =
                _amount(effect.amount, effect.value, actor, target) *
                multiplier;
            final previousLimits = _resourceLimits(target);
            target.permanentModifiers.update(
              Stat.maxHp,
              (n) => n + change,
              ifAbsent: () => change,
            );
            final clipped = target.hp > target.value(Stat.maxHp);
            if (clipped) target.hp = target.value(Stat.maxHp);
            _logResourceLimitChanges(target, previousLimits, source: actor);
            void done() {
              if (!_settlingAttack &&
                  target.depleted &&
                  (target.defenseLife || !target.continuesBattle)) {
                _deathAsync(target, () => modify(index + 1));
              } else {
                modify(index + 1);
              }
            }

            if (clipped && effect.onClamp.isNotEmpty) {
              _runAbility(
                actor,
                [target.instanceId],
                effect.onClamp,
                done,
                cards: cards,
                triggerContext: triggerSnapshot,
                statusOrigin: statusSnapshot,
                attackPacket: attackPacket,
                number: numberSnapshot,
                skillTargeting: skillTargeting,
                allowDeadActor: allowDeadActor,
              );
            } else {
              done();
            }
          });
        }

        modify(0);
        return;
      }
      if (effect is StealEffect) {
        var targets = <CharacterInstance>[];
        context(() {
          targets = _effectTargets(
            actor,
            selected,
            effect.target,
            attackPacket: attackPacket,
          ).where((c) => c.alive).toList();
        });
        void steal(int index) {
          if (index == targets.length || !canRun()) {
            proceed(next);
            return;
          }
          final target = targets[index];
          context(
            () => _damageAsync(
              actor,
              target,
              effect.hp * multiplier,
              DamageKind.lifeLoss,
              () {
                context(() {
                  _heal(actor, actor, effect.hp * multiplier);
                  final amount = (effect.attack * multiplier).clamp(
                    0,
                    target.value(Stat.attack),
                  );
                  target.permanentModifiers.update(
                    Stat.attack,
                    (n) => n - amount,
                    ifAbsent: () => -amount,
                  );
                  actor.permanentModifiers.update(
                    Stat.attack,
                    (n) => n + amount,
                    ifAbsent: () => amount,
                  );
                });
                steal(index + 1);
              },
            ),
          );
        }

        steal(0);
        return;
      }
      if (effect is StealLife) {
        var targets = <CharacterInstance>[];
        context(() {
          targets = _effectTargets(
            actor,
            selected,
            effect.target,
            attackPacket: attackPacket,
          ).where((c) => c.alive).toList();
        });
        void steal(int index) {
          if (index == targets.length || !canRun()) {
            if (_settlingAttack) {
              proceed(next);
            } else {
              _settleDeaths(() => proceed(next));
            }
            return;
          }
          final target = targets[index];
          context(() {
            final amount =
                _amount(effect.amount, effect.value, actor, target) *
                multiplier;
            final sourceId =
                triggerSnapshot?.status?.sourceId ?? statusSnapshot?.sourceId;
            final source = effect.fromStatusSource && sourceId != null
                ? _character(sourceId)
                : actor;
            if (source != target &&
                source.alive &&
                amount > 0 &&
                target.alive) {
              final actual = target.defenseLife
                  ? 0
                  : amount.clamp(0, target.hp.clamp(0, 1000000000));
              target.hp -= actual;
              _event('lifeStolen', {
                'sourceId': source.instanceId,
                'targetId': target.instanceId,
                'amount': actual,
                'nominalAmount': amount,
              });
              _heal(source, source, effect.healNominal ? amount : actual);
            }
            steal(index + 1);
          });
        }

        steal(0);
        return;
      }
      if (effect is GenerateRandomAction) {
        context(() {
          final wasRunning = _triggerInProgress;
          final parent = _currentTrigger;
          _triggerInProgress = false;
          _currentTrigger = null;
          try {
            _generatedCardAction(
              actor,
              complete: () {
                _triggerInProgress = wasRunning;
                proceed(next);
              },
            );
          } finally {
            _currentTrigger = parent;
          }
        });
        return;
      }
      if (effect is BorrowSkillEffect) {
        context(
          () => _skillBorrowModule.offer(
            actor,
            rule: effect.rule,
            complete: () => proceed(next),
          ),
        );
        return;
      }
      if (effect is CheckContinuation) {
        if (!actor.alive || !actor.lifeLocked) {
          proceed(next);
          return;
        }
        context(
          () => _rollAsync(actor, effect.sides, 1, (result) {
            if (effect.success.contains(result)) {
              final before = actor.hp;
              actor.setLifeIgnoringContinuation(
                effect.restoreHp.clamp(1, actor.value(Stat.maxHp)),
              );
              _event('lifeRestored', {
                'actorId': actor.instanceId,
                'before': before,
                'hp': actor.hp,
              });
            } else {
              _event('continuationFailed', {'actorId': actor.instanceId});
              _commitDeath(actor);
            }
            proceed(next);
          }),
        );
        return;
      }
      if (effect is DiceContest) {
        context(
          () => _runDiceContest(actor, effect, multiplier, () => proceed(next)),
        );
        return;
      }
      context(
        () => _effects(
          actor,
          selected,
          [effect],
          multiplier: multiplier,
          attackPacket: attackPacket,
        ),
      );
      proceed(next);
    }

    if (!_walkEffects(effects).any(
      (e) =>
          e is ShieldEffect ||
          e is DisableHandCards ||
          e is RestrictCardTag ||
          e is ChooseEffect ||
          e is SelectOptionEffect ||
          e is GenerateRandomAction ||
          e is BorrowSkillEffect ||
          e is CheckContinuation ||
          e is GenerateChosenCard ||
          e is ChooseCards ||
          e is ChooseObjects ||
          e is ChooseTargets ||
          e is WithTargets ||
          e is SettleStatus ||
          e is UseTimeReserve ||
          e is RollEffect ||
          e is DiceContest ||
          e is DamageEffect ||
          e is TransferReceivedDamage ||
          e is StealEffect ||
          e is StealLife ||
          (e is ModifyStat && e.stat == Stat.maxHp),
    )) {
      if (canRun() && !state.finished) {
        context(
          () => _effects(
            actor,
            selected,
            effects,
            multiplier: multiplier,
            attackPacket: attackPacket,
          ),
        );
      }
      proceed(complete);
    } else {
      run(0);
    }
  }

  void _openSelection(
    CharacterInstance actor,
    List<String> selected,
    ChooseEffect effect,
    int multiplier,
    List<CardInstance> cards,
    StatusInstance? parentStatus,
    int rolled,
    void Function() complete, {
    void Function(CharacterInstance?, StatusInstance?)? onSelect,
    int? number,
    bool skillTargeting = false,
    AttackPacket? attackPacket,
    StatusInstance? statusOrigin,
  }) {
    final localsSnapshot = _abilityLocals;
    final triggerContext = _currentTrigger;
    final numberSnapshot = number ?? _abilityNumber;
    final statusSnapshot = statusOrigin ?? _effectStatus;
    if (onSelect == null &&
        _preparedSelections.isNotEmpty &&
        identical(_preparedSelections.first.effect, effect)) {
      final prepared = _preparedSelections.removeFirst();
      final target = prepared.target;
      final status = prepared.status;
      if (target == null ||
          !target.alive ||
          !_attackEffectTargetAllowed(target, attackPacket) ||
          (status != null && !_selectionStatusValid(target, status, effect))) {
        complete();
        return;
      }
      _runAbility(
        actor,
        effect.preserveSelected ? selected : [target.instanceId],
        effect.effects,
        complete,
        multiplier: multiplier,
        cards: cards,
        chosenStatus: status ?? parentStatus,
        rolled: rolled,
        triggerContext: triggerContext,
        locals: localsSnapshot,
        number: numberSnapshot,
        skillTargeting: skillTargeting,
        attackPacket: attackPacket,
        statusOrigin: statusSnapshot,
      );
      return;
    }
    final targets =
        _effectTargets(
              actor,
              selected,
              effect.target,
              attackPacket: attackPacket,
            )
            .where(
              (c) =>
                  c.alive &&
                  (_interactionRulesVersion < 23 ||
                      !skillTargeting ||
                      effect.random ||
                      effect.preserveSelected ||
                      !_selectedEffectsHarm(effect.effects) ||
                      _enemy(actor, c)) &&
                  (!effect.excludeSelected ||
                      !selected.contains(c.instanceId)) &&
                  _conditionMatches(effect.when, actor, c),
            )
            .toList();
    if (effect.random) {
      if (targets.isEmpty) {
        complete();
        return;
      }
      final target = targets[_nextInt(targets.length)];
      _event('randomTargetSelected', {
        'actorId': actor.instanceId,
        'targetId': target.instanceId,
      });
      _runAbility(
        actor,
        [target.instanceId],
        effect.effects,
        complete,
        multiplier: multiplier,
        cards: cards,
        chosenStatus: parentStatus,
        rolled: rolled,
        triggerContext: triggerContext,
        locals: localsSnapshot,
        number: numberSnapshot,
        skillTargeting: skillTargeting,
        attackPacket: attackPacket,
        statusOrigin: statusSnapshot,
      );
      return;
    }
    final options = <Map<String, Object?>>[];
    final resolved = <String, (CharacterInstance, StatusInstance?)>{};
    void add(CharacterInstance c, StatusInstance? s) {
      final id = state.id('option');
      resolved[id] = (c, s);
      options.add({
        'optionId': id,
        'targetId': c.instanceId,
        if (s != null) ...{
          if (s.stacks > 0) 'instanceId': s.instanceId,
          if (s.stacks == 0) 'exists': false,
          'definitionId': s.definition.id,
          'stacks': s.stacks,
          'intensity': s.intensity,
        },
      });
    }

    for (final c in targets) {
      if (effect.kind == ChoiceKind.character) {
        add(c, null);
      } else {
        for (final s in _selectionStatuses(c, effect, actor: actor)) {
          add(c, s);
        }
      }
    }
    if (options.isEmpty) {
      complete();
      return;
    }
    final skipId = effect.optional ? state.id('option') : null;
    if (skipId != null) options.add({'optionId': skipId, 'skip': true});
    final chooser = effect.chooser == ChoiceChooser.target
        ? targets.single
        : actor;
    if (!chooser.alive) {
      complete();
      return;
    }
    final player = state.players.firstWhere((p) => p.character == chooser);
    state.choice = PendingChoice(
      id: state.id('choice'),
      playerId: player.id,
      kind: effect.kind,
      options: options,
    );
    _choiceContinuation = (id) {
      if (id == skipId) {
        if (onSelect != null) {
          onSelect(null, null);
        } else {
          complete();
        }
        return;
      }
      final (target, status) = resolved[id]!;
      if (!target.alive ||
          (status != null && !_selectionStatusValid(target, status, effect))) {
        complete();
        return;
      }
      if (onSelect != null) {
        onSelect(target, status);
        return;
      }
      _runAbility(
        actor,
        effect.preserveSelected ? selected : [target.instanceId],
        effect.effects,
        complete,
        multiplier: multiplier,
        cards: cards,
        chosenStatus: status ?? parentStatus,
        rolled: rolled,
        triggerContext: triggerContext,
        locals: localsSnapshot,
        number: numberSnapshot,
        skillTargeting: skillTargeting,
        attackPacket: attackPacket,
        statusOrigin: statusSnapshot,
      );
    };
    _event('choiceOpened', {
      'choiceId': state.choice!.id,
      'playerId': player.id,
      'kind': effect.kind.name,
    });
  }

  StatusInstance _missingStatus(
    CharacterInstance target,
    StatusDefinition definition,
  ) => StatusInstance(
    instanceId: '',
    definition: definition,
    ownerId: target.instanceId,
    sourceId: null,
    anchorPlayerId: state.activePlayer.id,
    stacks: 0,
    intensity: 0,
  );

  List<StatusInstance> _selectionStatuses(
    CharacterInstance target,
    ChooseEffect effect, {
    CharacterInstance? actor,
  }) {
    final query = _statusChoiceQueryVersion == 0 && effect.statusQueryFromAlias
        ? const StatusQuery()
        : effect.statusQuery;
    if (!effect.includeMissing) {
      return _queryStatuses(
        target,
        query,
        actor: actor,
      ).where((s) => _isStatusEffect(s.definition)).toList();
    }
    final ids = {
      if (query.statusId != null) query.statusId!,
      ...query.statusIds,
    };
    return _queryStatuses(
      target,
      query,
      actor: actor,
      candidates: [
        ...target.statuses,
        for (final id in ids)
          if (!target.statuses.any((s) => s.definition.id == id))
            _missingStatus(target, catalog.statuses[id]!),
      ],
    ).where((s) => _isStatusEffect(s.definition)).toList();
  }

  bool _selectionStatusValid(
    CharacterInstance target,
    StatusInstance status,
    ChooseEffect effect,
  ) =>
      target.statuses.contains(status) ||
      (effect.includeMissing &&
          status.stacks == 0 &&
          status.ownerId == target.instanceId &&
          !target.statuses.any((s) => s.definition.id == status.definition.id));

  List<StatusInstance> _queryStatuses(
    CharacterInstance target,
    StatusQuery q, {
    Iterable<StatusInstance>? candidates,
    CharacterInstance? actor,
  }) {
    final matches = (candidates ?? target.statuses)
        .where(
          (s) => _matchesStatusData(
            _statusQueryData(s),
            q,
            actor ?? target,
            target,
          ),
        )
        .toList();
    return q.latest && matches.isNotEmpty ? [matches.last] : matches;
  }

  StatusInstance? _valueStatus(CharacterInstance target, EffectValue value) =>
      value.statusId == null
      ? (target.statuses.contains(_chosenStatus) ? _chosenStatus : null)
      : target.statuses
            .where((s) => s.definition.id == value.statusId)
            .firstOrNull;

  double _calculateValue(
    EffectValue v,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final a = v.arguments.map((e) => _numberValue(e, actor, target)).toList();
    final result = switch (v.operation!) {
      ValueOperation.add => a.fold<double>(0, (n, x) => n + x),
      ValueOperation.multiply => a.fold<double>(1, (n, x) => n * x),
      ValueOperation.subtract => a[0] - a[1],
      ValueOperation.divide => a[1] == 0 ? 0.0 : a[0] / a[1],
      ValueOperation.modulo => a[1] == 0 ? 0.0 : a[0] % a[1],
      ValueOperation.min => a.reduce((x, y) => x < y ? x : y),
      ValueOperation.max => a.reduce((x, y) => x > y ? x : y),
      ValueOperation.floor => a.single.floorToDouble(),
      ValueOperation.ceil => a.single.ceilToDouble(),
    };
    return (v.constant + result * v.factor)
        .clamp(-1000000000, 1000000000)
        .toDouble();
  }

  Iterable<EffectValue> _valueTree(EffectValue value) sync* {
    yield value;
    for (final child in [
      ...value.arguments,
      if (value.variableIndex != null) value.variableIndex!,
      if (value.collection != null) ..._collectionValues(value.collection!),
    ]) {
      yield* _valueTree(child);
    }
  }

  Iterable<EffectValue> _conditionValues(ConditionDefinition? condition) sync* {
    if (condition is PredicateCondition) {
      for (final operand in condition.arguments) {
        if (operand.expression != null) yield operand.expression!;
        if (operand.reference != null) {
          yield EffectValue(reference: operand.reference);
        }
      }
    } else if (condition is AllCondition) {
      for (final c in condition.conditions) {
        yield* _conditionValues(c);
      }
    } else if (condition is NotCondition) {
      yield* _conditionValues(condition.condition);
    } else if (condition is ValueCondition) {
      yield condition.left;
      yield condition.right;
    } else if (condition is VariableCondition &&
        condition.input.value != null) {
      yield condition.input.value!;
    } else if (condition is AnyCondition) {
      for (final child in condition.conditions) {
        yield* _conditionValues(child);
      }
    } else if (condition is LivingCountCondition) {
      yield* _conditionValues(condition.when);
    }
  }

  Iterable<EffectValue> _effectValues(EffectDefinition effect) sync* {
    yield* _queryEffectValues(effect);
    final values = <EffectValue?>[
      if (effect is ChooseCards) ...[effect.minimum, effect.maximum],
      if (effect is PayLife) effect.value,
      if (effect is SelectOptionEffect)
        ...effect.options.expand((o) => _conditionValues(o.when)),
      if (effect is ChooseEffect && effect.statusQuery.minimumStacks != null)
        effect.statusQuery.minimumStacks,
      if (effect is ConvertStatus) effect.count,
      if (effect is ChooseTargets) ..._conditionValues(effect.when),
      if (effect is WithTargets && effect.reference.startsWith('event.'))
        EffectValue(reference: effect.reference),
      if (effect is ModifyAttack) effect.value,
      if (effect is ModifyAttackPower) effect.value,
      if (effect is ModifyVariable) ...[effect.input.value, effect.key.value],
      if (effect is ConditionalEffect) ..._conditionValues(effect.when),
      if (effect is ApplyStatus) ...[effect.stacksValue, effect.intensityValue],
      if (effect is ModifyStat) effect.value,
      if (effect is ModifyMp) effect.value,
      if (effect is RestoreLife) effect.value,
      if (effect is SetLife) effect.value,
      if (effect is HealEffect) effect.value,
      if (effect is DrawEffect) effect.value,
      if (effect is ShieldEffect) effect.value,
      if (effect is StealLife) effect.value,
      if (effect is DamageEffect) effect.value,
      if (effect is ModifyMark) effect.value,
      if (effect is EditStatus) ...[
        effect.stacks,
        effect.intensity,
        effect.initialStacks,
        effect.initialIntensity,
      ],
      if (effect is RollEffect) ...[effect.atMost, effect.atLeast],
    ];
    for (final v in values) {
      if (v != null) yield v;
    }
  }

  void _checkValue(EffectValue v, [int depth = 0]) {
    if ((v.field == ValueField.collection) != (v.collection != null)) {
      throw StateError('Collection query definition required');
    }
    if (v.collection != null) _checkCollectionQuery(v.collection!, depth + 1);
    _checkVariableValue(v);
    if (v.reference != null) {
      _checkReference(v.reference!);
      if (v.field != null || v.operation != null || v.arguments.isNotEmpty) {
        throw StateError('Reference cannot also define a query or operation');
      }
    }
    if (depth > 16 || !v.constant.isFinite || !v.factor.isFinite) {
      throw StateError('Invalid expression');
    }
    if ((v.field == ValueField.livingCount ||
            v.field == ValueField.statusTotalStacks ||
            v.field == ValueField.statusTotalIntensity ||
            v.field == ValueField.statusCharacterCount ||
            v.field == ValueField.markTotal) &&
        ![
          EffectTarget.self,
          EffectTarget.all,
          EffectTarget.allies,
          EffectTarget.enemies,
          EffectTarget.others,
        ].contains(v.among)) {
      throw StateError('Invalid living count value');
    }
    if (v.statusId != null) _require(catalog.statuses, v.statusId!);
    for (final id in v.markIds) {
      _require(catalog.marks, id);
    }
    if (v.field == ValueField.markCount) {
      _require(catalog.marks, v.markId ?? '');
    }
    final n = v.arguments.length;
    if (v.operation == null && n != 0) {
      throw StateError('Expression args require op');
    }
    if (v.operation != null && (v.field != null || v.perIntensity)) {
      throw StateError('Expression op cannot also be a field');
    }
    if (v.operation != null) {
      final valid = switch (v.operation!) {
        ValueOperation.subtract ||
        ValueOperation.divide ||
        ValueOperation.modulo => n == 2,
        ValueOperation.floor || ValueOperation.ceil => n == 1,
        _ => n > 0,
      };
      if (!valid) throw StateError('Invalid expression arity');
    }
    for (final child in v.arguments) {
      _checkValue(child, depth + 1);
    }
  }

  void _checkStatusQuery(StatusQuery q, [int depth = 0]) {
    _checkSourceReference(q.source);
    if (q.minimumIntensityValue != null) {
      _checkValue(q.minimumIntensityValue!, depth + 1);
    }
    if (q.maximumStacks != null) _checkValue(q.maximumStacks!, depth + 1);
    if (q.maximumIntensity != null) _checkValue(q.maximumIntensity!, depth + 1);
    if (q.source != null) _checkReference(q.source!);
    _checkSelectionReference(q.selection);
    if (q.minimumStacks != null) _checkValue(q.minimumStacks!, depth + 1);
    if (q.minimumIntensity != null && q.minimumIntensity! < 0) {
      throw StateError('Invalid minimum intensity');
    }
    for (final id in {...q.statusIds, ...q.excludeStatusIds}) {
      _require(catalog.statuses, id);
    }
    if (q.statusId != null) _require(catalog.statuses, q.statusId!);
  }

  void _editStatuses(
    CharacterInstance actor,
    CharacterInstance target,
    EditStatus effect,
    int multiplier,
  ) {
    final existing = _queryStatuses(target, effect.query, actor: actor);
    if (effect.createIfMissing) {
      final ids = effect.query.chosen
          ? {
              if (_chosenStatus?.ownerId == target.instanceId)
                _chosenStatus!.definition.id,
            }
          : {
              if (effect.query.statusId != null) effect.query.statusId!,
              ...effect.query.statusIds,
            };
      for (final id in ids) {
        if (!target.alive ||
            target.statuses.any((s) => s.definition.id == id)) {
          continue;
        }
        final missing = effect.query.chosen
            ? _chosenStatus!
            : _missingStatus(target, catalog.statuses[id]!);
        if (_interactionRulesVersion >= 5 &&
            missing.definition.category == StatusCategory.anomaly) {
          continue;
        }
        if (_queryStatuses(
          target,
          effect.query,
          candidates: [missing],
        ).isEmpty) {
          continue;
        }
        final sv = effect.stacks == null
            ? null
            : _amount(0, effect.stacks, actor, target) * multiplier;
        final iv = effect.intensity == null
            ? null
            : _amount(0, effect.intensity, actor, target) * multiplier;
        if ((sv ?? 0) <= 0 && (iv ?? 0) <= 0) continue;
        final stacks =
            sv ??
            (effect.initialStacks == null
                ? null
                : _amount(0, effect.initialStacks, actor, target));
        final intensity = !missing.definition.hasIntensity
            ? 1
            : iv ??
                  (effect.initialIntensity == null
                      ? null
                      : _amount(0, effect.initialIntensity, actor, target));
        if (stacks == null || intensity == null) {
          throw StateError('Missing initial status values');
        }
        _applyStatus(
          actor,
          target,
          ApplyStatus(id, stacks: stacks, intensity: intensity),
          1,
        );
      }
    }
    // Creation uses ordinary attachment rules; only pre-existing instances are
    // edited, so a newly created status never receives the increment twice.
    for (final status in existing) {
      if (effect.mode == StatusEditMode.remove) {
        _consumeStatus(
          target,
          status,
          amount: status.stacks,
          statisticsSource: actor,
        );
        continue;
      }
      if (_interactionRulesVersion >= 5 &&
          status.definition.category == StatusCategory.anomaly) {
        continue;
      }
      final oldChosen = _chosenStatus;
      _chosenStatus = status;
      late int stacks;
      late int intensity;
      try {
        final sv = effect.stacks == null
            ? null
            : _amount(0, effect.stacks, actor, target);
        final iv = effect.intensity == null
            ? null
            : _amount(0, effect.intensity, actor, target);
        stacks = sv == null
            ? status.stacks
            : (effect.mode == StatusEditMode.set
                  ? sv
                  : status.stacks + sv * multiplier);
        intensity = iv == null
            ? status.intensity
            : (effect.mode == StatusEditMode.set
                  ? iv
                  : status.intensity + iv * multiplier);
      } finally {
        _chosenStatus = oldChosen;
      }
      if (status.definition.category == StatusCategory.anomaly &&
          (stacks > status.stacks || intensity != status.intensity)) {
        continue;
      }
      if (!status.definition.hasIntensity && effect.intensity != null) continue;
      final oldStacks = status.stacks;
      final oldIntensity = status.intensity;
      final previousLimits = _resourceLimits(target);
      if (stacks <= 0) {
        _consumeStatus(
          target,
          status,
          amount: status.stacks,
          statisticsSource: actor,
        );
        continue;
      }
      if (stacks > oldStacks) {
        stacks =
            oldStacks +
            _statusStackGain(target, status.definition.id, stacks - oldStacks);
      }
      status.stacks = stacks.clamp(1, status.definition.maxStacks ?? 1000000);
      status.intensity = intensity.clamp(
        1,
        status.definition.maxIntensity ?? 1000000,
      );
      _performance.statusChange(
        actor,
        target,
        status.definition,
        oldStacks,
        oldIntensity,
        status.stacks,
        status.intensity,
      );
      _normalize(target);
      _event('statusModified', {
        'sourceId': actor.instanceId,
        'targetId': target.instanceId,
        'statusId': status.definition.id,
        'instanceId': status.instanceId,
        'stacks': status.stacks,
        'intensity': status.intensity,
        'negative': status.definition.negative,
        'stackDelta': status.stacks - oldStacks,
        'intensityDelta': status.intensity - oldIntensity,
      });
      _logResourceLimitChanges(target, previousLimits, source: actor);
    }
  }

  void _transferStatuses(
    CharacterInstance actor,
    CharacterInstance from,
    List<String> selected,
    TransferStatus effect,
  ) {
    final destinations = _effectTargets(
      actor,
      selected,
      effect.to,
    ).where((c) => c.alive && c != from).toList();
    if (destinations.length != 1) return;
    final to = destinations.single;
    final wasSettling = _settlingAttack;
    _settlingAttack = true;
    try {
      for (final status in _queryStatuses(
        from,
        effect.query,
        actor: actor,
      ).where((s) => _isStatusEffect(s.definition))) {
        final stacks = status.stacks;
        final intensity = status.intensity;
        _consumeStatus(from, status, amount: stacks, statisticsSource: actor);
        final eventStart = state.events.length;
        _applyStatus(
          from,
          to,
          ApplyStatus(
            status.definition.id,
            stacks: stacks,
            intensity: intensity,
            damageLimit: status.damageLimit,
          ),
          1,
          anchorPlayerId: state.players
              .firstWhere((p) => p.character == from)
              .id,
          statisticsSource: actor,
        );
        final moved = to.statuses
            .where((s) => s.definition.id == status.definition.id)
            .firstOrNull;
        if (moved != null &&
            state.events
                .skip(eventStart)
                .any(
                  (e) =>
                      e.type == 'statusApplied' &&
                      e.data['targetId'] == to.instanceId &&
                      e.data['statusId'] == status.definition.id,
                )) {
          moved
            ..sourceId = from.instanceId
            ..anchorPlayerId = state.players
                .firstWhere((p) => p.character == from)
                .id;
          moved.decayAtAnchorEnd = _usesEndAnchorDecay(
            moved.definition,
            moved.anchorPlayerId,
          );
          moved.damageTaken = moved.damageTaken > status.damageTaken
              ? moved.damageTaken
              : status.damageTaken;
          moved.usedDamageGuards.addAll(status.usedDamageGuards);
          moved.triggerMemory.counters.addAll(status.triggerMemory.counters);
          moved.triggerMemory.counterWindows.addAll(
            status.triggerMemory.counterWindows,
          );
          moved.triggerMemory.uses.addAll(status.triggerMemory.uses);
          moved.triggerMemory.useWindows.addAll(
            status.triggerMemory.useWindows,
          );
          moved.triggerMemory.groupUses.addAll(status.triggerMemory.groupUses);
          moved.triggerMemory.groupWindows.addAll(
            status.triggerMemory.groupWindows,
          );
          moved.triggerMemory.packetUses.addAll(
            status.triggerMemory.packetUses,
          );
        }
      }
    } finally {
      _settlingAttack = wasSettling;
    }
    _normalize(from);
    _normalize(to);
  }
}
