import 'package:test/test.dart';

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
import 'package:sns_server/domain/core/game.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';

void main() {
  group('GameEngine', () {
    test('startGame enters main decision for first player', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
      final state = GameState([
        Player('player_alpha', 'Alpha', [alpha], 0),
        Player('player_beta', 'Beta', [beta], 1),
      ], <PropCard>[], <PropCard>[]);
      final engine = GameEngine(state);

      await engine.initEngine();
      await engine.startGame();

      expect(state.flowState, FlowState.mainDecision);
      expect(state.activePlayerId, 'player_alpha');
      expect(state.priorityPlayerId, 'player_alpha');
      expect(state.waitingPlayerId, 'player_alpha');
      expect(state.currentPhase, TurnPhase.action);
    });

    test('action can open response window for another player', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
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
      expect(state.priorityPlayerId, 'player_beta');
      expect(state.waitingPlayerId, 'player_beta');
      expect(state.pendingStack, hasLength(1));
      expect(state.pendingStack.single.actionType, ActionType.skill);
    });

    test('passPriority resolves stack and returns to main decision', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
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

      await engine.passPriority('player_beta');

      expect(state.flowState, FlowState.mainDecision);
      expect(state.activePlayerId, 'player_alpha');
      expect(state.priorityPlayerId, 'player_alpha');
      expect(state.waitingPlayerId, 'player_alpha');
      expect(state.pendingStack, isEmpty);
      expect(alpha.actedTypes, contains(ActionType.skill));
    });

    test('response action can cancel a previous pending action', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
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

      await engine.processAction(beta, ActionType.skill, {
        'skillId': 'counter_skill',
        'responseEffect': 'cancelAction',
      });

      expect(state.flowState, FlowState.mainDecision);
      expect(state.pendingStack, isEmpty);
      expect(alpha.actedTypes, isEmpty);
      expect(beta.actedTypes, [ActionType.skill]);
    });

    test('response action can replace the target of a previous action', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
      final gamma = _TestCharacter('char_gamma');
      final state = GameState([
        Player('player_alpha', 'Alpha', [alpha], 0),
        Player('player_beta', 'Beta', [beta], 1),
        Player('player_gamma', 'Gamma', [gamma], 2),
      ], <PropCard>[], <PropCard>[]);
      state.characterById[alpha.id] = alpha;
      state.characterById[beta.id] = beta;
      state.characterById[gamma.id] = gamma;
      state.playerById['player_alpha'] = state.players[0];
      state.playerById['player_beta'] = state.players[1];
      state.playerById['player_gamma'] = state.players[2];
      final engine = GameEngine(state);

      await engine.initEngine();
      await engine.startGame();
      await engine.processAction(alpha, ActionType.attack, {
        'targetId': beta.id,
        'opensResponseWindow': true,
      });

      await engine.processAction(beta, ActionType.skill, {
        'skillId': 'redirect_skill',
        'responseEffect': 'replaceTarget',
        'newTargetId': gamma.id,
      });

      expect(state.flowState, FlowState.mainDecision);
      expect(state.pendingStack, isEmpty);
      expect(beta.actedTypes, [ActionType.skill]);
      expect(alpha.actedTypes, [ActionType.attack]);
      expect(alpha.actedPayloads.single['targetId'], gamma.id);
    });

    test('getActionBlockReason validates attackCard multi-card payload structure', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
      final state = GameState([
        Player('player_alpha', 'Alpha', [alpha], 0),
        Player('player_beta', 'Beta', [beta], 1),
      ], <PropCard>[], <PropCard>[]);
      final engine = GameEngine(state);

      await engine.initEngine();
      await engine.startGame();

      expect(
        engine.getActionBlockReason(alpha, ActionType.attackCard, {}),
        'Missing required action field: cardSelections',
      );
      expect(
        engine.getActionBlockReason(alpha, ActionType.attackCard, {
          'cardSelections': [
            {'cardId': ''},
          ],
        }),
        'Action cardSelections[0].cardId must be a non-empty string',
      );
    });

    test('getActionBlockReason validates limitedCard multi-card payload structure', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
      final state = GameState([
        Player('player_alpha', 'Alpha', [alpha], 0),
        Player('player_beta', 'Beta', [beta], 1),
      ], <PropCard>[], <PropCard>[]);
      final engine = GameEngine(state);

      await engine.initEngine();
      await engine.startGame();

      expect(
        engine.getActionBlockReason(alpha, ActionType.limitedCard, {
          'cardSelections': [],
        }),
        'Action cardSelections must not be empty',
      );
      expect(
        engine.getActionBlockReason(alpha, ActionType.limitedCard, {
          'cardSelections': [
            {'cardId': 'apollo_arrow', 'handIndex': 'bad'},
          ],
        }),
        'Action cardSelections[0].handIndex must be an integer',
      );
    });

    test('getActionBlockReason rejects mismatched play-card action type', () async {
      final alpha = _TestCharacter('char_alpha');
      final beta = _TestCharacter('char_beta');
      alpha.hand.add(_EngineTestPropCard('limited_card', isAttackLimited: true));
      final state = GameState([
        Player('player_alpha', 'Alpha', [alpha], 0),
        Player('player_beta', 'Beta', [beta], 1),
      ], <PropCard>[], <PropCard>[]);
      final engine = GameEngine(state);

      await engine.initEngine();
      await engine.startGame();

      expect(
        engine.getActionBlockReason(alpha, ActionType.attackCard, {
          'cardSelections': [
            {'cardId': 'limited_card', 'handIndex': 0},
          ],
        }),
        'Selected cards imply action type limitedCard, not attackCard',
      );
    });

    test('attackCard writes dice result into the response window payload', () async {
      final alpha = _FixedDiceBaseCharacter(
        'char_alpha',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final beta = _FixedDiceBaseCharacter(
        'char_beta',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final card = _EngineTestPropCard('card_normal', isAttackLimited: false);
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
      alpha
        ..attack = 18
        ..hand.add(card);
      beta
        ..currentHp = 40
        ..defense = 5;

      await engine.processAction(alpha, ActionType.attackCard, {
        'cardSelections': [
          {'cardId': card.id},
        ],
        'targetId': beta.id,
        'forcedResult': 2,
      });

      expect(state.flowState, FlowState.responseWindow);
      expect(state.pendingStack, hasLength(1));
      expect(state.pendingStack.single.stage, PendingActionStage.waitingResponse);
      expect(state.pendingStack.single.resolutionState.diceRoll, isNotNull);
      expect(state.pendingStack.single.resolutionState.diceRoll!.finalResult, 2);
      expect(state.pendingStack.single.resolutionState.pendingDamage, isNotNull);
      expect(state.pendingStack.single.resolutionState.pendingDamage!.amount, 26);
      expect(state.decision, isNotNull);
      expect(state.decision!.payload['actionId'], state.pendingStack.single.actionId);
      expect(state.decision!.payload['stage'], PendingActionStage.waitingResponse.name);
      expect(state.decision!.payload['diceRequest'], {
        'requestId': '${state.pendingStack.single.actionId}_damage_dice',
        'sides': 6,
        'forcedResult': 2,
        'reason': DiceRollReason.attackDamage.name,
        'relatedActionId': state.pendingStack.single.actionId,
      });
      expect(state.decision!.payload['diceRoll'], {
        'rawResult': 1,
        'finalResult': 2,
        'damageMultiplier': 2.0,
        'wasForced': true,
        'wasRerolled': false,
        'history': [1, 2],
      });
      expect(state.decision!.payload['baseDamage'], 13);
      expect(state.decision!.payload['pendingDamage'], {
        'amount': 26,
        'type': DamageType.physical.name,
        'source': DamageSource.action.name,
        'diceResult': 2,
      });
    });
  });
}

