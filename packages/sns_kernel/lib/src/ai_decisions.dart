part of 'engine.dart';

/// Read-only candidate validation reuses the command handlers' validation stage.
extension KernelAiDecisions on GameKernel {
  // An optimistic fee bound: adding cards may grant a tag discount or a negative
  // cost modifier. Prune only when even that best case is unaffordable.
  bool _aiCardPrefixCanPay(CharacterInstance actor, List<CardInstance> prefix) {
    if (actor.noMp || identical(_automaticActor, actor)) return true;
    final traitsBlocked = _blocked(actor, (s) => s.blockTraits);
    final freeTags = traitsBlocked
        ? <String>{}
        : actor.traits.expand((t) => t.definition.freeCardTags).toSet();
    int lowerFee(CardInstance card) {
      if (card.definition.tags.any(freeTags.contains)) return 0;
      final base = card.definition.mpCost;
      final bonus = card.definition.actionCostBonus;
      return base + (bonus < 0 ? bonus * 2 : bonus);
    }

    var raw = prefix.fold<int>(0, (n, c) => n + lowerFee(c));
    final hand = actor.hand.where((c) => !c.disabled).toList();
    for (final c in hand.where((c) => !prefix.contains(c))) {
      final fee = lowerFee(c);
      if (fee < 0) raw += fee;
    }
    var discount = _actionDiscount(actor);
    if (!traitsBlocked &&
        actor.traits.any((t) => t.definition.cardMaxTagDiscount)) {
      final tags = hand.fold<int>(
        0,
        (n, c) => c.definition.tags.length > n ? c.definition.tags.length : n,
      );
      if (tags > 0) discount += tags - 1;
    }
    var minimum = (raw - discount).clamp(0, 1000000000);
    for (final status in actor.statuses) {
      final cap = status.definition.cardMpCap;
      if (cap != null && cap < minimum) minimum = cap;
    }
    return minimum <= actor.mp;
  }

  String? aiCommandProblem(
    KernelCommand command, {
    void Function(int)? costQuote,
  }) => _withCommandNumber(
    command,
    () => _aiCommandProblem(command, costQuote: costQuote),
  );

  String? _aiCommandProblem(
    KernelCommand command, {
    void Function(int)? costQuote,
  }) {
    try {
      if (state.finished || state.phase == GamePhase.created) {
        throw StateError('Not a playable game');
      }
      final p = _player(command.playerId);
      if (!p.character.alive) throw StateError('Player is dead');
      if (state.preparation != null &&
          (state.choice == null || command is CancelAbilityCommand)) {
        _submitPreparation(p, command, validateOnly: true);
      } else if (state.choice != null) {
        _submitChoice(p, command, validateOnly: true);
      } else if (state.pending != null) {
        _submitResponse(p, command, validateOnly: true);
      } else {
        final anytime =
            command is UseSkillCommand &&
            _executionSkill(
              p.character,
              _ownedModuleSkill(p.character, command.skillInstanceId),
              command,
            ).definition.anytime;
        final anytimeTrait =
            command is ActivateTraitCommand &&
            p.character.traits.any(
              (t) =>
                  t.instanceId == command.traitInstanceId &&
                  t.definition.active?.anytime == true,
            );
        if (p.id != state.activePlayer.id && !anytime && !anytimeTrait) {
          throw StateError('Not the active player');
        }
        if (state.phase == GamePhase.discard) {
          if (command is! DiscardCommand) throw StateError('Discard required');
          _discard(p.character, command.cardInstanceIds, validateOnly: true);
        } else {
          if (state.phase != GamePhase.action) {
            throw StateError('Not an action window');
          }
          switch (command) {
            case AttackCommand():
              _attack(p, command, validateOnly: true, costQuote: costQuote);
            case PlayCardsCommand():
              _playCards(p, command, validateOnly: true, costQuote: costQuote);
            case UseSkillCommand():
              _useSkill(p, command, validateOnly: true, costQuote: costQuote);
            case ActivateTraitCommand():
              _activateTrait(p.character, command, validateOnly: true);
            case ActivateStatusCommand():
              _activateStatus(
                p.character,
                command.statusInstanceId,
                validateOnly: true,
              );
            case EndTurnCommand():
              break;
            default:
              throw StateError('Wrong decision window');
          }
        }
      }
      return null;
      // A rejected proposal is not executed and consumes no RNG or resources.
      // ignore: avoid_catching_errors
    } on StateError catch (e) {
      return e.message;
    }
  }

