import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';

/// 游戏实体通用接口
abstract class Identifiable {
  String get id;
}

/// 可执行效果
abstract class Action {
  /// 执行效果，context提供当前游戏上下文、执行者、目标等
  Future<void> execute(GameContext context, ActionTarget? target, [Map<String, dynamic>? params]);
}

/// 条件判断接口
abstract class Condition {
  bool test(GameContext context, ActionTarget? source, ActionTarget? target);
}

/// 修改器
abstract class Modifier {
  String get targetProperty;
  int get value;
  bool get isMultiply;
  Future<void> apply(Map<String, dynamic> stats);
  Future<void> revert(Map<String, dynamic> stats);
}

class ModifierImpl implements Modifier {
  @override
  final String targetProperty;
  @override
  int value;
  @override
  bool isMultiply = false;

  ModifierImpl(this.targetProperty, this.value, this.isMultiply);

  @override
  Future<void> apply(Map<String, dynamic> stats) async {}
  @override
  Future<void> revert(Map<String, dynamic> stats) async {}
}

class Damage {
  final int amount;
  final DamageType type;
  final int? diceResult; // 投骰结果，用于记录
  Damage(this.amount, this.type, [this.diceResult]);
}

