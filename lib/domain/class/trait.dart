import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/data/ids.dart';

abstract class Trait extends Identifiable {
  bool get isAuto;
  int get castCount;
  Condition? get canUseCondition;

  Future<void> register(GameContext context, Character owner);
  Future<void> onTurnStart(GameContext context, Character owner);
  Future<void> onTurnEnd(GameContext context, Character owner);
  DiceRequest? createTurnStartDiceRequest(
    GameContext context,
    Character owner, {
    required String relatedActionId,
  });
  Future<void> onTurnStartDiceResolved(
    GameContext context,
    Character owner,
    DiceRoll roll,
  );
}

class BaseTrait implements Trait {
  @override
  final String id;
  @override
  final bool isAuto;
  @override
  final int castCount;
  @override
  final Condition? canUseCondition;

  BaseTrait(this.id, this.isAuto, this.castCount, this.canUseCondition);

  @override
  Future<void> register(GameContext context, Character owner) async {}

  @override
  Future<void> onTurnStart(GameContext context, Character owner) async {}

  @override
  Future<void> onTurnEnd(GameContext context, Character owner) async {}

  @override
  DiceRequest? createTurnStartDiceRequest(
    GameContext context,
    Character owner, {
    required String relatedActionId,
  }) {
    return null;
  }

  @override
  Future<void> onTurnStartDiceResolved(
    GameContext context,
    Character owner,
    DiceRoll roll,
  ) async {}
}

class TraitSelfEncouragement extends BaseTrait {
  TraitSelfEncouragement(
    super.id,
    super.isAuto,
    super.castCount,
    super.canUseCondition,
  );

  bool hasTriggered = false;

  @override
  Future<void> register(GameContext context, Character owner) async {
    context.state.eventBus.on<TurnEndEvent>((e) {
      final hpPercent = owner.currentHp / owner.maxHp;
      if (hpPercent <= 0.5 && hpPercent > 0 && !hasTriggered) {
        final targetHp = (0.8 * owner.maxHp).round();
        final healAmount = targetHp - owner.currentHp;
        owner.applyHealing(context, healAmount, noWandering: true);
      }
    });
  }
}

class TraitRadiantBlast extends BaseTrait {
  TraitRadiantBlast() : super(TraitId.radiantBlast.id, true, -1, null);
  static const int _attackBonus = 10;

  Modifier? _activeAttackModifier;

  @override
  Future<void> onTurnStart(GameContext context, Character owner) async {
    if (_activeAttackModifier != null) {
      owner.removeModifier(_activeAttackModifier!);
      _activeAttackModifier = null;
    }
  }

  @override
  Future<void> onTurnEnd(GameContext context, Character owner) async {
    if (_activeAttackModifier == null) {
      return;
    }

    owner.removeModifier(_activeAttackModifier!);
    _activeAttackModifier = null;
    context.eventBus.emit(CharacterChangedEvent(context, owner));
  }

  @override
  DiceRequest createTurnStartDiceRequest(
    GameContext context,
    Character owner, {
    required String relatedActionId,
  }) {
    return DiceRequest(
      requestId: '${relatedActionId}_turn_start_dice',
      source: CharacterTarget(owner),
      target: CharacterTarget(owner),
      sides: 6,
      reason: DiceRollReason.traitEffect,
      relatedActionId: relatedActionId,
      payload: {
        'actionType': ActionType.trait.name,
        'traitId': id,
        'trigger': 'turnStart',
        'characterId': owner.id,
      },
    );
  }

  @override
  Future<void> onTurnStartDiceResolved(
    GameContext context,
    Character owner,
    DiceRoll roll,
  ) async {
    if (roll.finalResult < 4) {
      return;
    }

    final modifier = ModifierImpl(
      PropertyType.attack,
      _attackBonus,
      ModifierType.additive,
    );
    owner.applyModifier(modifier);
    _activeAttackModifier = modifier;
    context.eventBus.emit(CharacterChangedEvent(context, owner));
  }
}
