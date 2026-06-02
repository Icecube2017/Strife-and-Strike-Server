import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';

abstract class CardPack extends Identifiable {
  String get name;
  Map<String, int> get cards;
}

class BaseCardPack implements CardPack {
  @override
  final String id;
  @override
  final String name;
  @override
  final Map<String, int> cards;

  BaseCardPack(this.id, this.name, this.cards);

  factory BaseCardPack.fromJson(Map<String, dynamic> json) => 
    BaseCardPack(json["id"] as String, json["name"] as String, json["cards"] as Map<String, int>);
}

abstract class PropCard extends Identifiable {
  String get name;
  Set<PropCardTag> get tags;
  bool get isAttackLimited;

  void playCard(GameContext context, Character character);
}

class _BasePropCard implements PropCard {
  @override
  final String id;
  @override
  final String name;
  @override
  final Set<PropCardTag> tags;
  @override
  final bool isAttackLimited = false;

  _BasePropCard(this.id, this.name, this.tags);

  @override
  Future<void> playCard(GameContext context, Character character) async {}
}

// apollo_arrow
class CardApolloArrow extends _BasePropCard {
  CardApolloArrow() : super('card_apollow_arrow', "阿波罗之箭", {PropCardTag.sharp});
}

class CardBlade extends _BasePropCard {
  CardBlade() : super('card_blade', "短刀", {PropCardTag.sharp});

  @override
  Future<void> playCard(GameContext context, Character character) async {
    character.applyModifier(ModifierImpl("currentMp", -1, false));
    character.applyModifier(ModifierImpl("attack", 10, false));
  }
}

