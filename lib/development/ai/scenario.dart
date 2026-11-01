import 'dart:convert';

import 'package:sns_kernel/sns_kernel.dart';

/// An offline fixture, never a room or player-controlled state patch.
final class AiScenario {
  AiScenario._(
    this.definition,
    this.content,
    this.catalog,
    this.setup,
    this.initial,
  );

  factory AiScenario.parse(
    Map<String, dynamic> definition,
    Map<String, dynamic> content, {
    ContentCatalog? catalog,
  }) {
    if (definition['scenarioVersion'] != 1 ||
        definition['id'] is! String ||
        definition['players'] is! List) {
      throw const FormatException('Invalid AI scenario version, id or players');
    }
    final parsed =
        catalog ?? ExecutableContent.decode(jsonEncode(content)).catalog;
    if (definition['trainingMode'] == 'fullMatch' &&
        (definition['deck'] != 'default' ||
            definition['skillPool'] != 'default' ||
            definition.containsKey('prefix') ||
            (definition['players'] as List).any(
              (p) => (p as Map).containsKey('initial'),
            ) ||
            (definition['rules'] as Map? ?? {}).isNotEmpty)) {
      throw const FormatException(
        'Full matches require the production deck, skill pool and opening rules',
      );
    }
    String resolve(String group, Object? ref) {
      if (ref is! String) {
        throw FormatException('Expected a $group definition ID');
      }
      final matches = (content[group] as List)
          .cast<Map<String, dynamic>>()
          .where((row) => row['id'] == ref || row['wikiId'] == ref)
          .toList();
      if (matches.length != 1) {
        throw FormatException('Unknown or ambiguous $group ID: $ref');
      }
      return matches.single['id']! as String;
    }

    final players = <PlayerSetup>[];
    final initial = <String, Map<String, Object?>>{};
    for (final raw in definition['players'] as List) {
      final p = Map<String, dynamic>.from(raw as Map);
      if (p['id'] is! String || p['teamId'] is! String) {
        throw const FormatException('Player id and teamId are required');
      }
      players.add(
        PlayerSetup(
          id: p['id'] as String,
          teamId: p['teamId'] as String,
          characterId: resolve('characters', p['characterId']),
        ),
      );
      if (p['initial'] is Map) {
        final row = Map<String, Object?>.from(p['initial'] as Map);
        if (row['hand'] is List) {
          row['hand'] = [
            for (final ref in row['hand']! as List) resolve('cards', ref),
          ];
        }
        for (final group in ['skills', 'statuses', 'marks']) {
          if (row[group] is List) {
            row[group] = [
              for (final entry in row[group]! as List)
                {
                  ...Map<String, Object?>.from(entry as Map),
                  'definitionId': resolve(group, entry['definitionId']),
                },
            ];
          }
        }
        initial[p['id'] as String] = row;
      }
    }
    if (players.length < 2 ||
        players.length > 8 ||
        players.map((p) => p.teamId).toSet().length < 2) {
      throw const FormatException(
        'Scenarios need 2-8 players and at least two teams',
      );
    }
    final deck = definition['deck'];
    final defaultDeck = Map<String, dynamic>.from(
      ((content['deck'] as List).first as Map)['content'] as Map,
    );
    final deckIds = deck is List
        ? [for (final ref in deck) resolve('cards', ref)]
        : [
            for (final e in defaultDeck.entries)
              for (var i = 0; i < (e.value as int); i++)
                resolve('cards', e.key),
          ];
    if (deck != null && deck != 'default' && deck is! List) {
      throw const FormatException('deck must be default or a list of card IDs');
    }
    final defaults = KernelRecoveryCodec.setup(
      GameSetup(
        gameId: 'fixture',
        players: players,
        deck: deckIds,
        skillPool: const [],
      ),
    );
    final rules = Map<String, dynamic>.from(defaults['rules']! as Map);
    final overrides = Map<String, dynamic>.from(
      definition['rules'] as Map? ?? {},
    );
    if (overrides.keys.any((key) => !rules.containsKey(key))) {
      throw const FormatException('Unsupported scenario rule');
    }
    rules.addAll(overrides);
    final setup = KernelRecoveryCodec.readSetup(
      jsonDecode(
            jsonEncode({
              ...defaults,
              'gameId': definition['id'],
              'rules': rules,
              'skillPool': [
                for (final ref
                    in definition['skillPool'] == 'default'
                        ? content['skillPool'] as List
                        : definition['skillPool'] as List? ?? [])
                  resolve('skills', ref),
              ],
            }),
          )
          as Map<String, dynamic>,
    );
    return AiScenario._(
      jsonDecode(jsonEncode(definition)) as Map<String, dynamic>,
      content,
      parsed,
      setup,
      ScenarioSetup(initial),
    );
  }

