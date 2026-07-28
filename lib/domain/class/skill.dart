import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/data/ids.dart';

abstract class Skill extends Identifiable {
  int get cooldown; // 当前CD
  int get baseCooldown; // 基础CD
  bool get isExclusive; // 专属技能，不参与抽取
  Condition? get canUseCondition; // 使用条件

  Future<void> cast(GameContext context, Map<String, dynamic> data);
}

class BaseSkill implements Skill {
  @override
  final String id;
  @override
  final int cooldown = 0;
  @override
  final int baseCooldown;
  @override
  final bool isExclusive;
  @override
  final Condition? canUseCondition;

  BaseSkill(this.id, this.baseCooldown, this.isExclusive, this.canUseCondition);

  @override
  Future<void> cast(GameContext context, Map<String, dynamic> data) async {
    // 技能效果
  }
}

class SkillFinaleHope extends BaseSkill {
  SkillFinaleHope() : super(SkillId.finaleHope.id, 10, false, null);

  @override
  Future<void> cast(GameContext context, Map<String, dynamic> data) async {
    final forcedResult = _readForcedResult(data);
    final responseTargetActionId = _readTargetActionId(data);
    data['_postDispatchResponseMutations'] = <Map<String, dynamic>>[
      {
        'effect': StackMutationType.setDiceResult.name,
        if (responseTargetActionId != null)
          'targetActionId': responseTargetActionId,
        'value': forcedResult,
      },
    ];
  }

  String? _readTargetActionId(Map<String, dynamic> data) {
    final rawTargetActionId =
        data['responseTargetActionId'] ?? data['targetActionId'];
    if (rawTargetActionId == null) {
      return null;
    }
    if (rawTargetActionId is! String || rawTargetActionId.isEmpty) {
      throw StateError('responseTargetActionId must be a non-empty string');
    }
    return rawTargetActionId;
  }

  int _readForcedResult(Map<String, dynamic> data) {
    final rawForcedResult = data['forcedResult'];
    if (rawForcedResult is! int) {
      throw StateError('SkillFinaleHope requires forcedResult as an integer');
    }
    if (rawForcedResult < 1) {
      throw StateError('forcedResult must be a positive integer');
    }
    return rawForcedResult;
  }
}

class SkillReticence extends BaseSkill { 
  SkillReticence() : super(SkillId.reticence.id, 5, false, null);

  @override
  Future<void> cast(GameContext context, Map<String, dynamic> data) async {
    final responseTargetActionId = _readTargetActionId(data);
    data['_postDispatchResponseMutations'] = <Map<String, dynamic>>[
      {
        'effect': StackMutationType.cancelAction.name,
        if (responseTargetActionId != null)
          'targetActionId': responseTargetActionId,
      },
    ];
  }

  String? _readTargetActionId(Map<String, dynamic> data) {
    final rawTargetActionId =
        data['responseTargetActionId'] ?? data['targetActionId'];
    if (rawTargetActionId == null) {
      return null;
    }
    if (rawTargetActionId is! String || rawTargetActionId.isEmpty) {
      throw StateError('responseTargetActionId must be a non-empty string');
    }
    return rawTargetActionId;
  }
}
