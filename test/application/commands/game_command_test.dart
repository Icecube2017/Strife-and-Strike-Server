import 'package:test/test.dart';

import 'package:sns_server/application/commands/game_command.dart';
import 'package:sns_server/domain/core/enum.dart';

void main() {
  group('parseGameCommand', () {
    test('parses playCard into PlayCardCommand', () {
      final command = parseGameCommand(
        commandId: 'cmd_1',
        playerId: 'player_alpha',
        clientVersion: 3,
        actionType: ActionType.playCard,
        payload: {
          'targetId': 'char_beta',
          'cardSelections': [
            {'cardId': 'apollo_arrow', 'handIndex': 1},
            {'cardId': 'wood_sword', 'handIndex': 0},
          ],
        },
      );

      expect(command, isA<PlayCardCommand>());
      final playCardCommand = command as PlayCardCommand;
      expect(playCardCommand.targetCharacterId, 'char_beta');
      expect(
        playCardCommand.cardSelections
            .map((selection) => selection.toJson())
            .toList(growable: false),
        [
          {'cardId': 'apollo_arrow', 'handIndex': 1},
          {'cardId': 'wood_sword', 'handIndex': 0},
        ],
      );
    });

    test('rejects legacy attackCard API action', () {
      expect(
        () => parseGameCommand(
          commandId: 'cmd_2',
          playerId: 'player_alpha',
          clientVersion: 3,
          actionType: ActionType.attackCard,
          payload: {
            'cardSelections': [
              {'cardId': 'apollo_arrow'},
            ],
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('API clients must use playCard'),
          ),
        ),
      );
    });

    test('rejects legacy limitedCard API action', () {
      expect(
        () => parseGameCommand(
          commandId: 'cmd_3',
          playerId: 'player_alpha',
          clientVersion: 3,
          actionType: ActionType.limitedCard,
          payload: {
            'cardSelections': [
              {'cardId': 'limited_blast'},
            ],
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('API clients must use playCard'),
          ),
        ),
      );
    });
  });
}
