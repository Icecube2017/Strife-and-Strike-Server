part of 'engine.dart';

/// Shared operations used by content rather than character-specific branches.
extension _ContentOperations on GameKernel {
  int? _cardDiceSides(CardInstance card) =>
      _interactionRulesVersion >= 10 && card.reinforced
      ? card.definition.reinforcedDiceSides ?? card.definition.diceSides
      : card.definition.diceSides;

  int _cardStatusStackFactor(String definitionId, List<CardInstance> cards) =>
      cards.fold<int>(
        1,
        (factor, card) =>
            factor *
            (1 +
                ((card.definition.statusStackMultipliers[definitionId] ?? 1) -
                        1) *
                    _cardScale(card)),
      );

  List<EffectDefinition> _withCardStackFactor(
    List<EffectDefinition> effects,
    int factor,
  ) => factor == 1
      ? effects
      : [
          for (final effect in effects)
            switch (effect) {
              ApplyStatus() => ApplyStatus(
                effect.statusId,
                stacks: effect.stacks * factor,
                stacksValue: effect.stacksValue == null
                    ? null
                    : EffectValue(
                        operation: ValueOperation.multiply,
                        arguments: [
                          effect.stacksValue!,
                          EffectValue(constant: factor.toDouble()),
                        ],
                      ),
                intensity: effect.intensity,
                intensityValue: effect.intensityValue,
                refreshSource: effect.refreshSource,
                ignoreNegativeProtection: effect.ignoreNegativeProtection,
                damageLimit: effect.damageLimit,
                target: effect.target,
              ),
              ConditionalEffect() => ConditionalEffect(
                effect.when,
                _withCardStackFactor(effect.effects, factor),
                otherwise: _withCardStackFactor(effect.otherwise, factor),
                eachTarget: effect.eachTarget,
                snapshot: effect.snapshot,
                target: effect.target,
              ),
              _ => effect,
            },
        ];

  int _pendingDiceBonus(CharacterInstance actor, PendingResolution pending) =>
      pending.diceLocked
      ? 0
      : _cardContentModule.diceBonus(pending.id) +
            _attackDiceBonus(actor) -
            (_blocked(actor, (s) => s.blockTraits)
                ? 0
                : pending.deferredDiceBonus);

  int _summonedCount(CharacterInstance actor, EffectTarget among) {
    final owners = _effectTargets(
      actor,
      const [],
      among,
    ).map((c) => c.instanceId).toSet();
    return state.summonedUnits
        .where((u) => u.alive && owners.contains(u.ownerId))
        .length;
  }

  int _growAttackDice(CharacterInstance actor, int result) {
    if (_blocked(actor, (s) => s.blockTraits)) return 0;
    var gain = 0;
    for (final trait in actor.traits) {
      final rule = trait.definition.attackDiceGrowth;
      if (rule == null || result < rule.threshold) continue;
      final before = _variableCell(rule.variable, actor).value as num;
      final bonusBefore = _attackDiceBonus(actor);
      _modifyVariable(
        actor,
        actor,
        ModifyVariable(
          rule.variable,
          operation: VariableOperation.add,
          input: const VariableInput(literal: 1),
        ),
      );
      gain += _attackDiceBonus(actor) - bonusBefore;
      _event('attackDiceGrowth', {
        'actorId': actor.instanceId,
        'variable': rule.variable,
        'amount': ((_variableCell(rule.variable, actor).value as num) - before)
            .toInt(),
        'appliesNextAttack': true,
      });
    }
    return gain;
  }

  List<EffectDefinition> _cardEffectsFor(
    CharacterInstance actor,
    CardInstance card, {
    bool includeNonAttackOnHit = false,
  }) {
    if (_cardSuppressed(actor, card)) return const [];
    if (!_blocked(actor, (s) => s.blockTraits)) {
      for (final trait in actor.traits) {
        final replacement =
            trait.definition.cardEffectOverrides[card.definition.id];
        if (replacement != null) return replacement;
      }
    }
    return [
      ...card.definition.effects,
      if (includeNonAttackOnHit)
        ..._nonDamageAttachments(card.definition.onHit),
    ];
  }