  Map<String, Object?> aiObservation(String id) {
    final private = privateView(id);
    final public = publicView();
    // Whitelist player-visible views. Never expose saves, RNG, seeds, piles,
    // raw events, statistics internals, or other players' private records.
    final observation = <String, Object?>{
      'public': {
        'turnDirection': state.reversedOrder ? -1 : 1,
        'nextRoundDirection': (state.reversedOrder != state.reverseNextRound)
            ? -1
            : 1,
        for (final k in [
          'gameId',
          'version',
          'round',
          'turn',
          'logicalTurn',
          'extraTurn',
          'phase',
          'activePlayerId',
          'duel',
          'players',
          'responseWindow',
          'pending',
          'preparation',
          'outcome',
          'drawPileCount',
          'discardCount',
          'revealedHands',
          'globalEffects',
        ])
          if (public.containsKey(k)) k: public[k],
      },
      'private': {
        'mpFloor': _mpFloor(_player(id).character),
        for (final k in [
          'playerId',
          'characterId',
          'version',
          'cards',
          'skills',
          'choice',
          'preparation',
          'responseWindow',
          'marks',
          'variables',
          'actionRecords',
          'traitActions',
          'statusActions',
          'triggerState',
          'canAttack',
          'canPlayCards',
          'attackTargetCandidates',
        ])
          if (private.containsKey(k)) k: private[k],
      },
    };
    return observation;
  }

