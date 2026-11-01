import 'dart:convert';

import 'package:sns_kernel/sns_kernel.dart';

/// Presentation only: event facts and visibility are controlled by code,
/// editable JSON controls wording and can never read arbitrary game state.
final class GameLogRenderer {
  GameLogRenderer._(this._templates, this._labels, this._names);
  final Map<String, Object?> _templates;
  final Map<String, String> _labels;
  final Map<String, String> _names;
  static final _placeholder = RegExp(r'\{([a-zA-Z][a-zA-Z0-9]*)\}');
  static const _safeFields = {
    'stat',
    'actorId',
    'sourceId',
    'targetId',
    'ownerId',
    'playerId',
    'attackerId',
    'defenderId',
    'fromId',
    'amount',
    'nominalAmount',
    'count',
    'stacks',
    'intensity',
    'stackDelta',
    'intensityDelta',
    'round',
    'turn',
    'actualTurn',
    'sides',
    'result',
    'kind',
    'shieldAbsorbed',
    'hpLost',
    'before',
    'hp',
    'overflow',
    'attackPoints',
    'defenderRoll',
    'defenderPoints',
    'nextBonus',
    'won',
    'bonus',
    'attack',
    'skipped',
    'draw',
    'winnerTeamId',
    'reason',
    'outcome',
    'transferredAmount',
    'damage',
    'restoring',
    'tag',
    'untilRound',
    'threshold',
    'destination',
  };
  static const _namedFields = {
    'actor',
    'source',
    'target',
    'owner',
    'player',
    'attacker',
    'defender',
    'from',
    'character',
    'status',
    'skill',
    'trait',
    'mark',
    'card',
    'signedAmount',
    'statusChange',
    'diceChange',
    'expiry',
  };

  factory GameLogRenderer.decode(String source, {String? contentSource}) {
    final raw = jsonDecode(source) as Map<String, dynamic>;
    if (raw['formatVersion'] != 1 || raw['locale'] != 'zh-CN') {
      throw const FormatException('Unsupported game log format or locale');
    }
    final templates = Map<String, Object?>.from(raw['events'] as Map);
    for (final entry in templates.entries) {
      final template = entry.value;
      if (template != null && template is! String) {
        throw FormatException(
          'Log template must be a string or null: ${entry.key}',
        );
      }
      if (template is String) {
        for (final match in _placeholder.allMatches(template)) {
          final key = match[1]!;
          if (!_safeFields.contains(key) &&
              !_namedFields.contains(key) &&
              !(entry.key == 'handRevealed' && key == 'cards')) {
            throw FormatException(
              'Unsafe or unsupported log placeholder: $key',
            );
          }
        }
      }
    }
    final names = <String, String>{};
    if (contentSource != null) {
      final content = jsonDecode(contentSource) as Map<String, dynamic>;
      for (final section in [
        'characters',
        'cards',
        'skills',
        'traits',
        'statuses',
        'marks',
        'races',
      ]) {
        for (final item in content[section] as List? ?? []) {
          final row = item as Map<String, dynamic>;
          if (row['name'] is String) {
            names[row['id'] as String] = row['name'] as String;
          }
        }
      }
    }
    return GameLogRenderer._(
      Map.unmodifiable(templates),
      Map<String, String>.unmodifiable(
        Map<String, String>.from(raw['labels'] as Map? ?? {}),
      ),
      Map.unmodifiable(names),
    );
  }

