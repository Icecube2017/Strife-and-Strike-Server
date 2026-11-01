part of 'engine.dart';

final class _AttackCap {
  _AttackCap(this.owner, this.rule) : remaining = rule.cap;
  final CharacterInstance owner;
  final RedirectAttack rule;
  int remaining;
  int excess = 0;
}

final class _DamagePlan {
  _DamagePlan(
    this.source,
    this.target,
    this.amount,
    this.kind, {
    this.attack = false,
    this.packet,
    this.secondary = false,
    this.piercesContinuation = false,
    this.statusOrigin,
    this.independent = false,
  });
  final CharacterInstance? source;
  final CharacterInstance target;
  int amount;
  int requestedAmount = 0;
  bool finalMultiplierApplied = false;
  final DamageKind kind;
  final bool attack;
  final AttackPacket? packet;
  final bool secondary;
  final bool piercesContinuation;
  final StatusInstance? statusOrigin;
  final bool independent;
  DamageAttribution? scoreTrace;
  String? protectedTargetId;
  bool hit = true;
  final List<_DamagePlan> shares = [];
  final List<(String, List<EffectDefinition>, int)> reactions = [];
}

extension _DamageFlow on GameKernel {
  ({int amount, int lifeRefund}) _consumeReceivedDamage(
    CharacterInstance actor,
  ) {
    final amount =
        (actor.receivedDamageThisGlobalRound -
                actor.transferredDamageThisGlobalRound)
            .clamp(0, 1000000000);
    final lifeRefund = _damageAmountVersion == 0
        ? amount
        : (actor.receivedHpLostThisGlobalRound -
                  actor.transferredHpLostThisGlobalRound)
              .clamp(0, 1000000000);
    actor.transferredDamageThisGlobalRound =
        actor.receivedDamageThisGlobalRound;
    actor.transferredHpLostThisGlobalRound =
        actor.receivedHpLostThisGlobalRound;
    return (amount: amount, lifeRefund: lifeRefund);
  }

