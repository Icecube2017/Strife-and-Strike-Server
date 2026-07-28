import 'package:test/test.dart';

import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';

void main() {
  group('TraitRadiantBlast', () {
    test('grants +10 attack on a 4-6 roll during the owner turn start and removes it on turn end', () async {
      final alpha = _FixedDiceTraitCharacter(
        'char_alpha',
        4,
        [TraitRadiantBlast()],
      );
      final beta = _FixedDiceTraitCharacter(
        'char_beta',
        1,
        [],
      );
      final state = _buildGameState(alpha, beta);
      final engine = GameEngine(state);

      await engine.initEngine();
      alpha.attack = 20;

      await engine.startGame();
      expect(state.flowState, FlowState.responseWindow);

      await engine.passPriority('player_beta');

      expect(alpha.attack, 30);

      await engine.endTurn();

      expect(alpha.attack, 20);
    });

    test('does not grant attack when the roll is 1-3', () async {
      final alpha = _FixedDiceTraitCharacter(
        'char_alpha',
        3,
        [TraitRadiantBlast()],
      );
      final beta = _FixedDiceTraitCharacter(
        'char_beta',
        1,
        [],
      );
      final state = _buildGameState(alpha, beta);
      final engine = GameEngine(state);

      await engine.initEngine();
      alpha.attack = 20;

      await engine.startGame();
      expect(state.flowState, FlowState.responseWindow);

      await engine.passPriority('player_beta');

      expect(alpha.attack, 20);
    });
  });
}

class _FixedDiceTraitCharacter extends BaseCharacter {
  _FixedDiceTraitCharacter(
    String id,
    this.fixedRoll,
    List<Trait> traits,
  ) : super(
          id,
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          traits,
          [],
        );

  final int fixedRoll;

  @override
  Future<int> rollDice(GameContext context, int sides) async => fixedRoll;
}

GameState _buildGameState(Character alpha, Character beta) {
  final state = GameState([
    Player('player_alpha', 'Alpha', [alpha], 0),
    Player('player_beta', 'Beta', [beta], 1),
  ], <PropCard>[], <PropCard>[]);
  state.characterById[alpha.id] = alpha;
  state.characterById[beta.id] = beta;
  state.playerById['player_alpha'] = state.players[0];
  state.playerById['player_beta'] = state.players[1];
  return state;
}
