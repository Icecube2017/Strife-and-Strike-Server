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
import 'package:sns_server/domain/resolver/attack_card_resolver.dart';
import 'package:sns_server/domain/resolver/modifier_resolver.dart';
import 'package:sns_server/domain/core/register.dart';
import 'package:sns_server/domain/data/ids.dart';

//final Assets assets = Assets();

abstract class Character extends Identifiable {
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
  void addModifiers(List<Modifier> mods);
  void applyModifier(Modifier mod) {
    /*...*/
  }
  void removeModifier(Modifier mod) {
    /*...*/
  }
  void registerListeners(EventBus bus) {}

  Future<void> regenMp(GameContext context);
  Future<void> drawCard(GameContext context, int count);
  Future<int> rollDice(GameContext context, int sides);
  Future<void> act(
    GameContext context,
    ActionType type,
    Map<String, dynamic> data,
  );

  void applyHealing(GameContext context, int amount, {bool noWandering});
}

class BaseCharacter implements Character {
  @override
  final String id;
  @override
  final String templateId;
  @override
  final String raceId;
  @override
  final Set<CharacterTag> tags;
  @override
  late Template template;
  @override
  late Race race;
  @override
  List<Skill> skills;
  @override
  List<Trait> traits;
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
  final Set<EventBus> _listenerBuses = <EventBus>{};
  final ModifierResolver _modifierResolver = const ModifierResolver();
  final Map<String, int> _modifierBaseValues = <String, int>{};

  BaseCharacter(
    this.id,
    this.templateId,
    this.raceId,
    this.tags,
    this.traits,
    this.skills,
  ) {
    template = TemplateRepo().get(templateId);
    race = RaceRepo().get(raceId);
  }

  // 注册监听器
  @override
  void registerListeners(EventBus bus) {
    if (!_listenerBuses.add(bus)) {
      return;
    }
    registerDamageListeners(bus);
    registerCardListeners(bus);
  }

