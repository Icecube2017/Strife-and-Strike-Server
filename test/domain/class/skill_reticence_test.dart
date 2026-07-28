import 'package:test/test.dart';

import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/race.dart';
import 'package:sns_server/domain/class/skill.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/class/template.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';

void main() {
  group('SkillReticence', () {
    test('cancels the target skill during the response window', () async {
      final alpha = _ReticenceTestCharacter(
        'char_alpha',
        [BaseSkill('counterable_skill', 0, false, null)],
      );
      final beta = _ReticenceTestCharacter(
        'char_beta',
        [SkillReticence()],
      );
      final state = GameState([
        Player('player_alpha', 'Alpha', [alpha], 0),
        Player('player_beta', 'Beta', [beta], 1),
      ], <PropCard>[], <PropCard>[]);
      state.characterById[alpha.id] = alpha;
      state.characterById[beta.id] = beta;
      state.playerById['player_alpha'] = state.players[0];
      state.playerById['player_beta'] = state.players[1];
      final engine = GameEngine(state);

      await engine.initEngine();
      await engine.startGame();

      await engine.processAction(alpha, ActionType.skill, {
        'skillId': 'counterable_skill',
        'opensResponseWindow': true,
      });

      expect(state.flowState, FlowState.responseWindow);
      expect(state.pendingStack, hasLength(1));
      final targetActionId = state.pendingStack.single.actionId;

      await engine.processAction(beta, ActionType.skill, {
        'skillId': SkillId.reticence.id,
        'responseTargetActionId': targetActionId,
      });

      expect(alpha.actedTypes, isEmpty);
      expect(beta.actedTypes, [ActionType.skill]);
      expect(state.pendingStack, isEmpty);
      expect(state.discardPile, isEmpty);
      expect(state.flowState, FlowState.mainDecision);
      expect(state.activePlayerId, 'player_alpha');
    });
  });
}

class _ReticenceTestCharacter implements Character {
  _ReticenceTestCharacter(this.id, this.skills);

  @override
  final String id;

  final List<ActionType> actedTypes = [];
  final List<Map<String, dynamic>> actedPayloads = [];

  @override
  final List<Skill> skills;

  @override
  String get templateId => 'template_test';

  @override
  String get raceId => 'race_test';

  @override
  Template get template => _ReticenceTestTemplate();

  @override
  Race get race => _ReticenceTestRace();

  @override
  Set<CharacterTag> get tags => const {};

  @override
  List<Trait> get traits => [];

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
  void addModifier(List<Modifier> mods) {
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
    if (type == ActionType.skill) {
      final skillId = data['skillId'];
      final skill = skills.firstWhere(
        (candidate) => candidate.id == skillId,
        orElse: () => throw StateError('Character $id does not own skill $skillId'),
      );
      await skill.cast(context, data);
    }
  }

  @override
  void applyHealing(GameContext context, int amount, {bool noWandering = false}) {
    currentHp += amount;
  }
}

class _ReticenceTestTemplate implements Template {
  @override
  String get id => 'template_test';

  @override
  String get name => 'template_test';

  @override
  int get hp => 10;

  @override
  int get attack => 5;

  @override
  int get defense => 5;
}

class _ReticenceTestRace implements Race {
  @override
  String get id => 'race_test';

  @override
  int get maxMP => 5;

  @override
  int get initialMP => 0;

  @override
  int get regenerationInterval => 1;

  @override
  int get regenerationType => 0;

  @override
  int get regenerationValue => 0;
}