  /// Roll-dependent attack attachments are frozen before the target group's damage checkpoint.
  void _expandPacketEffects(
    AttackPacket packet,
    List<CardInstance> cards,
    void Function(List<AttackPacketEffect>) complete,
  ) {
    final expanded = <AttackPacketEffect>[];
    final localsByDefinition = <(String, String?), Map<String, Object?>>{};
    final target = _character(packet.targetId);
    void list(
      AttackPacketEffect attachment,
      List<EffectDefinition> effects,
      int index,
      int rolled, {
      required bool nested,
      required void Function() done,
    }) {
      if (index == effects.length) {
        done();
        return;
      }
      final actor = attachment.sourceId == null
          ? _character(packet.sourceId)
          : _character(attachment.sourceId!);
      final effect = effects[index];
      final locals = localsByDefinition.putIfAbsent((
        attachment.definitionId,
        attachment.sourceId,
      ), () => {});
      void context(void Function() action) {
        final previousLocals = _abilityLocals;
        _abilityLocals = locals;
        final previous = _rolled;
        final previousCards = _effectCards;
        _rolled = rolled;
        _effectCards = cards;
        try {
          action();
        } finally {
          _abilityLocals = previousLocals;
          _rolled = previous;
          _effectCards = previousCards;
        }
      }

      void next() => list(
        attachment,
        effects,
        index + 1,
        rolled,
        nested: nested,
        done: done,
      );
      if (effect is RollEffect) {
        final rollers = _effectTargets(
          actor,
          [target.instanceId],
          effect.target,
          attackPacket: packet,
        ).where((c) => c.alive).toList();
        void roll(int i) {
          if (i == rollers.length) {
            next();
            return;
          }
          final subject = rollers[i];
          _rollAsync(
            effect.roller == ChoiceChooser.actor ? actor : subject,
            effect.sides,
            effect.count,
            (result) {
              if (effect.bind != null) locals[effect.bind!] = result;
              final old = _rolled;
              final oldLocals = _abilityLocals;
              _abilityLocals = locals;
              _rolled = result;
              late bool success;
              try {
                success =
                    (effect.success.isEmpty ||
                        effect.success.contains(result)) &&
                    (effect.atMost == null ||
                        result <= _amount(0, effect.atMost, actor, subject)) &&
                    (effect.atLeast == null ||
                        result >= _amount(0, effect.atLeast, actor, subject));
              } finally {
                _rolled = old;
                _abilityLocals = oldLocals;
              }
              list(
                attachment,
                success ? effect.effects : effect.otherwise,
                0,
                result,
                nested: true,
                done: () => roll(i + 1),
              );
            },
            damageRoll: _damageRollEffect(effect),
            origin: RollContext(
              actorId: (effect.roller == ChoiceChooser.actor ? actor : subject)
                  .instanceId,
              purpose: catalog.cards.containsKey(attachment.definitionId)
                  ? RollPurpose.card
                  : catalog.statuses.containsKey(attachment.definitionId)
                  ? RollPurpose.status
                  : RollPurpose.trait,
              actionId: packet.actionId,
              definitionId: attachment.definitionId,
            ),
          );
        }

        roll(0);
        return;
      }
      if (effect is ConditionalEffect) {
        context(
          () => list(
            attachment,
            _conditionMatches(effect.when, actor, target)
                ? effect.effects
                : effect.otherwise,
            0,
            rolled,
            nested: true,
            done: next,
          ),
        );
        return;
      }
      final receiver = effect.target == EffectTarget.self ? actor : target;
      if (!_attackEffectTargetAllowed(receiver, packet) &&
          effect is! ChooseEffect &&
          effect is! ChooseTargets &&
          effect is! WithTargets) {
        next();
        return;
      }
      final freezeLocal =
          _directQueryEffectReferences(
            effect,
          ).any((r) => r.startsWith('local.')) ||
          _effectValues(effect)
              .expand(_valueTree)
              .any((v) => v.reference?.startsWith('local.') ?? false);
      context(() {
        if ((nested || freezeLocal) && effect is DamageEffect) {
          final receiver = effect.target == EffectTarget.self ? actor : target;
          var amount =
              _amount(effect.amount, effect.value, actor, receiver) *
              attachment.multiplier;
          if (!effect.sourceless &&
              (effect.kind == DamageKind.physical ||
                  effect.kind == DamageKind.magical)) {
            amount -= _incomingDamageReduction(
              actor,
              receiver,
              attachment: true,
            );
          }
          amount =
              (amount.clamp(0, 1000000000) * packet.attachmentDamageMultiplier)
                  .round();
          expanded.add(
            AttackPacketEffect(
              attachment.definitionId,
              DamageEffect(
                amount,
                kind: effect.kind,
                target: effect.target,
                sourceless: effect.sourceless,
                fromStatusSource: effect.fromStatusSource,
                onDamage: effect.onDamage,
              ),
              1,
              sourceId: attachment.sourceId,
            ),
          );
        } else if ((nested || freezeLocal) && effect is ApplyStatus) {
          expanded.add(
            AttackPacketEffect(
              attachment.definitionId,
              ApplyStatus(
                effect.statusId,
                stacks: _amount(
                  effect.stacks,
                  effect.stacksValue,
                  actor,
                  target,
                ),
                intensity: _amount(
                  effect.intensity,
                  effect.intensityValue,
                  actor,
                  target,
                ),
                refreshSource: effect.refreshSource,
                ignoreNegativeProtection: effect.ignoreNegativeProtection,
                damageLimit: effect.damageLimit,
                target: effect.target,
              ),
              attachment.multiplier,
              sourceId: attachment.sourceId,
            ),
          );
        } else {
          final receiver = effect.target == EffectTarget.self ? actor : target;
          final frozen = !(nested || freezeLocal)
              ? effect
              : switch (effect) {
                  ModifyMark() => ModifyMark(
                    effect.markId,
                    amount: _amount(
                      effect.amount,
                      effect.value,
                      actor,
                      receiver,
                    ),
                    set: effect.set,
                    references: effect.references,
                    target: effect.target,
                  ),
                  HealEffect() => HealEffect(
                    _amount(effect.amount, effect.value, actor, receiver),
                    sourceTraitId: effect.sourceTraitId,
                    targetTraitId: effect.targetTraitId,
                    target: effect.target,
                  ),
                  ShieldEffect() => ShieldEffect(
                    _amount(effect.amount, effect.value, actor, receiver),
                    target: effect.target,
                  ),
                  DrawEffect() => DrawEffect(
                    _amount(effect.count, effect.value, actor, receiver),
                    target: effect.target,
                  ),
                  ModifyMp() => ModifyMp(
                    _amount(effect.amount, effect.value, actor, receiver),
                    target: effect.target,
                  ),
                  ModifyStat() when effect.value != null => ModifyStat(
                    effect.stat,
                    _amount(effect.amount, effect.value, actor, receiver),
                    target: effect.target,
                    oncePerAction: effect.oncePerAction,
                    onClamp: effect.onClamp,
                  ),
                  StealLife() => StealLife(
                    _amount(effect.amount, effect.value, actor, receiver),
                    target: effect.target,
                    healNominal: effect.healNominal,
                  ),
                  _ => effect,
                };
          expanded.add(
            AttackPacketEffect(
              attachment.definitionId,
              frozen,
              attachment.multiplier,
              sourceId: attachment.sourceId,
            ),
          );
        }
      });
      next();
    }

    void next(int index) {
      if (index == packet.onHit.length) {
        complete(expanded);
        return;
      }
      final attachment = packet.onHit[index];
      list(
        attachment,
        [attachment.effect],
        0,
        0,
        nested: false,
        done: () => next(index + 1),
      );
    }

    next(0);
  }

  void _guardRollAsync(
    DamageGuard guard,
    CharacterInstance owner,
    String key,
    String? actionId,
    void Function({required bool success}) complete,
  ) {
    if (guard.rollSides == null) {
      complete(success: true);
      return;
    }
    final cacheKey = guard.oncePerAttack && actionId != null
        ? '$key/$actionId'
        : null;
    if (cacheKey != null && _attackGuardResults.containsKey(cacheKey)) {
      complete(success: _attackGuardResults[cacheKey]!);
      return;
    }
    _rollAsync(
      owner,
      guard.rollSides!,
      1,
      (result) {
        final success = guard.success.contains(result);
        if (cacheKey != null) _attackGuardResults[cacheKey] = success;
        _event('damageGuardRolled', {
          'ownerId': owner.instanceId,
          'guardId': key,
          'sides': guard.rollSides,
          'result': result,
          'success': success,
        });
        complete(success: success);
      },
      origin: RollContext(
        actorId: owner.instanceId,
        purpose: RollPurpose.damageGuard,
      ),
    );
  }

