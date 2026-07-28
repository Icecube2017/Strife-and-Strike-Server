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
  final Set<PropCardTag> tags;
  @override
  final int priority = 50;
  @override
  bool isAttackLimited;
  @override
  bool isDisabled = false;
  @override
  bool isReinforced = false;

  _BasePropCard(this.id, this.tags, this.isAttackLimited);

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
  CardApolloArrow() : super(CardId.apolloArrow.id, {PropCardTag.sharp}, false);
}

class CardBlade extends _BasePropCard {
  CardBlade() : super(CardId.woodSword.id, {PropCardTag.sharp}, false);

  @override
  Future<void> playCard(
    GameContext context,
    Character character, {
    ActionTarget? target,
    Map<String, dynamic> params = const {},
  }) async {
    isReinforced = params['isReinforced'] is bool && params['isReinforced'] as bool;
    final effectMultiplier = isReinforced ? 2 : 1;
    character.applyModifier(ModifierImpl('attack', 10 * effectMultiplier, ModifierType.additive));
  }
}
