import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';
import 'package:sns_server/domain/resolver/target_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('TargetResolver', () {
    late BaseCharacter alpha;
    late BaseCharacter bravo;
    late BaseCharacter charlie;
    late Player alphaPlayer;
    late Player bravoPlayer;
    late Player charliePlayer;
    late TargetResolver resolver;

    setUp(() {
      alpha = _character('alpha');
      bravo = _character('bravo');
      charlie = _character('charlie');
      alphaPlayer = Player('player_alpha', 'Alpha', [alpha], 1);
      bravoPlayer = Player('player_bravo', 'Bravo', [bravo], 2);
      charliePlayer = Player('player_charlie', 'Charlie', [charlie], 2);
      resolver = TargetResolver(
        _TestGameContext(
          GameState([alphaPlayer, bravoPlayer, charliePlayer], [], []),
        ),
      );
    });

    test('expands a player target to that player characters', () {
      final targets = resolver.resolve(PlayerTarget(bravoPlayer));

      expect(targets.single.character, same(bravo));
    });

    test('expands all characters in player order', () {
      final targets = resolver.resolve(AllCharactersTarget());

      expect(targets.map((target) => target.character), [
        alpha,
        bravo,
        charlie,
      ]);
    });

    test('expands enemies using the source character team', () {
      final targets = resolver.resolve(
        AllEnemiesTarget(),
        source: CharacterTarget(alpha),
      );

      expect(targets.map((target) => target.character), [bravo, charlie]);
    });

    test('expands allies including the source character', () {
      final targets = resolver.resolve(
        AllAlliesTarget(),
        source: CharacterTarget(alpha),
      );

      expect(targets.map((target) => target.character), [alpha]);
    });

    test('expands allies while excluding the source character', () {
      final ally = _character('ally');
      alphaPlayer.characters.add(ally);

      final targets = resolver.resolve(
        AllAlliesExceptSelfTarget(),
        source: CharacterTarget(alpha),
      );

      expect(targets.map((target) => target.character), [ally]);
    });

    test('requires a source to resolve enemies', () {
      expect(
        () => resolver.resolve(AllEnemiesTarget()),
        throwsStateError,
      );
    });

    test('requires a character source to exclude self from allies', () {
      expect(
        () => resolver.resolve(
          AllAlliesExceptSelfTarget(),
          source: PlayerTarget(alphaPlayer),
        ),
        throwsStateError,
      );
    });
  });
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
