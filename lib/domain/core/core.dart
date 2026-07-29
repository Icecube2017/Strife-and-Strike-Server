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
  ModifierType get type;
  Future<void> apply(Map<String, dynamic> stats);
  Future<void> revert(Map<String, dynamic> stats);
}

class ModifierImpl implements Modifier {
  @override
  final String targetProperty;
  @override
  int value;
  @override
  ModifierType type = ModifierType.additive;

  ModifierImpl(this.targetProperty, this.value, this.type);

  @override
  Future<void> apply(Map<String, dynamic> stats) async {}
  @override
  Future<void> revert(Map<String, dynamic> stats) async {}
}

class Damage {
  final int amount;
  final DamageType type;
  final DamageSource source;
  final int? diceResult; // 投骰结果，用于记录
  Damage(this.amount, this.type, this.source, [this.diceResult]);

  Damage copyWith({
    int? amount,
    DamageType? type,
    DamageSource? source,
    int? diceResult,
  }) {
    return Damage(
      amount ?? this.amount,
      type ?? this.type,
      source ?? this.source,
      diceResult ?? this.diceResult,
    );
  }
}

/// 一次待执行的掷骰请求。
class DiceRequest {
  final String requestId;
  final ActionTarget? source;
  final ActionTarget? target;
  final int sides;
  final int? forcedResult;
  final DiceRollReason reason;
  final String? relatedActionId;
  final Map<String, dynamic> payload;

  DiceRequest({
    required this.requestId,
    required this.sides, 
    required this.reason, 
    this.source,
    this.target,
    this.forcedResult,
    this.relatedActionId,
    this.payload = const {},
  });

  DiceRequest copyWith({
    String? requestId,
    ActionTarget? source,
    ActionTarget? target,
    int? sides,
    int? forcedResult,
    DiceRollReason? reason,
    String? relatedActionId,
    Map<String, dynamic>? payload,
  }) {
    return DiceRequest(
      requestId: requestId ?? this.requestId,
      source: source ?? this.source,
      target: target ?? this.target,
      sides: sides ?? this.sides,
      forcedResult: forcedResult ?? this.forcedResult,
      reason: reason ?? this.reason,
      relatedActionId: relatedActionId ?? this.relatedActionId,
      payload: payload ?? this.payload,
    );
  }
}

/// 一次掷骰从原始点数到最终点数的完整结果。
class DiceRoll {
  final DiceRequest request;
  final int rawResult;
  final int finalResult;
  final double damageMultiplier;
  final bool wasForced;
  final bool wasRerolled;
  final List<int> history;
  final Map<String, dynamic> payload;

  DiceRoll({
    required this.request,
    required this.rawResult,
    required this.finalResult,
    this.damageMultiplier = 1.0,
    this.wasForced = false,
    this.wasRerolled = false,
    this.history = const [],
    this.payload = const {},
  });

  DiceRoll copyWith({
    DiceRequest? request,
    int? rawResult,
    int? finalResult,
    double? damageMultiplier,
    bool? wasForced,
    bool? wasRerolled,
    List<int>? history,
    Map<String, dynamic>? payload,
  }) {
    return DiceRoll(
      request: request ?? this.request,
      rawResult: rawResult ?? this.rawResult,
      finalResult: finalResult ?? this.finalResult,
      damageMultiplier: damageMultiplier ?? this.damageMultiplier,
      wasForced: wasForced ?? this.wasForced,
      wasRerolled: wasRerolled ?? this.wasRerolled,
      history: history ?? this.history,
      payload: payload ?? this.payload,
    );
  }
}

/// 栈上动作在结算过程中累积的中间态。
class PendingActionResolutionState {
  String? targetCharacterId;
  DiceRequest? diceRequest;
  DiceRoll? diceRoll;
  int? baseDamage;
  double damageMultiplier;
  Damage? pendingDamage;
  final Map<String, dynamic> metadata;

  PendingActionResolutionState({
    this.targetCharacterId,
    this.diceRequest,
    this.diceRoll,
    this.baseDamage,
    this.damageMultiplier = 1.0,
    this.pendingDamage,
    Map<String, dynamic>? metadata,
  }) : metadata = metadata ?? <String, dynamic>{};
}

class StackMutation {
  final StackMutationType type;
  final String? targetActionId;
  final String? payloadField;
  final dynamic value;
  final String? newTargetId;
  final Map<String, dynamic> payloadPatch;

  const StackMutation({
    required this.type,
    this.targetActionId,
    this.payloadField,
    this.value,
    this.newTargetId,
    this.payloadPatch = const {},
  });
}

class PendingAction {
  final String actionId;
  final String actorPlayerId;
  final String actorCharacterId;
  final ActionType actionType;
  final Map<String, dynamic> payload;
  final String? parentActionId;
  final bool opensResponseWindow;
  PendingActionStage stage;
  final PendingActionResolutionState resolutionState;
  bool isResolved;
  bool isCancelled;

  PendingAction({
    required this.actionId,
    required this.actorPlayerId,
    required this.actorCharacterId,
    required this.actionType,
    required this.payload,
    this.parentActionId,
    this.opensResponseWindow = true,
    this.stage = PendingActionStage.declared,
    PendingActionResolutionState? resolutionState,
    this.isResolved = false,
    this.isCancelled = false,
  }) : resolutionState = resolutionState ?? PendingActionResolutionState();
}

class DecisionContext {
  final String decisionId;
  final DecisionType type;
  final List<String> allowedPlayerIds;
  final Map<String, dynamic> payload;

  DecisionContext({
    required this.decisionId,
    required this.type,
    required this.allowedPlayerIds,
    this.payload = const {},
  });
}

class GameOutcome {
  final GameOutcomeType type;
  final String? winnerPlayerId;
  final String? winnerTeamId;
  final String? reason;

  GameOutcome({
    required this.type,
    this.winnerPlayerId,
    this.winnerTeamId,
    this.reason,
  });
}
