import 'dart:math';

import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/race.dart';
import 'package:sns_server/domain/class/skill.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/class/template.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/register.dart';
import 'package:sns_server/domain/data/ids.dart';
import 'package:sns_server/domain/data/panels.dart';

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
  void addModifier(List<Modifier> mods);
  void applyModifier(Modifier mod) { /*...*/ }
  void removeModifier(Modifier mod) { /*...*/ }
  void registerListeners(EventBus bus) {  }

  Future<void> regenMp(GameContext context);
  Future<void> drawCard(GameContext context, int count);
  Future<int> rollDice(GameContext context, int sides);
  Future<void> act(GameContext context, ActionType type, Map<String, dynamic> data);

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
  final Map<Modifier, int> _modifierAppliedDeltaByModifier = <Modifier, int>{};
  final Map<Modifier, int> _modifierOverrideSnapshotByModifier = <Modifier, int>{};

  BaseCharacter(this.id, this.templateId, this.raceId, this.tags, this.traits, this.skills) {
    template = TemplateRepo().get(templateId);
    race = RaceRepo().get(raceId);
  }

  // 注册监听器
  @override
  void registerListeners(EventBus bus) {
    bus..on<DamageDealtEvent>((event) {
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
    return state.any((e) => e is StatusFrozen || e is StatusDreaming || e is StatusStellula) || !isAlive;
  }

  // ...
  @override
  void addModifier(List<Modifier> mods) {
    for (final mod in mods) {
      applyModifier(mod);
    }
  }

  // ...
  @override
  void applyModifier(Modifier mod) {
    if (_modifierAppliedDeltaByModifier.containsKey(mod) ||
        _modifierOverrideSnapshotByModifier.containsKey(mod)) {
      throw StateError('Modifier has already been applied');
    }

    final currentValue = _readIntProperty(mod.targetProperty);
    switch (mod.type) {
      case ModifierType.additive: {
        _writeIntProperty(mod.targetProperty, currentValue + mod.value);
        _modifierAppliedDeltaByModifier[mod] = mod.value;
      }
      case ModifierType.multiplicative: {
        final nextValue = (currentValue * mod.value).round();
        _writeIntProperty(mod.targetProperty, nextValue);
        _modifierAppliedDeltaByModifier[mod] = nextValue - currentValue;
      }
      case ModifierType.override: {
        _modifierOverrideSnapshotByModifier[mod] = currentValue;
        _writeIntProperty(mod.targetProperty, mod.value);
      }
    }

    modifiers.add(mod);
    _normalizeDerivedState();
    if (!_isAliveAfterNormalization()) {
      isAlive = false;
    }
  }

  // ...
  @override
  void removeModifier(Modifier mod) {
    final removed = modifiers.remove(mod);
    if (!removed) {
      throw StateError('Modifier has not been applied');
    }

    final overrideSnapshot = _modifierOverrideSnapshotByModifier.remove(mod);
    if (overrideSnapshot != null) {
      _writeIntProperty(mod.targetProperty, overrideSnapshot);
      _normalizeDerivedState();
      return;
    }

    final appliedDelta = _modifierAppliedDeltaByModifier.remove(mod);
    if (appliedDelta == null) {
      throw StateError('Modifier rollback state is missing');
    }

    final currentValue = _readIntProperty(mod.targetProperty);
    _writeIntProperty(mod.targetProperty, currentValue - appliedDelta);
    _normalizeDerivedState();
  }

  // 角色掷骰D点
  @override
  Future<int> rollDice(GameContext context, int sides) async {return Random().nextInt(sides) + 1;}

  // 角色行动
  @override
  Future<void> act(GameContext context, ActionType type, Map<String, dynamic> data) async {
    switch (type) {
      case (ActionType.attack) : {
        
      }
      case (ActionType.playCard) : {
        throw StateError('playCard must be resolved to attackCard or limitedCard before character execution');
      }
      case (ActionType.attackCard) : {
        final resumeDamageResolutionOnly = data['_resumeDamageResolutionOnly'] == true;
        if (resumeDamageResolutionOnly) {
          _materializePreparedAttackCardDamage(data);
          await _applyPreparedAttackCardDamage(context, data);
          break;
        }
        final deferDamageResolution = data['_deferDamageResolution'] == true;
        await _playCards(
          context,
          data,
          dealsDamage: true,
          deferDamageResolution: deferDamageResolution,
        );
      }
      case (ActionType.limitedCard) : {
        await _playCards(context, data, dealsDamage: false);
      }
      case (ActionType.skill) : {
        final skill = _resolveSkillFromPayload(data);
        await skill.cast(context, data);
      }
      case (ActionType.trait) : {

      }
      case (ActionType.passPriority) : {

      }
    }
  }

  // 角色
  @override
  Future<void> applyHealing(GameContext context, int amount, {bool? noWandering = false}) async {
    currentHp += amount;
  }

  Future<void> _playCards(
    GameContext context,
    Map<String, dynamic> data, { 
    required bool dealsDamage,
    bool deferDamageResolution = false,
  }) async {
    final cardSelections = _readCardSelections(data);
    final cards = _resolveCardsFromHand(cardSelections);
    for (final card in cards) {
      if (card.isDisabled) {
        throw StateError('Card ${card.id} is disabled and cannot be played');
      }
    }

    final target = _resolveCardTarget(context, data);
    final resolvedCardIds = cards.map((card) => card.id).toList(growable: false);
    for (final card in cards) {
      final params = Map<String, dynamic>.from(data)
        ..['isReinforced'] = card.isReinforced
        ..['isDisabled'] = card.isDisabled
        ..['resolvedCardId'] = card.id
        ..['resolvedCardIds'] = resolvedCardIds;

      await card.playCard(
        context,
        this,
        target: target,
        params: params,
      );
      hand.remove(card);
    }

    context.eventBus.emit(CardPlayedEvent(context, this, cards, cards.length));
    if (!dealsDamage) {
      return;
    }

    await _prepareAttackCardDamage(
      context,
      data,
      target,
    );
    if (deferDamageResolution) {
      return;
    }
    if (data['_resolvedDiceRoll'] is! DiceRoll) {
      final preparedDiceRequest = _readPreparedDiceRequest(data);
      if (preparedDiceRequest == null) {
        throw StateError('Prepared attackCard dice request is missing');
      }
      final diceRoll = await _resolveDice(
        context,
        preparedDiceRequest,
      );
      data['_resolvedDiceRequest'] = diceRoll.request;
      data['_resolvedDiceRoll'] = diceRoll;
    }
    _materializePreparedAttackCardDamage(data);
    await _applyPreparedAttackCardDamage(context, data);
  }

  Future<void> _prepareAttackCardDamage(
    GameContext context,
    Map<String, dynamic> data,
    CharacterTarget originalTarget,
  ) async {
    final preparedDiceRequest =
        _readPreparedDiceRequest(data) ??
        DiceRequest(
          requestId: _buildDamageDiceRequestId(data),
          source: CharacterTarget(this),
          target: originalTarget,
          sides: _readAttackDiceSides(data),
          forcedResult: _readOptionalForcedDiceResult(data),
          reason: DiceRollReason.attackDamage,
          relatedActionId: _readPendingActionId(data),
          payload: {
            'actionType': ActionType.attackCard.name,
            'characterId': id,
            'targetId': originalTarget.character.id,
          },
        );
    final resolvedBaseDamage = attack > originalTarget.character.defense
        ? attack - originalTarget.character.defense
        : 5 + attack ~/ 10;
    data['_resolvedTargetId'] = originalTarget.character.id;
    data['_resolvedDiceRequest'] = preparedDiceRequest;
    data['_resolvedBaseDamage'] = resolvedBaseDamage;
    if (data['_resolvedDiceRoll'] is DiceRoll) {
      _materializePreparedAttackCardDamage(data);
    }
  }

  Future<void> _applyPreparedAttackCardDamage(
    GameContext context,
    Map<String, dynamic> data,
  ) async {
    final resolvedTarget = _resolvePreparedDamageTarget(context, data);
    final preparedDamage = _readPreparedDamage(data);
    final beforeDamageEvent = BeforeDamageEvent(
      context,
      CharacterTarget(this),
      resolvedTarget,
      preparedDamage,
    );
    context.eventBus.emit(beforeDamageEvent);

    final resolvedSource = beforeDamageEvent.source;
    final finalTarget = beforeDamageEvent.target;
    final resolvedDamage = beforeDamageEvent.damage;
    context.eventBus.emit(
      DamageDealtEvent(
        context,
        resolvedSource,
        finalTarget,
        resolvedDamage,
      ),
    );
    context.eventBus.emit(
      AfterDamageEvent(
        context,
        resolvedSource,
        finalTarget,
        resolvedDamage,
      ),
    );
  }

  Future<DiceRoll> _resolveDice(
    GameContext context,
    DiceRequest request,
  ) async {
    final beforeDiceEvent = BeforeDiceEvent(context, request);
    context.eventBus.emit(beforeDiceEvent);

    final resolvedRequest = beforeDiceEvent.request;
    if (resolvedRequest.sides <= 0) {
      throw StateError('Dice sides must be greater than zero');
    }

    final rawResult = await rollDice(context, resolvedRequest.sides);
    final forcedResult = _readForcedDiceResult(resolvedRequest);
    final finalResult = forcedResult ?? rawResult;
    final initialRoll = DiceRoll(
      request: resolvedRequest,
      rawResult: rawResult,
      finalResult: finalResult,
      damageMultiplier: _damageMultiplierFromDiceResult(finalResult),
      wasForced: forcedResult != null,
      wasRerolled: false,
      history: [
        rawResult,
        if (forcedResult != null && forcedResult != rawResult) finalResult,
      ],
      payload: Map<String, dynamic>.from(resolvedRequest.payload),
    );

    final afterDiceEvent = AfterDiceEvent(
      context,
      resolvedRequest,
      initialRoll,
    );
    context.eventBus.emit(afterDiceEvent);

    var resolvedRoll = afterDiceEvent.roll;
    if (!identical(resolvedRoll.request, afterDiceEvent.request)) {
      resolvedRoll = resolvedRoll.copyWith(request: afterDiceEvent.request);
    }

    context.eventBus.emit(
      DiceResolvedEvent(
        context,
        afterDiceEvent.request,
        resolvedRoll,
      ),
    );
    return resolvedRoll;
  }

  String _buildDamageDiceRequestId(Map<String, dynamic> data) {
    final pendingActionId = _readPendingActionId(data);
    if (pendingActionId != null && pendingActionId.isNotEmpty) {
      return '${pendingActionId}_damage_dice';
    }
    return 'dice_${id}_${DateTime.now().microsecondsSinceEpoch}';
  }

  String? _readPendingActionId(Map<String, dynamic> data) {
    final rawActionId = data['_pendingActionId'];
    if (rawActionId is String && rawActionId.isNotEmpty) {
      return rawActionId;
    }
    return null;
  }

  int _readAttackDiceSides(Map<String, dynamic> data) {
    final rawSides = data['diceSides'];
    if (rawSides == null) {
      return 6;
    }
    if (rawSides is! int || rawSides <= 0) {
      throw StateError('diceSides must be a positive integer');
    }
    return rawSides;
  }

  int? _readOptionalForcedDiceResult(Map<String, dynamic> data) {
    final rawForcedResult = data['forcedResult'];
    if (rawForcedResult == null) {
      return null;
    }
    if (rawForcedResult is! int || rawForcedResult < 1) {
      throw StateError('forcedResult must be a positive integer');
    }
    return rawForcedResult;
  }

  int? _readForcedDiceResult(DiceRequest request) {
    final rawForcedResult = request.forcedResult;
    if (rawForcedResult == null) {
      return null;
    }
    if (rawForcedResult < 1 || rawForcedResult > request.sides) {
      throw StateError('forcedResult must be an integer between 1 and ${request.sides}');
    }
    return rawForcedResult;
  }

  CharacterTarget _resolvePreparedDamageTarget(
    GameContext context,
    Map<String, dynamic> data,
  ) {
    final rawTargetId = data['targetId'] ?? data['_resolvedTargetId'];
    if (rawTargetId is! String || rawTargetId.isEmpty) {
      throw StateError('Prepared attackCard damage requires a resolved targetId');
    }
    final targetCharacter = context.getCharacterById(rawTargetId);
    if (targetCharacter == null) {
      throw StateError('Target character $rawTargetId not found');
    }
    return CharacterTarget(targetCharacter);
  }

  Damage _readPreparedDamage(Map<String, dynamic> data) {
    final rawDamage = data['_resolvedDamage'];
    if (rawDamage is! Damage) {
      throw StateError('Prepared attackCard damage is missing');
    }
    return rawDamage;
  }

  DiceRequest? _readPreparedDiceRequest(Map<String, dynamic> data) {
    final rawDiceRequest = data['_resolvedDiceRequest'];
    if (rawDiceRequest == null) {
      return null;
    }
    if (rawDiceRequest is! DiceRequest) {
      throw StateError('Prepared attackCard dice request is invalid');
    }
    return rawDiceRequest;
  }

  void _materializePreparedAttackCardDamage(Map<String, dynamic> data) {
    final preparedDiceRoll = data['_resolvedDiceRoll'];
    if (preparedDiceRoll is! DiceRoll) {
      throw StateError('Prepared attackCard dice roll is missing');
    }
    final resolvedBaseDamage = data['_resolvedBaseDamage'];
    if (resolvedBaseDamage is! int) {
      throw StateError('Prepared attackCard base damage is missing');
    }
    data['_resolvedDamage'] = Damage(
      (resolvedBaseDamage * preparedDiceRoll.damageMultiplier).round(),
      DamageType.physical,
      DamageSource.action,
      preparedDiceRoll.finalResult,
    );
  }

  double _damageMultiplierFromDiceResult(int diceResult) {
    return diceResult.toDouble();
  }

  List<PropCard> _resolveCardsFromHand(List<_CardSelection> requests) {
    final seenHandIndices = <int>{};
    return requests.map((r) {
      if (r.handIndex != null) {
        if (!seenHandIndices.add(r.handIndex!)) {
          throw StateError('handIndex ${r.handIndex} is selected more than once');
        }
      }
      return _resolveSingleCardFromHand(r);
    }).toList();
  }

  PropCard _resolveSingleCardFromHand(_CardSelection request) {
    final cardId = request.cardId;
    final handIndex = request.handIndex;

    if (handIndex != null) {
      if (handIndex < 0 || handIndex >= hand.length) {
        throw StateError('handIndex $handIndex is out of range');
      }
      final card = hand[handIndex];
      if (card.id != cardId) {
        throw StateError('Card at handIndex $handIndex is ${card.id}, not $cardId');
      }
      return card;
    }

    final card = hand.cast<PropCard?>().firstWhere(
      (c) => c!.id == cardId,
      orElse: () => null,
    );
    if (card == null) {
      throw StateError('Card $cardId not found in character hand');
    }
    return card;
  }

  CharacterTarget _resolveCardTarget(
    GameContext context,
    Map<String, dynamic> data,
  ) {
    final rawTargetId = data['targetId'];
    if (rawTargetId == null) {
      throw StateError('targetId cannot be null');
    }
    if (rawTargetId is! String || rawTargetId.isEmpty) {
      throw StateError('targetId must be a non-empty string when provided');
    }

    final targetCharacter = context.getCharacterById(rawTargetId);
    if (targetCharacter == null) {
      throw StateError('Target character $rawTargetId not found');
    }
    return CharacterTarget(targetCharacter);
  }

  int? _readOptionalHandIndex(Map<String, dynamic> data) {
    final rawHandIndex = data['handIndex'];
    if (rawHandIndex == null) {
      return null;
    }
    if (rawHandIndex is! int) {
      throw StateError('handIndex must be an integer');
    }
    return rawHandIndex;
  }

  List<_CardSelection> _readCardSelections(Map<String, dynamic> data) {
    final rawCardSelections = data['cardSelections'];
    if (rawCardSelections is! List) {
      throw StateError('playCard action requires cardSelections as a list');
    }
    if (rawCardSelections.isEmpty) {
      throw StateError('playCard action requires at least one card selection');
    }

    return rawCardSelections.map((rawSelection) {
      if (rawSelection is! Map) {
        throw StateError('Each card selection must be an object');
      }
      final selection = Map<String, dynamic>.from(rawSelection);
      return _CardSelection(
        cardId: _readCardIdValue(selection['cardId']),
        handIndex: _readOptionalHandIndex(selection),
      );
    }).toList();
  }

  String _readCardIdValue(dynamic rawCardId) {
    if (rawCardId is! String || rawCardId.isEmpty) {
      throw StateError('playCard action requires a non-empty cardId');
    }
    return rawCardId;
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

class _CardSelection {
  final String cardId;
  final int? handIndex;

  const _CardSelection({
    required this.cardId,
    this.handIndex,
  });
}

class CharacterFactoryCreated extends BaseCharacter {
  CharacterFactoryCreated(super.id, super.templateId, super.raceId, super.tags, super.traits, super.skills);

  factory CharacterFactoryCreated.fromJson(Map<String, dynamic> json) {
    final tags = (json['tags'] as List).cast<String>().map((id) => CharacterTag.values.byName(id)).toSet();
    final traits = (json['traits'] as List).cast<String>().map(traitReg.create).toList();
    final skills = (json['skills'] as List?)?.cast<String>().map(skillReg.create).toList()??[];
    return CharacterFactoryCreated(
      json['id'] as String,
      json['template'] as String,
      json['race'] as String,
      tags,
      traits,
      skills
    );
  }
}

class CharacterDefenV extends BaseCharacter {  
  CharacterDefenV():super(CharacterId.defen5.id, TemplateId.defen5.id, RaceId.machina.id,
    {CharacterTag.defense, CharacterTag.survive},[],[]);

  @override
  void registerListeners(EventBus bus) {
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
    CharacterId.empty.id: [TemplateId.empty.id, RaceId.empty.id]
  };

  String getTemplateId(String id) => characters[id] == null ? TemplateId.empty.id: characters[id]![0];
  String getRaceId(String id) => characters[id] == null ? RaceId.empty.id: characters[id]![1];
}
