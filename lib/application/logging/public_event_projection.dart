import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/application/dto/api_error.dart';

/// Public event facts only. No text, hidden cards, response selections or state.
Map<String, Object?> projectPublicLogEvents(
  GameKernel game, {
  Map<int, String> timestamps = const {},
}) {
  // Resolve only cards that were actually declared publicly, including the
  // declaration immediately after an automatic reinforcement fact.
  final declarations = <String, List<Map<String, Object?>>>{};
  final ordinals = <String, int>{};
  for (final event in game.state.events) {
    if (event.type == 'cardsPlayed' && event.data['cards'] is List) {
      final cards = event.data['cards']! as List;
      for (var i = 0; i < cards.length; i++) {
        if (cards[i] is String) ordinals[cards[i] as String] = i + 1;
      }
    }
    final id = event.data['instanceId'];
    if (event.type == 'cardPlayed' &&
        id is String &&
        game.catalog.cards.containsKey(event.data['cardId'])) {
      (declarations[id] ??= []).add({
        'sequence': event.sequence,
        'cardId': event.data['cardId'],
        'cardInstanceId': id,
        'cardOwnerId': event.data['actorId'],
        if (ordinals[id] != null) 'cardOrdinal': ordinals[id],
      });
    }
  }
  Map<String, Object?> cardDetails(KernelEvent event) {
    if (!publicLogCardDetailEventTypes.contains(event.type)) return {};
    final id = event.type == 'skillUsed'
        ? event.data['logCardInstanceId']
        : event.data['instanceId'];
    final known = declarations[id] ?? [];
    final reference = event.type == 'cardReinforced'
        ? known
              .where((c) => (c['sequence']! as int) > event.sequence)
              .firstOrNull
        : known
              .where((c) => (c['sequence']! as int) <= event.sequence)
              .lastOrNull;
    if (reference == null) return {};
    return {
      for (final e in reference.entries)
        if (e.key != 'sequence') e.key: e.value,
    };
  }

  Map<String, Object?> revealedHand(KernelEvent event) {
    if (event.type != 'handRevealed' || event.data['cards'] is! List) {
      return const {};
    }
    final cards = <String>[
      for (final card in event.data['cards']! as List)
        if (card is Map && game.catalog.cards.containsKey(card['definitionId']))
          card['definitionId'] as String,
    ];
    return {'cards': cards, 'count': cards.length};
  }

  return {
    'schemaVersion': 2,
    'events': [
      for (final event in game.state.events.map(projectAttackDiceLogEvent))
        if (publicLogEventTypes.contains(event.type) &&
            (event.type != 'handRevealed' ||
                (event.data['cards'] is List &&
                    game.state.players.any(
                      (p) => p.character.instanceId == event.data['targetId'],
                    ))) &&
            (event.type != 'mpSpent' || hasPublicMpCost(event.data)) &&
            (event.type != 'markChanged' ||
                game.catalog.marks[event.data['markId']]?.visibility ==
                    MarkVisibility.public))
          {
            'sequence': event.sequence,
            if (timestamps[event.sequence] != null)
              'timestamp': timestamps[event.sequence],
            'type': event.type,
            'round': event.round,
            'turn': event.turn,
            'phase': event.phase,
            'extraTurn': event.extraTurn,
            if (const {
                  'traitTriggered',
                  'skillTriggered',
                }.contains(event.type) &&
                event.data['logStartSequence'] is int &&
                (event.data['logStartSequence']! as int) <= event.sequence)
              'displayBeforeSequence': event.data['logStartSequence'],
            'data':
                event.type == 'handCardMoved' &&
                    event.data['destination'] == 'hand'
                ? {
                    // A private hand transfer discloses participation and size,
                    // never the transferred card's identity or face.
                    for (final key in ['actorId', 'sourceId', 'targetId'])
                      if (event.data[key] is String) key: event.data[key],
                    'destination': 'hand',
                    'count': 1,
                  }
                : event.type == 'damage'
                ? damageWireData({
                    for (final e in event.data.entries)
                      if (e.key != 'statusId' ||
                          game.catalog.statuses.containsKey(e.value))
                        e.key: e.value,
                  })
                : {
                    if (const {
                          'cardsDiscarded',
                          'cardsLost',
                        }.contains(event.type) &&
                        event.data['cardDefinitionIds'] is List)
                      'cards': [
                        for (final id
                            in event.data['cardDefinitionIds']! as List)
                          if (game.catalog.cards.containsKey(id)) id,
                      ],
                    if (event.type == 'cardsPlayed' &&
                        event.data['cards'] is List)
                      'cards': [
                        for (final instance in event.data['cards']! as List)
                          if ((declarations[instance] ?? []).any(
                            (c) => (c['sequence']! as int) > event.sequence,
                          ))
                            (declarations[instance]!).firstWhere(
                              (c) => (c['sequence']! as int) > event.sequence,
                            )['cardId'],
                      ],
                    if (event.type == 'recordReplayed' &&
                        event.data['cards'] is List)
                      'cards': [
                        for (final id in event.data['cards']! as List)
                          if (game.catalog.cards.containsKey(id)) id,
                      ],
                    if (event.type == 'recordReplayed')
                      'reverse': event.data['reverse'] == true,
                    if (publicLogTargetEventTypes.contains(event.type))
                      'targetIds': [
                        for (final id
                            in (event.data['logTargetIds'] ??
                                    event.data['targets'] ??
                                    const [])
                                as List)
                          if (id is String &&
                              game.state.players.any(
                                (p) => p.character.instanceId == id,
                              ))
                            id,
                      ],
                    if (event.type == 'cardCancelled') ...{
                      if (game.state.players.any(
                        (p) =>
                            p.character.instanceId == event.data['logActorId'],
                      ))
                        'actorId': event.data['logActorId'],
                      if (game.catalog.skills.containsKey(
                        event.data['logSkillId'],
                      ))
                        'skillId': event.data['logSkillId'],
                    },
                    if (event.type == 'skillUsed') ...{
                      if (event.data['logInputNumber'] is int)
                        'inputNumber': event.data['logInputNumber'],
                      if (event.data['logDiceResult'] is int)
                        'selectedDiceResult': event.data['logDiceResult'],
                    },
                    if (event.type == 'traitTriggered' &&
                        event.data['logMode'] is String)
                      'mode': event.data['logMode'],
                    ...cardDetails(event),
                    if (event.type == 'diceChanged')
                      ...publicDiceChangeNumbers(event.data),
                    ...revealedHand(event),
                    for (final e in event.data.entries)
                      if (publicLogScalarFields.contains(e.key) &&
                          (event.type != 'actionRecorded' ||
                              !const {
                                'damage',
                                'recordId',
                                'cardId',
                                'instanceId',
                              }.contains(e.key)) &&
                          (e.value == null ||
                              e.value is String ||
                              e.value is num ||
                              e.value is bool))
                        e.key:
                            e.key == 'reason' &&
                                e.value is String &&
                                !RegExp(
                                  r'^[a-z][A-Za-z0-9]*$',
                                ).hasMatch(e.value! as String)
                            ? apiError(
                                StateError(e.value! as String),
                              )['errorCode']
                            : e.value,
                    if (game.catalog.statuses.containsKey(
                      event.data['statusId'],
                    ))
                      'statusId': event.data['statusId'],
                    if (game.catalog.traits.containsKey(event.data['traitId']))
                      'traitId': event.data['traitId'],
                    if (game.catalog.marks[event.data['markId']]?.visibility ==
                        MarkVisibility.public)
                      'markId': event.data['markId'],
                    if (event.type == 'characterDied' &&
                        event.data['instanceId'] is String)
                      'instanceId': event.data['instanceId'],
                    if (event.type == 'cardPlayed' &&
                        event.data['cardId'] is String)
                      'cardId': event.data['cardId'],
                    if (const {
                          'cardGenerated',
                          'preyPlaced',
                          'handCardMoved',
                          'skillBorrowed',
                          'skillReturned',
                        }.contains(event.type) &&
                        event.data['definitionId'] is String)
                      'definitionId': event.data['definitionId'],
                    if (const {
                          'skillUsed',
                          'skillTriggered',
                        }.contains(event.type) &&
                        event.data['skillId'] is String)
                      'skillId': event.data['skillId'],
                    if (const {
                      'cardsDiscarded',
                      'cardsPlayed',
                    }.contains(event.type))
                      'count': (event.data['cards'] as List?)?.length ?? 0,
                    if (const {
                          'responseWindowOpened',
                          'responseSubmitted',
                          'responseWindowClosed',
                        }.contains(event.type) &&
                        event.data['windowId'] is String)
                      'windowId': event.data['windowId'],
                    if (event.type == 'responseWindowClosed')
                      'hadOperations': event.data['hadOperations'] == true,
                  },
          },
    ],
  };
}
