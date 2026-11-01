part of 'engine.dart';

extension _CardEffects on GameKernel {
  List<CardDefinition> _copyableDeckCards(
    ChooseEffect effect, [
    CharacterInstance? actor,
  ]) {
    final counts = <String, int>{};
    for (final id in setup.deck) {
      counts.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
    return [
      for (final entry in counts.entries)
        if (entry.value >= effect.minimumDeckCopies &&
            _matchesCard(
              CardInstance(
                'definition_${entry.key}',
                catalog.cards[entry.key]!,
              ),
              effect.cardQuery,
              actor ?? state.activePlayer.character,
              actor ?? state.activePlayer.character,
            ))
          catalog.cards[entry.key]!,
    ];
  }

  void _checkActionFailure(
    CharacterInstance actor,
    void Function({required bool failed}) complete,
  ) {
    final statuses = actor.statuses
        .where((s) => s.definition.actionFailureSides != null)
        .toList();
    void next(int index) {
      if (!actor.alive || index == statuses.length) {
        complete(failed: false);
        return;
      }
      final status = statuses[index];
      if (!actor.statuses.contains(status)) {
        next(index + 1);
        return;
      }
      _rollAsync(actor, status.definition.actionFailureSides!, 1, (result) {
        if (result == 1) {
          _performance.actionCancelled(
            status.sourceId,
            actor,
            cards: _observedAction?.cards.length ?? 0,
          );
          _event('actionFailed', {
            'actorId': actor.instanceId,
            'statusId': status.definition.id,
          });
          complete(failed: true);
        } else {
          next(index + 1);
        }
      });
    }

    next(0);
  }

  void _runDiceContest(
    CharacterInstance actor,
    DiceContest effect,
    int multiplier,
    void Function() complete,
  ) {
    final others = _effectTargets(
      actor,
      const [],
      EffectTarget.others,
    ).where((c) => c.alive).toList();
    final results = <CharacterInstance, int>{};
    void next(int index) {
      if (index == others.length) {
        if (results.isEmpty) {
          complete();
          return;
        }
        final minimum = results.values.reduce((a, b) => a < b ? a : b);
        final maximum = results.values.reduce((a, b) => a > b ? a : b);
        final losers = results.entries
            .where((e) => e.value == minimum)
            .toList();
        void hurt(int i) {
          if (i == losers.length) {
            complete();
            return;
          }
          _damageAsync(
            actor,
            losers[i].key,
            effect.factor * (maximum + effect.bonus) * multiplier,
            DamageKind.physical,
            () => hurt(i + 1),
          );
        }

        hurt(0);
        return;
      }
      final other = others[index];
      _rollAsync(other, effect.sides, 1, (result) {
        results[other] = result;
        next(index + 1);
      }, damageRoll: true);
    }

    next(0);
  }

  void _runCardEffects(
    CharacterInstance actor,
    List<String> targets,
    List<CardInstance> cards,
    void Function() complete, {
    bool includeNonAttackOnHit = false,
  }) {
    _discardedCount = 0;
    _cardDiscardCounts.clear();
    _attackAdjustment = 0;
    _attackPowerAdjustment = 0;
    _attackEffectMultiplier = 1;
    void run(int index, EffectPhase phase) {
      if (!actor.alive || index == cards.length) {
        if (actor.alive && phase == EffectPhase.ruleSetup) {
          run(0, EffectPhase.resolve);
        } else {
          complete();
        }
        return;
      }
      final card = cards[index];
      _discardedCount = _cardDiscardCounts[card.instanceId] ?? 0;
      _runAbility(
        actor,
        targets,
        _withCardStackFactor(
          _cardEffectsFor(
            actor,
            card,
            includeNonAttackOnHit: includeNonAttackOnHit,
          ),
          _interactionRulesVersion >= 10
              ? _cardStatusStackFactor(card.definition.id, cards)
              : 1,
        ).where((effect) => effect.executionPhase == phase).toList(),
        () {
          _cardDiscardCounts[card.instanceId] = _discardedCount;
          run(index + 1, phase);
        },
        multiplier: card.reinforced ? 2 : 1,
        rollOrigin: RollContext(
          actorId: actor.instanceId,
          purpose: RollPurpose.card,
          definitionId: card.definition.id,
        ),
        cards: cards,
      );
    }

    run(0, EffectPhase.ruleSetup);
  }

  Map<String, Object?>? _choiceView([String? viewer]) {
    final choice = state.choice;
    if (choice == null) return null;
    if (_interactionRulesVersion >= 2 &&
        viewer != null &&
        viewer != choice.playerId) {
      return null;
    }
    return {
      'choiceId': choice.id,
      'playerId': choice.playerId,
      'kind': choice.kind.name,
      if (viewer == choice.playerId) ...{
        'options': choice.options.map(Map<String, Object?>.of).toList(),
        ...choice.details,
      },
    };
  }

  void _submitChoice(
    PlayerInstance player,
    KernelCommand command, {
    bool validateOnly = false,
  }) {
    final choice = state.choice!;
    if (command is! ChooseCommand ||
        command.choiceId != choice.id ||
        player.id != choice.playerId ||
        !choice.options.any((o) => o['optionId'] == command.optionId)) {
      throw StateError('Invalid or stale choice');
    }
    if (validateOnly) return;
    final continuation = _choiceContinuation!;
    state.choice = null;
    _choiceContinuation = null;
    _event('choiceResolved', {'choiceId': choice.id, 'playerId': player.id});
    final previous = _choiceSourceContext;
    _choiceSourceContext = choice.details['source'] as Map<String, Object?>?;
    try {
      continuation(command.optionId);
    } finally {
      _choiceSourceContext = previous;
    }
  }

  void _openChoice(
    CharacterInstance actor,
    List<String> selected,
    ChooseEffect effect,
    int multiplier,
    void Function({required bool didChoose}) complete, {
    void Function(void Function(), Map<String, Object?>)? onPrepared,
    int selectionIndex = 1,
    int? selectionCount,
    Set<String>? chosenInstances,
  }) {
    final count =
        selectionCount ??
        (_interactionRulesVersion >= 10 &&
                onPrepared == null &&
                const [
                  ChoiceKind.takeCard,
                  ChoiceKind.discardCard,
                  ChoiceKind.resetCooldown,
                ].contains(effect.kind)
            ? effect.amount * multiplier
            : 1);
    final chosen = chosenInstances ?? <String>{};
    if (onPrepared == null &&
        _preparedCardChoices.isNotEmpty &&
        identical(_preparedCardChoices.first.$1, effect)) {
      final prepared = _preparedCardChoices.removeFirst();
      prepared.$2();
      _flowSteps([_drainTriggers, () => complete(didChoose: prepared.$3)]);
      return;
    }
    final triggerContext = _currentTrigger;
    final targets = _effectTargets(
      actor,
      selected,
      effect.target,
    ).where((c) => c.alive).toList();
    final options = <Map<String, Object?>>[];
    final actions = <String, void Function()>{};
    void add(Map<String, Object?> data, void Function() action) {
      final id = state.id('option');
      options.add({'optionId': id, ...data});
      actions[id] = action;
    }

    final chooser = effect.chooser == ChoiceChooser.target
        ? targets.firstOrNull
        : actor;
    for (final target in targets) {
      switch (effect.kind) {
        case ChoiceKind.discardPileCard:
          for (final card
              in state.discardPile
                  .where(
                    (c) =>
                        !c.disabled &&
                        _matchesCard(c, effect.cardQuery, actor, target),
                  )
                  .toList()) {
            add(
              {
                'instanceId': card.instanceId,
                'definitionId': card.definition.id,
              },
              () {
                if (!state.discardPile.remove(card)) {
                  _event('cardRetrievalSkipped', {
                    'instanceId': card.instanceId,
                  });
                  return;
                }
                final before = actor.hand.length;
                actor.hand.add(card);
                _performance.resourceChange(
                  actor,
                  actor,
                  1,
                  resource: StatisticsResource.hand,
                );
                _handCountIncreased(actor, before);
                _event('cardRetrieved', {
                  'actorId': actor.instanceId,
                  'instanceId': card.instanceId,
                  'definitionId': card.definition.id,
                });
              },
            );
          }
        case ChoiceKind.deckCard:
          for (final definition in _copyableDeckCards(effect, actor)) {
            add({'definitionId': definition.id}, () {
              final card = CardInstance(state.id('card'), definition);
              final before = actor.hand.length;
              actor.hand.add(card);
              _performance.resourceChange(
                actor,
                actor,
                1,
                resource: StatisticsResource.hand,
              );
              _handCountIncreased(actor, before);
              _event('cardCopied', {
                'actorId': actor.instanceId,
                'instanceId': card.instanceId,
                'definitionId': definition.id,
              });
            });
          }
        case ChoiceKind.abilityOption:
        case ChoiceKind.character:
        case ChoiceKind.status:
          throw StateError('Selection requires ability frame');
        case ChoiceKind.mechanism:
        case ChoiceKind.attackCard:
          throw StateError('Attack card choices require attack assembly');
        case ChoiceKind.mark:
          throw StateError('Mark choices are opened by the turn scheduler');
        case ChoiceKind.takeCard:
        case ChoiceKind.discardCard:
        case ChoiceKind.returnCardToDeck:
          if (effect.reveal && selectionIndex == 1) {
            _performance.revealCards(actor, target);
            for (final skill in target.skills) {
              skill.revealed = true;
              state.publicSkillHistory[skill.definition.id] = skill.definition;
            }
            state.revealedHands[target.instanceId] = [
              for (final card in target.hand)
                {
                  'instanceId': card.instanceId,
                  'definitionId': card.definition.id,
                },
            ];
            _event('handRevealed', {
              'targetId': target.instanceId,
              'cards': [
                for (final card in target.hand)
                  {
                    'instanceId': card.instanceId,
                    'definitionId': card.definition.id,
                  },
              ],
            });
          }
          final hand = target.hand.toList();
          // Opaque options must not preserve a known hand order for a blind choice.
          final canSeeCards = effect.reveal || identical(chooser, target);
          if (!canSeeCards) _shuffle(hand);
          for (final card in hand) {
            if (card.disabled ||
                !_matchesCard(card, effect.cardQuery, actor, target)) {
              continue;
            }
            add(
              {
                'targetId': target.instanceId,
                if (canSeeCards) ...{
                  'definitionId': card.definition.id,
                  'instanceId': card.instanceId,
                },
              },
              () {
                final before = actor.hand.length;
                target.hand.remove(card);
                _performance.resourceChange(
                  actor,
                  target,
                  -1,
                  resource: StatisticsResource.hand,
                );
                if (effect.kind == ChoiceKind.takeCard) {
                  actor.hand.add(card);
                  _performance.resourceChange(
                    actor,
                    actor,
                    1,
                    resource: StatisticsResource.hand,
                  );
                  _handCountIncreased(actor, before, source: target);
                } else if (effect.kind == ChoiceKind.returnCardToDeck) {
                  state.drawPile.insert(
                    _nextInt(state.drawPile.length + 1),
                    card,
                  );
                } else {
                  state.discardPile.add(card);
                }
                _event('cardsLost', {
                  'actorId': target.instanceId,
                  'count': 1,
                  if (_interactionRulesVersion >= 5 &&
                      effect.kind == ChoiceKind.discardCard)
                    'cards': [card.instanceId],
                });
              },
            );
          }
        case ChoiceKind.resetCooldown:
          for (final skill in target.skills) {
            if (chosen.contains(skill.instanceId) ||
                !_matchesSkillData(
                  _skillQueryData(skill, target.instanceId),
                  effect.skillQuery,
                  actor,
                  target,
                )) {
              continue;
            }
            add(
              {
                'targetId': target.instanceId,
                'definitionId': skill.definition.id,
                'instanceId': skill.instanceId,
                'cooldown': skill.cooldown,
              },
              () {
                _setSkillCooldown(skill, 0);
              },
            );
          }
        case ChoiceKind.extendStatus:
          for (final status in target.statuses) {
            if (status.definition.category == StatusCategory.anomaly ||
                (status.definition.maxStacks != null &&
                    status.stacks >= status.definition.maxStacks!)) {
              continue;
            }
            add(
              {
                'targetId': target.instanceId,
                'definitionId': status.definition.id,
                'instanceId': status.instanceId,
                'stacks': status.stacks,
              },
              () {
                status.stacks = (status.stacks + effect.amount * multiplier)
                    .clamp(1, status.definition.maxStacks ?? 1000000);
                _event('statusExtended', {
                  'targetId': target.instanceId,
                  'instanceId': status.instanceId,
                  'stacks': status.stacks,
                });
              },
            );
          }
      }
    }
    if (options.isEmpty) {
      if (onPrepared != null) {
        onPrepared(() {}, {'skip': true});
      } else {
        complete(didChoose: selectionIndex > 1);
      }
      return;
    }
    if (chooser == null || !chooser.alive) {
      complete(didChoose: false);
      return;
    }
    final skipId = effect.optional ? state.id('option') : null;
    if (skipId != null) options.add({'optionId': skipId, 'skip': true});
    final player = state.players.firstWhere((p) => p.character == chooser);
    state.choice = PendingChoice(
      id: state.id('choice'),
      playerId: player.id,
      kind: effect.kind,
      options: List.unmodifiable(options),
      details: count <= 1
          ? const {}
          : {'selectionIndex': selectionIndex, 'selectionCount': count},
    );
    _choiceContinuation = (id) {
      if (onPrepared != null) {
        final option = options.firstWhere((o) => o['optionId'] == id);
        onPrepared(
          id == skipId ? () {} : actions[id]!,
          Map<String, Object?>.of(option),
        );
        return;
      }
      if (id == skipId) {
        complete(didChoose: false);
        return;
      }
      final previousTrigger = _currentTrigger;
      _currentTrigger = triggerContext;
      try {
        actions[id]!();
      } finally {
        _currentTrigger = previousTrigger;
      }
      final instance = options.firstWhere(
        (o) => o['optionId'] == id,
      )['instanceId'];
      if (instance is String) chosen.add(instance);
      void nextSelection() {
        if (selectionIndex < count && actor.alive) {
          _openChoice(
            actor,
            selected,
            effect,
            multiplier,
            complete,
            selectionIndex: selectionIndex + 1,
            selectionCount: count,
            chosenInstances: chosen,
          );
        } else {
          complete(didChoose: true);
        }
      }

      if (triggerContext == null) {
        _flowSteps([_drainTriggers, nextSelection]);
      } else {
        nextSelection();
      }
    };
    _event('choiceOpened', {
      'choiceId': state.choice!.id,
      'playerId': player.id,
      'kind': effect.kind.name,
    });
  }

  void _extendedEffect(
    CharacterInstance actor,
    CharacterInstance target,
    List<String> selected,
    EffectDefinition effect,
    int multiplier,
    AttackPacket? packet,
  ) {
    switch (effect) {
      case ArmTrigger():
        state.armedTriggers.add(
          ArmedTrigger(
            state.id('armed-trigger'),
            actor.instanceId,
            effect.triggers,
            multiplier,
          ),
        );
      case DiscardHand():
        final cards = actor.hand.where((c) => !c.disabled).toList();
        actor.hand.removeWhere((c) => cards.contains(c));
        state.discardPile.addAll(cards);
        _discardedCount += cards.length;
        _event('cardsDiscarded', {
          'actorId': actor.instanceId,
          'cards': List<String>.unmodifiable(cards.map((c) => c.instanceId)),
        });
      case StealEffect():
        final hp = effect.hp * multiplier;
        _damage(actor, target, hp, DamageKind.lifeLoss);
        _heal(actor, actor, hp);
        final attack = (effect.attack * multiplier).clamp(
          0,
          target.value(Stat.attack),
        );
        target.permanentModifiers.update(
          Stat.attack,
          (n) => n - attack,
          ifAbsent: () => -attack,
        );
        actor.permanentModifiers.update(
          Stat.attack,
          (n) => n + attack,
          ifAbsent: () => attack,
        );
      case SwapHands():
        if (target == actor) return;
        final actorBefore = actor.hand.length;
        final targetBefore = target.hand.length;
        final left = actor.hand.where((c) => !c.disabled).toList();
        final right = target.hand.where((c) => !c.disabled).toList();
        actor.hand
          ..removeWhere(left.contains)
          ..addAll(right);
        target.hand
          ..removeWhere(right.contains)
          ..addAll(left);
        _performance.resourceChange(
          actor,
          actor,
          actor.hand.length - actorBefore,
          resource: StatisticsResource.hand,
        );
        _performance.resourceChange(
          actor,
          target,
          target.hand.length - targetBefore,
          resource: StatisticsResource.hand,
        );
        for (final entry in [(actor, left, right), (target, right, left)]) {
          if (entry.$2.isNotEmpty) {
            _event('cardsLost', {
              'actorId': entry.$1.instanceId,
              'count': entry.$2.length,
            });
          }
        }
        _event('handsSwapped', {
          'sourceId': actor.instanceId,
          'targetId': target.instanceId,
          'sourceCount': right.length,
          'targetCount': left.length,
        });
        _handCountIncreased(actor, actorBefore, source: target);
        _handCountIncreased(target, targetBefore, source: actor);
      case SwapStatuses():
        if (target == actor) return;
        final actorLimits = _resourceLimits(actor);
        final targetLimits = _resourceLimits(target);
        final left = actor.statuses
            .where((s) => _isStatusEffect(s.definition))
            .toList();
        final right = target.statuses
            .where((s) => _isStatusEffect(s.definition))
            .toList();
        actor.statuses.removeWhere(left.contains);
        target.statuses.removeWhere(right.contains);
        for (final status in [...left, ...right]) {
          _performance.statusChange(
            actor,
            _character(status.ownerId),
            status.definition,
            status.stacks,
            status.intensity,
            0,
            0,
          );
          _event('statusRemoved', {
            'ownerId': status.ownerId,
            'statusId': status.definition.id,
          });
        }
        _logResourceLimitChanges(actor, actorLimits, source: actor);
        _logResourceLimitChanges(target, targetLimits, source: actor);
        final wasSettling = _settlingAttack;
        _settlingAttack = true;
        try {
          void transfer(
            CharacterInstance from,
            CharacterInstance to,
            List<StatusInstance> statuses,
          ) {
            for (final status in statuses) {
              _applyStatus(
                from,
                to,
                ApplyStatus(
                  status.definition.id,
                  stacks: status.stacks,
                  intensity: status.intensity,
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
              if (moved != null) {
                moved.damageTaken = moved.damageTaken > status.damageTaken
                    ? moved.damageTaken
                    : status.damageTaken;
                moved.usedDamageGuards.addAll(status.usedDamageGuards);
                moved.triggerMemory.counters.addAll(
                  status.triggerMemory.counters,
                );
                moved.triggerMemory.counterWindows.addAll(
                  status.triggerMemory.counterWindows,
                );
                moved.triggerMemory.groupUses.addAll(
                  status.triggerMemory.groupUses,
                );
                moved.triggerMemory.groupWindows.addAll(
                  status.triggerMemory.groupWindows,
                );
                moved.triggerMemory.packetUses.addAll(
                  status.triggerMemory.packetUses,
                );
                moved.triggerMemory.uses.addAll(status.triggerMemory.uses);
                moved.triggerMemory.useWindows.addAll(
                  status.triggerMemory.useWindows,
                );
              }
            }
          }

          transfer(actor, target, left);
          transfer(target, actor, right);
        } finally {
          _settlingAttack = wasSettling;
        }
        _normalize(actor);
        _normalize(target);
      case DrawSkill():
        for (
          var index = 0;
          index <
              effect.count * (_interactionRulesVersion >= 10 ? multiplier : 1);
          index++
        ) {
          final available = state.skillPool
              .where(
                (s) => !state.players.any(
                  (p) => p.character.skills.any(
                    (owned) => owned.definition.id == s.definition.id,
                  ),
                ),
              )
              .toList();
          if (available.isEmpty) break;
          final skill = available[_nextInt(available.length)];
          state.skillPool.remove(skill);
          skill.remainingUses = effect.uses;
          actor.skills.add(skill);
          _event('skillDrawn', {
            'actorId': actor.instanceId,
            'instanceId': skill.instanceId,
          });
        }
      case BlockStatusApplication():
        final rounds =
            effect.rounds * (_interactionRulesVersion >= 10 ? multiplier : 1);
        if (_interactionRulesVersion >= 5) {
          final anchor = state.activePlayer.id;
          final previous = state.statusApplicationBlocks[anchor] ?? 0;
          if (rounds > previous) {
            state.statusApplicationBlocks[anchor] = rounds;
          }
          _event('statusApplicationBlocked', {
            'anchorPlayerId': anchor,
            'rounds': rounds,
          });
          break;
        }
        final until = state.round + effect.rounds;
        if (until > state.blockStatusUntilRound) {
          state.blockStatusUntilRound = until;
        }
        _event('statusApplicationBlocked', {
          'untilRound': state.blockStatusUntilRound,
        });
      case ModifyAttack():
        _attackAdjustment +=
            _amount(effect.amount, effect.value, actor, target) * multiplier;
        _attackEffectMultiplier *= _scaledMultiplier(
          effect.multiplier,
          multiplier,
        );
      case SetCounter():
        _currentTrigger!.memory.counters[effect.counter] =
            effect.amount +
            (effect.add
                ? (_currentTrigger!.memory.counters[effect.counter] ?? 0)
                : 0);
      case ConditionalEffect():
        _effects(
          actor,
          effect.eachTarget ? [target.instanceId] : selected,
          (_conditionSnapshots[(effect, target.instanceId)] ??
                  _conditionMatches(effect.when, actor, target))
              ? effect.effects
              : effect.otherwise,
          multiplier: multiplier,
          attackPacket: packet,
        );
      case RollEffect():
      case DiceContest():
        throw StateError(
          'Branch and dice effects require ability continuation',
        );
      default:
        throw StateError('Unsupported extended effect');
    }
  }
}
