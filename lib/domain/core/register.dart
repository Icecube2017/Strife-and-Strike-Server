import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/race.dart';
import 'package:sns_server/domain/class/skill.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/class/template.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/core.dart';

/// 通过ID注册和获取游戏对象，实现动态加载
final class Registry<T extends Identifiable> {
  final Map<String, T Function()> _factories = {};
  
  void register(String id, T Function() factory) {
    _factories[id] = factory;
  }
  
  T create(String id) {
    return _factories[id]!();
  }
}

final traitReg = Registry<Trait>();
final skillReg = Registry<Skill>();
final statusReg = Registry<Status>();
final characterReg = Registry<Character>();
final cardReg = Registry<PropCard>();

// 道具卡注册
void registryAllCards() {
  cardReg.register('card_apollo_arrow', () => CardApolloArrow());
}

