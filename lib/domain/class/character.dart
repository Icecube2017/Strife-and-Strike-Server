import 'dart:math';

import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/race.dart';
import 'package:sns_server/domain/class/skill.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/class/template.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/register.dart';
import 'package:sns_server/domain/data/assets.dart';

//final Assets assets = Assets();

abstract class Character extends Identifiable {
  String get name;
  String get templateId;
  String get raceId;
  Template get template;
  Race get race;
  Set<CharacterTag> get tags;

  List<Trait> get traits;
  List<Skill> get skills; // 拥有的技能

  // 动态属性
  int get currentHp;
  int get maxHp;
  int get attack;
  int get defense;
  int get armor;
  int get currentMp;
  int get maxMp;
  List<Stuff> get stuffs;
  List<Status> get state;
  bool get isAlive;
  List<PropCard> get hand;
  int get maxHand;

  List<Modifier> get modifiers;

  void initCharacter();
  bool isNotActionable();
  void addModifier(List<Modifier> mods);
  void applyModifier(Modifier mod) { /*...*/ }
  void removeModifier(Modifier mod) { /*...*/ }
  void registerListeners(EventBus bus) {  }

  Future<void> regenMp(GameContext context);
  Future<void> drawCard(GameContext context, int count);
  Future<int> rollDice(GameContext context, int sides);
  void act(GameContext context, ActionType type, Map<String, dynamic> data);

  void applyHealing(GameContext context, int amount, {bool noWandering});
}

class BaseCharacter implements Character {
  @override
  final String id;
  @override
  final String name;
  @override
  final String templateId;
  @override
  final String raceId;
  @override
  final Set<CharacterTag> tags;
  @override
  final List<Trait> traits;
  @override
  late Template template;
  @override
  late Race race;
  @override
  List<Skill> skills;
  @override
  int maxHand = 6;
  @override
  int armor = 0;
  @override
  int attack = 0;
  @override
  int defense = 0;
  @override
  int maxHp = 1350;
  @override
  int currentHp = 1350;
  @override
  int maxMp = 5;
  @override
  int currentMp = 0;
  @override
  List<Stuff> stuffs = [];
  @override
  List<Status> state = [];
  @override
  List<PropCard> hand = [];
  @override
  List<Modifier> modifiers = [];
  @override
  bool isAlive = true;

  BaseCharacter(this.id, this.name, this.templateId, this.raceId, this.tags, this.traits, this.skills) {
    //template = assets.getTemplate(templateId);
    //race = assets.getRace(raceId);
  }

  // 注册监听器
  @override
  void registerListeners(EventBus bus) {
    bus.on<DamageDealtEvent>((event) {
      if (event.target.character.id == id) {
        // 处理受到伤害的逻辑
        Damage damage = event.damage;
        // 计算实际伤害，考虑防御、护甲等
        currentHp -= damage.amount;
        if (currentHp <= 0) {
          currentHp = 0;
          isAlive = false;
          bus.emit(CharacterDiedEvent(event.context, this));
        }
      }
    });
  }

  // 角色初始化
  @override
  void initCharacter() {
    maxHp = template.hp;
    currentHp = template.hp;
    attack = template.attack;
    defense = template.defense;
  }

  // 角色回复行动点
  @override
  Future<void> regenMp(GameContext context) async {
    
  }

  // 角色摸牌
  @override
  Future<void> drawCard(GameContext context, int count) async {
    if (context.state.drawPile.length <= count) {
      count = context.state.drawPile.length;
    }
    
  }

  // 判定角色当前是否可以行动
  @override
  bool isNotActionable() {
    return (state.any((e) => e is StatusFrozen || e is StatusDreaming || e is StatusStellula) || !isAlive);
  }

  // ...
  @override
  void addModifier(List<Modifier> mods) {
    modifiers.addAll(mods);
  }

  // ...
  @override
  void applyModifier(Modifier mod) {
    switch (mod.targetProperty) {
      case ("attack"): {
        
      }
    }
  }

  // ...
  @override
  void removeModifier(Modifier mod) {
    // TODO: implement removeModifier
  }

  // 角色掷骰D点
  @override
  Future<int> rollDice(GameContext context, int sides) async {return Random().nextInt(sides);}

  // 角色行动
  @override
  Future<void> act(GameContext context, ActionType type, Map<String, dynamic> data) async {
    switch (type) {
      case (ActionType.attack) : {
        
      }
      case (ActionType.attackCard) : {

      }
      case (ActionType.limitedCard) : {

      }
    }
  }

  // 角色
  @override
  Future<void> applyHealing(GameContext context, int amount, {bool? noWandering = false}) async {
    currentHp += amount;
  }
}

class CharacterFactoryCreated extends BaseCharacter {
  CharacterFactoryCreated(super.id, super.name, super.templateId, super.raceId, super.tags, super.traits, super.skills);

  factory CharacterFactoryCreated.fromJson(Map<String, dynamic> json) {
    final tags = (json["tags"] as List).cast<String>().map((id) => CharacterTag.values.byName(id)).toSet();
    final traits = (json["traits"] as List).cast<String>().map((id) => traitReg.create(id)).toList();
    final skills = (json["skills"] as List?)?.cast<String>().map((id) => skillReg.create(id)).toList()??[];
    return CharacterFactoryCreated(
      json["id"] as String,
      json["name"] as String,
      json["template"] as String,
      json["race"] as String,
      tags,
      traits,
      skills
    );
  }
}

class CharacterDefenV extends BaseCharacter {
  static const String regId = 'character_defen_v';
  CharacterDefenV():super(regId, 'DeFen-5', 'defen_v', 'machine',
    {CharacterTag.defense, CharacterTag.survive},[],[]);

  @override
  void registerListeners(EventBus bus) {
    bus.on<DamageDealtEvent>((event) {
      if (event.target.character.id == id) {
        // 处理受到伤害的逻辑
        Damage damage = event.damage;
        // 计算实际伤害，考虑防御、护甲等
        defense -= (damage.amount * 0.02).toInt();
        if (defense <= 0) {
          defense = 0;
          isAlive = false;
          bus.emit(CharacterDiedEvent(event.context, this));
        }
      }
    });
  }
}