  List<EffectDefinition> _nonDamageAttachments(List<EffectDefinition> effects) {
    final result = <EffectDefinition>[];
    for (final effect in effects) {
      if (effect is DamageEffect || effect is DiceContest) continue;
      if (effect is ConditionalEffect) {
        final yes = _nonDamageAttachments(effect.effects);
        final no = _nonDamageAttachments(effect.otherwise);
        if (yes.isNotEmpty || no.isNotEmpty) {
          result.add(
            ConditionalEffect(
              effect.when,
              yes,
              otherwise: no,
              eachTarget: effect.eachTarget,
              snapshot: effect.snapshot,
              target: effect.target,
            ),
          );
        }
      } else {
        result.add(effect);
      }
    }
    return result;
  }

  void _convertStatus(
    CharacterInstance actor,
    CharacterInstance target,
    ConvertStatus effect,
  ) {
    var remaining = _amount(0, effect.count, actor, target).clamp(0, 1000000);
    var converted = 0;
    for (final status
        in target.statuses
            .where(
              (s) => effect.fromStatusId == null
                  ? identical(s, _chosenStatus)
                  : s.definition.id == effect.fromStatusId,
            )
            .toList()) {
      final count = remaining.clamp(0, status.stacks);
      if (count == 0) break;
      _consumeStatus(target, status, amount: count, statisticsSource: actor);
      remaining -= count;
      converted += count;
    }
    if (converted > 0) {
      _applyStatus(
        actor,
        target,
        ApplyStatus(
          effect.toStatusId,
          stacks: converted,
          intensity: effect.intensity,
        ),
        1,
      );
    }
  }

  void _expireCardRestrictions() {
    for (final player in state.players) {
      final actor = player.character;
      actor.restrictedCardTags.removeWhere(
        (tag, until) => until <= state.round,
      );
      for (final card in actor.hand) {
        if (card.disabledUntilRound != null &&
            card.disabledUntilRound! <= state.round) {
          card.disabled = false;
          card.disabledUntilRound = null;
          _event('handCardEnabled', {'ownerId': actor.instanceId, 'count': 1});
        }
      }
    }
  }

  void _refundNonDamagingAction(_ObservedAction action) {
    if (action.paidMp <= 0 ||
        _blocked(action.actor, (s) => s.blockTraits) ||
        !action.actor.traits.any((t) => t.definition.refundNonDamagingAction)) {
      return;
    }
    final causedDamage = state.events
        .skip(action.start)
        .any(
          (e) =>
              e.type == 'damage' &&
              e.data['sourceId'] == action.actor.instanceId &&
              (_damageAmountVersion >= 1
                  ? (e.data['amount'] as int? ?? 0) > 0
                  : ((e.data['hpLost'] as int? ?? 0) > 0 ||
                        (e.data['shieldAbsorbed'] as int? ?? 0) > 0)),
        );
    if (causedDamage) return;
    final before = action.actor.mp;
    if (!action.actor.noMp) {
      action.actor.mp = (before + action.paidMp).clamp(
        _mpFloor(action.actor),
        action.actor.value(Stat.maxMp),
      );
    }
    _event('actionMpRefunded', {
      'actorId': action.actor.instanceId,
      'amount': action.actor.mp - before,
      'paidAmount': action.paidMp,
    });
  }

  void _expireHandCardsAtAnchor(String playerId, {bool atEnd = false}) {
    if (_interactionRulesVersion < 13) return;
    void expire(CardInstance card, {String? ownerId}) {
      final expiry = card.disabledUntilAnchor;
      if (expiry == null || !_anchorExpiryDue(expiry, playerId, atEnd: atEnd)) {
        return;
      }
      card
        ..disabled = false
        ..disabledUntilRound = null
        ..disabledUntilAnchor = null;
      if (ownerId != null) {
        _event('handCardEnabled', {'ownerId': ownerId, 'count': 1});
      }
    }

    for (final player in state.players) {
      for (final card in player.character.hand) {
        expire(card, ownerId: player.character.instanceId);
      }
    }
    // Death can move locked cards into the discard pile without an ordinary
    // discard. Their original deadline must still unlock those exact cards.
    for (final card in [...state.drawPile, ...state.discardPile]) {
      expire(card);
    }
  }

