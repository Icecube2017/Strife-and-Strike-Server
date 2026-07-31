import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/skill.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/data/ids.dart';

/// 通过ID注册和获取游戏对象，实现动态加载
final class Registry<T extends Identifiable> {
  final Map<String, T Function()> _factories = {};

  void register(String id, T Function() factory) {
    _factories[id] = factory;
  }

  T create(String id) {
    if (!_factories.containsKey(id)) {
      throw Exception('No factory registered for $id');
    }
    return _factories[id]!();
  }
}

final traitReg = Registry<Trait>();
final skillReg = Registry<Skill>();
final statusReg = Registry<Status>();
final characterReg = Registry<Character>();
final cardReg = Registry<PropCard>();

/// 道具卡注册
void registryAllCards() {
  cardReg
    ..register(CardId.apolloArrow.id, CardApolloArrow.new)
    ..register(CardId.blade.id, CardBlade.new);
}

/// 特质注册
void registryAllTraits() {
  traitReg.register(TraitId.radiantBlast.id, TraitRadiantBlast.new);
}

/// 技能注册
void registryAllSkills() {
  skillReg
    ..register(SkillId.finalHope.id, SkillFinalHope.new)
    ..register(SkillId.reticence.id, SkillReticence.new);
}

void registryAllStatuses() {
  statusReg.register(StatusId.strength.id, StatusStrength.new);
}
