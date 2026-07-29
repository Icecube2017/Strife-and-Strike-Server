import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/data/ids.dart';
import 'package:test/test.dart';

void main() {
  group('BaseCharacter.playCard actions', () {
    test('registerListeners is idempotent for the same event bus', () {
      final actor = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final target = BaseCharacter(
        'char_target',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final context = _buildContext(actor, target);

      actor
        ..registerListeners(context.eventBus)
        ..registerListeners(context.eventBus);
      context.eventBus.emit(
        DamageDealtEvent(
          context,
          CharacterTarget(target),
          CharacterTarget(actor),
          Damage(1, DamageType.physical, DamageSource.action),
        ),
      );

      expect(actor.currentHp, actor.maxHp - 1);
    });

    test('plays the matching card instance and removes it from hand', () async {
      final actor = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final target = BaseCharacter(
        'char_target',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final card = _TestPropCard(CardId.apolloArrow.id);
      actor.hand.add(card);
      final context = _buildContext(actor, target);

      await actor.act(context, ActionType.attackCard, {
        'cardSelections': [
          {'cardId': card.id},
        ],
        'targetId': target.id,
      });

      expect(actor.hand, isEmpty);
      expect(card.playedBy, same(actor));
      expect(card.playTarget, isA<CharacterTarget>());
      expect((card.playTarget! as CharacterTarget).character, same(target));
      expect(card.playParams['isReinforced'], isFalse);
    });

    test('passes reinforced multiplier to card effect execution', () async {
      final actor = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final target = BaseCharacter(
        'char_target',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final card = _TestPropCard(CardId.apolloArrow.id, isReinforced: true);
      actor.hand.add(card);
      final context = _buildContext(actor, target);

      await actor.act(context, ActionType.attackCard, {
        'cardSelections': [
          {'cardId': card.id},
        ],
        'targetId': target.id,
      });

      expect(card.playParams['isReinforced'], isTrue);
    });

    test('rejects disabled cards before executing the effect', () async {
      final actor = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final target = BaseCharacter(
        'char_target',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final card = _TestPropCard(CardId.apolloArrow.id, isDisabled: true);
      actor.hand.add(card);
      final context = _buildContext(actor, target);

      await expectLater(
        () => actor.act(context, ActionType.attackCard, {
          'cardSelections': [
            {'cardId': card.id},
          ],
          'targetId': target.id,
        }),
        throwsA(isA<StateError>()),
      );

      expect(card.wasPlayed, isFalse);
      expect(actor.hand, hasLength(1));
    });

    test('handIndex disambiguates duplicate card instances', () async {
      final actor = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final target = BaseCharacter(
        'char_target',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final normalCard = _TestPropCard(CardId.apolloArrow.id);
      final reinforcedCard = _TestPropCard(
        CardId.apolloArrow.id,
        isReinforced: true,
      );
      actor.hand.addAll([normalCard, reinforcedCard]);
      final context = _buildContext(actor, target);

      await actor.act(context, ActionType.attackCard, {
        'cardSelections': [
          {'cardId': CardId.apolloArrow.id, 'handIndex': 1},
        ],
        'targetId': target.id,
      });

      expect(normalCard.wasPlayed, isFalse);
      expect(reinforcedCard.wasPlayed, isTrue);
      expect(actor.hand, [same(normalCard)]);
    });

    test('plays multiple cards in the declared cardSelections order', () async {
      final actor = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final target = BaseCharacter(
        'char_target',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final firstCard = _TestPropCard(CardId.apolloArrow.id);
      final secondCard = _TestPropCard(CardId.blade.id, isReinforced: true);
      actor.hand.addAll([firstCard, secondCard]);
      final context = _buildContext(actor, target);

      await actor.act(context, ActionType.attackCard, {
        'cardSelections': [
          {'cardId': firstCard.id},
          {'cardId': secondCard.id},
        ],
        'targetId': target.id,
      });

      expect(actor.hand, isEmpty);
      expect(firstCard.wasPlayed, isTrue);
      expect(secondCard.wasPlayed, isTrue);
      expect(firstCard.playTarget, isA<CharacterTarget>());
      expect(secondCard.playTarget, isA<CharacterTarget>());
      expect(firstCard.playParams['resolvedCardIds'], [
        firstCard.id,
        secondCard.id,
      ]);
      expect(secondCard.playParams['resolvedCardIds'], [
        firstCard.id,
        secondCard.id,
      ]);
      expect(secondCard.playParams['isReinforced'], isTrue);
    });

    test('cardSelections can target specific hand instances', () async {
      final actor = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final target = BaseCharacter(
        'char_target',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      );
      final normalCard = _TestPropCard(CardId.apolloArrow.id);
      final reinforcedCard = _TestPropCard(
        CardId.apolloArrow.id,
        isReinforced: true,
      );
      actor.hand.addAll([normalCard, reinforcedCard]);
      final context = _buildContext(actor, target);

      await actor.act(context, ActionType.attackCard, {
        'cardSelections': [
          {'cardId': CardId.apolloArrow.id, 'handIndex': 1},
          {'cardId': CardId.apolloArrow.id, 'handIndex': 0},
        ],
        'targetId': target.id,
      });

      expect(actor.hand, isEmpty);
      expect(reinforcedCard.wasPlayed, isTrue);
      expect(normalCard.wasPlayed, isTrue);
      expect(reinforcedCard.playParams['isReinforced'], isTrue);
      expect(normalCard.playParams['isReinforced'], isFalse);
    });

    test(
      'rejects selecting the same handIndex twice in one multi-card action',
      () async {
        final actor = BaseCharacter(
          'char_actor',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        );
        final target = BaseCharacter(
          'char_target',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        );
        actor.hand.add(_TestPropCard(CardId.apolloArrow.id));
        final context = _buildContext(actor, target);

        await expectLater(
          () => actor.act(context, ActionType.attackCard, {
            'cardSelections': [
              {'cardId': CardId.apolloArrow.id, 'handIndex': 0},
              {'cardId': CardId.apolloArrow.id, 'handIndex': 0},
            ],
            'targetId': target.id,
          }),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'limitedCard uses the same multi-card protocol and execution path',
      () async {
        final actor = BaseCharacter(
          'char_actor',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        );
        final target = BaseCharacter(
          'char_target',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        );
        final firstCard = _TestPropCard(CardId.apolloArrow.id);
        final secondCard = _TestPropCard(
          CardId.blade.id,
          isReinforced: true,
        );
        actor.hand.addAll([firstCard, secondCard]);
        final context = _buildContext(actor, target);

        await actor.act(context, ActionType.limitedCard, {
          'cardSelections': [
            {'cardId': firstCard.id},
            {'cardId': secondCard.id},
          ],
          'targetId': target.id,
        });

        expect(actor.hand, isEmpty);
        expect(firstCard.wasPlayed, isTrue);
        expect(secondCard.wasPlayed, isTrue);
        expect(secondCard.playParams['resolvedCardIds'], [
          firstCard.id,
          secondCard.id,
        ]);
      },
    );

    test(
      'limitedCard does not emit dice or damage events or reduce target hp',
      () async {
        final actor = BaseCharacter(
          'char_actor',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        )..attack = 18;
        final target =
            BaseCharacter(
                'char_target',
                TemplateId.defensive.id,
                RaceId.human.id,
                const {},
                [],
                [],
              )
              ..currentHp = 40
              ..defense = 5;
        final card = _TestPropCard(CardId.apolloArrow.id);
        actor.hand.add(card);
        final context = _buildContext(actor, target);
        var effectEventCount = 0;

        actor.registerListeners(context.eventBus);
        target.registerListeners(context.eventBus);
        context.eventBus.on<BeforeDiceEvent>((_) => effectEventCount++);
        context.eventBus.on<AfterDiceEvent>((_) => effectEventCount++);
        context.eventBus.on<DiceResolvedEvent>((_) => effectEventCount++);
        context.eventBus.on<BeforeDamageEvent>((_) => effectEventCount++);
        context.eventBus.on<DamageDealtEvent>((_) => effectEventCount++);
        context.eventBus.on<AfterDamageEvent>((_) => effectEventCount++);

        await actor.act(context, ActionType.limitedCard, {
          'cardSelections': [
            {'cardId': card.id},
          ],
          'targetId': target.id,
        });

        expect(effectEventCount, 0);
        expect(target.currentHp, 40);
      },
    );

    test(
      'attackCard resolves dice before damage and reduces target hp',
      () async {
        final actor = BaseCharacter(
          'char_actor',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        )..attack = 18;
        final target =
            BaseCharacter(
                'char_target',
                TemplateId.defensive.id,
                RaceId.human.id,
                const {},
                [],
                [],
              )
              ..currentHp = 40
              ..defense = 5;
        final card = _TestPropCard(CardId.apolloArrow.id);
        actor.hand.add(card);
        final context = _buildContext(actor, target);
        final observedEvents = <String>[];
        BeforeDiceEvent? beforeDiceEvent;
        AfterDiceEvent? afterDiceEvent;
        DiceResolvedEvent? diceResolvedEvent;
        BeforeDamageEvent? beforeDamageEvent;
        DamageDealtEvent? dealtDamageEvent;
        AfterDamageEvent? afterDamageEvent;

        actor.registerListeners(context.eventBus);
        target.registerListeners(context.eventBus);
        context.eventBus.on<BeforeDiceEvent>((event) {
          observedEvents.add('beforeDice');
          beforeDiceEvent = event;
          event.request = event.request.copyWith(
            forcedResult: 2,
          );
        });
        context.eventBus.on<AfterDiceEvent>((event) {
          observedEvents.add('afterDice');
          afterDiceEvent = event;
        });
        context.eventBus.on<DiceResolvedEvent>((event) {
          observedEvents.add('diceResolved');
          diceResolvedEvent = event;
        });
        context.eventBus.on<BeforeDamageEvent>((event) {
          observedEvents.add('before');
          beforeDamageEvent = event;
        });
        context.eventBus.on<DamageDealtEvent>((event) {
          observedEvents.add('dealt');
          dealtDamageEvent = event;
        });
        context.eventBus.on<AfterDamageEvent>((event) {
          observedEvents.add('after');
          afterDamageEvent = event;
        });

        await actor.act(context, ActionType.attackCard, {
          'cardSelections': [
            {'cardId': card.id},
          ],
          'targetId': target.id,
        });

        expect(observedEvents, [
          'beforeDice',
          'afterDice',
          'diceResolved',
          'before',
          'dealt',
          'after',
        ]);
        expect(beforeDiceEvent, isNotNull);
        expect(afterDiceEvent, isNotNull);
        expect(diceResolvedEvent, isNotNull);
        expect(beforeDamageEvent, isNotNull);
        expect(dealtDamageEvent, isNotNull);
        expect(afterDamageEvent, isNotNull);
        expect(beforeDiceEvent!.request.reason, DiceRollReason.attackDamage);
        expect(afterDiceEvent!.roll.finalResult, 2);
        expect(afterDiceEvent!.roll.damageMultiplier, 2.0);
        expect(diceResolvedEvent!.roll.finalResult, 2);
        expect(beforeDamageEvent!.source!.character, same(actor));
        expect(beforeDamageEvent!.target.character, same(target));
        expect(beforeDamageEvent!.damage, isA<Damage>());
        expect(beforeDamageEvent!.damage.diceResult, 2);
        expect(beforeDamageEvent!.damage.amount, 26);
        expect(target.currentHp, 14);
        expect(target.isAlive, isTrue);
      },
    );
  });
}

GameContext _buildContext(Character actor, Character target) {
  final state = GameState(
    [
      Player('player_actor', 'Actor', [actor], 0),
      Player('player_target', 'Target', [target], 1),
    ],
    [],
    [],
  );
  state.characterById[actor.id] = actor;
  state.characterById[target.id] = target;
  state.playerById['player_actor'] = state.players[0];
  state.playerById['player_target'] = state.players[1];
  final context = _TestGameContext(state);
  actor.registerListeners(context.eventBus);
  target.registerListeners(context.eventBus);
  return context;
}

class _TestGameContext implements GameContext {
  _TestGameContext(this.state);

  @override
  final GameState state;

  @override
  Iterable<Player> getAllPlayers() => state.players;

  @override
  Character? getCharacterById(String id) => state.characterById[id];

  @override
  Player? getCurrentPlayer() => state.players.first;

  @override
  int getCurrentRound() => state.currentRound;

  @override
  int getCurrentTurnIndex() => state.currentPlayerIndex;

  @override
  EventBus get eventBus => state.eventBus;
}

class _TestPropCard implements PropCard {
  _TestPropCard(
    this.id, {
    this.isDisabled = false,
    this.isReinforced = false,
  });

  @override
  final String id;

  @override
  final bool isDisabled;

  @override
  final bool isReinforced;

  @override
  bool get isAttackLimited => false;

  @override
  int get priority => 50;

  @override
  Set<PropCardTag> get tags => const {};

  bool wasPlayed = false;
  Character? playedBy;
  ActionTarget? playTarget;
  Map<String, dynamic> playParams = const {};

  @override
  Future<void> playCard(
    GameContext context,
    Character character, {
    ActionTarget? target,
    Map<String, dynamic> params = const {},
  }) async {
    wasPlayed = true;
    playedBy = character;
    playTarget = target;
    playParams = Map<String, dynamic>.from(params);
  }
}