  void _interactiveContentOperation(
    CharacterInstance actor,
    List<String> selected,
    EffectDefinition effect,
    void Function() complete,
  ) {
    final targets = _effectTargets(
      actor,
      selected,
      effect.target,
    ).where((c) => c.alive).toList();
    final playerId = state.players.firstWhere((p) => p.character == actor).id;
    void targetAt(int index) {
      if (index == targets.length) {
        complete();
        return;
      }
      final target = targets[index];
      void next() => targetAt(index + 1);
      if (effect is RestrictCardTag) {
        final tags = catalog.cards.values.expand((c) => c.tags).toSet().toList()
          ..sort();
        if (tags.isEmpty) {
          next();
          return;
        }
        final options = [
          for (final tag in tags) {'optionId': state.id('option'), 'tag': tag},
        ];
        state.choice = PendingChoice(
          id: state.id('choice'),
          playerId: playerId,
          kind: ChoiceKind.mechanism,
          options: options,
          details: {'targetId': target.instanceId},
        );
        _choiceContinuation = (id) {
          final tag = options.firstWhere((o) => o['optionId'] == id)['tag']!;
          final expiry =
              _interactionRulesVersion >= 14 &&
                  effect.clock == DurationClock.anchoredRound
              ? _newAnchorExpiry(effect.rounds)
              : null;
          final until = state.round + effect.rounds;
          var extended = false;
          if (expiry != null) {
            final deadlines = target.anchoredCardTags.putIfAbsent(
              tag,
              () => [],
            );
            final previous = deadlines.indexWhere(
              (e) => e.playerId == expiry.playerId && e.atEnd == expiry.atEnd,
            );
            if (previous < 0) {
              deadlines.add(expiry);
              extended = true;
            } else if (deadlines[previous].turn < expiry.turn) {
              deadlines[previous] = expiry;
              extended = true;
            }
          } else {
            final previousUntil = target.restrictedCardTags[tag] ?? 0;
            target.restrictedCardTags[tag] = until > previousUntil
                ? until
                : previousUntil;
            extended = until > previousUntil;
          }
          if (extended) {
            _performance.otherEffect(
              actor,
              target,
              positive: false,
              kind: 'handLock',
            );
          }
          _event('cardTagRestricted', {
            'sourceId': actor.instanceId,
            'targetId': target.instanceId,
            'tag': tag,
            if (expiry == null)
              'untilRound': until
            else ...{
              'anchorPlayerId': expiry.playerId,
              'durationRounds': effect.rounds,
              'decayPhase': expiry.atEnd ? 'turnEnd' : 'turnStart',
            },
          });
          next();
        };
      } else if (effect is DisableHandCards) {
        final eligible = target.hand.where((c) => !c.disabled).toList();
        if (eligible.length < effect.count) {
          _runAbility(actor, [target.instanceId], effect.otherwise, next);
          return;
        }
        final picked = <CardInstance>[];
        void pick() {
          if (picked.length == effect.count) {
            final expiry = _interactionRulesVersion >= 13
                ? _newAnchorExpiry(effect.rounds)
                : null;
            for (final card in picked) {
              card
                ..disabled = true
                ..disabledUntilRound = expiry == null
                    ? state.round + effect.rounds
                    : null
                ..disabledUntilAnchor = expiry;
            }
            if (picked.isNotEmpty) {
              _performance.otherEffect(
                actor,
                target,
                positive: false,
                kind: 'handLock',
              );
            }
            // Public facts deliberately carry no card identities.
            _event('handCardsDisabled', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'count': picked.length,
              if (expiry == null)
                'untilRound': state.round + effect.rounds
              else ...{
                'anchorPlayerId': expiry.playerId,
                'durationRounds': effect.rounds,
                'decayPhase': expiry.atEnd ? 'turnEnd' : 'turnStart',
              },
            });
            next();
            return;
          }
          final candidates = eligible
              .where((c) => !picked.contains(c))
              .toList();
          _shuffle(candidates);
          final cards = <String, CardInstance>{};
          final options = <Map<String, Object?>>[];
          for (final card in candidates) {
            final id = state.id('option');
            cards[id] = card;
            options.add({'optionId': id, 'hidden': true});
          }
          state.choice = PendingChoice(
            id: state.id('choice'),
            playerId: playerId,
            kind: ChoiceKind.mechanism,
            options: options,
            details: {
              'targetId': target.instanceId,
              'selectedCount': picked.length,
              'count': effect.count,
            },
          );
          _choiceContinuation = (id) {
            picked.add(cards[id]!);
            pick();
          };
          _event('choiceOpened', {
            'choiceId': state.choice!.id,
            'playerId': playerId,
            'kind': ChoiceKind.mechanism.name,
          });
        }

        pick();
        return;
      }
      _event('choiceOpened', {
        'choiceId': state.choice!.id,
        'playerId': playerId,
        'kind': ChoiceKind.mechanism.name,
      });
    }

    targetAt(0);
  }
}
