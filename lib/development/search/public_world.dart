import 'dart:convert';
import 'dart:math';

import 'package:sns_kernel/sns_kernel.dart';

Map<String, dynamic> searchMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<Map<String, dynamic>> searchRows(Object? value) => value is List
    ? [
        for (final row in value)
          if (row is Map) searchMap(row),
      ]
    : [];
int searchInt(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

/// An explicit public-state approximation, NOT a clone or checkpoint restore.
/// Only the supplied player's observation is accepted. Hidden hands, skills and
/// future draws are sampled independently; unknown history is not recovered.
final class PublicSearchWorld {
  PublicSearchWorld(
    this.catalog,
    this.content,
    Map<String, dynamic> observation,
  ) : public = searchMap(observation['public']),
      private = searchMap(observation['private']) {
    viewer = private['playerId'] as String;
    players = searchRows(public['players']);
    if (players.length < 2 ||
        !players.any((p) => p['playerId'] == viewer) ||
        public['phase'] != 'action' ||
        public['activePlayerId'] != viewer ||
        public['pending'] != null ||
        public['choice'] != null ||
        private['choice'] != null ||
        public['preparation'] != null ||
        private['preparation'] != null) {
      throw StateError('searchRequiresStableOwnAction');
    }
    if (searchRows(private['actionRecords']).isNotEmpty ||
        searchRows(public['globalEffects']).isNotEmpty) {
      throw StateError('unprojectedHistoryMechanism');
    }
  }

  final ContentCatalog catalog;
  final Map<String, dynamic> content;
  final Map<String, dynamic> public;
  final Map<String, dynamic> private;
  late final String viewer;
  late final List<Map<String, dynamic>> players;

  /// Conservative training gate. Passing it is not proof of an exact clone;
  /// remaining public-state approximation limits are still recorded.
  List<String> get trainingConcerns {
    final found = <String>{};
    if (public['extraTurn'] == true || searchInt(public['round']) > 2) {
      found.add('unprojectedTurnHistory');
    }
    if (searchInt(public['turn'], 1) != searchInt(public['logicalTurn'], 1)) {
      found.add('extraTurnHistory');
    }
    for (final row in searchRows(private['triggerState'])) {
      if (searchMap(row['uses']).values.any((v) => searchInt(v) != 0) ||
          searchMap(row['counters']).values.any((v) => searchInt(v) != 0)) {
        found.add('nonzeroPrivateTriggerHistory');
      }
    }
    for (final p in players) {
      if (p['alive'] != true) found.add('pastEliminationHistory');
      if (p['alive'] == true && searchInt(p['hp']) <= 0) {
        found.add('battleContinuationHistory');
      }
      for (final s in searchRows(p['statuses'])) {
        final d = catalog.statuses[s['definitionId']];
        if (d == null) {
          found.add('unknownStatus');
          continue;
        }
        if ((d.decay == StatusDecay.anchoredRound ||
                d.decay == StatusDecay.anchorMpRecovery) &&
            s['anchorPlayerId'] == null) {
          found.add('unknownStatusAnchor');
        }
        if (d.triggers.isNotEmpty ||
            d.onHit.isNotEmpty ||
            d.turnStart.isNotEmpty ||
            d.turnEnd.isNotEmpty) {
          found.add('sourceDependentStatusHistory');
        }
      }
    }
    return found.toList()..sort();
  }

  List<String> get limitations => [
    'publicStateApproximationNotHistoricalClone',
    'unobservedTriggerAndMechanismHistoryUsesDefaults',
    'unknownStatusSourcesAndExpiryUseOwnerAnchors',
    'unknownHandsSkillsAndDrawsUseStaticContentPrior',
    'pastCardConservationAndOpponentBeliefsNotReconstructed',
    'effectiveStatsPreservedButModifierProvenanceUnknown',
    'defaultMatchRulesOnly',
  ];

  GameKernel sample(Random random) {
    final game = GameKernel(
      catalog,
      GameSetup(
        gameId: public['gameId'] as String,
        players: [
          for (final p in players)
            PlayerSetup(
              id: p['playerId'] as String,
              teamId: p['teamId'] as String,
              characterId: p['definitionId'] as String,
            ),
        ],
        deck: const [],
        skillPool: const [],
        rules: const GameRules(openingCards: 0, openingSkills: 0),
      ),
      randomInt: random.nextInt,
    );
    final round = searchInt(public['round'], 1);
    final activeSeat = players.indexWhere((p) => p['playerId'] == viewer);
    final reversed = public['turnDirection'] == -1;
    int position(int absolute) =>
        reversed ? players.length - 1 - absolute : absolute;
    final currentPosition = position(activeSeat);
    // Use IDs already visible to the viewer, never an actual save's ID counter.
    var nextId = game.state.nextInstance;
    void seen(Object? raw) {
      if (raw is String) {
        final n = int.tryParse(raw.split('/').last);
        if (n != null && n > nextId) nextId = n;
      }
    }

    for (final p in players) {
      seen(p['characterId']);
      for (final key in ['statuses', 'skills', 'marks']) {
        for (final row in searchRows(p[key])) {
          seen(row['instanceId']);
        }
      }
    }
    for (final key in ['cards', 'skills', 'marks']) {
      for (final row in searchRows(private[key])) {
        seen(row['instanceId']);
      }
    }
    for (final row in searchRows(private['traitActions'])) {
      seen(row['instanceId']);
    }
    game.state.nextInstance = nextId;

    final cardPool = <String>[];
    final deck = searchMap(searchRows(content['deck']).firstOrNull?['content']);
    for (final entry in deck.entries) {
      if (catalog.cards.containsKey(entry.key)) {
        cardPool.addAll(List.filled(searchInt(entry.value), entry.key));
      }
    }
    for (final card in searchRows(private['cards'])) {
      if (!cardPool.remove(card['definitionId'])) {
        // Generated cards need not have come from the original deck.
        if (!catalog.cards.containsKey(card['definitionId'])) {
          throw StateError('unknownVisibleCard');
        }
      }
    }
    cardPool.shuffle(random);
    String draw() {
      if (cardPool.isEmpty) throw StateError('cardPriorExhausted');
      return cardPool.removeLast();
    }

    final skillPool = (content['skillPool'] as List? ?? [])
        .whereType<String>()
        .where(catalog.skills.containsKey)
        .toSet()
        .toList();
    final knownSkills = {
      for (final p in players)
        for (final s in searchRows(
          p['playerId'] == viewer ? private['skills'] : p['skills'],
        ))
          s['definitionId'],
    };
    skillPool
      ..removeWhere(knownSkills.contains)
      ..shuffle(random);

    final built = <PlayerInstance>[];
    for (final p in players) {
      final own = p['playerId'] == viewer;
      final seatPosition = position(players.indexOf(p));
      final starts = round - 1 + (seatPosition <= currentPosition ? 1 : 0);
      final closes = round - 1 + (seatPosition < currentPosition ? 1 : 0);
      final ownTraits = {
        if (own)
          for (final row in searchRows(private['traitActions']))
            row['definitionId']: row,
      };
      final definition = catalog.characters[p['definitionId']]!;
      final c =
          CharacterInstance(
              instanceId: p['characterId'] as String,
              definition: definition,
              template: catalog.templates[definition.templateId]!,
              race: catalog.races[definition.raceId]!,
              maxHand: game.rules.maxHand,
              traits: [
                for (final id in definition.traits)
                  TraitInstance(
                      ownTraits[id]?['instanceId'] as String? ??
                          game.state.id('trait'),
                      catalog.traits[id]!,
                    )
                    ..activeRound = round
                    ..activeUses = searchInt(ownTraits[id]?['uses']),
              ],
              skills: [],
            )
            ..battleRound = round
            ..turnsStarted = starts
            ..turnsClosed = closes
            ..normalTurnsEnded = closes
            ..actionsRemaining = searchInt(p['actionsRemaining'])
            ..alive = p['alive'] == true;
      for (final s in searchRows(p['statuses'])) {
        final d = catalog.statuses[s['definitionId']];
        if (d == null) throw StateError('unknownVisibleStatus');
        c.statuses.add(
          StatusInstance(
            instanceId: s['instanceId'] as String,
            definition: d,
            ownerId: c.instanceId,
            sourceId: s['sourceId'] as String?,
            anchorPlayerId:
                s['anchorPlayerId'] as String? ?? p['playerId'] as String,
            stacks: searchInt(s['stacks'], 1),
            intensity: searchInt(s['intensity'], 1),
            damageLimit: s['damageLimit'] as int?,
            decayAtAnchorEnd: s['decayPhase'] == 'turnEnd',
          )..damageTaken = searchInt(s['damageTaken']),
        );
      }
      for (final bonus in searchRows(p['temporaryDefense'])) {
        c.temporaryDefense.add((
          amount: searchInt(bonus['amount']),
          expires: searchInt(bonus['expiresAtOwnTurn'], round + 1),
        ));
      }
      for (final s in searchRows(own ? private['skills'] : p['skills'])) {
        final d = catalog.skills[s['definitionId']];
        if (d == null) throw StateError('unknownVisibleSkill');
        final skill = SkillInstance(s['instanceId'] as String, d)
          ..cooldown = searchInt(s['cooldown'])
          ..remainingUses = s['remainingUses'] as int?
          ..revealed = !own || s['revealed'] == true
          ..leasedOut = s['leasedOut'] == true
          ..borrowed = s['borrowed'] == true;
        if (skill.cooldown > 0) {
          final anchor = searchMap(s['cooldownAnchor']);
          skill.cooldownAnchor = AnchorExpiry(
            playerId:
                anchor['anchorPlayerId'] as String? ?? p['playerId'] as String,
            turn: searchInt(anchor['turn'], round + skill.cooldown),
            atEnd: anchor['phase'] == 'turnEnd',
          );
        }
        c.skills.add(skill);
        if (skill.revealed) game.state.publicSkillHistory[d.id] = d;
      }
      if (!own) {
        for (var i = 0; i < searchInt(p['hiddenSkillCount']); i++) {
          if (skillPool.isEmpty) throw StateError('skillPriorExhausted');
          final d = catalog.skills[skillPool.removeLast()]!;
          c.skills.add(SkillInstance(game.state.id('skill'), d));
        }
      }
      for (final m in searchRows(own ? private['marks'] : p['marks'])) {
        final d = catalog.marks[m['definitionId']];
        if (d == null) throw StateError('unknownVisibleMark');
        c.marks.add(
          MarkInstance(
            instanceId: m['instanceId'] as String,
            definition: d,
            ownerId: c.instanceId,
            sourceId: m['sourceId'] as String?,
            count: searchInt(m['count']),
          ),
        );
      }
      // Invert the public value rather than adding its difference: attack
      // factors can multiply the underlying permanent modifier, and marks also
      // contribute. Reject an unrepresentable value instead of silently changing
      // the visible root statistics.
      for (final stat in [Stat.maxHp, Stat.attack, Stat.defense, Stat.maxMp]) {
        if (p[stat.name] is! num) continue;
        final target = searchInt(p[stat.name]);
        if (c.value(stat) == target) continue;
        var low = -1000000000;
        var high = 1000000000;
        while (low < high) {
          final mid = low + ((high - low) ~/ 2);
          c.permanentModifiers[stat] = mid;
          if (c.value(stat) < target) {
            low = mid + 1;
          } else {
            high = mid;
          }
        }
        c.permanentModifiers[stat] = low;
        if (c.value(stat) != target) {
          throw StateError('unrepresentableVisibleStat:${stat.name}');
        }
      }
      c
        ..setLifeIgnoringContinuation(searchInt(p['hp']))
        ..mp = searchInt(p['mp'])
        ..shield = searchInt(p['shield']);
      if (own) {
        for (final card in searchRows(private['cards'])) {
          c.hand.add(
            CardInstance(
                card['instanceId'] as String,
                catalog.cards[card['definitionId']]!,
              )
              ..reinforced = card['reinforced'] == true
              ..disabled = card['disabled'] == true
              ..disabledUntilRound = card['disabledUntilRound'] as int?,
          );
          final expiry = searchMap(card['disabledUntilAnchor']);
          if (expiry.isNotEmpty) {
            c.hand.last.disabledUntilAnchor = AnchorExpiry.fromJson(expiry);
          }
        }
      } else {
        for (var i = 0; i < searchInt(p['handCount']); i++) {
          c.hand.add(
            CardInstance(game.state.id('card'), catalog.cards[draw()]!),
          );
        }
      }
      built.add(
        PlayerInstance(p['playerId'] as String, p['teamId'] as String, c),
      );
    }
    game.state.players
      ..clear()
      ..addAll(built);
    for (var i = 0; i < searchInt(public['drawPileCount']); i++) {
      game.state.drawPile.add(
        CardInstance(game.state.id('card'), catalog.cards[draw()]!),
      );
    }
    // Unseen skill draws also use the declared common pool, not real server data.
    for (final id in skillPool) {
      game.state.skillPool.add(
        SkillInstance(game.state.id('skill'), catalog.skills[id]!),
      );
    }
    game.state.phase = GamePhase.action;
    game.state.round = round;
    game.state.turn = searchInt(
      public['logicalTurn'],
      searchInt(public['turn'], 1) - 1,
    );
    game.state.actualTurn = searchInt(public['turn'], 1) - 1;
    game.state.activeIndex = built.indexWhere((p) => p.id == viewer);
    game.state.version = searchInt(public['version']);
    game.state.extraTurn = public['extraTurn'] == true;
    game.state.duel = public['duel'] == true;
    game.state.reversedOrder = public['turnDirection'] == -1;
    game.state.reverseNextRound =
        public['turnDirection'] != public['nextRoundDirection'];
    game.state.roundSeatPosition = currentPosition;
    for (final row in searchRows(private['variables'])) {
      if (row['id'] is String &&
          row['holderId'] is String &&
          row['value'] != null) {
        final value = jsonDecode(jsonEncode(row['value'])) as Object;
        game.state.variables[(row['id'] as String, row['holderId'] as String)] =
            VariableState(value, round);
      }
    }
    return game;
  }
}