  final Map<String, dynamic> definition;
  final Map<String, dynamic> content;
  final ContentCatalog catalog;
  final GameSetup setup;
  final ScenarioSetup initial;
  String get id => setup.gameId;

  GameKernel create({int seed = 1}) {
    final game = GameKernel(
      catalog,
      GameSetup(
        gameId: setup.gameId,
        players: setup.players,
        deck: setup.deck,
        skillPool: setup.skillPool,
        rules: setup.rules,
        seed: seed,
      ),
      scenario: initial,
    )..start();
    for (final raw in definition['prefix'] as List? ?? []) {
      _prefix(game, Map<String, dynamic>.from(raw as Map));
    }
    return game;
  }

  AiScenario reverseSeats() => AiScenario.parse(
    {
      ...definition,
      'players': (definition['players'] as List).reversed.toList(),
    },
    content,
    catalog: catalog,
  );

  void _prefix(GameKernel game, Map<String, dynamic> row) {
    if (row['type'] == 'passAll') {
      for (var n = 0; game.state.pending != null; n++) {
        if (n >= 128) throw StateError('Prefix response limit exceeded');
        final p = game.state.pending!;
        game.submit(PassCommand(p.waitingPlayerIds.first, p.windowId));
      }
      return;
    }
    final player = game.state.players.singleWhere(
      (p) => p.id == row['playerId'],
    );
    String resolve(String group, Object? ref) =>
        (content[group] as List).cast<Map<String, dynamic>>().singleWhere(
              (v) => v['id'] == ref || v['wikiId'] == ref,
            )['id']!
            as String;
    List<String> targets() => [
      for (final id in row['targetPlayers'] as List? ?? [])
        game.state.players.singleWhere((p) => p.id == id).character.instanceId,
    ];
    List<String> hand() {
      final available = player.character.hand.toList();
      return [
        for (final ref in row['cards'] as List? ?? [])
          (() {
            final id = resolve('cards', ref);
            final card = available.firstWhere((c) => c.definition.id == id);
            available.remove(card);
            return card.instanceId;
          })(),
      ];
    }

    final KernelCommand command;
    switch (row['type']) {
      case 'attack':
        command = AttackCommand(player.id, targets().single);
      case 'playCards':
        command = PlayCardsCommand(
          player.id,
          hand(),
          targetId: targets().firstOrNull,
        );
      case 'useSkill':
        command = UseSkillCommand(
          player.id,
          player.character.skills
              .firstWhere(
                (s) => s.definition.id == resolve('skills', row['skillId']),
              )
              .instanceId,
          targetIds: targets(),
          number: row['number'] as int?,
          pendingActionId: row['response'] == true
              ? game.state.pending!.windowId
              : null,
          diceResult: row['diceResult'] as int?,
        );
      case 'activateTrait':
        command = ActivateTraitCommand(
          player.id,
          player.character.traits
              .firstWhere(
                (t) => t.definition.id == resolve('traits', row['traitId']),
              )
              .instanceId,
          cardInstanceIds: hand(),
          mode: row['mode'] as String? ?? 'self',
        );
      case 'choose':
        final choice = game.state.choice!;
        final option = choice.options[row['optionIndex']! as int];
        command = ChooseCommand(
          player.id,
          choice.id,
          option['optionId']! as String,
        );
      case 'confirmAbility':
        command = ConfirmAbilityCommand(player.id, game.state.preparation!.id);
      case 'cancelAbility':
        command = CancelAbilityCommand(player.id, game.state.preparation!.id);
      case 'endTurn':
        command = EndTurnCommand(player.id);
      case 'pass':
        command = PassCommand(player.id, game.state.pending!.windowId);
      case 'discard':
        command = DiscardCommand(player.id, hand());
      default:
        throw FormatException('Unsupported prefix command: ${row['type']}');
    }
    game.submit(command, expectedVersion: game.state.version);
  }
}
