part of 'engine.dart';

final class _AttackScorePiece {
  const _AttackScorePiece(
    this.owner, {
    this.attack = 0,
    this.defense = 0,
    this.dice = 0,
    this.finalBonus = 0,
    this.attackFactor = 1,
    this.defenseFactor = 1,
    this.finalFactor = 1,
    this.ignoreDefense = false,
    this.ignoreAmount = 0,
    this.ignoreRatio = 0,
  });
  final ContributionOwner? owner;
  final int attack, defense, dice, finalBonus, ignoreAmount;
  final double attackFactor, defenseFactor, finalFactor, ignoreRatio;
  final bool ignoreDefense;
}

final class _ScoreStatTerm {
  const _ScoreStatTerm(this.owner, this.flat, this.factor);
  final ContributionOwner? owner;
  final int flat;
  final double factor;
}

final class _ScoreStatSnapshot {
  const _ScoreStatSnapshot(this.base, this.terms, {this.attack = false});
  final int base;
  final bool attack;
  final List<_ScoreStatTerm> terms;
  int value(Set<String> excluded) {
    final included = terms.where(
      (t) => t.owner == null || !excluded.contains(t.owner!.key),
    );
    var value = base + included.fold<int>(0, (n, t) => n + t.flat);
    if (attack) {
      for (final t in included) {
        value = (value * t.factor).floor();
      }
    }
    return value.clamp(0, 1000000000);
  }
}

/// Adapts verified kernel facts to independent, non-mutating observers.
extension _StatisticsHooks on GameKernel {
  void _scoreResourceChange(
    CharacterInstance actor,
    CharacterInstance target,
    int delta, {
    StatisticsResource resource = StatisticsResource.mp,
  }) {
    if (_statisticsRulesVersion < 2) {
      _performance.resourceChange(actor, target, delta, resource: resource);
      return;
    }
    if (_previewMode) return;
    final status = _currentTrigger?.status ?? _effectStatus;
    final source = status == null
        ? actor
        : state.players
              .map((p) => p.character)
              .where((c) => c.instanceId == status.sourceId)
              .firstOrNull;
    if (source != null) {
      _performance.resourceChange(source, target, delta, resource: resource);
    }
  }

  ContributionOwner? _scoreOwner(
    String? source,
    CharacterInstance beneficiary,
    ContributionRoute route, {
    bool? increases,
  }) {
    if (source == null) return null;
    final friendly = _performance.scores.allies(source, beneficiary.instanceId);
    if (route == ContributionRoute.weakening ? friendly : !friendly) {
      return null;
    }
    return ContributionOwner(
      source,
      beneficiary.instanceId,
      route,
      increases: increases,
    );
  }

  _ScoreStatSnapshot _scoreStat(CharacterInstance c, Stat stat) {
    final mirrored = c.statuses.any((s) => s.definition.swapBaseAttackDefense);
    var base = stat == Stat.attack
        ? (mirrored ? c.template.defense : c.template.attack)
        : (mirrored ? c.template.attack : c.template.defense);
    base += c.permanentModifiers[stat] ?? 0;
    for (final trait in c.traits) {
      base += trait.definition.modifiers[stat] ?? 0;
      if (_blocked(c, (s) => s.blockTraits)) continue;
      for (final bonus in trait.definition.markStatBonuses) {
        final count = c.marks
            .where(
              (m) =>
                  m.definition.id == bonus.markId &&
                  (!bonus.fromSelf ||
                      !m.definition.sourceScoped ||
                      m.sourceId == c.instanceId),
            )
            .fold<int>(0, (n, m) => n + m.count);
        base += (bonus.modifiersPerCount[stat] ?? 0) * count;
      }
      for (final bonus in trait.definition.statusStatBonuses) {
        if (bonus.allStatuses.every(
          (id) => c.statuses.any((s) => s.definition.id == id),
        )) {
          base += bonus.modifiers[stat] ?? 0;
        }
      }
    }
    final terms = <_ScoreStatTerm>[];
    final attack = stat == Stat.attack;
    for (final s in c.statuses) {
      final flat =
          (s.definition.modifiersPerIntensity[stat] ?? 0) * s.intensity;
      final factor = attack ? s.definition.attackFactor : 1.0;
      final benefit = attack ? (flat > 0 || factor > 1) : (flat > 0);
      final harmful = attack ? (flat < 0 || factor < 1) : (flat < 0);
      final owner = benefit || harmful
          ? _scoreOwner(
              s.sourceId,
              c,
              benefit
                  ? (attack
                        ? ContributionRoute.enhancement
                        : ContributionRoute.protection)
                  : ContributionRoute.weakening,
              increases: attack ? benefit : harmful,
            )
          : null;
      terms.add(_ScoreStatTerm(owner, flat, factor));
    }
    if (!attack) {
      for (final d in c.temporaryDefense) {
        terms.add(
          _ScoreStatTerm(
            _scoreOwner(c.instanceId, c, ContributionRoute.protection),
            d.amount,
            1,
          ),
        );
      }
    }
    return _ScoreStatSnapshot(base, List.unmodifiable(terms), attack: attack);
  }