class _TestCharacter implements Character {
  _TestCharacter(this.id);

  @override
  final String id;

  final List<ActionType> actedTypes = [];
  final List<Map<String, dynamic>> actedPayloads = [];

  @override
  String get templateId => 'template_test';

  @override
  String get raceId => 'race_test';

  @override
  Template get template => _TestTemplate();

  @override
  Race get race => _TestRace();

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
  }

  @override
  void applyHealing(GameContext context, int amount, {bool noWandering = false}) {
    currentHp += amount;
  }
}

class _TestTemplate implements Template {
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

class _TestRace implements Race {
  @override
  String get id => 'race_test';

  @override
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

class _EngineTestPropCard implements PropCard {
  _EngineTestPropCard(
    this.id, {
    required this.isAttackLimited,
    this.isDisabled = false,
    this.isReinforced = false,
  });

  @override
  final String id;

  @override
  final bool isAttackLimited;

  @override
  final bool isDisabled;

  @override
  final bool isReinforced;

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

class _FixedDiceBaseCharacter extends BaseCharacter {
  _FixedDiceBaseCharacter(
    super.id,
    super.templateId,
    super.raceId,
    super.tags,
    super.traits,
    super.skills,
  );

  @override
  Future<int> rollDice(GameContext context, int sides) async => 1;
}