  void registerDamageListeners(EventBus bus) {
    bus.on<DamageDealtEvent>((event) {
      if (event.target.character.id == id) {
        // 处理受到伤害的逻辑
        final damage = event.damage;
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

  void registerCardListeners(EventBus bus) {
    bus.on<CardPlayedEvent>((event) {
      if (event.source.character.id == id) {
        hand.removeWhere(event.cards.contains);
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
    maxMp = race.maxMP;
    currentMp = race.initialMP;
  }

  // 角色回复行动点
  @override
  Future<void> regenMp(GameContext context) async {}

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
    return state.any(
          (e) =>
              e is StatusFrozen || e is StatusDreaming || e is StatusStellula,
        ) ||
        !isAlive;
  }

  // ...
  @override
  void addModifiers(List<Modifier> mods) {
    for (final mod in mods) {
      applyModifier(mod);
    }
  }

  // ...
  @override
  void applyModifier(Modifier mod) {
    if (modifiers.contains(mod)) {
      throw StateError('Modifier has already been applied');
    }

    _modifierBaseValues.putIfAbsent(
      mod.targetProperty,
      () => _readIntProperty(mod.targetProperty),
    );
    modifiers.add(mod);
    _recalculateModifiedProperty(mod.targetProperty);
  }

  // ...
  @override
  void removeModifier(Modifier mod) {
    final removed = modifiers.remove(mod);
    if (!removed) {
      throw StateError('Modifier has not been applied');
    }

    _recalculateModifiedProperty(mod.targetProperty);
    if (!modifiers.any(
      (active) => active.targetProperty == mod.targetProperty,
    )) {
      _modifierBaseValues.remove(mod.targetProperty);
    }
  }

  void _recalculateModifiedProperty(String property) {
    final baseValue = _modifierBaseValues[property];
    if (baseValue == null) {
      throw StateError('Modifier base value is missing for $property');
    }
    final active = modifiers.where(
      (modifier) => modifier.targetProperty == property,
    );
    _writeIntProperty(property, _modifierResolver.resolve(baseValue, active));
    _normalizeDerivedState();
    isAlive = _isAliveAfterNormalization();
  }

  // 角色掷骰D点
  @override
  Future<int> rollDice(GameContext context, int sides) async {
    return Random().nextInt(sides) + 1;
  }

  // 角色行动
  @override
  Future<void> act(
    GameContext context,
    ActionType type,
    Map<String, dynamic> data,
  ) async {
    switch (type) {
      case (ActionType.attack):
        {}
      case (ActionType.playCard):
        {
          throw StateError(
            'playCard must be resolved to attackCard or limitedCard before character execution',
          );
        }
      case (ActionType.attackCard):
        {
          await AttackCardResolver(context).resolveAttackCard(this, data);
        }
      case (ActionType.limitedCard):
        {
          await AttackCardResolver(context).resolveLimitedCard(this, data);
        }
      case (ActionType.skill):
        {
          final skill = _resolveSkillFromPayload(data);
          await skill.cast(context, data);
        }
      case (ActionType.trait):
        {}
      case (ActionType.passPriority):
        {}
    }
  }

  // 角色
  @override
  Future<void> applyHealing(
    GameContext context,
    int amount, {
    bool? noWandering = false,
  }) async {
    currentHp += amount;
  }

  Skill _resolveSkillFromPayload(Map<String, dynamic> data) {
    final rawSkillId = data['skillId'];
    if (rawSkillId is! String || rawSkillId.isEmpty) {
      throw StateError('skillId must be a non-empty string');
    }
    for (final skill in skills) {
      if (skill.id == rawSkillId) {
        return skill;
      }
    }
    throw StateError('Character $id does not own skill $rawSkillId');
  }

  int _readIntProperty(String property) {
    switch (property) {
      case 'attack':
        return attack;
      case 'defense':
        return defense;
      case 'armor':
        return armor;
      case 'currentHp':
        return currentHp;
      case 'maxHp':
        return maxHp;
      case 'currentMp':
        return currentMp;
      case 'maxMp':
        return maxMp;
    }
    throw StateError('Unsupported modifier targetProperty: $property');
  }

  void _writeIntProperty(String property, int value) {
    switch (property) {
      case 'attack':
        attack = value;
        return;
      case 'defense':
        defense = value;
        return;
      case 'armor':
        armor = value;
        return;
      case 'currentHp':
        currentHp = value;
        return;
      case 'maxHp':
        maxHp = value;
        return;
      case 'currentMp':
        currentMp = value;
        return;
      case 'maxMp':
        maxMp = value;
        return;
    }
    throw StateError('Unsupported modifier targetProperty: $property');
  }

  void _normalizeDerivedState() {
    if (attack < 0) {
      attack = 0;
    }
    if (defense < 0) {
      defense = 0;
    }
    if (armor < 0) {
      armor = 0;
    }
    if (maxHp < 0) {
      maxHp = 0;
    }
    if (maxMp < 0) {
      maxMp = 0;
    }
    if (currentHp < 0) {
      currentHp = 0;
    }
    if (currentHp > maxHp) {
      currentHp = maxHp;
    }
    if (currentMp < 0) {
      currentMp = 0;
    }
    if (currentMp > maxMp) {
      currentMp = maxMp;
    }
    if (currentHp > 0 && !isAlive) {
      isAlive = true;
    }
  }

  bool _isAliveAfterNormalization() {
    return currentHp > 0;
  }
}

class CharacterFactoryCreated extends BaseCharacter {
  CharacterFactoryCreated(
    super.id,
    super.templateId,
    super.raceId,
    super.tags,
    super.traits,
    super.skills,
  );

  factory CharacterFactoryCreated.fromJson(Map<String, dynamic> json) {
    final tags = (json['tags'] as List)
        .cast<String>()
        .map((id) => CharacterTag.values.byName(id))
        .toSet();
    final traits = (json['traits'] as List)
        .cast<String>()
        .map(traitReg.create)
        .toList();
    final skills =
        (json['skills'] as List?)
            ?.cast<String>()
            .map(skillReg.create)
            .toList() ??
        [];
    return CharacterFactoryCreated(
      json['id'] as String,
      json['template'] as String,
      json['race'] as String,
      tags,
      traits,
      skills,
    );
  }
}

class CharacterDefenV extends BaseCharacter {
  CharacterDefenV()
    : super(
        CharacterId.defen5.id,
        TemplateId.defen5.id,
        RaceId.machina.id,
        {CharacterTag.defense, CharacterTag.survive},
        [],
        [],
      );

  @override
  void registerDamageListeners(EventBus bus) {
    bus.on<DamageDealtEvent>((event) {
      if (event.target.character.id == id) {
        // 处理受到伤害的逻辑
        final damage = event.damage;
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

class CharacterRepo {
  CharacterRepo();

  Map<String, List<String>> characters = {
    CharacterId.empty.id: [TemplateId.empty.id, RaceId.empty.id],
  };

  String getTemplateId(String id) =>
      characters[id] == null ? TemplateId.empty.id : characters[id]![0];
  String getRaceId(String id) =>
      characters[id] == null ? RaceId.empty.id : characters[id]![1];
}