  void _prepareDamage(
    CharacterInstance? source,
    CharacterInstance target,
    int amount,
    DamageKind kind,
    void Function(_DamagePlan) complete, {
    bool attack = false,
    AttackPacket? packet,
    bool secondary = false,
    bool piercesContinuation = false,
    bool redirected = false,
  }) {
    void finish(_DamagePlan result) {
      if (!result.finalMultiplierApplied) {
        result.finalMultiplierApplied = true;
        if (state.duel && result.kind != DamageKind.lifeLoss) {
          final factor = rules.duelDamageMultiplier;
          result.amount = (result.amount * factor).round().clamp(0, 1000000000);
          result.scoreTrace?.transform(
            (v) => (v * factor).round().clamp(0, 1000000000),
          );
        }
      }
      complete(result);
    }

    final plan = _DamagePlan(
      source,
      target,
      amount.clamp(0, 1000000000),
      kind,
      attack: attack,
      packet: packet,
      secondary: secondary,
      piercesContinuation: piercesContinuation,
      statusOrigin: _currentTrigger == null
          ? _effectStatus
          : _currentTrigger?.status,
      independent:
          _currentTrigger != null ||
          _independentDamage ||
          _observedAction?.actor != source,
    );
    // ignore: cascade_invocations
    plan.requestedAmount = amount;
    plan.protectedTargetId = _performance.protectedTarget(
      packet?.actionId,
      target.instanceId,
    );
    if (_statisticsRulesVersion >= 2 && !_previewMode) {
      plan.scoreTrace = packet != null && !secondary
          ? _performance.damageAttribution(
              packet.actionId,
              target.instanceId,
              amount,
            )
          : DamageAttribution(amount);
    }
    if (!target.alive || amount <= 0) {
      plan
        ..amount = 0
        ..hit = false;
      finish(plan);
      return;
    }
    if (kind != DamageKind.physical && kind != DamageKind.magical) {
      _capAttackDamage(plan);
      finish(plan);
      return;
    }
    if (!redirected) {
      final team = state.players
          .firstWhere((p) => p.character == target)
          .teamId;
      final guardian = state.players
          .where(
            (p) =>
                p.teamId == team &&
                p.character != target &&
                p.character.alive &&
                p.character.statuses.any((s) => s.definition.redirectAllies),
          )
          .firstOrNull;
      if (guardian != null) {
        _event('damageRedirected', {
          'sourceId': source?.instanceId,
          'fromId': target.instanceId,
          'targetId': guardian.character.instanceId,
          'amount': amount,
          'kind': kind.name,
        });
        _prepareDamage(
          source,
          guardian.character,
          amount,
          kind,
          (redirectedPlan) {
            redirectedPlan.protectedTargetId = target.instanceId;
            finish(redirectedPlan);
          },
          attack: attack,
          packet: packet,
          secondary: secondary,
          piercesContinuation: piercesContinuation,
          redirected: true,
        );
        return;
      }
    }
    _scoreDamageModifiers(plan);
    if (kind == DamageKind.physical && source != null) {
      plan.amount =
          (plan.amount +
                  source.statuses.fold<int>(
                    0,
                    (n, s) =>
                        n +
                        s.definition.outgoingPhysicalFlatPerIntensity *
                            s.intensity,
                  ))
              .clamp(0, 1000000000);
    }
    var factor = 1.0;
    for (final status in target.statuses) {
      factor +=
          status.definition.incomingDamageBonusPerIntensity * status.intensity;
      if (attack) {
        factor +=
            status.definition.incomingAttackBonusPerIntensity *
            status.intensity;
      }
    }
    if ((kind == DamageKind.physical || kind == DamageKind.magical) &&
        !_blocked(target, (s) => s.blockTraits)) {
      for (final trait in target.traits) {
        factor *= trait.definition.incomingDamageMultiplier;
      }
    }
    var outgoing = 1.0;
    if (attack && source != null) {
      for (final status in source.statuses) {
        outgoing +=
            status.definition.outgoingAttackBonusPerIntensity *
            status.intensity;
      }
    }
    plan.amount =
        (plan.amount *
                factor.clamp(0, double.infinity) *
                outgoing.clamp(0, double.infinity))
            .round();
    for (final player in state.players) {
      final holder = player.character;
      if (!holder.alive || _blocked(holder, (s) => s.blockTraits)) continue;
      for (final trait in holder.traits) {
        final aura = trait.definition.damageAura;
        if (aura != null &&
            _effectTargets(holder, [
              target.instanceId,
            ], aura.scope).contains(target) &&
            _conditionMatches(aura.when, holder, target)) {
          plan.amount = ((plan.amount + aura.flat) * aura.factor).round().clamp(
            0,
            1000000000,
          );
        }
      }
    }
    if (target.statuses.any((s) => s.definition.invulnerable)) plan.amount = 0;
    final guards = <(String, DamageGuard, StatusInstance?, int)>[
      if (!_blocked(target, (s) => s.blockTraits))
        for (final trait in target.traits)
          if (trait.definition.mechanisms.get<SummonDefenseRule>() case final r?
              when !r.blockHealing)
            if (_summonCount(target, r.kind) > 0)
              (
                trait.instanceId,
                DamageGuard(
                  rollSides: r.rollSides,
                  oncePerAttack: true,
                  success: List.generate(
                    _summonCount(target, r.kind).clamp(0, r.rollSides),
                    (i) => i + 1,
                  ),
                  factor: 0,
                ),
                null,
                0,
              ),
      for (final status
          in packet == null
              ? target.statuses.toList()
              : _packetGuardStatuses.putIfAbsent(
                  '${packet.id}/${target.instanceId}',
                  () => target.statuses.toList(),
                ))
        for (final entry in status.definition.damageGuards.indexed)
          ('${status.instanceId}/${entry.$1}', entry.$2, status, entry.$1),
      for (final trait in target.traits.toList())
        for (final entry in trait.definition.damageGuards.indexed)
          if (!_blocked(
            target,
            (s) =>
                s.blockTraits && !entry.$2.traitBlockExceptions.contains(s.id),
          ))
            ('${trait.instanceId}/${entry.$1}', entry.$2, null, entry.$1),
    ];
    final actionId =
        attack &&
            _currentTrigger == null &&
            !_independentDamage &&
            _observedAction?.actor == source
        ? '${packet?.actionId}/${source?.instanceId}'
        : null;
    void next(int index) {
      if (index == guards.length) {
        if (plan.amount > 0 && !_blocked(target, (s) => s.blockTraits)) {
          for (final trait in target.traits) {
            if (trait.definition.damageRewrite != null &&
                (_interactionRulesVersion < 5 ||
                    kind == DamageKind.physical ||
                    kind == DamageKind.magical)) {
              final rewrite = trait.definition.damageRewrite!;
              plan.scoreTrace?.transform(
                (v) => v > 0 ? rewrite : v,
                owner: _scoreOwner(
                  target.instanceId,
                  target,
                  ContributionRoute.protection,
                ),
              );
              plan.amount = rewrite;
            }
          }
        }
        _capAttackDamage(plan);
        plan.hit = plan.amount > 0;
        if (redirected) {
          finish(plan);
        } else {
          _splitDamagePlan(plan, () => finish(plan));
        }
        return;
      }
      final (key, guard, status, guardIndex) = guards[index];
      final packetKey = packet == null || guard.perDamageInstance
          ? null
          : '${packet.id}/$key';
      final alreadyConsumed =
          packetKey != null && _packetConsumedGuards.contains(packetKey);
      if (plan.amount <= 0 ||
          !guard.kinds.contains(kind) ||
          !_conditionMatches(guard.when, target, target) ||
          (guard.groupAttackOnly && packet?.groupAttack != true) ||
          _guardAncestors.contains(key) ||
          (status != null &&
              !alreadyConsumed &&
              (!target.statuses.contains(status) ||
                  (guard.once &&
                      status.usedDamageGuards.contains(guardIndex))))) {
        next(index + 1);
        return;
      }
      _guardRollAsync(guard, target, key, actionId, ({required bool success}) {
        if (success) {
          final intensity = status?.intensity ?? 1;
          var flat = guard.flatPerIntensity * intensity;
          if (status != null && packetKey != null && flat < 0) {
            final remaining = _packetGuardFlatRemaining.putIfAbsent(
              packetKey,
              () => -flat,
            );
            final reduction = plan.amount.clamp(0, remaining);
            _packetGuardFlatRemaining[packetKey] = remaining - reduction;
            flat = -reduction;
          }
          plan.amount = ((plan.amount + flat) * guard.factor).round().clamp(
            0,
            1000000000,
          );
          final frozenFlat = flat, frozenFactor = guard.factor;
          final increasing = frozenFlat > 0 || frozenFactor > 1;
          plan.scoreTrace?.transform(
            (v) =>
                ((v + frozenFlat) * frozenFactor).round().clamp(0, 1000000000),
            owner: _scoreOwner(
              status?.sourceId ?? target.instanceId,
              target,
              increasing
                  ? ContributionRoute.weakening
                  : ContributionRoute.protection,
              increases: increasing,
            ),
          );
          if (status != null && packetKey != null
              ? !alreadyConsumed
              : (!guard.effectsOncePerAttack ||
                    actionId == null ||
                    _attackGuardReactions.add('$key/$actionId'))) {
            plan.reactions.add((key, guard.effects, intensity));
          }
          if (status != null && !alreadyConsumed) {
            if (packetKey != null) _packetConsumedGuards.add(packetKey);
            status.usedDamageGuards.add(guardIndex);
            if (guard.consumeStacks > 0) {
              _consumeStatus(target, status, amount: guard.consumeStacks);
            }
          }
        }
        next(index + 1);
      });
    }

    next(0);
  }