  /// Only public facts leave this module. Unknown events are omitted, never
  /// serialized as a fallback (they may contain hidden hands or selections).
  List<Map<String, Object?>> render(GameKernel game, {int afterSequence = 0}) {
    final characters = <String, String>{};
    final players = <String, String>{};
    for (final player in game.state.players) {
      final character = player.character;
      final name = _names[character.definition.id] ?? character.definition.id;
      final label = '$name（${player.id}）';
      characters[character.instanceId] = label;
      players[player.id] = label;
    }
    final activeWindows = {
      for (final event in game.state.events)
        if (event.type == 'responseWindowClosed' &&
            event.data['hadOperations'] == true)
          event.data['windowId'],
    };
    final result = <Map<String, Object?>>[];
    for (final event in game.state.events.map(projectAttackDiceLogEvent)) {
      if (event.sequence <= afterSequence) continue;
      if (const {
            'responseWindowOpened',
            'responseSubmitted',
            'responseWindowClosed',
          }.contains(event.type) &&
          !activeWindows.contains(event.data['windowId'])) {
        continue;
      }
      // Public event types are explicitly classified independently of templates.
      if (!_publicEvents.contains(event.type)) continue;
      final template = _templates[event.type];
      if (template is! String || template.isEmpty) continue;
      final privateHandTransfer =
          event.type == 'handCardMoved' && event.data['destination'] == 'hand';
      final d = {
        if (privateHandTransfer) ...{
          for (final key in ['actorId', 'sourceId', 'targetId'])
            if (event.data[key] is String) key: event.data[key],
          'destination': 'hand',
          'count': 1,
        } else
          ...event.data,
        if (event.type == 'diceChanged') ...publicDiceChangeNumbers(event.data),
      };
      if (event.type == 'mpSpent' && !hasPublicMpCost(d)) continue;
      if (event.type == 'handRevealed' &&
          (!characters.containsKey(d['targetId']) || d['cards'] is! List)) {
        continue;
      }
      if (event.type == 'markChanged') {
        final mark = game.catalog.marks[d['markId']];
        if (mark == null || mark.visibility != MarkVisibility.public) continue;
      }
      final fields = <String, Object?>{
        for (final e in d.entries)
          if (_safeFields.contains(e.key) &&
              (e.value == null ||
                  e.value is num ||
                  e.value is bool ||
                  e.value is String))
            e.key: e.value,
      };
      fields['signedAmount'] = d['amount'] is num
          ? _signed(d['amount']! as num)
          : '—';
      fields['statusChange'] = _statusChange(
        d,
        hasIntensity:
            game.catalog.statuses[d['statusId']]?.hasIntensity ?? true,
      );
      final before = d['before'];
      final value = d['result'];
      final diceDelta = before is num && value is num
          ? value - before
          : d['amount'];
      fields['diceChange'] = diceDelta is num
          ? '${_signed(diceDelta)}点${value is num ? '（${before is num ? '$before→' : '当前'}$value）' : ''}'
          : '设为${value ?? '—'}';
      if (event.type == 'duelResolved') {
        final rolled = d['defenderRoll'];
        final bonus = d['bonus'];
        fields['bonus'] = bonus is num ? _signed(bonus) : '—';
        fields['defenderPoints'] =
            d['defenderPoints'] ??
            (rolled is num && bonus is num ? rolled + bonus : '—');
      }
      for (final key in [
        'actor',
        'source',
        'target',
        'owner',
        'attacker',
        'defender',
        'from',
      ]) {
        fields[key] = characters[d['${key}Id']] ?? '无来源';
      }
      fields['player'] = players[d['playerId']] ?? '未知玩家';
      final anchor = players[d['anchorPlayerId']] ?? '附加座次';
      final rounds = d['durationRounds'] is int
          ? d['durationRounds']! as int
          : 1;
      fields['expiry'] = d['anchorPlayerId'] is String
          ? '至$anchor${rounds == 1 ? '下一次' : '之后第$rounds次'}自然轮次'
                '${d['decayPhase'] == 'turnEnd' ? '结束结算完成后' : '开始时'}'
          : '至第${d['untilRound'] ?? '—'}全局回合开始';
      if (d['actorId'] == null && d['playerId'] != null) {
        fields['actor'] = fields['player'];
      }
      if (event.type == 'cardsDiscarded' || event.type == 'cardsPlayed') {
        fields['count'] = (d['cards'] as List?)?.length ?? 0;
      }
      fields['card'] =
          const {
            'cardGenerated',
            'preyPlaced',
            'handCardMoved',
          }.contains(event.type)
          ? (_names[d['definitionId']] ?? '卡牌')
          : event.type == 'cardPlayed'
          ? (_names[d['cardId']] ?? '卡牌')
          : '卡牌';
      if (event.type == 'handRevealed') {
        final cards = [
          for (final card in d['cards'] as List? ?? [])
            if (card is Map &&
                game.catalog.cards.containsKey(card['definitionId']))
              '「${_names[card['definitionId']] ?? card['definitionId']}」',
        ];
        fields['cards'] = cards.isEmpty ? '无手牌' : cards.join('、');
      }
      fields['character'] = characters[d['instanceId']] ?? fields['actor'];
      for (final key in ['status', 'trait', 'mark']) {
        fields[key] = _names[d['${key}Id']] ?? '未知${_labels[key] ?? key}';
      }
      if (fields['destination'] != null) {
        fields['destination'] =
            _labels[fields['destination']] ?? fields['destination'];
      }
      // Drawn/copied hidden skills are deliberately not rendered by name.
      fields['skill'] =
          (event.type == 'skillBorrowed' || event.type == 'skillReturned')
          ? (_names[d['definitionId']] ?? '技能')
          : (event.type == 'skillUsed' || event.type == 'skillTriggered')
          ? (_names[d['skillId']] ?? '技能')
          : '技能';
      for (final key in ['kind', 'reason', 'outcome', 'stat']) {
        if (fields[key] is String) {
          fields[key] = _labels[fields[key]] ?? fields[key];
        }
      }
      if (fields['tag'] is String) {
        fields['tag'] = _labels[fields['tag']] ?? fields['tag'];
      }
      for (final key in ['won', 'skipped', 'draw', 'restoring']) {
        if (fields[key] is bool) {
          fields[key] = _labels['${fields[key]}'] ?? fields[key].toString();
        }
      }
      final displayTemplate = event.type == 'duelResolved'
          ? template.replaceAll('+{bonus}', '{bonus}')
          : template;
      var text = displayTemplate.replaceAllMapped(
        _placeholder,
        (m) => (fields[m[1]] ?? '—').toString(),
      );
      if (privateHandTransfer) {
        text = characters.containsKey(d['targetId'])
            ? '${fields['source']}给予${fields['target']}1张手牌。'
            : '${fields['source']}转移了1张手牌。';
      }
      if (event.type == 'duelResolved' && d['nextBonus'] is num) {
        text += ' 下次对决骰点修正${_signed(d['nextBonus']! as num)}点。';
      }
      result.add(
        Map<String, Object?>.unmodifiable({
          'sequence': event.sequence,
          'type': event.type,
          'round': event.round,
          'turn': event.turn,
          'text': text,
        }),
      );
    }
    return List.unmodifiable(result);
  }

