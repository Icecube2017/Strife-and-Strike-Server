import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/resolver/target_resolver.dart';

/// 可执行效果
abstract class Action {
  Future<void> execute(ActionExecutionContext actionContext);
}

class ActionExecutionContext {
  final GameContext context;
  final ActionTarget? source;
  final ActionTarget? target;
  final Map<String, dynamic> runtimeData;
  final int effectMultiplier;

  ActionExecutionContext({
    required this.context,
    required this.source,
    required this.target,
    Map<String, dynamic> runtimeData = const {},
    this.effectMultiplier = 1,
  }) : runtimeData = Map.unmodifiable(runtimeData) {
    if (effectMultiplier <= 0) {
      throw ArgumentError.value(
        effectMultiplier,
        'effectMultiplier',
        'must be positive',
      );
    }
  }
}

class ActionAddAttack extends Action {
  final int baseAmount;

  ActionAddAttack(this.baseAmount);

  @override
  Future<void> execute(ActionExecutionContext actionContext) async {
    if (actionContext.target == null) {
      throw StateError('ActionAddAttack requires a target');
    }

    final amount = baseAmount * actionContext.effectMultiplier;
    final targets = TargetResolver(
      actionContext.context,
    ).resolve(actionContext.target!, source: actionContext.source);
    for (final characterTarget in targets) {
      characterTarget.character.applyModifier(
        ModifierImpl(PropertyType.attack, amount, ModifierType.additive),
      );
    }
  }
}
