import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';
import 'package:sns_server/domain/resolver/status_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('StatusResolver', () {
    test(
      'drops one strength stack after the applied player count',
      () async {
        final owner = _character('owner')..attack = 20;
        final ally = _character('ally');
        final context = _context(owner, ally);
        final resolver = StatusResolver(context);

        final status = await resolver.apply(
          owner,
          StatusStrength(),
          intensity: 2,
        );

        expect(owner.attack, 30);
        expect(status.stacks, 1);

        await resolver.advanceBasePlayerTurn();
        expect(owner.attack, 30);
        expect(owner.state, contains(same(status)));

        await resolver.advanceBasePlayerTurn();
        expect(owner.attack, 20);
        expect(owner.state, isEmpty);
      },
    );

    test('allows a layer to last an additional normal player turn', () async {
      final owner = _character('owner')..attack = 20;
      final ally = _character('ally');
      final context = _context(owner, ally);
      final resolver = StatusResolver(context);

      await resolver.apply(
        owner,
        StatusStrength(),
        extraPlayerTurns: 1,
      );

      await resolver.advanceBasePlayerTurn();
      await resolver.advanceBasePlayerTurn();
      expect(owner.attack, 25);

      await resolver.advanceBasePlayerTurn();
      expect(owner.attack, 20);
    });

    test('captures player count when a layer is applied', () async {
      final owner = _character('owner')..attack = 20;
      final ally = _character('ally');
      final context = _context(owner, ally);
      final resolver = StatusResolver(context);

      await resolver.apply(owner, StatusStrength());
      context.state.players.add(
        Player('late_player', 'Late', [_character('late')], 3),
      );

      await resolver.advanceBasePlayerTurn();
      await resolver.advanceBasePlayerTurn();

      expect(owner.attack, 20);
      expect(owner.state, isEmpty);
    });

    test('does not reset decay progress when adding a stack', () async {
      final owner = _character('owner')..attack = 20;
      final ally = _character('ally');
      final context = _context(owner, ally);
      final resolver = StatusResolver(context);
      final status = await resolver.apply(owner, StatusStrength());

      await resolver.advanceBasePlayerTurn();
      await resolver.apply(owner, StatusStrength(), intensity: 0);

      expect(status.stacks, 2);
      expect(status.stackFractions, 1);

      await resolver.advanceBasePlayerTurn();
      expect(status.stacks, 1);
      expect(status.stackFractions, 2);
    });

    test(
      'exposes direct intensity and stack modifications for actions',
      () async {
        final owner = _character('owner')..attack = 20;
        final ally = _character('ally');
        final context = _context(owner, ally);
        final resolver = StatusResolver(context);
        final status = await resolver.apply(owner, StatusStrength());

        await resolver.changeIntensity(owner, status.id, 2);
        await resolver.changeStacks(owner, status.id, 1);

        expect(status.intensity, 3);
        expect(status.stacks, 2);
        expect(owner.attack, 35);

        await resolver.setStacks(owner, status.id, 0);
        expect(owner.attack, 20);
        expect(owner.state, isEmpty);
      },
    );
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

GameContext _context(Character owner, Character ally) => _TestGameContext(
  GameState(
    [
      Player('owner_player', 'Owner', [owner], 1),
      Player('ally_player', 'Ally', [ally], 2),
    ],
    [],
    [],
  ),
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