  static String _signed(num value) => value >= 0 ? '+$value' : '$value';
  static String _statusChange(
    Map<String, Object?> data, {
    required bool hasIntensity,
  }) {
    final changes = [
      if (data['stackDelta'] is num && data['stackDelta'] != 0)
        '层数${_signed(data['stackDelta']! as num)}',
      if (hasIntensity &&
          data['intensityDelta'] is num &&
          data['intensityDelta'] != 0)
        '强度${_signed(data['intensityDelta']! as num)}',
    ];
    final current = [
      if (data['stacks'] is num) '${data['stacks']}层',
      if (hasIntensity && data['intensity'] is num) '强度${data['intensity']}',
    ].join('、');
    return changes.isEmpty
        ? (current.isEmpty ? '状态已更新' : '当前$current')
        : '${changes.join('、')}${current.isEmpty ? '' : '（当前$current）'}';
  }

  static const _publicEvents = {
    'attackDiceFinalized',
    'damageDiceSelected',
    'attackDiceAdjusted',
    'statusSettled',
    'statusIntensityGrowth',
    'unitSummoned',
    'statModified',
    'cardPlayed',
    'gameStarted',
    'roundStarted',
    'roundEnding',
    'turnStarted',
    'turnEnded',
    'extraTurnStarted',
    'extraTurnGranted',
    'gameFinished',
    'attackDeclared',
    'diceRolled',
    'diceChanged',
    'attackDodged',
    'attackPacketResolved',
    'damage',
    'healed',
    'shieldGained',
    'shieldBroken',
    'lifePaid',
    'actionLifePaid',
    'lifeRestored',
    'lifeSet',
    'continuationExpired',
    'continuationFailed',
    'diceReplaced',
    'shieldConverted',
    'cardGenerated',
    'generatedActionSkipped',
    'skillBorrowed',
    'skillReturned',
    'resourceReaction',
    'lifeStolen',
    'damageRefunded',
    'statusApplied',
    'statusModified',
    'statusRemoved',
    'statusRejected',
    'statusStacksCancelled',
    'statusDamageLimitReached',
    'mpSpent',
    'mpChanged',
    'mpRegenerated',
    'cardsDrawn',
    'handRevealed',
    'cardsLost',
    'attackDiceGrowth',
    'actionMpRefunded',
    'cardTagRestricted',
    'handCardsDisabled',
    'handCardEnabled',
    'skillDrawn',
    'skillUsed',
    'traitTriggered',
    'characterDied',
    'deathAnnounced',
    'saveCreated',
    'saveRestored',
    'markChanged',
    'counterattack',
    'duelResolved',
    'outgoingDuelResolved',
    'duelAttackIncreased',
    'damageRedirected',
    'damageShared',
    'shieldTransferred',
    'handCardMoved',
    'attackRedirected',
    'attackDamageCapped',
    'skillTriggered',
    'summonsRemoved',
    'damageGuardRolled',
    'defenseLifeLost',
    'defenseIncreased',
    'handsSwapped',
    'resourcesSwapped',
    'cardTaken',
    'cardBorrowed',
    'cardReturned',
    'mentalActionFailed',
    'negativeMpEntered',
    'negativeMpReleased',
    'attackEffectsRotated',
    'mpConvertedToReserve',
    'timeReserveUsed',
    'discardReserveStored',
    'skillEffectsNegated',
    'targetFeeApplied',
    'buddyFullMpReleased',
    'supportStanceEntered',
    'attackTargetRedirected',
    'supportAttackStarted',

    'lifeThresholdActivated',
    'shieldCleared',
    'preyPlaced',
    'preyActivated',
    'preyDefended',
    'preyReleased',
    'cardCancelled',
    'cardReinforced',
    'cardsPlayed',
    'cardsDiscarded',
    'choiceOpened',
    'choiceResolved',
    'abilityPrepared',
    'abilityPreparationCancelled',
    'responseWindowOpened',
    'responseSubmitted',
    'responseWindowClosed',
    'responseWindowExpired',
    'responseSkipped',
    'actionCancelled',
    'actionFailed',
    'actionResolved',
    'recordReplayed',
    'recordConsumed',
    'actionRecorded',
    'statusActivated',
    'skillsRevealed',
    'duelStarted',
    'scheduledEffectResolved',
    'triggerBudgetExceeded',
    'attackTargetForced',
  };
}