  void _capAttackDamage(_DamagePlan plan) {
    final cap = _attackCaps[plan.packet?.actionId];
    if (cap == null ||
        cap.owner != plan.target ||
        !plan.attack ||
        (plan.kind == DamageKind.lifeLoss || plan.kind == DamageKind.real)) {
      return;
    }
    final frozenRemaining = cap.remaining;
    plan.scoreTrace?.transform(
      (v) => v.clamp(0, frozenRemaining),
      owner: _scoreOwner(
        cap.owner.instanceId,
        cap.owner,
        ContributionRoute.protection,
      ),
    );
    final retained = plan.amount.clamp(0, cap.remaining);
    final excess = plan.amount - retained;
    final before = cap.excess ~/ cap.rule.overflowUnit;
    cap.excess += excess;
    cap.remaining -= retained;
    plan.amount = retained;
    final gain = cap.excess ~/ cap.rule.overflowUnit - before;
    if (gain > 0) {
      _effects(cap.owner, [], [ModifyMark(cap.rule.markId, amount: gain)]);
    }
    if (excess > 0) {
      _event('attackDamageCapped', {
        'targetId': cap.owner.instanceId,
        'amount': excess,
        'retained': retained,
        'actionId': plan.packet?.actionId,
      });
    }
  }

  void _splitDamagePlan(_DamagePlan plan, void Function() complete) {
    if (plan.amount <= 0) {
      complete();
      return;
    }
    final owners = state.players
        .map((p) => p.character)
        .where(
          (c) =>
              c.alive &&
              !_enemy(c, plan.target) &&
              !_blocked(c, (s) => s.blockTraits),
        )
        .toList();
    void next(int i) {
      if (i == owners.length) {
        complete();
        return;
      }
      final owner = owners[i];
      final rule = owner.traits
          .map((t) => t.definition.mechanisms.get<DamageShareRule>())
          .whereType<DamageShareRule>()
          .firstOrNull;
      if (rule == null) {
        next(i + 1);
        return;
      }
      if (plan.source != null) {
        _editStatuses(
          owner,
          plan.source!,
          EditStatus(
            query: StatusQuery(statusId: rule.sourceStatusId),
            intensity: EffectValue(constant: rule.intensityGain.toDouble()),
          ),
          1,
        );
      }
      if (owner == plan.target) {
        next(i + 1);
        return;
      }
      final shared = (plan.amount * rule.factor).floor();
      if (shared == 0) {
        next(i + 1);
        return;
      }
      final frozenFactor = rule.factor;
      plan.scoreTrace?.transform((v) => v - (v * frozenFactor).floor());
      plan.amount -= shared;
      _event('damageShared', {
        'sourceId': plan.source?.instanceId,
        'fromId': plan.target.instanceId,
        'targetId': owner.instanceId,
        'amount': shared,
        'kind': plan.kind.name,
      });
      _prepareDamage(
        plan.source,
        owner,
        shared,
        plan.kind,
        (part) {
          part.protectedTargetId = plan.target.instanceId;
          plan.shares.add(part);
          next(i + 1);
        },
        attack: plan.attack,
        packet: plan.packet,
        secondary: plan.secondary,
        piercesContinuation: plan.piercesContinuation,
        redirected: true,
      );
    }

    next(0);
  }