  DamageAttribution? _scoreAttackFormula(
    CharacterInstance actor,
    CharacterInstance target,
    PendingResolution pending,
    List<_AttackScorePiece> pieces, {
    required int attackBonus,
    required int defenseBonus,
    required int diceBonus,
    required int finalBonus,
    required double finalMultiplierBase,
    required AttackFormula? formula,
    required DamageKind kind,
  }) {
    if (_statisticsRulesVersion < 2 || _previewMode) return null;
    final attack = _scoreStat(actor, Stat.attack),
        defense = _scoreStat(target, Stat.defense);
    final all = [...pieces];
    for (final status in actor.statuses) {
      final d = status.definition;
      final flat = (kind == DamageKind.real || kind == DamageKind.lifeLoss)
          ? 0
          : d.attackFlatPerIntensity * status.intensity;
      final dice = d.attackDicePerIntensity * status.intensity;
      if (flat != 0 || dice != 0) {
        all.add(
          _AttackScorePiece(
            _scoreOwner(
              status.sourceId,
              actor,
              flat + dice >= 0
                  ? ContributionRoute.enhancement
                  : ContributionRoute.weakening,
              increases: flat + dice >= 0,
            ),
            finalBonus: flat,
            dice: dice,
          ),
        );
      }
    }
    for (final status in target.statuses) {
      final d =
          status.definition.incomingDefenseBonusPerIntensity * status.intensity;
      if (d != 0) {
        all.add(
          _AttackScorePiece(
            _scoreOwner(
              status.sourceId,
              target,
              d > 0
                  ? ContributionRoute.protection
                  : ContributionRoute.weakening,
              increases: d < 0,
            ),
            defense: d,
          ),
        );
      }
    }
    var rawDice = pending.diceResult;
    final extra = pending.armedAttacks.any((a) => a.rule.diceCount > 1);
    final roll = pending.diceRoll;
    var preparedDiceBonus = 0;
    if (extra &&
        roll != null &&
        roll.spec.nominalCount > 1 &&
        !roll.modifications.any((m) => m.operation == DiceAdjustment.replace)) {
      final perDie = roll.values.length ~/ roll.spec.nominalCount;
      preparedDiceBonus = roll.values
          .skip(perDie)
          .fold<int>(0, (a, b) => a + b);
      all.add(
        _AttackScorePiece(
          _scoreOwner(actor.instanceId, actor, ContributionRoute.enhancement),
          dice: preparedDiceBonus,
        ),
      );
      rawDice -= preparedDiceBonus;
      diceBonus += preparedDiceBonus;
    }
    final fixedPieces = List<_AttackScorePiece>.unmodifiable(all);
    final caps = _blocked(target, (s) => s.blockTraits)
        ? <IncomingAttackRule>[]
        : target.traits
              .map((t) => t.definition.incomingAttack)
              .whereType<IncomingAttackRule>()
              .toList();
    final rawCommitted = pending.diceResult;
    final locked = pending.diceLocked, maximum = pending.maximumDiceResult;
    final legacy = rules.useLegacyDamageFormula;
    int calculate(Set<String> excluded) {
      final removed = fixedPieces.where(
        (p) => p.owner != null && excluded.contains(p.owner!.key),
      );
      final included = fixedPieces.where(
        (p) => p.owner == null || !excluded.contains(p.owner!.key),
      );
      var dice =
          rawDice + diceBonus - removed.fold<int>(0, (n, p) => n + p.dice);
      for (final cap in caps) {
        if (cap.useBaseDice) dice = rawCommitted;
        if (cap.diceCap != null) dice = dice.clamp(0, cap.diceCap!);
      }
      if (locked) dice = maximum;
      final a = attack.value(excluded);
      final aBonus = attackBonus - removed.fold<int>(0, (n, p) => n + p.attack);
      final dBonus =
          defenseBonus - removed.fold<int>(0, (n, p) => n + p.defense);
      final aFactor = included.fold<double>(1, (n, p) => n * p.attackFactor);
      final dFactor = included.fold<double>(1, (n, p) => n * p.defenseFactor);
      final flat =
          finalBonus - removed.fold<int>(0, (n, p) => n + p.finalBonus);
      final multiplier = included.fold<double>(
        finalMultiplierBase,
        (n, p) => n * p.finalFactor,
      );
      final ignored = included.any((p) => p.ignoreDefense);
      final ratio = included
          .fold<double>(0, (n, p) => n + p.ignoreRatio)
          .clamp(0, 1);
      final amount = included.fold<int>(0, (n, p) => n + p.ignoreAmount);
      final d = ignored
          ? 0
          : (defense.value(excluded) * (1 - ratio) - amount).clamp(
              0,
              1000000000,
            );
      if (formula != null) {
        return ((dice + 1) *
                .5 *
                ((a + aBonus) * aFactor + formula.attackOffset))
            .floor()
            .clamp(0, 1000000000);
      }
      return GameKernel.ruleDamage(
        finalDice: dice.clamp(0, 1000000).toDouble(),
        attack: a,
        defense: d,
        attackBonus: aBonus,
        defenseBonus: dBonus,
        attackMultiplier: aFactor,
        defenseMultiplier: dFactor,
        finalBonus: flat,
        finalMultiplier: multiplier,
        useLegacyDamageFormula: legacy,
      );
    }

    return DamageAttribution.formula(calculate, [
      ...attack.terms.map((t) => t.owner).whereType<ContributionOwner>(),
      ...defense.terms.map((t) => t.owner).whereType<ContributionOwner>(),
      ...fixedPieces.map((t) => t.owner).whereType<ContributionOwner>(),
    ]);
  }

