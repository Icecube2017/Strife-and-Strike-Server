import 'package:sns_server/application/commands/game_command.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/domain/class/action.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/race.dart';
import 'package:sns_server/domain/class/skill.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/class/template.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:test/test.dart';

void main() {
  group('GameRuntime play-card inference', () {
    test(
      'infers limitedCard when any selected card is attack-limited',
      () async {
        final alpha = _RuntimeTestCharacter('char_alpha');
        final beta = _RuntimeTestCharacter('char_beta');
        alpha.hand.addAll([
          _RuntimeTestPropCard('card_normal', isAttackLimited: false),
          _RuntimeTestPropCard('card_limited', isAttackLimited: true),
        ]);

        final runtime = await _buildRuntime(alpha, beta);
        final result = await runtime.submit(
          PlayCardCommand(
            commandId: 'cmd_1',
            playerId: 'player_alpha',
            clientVersion: 0,
            cardSelections: const [
              PlayCardSelection(cardId: 'card_normal', handIndex: 0),
              PlayCardSelection(cardId: 'card_limited', handIndex: 1),
            ],
            targetCharacterId: beta.id,
          ),
        );

        expect(result.success, isTrue);
        expect(alpha.actedTypes, [ActionType.limitedCard]);
        expect(alpha.actedPayloads.single['cardSelections'], [
          {'cardId': 'card_normal', 'handIndex': 0},
          {'cardId': 'card_limited', 'handIndex': 1},
        ]);
      },
    );

    test('infers attackCard when all selected cards are non-limited', () async {
      final alpha = _RuntimeTestCharacter('char_alpha');
      final beta = _RuntimeTestCharacter('char_beta');
      alpha.hand.addAll([
        _RuntimeTestPropCard('card_a', isAttackLimited: false),
        _RuntimeTestPropCard('card_b', isAttackLimited: false),
      ]);

      final runtime = await _buildRuntime(alpha, beta);
      final result = await runtime.submit(
        PlayCardCommand(
          commandId: 'cmd_2',
          playerId: 'player_alpha',
          clientVersion: 0,
          cardSelections: const [
            PlayCardSelection(cardId: 'card_a', handIndex: 0),
            PlayCardSelection(cardId: 'card_b', handIndex: 1),
          ],
          targetCharacterId: beta.id,
        ),
      );

      expect(result.success, isTrue);
      expect(runtime.state.flowState, FlowState.responseWindow);
      expect(alpha.actedTypes, isEmpty);

      final passResult = await runtime.submit(
        const PassPriorityCommand(
          commandId: 'cmd_2_pass',
          playerId: 'player_beta',
          clientVersion: 1,
        ),
      );

      expect(passResult.success, isTrue);
      expect(alpha.actedTypes, [ActionType.attackCard]);
    });

    test('rejects empty cardSelections before engine dispatch', () async {
      final alpha = _RuntimeTestCharacter('char_alpha');
      final beta = _RuntimeTestCharacter('char_beta');

      final runtime = await _buildRuntime(alpha, beta);
      final result = await runtime.submit(
        PlayCardCommand(
          commandId: 'cmd_3',
          playerId: 'player_alpha',
          clientVersion: 0,
          cardSelections: const [],
          targetCharacterId: beta.id,
        ),
      );

      expect(result.success, isFalse);
      expect(result.error, contains('cardSelections must not be empty'));
      expect(alpha.actedTypes, isEmpty);
    });
  });
}

Future<GameRuntime> _buildRuntime(
  _RuntimeTestCharacter alpha,
  _RuntimeTestCharacter beta,
) async {
  final state = GameState(
    [
      Player('player_alpha', 'Alpha', [alpha], 0),
      Player('player_beta', 'Beta', [beta], 1),
    ],
    <PropCard>[],
    <PropCard>[],
  );
  state.characterById[alpha.id] = alpha;
  state.characterById[beta.id] = beta;
  state.playerById['player_alpha'] = state.players[0];
  state.playerById['player_beta'] = state.players[1];

  final runtime = GameRuntime(gameId: 'game_test', state: state);
  await runtime.engine.initEngine();
  await runtime.engine.startGame();
  return runtime;
}

class _RuntimeTestCharacter implements Character {
  _RuntimeTestCharacter(this.id);

  @override
  final String id;

  final List<ActionType> actedTypes = [];
  final List<Map<String, dynamic>> actedPayloads = [];

  @override
  String get templateId => 'template_test';

  @override
  String get raceId => 'race_test';

  @override
  Template get template => _RuntimeTestTemplate();

  @override
  Race get race => _RuntimeTestRace();

  @override
  Set<CharacterTag> get tags => const {};

  @override
  List<Trait> get traits => [];

  @override
  List<Skill> get skills => [];

  @override
  int currentHp = 10;

  @override
  int maxHp = 10;

  @override
  int attack = 5;

  @override
  int defense = 5;

  @override
  int armor = 0;

  @override
  int currentMp = 0;

  @override
  int maxMp = 5;

  @override
  int actionTime = 0;

  @override
  int jumpedTurn = 0;

  @override
  DamageStats damageStats = DamageStats();

  @override
  HealStats healStats = HealStats();

  @override
  List<Stuff> stuffs = [];

  @override
  List<Status> state = [];

  @override
  bool isAlive = true;

  @override
  List<PropCard> hand = [];

  @override
  int maxHand = 6;

  @override
  List<Modifier> modifiers = [];

  @override
  void initCharacter() {}

  @override
  bool isNotActionable() => !isAlive;

  @override
  void addModifiers(List<Modifier> mods) {
    modifiers.addAll(mods);
  }

  @override
  void applyModifier(Modifier mod) {}

  @override
  void removeModifier(Modifier mod) {}

  @override
  void registerListeners(EventBus bus) {}

  @override
  Future<void> regenMp(GameContext context) async {}

  @override
  Future<void> drawCard(GameContext context, int count) async {}

  @override
  Future<int> rollDice(GameContext context, int sides) async => 1;

  @override
  Future<void> act(
    GameContext context,
    ActionType type,
    Map<String, dynamic> data,
  ) async {
    actedTypes.add(type);
    actedPayloads.add(Map<String, dynamic>.from(data));
  }

  @override
  void applyHealing(
    GameContext context,
    int amount, {
    bool noWandering = false,
  }) {
    currentHp += amount;
  }
}

class _RuntimeTestPropCard implements PropCard {
  _RuntimeTestPropCard(
    this.id, {
    required this.isAttackLimited,
  });

  @override
  final String id;

  @override
  List<Action> get actions => const [];

  @override
  final bool isAttackLimited;

  @override
  bool get isDisabled => false;

  @override
  bool get isReinforced => false;

  @override
  int get priority => 50;

  @override
  Set<PropCardTag> get tags => const {};

  @override
  Future<void> playCard(
    GameContext context,
    Character character, {
    ActionTarget? target,
    Map<String, dynamic> params = const {},
  }) async {}
}

class _RuntimeTestTemplate implements Template {
  @override
  String get id => 'template_test';

  String get name => 'template_test';

  @override
  int get hp => 10;

  @override
  int get attack => 5;

  @override
  int get defense => 5;
}

class _RuntimeTestRace implements Race {
  @override
  String get id => 'race_test';

  String get name => 'race_test';

  @override
  int get regenerationType => 0;

  @override
  int get maxMP => 5;

  @override
  int get initialMP => 0;

  @override
  int get regenerationValue => 1;

  @override
  int get regenerationInterval => 1;
}