  void _damageAsync(
    CharacterInstance? source,
    CharacterInstance target,
    int amount,
    DamageKind kind,
    void Function() complete, {
    bool attack = false,
    bool piercesContinuation = false,
    AttackPacket? packet,
    bool secondary = false,
    bool redirected = false,
    bool deferDeaths = false,
  }) {
    _prepareDamage(
      source,
      target,
      amount,
      kind,
      (plan) {
        _offerDamageSkills([plan], () {
          _runPlan(plan, () {
            if (_settlingAttack || deferDeaths) {
              complete();
            } else {
              _settleDeaths(complete);
            }
          });
        });
      },
      attack: attack,
      piercesContinuation: piercesContinuation,
      packet: packet,
      secondary: secondary,
      redirected: redirected,
    );
  }

  void _commitPlan(_DamagePlan plan) {
    if (!plan.target.alive || plan.requestedAmount <= 0) return;
    plan.scoreTrace?.settle(
      _performance.scores,
      observed: plan.amount,
      effectiveLimit: _scoreDamageLimit(
        plan.target,
        plan.kind,
        packet: plan.packet,
      ),
    );
    final oldOrigin = _effectStatus;
    final oldIndependent = _independentDamage;
    _effectStatus = plan.statusOrigin;
    _independentDamage = plan.independent;
    _damageDepth++;
    try {
      _damageComponent(
        plan.source,
        plan.target,
        plan.requestedAmount,
        plan.kind,
        attack: plan.attack,
        packet: plan.packet,
        secondary: plan.secondary,
        piercesContinuation: plan.piercesContinuation,
        redirected: true,
        prepared: plan,
      );
    } finally {
      _damageDepth--;
      _effectStatus = oldOrigin;
      _independentDamage = oldIndependent;
    }
  }

  void _runPlan(_DamagePlan plan, void Function() complete) {
    final reactions = plan.reactions.toList();
    plan.reactions.clear();
    final before = plan.source?.dealtDamageThisGlobalRound ?? 0;
    _commitPlan(plan);
    final after = plan.source?.dealtDamageThisGlobalRound ?? 0;
    void next(int index) {
      if (index == reactions.length) {
        _offerOtherDamageThreshold(plan, before, after, complete);
        return;
      }
      final (key, effects, intensity) = reactions[index];
      _guardAncestors.add(key);
      _runAbility(
        plan.target,
        plan.source == null ? [] : [plan.source!.instanceId],
        effects,
        () {
          _guardAncestors.remove(key);
          next(index + 1);
        },
        multiplier: intensity,
        statusOrigin: plan.statusOrigin,
        allowDeadActor: true,
      );
    }

    void share(int i) {
      if (i == plan.shares.length) {
        next(0);
        return;
      }
      _runPlan(plan.shares[i], () => share(i + 1));
    }

    share(0);
  }