  void _sampleStatistics() {
    if (_statisticsRulesVersion < 2 || _previewMode) return;
    _performance.sampleCoverage(
      state,
      skillEligible: _scoreSkillEligible,
      traitEligible: _scoreTraitEligible,
    );
  }

  void _scoreActionFee(
    CharacterInstance actor,
    int base,
    int paid, {
    bool cards = false,
  }) {
    if (_statisticsRulesVersion < 2 || _previewMode || actor.noMp) return;
    final discount = base - paid;
    if (discount <= 0) return;
    final sources = <String, double>{};
    void add(String? source, int value) {
      if (source != null && value > 0) {
        sources.update(
          source,
          (n) => n + value,
          ifAbsent: () => value.toDouble(),
        );
      }
    }

    for (final s in actor.statuses) {
      add(s.sourceId, s.definition.actionMpDiscount);
      if (cards) {
        if (s.definition.cardMpCap case final cap? when base > cap) {
          add(s.sourceId, base - cap);
        }
      }
    }
    if (!_blocked(actor, (s) => s.blockTraits)) {
      for (final t in actor.traits) {
        add(actor.instanceId, t.definition.actionMpDiscount);
        if (cards &&
            (t.definition.cardMaxTagDiscount ||
                t.definition.freeCardTags.isNotEmpty)) {
          add(actor.instanceId, discount);
        }
      }
    }
    _performance.scores.distributeEnhancement(
      sources,
      actor.instanceId,
      EnhancementScore.resourceGain,
      discount * _performance.rules['mp'],
    );
  }

