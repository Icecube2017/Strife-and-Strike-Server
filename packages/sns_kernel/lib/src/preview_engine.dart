part of 'engine.dart';

/// A visibility-aware projection, never a save file or a copy of the live RNG.
extension KernelPreviewProjection on GameKernel {
  // Both ability frames and atomic/special response paths pass this boundary.
  void _checkPreviewEffect(EffectDefinition effect) {
    if (_previewMode &&
        (effect is ChooseObjects ||
            effect is MoveCards ||
            effect is EditMarks ||
            effect is TransferMarks ||
            effect is EditSkills ||
            effect is DisableHandCards ||
            effect is RestrictCardTag ||
            effect is DrawSkill ||
            effect is SwapHands ||
            effect is DiscardHand ||
            effect is EqualizeHand ||
            effect is RandomDiscard ||
            effect is TransferReceivedDamage ||
            effect is ModifyVariable ||
            effect is ModifyMark ||
            (effect is ChooseEffect &&
                effect.kind != ChoiceKind.character &&
                effect.kind != ChoiceKind.status))) {
      throw const PreviewBoundary('unprojectedEffectState');
    }
  }

  Map<String, Object?> previewSnapshot(String viewerId) {
    _player(viewerId);
    final limitations = <String>{
      'assumesNoResponses',
      'unprojectedMechanismState',
    };
    final rows = <Map<String, Object?>>[];
    for (final p in state.players) {
      final c = p.character;
      if (c.hand.isNotEmpty && p.id != viewerId) {
        limitations.add('unknownOtherHands');
      }
      if (c.traits.isNotEmpty) limitations.add('unprojectedTraitHistory');
      if (c.statuses.isNotEmpty) limitations.add('unprojectedStatusHistory');
      rows.add({
        'playerId': p.id,
        'teamId': p.teamId,
        'characterId': c.instanceId,
        'definitionId': c.definition.id,
        'hp': c.hp,
        'continuationEntered': c.continuationEntered,
        'mp': c.mp,
        'shield': c.shield,
        'alive': c.alive,
        'maxHand': c.maxHand,
        'actionsRemaining': c.actionsRemaining,
        'turnsStarted': c.turnsStarted,
        'attack': c.value(Stat.attack),
        'defense': c.value(Stat.defense),
        'maxHp': c.value(Stat.maxHp),
        'temporaryDefense': [
          for (final b in c.temporaryDefense)
            {'amount': b.amount, 'expires': b.expires},
        ],
        'traits': [
          for (final t in c.traits)
            {'instanceId': t.instanceId, 'definitionId': t.definition.id},
        ],
        'statuses': [
          for (final s in c.statuses)
            {
              'instanceId': s.instanceId,
              'definitionId': s.definition.id,
              'sourceId': s.sourceId,
              'anchorPlayerId': s.anchorPlayerId,
              'decayAtAnchorEnd': s.decayAtAnchorEnd,
              'stacks': s.stacks,
              'intensity': s.intensity,
              'damageLimit': s.damageLimit,
            },
        ],
        'restrictedCardTags': Map<String, int>.of(c.restrictedCardTags),
        'anchoredCardTags': {
          for (final entry in c.anchoredCardTags.entries)
            entry.key: entry.value.map((expiry) => expiry.toJson()).toList(),
        },
        'temporaryShields': [
          for (final shield in c.temporaryShields)
            {
              'remaining': shield.remaining,
              'expires': shield.expires,
              if (shield.anchor != null) 'anchor': shield.anchor!.toJson(),
            },
        ],
        'hand': p.id == viewerId
            ? [
                for (final card in c.hand)
                  {
                    'instanceId': card.instanceId,
                    'definitionId': card.definition.id,
                    'disabled': card.disabled,
                    'disabledUntilRound': card.disabledUntilRound,
                    if (card.disabledUntilAnchor != null)
                      'disabledUntilAnchor': card.disabledUntilAnchor!.toJson(),
                    'reinforced': card.reinforced,
                  },
              ]
            : null,
        'unknownHandCount': p.id == viewerId ? 0 : c.hand.length,
        'skills': [
          for (final skill in c.skills)
            if (p.id == viewerId || skill.revealed)
              {..._skillView(skill), 'uses': skill.uses},
        ],
        'unknownSkillCount': c.skills
            .where((s) => !s.revealed && p.id != viewerId)
            .length,
        if (p.id == viewerId)
          'hasUnprojectedAttack':
              c.armedAttacks.isNotEmpty || c.preparedCards.isNotEmpty,
        'nextAttackTargetId': c.nextAttackTargetId,
        'extraTurnAttackTarget': c.extraTurnAttackTarget,
      });
    }
    return {
      'schemaVersion': 1,
      'kernelCompatibility': previewCompatibility,
      'gameId': state.gameId,
      'version': state.version,
      'viewerId': viewerId,
      'round': state.round,
      'logicalTurn': state.turn,
      'actualTurn': state.actualTurn,
      'activePlayerId': state.activePlayer.id,
      'roundSeatPosition': state.roundSeatPosition,
      'reversedOrder': state.reversedOrder,
      'reverseNextRound': state.reverseNextRound,
      'phase': state.phase.name,
      'damageAmountVersion': _damageAmountVersion,
      'available':
          !state.finished &&
          state.phase == GamePhase.action &&
          state.pending == null &&
          state.choice == null &&
          state.preparation == null &&
          _flow.isEmpty,
      'pendingAvailable':
          !state.finished &&
          state.pending != null &&
          state.choice == null &&
          state.preparation == null,
      'pendingAction': _pendingPreviewSnapshot(viewerId),
      'extraTurn': state.extraTurn,
      'duel': state.duel,
      'blockStatusUntilRound': state.blockStatusUntilRound,
      'interactionRulesVersion': _interactionRulesVersion,
      'endingAnchorPlayerId': _endingAnchorPlayerId,
      'statusApplicationBlocks': Map<String, int>.of(
        state.statusApplicationBlocks,
      ),
      'rules': {
        'useLegacyDamageFormula': rules.useLegacyDamageFormula,
        'normalAttackCost': rules.normalAttackCost,
        'defaultDiceSides': rules.defaultDiceSides,
        'actionsPerTurn': rules.actionsPerTurn,
        'maxHand': rules.maxHand,
        'duelHealingMultiplier': rules.duelHealingMultiplier,
        'duelDamageMultiplier': rules.duelDamageMultiplier,
        'anomalyConflict': rules.anomalyConflict.name,
      },
      'unknown': {
        'otherHands': true,
        'deckOrder': true,
        'hiddenSkills': true,
        'marks': true,
        'variables': true,
        'history': true,
      },
      'players': rows,
      'prey': publicView()['prey'],
      'summonedUnits': [
        for (final u in state.summonedUnits)
          {
            'instanceId': u.instanceId,
            'ownerId': u.ownerId,
            'kind': u.kind,
            'alive': u.alive,
          },
      ],
      'limitations': limitations.toList(),
    };
  }