  AiDecision? aiDecision({
    String? playerId,
    int maximumProposals = 100000,
    List<String>? cardPrefix,
    bool allowCardEdits = true,
  }) {
    if (state.finished) return null;
    final forced =
        state.choice?.playerId ??
        state.preparation?.playerId ??
        state.pending?.waitingPlayerId;
    if (forced != null && playerId != null && playerId != forced) return null;
    final id = forced ?? playerId ?? state.activePlayer.id;
    final player = _player(id);
    final actor = player.character;
    final observation = aiObservation(id);
    final private = observation['private']! as Map<String, Object?>;
    final candidates = <AiCandidate>[];
    final seen = <String>{};
    var proposals = 0;
    void add(KernelCommand c, {Map<String, Object?> features = const {}}) {
      if (++proposals > maximumProposals) {
        throw const AiCoverageError('candidateProposalBudgetExceeded');
      }
      int? quoted;
      if (aiCommandProblem(c, costQuote: (value) => quoted = value) != null) {
        return;
      }
      final signature = jsonEncode(KernelRecoveryCodec.command(c));
      if (seen.add(signature)) {
        candidates.add(
          AiCandidate(
            c,
            features: {...features, if (quoted != null) 'quotedMpCost': quoted},
          ),
        );
      }
    }

    Map<String, Object?> effectsFeatures(
      List<EffectDefinition> effects, {
      List<String> targets = const [],
      bool attack = false,
      int bonus = 0,
    }) {
      final effectList = _walkEffects(effects).toList();
      return {
        'targets': targets,
        'attack': attack,
        'attackPower': actor.value(Stat.attack) + bonus,
        'damage': effectList.whereType<DamageEffect>().fold<int>(
          0,
          (s, e) => s + e.amount,
        ),
        'healing': effectList.whereType<HealEffect>().fold<int>(
          0,
          (s, e) => s + e.amount,
        ),
        'shield': effectList.whereType<ShieldEffect>().fold<int>(
          0,
          (s, e) => s + e.amount,
        ),
        'draw': effectList.whereType<DrawEffect>().fold<int>(
          0,
          (s, e) => s + e.count,
        ),
        'statuses': effectList.whereType<ApplyStatus>().length,
        'targetStatusBenefit': effectList
            .whereType<ApplyStatus>()
            .where(
              (e) =>
                  e.target == EffectTarget.selected ||
                  e.target == EffectTarget.selfOrSelected,
            )
            .fold<int>(
              0,
              (sum, e) =>
                  sum +
                  (catalog.statuses[e.statusId]?.negative == true ? -10 : 5),
            ),
        'selfStatusBenefit': effectList
            .whereType<ApplyStatus>()
            .where((e) => e.target == EffectTarget.self)
            .fold<int>(
              0,
              (sum, e) =>
                  sum +
                  (catalog.statuses[e.statusId]?.negative == true ? -10 : 5),
            ),
        'cancel': effectList.any((e) => e is CancelSkill || e is CancelCard),
      };
    }

    void skills(SkillInstance owned, {PendingResolution? response}) {
      final executions =
          owned.definition.mechanism == SkillMechanism.copyPublicSkill
          ? _copyCandidates(actor, owned)
          : [owned];
      for (final execution in executions) {
        final d = execution.definition;
        if (d.passive ||
            owned.cooldown > 0 ||
            owned.remainingUses == 0 ||
            owned.leasedOut ||
            (response == null && id != state.activePlayer.id && !d.anytime)) {
          continue;
        }
        final targets = _skillTargetCandidates(actor, d);
        final parameter = d.numberParameter;
        var numberMaximum = parameter?.maximum ?? 0;
        if (parameter?.maximumValue != null) {
          numberMaximum = numberMaximum.clamp(
            0,
            _amount(
              0,
              parameter!.maximumValue,
              actor,
              actor,
            ).clamp(0, numberMaximum),
          );
        }
        if (parameter != null && !_negateSkills(actor)) {
          if (!actor.defenseLife && parameter.lifeCostPerUnit > 0) {
            numberMaximum = numberMaximum.clamp(
              0,
              ((actor.hp - d.lifeCost) ~/ parameter.lifeCostPerUnit).clamp(
                0,
                numberMaximum,
              ),
            );
          }
          if (parameter.markCostId != null) {
            numberMaximum = numberMaximum.clamp(
              0,
              _markCount(actor, parameter.markCostId!).clamp(0, numberMaximum),
            );
          }
        }
        if (response != null && response.maximumDiceResult > 256) {
          throw const AiCoverageError('diceParameterRangeExceeded');
        }
        final numbers = parameter == null
            ? <int?>[null]
            : parameter.allowedValues.isNotEmpty
            ? parameter.allowedValues.cast<int?>()
            : [for (var n = parameter.minimum; n <= numberMaximum; n++) n];
        final records = d.mechanism == SkillMechanism.replayRecord
            ? [
                for (final r
                    in _recordingModule.records[actor.instanceId] ??
                        <RecordedAction>[])
                  r.id,
              ]
            : <String?>[null];
        final dice =
            response != null && d.effects.any((e) => e is SetDiceResult)
            ? <int?>[for (var n = 1; n <= response.maximumDiceResult; n++) n]
            : <int?>[null];
        final cards = response != null && d.effects.any((e) => e is CancelCard)
            ? <String?>[for (final c in response.cards) c.instanceId]
            : <String?>[null];
        for (final selected in aiSelections(
          targets,
          d.minTargets,
          d.maxTargets,
          ordered: true,
        )) {
          for (final number in numbers) {
            for (final record in records) {
              for (final reverse in record == null ? [false] : [false, true]) {
                for (final die in dice) {
                  for (final card in cards) {
                    add(
                      UseSkillCommand(
                        id,
                        owned.instanceId,
                        targetIds: selected,
                        number: number,
                        recordId: record,
                        reverse: reverse,
                        copiedSkillId: identical(execution, owned)
                            ? null
                            : d.id,
                        pendingActionId: response?.windowId,
                        diceResult: die,
                        cardInstanceId: card,
                      ),
                      features: {
                        ...effectsFeatures(d.effects, targets: selected),
                        'definitionId': d.id,
                        'mpCost': _skillMpCost(actor, d, number: number),
                        if (die != null) 'diceResult': die,
                      },
                    );
                  }
                }
              }
            }
          }
        }
      }
    }

    final choice = state.choice;
    final preparation = state.preparation;
    final pending = state.pending;
    final String phase;
    if (choice != null) {
      phase = 'choice';
      final visible = private['choice']! as Map;
      for (final raw in visible['options']! as List) {
        final option = Map<String, Object?>.from(raw as Map);
        add(
          ChooseCommand(id, choice.id, option['optionId']! as String),
          features: {'option': option},
        );
      }
      if (preparation != null) add(CancelAbilityCommand(id, preparation.id));
    } else if (preparation != null) {
      phase = 'preparation';
      if (preparation.ready) add(ConfirmAbilityCommand(id, preparation.id));
      add(CancelAbilityCommand(id, preparation.id));
    } else if (pending != null) {
      phase = 'response';
      add(PassCommand(id, pending.windowId));
      final window = private['responseWindow']! as Map;
      final options = (window['options']! as List).cast<Map>();
      if (window['preparingOptionId'] == null &&
          window['canBeginResponse'] == true) {
        for (final o in options.where(
          (o) => o['enabled'] == true && o['kind'] != 'pass',
        )) {
          add(
            BeginResponseCommand(
              id,
              pending.windowId,
              o['optionId']! as String,
            ),
          );
        }
      }
      for (final o in options.where((o) => o['enabled'] == true)) {
        if (o['kind'] == 'playCard') {
          add(
            RespondCardCommand(
              id,
              pending.windowId,
              o['instanceId']! as String,
            ),
            features: {'protection': true},
          );
        } else if (o['kind'] == 'recordAction') {
          for (final card
              in pending.cards.isEmpty
                  ? <String?>[null]
                  : <String?>[for (final c in pending.cards) c.instanceId]) {
            add(
              RecordActionCommand(
                id,
                pending.windowId,
                o['instanceId']! as String,
                cardInstanceId: card,
              ),
            );
          }
        } else if (o['kind'] == 'useSkill') {
          final owned = actor.skills
              .where((s) => s.instanceId == o['instanceId'])
              .firstOrNull;
          if (owned != null) skills(owned, response: pending);
        }
      }
    } else if (state.phase == GamePhase.discard) {
      phase = 'discard';
      final cards = actor.hand
          .where((c) => !c.disabled)
          .map((c) => c.instanceId)
          .toList();
      final count = (actor.hand.length - actor.value(Stat.maxHand)).clamp(
        0,
        cards.length,
      );
      for (final batch in aiSelections(cards, count, count)) {
        add(DiscardCommand(id, batch));
      }
    } else {
      phase = id == state.activePlayer.id ? 'action' : 'opportunity';
      if (id == state.activePlayer.id) {
        add(EndTurnCommand(id));
        if (private['canAttack'] == true) {
          for (final p in state.players.where(
            (p) => p.character.alive && p.id != id,
          )) {
            add(
              AttackCommand(id, p.character.instanceId),
              features: effectsFeatures(
                const [],
                targets: [p.character.instanceId],
                attack: true,
              ),
            );
          }
        }
        if (cardPrefix != null && private['canPlayCards'] == true) {
          final hand = actor.hand.where((c) => !c.disabled).toList();
          final batch = [
            for (final iid in cardPrefix)
              hand.singleWhere((c) => c.instanceId == iid),
          ];
          if (batch.isNotEmpty && allowCardEdits) candidates.clear();
          for (final card in hand.where(
            (c) =>
                allowCardEdits &&
                !cardPrefix.contains(c.instanceId) &&
                _aiCardPrefixCanPay(actor, [...batch, c]),
          )) {
            candidates.add(
              AiCandidate(
                null,
                adapterAction: 'selectCard',
                features: {
                  ...effectsFeatures(
                    card.definition.effects,
                    attack: card.definition.attacks,
                    bonus: card.definition.attackBonus,
                  ),
                  'canCommit':
                      <String?>[
                        null,
                        for (final p in state.players.where(
                          (p) => p.character.alive,
                        ))
                          p.character.instanceId,
                      ].any(
                        (target) =>
                            aiCommandProblem(
                              PlayCardsCommand(id, [
                                ...cardPrefix,
                                card.instanceId,
                              ], targetId: target),
                            ) ==
                            null,
                      ),
                  'definitionId': card.definition.id,
                  'cardInstanceId': card.instanceId,
                  'selectedCardIds': cardPrefix,
                  'cardCount': batch.length + 1,
                },
              ),
            );
          }
          if (batch.isNotEmpty) {
            if (allowCardEdits) {
              candidates.add(
                AiCandidate(
                  null,
                  adapterAction: 'unselectCard',
                  features: {'selectedCardIds': cardPrefix},
                ),
              );
              candidates.add(
                AiCandidate(
                  null,
                  adapterAction: 'cancelCardSelection',
                  features: {'selectedCardIds': cardPrefix},
                ),
              );
            }
            for (final target in <String?>[
              null,
              for (final p in state.players.where((p) => p.character.alive))
                p.character.instanceId,
            ]) {
              add(
                PlayCardsCommand(id, cardPrefix, targetId: target),
                features: {
                  ...effectsFeatures(
                    [for (final c in batch) ...c.definition.effects],
                    targets: target == null ? [] : [target],
                    attack: batch.every((c) => c.definition.attacks),
                    bonus: batch.fold<int>(
                      0,
                      (n, c) => n + c.definition.attackBonus,
                    ),
                  ),
                  'cardCount': batch.length,
                },
              );
            }
            if (allowCardEdits) {
              return AiDecision(
                decisionId: '${state.gameId}:${state.version}:cards',
                gameVersion: state.version,
                actorId: id,
                phase: 'action',
                observation: observation,
                candidates: candidates,
              );
            }
          }
        }
        if (cardPrefix == null && private['canPlayCards'] == true) {
          final hand = actor.hand.where((c) => !c.disabled).toList();
          for (final batch in aiSelections(
            hand,
            1,
            hand.length,
            ordered: true,
          )) {
            final ids = [for (final c in batch) c.instanceId];
            for (final target in <String?>[
              null,
              for (final p in state.players.where((p) => p.character.alive))
                p.character.instanceId,
            ]) {
              add(
                PlayCardsCommand(id, ids, targetId: target),
                features: {
                  ...effectsFeatures(
                    [for (final c in batch) ...c.definition.effects],
                    targets: target == null ? [] : [target],
                    attack: batch.every((c) => c.definition.attacks),
                    bonus: batch.fold<int>(
                      0,
                      (s, c) => s + c.definition.attackBonus,
                    ),
                  ),
                  'cardCount': batch.length,
                },
              );
            }
          }
        }
        for (final s in actor.statuses.where(
          (s) => s.definition.active != null,
        )) {
          add(
            ActivateStatusCommand(id, s.instanceId),
            features: effectsFeatures(s.definition.active!.effects),
          );
        }
      }
      for (final s in actor.skills) {
        skills(s);
      }
      for (final t in (private['traitActions']! as List).cast<Map>()) {
        if (t['disabledReason'] != null) continue;
        final options = (t['options']! as List).cast<Map>();
        for (final mode in (t['modes']! as List).cast<String>()) {
          final option =
              options.where((o) => o['mode'] == mode).firstOrNull ?? t;
          if (option['disabledReason'] != null) continue;
          final discardCount = option['discardCount']! as int;
          final cards = (t['cardCandidates']! as List).cast<String>();
          for (final selected in aiSelections(
            cards,
            discardCount,
            discardCount,
          )) {
            add(
              ActivateTraitCommand(
                id,
                t['instanceId']! as String,
                cardInstanceIds: selected,
                mode: mode,
              ),
              features: {'mode': mode},
            );
          }
        }
      }
      if (id != state.activePlayer.id) candidates.add(AiCandidate(null));
    }
    if (candidates.isEmpty) {
      throw AiCoverageError('noLegalCandidates:$phase:$id');
    }
    return AiDecision(
      decisionId:
          '${state.gameId}:${state.version}:$phase:$id:${choice?.id ?? preparation?.id ?? pending?.windowId ?? ''}',
      gameVersion: state.version,
      actorId: id,
      phase: phase,
      observation: observation,
      candidates: candidates,
    );
  }
}