  void _scoreAbilityFee(
    CharacterInstance actor, {
    SkillDefinition? skill,
    TraitAction? trait,
  }) {
    if (_statisticsRulesVersion < 2 || _previewMode || actor.noMp) return;
    for (final s in actor.statuses) {
      final extra = skill != null
          ? s.definition.skillMpSurcharge
          : s.definition.traitMpSurcharge;
      if (extra > 0) {
        _performance.scores.control(
          s.sourceId,
          actor.instanceId,
          ControlScore.resourceSuppression,
          extra * _performance.rules['mp'],
        );
      }
    }
    if (skill != null &&
        skill.mpSurcharge > 0 &&
        !_blocked(actor, (s) => s.blockTraits) &&
        actor.traits.any((t) => t.definition.waiveSkillSurcharge)) {
      _performance.scores.enhance(
        actor.instanceId,
        actor.instanceId,
        EnhancementScore.resourceGain,
        skill.mpSurcharge * _performance.rules['mp'],
      );
    }
  }

  void _scoreHealing(
    CharacterInstance target,
    int requested,
    int resolved,
    int missing,
  ) {
    if (_statisticsRulesVersion < 2 ||
        _previewMode ||
        target.defenseLife ||
        target.lifeLocked ||
        missing <= 0) {
      return;
    }
    final pieces = <(ContributionOwner?, double)>[
      for (final s in target.statuses)
        if (s.definition.healingBonusPerIntensity != 0)
          (
            _scoreOwner(
              s.sourceId,
              target,
              s.definition.healingBonusPerIntensity > 0
                  ? ContributionRoute.enhancement
                  : ContributionRoute.weakening,
              increases: s.definition.healingBonusPerIntensity > 0,
            ),
            s.definition.healingBonusPerIntensity * s.intensity,
          ),
    ];
    final duelFactor = state.duel ? rules.duelHealingMultiplier : 1;
    final trace = DamageAttribution.formula((excluded) {
      final factor =
          1 +
          pieces
              .where((p) => p.$1 == null || !excluded.contains(p.$1!.key))
              .fold<double>(0, (n, p) => n + p.$2);
      return (requested * factor.clamp(0, double.infinity) * duelFactor)
          .floor();
    }, pieces.map((p) => p.$1).whereType<ContributionOwner>());
    trace.settle(
      _performance.scores,
      observed: resolved,
      effectiveLimit: missing,
    );
  }

  void _scoreNaturalMp(
    CharacterInstance actor,
    int base,
    int before,
    int after,
  ) {
    if (_statisticsRulesVersion < 2 || _previewMode || actor.noMp) return;
    final positive = <String, double>{}, negative = <String, double>{};
    for (final s in actor.statuses) {
      final bonus =
          (s.definition.mpRegenPerIntensity +
              s.definition.mpRecoveryFlatPerIntensity) *
          s.intensity;
      final source = s.sourceId;
      if (source == null || bonus == 0) continue;
      final map = bonus > 0 ? positive : negative;
      map.update(
        source,
        (n) => n + bonus.abs(),
        ifAbsent: () => bonus.abs().toDouble(),
      );
    }
    final ordinary = (before + base).clamp(
      _mpFloor(actor),
      actor.value(Stat.maxMp),
    );
    final delta = after - ordinary;
    if (delta > 0) {
      _performance.scores.distributeEnhancement(
        positive,
        actor.instanceId,
        EnhancementScore.resourceGain,
        delta * _performance.rules['mp'],
      );
    }
    if (delta < 0) {
      _performance.scores.distributeControl(
        negative,
        actor.instanceId,
        ControlScore.resourceSuppression,
        -delta * _performance.rules['mp'],
      );
    }
  }