  /// Rebuild only the known projection in a new kernel. No live references,
  /// callbacks, seed, deck order or hidden skill identities are copied.
  static GameKernel restore(
    ContentCatalog catalog,
    Map<String, dynamic> snapshot,
    int Function(int) randomInt,
  ) {
    final rows = (snapshot['players'] as List).cast<Map<String, dynamic>>();
    final r = snapshot['rules'] as Map<String, dynamic>;
    final game = GameKernel(
      catalog,
      GameSetup(
        gameId: snapshot['gameId'] as String,
        players: [
          for (final p in rows)
            PlayerSetup(
              id: p['playerId'] as String,
              teamId: p['teamId'] as String,
              characterId: p['definitionId'] as String,
            ),
        ],
        deck: const [],
        skillPool: const [],
        rules: GameRules(
          useLegacyDamageFormula: r['useLegacyDamageFormula'] as bool,
          normalAttackCost: r['normalAttackCost'] as int,
          defaultDiceSides: r['defaultDiceSides'] as int,
          actionsPerTurn: r['actionsPerTurn'] as int,
          maxHand: r['maxHand'] as int,
          anomalyConflict: AnomalyConflict.values.byName(
            r['anomalyConflict'] as String,
          ),
          duelHealingMultiplier: (r['duelHealingMultiplier'] as num).toDouble(),
          duelDamageMultiplier: (r['duelDamageMultiplier'] as num? ?? 1)
              .toDouble(),
          openingCards: 0,
          openingSkills: 0,
          cardsPerTurn: 0,
          requireAllResponses: false,
        ),
      ),
      randomInt: randomInt,
    );
    for (final row in snapshot['summonedUnits'] as List? ?? []) {
      game.state.summonedUnits.add(
        SummonedUnitInstance(
          instanceId: row['instanceId'] as String,
          ownerId: row['ownerId'] as String,
          kind: row['kind'] as String? ?? 'presence',
          alive: row['alive'] as bool,
        ),
      );
    }
    game.state.players.clear();
    for (final p in rows) {
      if (p['hand'] == null) {
        game._previewHiddenHands.add(p['characterId'] as String);
      }
      final d = catalog.characters[p['definitionId']]!;
      final c = CharacterInstance(
        instanceId: p['characterId'] as String,
        definition: d,
        template: catalog.templates[d.templateId]!,
        race: catalog.races[d.raceId]!,
        maxHand: p['maxHand'] as int,
        traits: [
          for (final t in p['traits'] as List)
            TraitInstance(
              t['instanceId'] as String,
              catalog.traits[t['definitionId']]!,
            ),
        ],
        skills: [],
      );
      c.battleRound = snapshot['round'] as int;
      c.continuationEntered = p['continuationEntered'] as bool? ?? false;
      c.setLifeIgnoringContinuation(p['hp'] as int);
      c.mp = p['mp'] as int;
      c.shield = p['shield'] as int;
      c.alive = p['alive'] as bool;
      c.actionsRemaining = p['actionsRemaining'] as int;
      c.turnsStarted = p['turnsStarted'] as int? ?? 0;
      c.nextAttackTargetId = p['nextAttackTargetId'] as String?;
      c.extraTurnAttackTarget = p['extraTurnAttackTarget'] as String?;

      c.restrictedCardTags.addAll(
        (p['restrictedCardTags'] as Map? ?? {}).cast<String, int>(),
      );
      for (final entry in (p['anchoredCardTags'] as Map? ?? {}).entries) {
        c.anchoredCardTags[entry.key as String] = [
          for (final expiry in entry.value as List)
            AnchorExpiry.fromJson(Map<String, dynamic>.from(expiry as Map)),
        ];
      }
      for (final shield in p['temporaryShields'] as List? ?? []) {
        final row = shield as Map;
        c.temporaryShields.add(
          TemporaryShield(
            remaining: row['remaining'] as int,
            expires: row['expires'] as int,
            anchor: row['anchor'] == null
                ? null
                : AnchorExpiry.fromJson(
                    Map<String, dynamic>.from(row['anchor'] as Map),
                  ),
          ),
        );
      }
      for (final b in p['temporaryDefense'] as List) {
        c.temporaryDefense.add((
          amount: b['amount'] as int,
          expires: b['expires'] as int,
        ));
      }
      for (final s in p['statuses'] as List) {
        c.statuses.add(
          StatusInstance(
            instanceId: s['instanceId'] as String,
            definition: catalog.statuses[s['definitionId']]!,
            ownerId: c.instanceId,
            sourceId: s['sourceId'] as String?,
            anchorPlayerId: s['anchorPlayerId'] as String,
            decayAtAnchorEnd: s['decayAtAnchorEnd'] as bool? ?? false,
            stacks: s['stacks'] as int,
            intensity: s['intensity'] as int,
            damageLimit: s['damageLimit'] as int?,
          ),
        );
      }
      for (final skill in p['skills'] as List? ?? []) {
        final definition = catalog.skills[skill['definitionId']];
        if (definition == null) throw StateError('技能执行定义不可用');
        c.skills.add(
          SkillInstance(skill['instanceId'] as String, definition)
            ..revealed = skill['revealed'] as bool? ?? false
            ..leasedOut = skill['leasedOut'] as bool? ?? false
            ..borrowed = skill['borrowed'] as bool? ?? false
            ..cooldown = skill['cooldown'] as int
            ..cooldownAnchor = skill['cooldownAnchor'] is Map
                ? AnchorExpiry.fromJson(
                    Map<String, dynamic>.from(skill['cooldownAnchor'] as Map),
                  )
                : null
            ..remainingUses = skill['remainingUses'] as int?
            ..uses = skill['uses'] as int,
        );
      }
      for (final card in p['hand'] as List? ?? []) {
        c.hand.add(
          CardInstance(
              card['instanceId'] as String,
              catalog.cards[card['definitionId']]!,
            )
            ..disabledUntilRound = card['disabledUntilRound'] as int?
            ..disabledUntilAnchor = card['disabledUntilAnchor'] == null
                ? null
                : AnchorExpiry.fromJson(
                    Map<String, dynamic>.from(
                      card['disabledUntilAnchor'] as Map,
                    ),
                  )
            ..disabled = card['disabled'] as bool
            ..reinforced = card['reinforced'] as bool,
        );
      }
      // Match only publicly visible totals, without publishing the composition
      // of permanent bonuses or any private marks.
      for (final stat in [Stat.attack, Stat.defense, Stat.maxHp]) {
        final desired = p[stat.name == 'maxHp' ? 'maxHp' : stat.name] as int;
        if (c.value(stat) == desired) continue;
        var low = -1000000000;
        var high = 1000000000;
        while (low < high) {
          final mid = low + ((high - low) ~/ 2);
          c.permanentModifiers[stat] = mid;
          if (c.value(stat) < desired) {
            low = mid + 1;
          } else {
            high = mid;
          }
        }
        c.permanentModifiers[stat] = low;
        if (c.value(stat) != desired) {
          throw StateError('公开属性不能精确恢复：${stat.name}');
        }
      }
      game.state.players.add(
        PlayerInstance(p['playerId'] as String, p['teamId'] as String, c),
      );
    }
    for (final row in snapshot['prey'] as List? ?? []) {
      final owner = game._character(row['sourceId'] as String);
      final rule = owner.traits
          .map((t) => t.definition.mechanisms.get<PreyRule>())
          .whereType<PreyRule>()
          .first;
      final card = CardInstance(
        row['instanceId'] as String,
        catalog.cards[row['definitionId']]!,
      );
      owner.hand.add(card);
      final held = game.state.cardCustody.hold(
        id: 'preview_${card.instanceId}',
        actionId: 'preview_prey',
        owner: owner,
        card: card,
        revealed: true,
      );
      game._preyModule.restoreCard(held, row['holderId'] as String, rule);
    }
    game.state.phase = GamePhase.action;
    game.state.round = snapshot['round'] as int;
    game.state.turn = snapshot['logicalTurn'] as int;
    game.state.actualTurn = snapshot['actualTurn'] as int;
    game.state.version = snapshot['version'] as int;
    game.state.extraTurn = snapshot['extraTurn'] as bool;
    game.state.duel = snapshot['duel'] as bool;
    game.state.blockStatusUntilRound = snapshot['blockStatusUntilRound'] as int;
    game.state.statusApplicationBlocks.addAll(
      Map<String, int>.from(snapshot['statusApplicationBlocks'] as Map? ?? {}),
    );
    game._interactionRulesVersion =
        snapshot['interactionRulesVersion'] as int? ?? 4;
    game._endingAnchorPlayerId = snapshot['endingAnchorPlayerId'] as String?;
    game.state.activeIndex = game.state.players.indexWhere(
      (p) => p.id == snapshot['activePlayerId'],
    );
    game.state.reversedOrder = snapshot['reversedOrder'] as bool? ?? false;
    game.state.reverseNextRound =
        snapshot['reverseNextRound'] as bool? ?? false;
    game.state.roundSeatPosition =
        snapshot['roundSeatPosition'] as int? ??
        (game.state.reversedOrder
            ? game.state.players.length - 1 - game.state.activeIndex
            : game.state.activeIndex);
    game.state.nextInstance = 1000000;
    game._damageAmountVersion = snapshot['damageAmountVersion'] as int;
    game._previewMode = true;
    return game;
  }
}