  void _settleDeaths(void Function() complete) {
    final characters = [for (final p in state.players) p.character];
    void next(int index) {
      if (index == characters.length) {
        _piercingTargets.clear();
        complete();
        return;
      }
      final c = characters[index];
      if (c.alive &&
          c.depleted &&
          (_piercingTargets.contains(c.instanceId) ||
              c.defenseLife ||
              !c.continuesBattle)) {
        _deathAsync(c, () => next(index + 1));
      } else {
        next(index + 1);
      }
    }

    next(0);
  }

  void _deathAsync(CharacterInstance target, void Function() complete) {
    if (_deferredDeathSkills.containsKey(target.instanceId)) {
      complete();
      return;
    }
    if (!target.alive || !target.depleted) {
      complete();
      return;
    }
    if (_restoreSave(target)) {
      _performance.preventedDeath(target, target);
      complete();
      return;
    }
    final skills = <(SkillInstance, SkillInstance)>[
      for (final owned in target.skills.toList())
        if (owned.definition.mechanism == SkillMechanism.copyPublicSkill)
          for (final execution in _copyCandidates(target, owned))
            (owned, execution)
        else
          (owned, owned),
    ];
    void next(int index) {
      if (!target.depleted || !target.alive) {
        if (target.alive) _performance.preventedDeath(target, target);
        complete();
        return;
      }
      if (index == skills.length) {
        _commitDeath(target);
        complete();
        return;
      }
      final (owned, skill) = skills[index];
      final rule = skill.definition.checkpoint;
      // Transfer consumes damage that has already landed, so the dying actor
      // must get a choice before committing death, with the normal costs.
      if (skill.definition.anytime &&
          _walkEffects(
            skill.definition.effects,
          ).any((e) => e is TransferReceivedDamage) &&
          target.receivedDamageThisGlobalRound >
              target.transferredDamageThisGlobalRound &&
          _settlementUsable(target, owned) &&
          _settlementUsable(target, skill)) {
        _offerDeathTransfer(target, owned, skill, () => next(index + 1));
        return;
      }
      if (rule?.at != SkillCheckpoint.beforeDeath ||
          !_settlementUsable(target, skill)) {
        next(index + 1);
        return;
      }
      _offerCheckpoint(target, owned, skill, null, {'hp': target.hp}, () {
        if (!target.defenseLife && rule!.restoreHp != null) {
          final before = target.hp;
          target.hp = rule.restoreHp!.clamp(0, target.value(Stat.maxHp));
          _event('lifeRestored', {
            'actorId': target.instanceId,
            'before': before,
            'hp': target.hp,
          });
        }
        if (rule!.shield > 0) {
          _effects(target, [target.instanceId], [ShieldEffect(rule.shield)]);
          target.temporaryShields.add(
            TemporaryShield(
              remaining: rule.shield,
              expires: state.round + rule.shieldRounds,
              anchor:
                  _interactionRulesVersion >= 14 &&
                      rule.shieldClock == DurationClock.anchoredRound
                  ? _newAnchorExpiry(rule.shieldRounds)
                  : null,
            ),
          );
          _performance.bindTemporaryShield(
            target,
            target.temporaryShields.last,
          );
        }
      }, () => next(index + 1));
    }

    next(0);
  }

  void _offerDeathTransfer(
    CharacterInstance actor,
    SkillInstance owned,
    SkillInstance skill,
    void Function() complete,
  ) {
    final player = state.players.firstWhere((p) => p.character == actor);
    final targets = <String, String>{};
    for (final p in state.players) {
      if (!p.character.alive) continue;
      try {
        _validateTargets(skill.definition, [
          p.character.instanceId,
        ], actor: actor);
        _checkMp(
          actor,
          _skillMpCost(actor, skill.definition) +
              (_negateSkills(actor)
                  ? 0
                  : _targetSurcharge([p.character.instanceId])),
        );
        targets[state.id('option')] = p.character.instanceId;
      } on StateError {
        /* Illegal targets are never offered. */
      }
    }
    if (targets.isEmpty) {
      complete();
      return;
    }
    final skip = state.id('option');
    final choice = PendingChoice(
      id: state.id('choice'),
      playerId: player.id,
      kind: ChoiceKind.abilityOption,
      options: [
        for (final entry in targets.entries)
          {
            'optionId': entry.key,
            'skillId': skill.definition.id,
            'instanceId': owned.instanceId,
            'targetId': entry.value,
            'checkpoint': 'beforeDeath',
          },
        {'optionId': skip, 'skip': true},
      ],
    );
    state.choice = choice;
    _choiceContinuation = (id) {
      if (id == skip ||
          (_interactionRulesVersion >= 3 &&
              (!actor.skills.contains(owned) ||
                  !_settlementUsable(actor, owned))) ||
          !_settlementUsable(actor, skill)) {
        complete();
        return;
      }
      final targetId = targets[id]!;
      final command = UseSkillCommand(
        player.id,
        owned.instanceId,
        copiedSkillId: identical(owned, skill) ? null : skill.definition.id,
        targetIds: [targetId],
      );
      final suppressed = _negateSkills(actor);
      _commitModuleSkill(actor, owned, skill, command);
      if (_interactionRulesVersion >= 4) {
        _openInterruptibleSkill(
          player,
          skill,
          [targetId],
          deferDeath: true,
          suppressed: suppressed,
          resolve: (done) => _runAbility(
            actor,
            [targetId],
            suppressed ? const [] : skill.definition.effects,
            done,
          ),
          complete: complete,
        );
        return;
      }
      _runAbility(actor, [targetId], skill.definition.effects, complete);
    };
    _event('choiceOpened', {
      'choiceId': choice.id,
      'playerId': player.id,
      'kind': choice.kind.name,
      'checkpoint': 'beforeDeath',
      'skillId': skill.definition.id,
    });
  }