  void _scoreDamageModifiers(_DamagePlan plan) {
    final trace = plan.scoreTrace;
    final source = plan.source, target = plan.target;
    if (trace == null) return;
    if (plan.kind == DamageKind.physical && source != null) {
      for (final s in source.statuses) {
        final flat =
            s.definition.outgoingPhysicalFlatPerIntensity * s.intensity;
        if (flat == 0) continue;
        trace.transform(
          (v) => v + flat,
          owner: _scoreOwner(
            s.sourceId,
            source,
            flat > 0
                ? ContributionRoute.enhancement
                : ContributionRoute.weakening,
            increases: flat > 0,
          ),
        );
      }
      trace.transform((v) => v.clamp(0, 1000000000));
    }
    final incoming = <(ContributionOwner?, double)>[];
    final traits = <(ContributionOwner?, double)>[];
    final outgoing = <(ContributionOwner?, double)>[];
    for (final s in target.statuses) {
      final delta =
          (s.definition.incomingDamageBonusPerIntensity +
              (plan.attack
                  ? s.definition.incomingAttackBonusPerIntensity
                  : 0)) *
          s.intensity;
      if (delta != 0) {
        incoming.add((
          _scoreOwner(
            s.sourceId,
            target,
            delta > 0
                ? ContributionRoute.weakening
                : ContributionRoute.protection,
            increases: delta > 0,
          ),
          delta,
        ));
      }
    }
    if (!_blocked(target, (s) => s.blockTraits)) {
      for (final t in target.traits) {
        final factor = t.definition.incomingDamageMultiplier;
        if (factor != 1) {
          traits.add((
            _scoreOwner(
              target.instanceId,
              target,
              ContributionRoute.protection,
            ),
            factor,
          ));
        }
      }
    }
    if (plan.attack && source != null) {
      for (final s in source.statuses) {
        final delta =
            s.definition.outgoingAttackBonusPerIntensity * s.intensity;
        if (delta != 0) {
          outgoing.add((
            _scoreOwner(
              s.sourceId,
              source,
              delta > 0
                  ? ContributionRoute.enhancement
                  : ContributionRoute.weakening,
              increases: delta > 0,
            ),
            delta,
          ));
        }
      }
    }
    bool included(ContributionOwner? owner, Set<String> excluded) =>
        owner == null || !excluded.contains(owner.key);
    trace.transformGroup(
      (value, excluded) {
        var factor = 1.0;
        for (final entry in incoming) {
          if (included(entry.$1, excluded)) factor += entry.$2;
        }
        for (final entry in traits) {
          if (included(entry.$1, excluded)) factor *= entry.$2;
        }
        var out = 1.0;
        for (final entry in outgoing) {
          if (included(entry.$1, excluded)) out += entry.$2;
        }
        return (value *
                factor.clamp(0, double.infinity) *
                out.clamp(0, double.infinity))
            .round();
      },
      [
        ...incoming,
        ...traits,
        ...outgoing,
      ].map((e) => e.$1).whereType<ContributionOwner>(),
    );
    for (final p in state.players) {
      final holder = p.character;
      if (!holder.alive || _blocked(holder, (s) => s.blockTraits)) continue;
      for (final t in holder.traits) {
        final aura = t.definition.damageAura;
        if (aura != null &&
            _effectTargets(holder, [
              target.instanceId,
            ], aura.scope).contains(target) &&
            _conditionMatches(aura.when, holder, target)) {
          final factor = aura.factor, flat = aura.flat;
          final decreasing = factor < 1 || flat < 0;
          trace.transform(
            (v) => ((v + flat) * factor).round().clamp(0, 1000000000),
            owner: _scoreOwner(
              holder.instanceId,
              target,
              decreasing
                  ? ContributionRoute.protection
                  : ContributionRoute.weakening,
              increases: !decreasing,
            ),
          );
        }
      }
    }
    for (final s in target.statuses.where((s) => s.definition.invulnerable)) {
      trace.transform(
        (_) => 0,
        owner: _scoreOwner(s.sourceId, target, ContributionRoute.protection),
      );
    }
  }

  int _scoreDamageLimit(
    CharacterInstance target,
    DamageKind kind, {
    AttackPacket? packet,
  }) {
    if (target.defenseLife) return 0;
    final shield =
        kind == DamageKind.physical &&
            packet?.ignoreShield != true &&
            !_blocked(target, (s) => s.ignoreShield)
        ? target.shield
        : 0;
    return target.hp.clamp(0, 1000000000) + shield.clamp(0, 1000000000);
  }

  void _scoreDodge(
    CharacterInstance actor,
    CharacterInstance target,
    AttackPacket packet,
    StatusInstance dodge,
  ) {
    if (_statisticsRulesVersion < 2 || _previewMode) return;
    final trace = _performance.damageAttribution(
      packet.actionId,
      target.instanceId,
      packet.amount,
    );
    trace.transform(
      (_) => 0,
      owner: _scoreOwner(dodge.sourceId, target, ContributionRoute.protection),
    );
    trace.settle(
      _performance.scores,
      observed: 0,
      effectiveLimit: _scoreDamageLimit(target, packet.kind, packet: packet),
    );
  }

