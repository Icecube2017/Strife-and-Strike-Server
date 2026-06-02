import 'package:sns_server/domain/core/core.dart';

abstract class Skill extends Identifiable {
  String get name;
  int get cooldown; // 回合CD
  bool get isExclusive; // 专属技能，不参与抽取
  Condition? get canUseCondition; // 使用条件
}
