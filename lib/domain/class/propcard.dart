import 'package:sns_server/domain/class/action.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/data/ids.dart';

abstract class CardPack extends Identifiable {
  Map<String, int> get cards;
}

class BaseCardPack implements CardPack {
  @override
  final String id;
  @override
  final Map<String, int> cards;

  BaseCardPack(this.id, this.cards);

  factory BaseCardPack.fromJson(Map<String, dynamic> json) =>
      BaseCardPack(json['id'] as String, json['cards'] as Map<String, int>);
}

abstract class PropCard extends Identifiable {
  List<Action> get actions;
  Set<PropCardTag> get tags;
  bool get isAttackLimited;
  int get priority;
  bool get isDisabled;
  bool get isReinforced;

  Future<void> playCard(
    GameContext context,
    Character character, {
    ActionTarget? target,
    Map<String, dynamic> params = const {},
  });
}

class _BasePropCard implements PropCard {
  @override
  final String id;
  @override
  final List<Action> actions;
  @override
  final Set<PropCardTag> tags;
  @override
  final int priority = 50;
  @override
  bool isAttackLimited;
  @override
  bool isDisabled = false;
  @override
  final bool isReinforced;

  _BasePropCard(
    this.id,
    List<Action> actions,
    this.tags,
    this.isAttackLimited, {
    this.isReinforced = false,
  }) : actions = List.unmodifiable(actions);

  @override
  Future<void> playCard(
    GameContext context,
    Character character, {
    ActionTarget? target,
    Map<String, dynamic> params = const {},
  }) async {}
}

// apollo_arrow
class CardApolloArrow extends _BasePropCard {
  CardApolloArrow({bool isReinforced = false})
    : super(
        CardId.apolloArrow.id,
        [],
        {PropCardTag.sharp},
        false,
        isReinforced: isReinforced,
      );
}

class CardBlade extends _BasePropCard {
  CardBlade({bool isReinforced = false})
    : super(
        CardId.blade.id,
        [ActionAddAttack(10)],
        {PropCardTag.sharp},
        false,
        isReinforced: isReinforced,
      );

  @override
  Future<void> playCard(
    GameContext context,
    Character character, {
    ActionTarget? target,
    Map<String, dynamic> params = const {},
  }) async {
    final effectMultiplier = isReinforced ? 2 : 1;
    final actionContext = ActionExecutionContext(
      context: context,
      source: CharacterTarget(character),
      target: CharacterTarget(character),
      runtimeData: params,
      effectMultiplier: effectMultiplier,
    );
    for (final action in actions) {
      await action.execute(actionContext);
    }
  }
}

class CardShardCrystal extends _BasePropCard {
  CardShardCrystal({bool isReinforced = false})
    : super(
        CardId.shardCrystal.id,
        [],
        {PropCardTag.sharp},
        false,
        isReinforced: isReinforced,
      );
}
