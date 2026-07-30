import 'package:sns_server/domain/class/action.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/skill.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';
import 'package:test/test.dart';

void main() {
  group('SkillFinalHope', () {
    test(
      'can rewrite a revealed attack dice result during the response window',
      () async {
        final alpha = _FixedDiceCharacter(
          'char_alpha',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        );
        final beta = _FixedDiceCharacter(
          'char_beta',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [SkillFinalHope()],
        );
        final attackCard = _SkillTestPropCard('card_normal');
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
        final engine = GameEngine(state);
        BeforeDamageEvent? beforeDamageEvent;

        await engine.initEngine();
        await engine.startGame();
        alpha
          ..attack = 18
          ..hand.add(attackCard);
        beta
          ..currentHp = 100
          ..defense = 5;
        state.eventBus.on<BeforeDamageEvent>((event) {
          beforeDamageEvent = event;
        });

        await engine.processAction(alpha, ActionType.attackCard, {
          'cardSelections': [
            {'cardId': attackCard.id},
          ],
          'targetId': beta.id,
          'forcedResult': 2,
        });

        expect(state.flowState, FlowState.responseWindow);
        final targetActionId = state.pendingStack.single.actionId;
        expect(state.decision!.payload['diceRoll'], isNotNull);
        expect(
          (state.decision!.payload['diceRoll']
              as Map<String, dynamic>)['finalResult'],
          2,
        );

        await engine.processAction(beta, ActionType.skill, {
          'skillId': SkillId.finalHope.id,
          'responseTargetActionId': targetActionId,
          'forcedResult': 6,
        });

        expect(beforeDamageEvent, isNotNull);
        expect(beforeDamageEvent!.damage.amount, 78);
        expect(beforeDamageEvent!.damage.diceResult, 6);
        expect(beta.currentHp, 22);
        expect(state.pendingStack, isEmpty);
        expect(state.flowState, FlowState.mainDecision);
        expect(state.activePlayerId, 'player_alpha');
      },
    );

    test(
      'can rewrite a revealed trait dice result during the response window',
      () async {
        final alpha = _FixedDiceCharacter(
          'char_alpha',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [TraitRadiantBlast()],
          [],
        );
        final beta = _FixedDiceCharacter(
          'char_beta',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [SkillFinalHope()],
        );
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
        final engine = GameEngine(state);

        await engine.initEngine();
        alpha.attack = 20;

        await engine.startGame();

        expect(state.flowState, FlowState.responseWindow);
        expect(state.pendingStack, hasLength(1));
        expect(state.pendingStack.single.actionType, ActionType.trait);
        expect(
          (state.decision!.payload['diceRoll']
              as Map<String, dynamic>)['finalResult'],
          1,
        );
        final targetActionId = state.pendingStack.single.actionId;

        await engine.processAction(beta, ActionType.skill, {
          'skillId': SkillId.finalHope.id,
          'responseTargetActionId': targetActionId,
          'forcedResult': 6,
        });

        expect(alpha.attack, 30);
        expect(state.pendingStack, isEmpty);
        expect(state.flowState, FlowState.mainDecision);
        expect(state.currentPhase, TurnPhase.action);
        expect(state.activePlayerId, 'player_alpha');
      },
    );
  });
}

class _FixedDiceCharacter extends BaseCharacter {
  _FixedDiceCharacter(
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

class _SkillTestPropCard implements PropCard {
  _SkillTestPropCard(this.id);

  @override
  final String id;

  @override
  List<Action> get actions => const [];

  @override
  bool get isAttackLimited => false;

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
