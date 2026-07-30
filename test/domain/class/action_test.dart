import 'package:sns_server/domain/class/action.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';
import 'package:test/test.dart';

void main() {
  test(
    'ActionAddAttack applies its modifier to every resolved target',
    () async {
      final source = _character('source');
      final ally = _character('ally');
      final enemy = _character('enemy');
      final sourcePlayer = Player('source_player', 'Source', [source, ally], 1);
      final enemyPlayer = Player('enemy_player', 'Enemy', [enemy], 2);
      final context = _TestGameContext(
        GameState([sourcePlayer, enemyPlayer], [], []),
      );
      final sourceAttack = source.attack;
      final allyAttack = ally.attack;
      final enemyAttack = enemy.attack;

      await ActionAddAttack(10).execute(
        ActionExecutionContext(
          context: context,
          source: CharacterTarget(source),
          target: AllAlliesTarget(),
        ),
      );

      expect(source.attack, sourceAttack + 10);
      expect(ally.attack, allyAttack + 10);
      expect(enemy.attack, enemyAttack);
    },
  );

  test(
    'CardBlade strengthens its player without accumulating actions',
    () async {
      final source = _character('source');
      final enemy = _character('enemy');
      final context = _TestGameContext(
        GameState(
          [
            Player('source_player', 'Source', [source], 1),
            Player('enemy_player', 'Enemy', [enemy], 2),
          ],
          [],
          [],
        ),
      );
      final card = CardBlade();
      final sourceAttack = source.attack;
      final enemyAttack = enemy.attack;

      await card.playCard(context, source, target: CharacterTarget(enemy));
      await card.playCard(context, source, target: CharacterTarget(enemy));

      expect(source.attack, sourceAttack + 20);
      expect(enemy.attack, enemyAttack);
      expect(card.actions, hasLength(1));
    },
  );

  test(
    'CardBlade reads reinforcement from its construction state',
    () async {
      final source = _character('source');
      final context = _TestGameContext(
        GameState(
          [
            Player('source_player', 'Source', [source], 1),
          ],
          [],
          [],
        ),
      );
      final card = CardBlade(isReinforced: true);
      final sourceAttack = source.attack;

      await card.playCard(context, source, params: {'isReinforced': false});

      expect(source.attack, sourceAttack + 20);
    },
  );
}

BaseCharacter _character(String id) => BaseCharacter(
  id,
  TemplateId.defensive.id,
  RaceId.human.id,
  const {},
  [],
  [],
);

class _TestGameContext implements GameContext {
  _TestGameContext(this.state);

  @override
  final GameState state;

  @override
  EventBus get eventBus => state.eventBus;

  @override
  Iterable<Player> getAllPlayers() => state.players;

  @override
  Character? getCharacterById(String id) => state.characterById[id];

  @override
  Player? getCurrentPlayer() => state.players.firstOrNull;

  @override
  int getCurrentRound() => state.currentRound;

  @override
  int getCurrentTurnIndex() => state.currentPlayerIndex;
}