  void _spendTemporaryShields(CharacterInstance target, int amount) {
    var left = amount;
    for (var i = 0; i < target.temporaryShields.length && left > 0; i++) {
      final layer = target.temporaryShields[i];
      final spent = left < layer.remaining ? left : layer.remaining;
      layer.remaining -= spent;
      left -= spent;
    }
    target.temporaryShields.removeWhere((s) => s.remaining <= 0);
  }

  bool _settlementUsable(CharacterInstance actor, SkillInstance skill) {
    if (skill.leasedOut ||
        !actor.alive ||
        _blocked(actor, (s) => s.blockSkills) ||
        skill.cooldown > 0 ||
        skill.remainingUses == 0) {
      return false;
    }
    try {
      _checkExecutionCosts(actor, skill);
      return true;
      // Validation failures become a disabled option; no mutation has occurred.
      // ignore: avoid_catching_errors
    } on StateError {
      return false;
    }
  }

  void _offerDamageSkills(List<_DamagePlan> plans, void Function() complete) {
    plans = [
      for (final plan in plans) ...[plan, ...plan.shares],
    ];
    final holders = [for (final p in state.players) p.character];
    void holder(int index) {
      if (index == holders.length) {
        complete();
        return;
      }
      final actor = holders[index];
      // A one-use checkpoint skill removes itself. Resume over the original
      // instances so shifting positions cannot skip a sibling or run past end.
      final ownedSkills = _interactionRulesVersion >= 3
          ? actor.skills.toList()
          : actor.skills;
      void skills(int i) {
        if (i >= ownedSkills.length) {
          holder(index + 1);
          return;
        }
        final owned = ownedSkills[i];
        if (!actor.skills.contains(owned)) {
          skills(i + 1);
          return;
        }
        final executions =
            owned.definition.mechanism == SkillMechanism.copyPublicSkill
            ? _copyCandidates(actor, owned).toList()
            : [owned];
        void candidate(int j) {
          if (j == executions.length) {
            skills(i + 1);
            return;
          }
          final skill = executions[j];
          final rule = skill.definition.checkpoint;
          final eligible = plans
              .where(
                (p) =>
                    p.amount > 0 &&
                    p.kind != DamageKind.real &&
                    rule != null &&
                    rule.kinds.contains(p.kind) &&
                    (!rule.attackOnly || p.attack) &&
                    ((rule.at == SkillCheckpoint.damageDealt &&
                            p.source == actor) ||
                        (rule.at == SkillCheckpoint.damageReceived &&
                            p.target == actor)),
              )
              .toList();
          final amount = eligible.fold<int>(0, (n, p) => n + p.amount);
          if (eligible.isEmpty ||
              !actor.skills.contains(owned) ||
              amount < rule!.minimumDamage ||
              !_settlementUsable(actor, skill)) {
            candidate(j + 1);
            return;
          }
          final opponent = rule.at == SkillCheckpoint.damageDealt
              ? eligible.first.target
              : eligible.first.source;
          _offerCheckpoint(
            actor,
            owned,
            skill,
            opponent,
            {
              'damage': amount,
              'targetId': eligible.first.target.instanceId,
              'sourceId': eligible.first.source?.instanceId,
            },
            () {
              for (final p in plans.where(
                (p) =>
                    p.kind != DamageKind.lifeLoss &&
                    p.kind != DamageKind.real &&
                    (rule.at == SkillCheckpoint.damageDealt
                        ? p.source == actor
                        : p.target == actor),
              )) {
                p.amount = (p.amount * rule.damageFactor).round().clamp(
                  0,
                  1000000000,
                );
              }
            },
            () => candidate(j + 1),
          );
        }

        candidate(0);
      }

      skills(0);
    }

    holder(0);
  }

