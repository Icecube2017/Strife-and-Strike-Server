import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';

abstract class Trait extends Identifiable {
  String get name;
  bool get isAuto;

  Future<void> register(GameContext context, Character owner);
}

class BaseTrait implements Trait {
  @override
  final String id;
  @override
  final String name;
  @override
  final bool isAuto;

  BaseTrait(this.id, this.name, this.isAuto);

  @override
  Future<void> register(GameContext context, Character owner) async {}
}

class TraitSelfEncouragement extends BaseTrait {
  TraitSelfEncouragement(super.id, super.name, super.isAuto);

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