  bool _scoreSkillEligible(CharacterInstance actor, SkillInstance skill) {
    final d = skill.definition;
    if (skill.leasedOut ||
        skill.remainingUses == 0 ||
        skill.cooldown > 0 ||
        d.passive) {
      return false;
    }
    final ownTurn =
        state.activePlayer.character == actor &&
        state.phase == GamePhase.action &&
        state.pending == null;
    final pending = state.pending;
    final response =
        pending != null &&
        pending.waitingPlayerIds.contains(
          state.players.firstWhere((p) => p.character == actor).id,
        );
    final timing = switch (d.timing) {
      SkillTiming.main =>
        ownTurn ||
            (d.anytime && state.phase == GamePhase.action && pending == null),
      SkillTiming.diceResponse =>
        response && pending.kind == PendingKind.attack,
      SkillTiming.skillResponse =>
        response && pending.kind == PendingKind.skill,
      SkillTiming.actionResponse => response,
      SkillTiming.settlement => false,
    };
    if (!timing ||
        ((d.beforeAttack || d.beforeCards) && actor.actionsRemaining <= 0)) {
      return false;
    }
    try {
      return _conditionMatches(d.when, actor, actor) &&
          (actor.noMp || actor.mp >= _skillMpCost(actor, d)) &&
          (actor.defenseLife || actor.hp >= _skillLifeCost(actor, d)) &&
          _canPayMarks(actor, d.markCosts) &&
          d.statCosts.entries.every((e) => actor.value(e.key) >= e.value);
    } on StateError {
      return false;
    }
  }

  bool _scoreTraitEligible(CharacterInstance actor, TraitInstance trait) {
    final base = trait.definition.active;
    if (base == null) return false;
    final options = base.options.isEmpty ? [base] : base.options.values;
    return options.any(
      (a) =>
          (a.anytime ||
              (state.phase == GamePhase.action &&
                  state.activePlayer.character == actor &&
                  state.pending == null)) &&
          (a.maxUsesPerRound == null ||
              trait.activeRound != _activeLimitWindow(actor, a) ||
              trait.activeUses < a.maxUsesPerRound!) &&
          (actor.noMp || actor.mp >= _traitMpCost(actor, a)) &&
          (!a.requireFullMp || actor.mp >= actor.value(Stat.maxMp)) &&
          actor.hand.where((c) => !c.disabled).length >= a.discardCount &&
          _canPayMarks(actor, a.markCosts),
    );
  }

  int _scoreAvailableDraw(int requested) => requested.clamp(
    0,
    state.drawPile.length +
        (rules.emptyDeckPolicy == EmptyDeckPolicy.recycleDiscards
            ? state.discardPile.length
            : 0),
  );
  void _scoreBlockedDrawPhase(CharacterInstance actor, int amount) {
    _performance.blockedResource(
      actor,
      _scoreAvailableDraw(amount),
      resource: StatisticsResource.hand,
      blocked: (s) => s.blockDrawPhase || s.blockDraw,
    );
  }

  void _scoreBlockedNaturalMp(CharacterInstance actor) {
    if (_statisticsRulesVersion < 2 ||
        !actor.alive ||
        actor.noMp ||
        _skipOpeningMpRecovery(actor.race.regenPhase)) {
      return;
    }
    final race = actor.race;
    int wanted;
    if (race.regenMode == MpRegenMode.refillAfterExhaustion) {
      wanted = actor.refillAfterExhaustionPending
          ? actor.value(Stat.maxMp) - actor.mp
          : 0;
    } else {
      if (race.regenInterval <= 0 ||
          actor.regenProgress + 1 < race.regenInterval) {
        return;
      }
      wanted =
          _amount(race.regenMp, race.regenMpValue, actor, actor) +
          actor.statuses.fold<int>(
            0,
            (n, s) => n + s.definition.mpRegenPerIntensity * s.intensity,
          );
    }
    wanted += actor.statuses.fold<int>(
      0,
      (n, s) => n + s.definition.mpRecoveryFlatPerIntensity * s.intensity,
    );
    wanted = wanted.clamp(
      0,
      (actor.value(Stat.maxMp) - actor.mp).clamp(0, 1000000),
    );
    _performance.blockedResource(
      actor,
      wanted,
      resource: StatisticsResource.mp,
      blocked: (s) => s.blockMpRegen || s.skipTurn,
    );
  }
}
