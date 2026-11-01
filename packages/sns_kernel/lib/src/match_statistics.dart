import 'definitions.dart';
import 'performance_statistics.dart';
import 'state.dart';
import 'statistics/damage_attribution.dart';
import 'statistics/match_data.dart';
import 'statistics/support_scores.dart';

enum StatisticsResource { mp, hand }

final class _ShieldContribution {
  _ShieldContribution(this.source, this.remaining);
  final String source;
  int remaining;
  TemporaryShield? temporary;
}

/// Integration facade; legacy projections remain exact for pre-v2 checkpoints.
final class MatchStatistics {
  MatchStatistics({
    required this.version,
    this.rules = const SupportScoreRules(),
  }) : scores = SupportScores(rules: rules);
  final int version;
  final SupportScoreRules rules;
  final SupportScores scores;
  final MatchDataStatistics data = MatchDataStatistics();
  final PerformanceStatistics _legacy = PerformanceStatistics();
  final Set<int> _seen = {};
  final Map<String, List<_ShieldContribution>> _shields = {};
  final Map<String, int> _cycles = {};
  final Map<String, String> _disabledSources = {},
      _tagSources = {},
      _forcedSources = {};
  final Set<String> _coveredCards = {}, _coveredTags = {};
  final Set<String> _lastDisabled = {};
  final Set<String> _revealedCards = {};
  final Set<String> _cleanseGroups = {};
  final Map<String, DamageAttribution> _attackAttribution = {};
  final Map<String, String> _redirectProtection = {};
  final Map<String, Map<String, double>> _cancelledCardCounts = {};
  bool get modern => version >= 2;

  void record(KernelEvent event, KernelState state) {
    if (!modern) {
      _legacy.record(event, state);
      return;
    }
    if (!_seen.add(event.sequence)) return;
    scores.register(state);
    data.record(event, state);
    final d = event.data;
    if (event.type == 'turnStarted' && !event.extraTurn) {
      final player = state.players
          .where((p) => p.id == d['playerId'])
          .firstOrNull;
      if (player != null) {
        _cycles.update(
          player.character.instanceId,
          (v) => v + 1,
          ifAbsent: () => 1,
        );
      }
    }
    if (event.type == 'handCardsDisabled' && d['sourceId'] is String) {
      final target = state.players
          .where((p) => p.character.instanceId == d['targetId'])
          .firstOrNull;
      for (final card in target?.character.hand ?? <CardInstance>[]) {
        if (card.disabled && !_lastDisabled.contains(card.instanceId)) {
          _disabledSources[card.instanceId] = d['sourceId']! as String;
        }
      }
    }
    if (event.type == 'cardTagRestricted' &&
        d['sourceId'] is String &&
        d['tag'] is String) {
      _tagSources['${d['targetId']}/${d['tag']}'] = d['sourceId']! as String;
    }
    if (event.type == 'forcedAttackTargetConsumed') {
      final target = d['actorId'] as String?;
      if (target != null) {
        scores.control(
          _forcedSources.remove(target),
          target,
          ControlScore.actionDenial,
          rules['redirect'],
        );
      }
    }
    _lastDisabled
      ..clear()
      ..addAll(
        state.players
            .expand((p) => p.character.hand)
            .where((c) => c.disabled)
            .map((c) => c.instanceId),
      );
    if (event.type == 'shieldGained' &&
        (d['amount'] as int? ?? 0) > 0 &&
        d['sourceId'] is String) {
      (_shields[d['targetId']! as String] ??= []).add(
        _ShieldContribution(d['sourceId']! as String, d['amount']! as int),
      );
    }
    if (event.type == 'cardPlayed' && d['instanceId'] is String) {
      _revealedCards.add(d['instanceId']! as String);
    }
    if (event.type == 'shieldBroken') _shields.remove(d['targetId']);
    for (final p in state.players) {
      final lots = _shields[p.character.instanceId];
      if (lots == null) continue;
      lots.removeWhere(
        (l) =>
            l.temporary != null &&
            !p.character.temporaryShields.contains(l.temporary),
      );
      var excess =
          lots.fold<int>(0, (n, l) => n + l.remaining) - p.character.shield;
      while (excess > 0 && lots.isNotEmpty) {
        final first = lots.removeAt(0);
        final removed = excess.clamp(0, first.remaining);
        excess -= removed;
        if (removed < first.remaining) {
          first.remaining -= removed;
          lots.insert(0, first);
        }
      }
    }
  }