  void _offerCheckpoint(
    CharacterInstance actor,
    SkillInstance owned,
    SkillInstance skill,
    CharacterInstance? opponent,
    Map<String, Object?> details,
    void Function() apply,
    void Function() complete,
  ) {
    final player = state.players.firstWhere((p) => p.character == actor);
    final branches =
        skill.definition.effects.isNotEmpty &&
            skill.definition.effects.first is SelectOptionEffect
        ? (skill.definition.effects.first as SelectOptionEffect).options
        : [
            AbilityOption(
              id: 'activate',
              label: '发动',
              effects: skill.definition.effects,
            ),
          ];
    final options = <Map<String, Object?>>[];
    final actions = <String, AbilityOption>{};
    for (final branch in branches) {
      final id = state.id('option');
      actions[id] = branch;
      options.add({
        'optionId': id,
        'instanceId': owned.instanceId,
        'definitionId': skill.definition.id,
        'abilityOptionId': branch.id,
        'label': branch.label,
        'checkpoint': skill.definition.checkpoint!.at.name,
        'cost': {
          'life': skill.definition.lifeCost,
          'mp': actor.noMp ? 0 : _skillMpCost(actor, skill.definition),
        },
        'cooldownOnUse': skill.definition.cooldown,
        ...details,
      });
    }
    final skip = state.id('option');
    options.add({'optionId': skip, 'skip': true, 'label': '不发动'});
    final choice = PendingChoice(
      id: state.id('choice'),
      playerId: player.id,
      kind: ChoiceKind.abilityOption,
      options: options,
      details:
          skill.definition.checkpoint!.at ==
              SkillCheckpoint.otherDamageThreshold
          ? {
              'source': {'kind': 'skill', 'definitionId': skill.definition.id},
            }
          : const {},
    );
    state.choice = choice;
    _choiceContinuation = (id) {
      if (id == skip ||
          (_interactionRulesVersion >= 3 &&
              (!actor.skills.contains(owned) ||
                  !_settlementUsable(actor, owned))) ||
          !_settlementUsable(actor, skill)) {
        complete();
        return;
      }
      final command = UseSkillCommand(
        player.id,
        owned.instanceId,
        copiedSkillId: identical(owned, skill) ? null : skill.definition.id,
        targetIds:
            skill.definition.checkpoint!.at ==
                    SkillCheckpoint.otherDamageThreshold &&
                opponent != null
            ? [opponent.instanceId]
            : const [],
      );
      final suppressed =
          skill.definition.checkpoint!.at ==
              SkillCheckpoint.otherDamageThreshold &&
          _negateSkills(actor);
      _commitModuleSkill(actor, owned, skill, command);
      final tail =
          skill.definition.effects.isNotEmpty &&
              skill.definition.effects.first is SelectOptionEffect
          ? skill.definition.effects.skip(1).toList()
          : const <EffectDefinition>[];
      if (_interactionRulesVersion >= 4) {
        final targets = opponent == null ? <String>[] : [opponent.instanceId];
        _openInterruptibleSkill(
          player,
          skill,
          targets,
          suppressed: suppressed,
          deferDeath:
              skill.definition.checkpoint!.at == SkillCheckpoint.beforeDeath,
          resolve: (done) {
            if (suppressed) {
              done();
              return;
            }
            apply();
            _runAbility(actor, targets, [
              ...actions[id]!.effects,
              ...tail,
            ], done);
          },
          complete: complete,
        );
        return;
      }
      apply();
      _runAbility(actor, opponent == null ? [] : [opponent.instanceId], [
        ...actions[id]!.effects,
        ...tail,
      ], complete);
    };
    _event('choiceOpened', {
      'choiceId': choice.id,
      'playerId': player.id,
      'kind': choice.kind.name,
      'checkpoint': skill.definition.checkpoint!.at.name,
      'skillId': skill.definition.id,
      ...details,
    });
  }

  void _offerOtherDamageThreshold(
    _DamagePlan plan,
    int before,
    int after,
    void Function() complete,
  ) {
    final source = plan.source;
    if (source == null ||
        !source.alive ||
        plan.kind == DamageKind.lifeLoss ||
        after <= before) {
      complete();
      return;
    }
    // Snapshot instances: a preceding reaction can consume, borrow or remove
    // skills. Recheck ownership, costs and target conditions before each offer.
    final candidates = <(CharacterInstance, SkillInstance, SkillInstance)>[
      for (final player in state.players)
        if (player.character != source)
          for (final owned in player.character.skills.toList())
            if (owned.definition.mechanism == SkillMechanism.copyPublicSkill)
              for (final skill in _copyCandidates(player.character, owned))
                (player.character, owned, skill)
            else
              (player.character, owned, owned),
    ];
    void next(int index) {
      if (index == candidates.length || !source.alive) {
        complete();
        return;
      }
      final (actor, owned, skill) = candidates[index];
      final rule = skill.definition.checkpoint;
      if (rule?.at != SkillCheckpoint.otherDamageThreshold ||
          before >= rule!.minimumDamage ||
          after < rule.minimumDamage ||
          !rule.kinds.contains(plan.kind) ||
          (rule.attackOnly && !plan.attack) ||
          !actor.skills.contains(owned) ||
          !_settlementUsable(actor, owned) ||
          !_settlementUsable(actor, skill) ||
          !_conditionMatches(skill.definition.targetWhen, actor, source)) {
        next(index + 1);
        return;
      }
      _offerCheckpoint(
        actor,
        owned,
        skill,
        source,
        {
          'targetId': source.instanceId,
          'damage': after - before,
          'damageThisGlobalRound': after,
        },
        () {},
        () => next(index + 1),
      );
    }

    next(0);
  }
}