  void resourceChange(
    CharacterInstance source,
    CharacterInstance target,
    int delta, {
    StatisticsResource resource = StatisticsResource.mp,
  }) {
    if (!modern) {
      _legacy.resourceChange(source, target, delta);
      return;
    }
    final points =
        delta.abs() * rules[resource == StatisticsResource.mp ? 'mp' : 'card'];
    if (delta > 0) {
      scores.enhance(
        source.instanceId,
        target.instanceId,
        EnhancementScore.resourceGain,
        points,
      );
    }
    if (delta < 0) {
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.resourceSuppression,
        points,
      );
    }
  }

  void statusChange(
    CharacterInstance source,
    CharacterInstance target,
    StatusDefinition status,
    int oldStacks,
    int oldIntensity,
    int stacks,
    int intensity,
  ) {
    if (!modern) {
      _legacy.statusChange(
        source,
        target,
        status,
        oldStacks,
        oldIntensity,
        stacks,
        intensity,
      );
      return;
    }
    if (stacks >= oldStacks && intensity >= oldIntensity) return;
    final removedLayers = (oldStacks - stacks).clamp(0, 1000000);
    final removedIntensity = status.hasIntensity
        ? (oldIntensity - (stacks <= 0 ? 0 : intensity)).clamp(0, 1000000)
        : 0;
    if (removedLayers == 0 && removedIntensity == 0) return;
    final instance = target.statuses
        .where((s) => s.definition.id == status.id)
        .firstOrNull;
    final friendly = scores.allies(source.instanceId, target.instanceId);
    final harmful =
        status.negative ||
        status.id.startsWith('decree_') ||
        status.skipTurn ||
        status.blockAttack ||
        status.blockCards ||
        status.blockSkills ||
        status.blockTraits ||
        status.blockDraw ||
        status.blockDrawPhase ||
        status.blockMpRegen ||
        status.healingBonusPerIntensity < 0 ||
        status.mpRegenPerIntensity < 0 ||
        status.incomingDamageBonusPerIntensity > 0 ||
        status.attackFactor < 1 ||
        status.modifiersPerIntensity.values.any((v) => v < 0);
    if (friendly && harmful) {
      if (instance?.sourceId case final String origin
          when scores.allies(origin, target.instanceId)) {
        return;
      }
      final lock =
          status.skipTurn ||
          status.blockAttack ||
          status.blockCards ||
          status.blockSkills ||
          status.blockTraits ||
          status.id == 'mental_action_lock';
      if (lock &&
          !_cleanseGroups.add(
            '${source.instanceId}/${target.instanceId}/'
            '${status.skipTurn}/${status.blockAttack}/${status.blockCards}/${status.blockSkills}/${status.blockTraits}',
          )) {
        return;
      }
      final points = lock
          ? rules['cleanseLock']
          : status.category == StatusCategory.anomaly
          ? rules['anomalyCleansed']
          : !status.isStatusEffect
          ? rules['fallback']
          : status.hasIntensity
          ? removedLayers * rules['statusLayer'] +
                removedIntensity * rules['statusIntensity']
          : removedLayers * rules['plainStatusLayer'];
      scores.enhance(
        source.instanceId,
        target.instanceId,
        EnhancementScore.buffCleanse,
        points,
      );
    } else if (!friendly && !harmful) {
      final points = !status.isStatusEffect
          ? rules['temporaryRemoved']
          : status.hasIntensity
          ? removedLayers * rules['statusLayer'] +
                removedIntensity * rules['statusIntensity']
          : removedLayers * rules['plainStatusLayer'];
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.weakeningDispel,
        points,
      );
    }
  }

  void otherEffect(
    CharacterInstance source,
    CharacterInstance target, {
    required bool positive,
    String? kind,
  }) {
    if (!modern) {
      _legacy.otherEffect(source, target, positive: positive);
      return;
    }
    if (const {
      'shield',
      'stat',
      'markGrant',
      'forcedTarget',
      'redirect',
      'cancelSkill',
      'cancelCard',
      'handLock',
    }.contains(kind)) {
      return;
    }
    if (positive) {
      scores.enhance(
        source.instanceId,
        target.instanceId,
        EnhancementScore.buffCleanse,
        rules['fallback'],
      );
    } else {
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.weakeningDispel,
        rules['fallback'],
      );
    }
  }

  void statChange(
    CharacterInstance source,
    CharacterInstance target,
    Stat stat,
    int delta,
  ) {
    if (!modern || delta == 0) return;
    final key = switch (stat) {
      Stat.attack || Stat.defense => 'permanentStat',
      Stat.maxHp => 'maxHp',
      Stat.maxMp => 'maxMp',
      Stat.maxHand => 'maxHand',
    };
    if (delta > 0) {
      scores.enhance(
        source.instanceId,
        target.instanceId,
        EnhancementScore.buffCleanse,
        delta * rules[key],
      );
    } else {
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.weakeningDispel,
        -delta * rules[key],
      );
    }
  }

  void cooldownChange(
    CharacterInstance source,
    CharacterInstance target,
    int delta,
  ) {
    if (!modern || delta == 0) return;
    if (delta < 0) {
      scores.enhance(
        source.instanceId,
        target.instanceId,
        EnhancementScore.buffCleanse,
        -delta * rules['cooldown'],
      );
    } else {
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.abilityRestriction,
        delta * rules['cooldown'],
      );
    }
  }

  void actionChange(
    CharacterInstance source,
    CharacterInstance target,
    int delta,
  ) {
    if (!modern || delta == 0) return;
    if (delta > 0) {
      scores.enhance(
        source.instanceId,
        target.instanceId,
        EnhancementScore.resourceGain,
        delta * rules['actionGained'],
      );
    } else {
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.actionDenial,
        -delta * rules['actionLost'],
      );
    }
  }

  void shieldRemoved(
    CharacterInstance source,
    CharacterInstance target,
    int amount,
  ) {
    if (!modern || amount <= 0) return;
    _consumeShields(target, amount, score: false);
    scores.control(
      source.instanceId,
      target.instanceId,
      ControlScore.weakeningDispel,
      amount * rules['shieldRemoved'],
    );
  }

  void shieldAbsorbed(CharacterInstance target, int consumed) {
    _consumeShields(target, consumed, score: true);
  }

  void bindTemporaryShield(CharacterInstance target, TemporaryShield shield) {
    if (!modern) return;
    final lot = _shields[target.instanceId]?.lastOrNull;
    if (lot != null) lot.temporary = shield;
  }

  void _consumeShields(
    CharacterInstance target,
    int consumed, {
    required bool score,
  }) {
    if (!modern || consumed <= 0) return;
    final lots = _shields[target.instanceId] ?? [];
    // Follow the engine's temporary-shield order, then FIFO permanent grants.
    final ordered = [
      for (final temporary in target.temporaryShields)
        ...lots.where((l) => identical(l.temporary, temporary)),
      ...lots.where((l) => l.temporary == null),
    ];
    for (final lot in ordered) {
      if (consumed <= 0) break;
      final amount = consumed.clamp(0, lot.remaining);
      if (score) {
        scores.enhance(
          lot.source,
          target.instanceId,
          EnhancementScore.damageProtection,
          amount * rules['damage'],
        );
      }
      consumed -= amount;
      lot.remaining -= amount;
    }
    lots.removeWhere((l) => l.remaining <= 0);
  }

  Map<String, double> lockSources(
    CharacterInstance target,
    bool Function(StatusDefinition) test,
  ) {
    final result = <String, double>{};
    for (final status in target.statuses) {
      final source = status.sourceId;
      if (source != null &&
          test(status.definition) &&
          !scores.allies(source, target.instanceId)) {
        result[source] = 1;
      }
    }
    return result;
  }

  String _cycle(CharacterInstance c) =>
      '${c.instanceId}/${_cycles[c.instanceId] ?? 0}';

  void blockedResource(
    CharacterInstance target,
    int amount, {
    required StatisticsResource resource,
    required bool Function(StatusDefinition) blocked,
  }) {
    if (!modern || amount <= 0) return;
    scores.distributeControl(
      lockSources(target, blocked),
      target.instanceId,
      ControlScore.resourceSuppression,
      amount * rules[resource == StatisticsResource.mp ? 'mp' : 'card'],
    );
  }

  void sampleCoverage(
    KernelState state, {
    required bool Function(CharacterInstance, SkillInstance) skillEligible,
    required bool Function(CharacterInstance, TraitInstance) traitEligible,
  }) {
    if (!modern || state.finished) return;
    _cleanseGroups.clear();
    scores.register(state);
    for (final p in state.players) {
      final c = p.character;
      if (!c.alive) continue;
      final cycle = _cycle(c);
      final skillSources = lockSources(c, (s) => s.blockSkills);
      if (skillSources.isNotEmpty && c.skills.any((s) => skillEligible(c, s))) {
        scores.distributeControl(
          skillSources,
          c.instanceId,
          ControlScore.abilityRestriction,
          rules['skillLock'],
          capKey: 'skill/$cycle',
          cap: rules['skillLock'],
        );
      }
      final traitSources = lockSources(c, (s) => s.blockTraits);
      if (traitSources.isNotEmpty && c.traits.any((t) => traitEligible(c, t))) {
        traitSuppressed(c);
      }
      if (state.activePlayer.character != c ||
          state.phase != GamePhase.action) {
        continue;
      }
      for (final card in c.hand) {
        final cardKey = '$cycle/${card.instanceId}';
        final disabledSource = _disabledSources[card.instanceId];
        if (card.disabled && disabledSource != null) {
          if (_coveredCards.add(cardKey)) {
            scores.distributeControl(
              {disabledSource: 1},
              c.instanceId,
              ControlScore.abilityRestriction,
              rules['handLock'],
              capKey: 'hand/$cycle',
              cap: rules['handLockCap'],
            );
          }
        }
        for (final tag in card.definition.tags) {
          final source = _tagSources['${c.instanceId}/$tag'];
          final restricted =
              (c.restrictedCardTags[tag] ?? 0) > state.round ||
              (c.anchoredCardTags[tag]?.isNotEmpty ?? false);
          if (source == null ||
              !restricted ||
              _coveredCards.contains(cardKey)) {
            continue;
          }
          if (_coveredTags.add('$cycle/$tag')) {
            scores.distributeControl(
              {source: 1},
              c.instanceId,
              ControlScore.abilityRestriction,
              rules['tagLock'],
              capKey: 'hand/$cycle',
              cap: rules['handLockCap'],
            );
          }
          _coveredCards.add(cardKey);
        }
      }
    }
  }

  void traitSuppressed(CharacterInstance c) {
    if (!modern) return;
    scores.distributeControl(
      lockSources(c, (s) => s.blockTraits),
      c.instanceId,
      ControlScore.abilityRestriction,
      rules['traitLock'],
      capKey: 'trait/${_cycle(c)}',
      cap: rules['traitLock'],
    );
  }

  void skillSuppressed(CharacterInstance c) {
    if (!modern) return;
    scores.distributeControl(
      lockSources(c, (s) => s.blockSkills),
      c.instanceId,
      ControlScore.abilityRestriction,
      rules['skillLock'],
      capKey: 'skill/${_cycle(c)}',
      cap: rules['skillLock'],
    );
  }

  void actionCancelled(
    String? source,
    CharacterInstance target, {
    int cards = 0,
  }) {
    if (!modern) return;
    final handPoints = cards * rules['cardCancelled'];
    scores.control(
      source,
      target.instanceId,
      ControlScore.actionDenial,
      handPoints > rules['actionCancelled']
          ? handPoints
          : rules['actionCancelled'],
    );
  }

  void lostActions(
    CharacterInstance target,
    int count, {
    bool skipped = false,
  }) {
    if (!modern || count <= 0) return;
    final full =
        skipped ||
        target.statuses.any((s) => s.definition.skipTurn) ||
        (target.statuses.any((s) => s.definition.blockAttack) &&
            target.statuses.any((s) => s.definition.blockCards));
    final sources = lockSources(
      target,
      (s) => skipped
          ? s.skipTurn
          : full && (s.blockAttack || s.blockCards || s.skipTurn),
    );
    scores.distributeControl(
      sources,
      target.instanceId,
      ControlScore.actionDenial,
      count * rules['actionLost'],
    );
    if (!skipped && sources.isEmpty) {
      scores.distributeControl(
        lockSources(target, (s) => s.blockAttack != s.blockCards),
        target.instanceId,
        ControlScore.actionDenial,
        rules['partialActionLock'],
        capKey: 'partial/${_cycle(target)}',
        cap: rules['partialActionLock'],
      );
    }
  }

  void forceTarget(CharacterInstance source, CharacterInstance target) {
    if (modern) _forcedSources[target.instanceId] = source.instanceId;
  }

  void countered(
    CharacterInstance source,
    CharacterInstance target, {
    bool card = false,
    String? action,
    bool wholeAction = false,
  }) {
    if (!modern) return;
    scores.control(
      source.instanceId,
      target.instanceId,
      ControlScore.abilityRestriction,
      rules[card ? 'cardCancelled' : 'interrupt'],
    );
    if (card &&
        action != null &&
        !scores.allies(source.instanceId, target.instanceId)) {
      final counts = _cancelledCardCounts.putIfAbsent(action, () => {});
      counts.update(source.instanceId, (n) => n + 1, ifAbsent: () => 1);
      if (wholeAction) {
        for (final e in counts.entries) {
          scores.moveControl(
            e.key,
            ControlScore.abilityRestriction,
            ControlScore.actionDenial,
            e.value * rules['cardCancelled'],
          );
        }
        final paid =
            counts.values.fold<double>(0, (a, b) => a + b) *
            rules['cardCancelled'];
        scores.distributeControl(
          counts,
          target.instanceId,
          ControlScore.actionDenial,
          (rules['actionCancelled'] - paid).clamp(0, double.infinity),
        );
        _cancelledCardCounts.remove(action);
      }
    }
  }

  void preventedDeath(CharacterInstance source, CharacterInstance target) {
    if (modern) {
      scores.enhance(
        source.instanceId,
        target.instanceId,
        EnhancementScore.damageProtection,
        rules['deathPrevented'],
      );
    }
  }

  void temporaryTriggered(StatusInstance status, CharacterInstance target) {
    if (modern &&
        !status.definition.isStatusEffect &&
        !status.definition.negative) {
      scores.enhance(
        status.sourceId,
        target.instanceId,
        EnhancementScore.buffCleanse,
        rules['temporaryTrigger'],
      );
    }
  }

  void reveal(
    CharacterInstance source,
    CharacterInstance target,
    int newlyKnown,
  ) {
    if (modern) {
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.abilityRestriction,
        newlyKnown * rules['revealCard'],
      );
    }
  }

  void revealCards(CharacterInstance source, CharacterInstance target) {
    var added = 0;
    for (final card in target.hand) {
      if (_revealedCards.add(card.instanceId)) added++;
    }
    reveal(source, target, added);
  }

  void markChange(
    CharacterInstance source,
    CharacterInstance target,
    int before,
    int after,
  ) {
    if (modern && after < before) {
      scores.control(
        source.instanceId,
        target.instanceId,
        ControlScore.weakeningDispel,
        rules['temporaryRemoved'],
      );
    }
  }

  void attackAttribution(
    String action,
    String target,
    DamageAttribution trace,
  ) {
    if (modern) _attackAttribution['$action/$target'] = trace;
  }

  DamageAttribution damageAttribution(
    String? action,
    String target,
    int amount,
  ) =>
      (action == null ? null : _attackAttribution['$action/$target'])?.copy() ??
      DamageAttribution(amount);
  void takenForAlly(String protector, String protected, int amount) {
    if (modern) {
      scores.enhance(
        protector,
        protected,
        EnhancementScore.damageProtection,
        amount * rules['damageTakenForAlly'],
      );
    }
  }

  void redirectAttack(
    String action,
    CharacterInstance protector,
    CharacterInstance attacker,
    List<String> previous,
  ) {
    if (!modern) return;
    final protected = previous
        .where(
          (id) =>
              id != protector.instanceId &&
              scores.allies(protector.instanceId, id),
        )
        .firstOrNull;
    if (protected != null) {
      _redirectProtection['$action/${protector.instanceId}'] = protected;
    } else if (!previous.contains(protector.instanceId)) {
      scores.control(
        protector.instanceId,
        attacker.instanceId,
        ControlScore.actionDenial,
        rules['redirect'],
      );
    }
  }

  String? protectedTarget(String? action, String target) =>
      _redirectProtection['$action/$target'];

  Map<String, Object?> snapshot(
    Map<String, Object?> combat,
    KernelState state, {
    bool includeScores = true,
  }) {
    if (!modern) return _legacy.snapshot(combat, state);
    scores.register(state);
    final sources = combat['bySource']! as Map;
    final targets = combat['byTarget']! as Map;
    return {
      ...combat,
      'performanceSchemaVersion': 2,
      'statisticsRulesVersion': version,
      'scoreRulesVersion': 2,
      'scoreAvailable': includeScores,
      'totals': <String, Object?>{
        ...(combat['totals']! as Map).cast<String, Object?>(),
        'resources': data.resourceTotals,
        'protection': data.protectionTotals,
        'lifeCosts': data.lifeCostTotals,
        if (includeScores) 'support': scores.totals(),
      },
      'bySource': <String, Object?>{
        for (final p in state.players)
          p.character.instanceId: <String, Object?>{
            ...?(sources[p.character.instanceId] as Map?)
                ?.cast<String, Object?>(),
            'resources': data.resources(p.character.instanceId),
            if (includeScores)
              'support': scores.forSource(p.character.instanceId),
          },
      },
      'byTarget': <String, Object?>{
        for (final p in state.players)
          p.character.instanceId: <String, Object?>{
            ...?(targets[p.character.instanceId] as Map?)
                ?.cast<String, Object?>(),
            'protection': data.protection(p.character.instanceId),
            'lifeCosts': data.lifeCosts(p.character.instanceId),
          },
      },
      'survival': data.survival(state),
    };
  }
}
