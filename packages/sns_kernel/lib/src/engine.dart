import 'dart:collection';
import 'dart:convert';

import 'package:sns_kernel/src/ai/decision_context.dart';
import 'package:sns_kernel/src/attack_packet.dart';
import 'package:sns_kernel/src/combat_statistics.dart';
import 'package:sns_kernel/src/commands.dart';
import 'package:sns_kernel/src/damage_amounts.dart';
import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/dice.dart';
import 'package:sns_kernel/src/duel.dart';
import 'package:sns_kernel/src/match_statistics.dart';
import 'package:sns_kernel/src/mechanisms/action_recording_module.dart';
import 'package:sns_kernel/src/mechanisms/buddy_block_module.dart';
import 'package:sns_kernel/src/mechanisms/card_content_module.dart';
import 'package:sns_kernel/src/mechanisms/damage_resource_module.dart';
import 'package:sns_kernel/src/mechanisms/damage_roll_choice_module.dart';
import 'package:sns_kernel/src/mechanisms/decree_module.dart';
import 'package:sns_kernel/src/mechanisms/dream_craft_module.dart';
import 'package:sns_kernel/src/mechanisms/fruit_attack_module.dart';
import 'package:sns_kernel/src/mechanisms/mental_gate_module.dart';
import 'package:sns_kernel/src/mechanisms/nightmare_module.dart';
import 'package:sns_kernel/src/mechanisms/prey_module.dart';
import 'package:sns_kernel/src/mechanisms/reroll_module.dart';
import 'package:sns_kernel/src/mechanisms/resource_reserve_module.dart';
import 'package:sns_kernel/src/mechanisms/runtime.dart';
import 'package:sns_kernel/src/mechanisms/skill_borrow_module.dart';
import 'package:sns_kernel/src/mechanisms/skill_copy_module.dart';
import 'package:sns_kernel/src/mechanisms/summon_defense_module.dart';
import 'package:sns_kernel/src/mechanisms/support_stance_module.dart';
import 'package:sns_kernel/src/mechanisms/team_host.dart';
import 'package:sns_kernel/src/mechanisms/turn_save_module.dart';
import 'package:sns_kernel/src/mechanisms/validator.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/recovery_codec.dart';
import 'package:sns_kernel/src/state.dart';
import 'package:sns_kernel/src/statistics/damage_attribution.dart';
import 'package:sns_kernel/src/statistics/support_scores.dart';
import 'package:sns_kernel/src/testing/scenario_setup.dart';

part 'ability_flow.dart';
part 'ability_log.dart';
part 'ability_options.dart';
part 'ability_preparation.dart';
part 'ai_decisions.dart';
part 'attack_assembly.dart';
part 'attack_duel.dart';
part 'attack_rules.dart';
part 'bound_choices.dart';
part 'card_effects.dart';
part 'card_trait_mechanisms.dart';
part 'choice_provenance.dart';
part 'content_operations.dart';
part 'damage_flow.dart';
part 'dice_flow.dart';
part 'hand_choices.dart';
part 'mechanism_hosts.dart';
part 'natural_durations.dart';
part 'pending_preview.dart';
part 'preview_engine.dart';
part 'query_engine.dart';
part 'query_operations.dart';
part 'query_validation.dart';
part 'public_skill_modules.dart';
part 'recovery_engine.dart';
part 'response_engine.dart';
part 'scenario_initialization.dart';
part 'rule_expressions.dart';
part 'skill_modules.dart';
part 'special_traits.dart';
part 'staged_trait_mechanisms.dart';
part 'statistics_hooks.dart';
part 'status_decay.dart';
part 'status_mark_engine.dart';
part 'trait_actions.dart';
part 'trait_mechanisms.dart';
part 'trigger_engine.dart';
part 'variable_engine.dart';

/// Pure Dart game kernel. It performs no file, network, clock or database IO.
/// Content is fixed for a game's lifetime; all mutable objects belong to state.
final class GameKernel {
  factory GameKernel.restore(
    ContentCatalog catalog,
    Map<String, dynamic> checkpoint,
  ) => KernelRecovery.restore(catalog, checkpoint);

  // Frozen compatibility policy for games created before first-round MP changed.
  bool _firstRoundMpRecovery = false;
  // 0 reproduces the historical ignored `choose.statusQuery` alias.
  int _statusChoiceQueryVersion = 1;
  // 0 freezes historical post-shield damage facts and triggers.
  int _damageAmountVersion = 1;

  final CombatStatistics _statistics = CombatStatistics();
  final int _statisticsRulesVersion;
  final SupportScoreRules _supportScoreRules;
  late final MatchStatistics _performance = MatchStatistics(
    version: _statisticsRulesVersion,
    rules: _supportScoreRules,
  );
  late final MechanismRuntime _modules = _createMechanismModules(this);
  Map<String, Object?> statisticsView({bool includeScores = true}) =>
      _performance.snapshot(
        _statistics.snapshot(),
        state,
        includeScores: includeScores,
      );
  List<RollResult> get diceHistory =>
      List.unmodifiable(state.diceHistory.values);
  List<Map<String, Object?>> diceHistoryView() => [
    for (final roll in diceHistory) roll.toJson(),
  ];
  GameKernel(
    this.catalog,
    this.setup, {
    int Function(int)? randomInt,
    int statisticsRulesVersion = 2,
    SupportScoreRules scoreRules = const SupportScoreRules(),
    this.scenario,
  }) : _randomInt = randomInt,
       _statisticsRulesVersion = statisticsRulesVersion,
       _supportScoreRules = SupportScoreRules.fromJson(scoreRules.toJson()) {
    if (statisticsRulesVersion < 1 || statisticsRulesVersion > 2) {
      throw StateError('Unsupported statistics rules');
    }
    if (rules.actionsPerTurn < 0) {
      throw StateError('Action allowance cannot be negative');
    }
    if (rules.responseTimeoutSeconds <= 0) {
      throw StateError('Response timeout must be positive');
    }
    if (setup.players.isEmpty) {
      throw StateError('At least one player is required');
    }
    if (setup.players.map((p) => p.id).toSet().length != setup.players.length) {
      throw StateError('Player IDs must be unique');
    }
    _checkExecutableContent();
    state = KernelState(
      setup.gameId,
      catalog.version,
      [],
      [],
      [],
      (setup.seed % 2147483646) + 1,
    );
    for (final player in setup.players) {
      final definition = _require(catalog.characters, player.characterId);
      final character = CharacterInstance(
        instanceId: state.id('character'),
        definition: definition,
        template: _require(catalog.templates, definition.templateId),
        race: _require(catalog.races, definition.raceId),
        maxHand: rules.maxHand,
        traits: [
          for (final id in definition.traits)
            TraitInstance(state.id('trait'), _require(catalog.traits, id)),
        ],
        skills: [
          for (final id in definition.skills)
            SkillInstance(state.id('skill'), _require(catalog.skills, id))
              ..revealed = _require(catalog.skills, id).exclusive,
        ],
      );
      character.hp = character.value(Stat.maxHp);
      character.mp = character.mp.clamp(0, character.value(Stat.maxMp));
      character.alive =
          !character.depleted ||
          (!character.defenseLife && character.continuesBattle);
      state.players.add(PlayerInstance(player.id, player.teamId, character));
    }
    for (final id in setup.deck) {
      state.drawPile.add(
        CardInstance(state.id('card'), _require(catalog.cards, id)),
      );
    }
    for (final id in setup.skillPool) {
      final definition = _require(catalog.skills, id);
      if (definition.exclusive) {
        throw StateError('Exclusive skill $id cannot be drawn');
      }
      state.skillPool.add(SkillInstance(state.id('skill'), definition));
    }
    _initializeScenario();
    _resetVariableWindows();
  }

  final Queue<CharacterInstance> _generatedRequests = Queue();
  CharacterInstance? _automaticActor;
  final List<void Function()> _automaticRestores = [];
  int _interactionRulesVersion = 23;
  // Presentation layout is versioned independently of combat timing policies.
  bool _privateRecordViews = true;
  String? _endingAnchorPlayerId;
  Map<String, Object?>? _choiceSourceContext;
  bool _previewMode = false;
  final Set<String> _previewHiddenHands = {};
  final int Function(int)? _randomInt;
  final List<Map<String, Object?>> _recoveryInputs = [];
  final List<Map<String, int>> _recoveryRandom = [];
  List<Map<String, int>>? _replayRandom;
  int _replayCursor = 0;
  final ContentCatalog catalog;
  final GameSetup setup;
  final ScenarioSetup? scenario;
  final Map<String, int> _specialRoundDamage = {};
  final Map<String, int> _defensePacketDamage = {};
  final Set<String> _bonusDrawPending = {};
  _ObservedAction? _observedAction;
  bool _independentDamage = false;
  Map<(EffectValue, String), double> _scheduledValues = const {};
  final Map<String, bool> _attackGuardResults = {};
  final Set<String> _attackGuardReactions = {};
  final Map<String, List<StatusInstance>> _packetGuardStatuses = {};
  final Set<String> _packetConsumedGuards = {};
  final Map<String, int> _packetGuardFlatRemaining = {};
  bool _settlingAttack = false;
  int _packetSettlementDepth = 0;
  final Set<String> _pendingDeaths = {};
  void Function(String)? _choiceContinuation;
  bool _committingPrepared = false;
  void Function()? _preparationCommit;
  final Queue<_PreparedSelection> _preparedSelections = Queue();
  final Map<CardInstance, bool> _temporaryReinforcement = {};
  void Function(RollResult)? _diceContinuation;
  final Map<String, _InterruptibleSkill> _interruptibleSkills = {};
  final Map<String, int> _deferredDeathSkills = {};
  final Queue<(ChooseEffect, void Function(), bool)> _preparedCardChoices =
      Queue();
  final Queue<(SelectOptionEffect, AbilityOption)> _preparedOptions = Queue();
  Map<String, Object?> _abilityLocals = {};
  Map<String, Object?>? _queryRecord;
  int _queryValidationDepth = 0;
  int _recordQueryValidationDepth = 0;
  final Map<ChooseTargets, List<String>> _preparedBindings = {};
  final Map<ChooseCards, List<CardInstance>> _preparedHandCards = {};
  final Map<ChooseObjects, List<Map<String, Object?>>> _preparedObjectChoices =
      {};
  final Map<GenerateChosenCard, (CardDefinition, String?)>
  _preparedGeneratedCards = {};
  final Map<String, _AttackCap> _attackCaps = {};
  int _rolled = 0;
  RollContext? _rollOrigin;
  int _abilityNumber = 0;
  int _discardedCount = 0;
  final Map<String, int> _cardDiscardCounts = {};
  StatusInstance? _effectStatus;
  int _attackDiceFinal = 0;
  int _attackDamage = 0;
  int _attackAdjustment = 0;
  int _attackPowerAdjustment = 0;
  final Map<String, int> _declaredAttackPower = {};
  double _attackEffectMultiplier = 1;
  int _damageDepth = 0;
  int _committedAttackBonus = 0;
  List<CardInstance> _effectCards = const [];
  Map<(ConditionalEffect, String), bool> _conditionSnapshots = const {};
  StatusInstance? _chosenStatus;
  final Set<String> _guardAncestors = {};
  bool _drainingTriggers = false;
  bool _triggerInProgress = false;
  bool _pumpingFlow = false;
  final Queue<void Function()> _flow = Queue();
  int _triggerBudget = 256;
  bool _triggerBudgetExhausted = false;
  final Queue<_TriggerInvocation> _triggerQueue = Queue();
  _TriggerInvocation? _currentTrigger;
  final Set<String> _piercingTargets = {};
  late final KernelState state;
  GameRules get rules => setup.rules;

  T _require<T>(Map<String, T> values, String id) =>
      values[id] ?? (throw StateError('Unknown content definition: $id'));

  void _checkExecutableContent() {
    _checkVariableDefinitions();
    for (final race in catalog.races.values) {
      _checkTriggers(race.counters, race.triggers);
      for (final value in [
        race.initialMpValue,
        race.regenMpValue,
      ].whereType<EffectValue>()) {
        _checkValue(value);
        if (_valueTree(value).any(
          (v) =>
              v.perIntensity ||
              (v.field != null &&
                  ![
                    ValueField.handCount,
                    ValueField.hp,
                    ValueField.maxHp,
                    ValueField.attack,
                    ValueField.defense,
                    ValueField.mp,
                    ValueField.maxMp,
                  ].contains(v.field)),
        )) {
          throw StateError(
            'Race recovery expression requires stable character fields',
          );
        }
      }
    }
    void check(
      List<EffectDefinition> effects, {
      SkillTiming timing = SkillTiming.main,
      bool allowChoices = false,
      bool allowAttackPower = false,
      bool validateBindings = true,
    }) {
      _checkEffects(effects);
      if (validateBindings) _validateNamedResults(effects);
      for (final effect in _walkEffects(effects).whereType<ModifyStat>()) {
        if (_walkEffects(
          effect.onClamp,
        ).any((e) => e is ChooseEffect || e is SelectOptionEffect)) {
          throw StateError('onClamp must remain atomic');
        }
      }
      for (final effect in _walkEffects(effects)) {
        _checkVariableContext(effect, allowEvent: false);
        if ((effect is ChooseEffect ||
                effect is ChooseObjects ||
                effect is ChooseTargets ||
                effect is UseTimeReserve ||
                effect is SelectOptionEffect) &&
            !allowChoices) {
          throw StateError(
            'Interactive choice requires an ability execution frame',
          );
        }
        if (effect is ScheduleEffect) {
          if (effect.after < 0 ||
              (effect.phase != SchedulePhase.turnEnd &&
                  effect.phase != SchedulePhase.roundEnd &&
                  effect.after == 0)) {
            throw StateError('Invalid schedule offset');
          }
          // The outer traversal already checked bindings with their enclosing
          // names. Rechecking a detached child loses captured local operands.
          check(effect.effects, validateBindings: false);
        }
        if (effect is ModifyActionDice) {
          throw StateError('Action dice rewards require tagRewards');
        }
        if ((effect is ModifyAttack && !allowChoices) ||
            (effect is ModifyAttackPower && !allowAttackPower)) {
          throw StateError('Attack adjustments require ordinary card effects');
        }
        if ((effect is DamageEffect && effect.fromStatusSource) ||
            (effect is StealLife && effect.fromStatusSource) ||
            effect is SetCounter ||
            (effect is ConditionalEffect &&
                effect.when is CounterEqualsCondition) ||
            effect is ModifyOwnStatus ||
            (effect is ModifyCooldown && effect.usedSkillOnly) ||
            effect.target == EffectTarget.statusSource ||
            effect.target == EffectTarget.eventSource ||
            effect.target == EffectTarget.eventTarget ||
            _contextValue(effect) != null) {
          throw StateError('Contextual operator requires a trigger');
        }
        if ((effect is SetDiceResult && timing != SkillTiming.diceResponse) ||
            ((effect is CancelCard || effect is RedirectAttack) &&
                timing != SkillTiming.actionResponse) ||
            (effect is CancelSkill && timing != SkillTiming.skillResponse)) {
          throw StateError(
            'Response operator used outside its response timing',
          );
        }
      }
    }

    void checkOnHit(List<EffectDefinition> effects) {
      check(effects);
      for (final effect in effects) {
        if (effect.target != EffectTarget.self &&
            effect.target != EffectTarget.selected) {
          throw StateError('onHit effects must target self or selected');
        }
      }
    }

    for (final mark in catalog.marks.values) {
      if ((mark.playerCountBonus != null &&
              (mark.playerCountBonus! < 0 || mark.maxCount != null)) ||
          (mark.maxCount != null && mark.maxCount! < 1) ||
          (mark.groupLimit != null &&
              (mark.group == null || mark.groupLimit! < 1))) {
        throw StateError('Invalid mark capacity');
      }
    }
    for (final card in catalog.cards.values) {
      if (card.mirrorCardId != null) {
        _require(catalog.cards, card.mirrorCardId!);
      }
      check(card.effects, allowChoices: true, allowAttackPower: card.attacks);
      _checkAttackModifiers(card.attackModifiers);
      checkOnHit(card.onHit);
      for (final id in {
        ...card.attacksWithCardIds,
        ...card.statusStackMultipliers.keys,
      }) {
        _require(catalog.cards, id);
      }
      if (card.statusStackMultipliers.values.any((n) => n < 1 || n > 16)) {
        throw StateError('Invalid card status stack multiplier');
      }
      if (card.mpCost < 0 ||
          (card.diceSides != null && card.diceSides! <= 0) ||
          (card.reinforcedDiceSides != null &&
              card.reinforcedDiceSides! <= 0) ||
          card.defenseMultiplier <= 0 ||
          card.defenseBonus <= -50) {
        throw StateError('Invalid executable card parameters: ${card.id}');
      }
    }
    for (final skill in catalog.skills.values) {
      if (!skill.replayPolicy.damageFactor.isFinite ||
          skill.replayPolicy.damageFactor < 0 ||
          !skill.replayPolicy.healingFactor.isFinite ||
          skill.replayPolicy.healingFactor < 0) {
        throw StateError('Invalid replay factors');
      }
      _checkTriggers(skill.counters, skill.triggers);
      if (skill.passive &&
          (skill.triggers.isEmpty ||
              skill.effects.isNotEmpty ||
              skill.checkpoint != null)) {
        throw StateError('Passive skill requires triggers only');
      }
      if (_walkEffects(skill.effects).any((e) => e is TransferReceivedDamage) &&
          (skill.minTargets != 1 || skill.maxTargets != 1)) {
        throw StateError('Damage transfer requires exactly one target');
      }
      if (skill.preselectAll &&
          (skill.timing != SkillTiming.main ||
              skill.effects.isEmpty ||
              skill.effects.any(
                (e) =>
                    e is! ChooseEffect ||
                    e.kind != ChoiceKind.character ||
                    e.random ||
                    e.chooser != ChoiceChooser.actor ||
                    _walkEffects(e.effects).any(
                      (child) =>
                          child is ChooseEffect ||
                          child is SelectOptionEffect ||
                          child is RollEffect,
                    ),
              ))) {
        throw StateError(
          'Preselected skill requires independent character choices',
        );
      }
      for (final branch in skill.cooldownBranches) {
        if (branch.cooldown < 0) throw StateError('Invalid cooldown branch');
        _checkChoiceCondition(branch.when);
        check([ConditionalEffect(branch.when, const [])]);
      }
      _checkChoiceCondition(skill.when);
      _checkChoiceCondition(skill.targetWhen);
      if (skill.when != null) {
        check([ConditionalEffect(skill.when!, const [])]);
      }
      if (skill.targetWhen != null) {
        check([ConditionalEffect(skill.targetWhen!, const [])]);
      }
      if (skill.checkpoint case final rule?) {
        final manualThreshold =
            rule.at == SkillCheckpoint.otherDamageThreshold &&
            skill.anytime &&
            skill.timing == SkillTiming.main;
        if ((!manualThreshold && skill.timing != SkillTiming.settlement) ||
            rule.minimumDamage < 0 ||
            rule.maximumTargetHp < 0 ||
            rule.extraTurns < 1 ||
            rule.extraTurns > 32 ||
            !rule.damageFactor.isFinite ||
            rule.damageFactor < 0 ||
            rule.damageFactor > 1 ||
            rule.shield < 0 ||
            rule.shieldRounds < 0 ||
            rule.restoreHp != null && rule.restoreHp! <= 0) {
          throw StateError('Invalid settlement checkpoint');
        }
      } else if (skill.timing == SkillTiming.settlement && !skill.passive) {
        throw StateError('Settlement skill requires a checkpoint');
      }
      if (skill.numberParameter case final parameter?) {
        if (parameter.markCostId != null) {
          _require(catalog.marks, parameter.markCostId!);
        }
        if (parameter.allowedValues.any(
          (n) => n < parameter.minimum || n > parameter.maximum,
        )) {
          throw StateError('Invalid numeric choices');
        }
        if (skill.timing != SkillTiming.main ||
            parameter.minimum < (parameter.countTargets ? 0 : 1) ||
            parameter.maximum < parameter.minimum ||
            parameter.maximum > 10000 ||
            parameter.lifeCostPerUnit < 0 ||
            parameter.mpCostPerUnit < 0) {
          throw StateError('Invalid number parameter');
        }
      }
      if (skill.lifeCost < 0 ||
          ((skill.beforeAttack || skill.beforeCards) &&
              skill.timing != SkillTiming.main)) {
        throw StateError(
          'Invalid skill life cost or attack preparation timing',
        );
      }
      if (skill.statCosts.values.any((n) => n <= 0)) {
        throw StateError('Invalid stat cost');
      }
      for (final cost in skill.markCosts) {
        _require(catalog.marks, cost.markId);
        if (cost.amount <= 0) throw StateError('Invalid mark cost');
      }
      check(
        skill.effects,
        timing: skill.timing,
        allowChoices:
            skill.timing == SkillTiming.main ||
            skill.timing == SkillTiming.settlement,
      );
      if (skill.lifeCostValue != null) _checkValue(skill.lifeCostValue!);
      if (skill.numberParameter?.maximumValue != null) {
        _checkValue(skill.numberParameter!.maximumValue!);
      }
      if (skill.cooldownValue != null) {
        _checkValue(skill.cooldownValue!);
        if (_valueTree(skill.cooldownValue!).any(
          (v) =>
              v.perIntensity ||
              (v.field != null &&
                  ![
                    ValueField.mp,
                    ValueField.maxMp,
                    if (skill.numberParameter != null) ValueField.inputNumber,
                    ValueField.hp,
                    ValueField.maxHp,
                    ValueField.attack,
                    ValueField.defense,
                    ValueField.handCount,
                  ].contains(v.field)),
        )) {
          throw StateError('Cooldown expression requires stable actor fields');
        }
      }
      if (skill.mpSurcharge < 0 ||
          skill.mpCost < 0 ||
          skill.cooldown < 0 ||
          skill.minTargets < 0 ||
          skill.maxTargets < skill.minTargets) {
        throw StateError('Invalid executable skill parameters: ${skill.id}');
      }
    }
    for (final status in catalog.statuses.values) {
      if (status.attackDiceSides != null && status.attackDiceSides! <= 0) {
        throw StateError('Invalid status attack dice sides');
      }
      if (status.cardMpCap != null && status.cardMpCap! < 0) {
        throw StateError('Invalid card MP cap');
      }
      if (status.active != null) {
        if (status.active!.lifeCostPerIntensity < 0) {
          throw StateError('Invalid status cost');
        }
        check(status.active!.effects);
      }
      for (final guard in status.damageGuards) {
        _checkGuardRoll(guard);
        _checkChoiceCondition(guard.when);
        for (final id in guard.traitBlockExceptions) {
          _require(catalog.statuses, id);
        }
        if (guard.factor < 0 || guard.consumeStacks < 0) {
          throw StateError('Invalid damage guard');
        }
        check(guard.effects, allowChoices: true);
      }
      checkOnHit(status.onHit);
      check(status.turnStart);
      check(status.turnEnd);
      _checkTriggers(status.counters, status.triggers, status: true);
      if (status.opposingStatusId != null) {
        final opposite = _require(catalog.statuses, status.opposingStatusId!);
        if (opposite.id == status.id ||
            opposite.opposingStatusId != status.id) {
          throw StateError(
            'Opposing statuses must reference each other: ${status.id}',
          );
        }
      }
    }
    _checkAttackDiceSequences();
    for (final trait in catalog.traits.values) {
      _checkCardTraitRules(trait);
      if ((trait.rerollOfferCost != null && trait.rerollOfferCost! < 0) ||
          !trait.incomingDamageMultiplier.isFinite ||
          trait.incomingDamageMultiplier < 0 ||
          (trait.battleContinuationThroughRound != null &&
              trait.battleContinuationThroughRound! < 1) ||
          (trait.continuationRecoverySides != null &&
              (trait.continuationRecoverySides! < 1 ||
                  !trait.battleContinuation ||
                  trait.continuationRecoverySuccess.isEmpty ||
                  trait.continuationRecoverySuccess.any(
                    (n) => n < 1 || n > trait.continuationRecoverySides!,
                  )))) {
        throw StateError('Invalid trait mechanism parameters');
      }
      if (trait.attackDiceGrowth case final growth?) {
        final variable = _require(catalog.variables, growth.variable);
        if (growth.threshold < 1 ||
            variable.type != VariableType.number ||
            variable.scope != VariableScope.owner ||
            variable.reset != CounterReset.never) {
          throw StateError('Invalid attack dice growth');
        }
      }
      for (final entry in trait.cardEffectOverrides.entries) {
        if (entry.key.isEmpty) {
          throw StateError('Invalid card override identifier');
        }
        check(entry.value);
      }
      if (trait.attackDiceBonusValue != null) {
        check([ModifyStat(Stat.attack, 0, value: trait.attackDiceBonusValue)]);
      }
      for (final entry in trait.statusGainMultipliers.entries) {
        _require(catalog.statuses, entry.key);
        if (entry.value < 1 || entry.value > 16) {
          throw StateError('Invalid status gain multiplier');
        }
      }

      _checkChoiceCondition(trait.incomingAttackTargetWhen);
      _checkAttackModifiers(trait.attackModifiers);
      if (trait.actionMpDiscount < 0) {
        throw StateError('Invalid action discount');
      }
      for (final guard in trait.damageGuards) {
        _checkGuardRoll(guard);
        _checkChoiceCondition(guard.when);
        for (final id in guard.traitBlockExceptions) {
          _require(catalog.statuses, id);
        }
        if (guard.factor < 0 || guard.once || guard.consumeStacks != 0) {
          throw StateError('Invalid trait damage guard');
        }
        check(guard.effects, allowChoices: true);
      }
      for (final id in trait.immuneStatuses) {
        _require(catalog.statuses, id);
      }
      for (final r in trait.attackStatuses) {
        _require(catalog.statuses, r.statusId);
      }
      for (final id in trait.endMarkChoices) {
        _require(catalog.marks, id);
      }
      for (final bonus in trait.markStatBonuses) {
        _require(catalog.marks, bonus.markId);
      }
      for (final bonus in trait.statusStatBonuses) {
        if (bonus.allStatuses.isEmpty) {
          throw StateError('Status bonus needs conditions');
        }
        for (final id in bonus.allStatuses) {
          _require(catalog.statuses, id);
        }
      }
      if (trait.defaultAttackDiceSides != null &&
          (trait.defaultAttackDiceSides! < 1 ||
              trait.defaultAttackDiceSides! > 1000000)) {
        throw StateError('Invalid default attack dice');
      }
      if (trait.incomingAttack?.finalDamageReductionValue case final value?) {
        check([DamageEffect(0, value: value)]);
      }
      if (trait.openingSkillBonus < 0 || trait.openingSkillBonus > 32) {
        throw StateError('Invalid opening skill bonus');
      }
      if (trait.healingRewriteBlockedBy != null) {
        _checkStatusQuery(trait.healingRewriteBlockedBy!);
      }
      if (trait.damageAura case final aura?) {
        _checkChoiceCondition(aura.when);
        if (!aura.factor.isFinite || aura.factor < 0) {
          throw StateError('Invalid damage aura');
        }
      }
      if (trait.outgoingDuel case final duel?) {
        check(duel.victory);
        check(duel.after);
      }
      void checkAction(TraitAction a, {bool nested = false}) {
        check(a.effects, allowChoices: true);
        for (final cost in a.markCosts) {
          _require(catalog.marks, cost.markId);
          if (cost.amount <= 0) throw StateError('Invalid trait mark cost');
        }
        if (a.options.isNotEmpty &&
            (a.effects.isNotEmpty ||
                a.mpCost != 0 ||
                a.discardCount != 0 ||
                a.markCosts.isNotEmpty ||
                a.markLayers != null ||
                a.markIntensity != null ||
                a.requireFullMp ||
                a.maxUsesPerRound != null ||
                a.extraActions != 0 ||
                a.attackBonus != 0)) {
          throw StateError(
            'Trait option container cannot also define an action',
          );
        }
        if (nested && a.options.isNotEmpty) {
          throw StateError('Nested trait options are not supported');
        }
        for (final option in a.options.entries) {
          if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(option.key) ||
              option.key == 'self' ||
              option.key == 'attack') {
            throw StateError('Invalid trait option ID');
          }
          checkAction(option.value, nested: true);
        }
        if (![
              CounterReset.round,
              CounterReset.personalRound,
            ].contains(a.limitWindow) ||
            a.mpCost < 0 ||
            a.discardCount < 0 ||
            a.extraActions < 0 ||
            a.layersPerMark < 0 ||
            a.intensityPerMark < 0 ||
            a.fallbackLayersPerMark < 0 ||
            (a.maxUsesPerRound != null && a.maxUsesPerRound! < 1) ||
            ((a.markLayers == null) != (a.markIntensity == null))) {
          throw StateError('Invalid trait action');
        }
        if (a.markLayers != null) {
          _require(catalog.marks, a.markLayers!);
          _require(catalog.marks, a.markIntensity!);
        }
      }

      if (trait.active case final a?) checkAction(a);
      if (trait.attackAura case final aura?) {
        if (aura.thresholdReduction < 0 || aura.thresholdReduction > 1024) {
          throw StateError('Invalid strengthened threshold reduction');
        }
        _checkAttackModifiers(aura.attackModifiers);
        checkOnHit(aura.onHit);
      }
      checkOnHit(trait.onHit);
      _checkTriggers(trait.counters, trait.triggers);
    }
  }

  int _openingSkillCount(CharacterInstance actor) =>
      _interactionRulesVersion >= 5 && actor.definition.skills.isNotEmpty
      ? 0
      : (actor.skills.any((s) => s.definition.exclusive)
                ? 0
                : rules.openingSkills) +
            (_blocked(actor, (s) => s.blockTraits)
                ? 0
                : actor.traits.fold<int>(
                    0,
                    (n, t) => n + t.definition.openingSkillBonus,
                  ));

  void start() {
    _start();
    _recoveryInputs.add({'type': 'start'});
  }

  void _start() {
    if (state.phase != GamePhase.created) {
      throw StateError('Game already started');
    }
    if (_interactionRulesVersion >= 5) {
      final innate = catalog.characters.values.expand((c) => c.skills).toSet();
      state.skillPool.removeWhere((s) => innate.contains(s.definition.id));
    }
    final requiredSkills = state.players
        .where((p) => p.character.alive)
        .fold<int>(0, (n, p) => n + _openingSkillCount(p.character));
    final owned = <String, String>{};
    if (rules.enforceSkillUniqueness) {
      for (final player in state.players) {
        for (final skill in player.character.skills) {
          final previous = owned[skill.definition.id];
          if (previous != null && previous != player.id) {
            throw StateError('A skill definition can have only one owner');
          }
          owned[skill.definition.id] = player.id;
        }
      }
    }
    final available = rules.enforceSkillUniqueness
        ? state.skillPool
              .map((s) => s.definition.id)
              .where((id) => !owned.containsKey(id))
              .toSet()
              .length
        : state.skillPool.length;
    if (available < requiredSkills) {
      throw StateError(
        'Opening requires $requiredSkills common skill instances',
      );
    }
    _triggerBudget = 256;
    _triggerBudgetExhausted = false;
    if (rules.shuffleDeck) _shuffle(state.drawPile);
    if (rules.shuffleSkillPool) _shuffle(state.skillPool);
    if (rules.enforceSkillUniqueness) {
      state.skillPool.removeWhere((s) => owned.containsKey(s.definition.id));
    }
    state.phase = GamePhase.opening;
    _event('gameStarted', {
      'contentVersion': catalog.version,
      'rules': {'useLegacyDamageFormula': rules.useLegacyDamageFormula},
    });
    // Round zero is explicitly reverse seat order. Piles draw from their front.
    for (final player in state.players.reversed) {
      final character = player.character;
      if (!character.alive) continue;
      {
        for (var i = 0; i < _openingSkillCount(character); i++) {
          final skill = state.skillPool.removeAt(0);
          if (rules.enforceSkillUniqueness) {
            state.skillPool.removeWhere(
              (s) => s.definition.id == skill.definition.id,
            );
          }
          character.skills.add(skill);
          _event('skillDrawn', {
            'playerId': player.id,
            'actorId': character.instanceId,
            'skillId': skill.definition.id,
            'instanceId': skill.instanceId,
          });
        }
      }
      _draw(character, rules.openingCards);
      if (character.race.initialMpValue != null) {
        character.mp = _amount(
          character.race.initialMp,
          character.race.initialMpValue,
          character,
          character,
        ).clamp(0, character.value(Stat.maxMp));
      }
    }
    _enqueueTrigger(_TriggerFact(TriggerTiming.gameStart));
    _flowSteps([
      _drainTriggers,
      () {
        state.round = 1;
        state.turn = 1;
        _beginRound();
      },
      () {
        if (!_checkVictory()) _enterPlayableTurn();
      },
    ]);
    _sampleStatistics();
    state.version++;
  }

  /// Commands contain choices only. No client-supplied effect or state patches.
  /// Rejected commands do not consume resources, RNG or the state version.
  void submit(KernelCommand command, {int? expectedVersion}) {
    _withCommandNumber(
      command,
      () => _submit(command, expectedVersion: expectedVersion),
    );
    _recoveryInputs.add({
      'type': 'command',
      'expectedVersion': expectedVersion,
      'command': KernelRecoveryCodec.command(command),
    });
  }

  T _withCommandNumber<T>(KernelCommand command, T Function() action) {
    if (_interactionRulesVersion < 23 || command is! UseSkillCommand) {
      return action();
    }
    return _withSkillNumber(command.number, action);
  }

  T _withSkillNumber<T>(int? number, T Function() action) {
    if (_interactionRulesVersion < 23) return action();
    final previous = _abilityNumber;
    _abilityNumber = number ?? 0;
    try {
      return action();
    } finally {
      _abilityNumber = previous;
    }
  }

  void _submit(KernelCommand command, {int? expectedVersion}) {
    if (state.phase == GamePhase.created) {
      throw StateError('Game has not started');
    }
    if (state.finished) throw StateError('Game already finished');
    final pending = state.pending;
    final responseId = switch (command) {
      PassCommand() => command.pendingActionId,
      BeginResponseCommand() => command.pendingActionId,
      RespondCardCommand() => command.pendingActionId,
      RecordActionCommand() => command.pendingActionId,
      UseSkillCommand() => command.pendingActionId,
      _ => null,
    };
    // Choices are collected without changing the board: peers may submit the
    // opening snapshot concurrently. Window identity still fences stale input.
    final concurrentResponse =
        pending != null &&
        responseId == pending.windowId &&
        expectedVersion != null &&
        expectedVersion >= pending.openedVersion &&
        expectedVersion <= state.version;
    if (expectedVersion != null &&
        expectedVersion != state.version &&
        !concurrentResponse) {
      throw StateError('Version conflict: expected ${state.version}');
    }
    final player = _player(command.playerId);
    if (!player.character.alive) throw StateError('Player is dead');
    if (state.choice == null && !_triggerInProgress && _flow.isEmpty) {
      _triggerBudget = 256;
      _triggerBudgetExhausted = false;
    }
    if (state.preparation != null &&
        (state.choice == null || command is CancelAbilityCommand)) {
      _submitPreparation(player, command);
    } else if (state.choice != null) {
      _submitChoice(player, command);
    } else if (state.pending != null) {
      _submitResponse(player, command);
    } else {
      final anytimeSkill =
          command is UseSkillCommand &&
          command.pendingActionId == null &&
          _executionSkill(
            player.character,
            _ownedModuleSkill(player.character, command.skillInstanceId),
            command,
          ).definition.anytime;
      final anytimeTrait =
          command is ActivateTraitCommand &&
          player.character.traits.any(
            (t) =>
                t.instanceId == command.traitInstanceId &&
                t.definition.active?.anytime == true,
          );
      if (player.id != state.activePlayer.id &&
          !anytimeSkill &&
          !anytimeTrait) {
        throw StateError('Not the active player');
      }
      if (state.phase == GamePhase.discard) {
        if (command is! DiscardCommand) throw StateError('Discard required');
        _discard(player.character, command.cardInstanceIds);
      } else {
        if (state.phase != GamePhase.action) {
          throw StateError('Not an action window');
        }
        switch (command) {
          case AttackCommand():
            _attack(player, command);
          case PlayCardsCommand():
            _playCards(player, command);
          case UseSkillCommand():
            _useSkill(player, command);
          case EndTurnCommand():
            _endTurn();
          case DiscardCommand():
            throw StateError('Not a discard window');
          case ActivateTraitCommand():
            _activateTrait(player.character, command);
          case ActivateStatusCommand():
            _activateStatus(player.character, command.statusInstanceId);
          case ConfirmAbilityCommand():
          case CancelAbilityCommand():
            throw StateError('Not a preparation window');
          case ChooseCommand():
            throw StateError('Not a choice window');
          case RecordActionCommand():
          case RespondCardCommand():
          case BeginResponseCommand():
          case PassCommand():
            throw StateError('Not a response window');
        }
      }
    }
    _drainTriggers();
    _pumpFlow();
    _sampleStatistics();
    state.version++;
  }

  /// Trusted application deadline transition. Never accepts a client clock.
  bool expireResponse(String windowId) {
    final changed = _expireResponse(windowId);
    if (changed) _recoveryInputs.add({'type': 'expire', 'windowId': windowId});
    return changed;
  }

  bool _expireResponse(String windowId) {
    final pending = state.pending;
    if (pending == null || pending.windowId != windowId || state.finished) {
      return false;
    }
    if (_interactionRulesVersion >= 9 && pending.responseExpired) return false;
    _triggerBudget = 256;
    _triggerBudgetExhausted = false;
    final timedOut = pending.waitingPlayerIds
        .where(
          (id) =>
              _interactionRulesVersion < 9 ||
              !pending.responseSelections.containsKey(id),
        )
        .toList();
    if (_interactionRulesVersion >= 9) pending.responseExpired = true;
    for (final id in timedOut) {
      pending.submissions[id] = PassCommand(id, windowId);
    }
    _event('responseWindowExpired', {
      'windowId': windowId,
      'playerIds': List<String>.unmodifiable(timedOut),
    });
    _finishResponsesIfReady();
    _drainTriggers();
    state.version++;
    return true;
  }

  void _checkHostileAttackTarget(
    PlayerInstance actor,
    CharacterInstance target,
  ) {
    // Older recorded games retain their original validation during recovery.
    if (_interactionRulesVersion >= 19 &&
        state.players.any(
          (p) => p.character == target && p.teamId == actor.teamId,
        )) {
      throw StateError('Cannot attack teammate');
    }
  }

  void _attack(
    PlayerInstance player,
    AttackCommand command, {
    bool validateOnly = false,
    void Function(int)? costQuote,
  }) {
    final actor = player.character;
    if (actor.actionsRemaining <= 0 && !identical(_automaticActor, actor)) {
      throw StateError('No actions remaining');
    }
    if (_blocked(actor, (s) => s.blockAttack)) {
      throw StateError('Attack is blocked');
    }
    final target = _target(command.targetId);
    if (target == actor) throw StateError('Cannot attack self');
    _checkHostileAttackTarget(player, target);
    _checkArmedAttackTarget(actor, [target.instanceId]);
    final cost = identical(_automaticActor, actor)
        ? 0
        : _actionCost(actor, rules.normalAttackCost) +
              _targetSurcharge([target.instanceId]);
    _checkMp(actor, cost, allowNegative: false);
    costQuote?.call(actor.noMp ? 0 : cost);
    if (validateOnly) return;
    if (_offerTimeReserve(actor, () => _attack(player, command))) return;
    if (_mentalActionGate(actor, () => _attack(player, command))) return;
    if (!identical(_automaticActor, actor)) {
      _scoreActionFee(
        actor,
        rules.normalAttackCost,
        cost - _targetSurcharge([target.instanceId]),
      );
    }
    if (!identical(_automaticActor, actor)) _commitActionAllowance(actor);
    _payMp(actor, cost);
    _rewardTargetFees([target.instanceId]);
    _beginObservedAction(
      actor,
      [target.instanceId],
      const [],
      paidMp: actor.noMp ? 0 : cost,
    );
    _event('actionCommitted', {'actorId': actor.instanceId});
    _assembleAttack(player.id, [target.instanceId], const [], (
      actionId,
      cards,
    ) {
      void finish() {
        _flowSteps([
          _drainTriggers,
          () {
            _checkActionFailure(actor, ({required bool failed}) {
              if (!actor.alive || !target.alive || failed) {
                _returnAttackCards(actionId);
                _afterResolution();
                return;
              }
              _declareAttack(
                player.id,
                [target.instanceId],
                cards,
                actionId: actionId,
              );
            });
          },
        ]);
      }

      if (cards.isNotEmpty) {
        _recordPlayedCards(
          actor,
          [target.instanceId],
          cards,
          handLossCount: 0,
          actionId: actionId,
          complete: finish,
        );
      } else {
        finish();
      }
    });
  }

  void _playCards(
    PlayerInstance player,
    PlayCardsCommand command, {
    bool validateOnly = false,
    void Function(int)? costQuote,
  }) {
    final actor = player.character;
    if (actor.actionsRemaining <= 0 && !identical(_automaticActor, actor)) {
      throw StateError('No actions remaining');
    }
    if (_blocked(actor, (s) => s.blockCards)) {
      throw StateError('Cards are blocked');
    }
    final cards = _selectCards(actor, command.cardInstanceIds);
    if (_interactionRulesVersion >= 2 &&
        _interactionRulesVersion < 9 &&
        cards.any((c) => !c.definition.isLimited) &&
        cards.any((c) => c.definition.isLimited && !_companionCard(actor, c))) {
      throw StateError('Cannot mix limited and regular cards');
    }
    if (cards.any(
      (card) =>
          card.definition.tags.any((tag) => _cardTagRestricted(actor, tag)),
    )) {
      throw StateError('Card tag is restricted');
    }
    final attackIds = cards
        .where((c) => c.definition.attacks)
        .map((c) => c.definition.id)
        .toSet();
    final constraintSuppressesAttack =
        _interactionRulesVersion >= 9 &&
        cards.any((c) => c.definition.isLimited && !_companionCard(actor, c));
    final attacks =
        !constraintSuppressesAttack &&
        cards.every(
          (c) =>
              c.definition.attacks ||
              c.definition.attacksWithCardIds.any(attackIds.contains) ||
              (attackIds.isNotEmpty && _companionCard(actor, c)),
        );
    if (attacks &&
        _blocked(actor, (s) => s.blockAttack || s.blockAttackCards)) {
      throw StateError('Attack is blocked');
    }
    final executionCards = attacks
        ? _projectCardGroup(actor, cards)
        : cards.map((c) => _effectiveCard(actor, c)).toList();
    final effects = [
      for (final card in executionCards)
        ..._cardEffectsFor(
          actor,
          card,
          includeNonAttackOnHit: constraintSuppressesAttack,
        ),
    ];
    final needsTarget =
        attacks ||
        effects.any((e) => e.target == EffectTarget.selected) ||
        _tagNeedsTarget(actor, cards);
    if (needsTarget && command.targetId == null) {
      throw StateError('Target is required');
    }
    final targets = command.targetId == null
        ? <String>[]
        : [_target(command.targetId!).instanceId];
    if (attacks && targets.single == actor.instanceId) {
      throw StateError('Cannot attack self');
    }
    if (attacks) _checkHostileAttackTarget(player, _target(targets.single));
    if (attacks) _checkArmedAttackTarget(actor, targets);
    _checkEffects(effects);
    final pendingReinforcement = actor.statuses.any(
      (s) => s.definition.reinforceFirstCard,
    );
    final defenseBonus = executionCards.fold(
      0,
      (sum, card) =>
          sum +
          _effectiveCard(actor, card).definition.defenseBonus *
              ((pendingReinforcement && identical(card, cards.first))
                  ? 2
                  : _cardScale(card)),
    );
    if (defenseBonus <= -50) {
      throw StateError('Combined defense reduction exceeds formula domain');
    }
    _validateAbilityTargets(effects, targets);
    final freeTags = _blocked(actor, (s) => s.blockTraits)
        ? <String>{}
        : actor.traits.expand((t) => t.definition.freeCardTags).toSet();
    final rawCost = cards.fold(
      0,
      (sum, card) =>
          sum +
          (card.definition.tags.any(freeTags.contains)
              ? 0
              : card.definition.mpCost +
                    card.definition.actionCostBonus *
                        (_interactionRulesVersion >= 10 &&
                                pendingReinforcement &&
                                identical(card, cards.first)
                            ? 2
                            : _interactionRulesVersion >= 10
                            ? _cardScale(card)
                            : 1)),
    );
    var discount = 0;
    if (!_blocked(actor, (s) => s.blockTraits) &&
        actor.traits.any((t) => t.definition.cardMaxTagDiscount)) {
      final maximumTags = cards.fold(
        0,
        (n, card) =>
            card.definition.tags.length > n ? card.definition.tags.length : n,
      );
      discount = maximumTags > 0 ? maximumTags - 1 : 0;
    }
    discount += _actionDiscount(actor);
    var cost = rawCost > discount ? rawCost - discount : 0;
    for (final status in actor.statuses) {
      final cap = status.definition.cardMpCap;
      if (cap != null && cost > cap) cost = cap;
    }
    cost += _targetSurcharge(targets);
    if (identical(_automaticActor, actor)) cost = 0;
    _checkMp(actor, cost, allowNegative: false);
    costQuote?.call(actor.noMp ? 0 : cost);
    if (validateOnly) {
      if (!_leadingSelectionAvailable(actor, targets, effects)) {
        throw StateError('No available leading selection');
      }
      return;
    }
    if (_prepareAbility(
      actor,
      effects,
      targets,
      cost,
      () => _playCards(player, command),
      input: {
        'kind': 'playCards',
        'cardInstanceIds': command.cardInstanceIds,
        'targetIds': targets,
        'actionCost': 1,
      },
    )) {
      return;
    }
    if (_offerTimeReserve(actor, () => _playCards(player, command))) return;
    if (_mentalActionGate(actor, () => _playCards(player, command))) return;
    if (!identical(_automaticActor, actor)) {
      _scoreActionFee(
        actor,
        rawCost,
        cost - _targetSurcharge(targets),
        cards: true,
      );
    }
    if (!identical(_automaticActor, actor)) _commitActionAllowance(actor);
    _payMp(actor, cost);
    _rewardTargetFees(targets);
    if (actor.cardLifeCost > 0 && !identical(_automaticActor, actor)) {
      actor.hp -= cards.length * actor.cardLifeCost;
      _event('actionLifePaid', {
        'actorId': actor.instanceId,
        'amount': cards.length * actor.cardLifeCost,
      });
      _normalize(actor);
    }
    final reinforcement = actor.statuses
        .where((s) => s.definition.reinforceFirstCard)
        .firstOrNull;
    if (reinforcement != null) {
      _temporaryReinforcement.putIfAbsent(
        cards.first,
        () => cards.first.reinforced,
      );
      cards.first.reinforced = true;
      _consumeStatus(actor, reinforcement);
      _event('cardReinforced', {
        'actorId': actor.instanceId,
        'instanceId': cards.first.instanceId,
      });
    }
    // Declaration commits the physical cards once, even when later cancelled.
    for (final card in cards) {
      actor.hand.remove(card);
      state.discardPile.add(card);
    }
    _beginObservedAction(actor, targets, cards, paidMp: actor.noMp ? 0 : cost);
    _event('actionCommitted', {'actorId': actor.instanceId});
    void resolve(String? actionId, List<CardInstance> played) {
      void finish() {
        _flowSteps([
          _drainTriggers,
          () {
            _checkActionFailure(actor, ({required bool failed}) {
              if (!actor.alive || failed) {
                if (actionId != null) _returnAttackCards(actionId);
                _afterResolution();
                return;
              }
              if (attacks) {
                _declareAttack(player.id, targets, played, actionId: actionId!);
              } else {
                _openResponse(
                  PendingResolution(
                    id: state.id('action'),
                    kind: PendingKind.cards,
                    constraintAction: constraintSuppressesAttack,
                    actorId: player.id,
                    targets: targets,
                    cards: played,
                  ),
                );
              }
            });
          },
        ]);
      }

      _recordPlayedCards(
        actor,
        targets,
        played,
        handLossCount: cards.length,
        actionId: actionId,
        complete: finish,
      );
    }

    if (attacks) {
      _assembleAttack(player.id, targets, executionCards, resolve);
    } else {
      resolve(null, executionCards);
    }
  }

  void _recordPlayedCards(
    CharacterInstance actor,
    List<String> targets,
    List<CardInstance> cards, {
    required int handLossCount,
    bool response = false,
    String? actionId,
    required void Function() complete,
  }) {
    if (!response && _observedAction?.actor == actor) {
      _observedAction!.cards = List.of(cards);
    }
    final recorded = cards
        .where((c) => !_preyModule.wasActivated(actionId, c.instanceId))
        .toList();
    if (recorded.isEmpty) {
      complete();
      return;
    }
    _event('cardsPlayed', {
      'actionId': actionId,
      'attack': !response && actionId != null,
      'actorId': actor.instanceId,
      'targets': List<String>.unmodifiable(targets),
      if (targets.length == 1) 'targetId': targets.single,
      'handLossCount': handLossCount,
      'cards': List<String>.unmodifiable(recorded.map((c) => c.instanceId)),
      'tagCounts': Map<String, int>.unmodifiable({
        for (final tag in recorded.expand((c) => c.definition.tags).toSet())
          tag: recorded.where((c) => c.definition.tags.contains(tag)).length,
      }),
    });
    final steps = <void Function()>[];
    for (final card in recorded) {
      steps.add(
        () => _event('cardPlayed', {
          'actorId': actor.instanceId,
          'cardId': card.definition.id,
          'instanceId': card.instanceId,
          'targets': List<String>.unmodifiable(targets),
          if (targets.length == 1) 'targetId': targets.single,
          'tagCounts': Map<String, int>.unmodifiable({
            for (final tag in card.definition.tags) tag: 1,
          }),
        }),
      );
      steps.add(
        () =>
            _runCardTraitRules(actor, targets, card, recorded, actionId, () {}),
      );
      steps.add(_drainTriggers);
    }
    _flowSteps([...steps, complete]);
  }

  void _declareAttack(
    String playerId,
    List<String> targets,
    List<CardInstance> cards, {
    required String actionId,
  }) {
    final actor = _player(playerId).character;
    var sides = rules.defaultDiceSides;
    if (!_blocked(actor, (s) => s.blockTraits)) {
      sides =
          actor.traits
              .map((t) => t.definition.defaultAttackDiceSides)
              .whereType<int>()
              .firstOrNull ??
          sides;
    }
    final baseDiceSides = sides;
    for (final card in cards) {
      sides = _cardDiceSides(card) ?? sides;
    }
    final diceOverrides = actor.statuses
        .where((s) => s.definition.attackDiceSides != null)
        .toList();
    for (final status in diceOverrides) {
      sides = status.definition.attackDiceSides!;
    }
    if (actor.nextAttackTargetId != null) {
      _event('forcedAttackTargetConsumed', {
        'actorId': actor.instanceId,
        'targetId': actor.nextAttackTargetId,
      });
      actor.nextAttackTargetId = null;
    }
    final armed = _effectiveArmedAttacks(actor);
    actor.armedAttacks.clear();
    final reciprocal = targets
        .map((id) => actor.reciprocalDice.remove(id) ?? 1)
        .fold<int>(1, (a, b) => a > b ? a : b);
    final diceCount = armed.fold<int>(
      reciprocal,
      (n, a) => a.rule.diceCount > n ? a.rule.diceCount : n,
    );
    final rawSides = sides;
    var diceSides = sides;
    _chooseDamageRoll(
      actor,
      () {
        final rolled = _attackRoll(
          actor,
          rawSides,
          diceCount,
          actionId: actionId,
          fixedMaximum: armed.any((a) => a.rule.fixedMaximum),
        );
        diceSides = rolled.spec.nominalSides;
        _event('diceRolled', {
          'actorId': actor.instanceId,
          'actionId': actionId,
          'sides': diceSides,
          'result': rolled.finalTotal,
          'rollId': rolled.id,
          'roll': rolled.toJson(),
        });
        return rolled;
      },
      (rolledResult) {
        final diceResult = rolledResult.finalTotal;
        final deferredDiceBonus = _growAttackDice(actor, diceResult);
        for (final ability in armed.where((a) => a.rule.reciprocalDice)) {
          for (final id in targets) {
            _character(id).reciprocalDice[actor.instanceId] =
                ability.rule.diceCount;
          }
        }
        for (final status in diceOverrides.where(
          (s) => s.definition.consumeOnAttackRoll,
        )) {
          _performance.temporaryTriggered(status, actor);
          _consumeStatus(actor, status);
        }
        sides = diceSides;
        final pending = PendingResolution(
          id: actionId,
          kind: PendingKind.attack,
          actorId: playerId,
          targets: targets,
          cards: cards,
          diceSides: sides,
          diceRoll: rolledResult,
          deferredDiceBonus: deferredDiceBonus,
          diceCount: diceCount,
          armedAttacks: armed,
          attackPowerBonus: _declaredAttackPower.remove(actionId) ?? 0,
          baseDiceSides: baseDiceSides,
          forcedDiceSides: diceOverrides.lastOrNull?.definition.attackDiceSides,
        );
        _event('attackDeclared', {
          'actorId': _player(playerId).character.instanceId,
          'actionId': pending.id,
          'targets': List<String>.unmodifiable(targets),
          if (targets.length == 1) 'targetId': targets.single,
        });
        _event('attackDiceCommitted', {
          'actorId': _player(playerId).character.instanceId,
          'actionId': pending.id,
          'sides': sides,
          'result': pending.diceResult,
        });
        _offerReroll(
          actor,
          pending.diceSides,
          pending.diceCount,
          pending.diceRoll!,
          (result) {
            pending.setDiceRoll(_storeRoll(result));
            _flowSteps([
              _drainTriggers,
              () {
                if (!_player(playerId).character.alive) {
                  _returnAttackCards(actionId);
                  _afterResolution();
                  return;
                }
                _openResponse(pending);
              },
            ]);
          },
          generate: () => _rerollPendingAttack(actor, pending),
          damageRoll: true,
          locked: pending.diceLocked,
        );
      },
      locked: armed.any((a) => a.rule.fixedMaximum),
    );
  }

  void _useSkill(
    PlayerInstance player,
    UseSkillCommand command, {
    bool validateOnly = false,
    void Function(int)? costQuote,
  }) => _withCommandNumber(
    command,
    () => _useSkillBody(
      player,
      command,
      validateOnly: validateOnly,
      costQuote: costQuote,
    ),
  );

  void _useSkillBody(
    PlayerInstance player,
    UseSkillCommand command, {
    bool validateOnly = false,
    void Function(int)? costQuote,
  }) {
    if (command.pendingActionId != null) throw StateError('Stale response');
    if (_interactionRulesVersion >= 23 &&
        (command.diceResult != null || command.cardInstanceId != null)) {
      throw StateError('Main skills do not accept response dice or card input');
    }
    final owned = _ownedModuleSkill(player.character, command.skillInstanceId);
    final skill = _executionSkill(player.character, owned, command);
    _checkExecutionCosts(player.character, skill);
    _checkSkillNumber(player.character, skill.definition, command.number);
    if (skill.definition.numberParameter?.countTargets == true &&
        command.targetIds.length != command.number) {
      throw StateError('Number must equal selected target count');
    }
    if (skill.definition.timing != SkillTiming.main) {
      throw StateError('Skill requires a response');
    }
    _validateTargets(
      skill.definition,
      command.targetIds,
      actor: player.character,
    );
    final suppressed = _negateSkills(player.character);
    _checkMp(
      player.character,
      _skillMpCost(player.character, skill.definition, number: command.number) +
          (suppressed ? 0 : _targetSurcharge(command.targetIds)),
    );
    final preparationEffects = suppressed
        ? <EffectDefinition>[]
        : _modulePreparationEffects(player.character, skill, command);
    if (_interactionRulesVersion >= 23) {
      _checkHarmfulSkillTargets(
        player.character,
        preparationEffects,
        command.targetIds,
        replayDamage:
            skill.definition.mechanism == SkillMechanism.replayRecord &&
            !command.reverse &&
            _ownedRecord(player.character, command.recordId).damage > 0,
      );
    }
    _validateAbilityTargets(preparationEffects, command.targetIds);
    _checkNewCopyAttack(
      player.character,
      preparationEffects,
      command.targetIds,
    );
    _checkEffects(skill.definition.effects);
    costQuote?.call(
      player.character.noMp
          ? 0
          : _skillMpCost(
                  player.character,
                  skill.definition,
                  number: command.number,
                ) +
                (suppressed ? 0 : _targetSurcharge(command.targetIds)),
    );
    if (validateOnly) {
      if (!_leadingSelectionAvailable(
        player.character,
        command.targetIds,
        preparationEffects,
        skillTargeting: true,
      )) {
        throw StateError('No available leading selection');
      }
      return;
    }
    if (_prepareAbility(
      player.character,
      preparationEffects,
      command.targetIds,
      _skillMpCost(player.character, skill.definition, number: command.number) +
          (suppressed ? 0 : _targetSurcharge(command.targetIds)),
      () => _useSkill(player, command),
      collectAll: skill.definition.preselectAll,
      input: {
        'kind': 'useSkill',
        'instanceId': skill.instanceId,
        'definitionId': skill.definition.id,
        'copiedSkillId': command.copiedSkillId,
        'recordId': command.recordId,
        'reverse': command.reverse,
        'number': command.number,
        'targetIds': command.targetIds,
        'cooldown': skill.definition.cooldown,
        'lifeCost': suppressed
            ? 0
            : _skillLifeCost(
                player.character,
                skill.definition,
                number: command.number,
              ),
        'statCosts': {
          for (final e
              in (suppressed ? <Stat, int>{} : skill.definition.statCosts)
                  .entries)
            e.key.name: e.value,
        },
        'markCosts': [
          for (final e in _markCosts(
            suppressed ? const [] : skill.definition.markCosts,
          ).entries)
            {'markId': e.key, 'amount': e.value},
        ],
      },
    )) {
      return;
    }
    if ((owned.definition.mechanism != SkillMechanism.ordinary ||
            skill.definition.numberParameter != null) &&
        !_committingPrepared) {
      _confirmModuleSkill(player, owned, skill, command);
      return;
    }
    final conditionalBranches = _captureConditionalBranches(
      player.character,
      command.targetIds,
      skill.definition.effects,
    );
    _beginObservedAction(
      player.character,
      command.targetIds,
      const [],
      recordable: false,
      countsAsAction: false,
    );
    _commitModuleSkill(player.character, owned, skill, command);
    _flowSteps([
      _drainTriggers,
      () {
        if (!player.character.alive) {
          _afterResolution();
          return;
        }
        _openResponse(
          PendingResolution(
            id: state.id('action'),
            kind: PendingKind.skill,
            actorId: player.id,
            targets: command.targetIds,
            skill: skill,
            conditionalBranches: conditionalBranches,
            replayRecord: command.recordId,
            reverseReplay: command.reverse,
            suppressedEffects: suppressed,
            number: command.number,
          ),
        );
      },
    ]);
  }

  int _skillMpCost(
    CharacterInstance actor,
    SkillDefinition skill, {
    int? number,
  }) => _negateSkills(actor)
      ? 0
      : skill.mpCost +
            (skill.numberParameter?.mpCostPerUnit ?? 0) *
                (number ?? _abilityNumber) +
            actor.statuses.fold<int>(
              0,
              (n, s) => n + s.definition.skillMpSurcharge,
            ) +
            (!_blocked(actor, (s) => s.blockTraits) &&
                    actor.traits.any((t) => t.definition.waiveSkillSurcharge)
                ? 0
                : skill.mpSurcharge);

  SkillInstance _usableSkill(CharacterInstance actor, String id) {
    final skill = actor.skills.where((s) => s.instanceId == id).firstOrNull;
    if (skill == null) throw StateError('Skill instance is not owned');
    if (skill.definition.passive) {
      throw StateError('Passive skills cannot be activated');
    }
    if (skill.leasedOut) throw StateError('Skill is temporarily borrowed');
    if (_blocked(actor, (s) => s.blockSkills)) {
      throw StateError('Skills are blocked');
    }
    if (!_negateSkills(actor) &&
        !_canPayMarks(actor, skill.definition.markCosts)) {
      throw StateError('Insufficient marks');
    }
    if (skill.remainingUses == 0) throw StateError('Skill is exhausted');
    if (skill.cooldown > 0) throw StateError('Skill is on cooldown');
    _checkExecutionCosts(actor, skill);
    return skill;
  }

  int _skillLifeCost(
    CharacterInstance actor,
    SkillDefinition skill, {
    int? number,
  }) {
    final previous = _abilityNumber;
    _abilityNumber = number ?? previous;
    try {
      return (_amount(skill.lifeCost, skill.lifeCostValue, actor, actor) +
              (skill.numberParameter?.lifeCostPerUnit ?? 0) * _abilityNumber)
          .clamp(0, 1000000000);
    } finally {
      _abilityNumber = previous;
    }
  }

  void _commitSkill(
    CharacterInstance actor,
    SkillInstance skill,
    List<String> targets,
  ) {
    final branchCooldown = skill.definition.cooldownBranches
        .where((b) => _conditionMatches(b.when, actor, actor))
        .firstOrNull
        ?.cooldown;
    var lifeCost = 0;
    if (!_negateSkills(actor)) {
      final previousLimits = _resourceLimits(actor);
      for (final cost in skill.definition.statCosts.entries) {
        actor.permanentModifiers.update(
          cost.key,
          (n) => n - cost.value,
          ifAbsent: () => -cost.value,
        );
      }
      if (skill.definition.statCosts.isNotEmpty) _normalize(actor);
      _logResourceLimitChanges(actor, previousLimits, source: actor);
      if (_interactionRulesVersion >= 23) {
        _payMarkCosts(actor, _skillMarkCosts(skill.definition));
      } else {
        _payMarkCosts(actor, skill.definition.markCosts);
        final numericMark = skill.definition.numberParameter?.markCostId;
        if (numericMark != null) {
          _payMarkCosts(actor, [MarkCost(numericMark, _abilityNumber)]);
        }
      }
      _payMp(
        actor,
        _skillMpCost(actor, skill.definition) + _targetSurcharge(targets),
      );
      _scoreAbilityFee(actor, skill: skill.definition);
      lifeCost = _skillLifeCost(actor, skill.definition);
      if (lifeCost > 0) {
        if (!actor.defenseLife) actor.hp -= lifeCost;
        _event('lifePaid', {
          'actorId': actor.instanceId,
          'amount': actor.defenseLife ? 0 : lifeCost,
          'nominalAmount': lifeCost,
        });
      }
    }
    _rewardTargetFees(targets);
    _setSkillCooldown(
      skill,
      branchCooldown ??
          _amount(
            skill.definition.cooldown,
            skill.definition.cooldownValue,
            actor,
            actor,
          ).clamp(0, 1000000000),
      preserveAnchor: false,
    );
    skill.revealed = true;
    state.publicSkillHistory[skill.definition.id] = skill.definition;
    skill.uses++;
    if (skill.remainingUses != null) {
      skill.remainingUses = skill.remainingUses! - 1;
      if (_interactionRulesVersion < 23 &&
          !_negateSkills(actor) &&
          !_canPayMarks(actor, skill.definition.markCosts)) {
        throw StateError('Insufficient marks');
      }
      if (skill.remainingUses == 0) actor.skills.remove(skill);
    }
    _event('skillUsed', {
      'actorId': actor.instanceId,
      'skillId': skill.definition.id,
      'targets': List<String>.unmodifiable(targets),
      if (targets.length == 1) 'targetId': targets.single,
      'instanceId': skill.instanceId,
      'cooldown': skill.cooldown,
    });
    final divisor = _skillRefundDivisor(actor);
    if (divisor != null) {
      _effects(actor, [], [ModifyMp(skill.cooldown ~/ divisor)]);
      _event('skillEffectsNegated', {
        'actorId': actor.instanceId,
        'skillId': skill.definition.id,
        'amount': skill.cooldown ~/ divisor,
      });
    }
    if (lifeCost > 0 && skill.definition.numberParameter == null) {
      _normalize(actor);
    }
  }

  final Set<EffectDefinition> _oncePerAttackEffects = Set.identity();

  void _resolveAttack(CharacterInstance actor, PendingResolution pending) {
    _redirectSupportAttack(actor, pending);
    _runCardEffects(actor, pending.targets, pending.cards, () {
      _flowSteps([
        () {
          if (!actor.alive) return;
          _attackPowerAdjustment += pending.attackPowerBonus;
          _event('attackPreparing', {
            'actionId': pending.id,
            'tagCounts': Map<String, int>.unmodifiable({
              for (final tag
                  in pending.cards.expand((c) => c.definition.tags).toSet())
                tag: pending.cards
                    .where((c) => c.definition.tags.contains(tag))
                    .length,
            }),
            'actorId': actor.instanceId,
            'targets': List<String>.unmodifiable(pending.targets),
            if (pending.targets.length == 1) 'targetId': pending.targets.single,
          });
        },
        () {
          if (!actor.alive) return;
          for (final targetId in pending.targets) {
            if (!_character(targetId).alive) continue;
            _event('attackReceived', {
              'sourceId': actor.instanceId,
              'targetId': targetId,
              'actionId': pending.id,
              'targets': [actor.instanceId],
            });
          }
        },
        () => _offerPreyDefense(actor, pending),
        () => _offerFruitAttacks(actor, pending),
        () => _runAttackDuels(actor, pending),
        () {
          final previousCards = _effectCards;
          _effectCards = pending.cards;
          try {
            _buildAttackPackets(actor, pending);
          } finally {
            _effectCards = previousCards;
          }
        },
        () => _fruitAttackModule.finishAction(pending.id),
        _oncePerAttackEffects.clear,
        () => _event(actor.alive ? 'actionResolved' : 'actionCancelled', {
          'actionId': pending.id,
        }),
        () => _returnAttackCards(pending.id),
        () => _offerPlacePrey(actor, pending),
        () {
          _cardContentModule.finishAction(pending.id);
          _preyModule.finishAction(pending.id);
        },
        _afterResolution,
      ]);
    });
  }

  void _buildAttackPackets(CharacterInstance actor, PendingResolution pending) {
    if (!actor.alive) return;
    final attackerDice =
        pending.diceResult +
        _pendingDiceBonus(actor, pending) +
        pending.cards.fold<int>(
          0,
          (n, c) => n + c.definition.diceBonus * _cardScale(c),
        );
    _attackDiceFinal = attackerDice;
    final auras = <(CharacterInstance, AttackAura)>[];
    for (final player in state.players) {
      final holder = player.character;
      if (!holder.alive || _blocked(holder, (s) => s.blockTraits)) continue;
      for (final trait in holder.traits) {
        final aura = trait.definition.attackAura;
        if (aura != null &&
            _effectTargets(holder, const [], aura.scope).contains(actor)) {
          auras.add((holder, aura));
        }
      }
    }
    final reduction = auras.fold<int>(0, (n, a) => n + a.$2.thresholdReduction);
    final threshold = ((pending.diceSides * 0.7).ceil() - reduction).clamp(
      0,
      1000000,
    );
    final strengthenedTargets = pending.targets
        .where(
          (id) =>
              attackerDice + _fruitAttackModule.adjustmentFor(pending.id, id) >=
              threshold,
        )
        .toList();
    final strengthened = strengthenedTargets.isNotEmpty;
    if (strengthened) {
      _event('strengthenedAttack', {
        'sourceId': actor.instanceId,
        'actionId': pending.id,
        'attack': true,
        'targets': strengthenedTargets,
      });
    }
    final formula = _blocked(actor, (s) => s.blockTraits)
        ? null
        : actor.traits
              .map((t) => t.definition.attackFormula)
              .whereType<AttackFormula>()
              .firstOrNull;
    final packets = <AttackPacket>[];
    for (final targetId in pending.targets) {
      final target = _character(targetId);
      final strengthened = strengthenedTargets.contains(targetId);
      _attackDiceFinal =
          attackerDice + _fruitAttackModule.adjustmentFor(pending.id, targetId);
      if (!target.alive) continue;
      final ignoreCardFinal =
          !_blocked(target, (s) => s.blockTraits) &&
          target.traits.any(
            (t) => t.definition.incomingAttack?.ignoreCardFinalDamage ?? false,
          );
      var attackBonus = _committedAttackBonus + _attackPowerAdjustment;
      var defenseBonus = target.statuses.fold<int>(
        0,
        (sum, status) =>
            sum +
            status.definition.incomingDefenseBonusPerIntensity *
                status.intensity,
      );
      var attackMultiplier = 1.0;
      var defenseMultiplier = 1.0;
      var finalBonus =
          _attackAdjustment +
          actor.statuses.fold<int>(
            0,
            (n, s) => n + s.definition.attackFlatPerIntensity * s.intensity,
          );
      final preyFactor = _preyModule.factorFor(pending.id, targetId);
      var finalMultiplier = _attackEffectMultiplier * preyFactor;
      final scoreFinalBase = finalMultiplier;
      final scorePieces = <_AttackScorePiece>[];
      var kind = DamageKind.physical;
      var pierces = false;
      var diceBonus =
          _pendingDiceBonus(actor, pending) +
          _fruitAttackModule.adjustmentFor(pending.id, targetId);
      var ignoreDefense = false;
      var ignoredDefense = 0;
      var ignoredDefenseRatio = 0.0;
      var ignoreShield = false;
      var ignoreDodge = pending.cards.any((c) => c.definition.ignoreDodge);
      var clearDodge = pending.cards.any((c) => c.definition.clearDodge);
      void applyModifier(
        AttackModifier modifier, {
        bool cardSource = false,
        int scale = 1,
        String? scoreSource,
      }) {
        if (!_conditionMatches(modifier.when, actor, target)) return;
        attackBonus += modifier.attackBonus * scale;
        var scoreFlat = 0;
        var scoreFactor = 1.0;
        if (!cardSource || !ignoreCardFinal) {
          scoreFlat =
              (modifier.finalDamageBonus +
                  _amount(0, modifier.finalDamageValue, actor, target)) *
              scale;
          finalBonus += scoreFlat;
          scoreFactor = _scaledMultiplier(
            modifier.finalDamageMultiplier,
            scale,
          );
          finalMultiplier *= scoreFactor;
        }
        scorePieces.add(
          _AttackScorePiece(
            _scoreOwner(
              scoreSource ?? actor.instanceId,
              actor,
              ContributionRoute.enhancement,
            ),
            attack: modifier.attackBonus * scale,
            finalBonus: scoreFlat,
            finalFactor: scoreFactor,
          ),
        );
        scorePieces.add(
          _AttackScorePiece(
            _scoreOwner(
              scoreSource ?? actor.instanceId,
              target,
              ContributionRoute.weakening,
            ),
            ignoreAmount: modifier.ignoreDefenseAmount * scale,
            ignoreRatio: _interactionRulesVersion >= 8
                ? modifier.ignoreDefenseRatio * scale
                : 0,
          ),
        );
        ignoredDefense += modifier.ignoreDefenseAmount * scale;
        if (_interactionRulesVersion >= 8) {
          ignoredDefenseRatio =
              (ignoredDefenseRatio + modifier.ignoreDefenseRatio * scale).clamp(
                0.0,
                1.0,
              );
        }
        ignoreShield = ignoreShield || modifier.ignoreShield;
        ignoreDodge = ignoreDodge || modifier.ignoreDodge;
        clearDodge = clearDodge || modifier.clearDodge;
      }

      for (final card in pending.cards) {
        final d = card.definition;
        final scale = _cardScale(card);
        scorePieces.add(
          _AttackScorePiece(
            _scoreOwner(actor.instanceId, actor, ContributionRoute.enhancement),
            attack: d.attackBonus * scale,
            dice: d.diceBonus * scale,
            attackFactor: _scaledMultiplier(d.attackMultiplier, scale),
            finalBonus: ignoreCardFinal ? 0 : d.finalDamageBonus * scale,
            finalFactor: ignoreCardFinal
                ? 1
                : _scaledMultiplier(d.finalDamageMultiplier, scale),
          ),
        );
        scorePieces.add(
          _AttackScorePiece(
            _scoreOwner(actor.instanceId, target, ContributionRoute.weakening),
            defense: d.defenseBonus * scale,
            defenseFactor: _scaledMultiplier(d.defenseMultiplier, scale),
            ignoreDefense: d.ignoreDefense,
          ),
        );
        attackBonus += d.attackBonus * scale;
        diceBonus += d.diceBonus * scale;
        ignoreDefense = ignoreDefense || d.ignoreDefense;
        defenseBonus += d.defenseBonus * scale;
        attackMultiplier *= _scaledMultiplier(d.attackMultiplier, scale);
        defenseMultiplier *= _scaledMultiplier(d.defenseMultiplier, scale);
        if (!ignoreCardFinal) {
          finalBonus += d.finalDamageBonus * scale;
          finalMultiplier *= _scaledMultiplier(d.finalDamageMultiplier, scale);
        }
        if (d.damageKind != DamageKind.physical) kind = d.damageKind;
        pierces = pierces || d.piercesContinuation;
        for (final modifier in d.attackModifiers) {
          applyModifier(modifier, cardSource: true, scale: scale);
        }
      }
      if (!_blocked(actor, (s) => s.blockTraits)) {
        for (final trait in actor.traits) {
          for (final modifier in trait.definition.attackModifiers) {
            applyModifier(modifier);
          }
        }
      }
      for (final entry in auras) {
        if (entry.$2.strengthenedOnly && !strengthened) continue;
        for (final modifier in entry.$2.attackModifiers) {
          applyModifier(modifier, scoreSource: entry.$1.instanceId);
        }
      }
      if (kind == DamageKind.real || kind == DamageKind.lifeLoss) {
        finalBonus -= actor.statuses.fold<int>(
          0,
          (n, s) => n + s.definition.attackFlatPerIntensity * s.intensity,
        );
      }
      if (kind != DamageKind.real &&
          kind != DamageKind.lifeLoss &&
          !_blocked(actor, (s) => s.blockTraits)) {
        for (final trait in actor.traits) {
          final d = trait.definition;
          if (d.attackHpThreshold == null ||
              actor.hp <= actor.value(Stat.maxHp) * d.attackHpThreshold!) {
            finalMultiplier *= d.attackDamageMultiplier;
            scorePieces.add(
              _AttackScorePiece(
                _scoreOwner(
                  actor.instanceId,
                  actor,
                  ContributionRoute.enhancement,
                ),
                finalFactor: d.attackDamageMultiplier,
              ),
            );
          }
        }
      }
      var effectiveDice = pending.diceResult + diceBonus;
      var calculatedRoll = pending.diceRoll?.modified(
        RollModification(
          DiceAdjustment.add,
          diceBonus,
          sourceId: 'attack_modifiers',
        ),
      );
      if (!_blocked(target, (s) => s.blockTraits)) {
        for (final trait in target.traits) {
          final rule = trait.definition.incomingAttack;
          if (rule == null) continue;
          if (rule.useBaseDice) {
            effectiveDice = pending.diceResult;
            calculatedRoll = calculatedRoll?.modified(
              RollModification(
                DiceAdjustment.replace,
                pending.diceResult,
                sourceId: trait.definition.id,
              ),
            );
          }
          if (rule.diceCap != null) {
            effectiveDice = effectiveDice.clamp(0, rule.diceCap!);
            calculatedRoll = calculatedRoll
                ?.modified(
                  RollModification(
                    DiceAdjustment.capMinimum,
                    0,
                    sourceId: trait.definition.id,
                  ),
                )
                .modified(
                  RollModification(
                    DiceAdjustment.capMaximum,
                    rule.diceCap!,
                    sourceId: trait.definition.id,
                  ),
                );
          }
        }
      }
      if (pending.diceLocked) {
        effectiveDice = pending.maximumDiceResult;
        calculatedRoll = calculatedRoll?.modified(
          RollModification(
            DiceAdjustment.replace,
            effectiveDice,
            sourceId: 'fixed_maximum',
          ),
        );
      }
      if (kind != DamageKind.real &&
          kind != DamageKind.lifeLoss &&
          formula == null) {
        for (final player in state.players) {
          final holder = player.character;
          if (!holder.alive || _blocked(holder, (s) => s.blockTraits)) continue;
          for (final trait in holder.traits) {
            final aura = trait.definition.attackAura;
            if (aura != null &&
                (!aura.strengthenedOnly || strengthened) &&
                _effectTargets(holder, const [], aura.scope).contains(actor)) {
              finalMultiplier *= aura.finalDamageMultiplier;
              scorePieces.add(
                _AttackScorePiece(
                  _scoreOwner(
                    holder.instanceId,
                    actor,
                    ContributionRoute.enhancement,
                  ),
                  finalFactor: aura.finalDamageMultiplier,
                ),
              );
            }
          }
        }
      }
      if (formula != null) kind = formula.kind;
      final effectiveDefense = ignoreDefense
          ? 0
          : (target.value(Stat.defense) * (1 - ignoredDefenseRatio) -
                    ignoredDefense)
                .clamp(0, 1000000000);
      var amount = formula != null
          ? ((effectiveDice + 1) *
                    0.5 *
                    ((actor.value(Stat.attack) + attackBonus) *
                            attackMultiplier +
                        formula.attackOffset))
                .floor()
                .clamp(0, 1000000000)
          : ruleDamage(
              finalDice: effectiveDice.clamp(0, 1000000).toDouble(),
              useLegacyDamageFormula: rules.useLegacyDamageFormula,
              attack: actor.value(Stat.attack),
              defense: effectiveDefense,
              attackBonus: attackBonus,
              defenseBonus: defenseBonus,
              attackMultiplier: attackMultiplier,
              defenseMultiplier: defenseMultiplier,
              finalBonus: finalBonus,
              finalMultiplier: finalMultiplier,
            );
      _event('damageCalculated', {
        'actionId': pending.id,
        'sourceId': actor.instanceId,
        'targetId': targetId,
        'formula': formula != null
            ? 'trait'
            : rules.useLegacyDamageFormula
            ? 'legacy'
            : 'current',
        'finalDice': effectiveDice,
        if (calculatedRoll != null) 'diceRoll': calculatedRoll.toJson(),
        'attack': actor.value(Stat.attack),
        'defense': target.value(Stat.defense),
        'attackBonus': attackBonus,
        'defenseBonus': defenseBonus,
        'attackMultiplier': attackMultiplier,
        'defenseMultiplier': defenseMultiplier,
        'ignoreDefense': ignoreDefense,
        'ignoredDefense': ignoredDefense,
        if (ignoredDefenseRatio > 0) ...{
          'ignoredDefenseRatio': ignoredDefenseRatio,
          'effectiveDefense': effectiveDefense,
        },
        'finalBonus': finalBonus,
        'finalMultiplier': finalMultiplier,
        'amount': amount,
      });
      final baseDamage = formula != null
          ? amount
          : ruleDamage(
              finalDice: effectiveDice.clamp(0, 1000000).toDouble(),
              useLegacyDamageFormula: rules.useLegacyDamageFormula,
              attack: actor.value(Stat.attack),
              defense: effectiveDefense,
              attackBonus: attackBonus,
              defenseBonus: defenseBonus,
              attackMultiplier: attackMultiplier,
              defenseMultiplier: defenseMultiplier,
            );
      final armedFactor = pending.armedAttacks.fold<double>(
        1,
        (n, a) => n * a.rule.damageMultiplier,
      );
      final scoreTrace = _scoreAttackFormula(
        actor,
        target,
        pending,
        scorePieces,
        attackBonus: attackBonus,
        defenseBonus: defenseBonus,
        diceBonus: diceBonus,
        finalBonus: finalBonus,
        finalMultiplierBase: scoreFinalBase,
        formula: formula,
        kind: kind,
      );
      scoreTrace?.transform(
        (v) => (v * armedFactor).round(),
        owner: _scoreOwner(
          actor.instanceId,
          actor,
          ContributionRoute.enhancement,
        ),
      );
      amount = (amount * armedFactor).round();
      _attackDamage = amount;
      if (kind == DamageKind.physical || kind == DamageKind.magical) {
        final reduction = _incomingDamageReduction(actor, target);
        scoreTrace?.transform(
          (v) => (v - reduction).clamp(0, 1000000000),
          owner: _scoreOwner(
            target.instanceId,
            target,
            ContributionRoute.protection,
          ),
        );
        amount = (amount - reduction).clamp(0, 1000000000);
      }
      if (scoreTrace != null) {
        _performance.attackAttribution(
          pending.id,
          target.instanceId,
          scoreTrace,
        );
      }
      final onHit = <AttackPacketEffect>[];
      void append(
        String definitionId,
        List<EffectDefinition> effects,
        int multiplier, {
        CharacterInstance? effectSource,
        bool freezeSupport = true,
      }) {
        for (final effect in effects) {
          if (effect is ConditionalEffect) {
            if (effect.when is AnyCondition ||
                effect.when is HpRatioCondition ||
                effect.when is LivingCountCondition ||
                effect.when is RelationCondition ||
                effect.when is HasStatusQueryCondition ||
                effect.when is ValueCondition ||
                effect.when is PredicateCondition ||
                effect.when is AllCondition ||
                effect.when is NotCondition) {
              _checkChoiceCondition(effect.when);
            }
            append(
              definitionId,
              _conditionMatches(effect.when, actor, target)
                  ? effect.effects
                  : effect.otherwise,
              multiplier,
              effectSource: effectSource,
            );
            continue;
          }
          final effectTarget = effect.target == EffectTarget.self
              ? actor
              : target;
          final frozen = switch (effect) {
            ApplyStatus() => ApplyStatus(
              effect.statusId,
              stacks:
                  _amount(
                    effect.stacks,
                    effect.stacksValue,
                    actor,
                    effectTarget,
                  ) *
                  pending.cards.fold<int>(
                    1,
                    (n, card) =>
                        n *
                        (1 +
                            ((card
                                            .definition
                                            .statusStackMultipliers[definitionId] ??
                                        1) -
                                    1) *
                                _cardScale(card)),
                  ),
              refreshSource: effect.refreshSource,
              ignoreNegativeProtection: effect.ignoreNegativeProtection,
              damageLimit: effect.damageLimit,
              intensity: _amount(
                effect.intensity,
                effect.intensityValue,
                actor,
                effectTarget,
              ),
              target: effect.target,
            ),
            DamageEffect() => DamageEffect(
              ((_amount(effect.amount, effect.value, actor, effectTarget) *
                                  multiplier -
                              ((!effect.sourceless &&
                                      (effect.kind == DamageKind.physical ||
                                          effect.kind == DamageKind.magical))
                                  ? _incomingDamageReduction(
                                      effectSource ?? actor,
                                      effectTarget,
                                      attachment: true,
                                    )
                                  : 0))
                          .clamp(0, 1000000000) *
                      armedFactor *
                      preyFactor)
                  .round(),
              kind: effect.kind,
              target: effect.target,
              sourceless: effect.sourceless,
              fromStatusSource: effect.fromStatusSource,
              onDamage: effect.onDamage,
            ),
            ModifyMp() => ModifyMp(
              _amount(effect.amount, effect.value, actor, effectTarget),
              target: effect.target,
            ),
            StealLife() => StealLife(
              _amount(effect.amount, effect.value, actor, effectTarget),
              target: effect.target,
              healNominal: effect.healNominal,
            ),
            ShieldEffect() when freezeSupport => ShieldEffect(
              _amount(effect.amount, effect.value, actor, effectTarget),
              target: effect.target,
            ),
            HealEffect() when freezeSupport => HealEffect(
              _amount(effect.amount, effect.value, actor, effectTarget),
              sourceTraitId: effect.sourceTraitId,
              targetTraitId: effect.targetTraitId,
              target: effect.target,
            ),
            _ => effect,
          };
          onHit.add(
            AttackPacketEffect(
              definitionId,
              frozen,
              frozen is DamageEffect ? 1 : multiplier,
              sourceId: effectSource?.instanceId,
            ),
          );
        }
      }

      append(
        'rotating_card_effects',
        _cardContentModule.rotatingEffects(pending.id),
        1,
        freezeSupport: false,
      );
      for (final armed in pending.armedAttacks) {
        append('prepared_attack', armed.rule.onHit, 1);
      }
      append('tag_rewards', _cardContentModule.tagEffects(pending.id), 1);
      for (final card in pending.cards) {
        _discardedCount = _cardDiscardCounts[card.instanceId] ?? 0;
        append(
          card.definition.id,
          card.definition.onHit,
          card.reinforced ? 2 : 1,
        );
      }
      if (!_blocked(actor, (s) => s.blockTraits)) {
        for (final trait in actor.traits) {
          append(trait.definition.id, trait.definition.onHit, 1);
          for (final rule in trait.definition.attackStatuses) {
            final matches = pending.cards
                .where((c) => rule.tags.any(c.definition.tags.contains))
                .length;
            append(trait.definition.id, [
              ApplyStatus(
                rule.statusId,
                stacks: rule.stacks,
                intensity: rule.intensity,
              ),
            ], 1);
            if (matches > 0) {
              append(trait.definition.id, [
                ModifyAppliedStatus(
                  rule.statusId,
                  stacks: rule.tagStacks * matches,
                  intensity: rule.tagIntensity * matches,
                ),
              ], 1);
            }
          }
        }
      }
      for (final entry in auras) {
        if (!entry.$2.strengthenedOnly || strengthened) {
          append('attack_aura', entry.$2.onHit, 1, effectSource: entry.$1);
        }
      }
      if (actor.armedStatusTransfer case final plan?) {
        if ((plan.targetId == null || plan.targetId == targetId) &&
            !_blocked(actor, (s) => s.blockTraits)) {
          append('armed_status_transfer', [
            TransferStatus(
              query: StatusQuery(instanceId: plan.statusInstanceId),
              target: EffectTarget.self,
              to: EffectTarget.selected,
            ),
          ], 1);
        }
      }
      for (final status in actor.statuses) {
        append(status.definition.id, status.definition.onHit, status.intensity);
      }
      packets.add(
        AttackPacket(
          id: state.id('attackPacket'),
          actionId: pending.id,
          sourceId: actor.instanceId,
          targetId: targetId,
          amount: amount,
          baseDamage: baseDamage,
          attachmentDamageMultiplier: armedFactor * preyFactor,
          kind: kind,
          groupAttack: pending.targets.length >= 2,
          piercesContinuation: pierces,
          ignoreDodge: ignoreDodge,
          ignoreShield: ignoreShield,
          clearDodge: clearDodge,
          clearShield: pending.cards.any((c) => c.definition.clearShield),
          onHit: onHit,
        ),
      );
    }
    for (final status
        in actor.statuses
            .where((s) => s.definition.decay == StatusDecay.onAttack)
            .toList()) {
      _consumeStatus(actor, status);
    }
    _settlingAttack = true;
    final cards = List<CardInstance>.of(_effectCards);
    void next(int index) {
      if (index < packets.length) {
        _resolveAttackPacket(
          packets[index],
          () => next(index + 1),
          cards: cards,
        );
        return;
      }
      _settlingAttack = false;
      _defensePacketDamage.clear();
      _settleDeaths(() {
        _finishAttackSkills(actor, pending, () {
          if (actor.armedMarkAction != null) {
            final action = actor.armedMarkAction!;
            actor.armedMarkAction = null;
            if (!_blocked(actor, (s) => s.blockTraits)) {
              for (final id in pending.targets) {
                if (_enhanceWithMarks(
                  actor,
                  _character(id),
                  action,
                  negative: true,
                )) {
                  break;
                }
              }
            }
          }
          actor.armedStatusTransfer = null;
          _triggers(
            actor,
            TriggerTiming.attackResolved,
            selected: pending.targets,
          );
        });
      });
    }

    next(0);
  }

  void _resolveAttackPacket(
    AttackPacket packet,
    void Function() complete, {
    List<CardInstance> cards = const [],
  }) {
    final actor = _character(packet.sourceId);
    final target = _character(packet.targetId);
    final initialStatusIds = target.statuses.map((s) => s.instanceId).toList();
    final hitStatuses = target.statuses
        .where(
          (s) =>
              !s.definition.dodge &&
              s.definition.decay == StatusDecay.onAttackHit,
        )
        .toList();
    _event('attackPacketStarted', {
      'packetId': packet.id,
      'actionId': packet.actionId,
      'sourceId': packet.sourceId,
      'targetId': packet.targetId,
    });
    final effectsAllowed = _attackEffectTargetAllowed(target, packet);
    if (effectsAllowed && packet.clearShield && target.shield > 0) {
      final removed = target.shield;
      _performance.shieldRemoved(actor, target, removed);
      target.shield = 0;
      target.temporaryShields.clear();
      _event('shieldBroken', {
        'sourceId': actor.instanceId,
        'targetId': target.instanceId,
        'amount': removed,
      });
    }
    if (effectsAllowed && packet.clearDodge) {
      for (final status
          in target.statuses.where((s) => s.definition.dodge).toList()) {
        _consumeStatus(target, status, amount: status.stacks);
      }
    }
    if (!target.alive || packet.amount <= 0) {
      if (target.alive && _statisticsRulesVersion >= 2 && !_previewMode) {
        _performance
            .damageAttribution(
              packet.actionId,
              target.instanceId,
              packet.amount,
            )
            .settle(
              _performance.scores,
              observed: packet.amount,
              effectiveLimit: _scoreDamageLimit(
                target,
                packet.kind,
                packet: packet,
              ),
            );
      }
      _finishPacket(packet, 'negated');
      complete();
      return;
    }
    var dodged = false;
    if (packet.kind == DamageKind.physical ||
        packet.kind == DamageKind.magical) {
      final dodge = target.statuses
          .where((s) => s.definition.dodge)
          .firstOrNull;
      if (dodge != null && !packet.ignoreDodge) {
        _scoreDodge(actor, target, packet, dodge);
        _consumeStatus(target, dodge);
        dodged = true;
        _event('attackDodged', {
          'targetId': target.instanceId,
          'packetId': packet.id,
          'actionId': packet.actionId,
        });
      }
    }
    var resolvedEffects = packet.onHit;
    final plans = <_DamagePlan>[];
    final attachmentPlans = <AttackPacketEffect, _DamagePlan>{};
    void attachments(int index, {required bool hit}) {
      if (index == resolvedEffects.length) {
        hit = hit || plans.any((p) => p.hit);
        if (hit) {
          for (final status in hitStatuses) {
            if (target.statuses.contains(status)) {
              _consumeStatus(target, status);
            }
          }
        }
        final outcome = dodged
            ? 'dodged'
            : hit
            ? 'hit'
            : 'negated';
        if (_interactionRulesVersion < 18) {
          _finishPacket(packet, outcome);
          complete();
          return;
        }
        _flowSteps([
          if (_interactionRulesVersion >= 18 && hit)
            () => _event('attackDamageSettled', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'packetId': packet.id,
              'actionId': packet.actionId,
              'attack': true,
              'eligibleStatuses': initialStatusIds,
            }),
          () {
            final deferred = _triggerQueue
                .where(
                  (entry) =>
                      entry.fact.timing != TriggerTiming.attackDamageSettled ||
                      entry.fact.packetId != packet.id,
                )
                .toList();
            _triggerQueue.removeWhere(deferred.contains);
            _packetSettlementDepth++;
            _flowSteps([
              _drainTriggers,
              () {
                _packetSettlementDepth--;
                _triggerQueue.addAll(deferred);
                _finishPacket(packet, outcome);
              },
              complete,
            ]);
          },
        ]);
        return;
      }
      final attachment = resolvedEffects[index];
      if (dodged &&
          attachment.effect is DamageEffect &&
          ((attachment.effect as DamageEffect).kind == DamageKind.physical ||
              (attachment.effect as DamageEffect).kind == DamageKind.magical)) {
        attachments(index + 1, hit: hit);
        return;
      }
      _event('attackEffectStarted', {
        'packetId': packet.id,
        'definitionId': attachment.definitionId,
      });
      final plan = attachmentPlans[attachment];
      if (plan != null) {
        _runPlan(plan, () {
          final effect = attachment.effect as DamageEffect;
          if (plan.amount > 0 && effect.onDamage.isNotEmpty) {
            _runAbility(
              plan.source ?? actor,
              [target.instanceId],
              effect.onDamage,
              () => attachments(index + 1, hit: hit),
              cards: cards,
              attackPacket: packet,
            );
          } else {
            attachments(index + 1, hit: hit);
          }
        });
      } else {
        _runAbility(
          attachment.sourceId == null
              ? actor
              : _character(attachment.sourceId!),
          [target.instanceId],
          [attachment.effect],
          () => attachments(index + 1, hit: hit),
          multiplier: attachment.multiplier,
          cards: cards,
          attackPacket: packet,
        );
      }
    }

    if (dodged) {
      attachments(0, hit: false);
      return;
    }
    _expandPacketEffects(packet, cards, (expanded) {
      resolvedEffects = expanded;
      _prepareDamage(
        actor,
        target,
        packet.amount,
        packet.kind,
        (main) {
          plans.add(main);
          final groupGuarded =
              packet.groupAttack &&
              !_blocked(target, (s) => s.blockTraits) &&
              target.traits.any(
                (t) => t.definition.damageGuards.any(
                  (g) => g.groupAttackOnly && g.kinds.contains(packet.kind),
                ),
              );
          final hit = main.hit || groupGuarded;
          void prepare(int index) {
            if (index == resolvedEffects.length) {
              _offerDamageSkills(
                plans,
                () => _runPlan(main, () => attachments(0, hit: hit)),
              );
              return;
            }
            final attachment = resolvedEffects[index];
            final effect = attachment.effect;
            if (effect is! DamageEffect ||
                effect.target != EffectTarget.selected) {
              prepare(index + 1);
              return;
            }
            final source = effect.sourceless
                ? null
                : attachment.sourceId == null
                ? actor
                : _character(attachment.sourceId!);
            _prepareDamage(
              source,
              target,
              effect.amount * attachment.multiplier,
              effect.kind,
              (plan) {
                plans.add(plan);
                attachmentPlans[attachment] = plan;
                prepare(index + 1);
              },
              attack: true,
              packet: packet,
              secondary: true,
            );
          }

          prepare(0);
        },
        attack: true,
        packet: packet,
        piercesContinuation: packet.piercesContinuation,
      );
    });
  }

  void _finishPacket(AttackPacket packet, String outcome) =>
      _event('attackPacketResolved', {
        'packetId': packet.id,
        'actionId': packet.actionId,
        'sourceId': packet.sourceId,
        'targetId': packet.targetId,
        'kind': packet.kind.name,
        'outcome': outcome,
      });

  /// RULE.md: dice factor (final dice + 1)/2; defense scales before adding 50.
  static int ruleDamage({
    required double finalDice,
    required int attack,
    required num defense,
    bool useLegacyDamageFormula = false,
    int attackBonus = 0,
    int defenseBonus = 0,
    double attackMultiplier = 1,
    double defenseMultiplier = 1,
    int finalBonus = 0,
    double finalMultiplier = 1,
  }) {
    final finalAttack = (attack + attackBonus) * attackMultiplier;
    final finalDefense = (defense + defenseBonus) * defenseMultiplier;
    final denominator = 50 + finalDefense;
    if (!useLegacyDamageFormula && denominator <= 0) {
      throw StateError('Damage denominator must be positive');
    }
    final diceFactor = !useLegacyDamageFormula
        ? (finalDice + 1) / 2
        : finalDice;
    final base = useLegacyDamageFormula
        ? finalDice * (finalAttack - finalDefense)
        : diceFactor * finalAttack * 50 / denominator;
    final value = ((base + finalBonus) * finalMultiplier).round();
    return value < 0 ? 0 : value;
  }

  // A direct transfer needs a recipient distinct from its owner. Older content
  // omitted the explicit target flag; enforce the same invariant for live play,
  // AI candidates and response target lists without rewriting frozen assets.
  bool _skillExcludesSelfTarget(SkillDefinition skill) =>
      skill.excludeSelfTarget ||
      (_interactionRulesVersion >= 23 && _selectedEffectsHarm(skill.effects)) ||
      (_interactionRulesVersion >= 22 &&
          skill.effects.any(
            (e) =>
                e is TransferReceivedDamage &&
                e.target == EffectTarget.selected,
          ));

  bool _selectedEffectsHarm(Iterable<EffectDefinition> effects) {
    for (final effect in effects) {
      final selected = const {
        EffectTarget.selected,
        EffectTarget.selfOrSelected,
      }.contains(effect.target);
      if (selected &&
          (effect is DamageEffect ||
              effect is TransferReceivedDamage ||
              (effect is StealLife && !effect.fromStatusSource) ||
              (effect is StealEffect && effect.hp > 0) ||
              (effect is ArmAttack && effect.copyDamage))) {
        return true;
      }
      if (effect is ConditionalEffect &&
          (!effect.eachTarget || selected) &&
          (_selectedEffectsHarm(effect.effects) ||
              _selectedEffectsHarm(effect.otherwise))) {
        return true;
      }
      if (effect is RollEffect &&
          (_selectedEffectsHarm(effect.effects) ||
              _selectedEffectsHarm(effect.otherwise))) {
        return true;
      }
      if (effect is SelectOptionEffect &&
          effect.options.any((o) => _selectedEffectsHarm(o.effects))) {
        return true;
      }
      if (effect is ScheduleEffect &&
          selected &&
          _selectedEffectsHarm(effect.effects)) {
        return true;
      }
      if (effect is ChooseEffect &&
          effect.preserveSelected &&
          _selectedEffectsHarm(effect.effects)) {
        return true;
      }
    }
    return false;
  }

  bool _boundTargetsHarm(String binding, Iterable<EffectDefinition> effects) =>
      effects.any(
        (effect) =>
            effect is WithTargets &&
                (effect.reference == 'local.$binding' ||
                    effect.reference.startsWith('local.$binding.')) &&
                _selectedEffectsHarm(effect.effects) ||
            effect is ConditionalEffect &&
                (_boundTargetsHarm(binding, effect.effects) ||
                    _boundTargetsHarm(binding, effect.otherwise)) ||
            effect is SelectOptionEffect &&
                effect.options.any(
                  (o) => _boundTargetsHarm(binding, o.effects),
                ),
      );

  void _checkHarmfulSkillTargets(
    CharacterInstance actor,
    List<EffectDefinition> effects,
    List<String> targets, {
    bool replayDamage = false,
  }) {
    if (!replayDamage && !_selectedEffectsHarm(effects)) return;
    if (targets.any((id) => !_enemy(actor, _target(id)))) {
      throw StateError('Damage skills require enemy targets');
    }
  }

  bool _skillTargetAllowed(
    CharacterInstance actor,
    SkillDefinition skill,
    CharacterInstance target,
  ) =>
      target.alive &&
      (!_skillExcludesSelfTarget(skill) || target != actor) &&
      (_interactionRulesVersion < 23 ||
          !_selectedEffectsHarm(skill.effects) ||
          _enemy(actor, target)) &&
      _conditionMatches(skill.targetWhen, actor, target);

  void _validateTargets(
    SkillDefinition skill,
    List<String> targets, {
    CharacterInstance? actor,
  }) {
    if (targets.length < skill.minTargets ||
        targets.length > skill.maxTargets ||
        targets.toSet().length != targets.length) {
      throw StateError('Invalid target count');
    }
    for (final id in targets) {
      final target = _target(id);
      if (_skillExcludesSelfTarget(skill) &&
          target == (actor ?? state.activePlayer.character)) {
        throw StateError('Skill requires another character');
      }
      if (_interactionRulesVersion >= 23 &&
          _selectedEffectsHarm(skill.effects) &&
          !_enemy(actor ?? state.activePlayer.character, target)) {
        throw StateError('Damage skills require enemy targets');
      }
      if (!_conditionMatches(
        skill.targetWhen,
        actor ?? state.activePlayer.character,
        target,
      )) {
        throw StateError('Skill target requirement not met');
      }
    }
    if (targets.isEmpty &&
        skill.effects.any(
          (e) =>
              e.target == EffectTarget.selected &&
              e is! SetDiceResult &&
              e is! CancelSkill,
        )) {
      throw StateError('Target is required');
    }
  }

  Iterable<EffectDefinition> _walkEffects(
    List<EffectDefinition> effects,
  ) sync* {
    for (final effect in effects) {
      yield effect;
      if (effect is WithTargets) {
        yield* _walkEffects(effect.effects);
      } else if (effect is DisableHandCards) {
        yield* _walkEffects(effect.otherwise);
      } else if (effect is RollEffect) {
        yield* _walkEffects(effect.effects);
        yield* _walkEffects(effect.otherwise);
      } else if (effect is ConditionalEffect) {
        yield* _walkEffects(effect.effects);
        yield* _walkEffects(effect.otherwise);
      } else if (effect is SelectOptionEffect) {
        for (final option in effect.options) {
          yield* _walkEffects(option.effects);
        }
      } else if (effect is ChooseEffect) {
        yield* _walkEffects(effect.effects);
      } else if (effect is DamageEffect) {
        yield* _walkEffects(effect.onDamage);
      } else if (effect is ModifyStat) {
        yield* _walkEffects(effect.onClamp);
      } else if (effect is ScheduleEffect) {
        yield* _walkEffects(effect.effects);
      }
    }
  }

  void _checkAttackModifiers(List<AttackModifier> modifiers) {
    for (final modifier in modifiers) {
      if (modifier.when is VariableCondition) {
        final condition = modifier.when! as VariableCondition;
        _checkVariableCondition(condition);
        _checkVariableContext(
          ConditionalEffect(condition, const []),
          allowEvent: false,
        );
      }
      if (modifier.finalDamageValue != null) {
        _checkValue(modifier.finalDamageValue!);
        _checkVariableContext(
          DamageEffect(0, value: modifier.finalDamageValue),
          allowEvent: false,
        );
      }
      if (modifier.when is CounterEqualsCondition ||
          modifier.finalDamageValue?.field == ValueField.counter ||
          modifier.finalDamageValue?.field == ValueField.eventAmount) {
        throw StateError('Attack modifiers cannot read trigger context');
      }
    }
    for (final modifier in modifiers) {
      _checkChoiceCondition(modifier.when);
      if (modifier.when != null) {
        _checkVariableContext(
          ConditionalEffect(modifier.when!, const []),
          allowEvent: false,
        );
      }
      if (modifier.finalDamageValue != null &&
          _valueTree(modifier.finalDamageValue!).any(
            (v) =>
                v.perIntensity ||
                [
                  ValueField.counter,
                  ValueField.eventAmount,
                  ValueField.eventSkillCooldown,
                  ValueField.eventAttackBaseDamage,
                  ValueField.statusIntensity,
                ].contains(v.field),
          )) {
        throw StateError('Attack modifiers cannot read trigger context');
      }
      if (modifier.ignoreDefenseAmount < 0 ||
          !modifier.ignoreDefenseRatio.isFinite ||
          modifier.ignoreDefenseRatio < 0 ||
          modifier.ignoreDefenseRatio > 1 ||
          !modifier.finalDamageMultiplier.isFinite ||
          modifier.finalDamageMultiplier < 0) {
        throw StateError('Invalid attack modifier');
      }
    }
  }

  void _checkEffects(List<EffectDefinition> effects) {
    for (final effect in effects) {
      _checkQueryEffect(effect);
      if (effect is TransferMp &&
          (effect.amount < 0 || effect.amount > 1000000)) {
        throw StateError('Invalid MP transfer amount');
      }
      if (effect is SettleStatus) {
        final status = _require(catalog.statuses, effect.statusId);
        if (effect.phase != null) {
          if (effect.phase != SchedulePhase.turnStart &&
              effect.phase != SchedulePhase.turnEnd) {
            throw StateError(
              'Status settlement phase must be turnStart or turnEnd',
            );
          }
          continue;
        }
        if (effect.triggerIndex < 0 ||
            effect.triggerIndex >= status.triggers.length) {
          throw StateError('Invalid status settlement index');
        }
        final trigger = status.triggers[effect.triggerIndex];
        if (trigger.recordOnly ||
            trigger.threshold != null ||
            trigger.counterUpdates.isNotEmpty) {
          throw StateError(
            'Explicit status settlement requires a pure effect trigger',
          );
        }
      }
      if (effect is SummonUnit &&
          (effect.kind.isEmpty || effect.count < 1 || effect.count > 128)) {
        throw StateError('Invalid summon');
      }
      if (effect is RedirectAttack) {
        _require(catalog.marks, effect.markId);
        if (effect.cap < 1 || effect.overflowUnit < 1) {
          throw StateError('Invalid attack cap');
        }
      }
      if (effect is ConvertShieldToLife &&
          (!effect.factor.isFinite || effect.factor < 0)) {
        throw StateError('Invalid shield conversion factor');
      }
      if (effect is CheckContinuation &&
          (effect.sides < 1 ||
              effect.sides > 1000 ||
              effect.restoreHp < 1 ||
              effect.success.isEmpty ||
              effect.success.any((n) => n < 1 || n > effect.sides))) {
        throw StateError('Invalid continuation check');
      }
      if (effect is BorrowSkillEffect &&
          (effect.rule.drawCount < 0 || effect.rule.durationRounds < 1)) {
        throw StateError('Invalid skill borrowing policy');
      }
      if (effect is GenerateChosenCard) {
        for (final id in effect.exclude) {
          _require(catalog.cards, id);
        }
      }
      if (effect is TransferShield && effect.limit < 0) {
        throw StateError('Invalid shield transfer limit');
      }
      if (effect is RemoveSummons && effect.kind.isEmpty) {
        throw StateError('Missing summon kind');
      }
      if (effect is ChooseCards) {
        _checkValue(effect.minimum);
        _checkValue(effect.maximum);
        if (effect.minimumTags < 0) {
          throw StateError('Invalid tag count filter');
        }
      }
      if (effect is ConvertStatus) {
        if (effect.fromStatusId != null) {
          _require(catalog.statuses, effect.fromStatusId!);
        }
        _require(catalog.statuses, effect.toStatusId);
        if (effect.intensity <= 0) {
          throw StateError('Invalid conversion intensity');
        }
      }
      if (effect is RestrictCardTag && effect.rounds < 1) {
        throw StateError('Invalid tag restriction duration');
      }
      if (effect is DisableHandCards) {
        if (effect.count < 1 || effect.count > 128 || effect.rounds < 1) {
          throw StateError('Invalid hand restriction');
        }
        _checkEffects(effect.otherwise);
      }
      for (final v in _effectValues(effect)) {
        _checkValue(v);
      }
      if (effect is ArmAttack) {
        _checkEffects(effect.onHit);
        _checkEffects(effect.after);
        for (final effects in effect.rotationBonus.values) {
          _checkEffects(effects);
        }
      }
      if (effect is ArmAttack &&
          (!effect.damageMultiplier.isFinite ||
              effect.damageMultiplier < 0 ||
              effect.damageMultiplier > 16 ||
              effect.diceCount < 1 ||
              effect.diceCount > 16)) {
        throw StateError('Invalid armed attack rule');
      }
      if (effect is SelectOptionEffect) _checkAbilityOptions(effect);
      if (effect is ChooseTargets) {
        if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(effect.bind) ||
            effect.minimum < 0 ||
            effect.maximum < effect.minimum ||
            effect.maximum > 1024) {
          throw StateError('Invalid bound character choice');
        }
        _checkChoiceCondition(effect.when);
      }
      if (effect is WithTargets) {
        _checkReference(effect.reference);
        _checkEffects(effect.effects);
      }
      if (effect is ChooseEffect) {
        _checkChoiceCondition(effect.when);
        if (effect.kind == ChoiceKind.attackCard ||
            effect.kind == ChoiceKind.mechanism ||
            effect.kind == ChoiceKind.abilityOption) {
          throw StateError('Attack card choices require attack assembly');
        }
        if (effect.kind == ChoiceKind.mark) {
          throw StateError('Use an end mark option');
        }
        _checkStatusQuery(effect.statusQuery);
        if (effect.includeMissing &&
            (effect.kind != ChoiceKind.status ||
                effect.random ||
                (effect.statusQuery.statusId == null &&
                    effect.statusQuery.statusIds.isEmpty) ||
                effect.statusQuery.chosen ||
                effect.statusQuery.latest ||
                effect.statusQuery.instanceId != null)) {
          throw StateError(
            'Missing status selection requires explicit definitions',
          );
        }
        _checkEffects(effect.effects);
      }
      if (effect is FlipMarks) {
        final first = _require(catalog.marks, effect.first);
        final second = _require(catalog.marks, effect.second);
        if (first.sourceScoped ||
            second.sourceScoped ||
            first.id == second.id ||
            first.maxCount != null ||
            second.maxCount != null ||
            first.group != null ||
            second.group != null) {
          throw StateError(
            'Mark flip requires distinct uncapped holder-wide marks',
          );
        }
        if (!['first', 'second', 'toggle'].contains(effect.mode)) {
          throw StateError('Invalid mark flip');
        }
      }
      if (effect is EditStatus) {
        _checkStatusQuery(effect.query);
        if (effect.createIfMissing &&
            (effect.mode != StatusEditMode.add ||
                (!effect.query.chosen &&
                    effect.query.statusId == null &&
                    effect.query.statusIds.isEmpty))) {
          throw StateError(
            'Status creation requires explicit definitions or chosen status',
          );
        }
      }
      if (effect is TransferStatus) {
        _checkStatusQuery(effect.query);
        if (effect.to != EffectTarget.self &&
            effect.to != EffectTarget.selected) {
          throw StateError('Transfer destination must be self or selected');
        }
      }
      if (effect is ApplyStatus) {
        _require(catalog.statuses, effect.statusId);
        if (effect.damageLimit != null && effect.damageLimit! <= 0) {
          throw StateError('Invalid status damage limit');
        }
        for (final id in effect.ignoreNegativeProtection) {
          _require(catalog.statuses, id);
        }
      }
      if (effect is ModifyAppliedStatus) {
        _require(catalog.statuses, effect.statusId);
      }
      if (effect is GrantExtraTurns && effect.count < 0) {
        throw StateError('Invalid extra turn count');
      }
      if (effect is HealToFraction &&
          (effect.fraction < 0 || effect.fraction > 1)) {
        throw StateError('Invalid HP fraction');
      }
      if (effect is ModifyMark) _require(catalog.marks, effect.markId);
      if (effect is ModifyStat) _checkEffects(effect.onClamp);
      if (effect is RemoveStatuses && effect.statusId != null) {
        _require(catalog.statuses, effect.statusId!);
      }
      final value = switch (effect) {
        HealEffect() => effect.value,
        DamageEffect() => effect.value,
        ModifyMark() => effect.value,
        _ => null,
      };
      if (value?.field == ValueField.markCount) {
        _require(catalog.marks, value!.markId ?? '');
      }
      if (effect is DamageEffect) {
        _checkEffects(effect.onDamage);
        if (_walkEffects(
          effect.onDamage,
        ).any((e) => e is ChooseEffect || e is SelectOptionEffect)) {
          throw StateError('Damage follow-up must be atomic');
        }
      }
      if (effect is ChooseEffect &&
          effect.random &&
          (effect.kind != ChoiceKind.character ||
              effect.chooser != ChoiceChooser.actor ||
              effect.optional ||
              effect.preserveSelected)) {
        throw StateError(
          'Random selection requires mandatory character selection',
        );
      }
      if (effect is ChooseEffect &&
          [
            ChoiceKind.discardPileCard,
            ChoiceKind.deckCard,
          ].contains(effect.kind) &&
          (effect.target != EffectTarget.self ||
              effect.chooser != ChoiceChooser.actor ||
              effect.minimumDeckCopies < 0)) {
        throw StateError('Invalid public card choice');
      }
      if (effect is CancelSkill && effect.discardCount < 0) {
        throw StateError('Invalid canceled skill discard count');
      }
      if (effect is RandomDiscard && effect.count < 0) {
        throw StateError('Invalid random discard count');
      }
      if (effect is TransferReceivedDamage &&
          effect.target != EffectTarget.selected) {
        throw StateError('Damage transfer requires one selected target');
      }
      if (effect is PayMp && effect.amount < 0) {
        throw StateError('Invalid MP payment');
      }
      if (effect is HealEffect &&
          (effect.sourceTraitId?.isEmpty == true ||
              effect.targetTraitId?.isEmpty == true)) {
        throw StateError('Healing trait filters must not be empty');
      }
      if (effect is ModifyVariable) _checkVariableEffect(effect);
      if (effect is ConditionalEffect && effect.when is VariableCondition) {
        _checkVariableCondition(effect.when as VariableCondition);
      }
      if (effect is ArmTrigger) _checkTriggers([], effect.triggers);
      if (effect is RollEffect) {
        if (effect.bind != null &&
            !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(effect.bind!)) {
          throw StateError('Invalid dice result binding');
        }
        if (effect.sides <= 0 || effect.count <= 0) {
          throw StateError('Invalid dice');
        }
        _checkEffects(effect.effects);
        _checkEffects(effect.otherwise);
      }
      if (effect is ConditionalEffect) {
        if (effect.when is AnyCondition ||
            effect.when is HpRatioCondition ||
            effect.when is LivingCountCondition ||
            effect.when is RelationCondition ||
            effect.when is HasStatusQueryCondition ||
            effect.when is ValueCondition) {
          _checkChoiceCondition(effect.when);
        }
        if (effect.when case PlayedCardCondition(:final cardIds)) {
          for (final id in cardIds) {
            _require(catalog.cards, id);
          }
        }
        if (effect.when case MarkCondition(:final markId)) {
          _require(catalog.marks, markId);
        }
        if (effect.when case HasStatusCondition(:final statusId)) {
          _require(catalog.statuses, statusId);
        }
        _checkEffects(effect.effects);
        _checkEffects(effect.otherwise);
      }
      if (effect is DiceContest && effect.sides <= 0) {
        throw StateError('Invalid contest dice');
      }
      if (effect is DrawSkill &&
          (effect.uses <= 0 || effect.count < 1 || effect.count > 128)) {
        throw StateError('Invalid skill uses');
      }
      if (effect is ScheduleEffect) {
        if (effect.after < 0 ||
            (effect.phase != SchedulePhase.turnEnd &&
                effect.phase != SchedulePhase.roundEnd &&
                effect.after == 0)) {
          throw StateError('Invalid schedule offset');
        }
        for (final child in _walkEffects(effect.effects)) {
          if (effect.captureValues &&
              _effectValues(child).isNotEmpty &&
              child.target != EffectTarget.self &&
              child.target != EffectTarget.selected) {
            throw StateError(
              'Captured values require self or selected targets',
            );
          }
          _checkVariableContext(child, allowEvent: false);
          if (!effect.captureValues &&
              _effectValues(child)
                  .expand(_valueTree)
                  .any(
                    (v) =>
                        (v.reference?.startsWith('local.') ?? false) ||
                        v.field == ValueField.cardCount ||
                        v.field == ValueField.cardTagCount ||
                        ((v.field == ValueField.statusStacks ||
                                v.field == ValueField.statusStrength) &&
                            v.statusId == null),
                  )) {
            throw StateError(
              'Deferred expressions cannot retain a selected status or played cards',
            );
          }
          if (child is SetCounter ||
              child is ChooseEffect ||
              child is SelectOptionEffect ||
              child is ModifyAttack ||
              child is ModifyAttackPower ||
              (child is ConditionalEffect &&
                  child.when is CounterEqualsCondition) ||
              child is SetDiceResult ||
              child is CancelSkill ||
              child is ModifyOwnStatus ||
              (child is ModifyCooldown && child.usedSkillOnly) ||
              (_contextValue(child) != null && !effect.captureValues) ||
              child.target == EffectTarget.eventSource ||
              child.target == EffectTarget.eventTarget) {
            throw StateError(
              'Deferred effects cannot retain transient trigger or response context',
            );
          }
        }
        _checkEffects(effect.effects);
      }
    }
  }

  void _effects(
    CharacterInstance actor,
    List<String> selected,
    List<EffectDefinition> effects, {
    int multiplier = 1,
    AttackPacket? attackPacket,
    StatusInstance? statusOrigin,
  }) {
    final old = _effectStatus;
    _effectStatus = statusOrigin ?? old;
    try {
      _effectsBody(
        actor,
        selected,
        effects,
        multiplier: multiplier,
        attackPacket: attackPacket,
      );
    } finally {
      _effectStatus = old;
    }
  }

  void _effectsBody(
    CharacterInstance actor,
    List<String> selected,
    List<EffectDefinition> effects, {
    int multiplier = 1,
    AttackPacket? attackPacket,
  }) {
    for (final effect in effects) {
      _checkPreviewEffect(effect);
      if (effect is MoveCards) {
        _moveQueryCards(
          actor,
          selected,
          effect,
          multiplier: _interactionRulesVersion >= 18 ? multiplier : 1,
        );
        continue;
      }
      final targets = _effectTargets(
        actor,
        selected,
        effect.target,
        attackPacket: attackPacket,
      );
      for (final target in targets) {
        if (!target.alive) continue;
        switch (effect) {
          case TransferShield():
            final amount = target.shield.clamp(0, effect.limit);
            _performance.shieldRemoved(actor, target, amount);
            final before = target.shield;
            target.shield -= amount;
            var remaining = amount;
            for (var i = 0; i < target.temporaryShields.length; i++) {
              final shield = target.temporaryShields[i];
              final consumed = shield.remaining.clamp(0, remaining);
              shield.remaining -= consumed;
              remaining -= consumed;
            }
            target.temporaryShields.removeWhere((s) => s.remaining == 0);
            _effects(actor, [], [ShieldEffect(amount)]);
            _event('shieldTransferred', {
              'sourceId': target.instanceId,
              'targetId': actor.instanceId,
              'amount': amount,
            });
            if (before > 0 && target.shield == 0) {
              _event('shieldBroken', {
                'targetId': target.instanceId,
                'sourceId': actor.instanceId,
              });
            }
          case RemoveSummons():
            var count = 0;
            for (final unit in state.summonedUnits) {
              if (unit.alive &&
                  unit.ownerId == target.instanceId &&
                  unit.kind == effect.kind) {
                unit.alive = false;
                count++;
              }
            }
            _event('summonsRemoved', {
              'actorId': actor.instanceId,
              'targetId': target.instanceId,
              'kind': effect.kind,
              'count': count,
            });
          case ArmAttack():
            actor.armedAttacks.add(
              ArmedAttack(effect, effect.copyDamage ? target.instanceId : null),
            );
          case EditMarks():
            _editQueryMarks(actor, target, effect, multiplier);
          case TransferMarks():
            _transferQueryMarks(actor, target, selected, effect);
          case EditSkills():
            _editQuerySkills(actor, target, effect, multiplier);
          case MoveCards():
            throw StateError('Card moves require collection scope');
          case ChooseObjects():
            throw StateError('Object choices require an ability frame');
          case EditStatus():
            _editStatuses(actor, target, effect, multiplier);
          case TransferStatus():
            _transferStatuses(actor, target, selected, effect);
          case ModifyMark():
            _modifyMark(actor, target, effect, multiplier);
          case ModifyVariable():
            _modifyVariable(actor, target, effect);
          case ImpactEffect():
            _performance.otherEffect(actor, target, positive: false);
            _event('impact', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'targets': List<String>.unmodifiable([target.instanceId]),
            });
          case CancelCard():
            throw StateError('Card cancellation requires a response frame');
          case WithTargets():
          case GenerateRandomAction():
          case BorrowSkillEffect():
          case CheckContinuation():
          case GenerateChosenCard():
            throw StateError('Card generation requires ability frame');
          case ChooseCards():
            throw StateError('Hand choices require an ability frame');
          case ChooseTargets():
          case SelectOptionEffect():
          case ChooseEffect():
            throw StateError('Choice requires ability continuation');
          case ModifyAttackPower():
            _modifyAttackPower(actor, target, effect, multiplier);
          case FlipMarks():
            _flipMarks(actor, target, effect);
          case ForceNextAttackTarget():
            _performance.otherEffect(
              actor,
              target,
              positive: false,
              kind: 'forcedTarget',
            );
            _performance.forceTarget(actor, target);
            target.nextAttackTargetId = actor.instanceId;
            _event('attackTargetForced', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'requiredTargetId': actor.instanceId,
            });
          case ModifyActionDice():
            throw StateError('Action dice rewards require tagRewards');
          case ClearProtection():
            _clearProtection(actor, target, effect);
          case SummonUnit():
            _summonUnit(actor, target, effect);
          case SettleStatus():
            throw StateError('Status settlement requires the ability runner');
          case UseTimeReserve():
            throw StateError('Time reserve requires the ability runner');
          case ConvertStatus():
            _convertStatus(actor, target, effect);
          case RestrictCardTag():
          case DisableHandCards():
            throw StateError('Interactive operation requires ability flow');
          case ArmTrigger():
          case DiscardHand():
          case StealEffect():
          case SwapHands():
          case SwapStatuses():
          case DrawSkill():
          case BlockStatusApplication():
          case ModifyAttack():
          case SetCounter():
          case ConditionalEffect():
          case RollEffect():
          case DiceContest():
            _extendedEffect(
              actor,
              target,
              selected,
              effect,
              multiplier,
              attackPacket,
            );
          case ModifyStat():
            if (attackPacket != null &&
                effect.oncePerAction &&
                !_oncePerAttackEffects.add(effect)) {
              continue;
            }
            final change =
                _amount(effect.amount, effect.value, actor, target) *
                multiplier;
            final previousValue = target.value(effect.stat);
            target.permanentModifiers.update(
              effect.stat,
              (n) => n + change,
              ifAbsent: () => change,
            );
            final clipped =
                effect.stat == Stat.maxHp &&
                target.hp > target.value(Stat.maxHp);
            _normalize(target);
            if (target.value(effect.stat) != previousValue) {
              _performance.otherEffect(
                actor,
                target,
                positive: target.value(effect.stat) > previousValue,
                kind: 'stat',
              );
              _performance.statChange(
                actor,
                target,
                effect.stat,
                target.value(effect.stat) - previousValue,
              );
            }
            _event('statModified', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'stat': effect.stat.name,
              'amount':
                  _interactionRulesVersion >= 6 &&
                      (effect.stat == Stat.maxHp || effect.stat == Stat.maxMp)
                  ? target.value(effect.stat) - previousValue
                  : change,
              'result': target.value(effect.stat),
            });
            if (clipped) {
              _effects(
                actor,
                [target.instanceId],
                effect.onClamp,
                multiplier: multiplier,
              );
            }
          case CaptureSave():
            _turnSaveModule.capture(actor, explicit: true);
          case ConvertShieldToLife():
            final shield = target.shield;
            target.shield = 0;
            target.temporaryShields.clear();
            _effects(
              actor,
              [target.instanceId],
              [
                RestoreLife(
                  (shield * effect.factor).floor(),
                  target: EffectTarget.selected,
                ),
              ],
            );
            _event('shieldConverted', {
              'actorId': target.instanceId,
              'amount': shield,
            });
          case RestoreLife():
            final amount =
                (_amount(effect.amount, effect.value, actor, target) *
                        multiplier)
                    .clamp(0, 1000000000);
            final before = target.hp;
            if (!target.defenseLife) {
              target.hp = (before + amount).clamp(
                -1000000000,
                target.value(Stat.maxHp),
              );
            }
            _event('lifeRestored', {
              'sourceId': actor.instanceId,
              'actorId': target.instanceId,
              'targetId': target.instanceId,
              'before': before,
              'hp': target.hp,
              'amount': target.hp - before,
            });
            _normalize(target);
          case SetLife():
            final before = target.hp;
            if (!target.defenseLife) {
              target.hp = _amount(
                effect.amount,
                effect.value,
                actor,
                target,
              ).clamp(-1000000000, target.value(Stat.maxHp));
            }
            _event('lifeSet', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'before': before,
              'hp': target.hp,
            });
            _normalize(target);
          case HealEffect():
            bool holdsTrait(CharacterInstance character, String id) =>
                character.alive &&
                !_blocked(character, (s) => s.blockTraits) &&
                character.traits.any((t) => t.definition.id == id);
            if (effect.targetTraitId != null &&
                !holdsTrait(target, effect.targetTraitId!)) {
              continue;
            }
            CharacterInstance? source = actor;
            if (effect.sourceTraitId case final id?) {
              final statusSource =
                  _currentTrigger?.status?.sourceId ?? _effectStatus?.sourceId;
              final candidates = state.players
                  .map((p) => p.character)
                  .where((c) => holdsTrait(c, id))
                  .toList();
              source =
                  candidates
                      .where((c) => c.instanceId == statusSource)
                      .firstOrNull ??
                  candidates.firstOrNull;
            }
            if (source == null) continue;
            _heal(
              source,
              target,
              _amount(effect.amount, effect.value, actor, target) * multiplier,
            );
          case DamageEffect():
            final eventStart = state.events.length;
            _damage(
              effect.sourceless
                  ? null
                  : (effect.fromStatusSource
                        ? (_currentTrigger?.status?.sourceId == null
                              ? null
                              : _character(_currentTrigger!.status!.sourceId!))
                        : actor),
              target,
              _amount(effect.amount, effect.value, actor, target) * multiplier,
              effect.kind,
              attack: attackPacket != null,
              packet: attackPacket,
              secondary: attackPacket != null,
            );
            final damageEvent = state.events
                .skip(eventStart)
                .where((e) => e.type == 'damage')
                .firstOrNull;
            if (damageEvent != null &&
                (damageEvent.data['amount']! as int) > 0) {
              _effects(actor, [target.instanceId], effect.onDamage);
            }
          case TransferReceivedDamage():
            final consumed = _consumeReceivedDamage(actor);
            final amount = consumed.amount;
            final before = actor.hp;
            if (!actor.defenseLife) {
              actor.hp = (actor.hp + consumed.lifeRefund).clamp(
                0,
                actor.value(Stat.maxHp),
              );
            }
            _event('damageRefunded', {
              'actorId': actor.instanceId,
              'amount': actor.hp - before,
              'transferredAmount': amount,
              'round': state.round,
            });
            _damage(actor, target, amount, DamageKind.physical);
          case StealLife():
            final sourceId =
                _currentTrigger?.status?.sourceId ?? _effectStatus?.sourceId;
            final source = effect.fromStatusSource && sourceId != null
                ? _character(sourceId)
                : actor;
            _stealLife(
              source,
              target,
              _amount(effect.amount, effect.value, actor, target) * multiplier,
              healNominal: effect.healNominal,
            );
          case ShieldEffect():
            final amount =
                _amount(effect.amount, effect.value, actor, target) *
                multiplier;
            target.shield += amount;
            if (amount != 0) {
              _performance.otherEffect(
                actor,
                target,
                positive: amount > 0,
                kind: 'shield',
              );
            }
            if (!_blocked(target, (s) => s.blockTraits)) {
              for (final trait in target.traits) {
                final rule = trait.definition.resourceAbilities;
                if (rule.shieldDefenseFactor == 0) continue;
                target.temporaryDefense.add((
                  amount: (amount * rule.shieldDefenseFactor).floor(),
                  expires: target.turnsStarted + rule.shieldDefenseTurns,
                ));
              }
            }
            _event('shieldGained', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'amount': amount,
            });
          case ReverseTurnOrder():
            state.reverseNextRound = !state.reverseNextRound;
          case ScheduleEffect():
            final progress = switch (effect.phase) {
              SchedulePhase.turnStart => target.turnsStarted,
              SchedulePhase.turnEnd => target.turnsClosed,
              SchedulePhase.roundStart || SchedulePhase.roundEnd => state.round,
            };
            state.scheduledEffects.add(
              ScheduledEffect(
                id: state.id('schedule'),
                sourceId: actor.instanceId,
                anchorId: target.instanceId,
                phase: effect.phase,
                due: progress + effect.after,
                effects: effect.effects,
                multiplier: multiplier,
                capturedValues: effect.captureValues
                    ? {
                        for (final child in _walkEffects(effect.effects))
                          for (final value in _effectValues(child))
                            (
                              value,
                              child.target == EffectTarget.self
                                  ? actor.instanceId
                                  : target.instanceId,
                            ): _numberValue(
                              value,
                              actor,
                              child.target == EffectTarget.self
                                  ? actor
                                  : target,
                            ),
                      }
                    : const {},
              ),
            );
          case HealToFraction():
            final wanted = (target.value(Stat.maxHp) * effect.fraction).floor();
            if (wanted > target.hp) _heal(actor, target, wanted - target.hp);
          case ModifyAppliedStatus():
            final status = target.statuses
                .where((s) => s.definition.id == effect.statusId)
                .firstOrNull;
            if (status != null) {
              _increaseStatus(
                status,
                effect.stacks * multiplier,
                effect.intensity * multiplier,
                source: actor,
              );
            }
          case GrantExtraTurns():
            final added = (effect.count * multiplier).clamp(0, 100);
            target.extraTurns += added;
            _performance.actionChange(
              actor,
              target,
              added * rules.actionsPerTurn,
            );
          case GrantActions():
            final before = target.actionsRemaining;
            target.actionsRemaining =
                (target.actionsRemaining +
                        _amount(effect.count, effect.value, actor, target) *
                            multiplier)
                    .clamp(0, 1000000);
            _performance.actionChange(
              actor,
              target,
              target.actionsRemaining - before,
            );
          case SwapResources():
            if (target == actor) continue;
            final actorHp = actor.defenseLife ? 0 : actor.hp;
            final targetHp = target.defenseLife ? 0 : target.hp;
            final actorMp = actor.mp;
            final targetMp = target.mp;
            if (effect.hp) {
              if (!actor.defenseLife) {
                actor.hp = targetHp.clamp(0, actor.value(Stat.maxHp));
              }
              if (!target.defenseLife) {
                target.hp = actorHp.clamp(0, target.value(Stat.maxHp));
              }
            }
            if (effect.mp) {
              actor.mp = actor.noMp
                  ? 0
                  : targetMp.clamp(_mpFloor(actor), actor.value(Stat.maxMp));
              target.mp = target.noMp
                  ? 0
                  : actorMp.clamp(_mpFloor(target), target.value(Stat.maxMp));
              _scoreResourceChange(actor, actor, actor.mp - actorMp);
              _scoreResourceChange(actor, target, target.mp - targetMp);
            }
            _event('resourcesSwapped', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'hp': effect.hp,
              'mp': effect.mp,
              'sourceHp': actor.defenseLife ? 0 : actor.hp,
              'targetHp': target.defenseLife ? 0 : target.hp,
              'sourceMp': actor.mp,
              'targetMp': target.mp,
            });
            _normalize(actor);
            _normalize(target);
          case EqualizeHand():
            _draw(
              actor,
              (target.hand.length - actor.hand.length).clamp(0, 1000000),
              source: actor,
            );
          case RandomDiscard():
            final cards = target.hand
                .where(
                  (c) =>
                      !c.disabled &&
                      _matchesCard(c, effect.query, actor, target),
                )
                .toList();
            _shuffle(cards);
            final discarded = cards
                .take(
                  (_amount(effect.count, effect.value, actor, target) *
                          multiplier)
                      .clamp(0, cards.length),
                )
                .toList();
            for (final card in discarded) {
              target.hand.remove(card);
              state.discardPile.add(card);
            }
            _discardedCount += discarded.length;
            if (discarded.isNotEmpty) {
              _scoreResourceChange(
                actor,
                target,
                -discarded.length,
                resource: StatisticsResource.hand,
              );
              _event('cardsLost', {
                'actorId': target.instanceId,
                'count': discarded.length,
              });
              _event('cardsDiscarded', {
                'actorId': target.instanceId,
                'cards': List<String>.unmodifiable(
                  discarded.map((c) => c.instanceId),
                ),
              });
            }
          case DrawEffect():
            _draw(
              target,
              _amount(effect.count, effect.value, actor, target) * multiplier,
              source: actor,
            );
          case ApplyStatus():
            _applyStatus(
              actor,
              target,
              ApplyStatus(
                effect.statusId,
                stacks: _amount(
                  effect.stacks,
                  effect.stacksValue,
                  actor,
                  target,
                ),
                refreshSource: effect.refreshSource,
                ignoreNegativeProtection: effect.ignoreNegativeProtection,
                damageLimit: effect.damageLimit,
                intensity: _amount(
                  effect.intensity,
                  effect.intensityValue,
                  actor,
                  target,
                ),
                target: effect.target,
              ),
              multiplier,
            );
          case PayLife():
            final nominal = _amount(0, effect.value, actor, actor);
            if (nominal < 0 || (!actor.defenseLife && actor.hp < nominal)) {
              throw StateError('Insufficient life fee');
            }
            final paid = actor.defenseLife ? 0 : nominal;
            actor.hp -= paid;
            _event('lifePaid', {
              'actorId': actor.instanceId,
              'amount': paid,
              'nominalAmount': nominal,
            });
          case PayMp():
            final amount = _amount(
              effect.amount,
              effect.value,
              actor,
              target,
            ).clamp(0, 1000000);
            _checkMp(target, amount);
            _payMp(target, amount);
          case ArmAttackTransfer():
            if (_chosenStatus == null ||
                !actor.statuses.contains(_chosenStatus)) {
              throw StateError('Status transfer selection is stale');
            }
            actor.armedStatusTransfer = StatusTransferPlan(
              _chosenStatus!.instanceId,
              effect.followAttackTarget ? null : target.instanceId,
            );
          case ModifyMp():
            final amount = _amount(effect.amount, effect.value, actor, target);
            if (amount > 0 && _blocked(target, (s) => s.blockMpRegen)) {
              final wanted =
                  (amount * multiplier +
                          target.statuses.fold<int>(
                            0,
                            (n, s) =>
                                n +
                                s.definition.mpRecoveryFlatPerIntensity *
                                    s.intensity,
                          ))
                      .clamp(
                        0,
                        target.noMp
                            ? 0
                            : (target.value(Stat.maxMp) - target.mp).clamp(
                                0,
                                1000000,
                              ),
                      );
              _performance.blockedResource(
                target,
                wanted,
                resource: StatisticsResource.mp,
                blocked: (s) => s.blockMpRegen,
              );
              continue;
            }
            final previous = target.mp;
            final adjustment = amount > 0
                ? _mpRecovery(target, amount * multiplier)
                : amount * multiplier;
            target.mp = (target.mp + (target.noMp ? 0 : adjustment)).clamp(
              _mpFloor(target),
              target.value(Stat.maxMp),
            );
            _negativeMpCrossed(actor, target, previous);
            _scoreResourceChange(actor, target, target.mp - previous);
            if (previous > 0 &&
                target.mp == 0 &&
                target.race.regenMode == MpRegenMode.refillAfterExhaustion) {
              target.refillAfterExhaustionPending = true;
            }
            _event('mpChanged', {
              'sourceId': actor.instanceId,
              'targetId': target.instanceId,
              'amount': target.mp - previous,
              'nominalAmount': adjustment,
              'overflow': adjustment > 0
                  ? (adjustment - (target.mp - previous))
                  : 0,
            });
          case ModifyCooldown():
            for (final skill in target.skills) {
              if (!_matchesSkillData(
                _skillQueryData(skill, target.instanceId),
                effect.query,
                actor,
                target,
              )) {
                continue;
              }
              if (effect.skillId != null &&
                  skill.definition.id != effect.skillId) {
                continue;
              }
              if (effect.usedSkillOnly &&
                  skill.instanceId != _currentTrigger?.fact.skill) {
                continue;
              }
              final oldCooldown = skill.cooldown;
              _setSkillCooldown(
                skill,
                (skill.cooldown +
                        _amount(effect.amount, effect.value, actor, target) *
                            multiplier)
                    .clamp(0, 1000000),
              );
              _performance.cooldownChange(
                actor,
                target,
                skill.cooldown - oldCooldown,
              );
            }
          case TransferMp():
            if (target == actor || target.noMp || effect.amount <= 0) break;
            final amount = (effect.amount * multiplier).clamp(
              0,
              target.mp.clamp(0, 1000000),
            );
            if (amount > 0) {
              _effects(
                actor,
                [target.instanceId],
                [
                  ModifyMp(-amount, target: EffectTarget.selected),
                  ModifyMp(amount),
                ],
              );
            }
          case ModifyOwnStatus():
            final status = _currentTrigger?.status;
            if (status == null || !target.statuses.contains(status)) break;
            if (status.definition.category == StatusCategory.anomaly &&
                (effect.stacks > 0 ||
                    (_interactionRulesVersion >= 5
                        ? effect.intensity != 0
                        : effect.intensity > 0))) {
              break;
            }
            if (!status.definition.hasIntensity && effect.intensity != 0) break;
            final oldStacks = status.stacks;
            final oldIntensity = status.intensity;
            final previousLimits = _resourceLimits(target);
            status.intensity = (status.intensity + effect.intensity).clamp(
              1,
              status.definition.maxIntensity ?? 1000000,
            );
            status.stacks += effect.stacks;
            if (status.definition.maxStacks != null) {
              status.stacks = status.stacks.clamp(
                0,
                status.definition.maxStacks!,
              );
            }
            _performance.statusChange(
              actor,
              target,
              status.definition,
              oldStacks,
              oldIntensity,
              status.stacks,
              status.intensity,
            );
            if (status.stacks <= 0) {
              _consumeStatus(
                target,
                status,
                amount: 0,
                limitBefore: previousLimits,
              );
            } else {
              _normalize(target);
              _logResourceLimitChanges(target, previousLimits, source: actor);
            }
          case RemoveStatuses():
            for (final status in List<StatusInstance>.of(target.statuses)) {
              if ((effect.statusId != null ||
                      _isStatusEffect(status.definition)) &&
                  (effect.statusId == null ||
                      status.definition.id == effect.statusId) &&
                  (effect.includeAnomalies ||
                      status.definition.category != StatusCategory.anomaly) &&
                  (!effect.negativeOnly ||
                      _matchesNegativeCleanse(status.definition))) {
                _consumeStatus(
                  target,
                  status,
                  amount: status.stacks,
                  statisticsSource: actor,
                );
              }
            }
          case RedirectAttack():
          case SetDiceResult():
          case CancelSkill():
            throw StateError('Response effect outside response handler');
        }
      }
    }
    _drainTriggers();
  }

  List<CharacterInstance> _effectTargets(
    CharacterInstance actor,
    List<String> selected,
    EffectTarget target, {
    AttackPacket? attackPacket,
  }) {
    final team = state.players.firstWhere((p) => p.character == actor).teamId;
    final List<CharacterInstance> targets = switch (target) {
      EffectTarget.statusSource =>
        _currentTrigger?.status?.sourceId == null
            ? []
            : [_character(_currentTrigger!.status!.sourceId!)],
      EffectTarget.eventSource =>
        _currentTrigger?.fact.source == null
            ? []
            : [_character(_currentTrigger!.fact.source!)],
      EffectTarget.eventTarget =>
        _currentTrigger?.fact.target == null
            ? []
            : [_character(_currentTrigger!.fact.target!)],
      EffectTarget.highestHp =>
        state.players
            .map((p) => p.character)
            .where(
              (c) =>
                  c.alive &&
                  state.players
                      .where((p) => p.character.alive)
                      .every((p) => c.hp >= p.character.hp),
            )
            .toList(),
      EffectTarget.lowestHp =>
        state.players
            .map((p) => p.character)
            .where(
              (c) =>
                  c.alive &&
                  state.players
                      .where((p) => p.character.alive)
                      .every((p) => c.hp <= p.character.hp),
            )
            .take(1)
            .toList(),
      EffectTarget.others =>
        state.players.map((p) => p.character).where((c) => c != actor).toList(),
      EffectTarget.selfOrSelected => {
        actor,
        ...selected.map(_character),
      }.toList(),
      EffectTarget.self => [actor],
      EffectTarget.selected => selected.map(_character).toList(),
      EffectTarget.all => state.players.map((p) => p.character).toList(),
      EffectTarget.allies =>
        state.players
            .where((p) => p.teamId == team)
            .map((p) => p.character)
            .toList(),
      EffectTarget.enemies =>
        state.players
            .where((p) => p.teamId != team)
            .map((p) => p.character)
            .toList(),
    };
    return attackPacket == null
        ? targets
        : targets
              .where((c) => _attackEffectTargetAllowed(c, attackPacket))
              .toList();
  }

  CharacterInstance _previousPlayer(CharacterInstance actor) {
    final index = state.players.indexWhere((p) => p.character == actor);
    for (var offset = 1; offset < state.players.length; offset++) {
      final candidate = state
          .players[(index - offset + state.players.length) %
              state.players.length]
          .character;
      if (candidate.alive) return candidate;
    }
    return actor;
  }

  bool _conditionMatches(
    ConditionDefinition? condition,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    if (condition == null) return true;
    switch (condition) {
      case PredicateCondition():
        return _predicate(condition, actor, target);
      case AllCondition():
        return condition.conditions.every(
          (c) => _conditionMatches(c, actor, target),
        );
      case NotCondition():
        return !_conditionMatches(condition.condition, actor, target);
      case ValueCondition():
        final left = _numberValue(condition.left, actor, target);
        final right = _numberValue(condition.right, actor, target);
        return switch (condition.comparison) {
          NumericComparison.equals => left == right,
          NumericComparison.greaterThan => left > right,
          NumericComparison.atLeast => left >= right,
          NumericComparison.atMost => left <= right,
          NumericComparison.lessThan => left < right,
        };
      case MarkCondition():
        if (_previewMode) throw const PreviewBoundary('unprojectedMarks');
        final holder = condition.subject == EffectTarget.self ? actor : target;
        final matches =
            _markCount(
              holder,
              condition.markId,
              sourceId: condition.fromSelf ? actor.instanceId : null,
            ) >=
            condition.minimum;
        return condition.negate ? !matches : matches;
      case RelationCondition():
        return _effectTargets(
          actor,
          const [],
          condition.among,
        ).contains(target);
      case LivingCountCondition():
        return _effectTargets(actor, [target.instanceId], condition.among)
                .where(
                  (c) =>
                      c.alive &&
                      (!condition.selectedOnly ||
                          (_currentTrigger?.fact.selected.contains(
                                c.instanceId,
                              ) ??
                              false)) &&
                      (!condition.excludeSelf || c != actor) &&
                      _conditionMatches(condition.when, actor, c),
                )
                .length >=
            condition.atLeast;
      case HpRatioCondition():
        final subject = switch (condition.subject) {
          ValueSubject.self => actor,
          ValueSubject.selected => target,
          ValueSubject.previousPlayer => _previousPlayer(actor),
        };
        return subject.hp < subject.value(Stat.maxHp) * condition.fraction;
      case AnyCondition():
        return condition.conditions.any(
          (c) => _conditionMatches(c, actor, target),
        );
      case VariableCondition():
        return _variableCondition(condition, actor, target);
      case CounterEqualsCondition():
        if (_previewMode) {
          throw const PreviewBoundary('unprojectedTriggerHistory');
        }
        return _currentTrigger?.memory.counters[condition.counter] ==
            condition.amount;
      case PlayedCardCondition():
        return _effectCards.any(
          (c) => condition.cardIds.contains(c.definition.id),
        );
      case HasStatusQueryCondition():
        return _queryStatuses(target, condition.query, actor: actor).isNotEmpty;
      case HasStatusCondition():
        return target.statuses.any(
          (s) => s.definition.id == condition.statusId,
        );
      case HasShieldCondition():
        return target.shield > 0;
      case StatExtremumCondition():
        final subject = condition.subject == EffectTarget.self ? actor : target;
        final candidates = _effectTargets(
          actor,
          const [],
          condition.among,
        ).where((c) => c.alive).toList();
        if (!candidates.contains(subject)) return false;
        final value = subject.value(condition.stat);
        return candidates.every(
          (c) => condition.highest
              ? value >= c.value(condition.stat)
              : value <= c.value(condition.stat),
        );
    }
  }

  int _amount(
    int fallback,
    EffectValue? value,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    if (value == null) return fallback;
    return _numberValue(value, actor, target).floor();
  }

  double _numberValue(
    EffectValue value,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    if (_scheduledValues.containsKey((value, target.instanceId))) {
      return _scheduledValues[(value, target.instanceId)]!;
    }
    if (value.reference != null) {
      final resolved = _referenceValue(value.reference!, actor, target);
      if (resolved is! num || !resolved.isFinite) {
        throw StateError('Reference is not numeric: ${value.reference}');
      }
      return value.constant + resolved.toDouble() * value.factor;
    }
    if (value.operation != null) return _calculateValue(value, actor, target);
    final subject = switch (value.subject) {
      ValueSubject.self => actor,
      ValueSubject.selected => target,
      ValueSubject.previousPlayer => _previousPlayer(actor),
    };
    if (_previewMode &&
        const {
          ValueField.markCount,
          ValueField.markTotal,
          ValueField.handCount,
          ValueField.damageThisTurn,
          ValueField.damageThisRound,
          ValueField.damageDealtThisGlobalRound,
          ValueField.damageReceivedThisGlobalRound,
          ValueField.healedPreviousGlobalRound,
        }.contains(value.field)) {
      throw const PreviewBoundary('unprojectedCalculationState');
    }
    final field = switch (value.field) {
      null => 0,
      ValueField.collection => _collectionNumber(
        value.collection!,
        actor,
        subject,
      ),
      ValueField.variableListValue ||
      ValueField.variableNumber ||
      ValueField.variableSize ||
      ValueField.variableMapValue ||
      ValueField.variableNewTagCount => _variableNumber(
        value,
        subject,
        actor,
        target,
      ),
      ValueField.eventTagCount =>
        value.tags.isEmpty
            ? (_currentTrigger?.fact.tags.values.fold<int>(
                    0,
                    (n, v) => n > v ? n : v,
                  ) ??
                  0)
            : value.tags.fold<int>(
                0,
                (n, tag) => n + (_currentTrigger?.fact.tags[tag] ?? 0),
              ),
      ValueField.eventAmount => _currentTrigger?.fact.amount ?? 0,
      ValueField.eventSkillCooldown => _currentTrigger?.fact.skillCooldown ?? 0,
      ValueField.eventStatusStackDelta =>
        _currentTrigger?.fact.statusStackDelta ?? 0,
      ValueField.eventStatusIntensity =>
        _currentTrigger?.fact.statusIntensity ?? 0,
      ValueField.summonedCount =>
        state.summonedUnits
            .where(
              (u) =>
                  u.alive &&
                  u.ownerId == subject.instanceId &&
                  (value.summonKind == null || u.kind == value.summonKind),
            )
            .length,
      ValueField.livingCount =>
        _effectTargets(
              actor,
              const [],
              value.among,
            ).where((c) => c.alive).length +
            (value.includeSummoned ? _summonedCount(actor, value.among) : 0),
      ValueField.eventAttackBaseDamage => _currentTrigger?.fact.baseDamage ?? 0,
      ValueField.counter =>
        _currentTrigger?.memory.counters[value.counter] ?? 0,
      ValueField.markCount => _markCount(
        subject,
        value.markId!,
        sourceId: value.markFromSelf ? actor.instanceId : null,
      ),
      ValueField.statusIntensity => _currentTrigger?.intensity ?? 1,
      ValueField.rolled => _rolled,
      ValueField.inputNumber => _abilityNumber,
      ValueField.discardedCount => _discardedCount,
      ValueField.attackDamage => _attackDamage,
      ValueField.attackDice => _attackDiceFinal,
      ValueField.cardTagCount => _effectCards.fold<int>(
        0,
        (n, c) => n + c.definition.tags.length,
      ),
      ValueField.cardCount =>
        _effectCards
            .where(
              (c) =>
                  value.tags.isEmpty ||
                  value.tags.any(c.definition.tags.contains),
            )
            .length,
      ValueField.statusStacks => _valueStatus(subject, value)?.stacks ?? 0,
      ValueField.statusStrength => _valueStatus(subject, value)?.intensity ?? 0,
      ValueField.hp => subject.hp,
      ValueField.missingHp => (subject.value(Stat.maxHp) - subject.hp).clamp(
        0,
        1000000,
      ),
      ValueField.maxMp => subject.value(Stat.maxMp).toDouble(),
      ValueField.maxHp => subject.value(Stat.maxHp),
      ValueField.attack => subject.value(Stat.attack),
      ValueField.defense => subject.value(Stat.defense),
      ValueField.mp => subject.mp,
      ValueField.handCount => subject.hand.length,
      ValueField.shield => subject.shield,
      ValueField.globalRound => state.round,
      ValueField.markTotal =>
        _effectTargets(actor, [target.instanceId], value.among)
            .where((c) => value.includeDead || c.alive)
            .expand((c) => c.marks)
            .where(
              (m) =>
                  value.markIds.isEmpty ||
                  value.markIds.contains(m.definition.id),
            )
            .fold<int>(0, (n, m) => n + m.count),
      ValueField.statusCharacterCount =>
        _effectTargets(actor, [target.instanceId], value.among)
            .where((c) => value.includeDead || c.alive)
            .where(
              (c) => c.statuses.any(
                (s) =>
                    s.stacks > 0 &&
                    (value.statusId == null
                        ? _isStatusEffect(s.definition)
                        : s.definition.id == value.statusId),
              ),
            )
            .length,
      ValueField.statusTotalStacks || ValueField.statusTotalIntensity =>
        _effectTargets(actor, [target.instanceId], value.among)
            .where((c) => value.includeDead || c.alive)
            .expand((c) => c.statuses)
            .where(
              (s) => value.statusId == null
                  ? _isStatusEffect(s.definition)
                  : s.definition.id == value.statusId,
            )
            .fold<int>(
              0,
              (n, s) =>
                  n +
                  (value.field == ValueField.statusTotalStacks
                      ? s.stacks
                      : s.intensity),
            ),
      ValueField.damageThisTurn => subject.damageThisTurn,
      ValueField.damageThisRound => subject.damageThisRound,
      ValueField.damageDealtThisGlobalRound =>
        subject.dealtDamageThisGlobalRound,
      ValueField.damageReceivedThisGlobalRound =>
        subject.receivedDamageThisGlobalRound,
      ValueField.healedPreviousGlobalRound => subject.healedPreviousGlobalRound,
    };
    return (value.constant + field * value.factor) *
        (value.perIntensity ? (_currentTrigger?.intensity ?? 1) : 1);
  }

  void _triggers(
    CharacterInstance actor,
    TriggerTiming timing, {
    List<String> selected = const [],
  }) {
    _enqueueTrigger(
      _TriggerFact(
        timing,
        subject: actor.instanceId,
        source: actor.instanceId,
        target: selected.length == 1 ? selected.single : null,
        selected: selected,
      ),
    );
    _drainTriggers();
  }

  void _applyStatus(
    CharacterInstance actor,
    CharacterInstance target,
    ApplyStatus effect,
    int multiplier, {
    String? anchorPlayerId,
    CharacterInstance? statisticsSource,
  }) {
    final definition = _require(catalog.statuses, effect.statusId);
    final statusEffect = _isStatusEffect(definition);
    final effectiveAnchor =
        anchorPlayerId ??
        (_interactionRulesVersion >= 15 &&
                definition.decay == StatusDecay.anchorMpRecovery
            ? state.players.firstWhere((p) => p.character == actor).id
            : state.activePlayer.id);
    if (effect.stacks <= 0 ||
        effect.intensity <= 0 ||
        (statusEffect &&
            (state.round < state.blockStatusUntilRound ||
                state.statusApplicationBlocks.isNotEmpty ||
                _blocked(target, (s) => s.blockStatus))) ||
        (!_blocked(target, (s) => s.blockTraits) &&
            statusEffect &&
            target.traits.any(
              (t) => t.definition.immuneStatuses.contains(effect.statusId),
            ))) {
      return;
    }
    if (statusEffect &&
        definition.negative &&
        (_interactionRulesVersion < 21 ||
            definition.category == StatusCategory.normal)) {
      final immunities = target.statuses
          .where(
            (s) =>
                s.definition.blockNegative &&
                !effect.ignoreNegativeProtection.contains(s.definition.id),
          )
          .toList();
      final immunity =
          immunities
              .where((s) => !s.definition.consumeOnNegative)
              .firstOrNull ??
          immunities.firstOrNull;
      if (immunity != null) {
        if (immunity.definition.consumeOnNegative) {
          _consumeStatus(target, immunity);
          if (_interactionRulesVersion >= 21 && immunity.stacks > 0) {
            _event('statusModified', {
              'sourceId': target.instanceId,
              'targetId': target.instanceId,
              'statusId': immunity.definition.id,
              'instanceId': immunity.instanceId,
              'negative': immunity.definition.negative,
              'stacks': immunity.stacks,
              'intensity': immunity.intensity,
              'stackDelta': -1,
              'intensityDelta': 0,
            });
          }
        }
        _event('statusRejected', {
          'targetId': target.instanceId,
          'statusId': definition.id,
          'reason': 'negativeImmunity',
        });
        return;
      }
    }
    if (definition.exclusiveGroup != null) {
      for (final old
          in target.statuses
              .where(
                (s) =>
                    s.definition.id != definition.id &&
                    s.definition.exclusiveGroup == definition.exclusiveGroup,
              )
              .toList()) {
        _consumeStatus(
          target,
          old,
          amount: old.stacks,
          statisticsSource: statisticsSource ?? actor,
        );
      }
      if (!target.alive) return;
    }
    if (definition.category == StatusCategory.anomaly) {
      final existing = target.statuses
          .where((s) => s.definition.category == StatusCategory.anomaly)
          .firstOrNull;
      if (existing != null) {
        if (existing.definition.id == definition.id ||
            rules.anomalyConflict == AnomalyConflict.reject) {
          _event('statusRejected', {
            'targetId': target.instanceId,
            'statusId': definition.id,
            'reason': 'anomalyConflict',
          });
          return;
        }
        _consumeStatus(
          target,
          existing,
          amount: existing.stacks,
          statisticsSource: statisticsSource ?? actor,
        );
        if (!target.alive) return;
      }
    }
    if (definition.cleanseNegativeOnApply) {
      for (final old
          in target.statuses
              .where(
                (s) =>
                    _isStatusEffect(s.definition) &&
                    _matchesNegativeCleanse(s.definition),
              )
              .toList()) {
        _consumeStatus(
          target,
          old,
          amount: old.stacks,
          statisticsSource: statisticsSource ?? actor,
        );
      }
      if (!target.alive) return;
    }
    var remainingStacks = statusEffect
        ? _statusStackGain(target, definition.id, effect.stacks * multiplier)
        : effect.stacks * multiplier;
    final opposite = target.statuses
        .where((s) => s.definition.id == definition.opposingStatusId)
        .firstOrNull;
    if (opposite != null) {
      final cancelled = remainingStacks < opposite.stacks
          ? remainingStacks
          : opposite.stacks;
      remainingStacks -= cancelled;
      _consumeStatus(
        target,
        opposite,
        amount: cancelled,
        statisticsSource: statisticsSource ?? actor,
      );
      _event('statusStacksCancelled', {
        'targetId': target.instanceId,
        'incomingStatusId': definition.id,
        'opposingStatusId': opposite.definition.id,
        'stacks': cancelled,
      });
    }
    if (remainingStacks <= 0 || !target.alive) return;
    final previousLimits = _resourceLimits(target);
    var status = target.statuses
        .where((s) => s.definition.id == definition.id)
        .firstOrNull;
    final previousStacks = status?.stacks ?? 0;
    final previousIntensity = status?.intensity ?? 0;
    if (status == null) {
      status = StatusInstance(
        instanceId: state.id('status'),
        definition: definition,
        ownerId: target.instanceId,
        sourceId: actor.instanceId,
        anchorPlayerId: effectiveAnchor,
        decayAtAnchorEnd: _usesEndAnchorDecay(definition, effectiveAnchor),
        stacks: remainingStacks,
        intensity: definition.hasIntensity ? effect.intensity : 1,
        damageLimit: effect.damageLimit,
      );
      target.statuses.add(status);
    } else {
      status.stacks += remainingStacks;
      status.intensity = definition.addIntensity
          ? status.intensity + effect.intensity
          : (status.intensity > effect.intensity
                ? status.intensity
                : effect.intensity);
    }
    if (effect.damageLimit != null) {
      final previousLimit = status.damageLimit;
      status.damageLimit = previousLimit == null
          ? effect.damageLimit
          : previousLimit < effect.damageLimit!
          ? previousLimit
          : effect.damageLimit;
    }
    if (effect.refreshSource) {
      status
        ..sourceId = actor.instanceId
        ..anchorPlayerId = effectiveAnchor
        ..decayAtAnchorEnd = _usesEndAnchorDecay(definition, effectiveAnchor);
    }
    if (!definition.hasIntensity) status.intensity = 1;
    if (definition.maxStacks != null && status.stacks > definition.maxStacks!) {
      status.stacks = definition.maxStacks!;
    }
    if (definition.maxIntensity != null) {
      status.intensity = status.intensity.clamp(1, definition.maxIntensity!);
    }
    _performance.statusChange(
      statisticsSource ?? actor,
      target,
      definition,
      previousStacks,
      previousIntensity,
      status.stacks,
      status.intensity,
    );
    _normalize(target);
    _event('statusApplied', {
      'sourceId': actor.instanceId,
      'targetId': target.instanceId,
      'statusId': definition.id,
      'instanceId': status.instanceId,
      'stacks': status.stacks,
      'amount': status.stacks - previousStacks,
      'stackDelta': status.stacks - previousStacks,
      'intensityDelta': status.intensity - previousIntensity,
      'negative': definition.negative,
      'intensity': status.intensity,
    });
    _logResourceLimitChanges(target, previousLimits, source: actor);
  }

  /// Legacy scalar callers delegate to the staged settlement pipeline.
  void _damage(
    CharacterInstance? source,
    CharacterInstance target,
    int amount,
    DamageKind kind, {
    bool attack = false,
    bool piercesContinuation = false,
    AttackPacket? packet,
    bool secondary = false,
    bool redirected = false,
  }) {
    _damageAsync(
      source,
      target,
      amount,
      kind,
      () {},
      attack: attack,
      piercesContinuation: piercesContinuation,
      packet: packet,
      secondary: secondary,
      redirected: redirected,
    );
  }

  bool _damageComponent(
    CharacterInstance? source,
    CharacterInstance target,
    int amount,
    DamageKind kind, {
    required _DamagePlan prepared,
    bool attack = false,
    bool piercesContinuation = false,
    AttackPacket? packet,
    bool secondary = false,
    bool redirected = false,
  }) {
    if (!target.alive || amount <= 0) return false;
    final hpBefore = target.hp;
    var defenseLost = 0;
    var remaining = prepared.amount;
    var shieldAbsorbed = 0;
    final hit = prepared.hit;
    if (kind == DamageKind.physical || kind == DamageKind.magical) {
      if (kind == DamageKind.physical &&
          packet?.ignoreShield != true &&
          !_blocked(target, (s) => s.ignoreShield)) {
        final hadShield = target.shield > 0;
        final absorbed = remaining < target.shield ? remaining : target.shield;
        _performance.shieldAbsorbed(target, absorbed);
        shieldAbsorbed += absorbed;
        target.shield -= absorbed;
        _spendTemporaryShields(target, absorbed);
        remaining -= absorbed;
        if (hadShield && target.shield == 0) {
          _event('shieldBroken', {
            'sourceId': source?.instanceId,
            'targetId': target.instanceId,
            'amount': absorbed,
          });
        }
        final barrier = target.statuses
            .where((s) => s.definition.shieldOverflowBarrier)
            .firstOrNull;
        if (hadShield && target.shield == 0 && barrier != null) {
          remaining = 0;
          _consumeStatus(target, barrier);
        }
      }
    }
    final absorbedDamage = shieldAbsorbed;
    if (target.defenseLife) {
      if (kind == DamageKind.lifeLoss) {
        remaining = 0;
      } else {
        final factor = target.defenseLossPerDamage;
        var loss = (remaining * factor).floor();
        if (packet != null) {
          final key = '${packet.id}/${target.instanceId}';
          final before = _defensePacketDamage[key] ?? 0;
          _defensePacketDamage[key] = before + remaining;
          loss =
              ((before + remaining) * factor).floor() -
              (before * factor).floor();
        }
        defenseLost = loss;
        target.permanentModifiers.update(
          Stat.defense,
          (n) => n - loss,
          ifAbsent: () => -loss,
        );
        _event('defenseLifeLost', {
          'targetId': target.instanceId,
          'amount': loss,
        });
      }
    } else {
      final bypass = kind == DamageKind.real || piercesContinuation;
      if (target.lifeLocked && !bypass) {
        remaining = 0;
      } else if (bypass) {
        target.setLifeIgnoringContinuation(target.hp - remaining);
      } else {
        target.hp -= remaining;
      }
    }
    final actualDamage = _damageAmountVersion == 0
        ? remaining
        : remaining + absorbedDamage;
    if (prepared.protectedTargetId != null && kind != DamageKind.lifeLoss) {
      final effective = target.defenseLife
          ? remaining
          : remaining.clamp(0, hpBefore.clamp(0, 1000000000)) + absorbedDamage;
      _performance.takenForAlly(
        target.instanceId,
        prepared.protectedTargetId!,
        effective,
      );
    }
    if (kind != DamageKind.lifeLoss) {
      target.receivedDamageThisGlobalRound += actualDamage;
      target.receivedHpLostThisGlobalRound += target.defenseLife
          ? 0
          : remaining.clamp(0, hpBefore.clamp(0, 1000000000));
    }
    if (kind != DamageKind.lifeLoss && source != null) {
      source
        ..damageThisTurn += actualDamage
        ..damageThisRound += actualDamage
        ..dealtDamageThisGlobalRound += actualDamage
        ..damageTotal += actualDamage;
    }
    final statusOrigin = _currentTrigger == null
        ? _effectStatus
        : _currentTrigger?.status;
    _event('damage', {
      'sourceId': kind == DamageKind.lifeLoss ? null : source?.instanceId,
      'statisticsSourceId': source?.instanceId,
      'targetId': target.instanceId,
      'requestedAmount': amount,
      'actualHpLost': target.defenseLife
          ? 0
          : remaining.clamp(0, (hpBefore > 0 ? hpBefore : 0)),
      'overkill': target.defenseLife
          ? 0
          : (remaining - (hpBefore > 0 ? hpBefore : 0)).clamp(0, remaining),
      'convertedToDefense': target.defenseLife && kind != DamageKind.lifeLoss
          ? remaining
          : 0,
      'defenseLost': defenseLost,
      'kind': kind.name,
      'amount': actualDamage,
      if (_damageAmountVersion >= 1) 'amountIncludesShield': true,
      'independent':
          _currentTrigger != null ||
          _independentDamage ||
          _observedAction?.actor != source,
      if (statusOrigin != null) 'statusId': statusOrigin.definition.id,
      if (statusOrigin != null) 'intensity': statusOrigin.intensity,
      'shieldAbsorbed': absorbedDamage,
      'hpLost': target.defenseLife ? 0 : remaining,
      'attack': attack,
      if (packet != null) 'packetId': packet.id,
      if (packet != null) 'actionId': packet.actionId,
      if (packet != null) 'component': secondary ? 'onHit' : 'main',
      if (packet != null) 'baseDamage': secondary ? 0 : packet.baseDamage,
    });
    if (kind != DamageKind.lifeLoss && actualDamage > 0) {
      for (final status in target.statuses.toList()) {
        final limit = status.damageLimit;
        if (limit == null) continue;
        status.damageTaken += actualDamage;
        if (status.damageTaken >= limit) {
          _event('statusDamageLimitReached', {
            'targetId': target.instanceId,
            'instanceId': status.instanceId,
            'statusId': status.definition.id,
            'damageTaken': status.damageTaken,
            'damageLimit': limit,
          });
          _consumeStatus(target, status, amount: status.stacks);
        }
      }
    }
    if ((piercesContinuation || kind == DamageKind.real) && remaining > 0) {
      _piercingTargets.add(target.instanceId);
    }
    return hit;
  }

  void _heal(CharacterInstance source, CharacterInstance target, int amount) {
    if (!target.alive || amount <= 0) return;
    if (_summonHealingBlocked(target) ||
        target.traits.any((t) => t.definition.healingForbidden)) {
      _event('healed', {
        'sourceId': source.instanceId,
        'targetId': target.instanceId,
        'amount': 0,
        'nominalAmount': amount,
      });
      return;
    }
    final rewrite = _blocked(target, (s) => s.blockTraits)
        ? null
        : target.traits
              .where(
                (t) =>
                    t.definition.healingRewriteIgnoresModifiers &&
                    t.definition.healingRewrite != null,
              )
              .firstOrNull;
    int scaled;
    if (rewrite != null) {
      final blocked = rewrite.definition.healingRewriteBlockedBy;
      scaled = blocked != null && _queryStatuses(target, blocked).isNotEmpty
          ? 0
          : rewrite.definition.healingRewrite!;
    } else {
      var healingFactor = 1.0;
      for (final status in target.statuses) {
        healingFactor +=
            status.definition.healingBonusPerIntensity * status.intensity;
      }
      var normalScaled =
          (amount *
                  healingFactor.clamp(0, double.infinity) *
                  (state.duel ? rules.duelHealingMultiplier : 1))
              .floor();
      if (normalScaled > 0 && !_blocked(target, (s) => s.blockTraits)) {
        for (final t in target.traits) {
          if (t.definition.healingRewrite != null) {
            normalScaled = t.definition.healingRewrite!;
          }
        }
      }
      scaled = normalScaled;
    }
    final missing = target.value(Stat.maxHp) - target.hp;
    final actual = target.defenseLife || target.lifeLocked
        ? 0
        : scaled.clamp(0, missing < 0 ? 0 : missing);
    _scoreHealing(target, amount, scaled, missing);
    target.hp += actual;
    target.healedThisGlobalRound += actual;
    _event('healed', {
      'sourceId': source.instanceId,
      'targetId': target.instanceId,
      'amount': actual,
      'requestedAmount': amount,
      'resolvedAmount': scaled,
      'overheal': target.defenseLife ? 0 : scaled - actual,
      'ignoredHealing': target.defenseLife || target.lifeLocked ? scaled : 0,
    });
  }

  void _kill(CharacterInstance target) {
    if (!target.alive || !_pendingDeaths.add(target.instanceId)) return;
    _flowSteps([
      () => _deathAsync(target, () {
        _pendingDeaths.remove(target.instanceId);
      }),
    ]);
  }

  void _commitDeath(CharacterInstance target) {
    if (!target.alive) return;
    target
      ..alive = false
      ..hp = 0;
    _releaseNegativeMp(target);
    final lostCards = target.hand.length;
    state.discardPile.addAll(target.hand);
    target.hand.clear();
    if (lostCards > 0) {
      _event('cardsLost', {
        'actorId': target.instanceId,
        'count': lostCards,
        'reason': 'death',
      });
    }
    _releaseDeadPrey(target);
    _event('characterDied', {'instanceId': target.instanceId});
  }

  void _normalize(CharacterInstance target) {
    if (target.hp > target.value(Stat.maxHp)) {
      target.hp = target.value(Stat.maxHp);
    }
    target.mp = target.mp.clamp(_mpFloor(target), target.value(Stat.maxMp));
    _checkLifeThresholds(target);
    if (!_settlingAttack &&
        _damageDepth == 0 &&
        target.depleted &&
        (target.defenseLife || !target.continuesBattle)) {
      _kill(target);
    }
  }

  void _endTurn() {
    final actor = state.activePlayer.character;
    if (actor.extraTurns > 0) {
      actor.extraTurns--;
      actor.extraTurnAttackTarget = actor.extraTurnTargets.isEmpty
          ? null
          : actor.extraTurnTargets.removeAt(0);
      state.extraTurn = true;
      actor.actionsRemaining = rules.actionsPerTurn;
      actor.bonusActions.clear();
      state.phase = GamePhase.start;
      _event('extraTurnStarted', {'actorId': actor.instanceId});
      _flowSteps([
        () => _mpRecoveryNode(actor),
        () => _triggers(actor, TriggerTiming.turnStartEnd),
        () => _settleOwnerStartStatuses(actor),
        () => _captureSave(actor),
        () {
          if (!actor.alive) return;
          state.phase = GamePhase.draw;
          if (!_blocked(actor, (s) => s.blockDrawPhase)) {
            _draw(actor, rules.cardsPerTurn);
          } else {
            _scoreBlockedDrawPhase(actor, rules.cardsPerTurn);
          }
        },
        () => _specialDrawBonus(actor),
        () => _offerDreamRemoval(actor),
        _afterResolution,
        () {
          if (!state.finished && actor.alive) state.phase = GamePhase.action;
        },
      ]);
      return;
    }
    actor.extraTurnAttackTarget = null;
    state.phase = GamePhase.discard;
    if (_discardReserve(actor)) return;
    if (actor.hand.length > actor.value(Stat.maxHand) &&
        actor.hand.any((c) => !c.disabled)) {
      return;
    }
    _closeTurn();
  }

  void _discard(
    CharacterInstance actor,
    List<String> ids, {
    bool validateOnly = false,
  }) {
    final overflow = (actor.hand.length - actor.value(Stat.maxHand)).clamp(
      0,
      actor.hand.where((c) => !c.disabled).length,
    );
    if (ids.length != overflow) {
      throw StateError('Must discard exactly $overflow cards');
    }
    final cards = _selectCards(actor, ids);
    if (validateOnly) return;
    for (final card in cards) {
      actor.hand.remove(card);
      state.discardPile.add(card);
    }
    _event('cardsDiscarded', {
      'actorId': actor.instanceId,
      'cards': List<String>.unmodifiable(ids),
    });
    _flowSteps([_drainTriggers, _closeTurn]);
  }

  void _closeTurn({bool skipped = false}) {
    _performance.lostActions(
      state.activePlayer.character,
      state.activePlayer.character.actionsRemaining,
    );
    state.phase = GamePhase.end;
    final endStatuses = _interactionRulesVersion >= 12
        ? List<StatusInstance>.of(state.activePlayer.character.statuses)
        : null;
    final endDecay = _beginAnchorEnd();
    _chooseEndMarks(
      state.activePlayer.character,
      () => _finishTurn(
        skipped: skipped,
        endDecay: endDecay,
        endStatuses: endStatuses,
      ),
    );
  }

  void _finishTurn({
    bool skipped = false,
    List<_EndDecayStatus> endDecay = const [],
    List<StatusInstance>? endStatuses,
  }) {
    state.phase = GamePhase.end;
    final actor = state.activePlayer.character;
    _flowSteps([
      () =>
          _mpRecoveryNode(actor, phase: MpRegenPhase.turnEnd, skipped: skipped),
      () {
        if (!skipped && actor.alive) {
          actor.normalTurnsEnded++;
          _triggers(actor, TriggerTiming.turnEnd);
        }
      },
      () => _flowSteps([
        for (final status
            in endStatuses ?? List<StatusInstance>.of(actor.statuses))
          () {
            if (actor.alive && actor.statuses.contains(status)) {
              _runAbility(
                actor,
                [actor.instanceId],
                status.definition.turnEnd,
                () {
                  if (status.definition.turnEnd.isNotEmpty) {
                    _statusSettlementCompleted(actor, status);
                  }
                },
                multiplier: status.intensity,
                statusOrigin: status,
              );
            }
          },
      ]),
      () => _runScheduled(SchedulePhase.turnEnd, actor),
      () => _endAnchorDecay(endDecay),
      () {
        state.actualTurn++;
        _event('turnEnded', {
          'playerId': state.activePlayer.id,
          'skipped': skipped,
        });
      },
      () {
        if (!_checkVictory()) _advanceSeat();
      },
      () {
        if (!_checkVictory()) _enterPlayableTurn();
      },
    ]);
  }

  void _tickAnchor(String playerId) {
    _expireHandCardsAtAnchor(playerId);
    _expireNaturalDurations(playerId);
    if (_interactionRulesVersion >= 5) {
      final remaining = state.statusApplicationBlocks[playerId];
      if (remaining != null) {
        if (remaining <= 1) {
          state.statusApplicationBlocks.remove(playerId);
        } else {
          state.statusApplicationBlocks[playerId] = remaining - 1;
        }
      }
    }
    // Snapshots prevent statuses created by a tick from also ticking immediately.
    final scheduled = [
      for (final p in state.players)
        for (final s in p.character.statuses)
          if (s.anchorPlayerId == playerId &&
              !s.decayAtAnchorEnd &&
              s.definition.decay == StatusDecay.anchoredRound)
            (p.character, s),
    ];
    if (_interactionRulesVersion < 5) {
      for (final (owner, status) in scheduled) {
        if (owner.alive && owner.statuses.contains(status)) {
          _consumeStatus(owner, status);
        }
      }
      return;
    }
    _flowSteps([
      for (final (owner, status) in scheduled)
        () {
          if (!owner.alive || !owner.statuses.contains(status)) return;
          if (_interactionRulesVersion >= 5 &&
              status.definition.settleAtAnchor) {
            _runAbility(
              owner,
              [owner.instanceId],
              status.definition.turnStart,
              () {
                if (status.definition.turnStart.isNotEmpty) {
                  _statusSettlementCompleted(owner, status);
                }
                if (owner.statuses.contains(status)) {
                  _consumeStatus(owner, status);
                }
              },
              multiplier: status.intensity,
              statusOrigin: status,
            );
          } else {
            _consumeStatus(owner, status);
          }
        },
    ]);
  }

  void _settleOwnerStartStatuses(CharacterInstance actor) {
    if (_interactionRulesVersion < 9) return;
    final scheduled = actor.statuses
        .where((s) => s.definition.decay == StatusDecay.ownerTurnStartEnd)
        .toList();
    _flowSteps([
      for (final status in scheduled)
        () {
          if (!actor.alive || !actor.statuses.contains(status)) return;
          _runAbility(
            actor,
            [actor.instanceId],
            status.definition.turnStart,
            () {
              if (status.definition.turnStart.isNotEmpty) {
                _statusSettlementCompleted(actor, status);
              }
              if (actor.statuses.contains(status)) {
                _consumeStatus(actor, status);
              }
            },
            multiplier: status.intensity,
            statusOrigin: status,
          );
        },
    ]);
  }

  void _consumeStatus(
    CharacterInstance owner,
    StatusInstance status, {
    int amount = 1,
    CharacterInstance? statisticsSource,
    Map<Stat, int>? limitBefore,
  }) {
    final previousLimits = limitBefore ?? _resourceLimits(owner);
    final oldStacks = status.stacks;
    status.stacks -= amount;
    if (statisticsSource != null) {
      _performance.statusChange(
        statisticsSource,
        owner,
        status.definition,
        oldStacks,
        status.intensity,
        status.stacks.clamp(0, oldStacks),
        status.intensity,
      );
    }
    if (status.stacks <= 0) {
      owner.statuses.remove(status);
      _normalize(owner);
      _event('statusRemoved', {
        'ownerId': owner.instanceId,
        'statusId': status.definition.id,
        'sourceId': status.sourceId,
        'instanceId': status.instanceId,
      });
      _logResourceLimitChanges(owner, previousLimits, source: statisticsSource);
    }
  }

  void _enterPlayableTurn() {
    if (state.finished) return;
    final actor = state.activePlayer.character;
    List<_EndDecayStatus>? logicalEndDecay;
    var logicalTurn = false;
    void advance() => _flowSteps([
      if (_interactionRulesVersion >= 15)
        () {
          logicalEndDecay ??= _beginAnchorEnd();
          _mpRecoveryNode(actor, phase: MpRegenPhase.turnEnd, skipped: true);
        },
      () => _endAnchorDecay(logicalEndDecay ?? _beginAnchorEnd()),
      if (_interactionRulesVersion >= 12)
        () {
          if (logicalTurn) {
            _event('logicalTurnEnded', {'playerId': state.activePlayer.id});
          }
        },
      () {
        if (!_checkVictory()) _advanceSeat();
      },
      () {
        if (!_checkVictory()) _enterPlayableTurn();
      },
    ]);
    _flowSteps([
      () {
        actor.turnsStarted++;
        actor.temporaryDefense.removeWhere(
          (b) => b.expires <= actor.turnsStarted,
        );
        _normalize(actor);
        _convertCraftDream(actor);
        _tickAnchor(state.activePlayer.id);
        _tickSkillCooldowns(state.activePlayer.id);
      },
      () {
        _expireUnusableAttackCopies();
        if (_checkVictory()) return;
        if (!actor.alive) {
          logicalTurn = true;
          if (_interactionRulesVersion >= 15) state.phase = GamePhase.start;
          _event('logicalTurnStarted', {'playerId': state.activePlayer.id});
          _flowSteps([
            if (_interactionRulesVersion >= 15)
              () => _mpRecoveryNode(actor, skipped: true),
            () => _runScheduled(SchedulePhase.turnStart, actor),
            () => _triggers(actor, TriggerTiming.turnStart),
            () {
              logicalEndDecay = _beginAnchorEnd();
              _triggers(actor, TriggerTiming.turnEnd);
            },
            () => _runScheduled(SchedulePhase.turnEnd, actor),
            if (_interactionRulesVersion < 12)
              () => _event('logicalTurnEnded', {
                'playerId': state.activePlayer.id,
              }),
            advance,
          ]);
          return;
        }
        state.phase = GamePhase.start;
        state.extraTurn = false;
        actor.bonusActions.clear();
        actor
          ..armedMarkAction = null
          ..actionsRemaining = rules.actionsPerTurn;
        _resetTriggerWindows();
        for (final p in state.players) {
          p.character.damageThisTurn = 0;
        }
        if (_interactionRulesVersion < 18) {
          for (final skill in actor.skills) {
            if (skill.cooldown > 0) skill.cooldown--;
          }
        }
        _event('turnStarted', {
          'playerId': state.activePlayer.id,
          'round': state.round,
          'turn': state.turn,
          'actualTurn': state.actualTurn,
          'extraTurn': state.extraTurn,
        });
        if (_blocked(actor, (s) => s.skipTurn)) {
          _performance.lostActions(
            actor,
            actor.actionsRemaining,
            skipped: true,
          );
          _scoreBlockedNaturalMp(actor);
          _performance.blockedResource(
            actor,
            _scoreAvailableDraw(rules.cardsPerTurn),
            resource: StatisticsResource.hand,
            blocked: (s) => s.skipTurn,
          );
          for (final status in List<StatusInstance>.of(actor.statuses)) {
            if (status.definition.skipTurn) _consumeStatus(actor, status);
          }
          if (_interactionRulesVersion >= 15) {
            _flowSteps([() => _mpRecoveryNode(actor, skipped: true), advance]);
          } else {
            advance();
          }
          return;
        }
        _flowSteps([
          () => _triggers(actor, TriggerTiming.turnStartEarly),
          () => _specialTurnStart(actor),
          () => _craftDreamAtStart(actor),
          () => _configuredTurnStart(actor),
          () => _supportStanceStart(actor),
          () => _triggers(actor, TriggerTiming.turnStartBeforeRecovery),
          () => _mpRecoveryNode(actor),
          () => _runScheduled(SchedulePhase.turnStart, actor),
          () => _triggers(actor, TriggerTiming.turnStart),
          () => _flowSteps([
            for (final status in List<StatusInstance>.of(actor.statuses))
              () {
                if (_interactionRulesVersion >= 5 &&
                    (status.definition.settleAtAnchor ||
                        status.definition.decay ==
                            StatusDecay.ownerTurnStartEnd ||
                        status.definition.decay ==
                            StatusDecay.anchorMpRecovery)) {
                  return;
                }
                if (actor.alive && actor.statuses.contains(status)) {
                  _runAbility(
                    actor,
                    [actor.instanceId],
                    status.definition.turnStart,
                    () {
                      if (status.definition.turnStart.isNotEmpty) {
                        _statusSettlementCompleted(actor, status);
                      }
                    },
                    multiplier: status.intensity,
                    statusOrigin: status,
                  );
                }
              },
          ]),
          () => _triggers(actor, TriggerTiming.turnStartEnd),
          () => _settleOwnerStartStatuses(actor),
          () {
            if (_checkVictory()) return;
            if (!actor.alive) {
              advance();
              return;
            }
            _captureSave(actor);
            state.phase = GamePhase.draw;
            if (!_blocked(actor, (s) => s.blockDrawPhase)) {
              _draw(actor, rules.cardsPerTurn + _claimDiscardReserve(actor));
            } else {
              _scoreBlockedDrawPhase(actor, rules.cardsPerTurn);
            }
            _flowSteps([
              () {
                if (_checkVictory()) return;
                if (!actor.alive) {
                  advance();
                  return;
                }
                _flowSteps([
                  () => _specialDrawBonus(actor),
                  () => _offerDreamRemoval(actor),
                  () {
                    if (actor.alive) state.phase = GamePhase.action;
                  },
                ]);
              },
            ]);
          },
        ]);
      },
    ]);
  }

  void _advanceSeat() {
    // RULE.md's personal "this round" ends when this owner's turn ends.
    state.activePlayer.character.damageThisRound = 0;
    state.activePlayer.character.turnsClosed++;
    _resetTriggerWindows();
    state.turn++;
    state.roundSeatPosition++;
    if (state.roundSeatPosition == state.players.length) {
      _flowSteps([
        () => _event('roundEnding', {'round': state.round}),
        () => _runScheduled(SchedulePhase.roundEnd, null),
        () {
          // Resource rules can settle after all ordinary round-end effects.
          if (_hasTriggerListener(TriggerTiming.roundEndFinal)) {
            _enqueueTrigger(_TriggerFact(TriggerTiming.roundEndFinal));
            _drainTriggers();
          }
        },
        () {
          if (_checkVictory()) return;
          state.roundSeatPosition = 0;
          state.round++;
          if (state.reverseNextRound) {
            state.reversedOrder = !state.reversedOrder;
            _reverseDecayAnchors();
          }
          state.reverseNextRound = false;
          state.activeIndex = state.reversedOrder
              ? state.players.length - 1
              : 0;
          _beginRound();
        },
      ]);
    } else {
      state.activeIndex = state.reversedOrder
          ? state.players.length - 1 - state.roundSeatPosition
          : state.roundSeatPosition;
    }
  }

  void _runScheduled(SchedulePhase phase, CharacterInstance? anchor) {
    final due = state.scheduledEffects.where((job) {
      if (job.phase != phase ||
          (phase != SchedulePhase.roundStart &&
              phase != SchedulePhase.roundEnd &&
              job.anchorId != anchor?.instanceId)) {
        return false;
      }
      final progress = switch (phase) {
        SchedulePhase.turnStart => anchor!.turnsStarted,
        SchedulePhase.turnEnd => anchor!.turnsClosed + 1,
        SchedulePhase.roundStart || SchedulePhase.roundEnd => state.round,
      };
      return progress >= job.due;
    }).toList();
    _flowSteps([
      for (final job in due)
        () {
          state.scheduledEffects.remove(job);
          final previous = _scheduledValues;
          _scheduledValues = job.capturedValues;
          try {
            _runAbility(
              _character(job.sourceId),
              [job.anchorId],
              job.effects,
              () => _event('scheduledEffectResolved', {'scheduleId': job.id}),
              allowDeadActor: true,
              multiplier: job.multiplier,
            );
          } finally {
            _scheduledValues = previous;
          }
        },
    ]);
  }

  void _beginRound() {
    for (final player in state.players) {
      final character = player.character;
      character.battleRound = state.round;
      if (character.alive &&
          character.continuationEntered &&
          character.traits.any(
            (t) =>
                t.definition.battleContinuationThroughRound != null &&
                state.round > t.definition.battleContinuationThroughRound!,
          )) {
        _event('continuationExpired', {'actorId': character.instanceId});
        _commitDeath(character);
      }
      final expired = character.temporaryShields
          .where((s) => s.anchor == null && s.expires <= state.round)
          .fold<int>(0, (n, s) => n + s.remaining);
      character.shield = (character.shield - expired).clamp(0, 1000000000);
      character.temporaryShields.removeWhere(
        (s) => s.anchor == null && s.expires <= state.round,
      );
    }

    _expireSkillLeases();
    _expireCardRestrictions();
    _closeSpecialRound();
    for (final player in state.players) {
      player.character.healedPreviousGlobalRound =
          player.character.healedThisGlobalRound;
      player.character.healedThisGlobalRound = 0;
      player.character.receivedDamageThisGlobalRound = 0;
      player.character.receivedHpLostThisGlobalRound = 0;
      player.character.transferredHpLostThisGlobalRound = 0;
      player.character.transferredDamageThisGlobalRound = 0;
      player.character.dealtDamageThisGlobalRound = 0;
    }
    for (final player in state.players) {
      if (state.round >= rules.revealRound) {
        for (final skill in player.character.skills) {
          skill.revealed = true;
          state.publicSkillHistory[skill.definition.id] = skill.definition;
        }
      }
    }
    if (state.round == rules.revealRound) {
      _event('skillsRevealed', {'round': state.round});
    }
    if (rules.duelEnabled && !state.duel && state.round >= rules.duelRound) {
      state.duel = true;
      for (final player in state.players) {
        player.character.permanentModifiers.update(
          Stat.attack,
          (n) => n + rules.duelAttackBonus,
          ifAbsent: () => rules.duelAttackBonus,
        );
      }
      _event('duelStarted', {'round': state.round});
    }
    _resetTriggerWindows();
    for (final player in state.players) {
      for (final status
          in player.character.statuses
              .where((s) => s.definition.decay == StatusDecay.globalRound)
              .toList()) {
        _consumeStatus(player.character, status);
      }
    }
    _event('roundStarted', {'round': state.round});
    _flowSteps([
      _drainTriggers,
      () => _runScheduled(SchedulePhase.roundStart, null),
    ]);
  }

  void _afterResolution() {
    _reserveModule.finishAction();
    if (_automaticRestores.isNotEmpty) {
      _flowSteps([
        _finishObservedAction,
        _drainTriggers,
        () => _automaticRestores.removeLast()(),
      ]);
      return;
    }
    _declaredAttackPower.clear();
    _attackGuardResults.clear();
    _attackGuardReactions.clear();
    _packetGuardStatuses.clear();
    _packetConsumedGuards.clear();
    _packetGuardFlatRemaining.clear();
    _flowSteps([
      _finishObservedAction,
      _drainTriggers,
      () {
        _preparedSelections.clear();
        _preparedOptions.clear();
        _preparedCardChoices.clear();
        for (final entry in _temporaryReinforcement.entries) {
          entry.key.reinforced = entry.value;
        }
        _temporaryReinforcement.clear();
        _recordingModule.clearCommitted();
        _expireUnusableAttackCopies();
        if (_checkVictory()) return;
        if (!state.activePlayer.character.alive &&
            (_interactionRulesVersion < 12 || _endingAnchorPlayerId == null)) {
          _flowSteps([
            if (_interactionRulesVersion >= 12)
              () => _endAnchorDecay(_beginAnchorEnd()),
            _advanceSeat,
            _enterPlayableTurn,
          ]);
        }
      },
    ]);
  }

  bool _checkVictory() {
    if (state.choice != null || _triggerInProgress) return false;
    if (state.finished) return true;
    final alive = state.players.where((p) => p.character.alive).toList();
    final teams = alive.map((p) => p.teamId).toSet();
    if (teams.length > 1) return false;
    state.outcome = alive.isEmpty
        ? const GameOutcome(draw: true)
        : GameOutcome(
            winnerTeamId: teams.single,
            winnerPlayerId: alive.length == 1 ? alive.single.id : null,
          );
    state.phase = GamePhase.finished;
    state.pending = null;
    _event('gameFinished', {
      'winnerTeamId': state.outcome!.winnerTeamId,
      'draw': state.outcome!.draw,
    });
    return true;
  }

  void _draw(CharacterInstance actor, int count, {CharacterInstance? source}) {
    if (_previewMode && count > 0) {
      throw const PreviewBoundary('unknownDrawPile');
    }
    if (!actor.alive) return;
    if (_blocked(actor, (s) => s.blockDraw)) {
      _performance.blockedResource(
        actor,
        _scoreAvailableDraw(count),
        resource: StatisticsResource.hand,
        blocked: (s) => s.blockDraw,
      );
      return;
    }
    final before = actor.hand.length;
    var drawn = 0;
    for (var i = 0; i < count; i++) {
      if (state.drawPile.isEmpty &&
          rules.emptyDeckPolicy == EmptyDeckPolicy.recycleDiscards &&
          state.discardPile.isNotEmpty) {
        state.drawPile.addAll(state.discardPile);
        state.discardPile.clear();
        _shuffle(state.drawPile);
      }
      if (state.drawPile.isEmpty) break;
      actor.hand.add(state.drawPile.removeAt(0));
      drawn++;
    }
    _event('cardsDrawn', {'actorId': actor.instanceId, 'count': drawn});
    if (source != null) {
      _scoreResourceChange(
        source,
        actor,
        drawn,
        resource: StatisticsResource.hand,
      );
    }
    _handCountIncreased(actor, before);
  }

  /// One atomic hand operation, independent of where the cards came from.
  /// A trigger fact (not a second draw event) preserves legacy replay journals.
  void _handCountIncreased(
    CharacterInstance owner,
    int before, {
    CharacterInstance? source,
  }) {
    final gained = owner.hand.length - before;
    if (gained <= 0 || !_hasTriggerListener(TriggerTiming.cardsGained)) return;
    _enqueueTrigger(
      _TriggerFact(
        TriggerTiming.cardsGained,
        subject: owner.instanceId,
        target: owner.instanceId,
        source: (source ?? owner).instanceId,
        amount: gained,
        data: {'before': before, 'after': owner.hand.length},
      ),
    );
  }

  List<CardInstance> _selectCards(CharacterInstance actor, List<String> ids) {
    if (ids.isEmpty || ids.toSet().length != ids.length) {
      throw StateError('Select distinct cards');
    }
    return ids.map((id) {
      final card = actor.hand.where((c) => c.instanceId == id).firstOrNull;
      if (card == null) throw StateError('Card instance is not owned');
      if (card.disabled) throw StateError('Card instance is disabled');
      return card;
    }).toList();
  }

  bool _blocked(
    CharacterInstance actor,
    bool Function(StatusDefinition) test,
  ) => actor.statuses.any((s) => test(s.definition));
  void _checkMp(
    CharacterInstance actor,
    int cost, {
    bool allowNegative = true,
  }) {
    if (cost < 0) {
      throw StateError(
        'Invalid MP cost: actor=${actor.instanceId}, cost=$cost',
      );
    }
    final floor = allowNegative ? _mpFloor(actor) : 0;
    if (!actor.noMp && actor.mp - floor < cost) {
      throw StateError(
        'Insufficient MP: actor=${actor.instanceId}, '
        'current=${actor.mp}, required=$cost, minimum=$floor',
      );
    }
  }

  void _payMp(CharacterInstance actor, int cost) {
    final previous = actor.mp;
    actor.mp -= actor.noMp ? 0 : cost;
    _negativeMpCrossed(actor, actor, previous);
    if (previous > 0 &&
        actor.mp == 0 &&
        actor.race.regenMode == MpRegenMode.refillAfterExhaustion) {
      actor.refillAfterExhaustionPending = true;
    }
    _event('mpSpent', {
      'actorId': actor.instanceId,
      'amount': actor.noMp ? 0 : cost,
      'nominalAmount': cost,
      'paid': true,
    });
  }

  PlayerInstance _player(String id) =>
      state.players.where((p) => p.id == id).firstOrNull ??
      (throw StateError('Unknown player: $id'));
  CharacterInstance _character(String id) =>
      state.players
          .map((p) => p.character)
          .where((c) => c.instanceId == id)
          .firstOrNull ??
      (throw StateError('Unknown character instance: $id'));
  CharacterInstance _target(String id) {
    final target = _character(id);
    if (!target.alive) throw StateError('Target is dead');
    return target;
  }

  void _event(String type, Map<String, Object?> data) {
    if (_interactionRulesVersion >= 5 &&
        (type == 'cardsDiscarded' || type == 'cardsLost') &&
        data['cards'] is List) {
      final discarded = {for (final c in state.discardPile) c.instanceId: c};
      data = {
        ...data,
        'cardDefinitionIds': [
          for (final id in data['cards'] as List? ?? [])
            if (discarded[id] case final card?) card.definition.id,
        ],
      };
    }
    if (_interactionRulesVersion >= 2 && type == 'choiceOpened') {
      _annotateChoiceSource();
    }
    if (type == 'damage' && data['sourceId'] is String) {
      final id = data['sourceId']! as String;
      if (data['independent'] == true) {
        final source = _character(id);
        final amount = data['amount']! as int;
        if (source.hasDamageHealing && amount > 0) {
          _flow.addFirst(() => _healConvertedDamage(source, amount));
        }
      }
      _specialRoundDamage.update(
        id,
        (n) => n + (data['amount']! as int),
        ifAbsent: () => data['amount']! as int,
      );
    }
    final event = KernelEvent(
      state.events.length + 1,
      type,
      _freezeEventData(data),
      round: state.round,
      turn: state.actualTurn + 1,
      phase: state.phase.name,
      extraTurn: state.extraTurn,
    );
    state.events.add(event);
    _statistics.record(event);
    _performance.record(event, state);
    _queueFact(type, data);
    _damageResourceFact(type, data);
    _collectReserveOverflow(type, data);
    _buddyMpBoundary(type, data);
    _supportDamageFact(type, data);
    if (const {
      'damage',
      'healed',
      'lifePaid',
      'lifeStolen',
      'actionLifePaid',
      'lifeSet',
      'lifeRestored',
      'statModified',
    }.contains(type)) {
      final id = data['targetId'] ?? data['actorId'];
      if (id is String) _checkLifeThresholds(_character(id));
    }
    if (type == 'shieldGained' && (data['amount'] as int? ?? 0) > 0) {
      final holder = _character(data['targetId']! as String);
      if (holder.alive &&
          !_blocked(holder, (s) => s.blockTraits) &&
          holder.traits.any(
            (t) => t.definition.mechanisms.has<GeneratedShieldActionRule>(),
          )) {
        _generatedRequests.add(holder);
      }
    }
  }

  int _nextInt(int upper) {
    if (upper <= 0) throw StateError('Random bound must be positive');
    int result;
    if (_replayRandom != null) {
      if (_replayCursor >= _replayRandom!.length) {
        throw StateError('Recovery random tape exhausted');
      }
      final draw = _replayRandom![_replayCursor++];
      if (draw['upper'] != upper) {
        throw StateError('Recovery random bound mismatch');
      }
      result = draw['result']!;
      state.randomState = draw['state']!;
    } else if (_randomInt != null) {
      result = _randomInt(upper);
    } else {
      state.randomState = (state.randomState * 48271) % 2147483647;
      result = state.randomState % upper;
    }
    if (result < 0 || result >= upper) throw StateError('Invalid random value');
    _recoveryRandom.add({
      'upper': upper,
      'result': result,
      'state': state.randomState,
    });
    return result;
  }

  void _shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = _nextInt(i + 1);
      final value = list[i];
      list[i] = list[j];
      list[j] = value;
    }
  }

  /// Detached views. Hidden skills and card identities are only in the owner's view.
  Map<String, Object?> publicView() => {
    'prey': [
      for (final p in _preyModule.cards)
        {
          'sourceId': p.held.owner.instanceId,
          'holderId': p.holderId,
          'instanceId': p.held.card.instanceId,
          'definitionId': p.held.card.definition.id,
        },
    ],
    'summonedUnits': [
      for (final unit in state.summonedUnits)
        {
          'instanceId': unit.instanceId,
          'ownerId': unit.ownerId,
          'kind': unit.kind,
          'alive': unit.alive,
        },
    ],
    'statistics': statisticsView(includeScores: state.finished),
    'variables': _variableView(),
    'gameId': state.gameId,
    'contentVersion': state.contentVersion,
    'rules': {'useLegacyDamageFormula': rules.useLegacyDamageFormula},
    'globalEffects': _globalEffectView(),
    if (!_privateRecordViews)
      'actionRecords': {
        for (final e in _recordingModule.records.entries)
          e.key: [
            for (final r in e.value)
              {
                'id': r.id,
                'actorId': r.actorId,
                'damage': r.damage,
                'cards': [for (final c in r.cards) c.definition.id],
              },
          ],
      },
    'characterSaves': {
      for (final e in _turnSaveModule.saves.entries)
        e.key: {'id': e.value.id, 'used': e.value.used},
    },
    'version': state.version,
    'round': state.round,
    'turn': state.actualTurn + 1,
    'logicalTurn': state.turn,
    'actualTurn': state.actualTurn,
    'extraTurn': state.extraTurn,
    'phase': state.phase.name,
    'drawPileCount': state.drawPile.length,
    'activePlayerId': state.activePlayer.id,
    'duel': state.duel,
    'waitingPlayerId':
        state.choice?.playerId ??
        state.pending?.waitingPlayerId ??
        (state.finished ? null : state.activePlayer.id),
    'discardCount': state.phase == GamePhase.discard
        ? state.activePlayer.character.hand.length -
              state.activePlayer.character.value(Stat.maxHand)
        : 0,
    'revealedCards': Map<String, String>.of(state.revealedCards),
    'cardCustody': [
      for (final held in state.cardCustody.entries)
        {
          'id': held.id,
          'actionId': held.actionId,
          'ownerId': held.owner.instanceId,
          if (held.revealed) ...{
            'instanceId': held.card.instanceId,
            'definitionId': held.card.definition.id,
          },
        },
    ],
    'preparation': _preparationView(),
    'choice': _choiceView(),
    'responseWindow': _publicResponseWindow(),
    'pending': state.pending == null
        ? null
        : {
            'id': state.pending!.windowId,
            'actionId': state.pending!.id,
            'kind': state.pending!.kind.name,
            'actorId': state.pending!.actorId,
            'targets': state.pending!.targets.toList(),
            'cards': [
              for (final card in state.pending!.cards)
                {
                  'instanceId': card.instanceId,
                  'definitionId': card.definition.id,
                },
            ],
            if (state.pending!.kind == PendingKind.attack ||
                state.pending!.kind == PendingKind.dice)
              'diceSides': state.pending!.diceSides,
            if (state.pending!.kind == PendingKind.attack ||
                state.pending!.kind == PendingKind.dice)
              'diceResult': state.pending!.diceResult,
            'diceCount': state.pending!.diceCount,
            if (state.pending!.diceRoll != null)
              'diceRoll': state.pending!.diceRoll!.toJson(),
            if (state.pending!.skill != null)
              'skillId': state.pending!.skill!.definition.id,
          },
    'players': [
      for (final p in state.players)
        {
          'playerId': p.id,
          'teamId': p.teamId,
          'characterId': p.character.instanceId,
          'definitionId': p.character.definition.id,
          'hp': p.character.hp,
          'resourcePolicy': p.character.noMp
              ? 'healthActions'
              : p.character.defenseLife
              ? 'defenseLife'
              : 'normal',
          'temporaryDefense': [
            for (final bonus in p.character.temporaryDefense)
              {'amount': bonus.amount, 'expiresAtOwnTurn': bonus.expires},
          ],
          'maxHp': p.character.value(Stat.maxHp),
          'attack': p.character.value(Stat.attack),
          'defense': p.character.value(Stat.defense),
          'actionsRemaining': p.character.actionsRemaining,
          'mp': p.character.mp,
          'maxMp': p.character.value(Stat.maxMp),
          'shield': p.character.shield,
          'alive': p.character.alive,
          'handCount': p.character.hand.length,
          'lastRevealedHand': state.revealedHands[p.character.instanceId]
              ?.map(Map<String, Object?>.of)
              .toList(),
          'skills': [
            for (final s in p.character.skills)
              if (s.revealed) _skillView(s),
          ],
          'hiddenSkillCount': p.character.skills
              .where((s) => !s.revealed)
              .length,
          'marks': _markView(p.character, null),
          'statuses': [
            for (final s in p.character.statuses)
              {
                'instanceId': s.instanceId,
                'definitionId': s.definition.id,
                'category': s.definition.category.name,
                'hasIntensity': s.definition.hasIntensity,
                'isStatusEffect': _isStatusEffect(s.definition),
                if (_interactionRulesVersion >= 12 && s.decayAtAnchorEnd) ...{
                  'anchorPlayerId': s.anchorPlayerId,
                  'decayPhase': 'turnEnd',
                },
                if (_interactionRulesVersion >= 15 &&
                    s.definition.decay == StatusDecay.anchorMpRecovery) ...{
                  'anchorPlayerId': s.anchorPlayerId,
                  'decayPhase': 'afterMpRecovery',
                },
                'stacks': s.stacks,
                'intensity': s.intensity,
                if (s.damageLimit != null) 'damageLimit': s.damageLimit,
                if (s.damageLimit != null) 'damageTaken': s.damageTaken,
              },
          ],
        },
    ],
    'outcome': state.outcome == null
        ? null
        : {
            'draw': state.outcome!.draw,
            'winnerTeamId': state.outcome!.winnerTeamId,
            'winnerPlayerId': state.outcome!.winnerPlayerId,
          },
  };
  Map<String, Object?> privateView(String playerId) {
    final actor = _player(playerId).character;
    return {
      'playerId': playerId,
      'variables': _variableView(playerId),
      if (_privateRecordViews)
        'actionRecords': [
          for (final r
              in _recordingModule.records[actor.instanceId] ??
                  const <RecordedAction>[])
            {
              'id': r.id,
              'actorId': r.actorId,
              'damage': r.damage,
              'cards': [for (final card in r.cards) card.definition.id],
            },
        ],
      'characterId': actor.instanceId,
      'version': state.version,
      'preparation': _preparationView(playerId),
      'choice': _choiceView(playerId),
      'responseWindow': _privateResponseWindow(playerId),
      'marks': _markView(actor, playerId),
      if (actor.armedStatusTransfer case final plan?)
        'armedStatusTransfer': {
          'statusInstanceId': plan.statusInstanceId,
          if (plan.targetId != null) 'targetId': plan.targetId,
        },
      'nextAttackTargetId': actor.nextAttackTargetId,
      'extraTurnAttackTarget': actor.extraTurnAttackTarget,
      'preparedCards': [
        for (final c in actor.preparedCards)
          {'instanceId': c.instanceId, 'definitionId': c.definition.id},
      ],
      'armedAttacks': [
        for (final a in actor.armedAttacks)
          {
            'targetId': a.targetId,
            'diceCount': a.rule.diceCount,
            'damageMultiplier': a.rule.damageMultiplier,
            'copyDamage': a.rule.copyDamage,
            'fixedMaximum': a.rule.fixedMaximum,
            'hasOnHit': a.rule.onHit.isNotEmpty,
            'hasAfterEffects': a.rule.after.isNotEmpty,
            'hasRotationBonus': a.rule.rotationBonus.isNotEmpty,
          },
      ],
      'reciprocalDice': Map<String, int>.of(actor.reciprocalDice),
      'traitActions': _traitActionView(actor),
      'canAttack':
          actor.alive &&
          actor.actionsRemaining > 0 &&
          !_blocked(actor, (s) => s.blockAttack) &&
          (actor.noMp ||
              actor.mp >= _actionCost(actor, rules.normalAttackCost)),
      'canPlayCards': actor.alive && _canPrepareCards(actor),
      'attackTargetCandidates': [
        for (final p in state.players)
          if (p.character.alive &&
              p.character != actor &&
              (_interactionRulesVersion < 1 ||
                  p.teamId !=
                      state.players
                          .firstWhere((owner) => owner.character == actor)
                          .teamId) &&
              _incomingAttackTargetAllowed(actor, p.character) &&
              (actor.nextAttackTargetId == null ||
                  actor.nextAttackTargetId == p.character.instanceId) &&
              (actor.extraTurnAttackTarget == null ||
                  actor.extraTurnAttackTarget == p.character.instanceId))
            p.character.instanceId,
      ],
      'statusActions': [
        for (final s in actor.statuses)
          if (s.definition.active != null)
            {
              'instanceId': s.instanceId,
              'definitionId': s.definition.id,
              'enabled':
                  actor.alive &&
                  state.activePlayer.id == playerId &&
                  state.phase == GamePhase.action &&
                  state.pending == null &&
                  state.choice == null &&
                  state.preparation == null,
              'lifeCost':
                  s.definition.active!.lifeCostPerIntensity * s.intensity,
            },
      ],
      'restrictedCardTags': Map<String, int>.of(actor.restrictedCardTags),
      if (actor.anchoredCardTags.isNotEmpty)
        'anchoredCardTags': {
          for (final entry in actor.anchoredCardTags.entries)
            entry.key: entry.value.map((expiry) => expiry.toJson()).toList(),
        },
      'cards': [
        for (final c in actor.hand)
          {
            'instanceId': c.instanceId,
            'definitionId': c.definition.id,
            'disabled': c.disabled,
            'disabledUntilRound': c.disabledUntilRound,
            if (c.disabledUntilAnchor != null)
              'disabledUntilAnchor': c.disabledUntilAnchor!.toJson(),
            'reinforced': c.reinforced,
            if (_interactionRulesVersion >= 1) ...{
              'attackCompanion': _companionCard(actor, c),
              'requiresTarget':
                  _tagNeedsTarget(actor, [c]) ||
                  _cardEffectsFor(
                    actor,
                    _effectiveCard(actor, c),
                    includeNonAttackOnHit: _interactionRulesVersion >= 9,
                  ).any((e) => e.target == EffectTarget.selected),
            },
          },
      ],
      'skills': [
        for (final skill in actor.skills)
          {
            ..._skillView(skill),
            'statCosts': {
              for (final cost in skill.definition.statCosts.entries)
                cost.key.name: cost.value,
            },
            'costsPayable': _settlementUsable(actor, skill),
            'mpCost': actor.noMp ? 0 : _skillMpCost(actor, skill.definition),
            'anytime': skill.definition.anytime,
            'beforeAttack': skill.definition.beforeAttack,
            'beforeCards': skill.definition.beforeCards,
            'lifeCost': skill.definition.lifeCost,
            if (skill.definition.checkpoint case final checkpoint?)
              'checkpoint': {
                'at': checkpoint.at.name,
                'minimumDamage': checkpoint.minimumDamage,
                'attackOnly': checkpoint.attackOnly,
                'kinds': checkpoint.kinds.map((k) => k.name).toList(),
              },
            if (skill.definition.numberParameter case final parameter?)
              'numberParameter': {
                'minimum': parameter.minimum,
                'maximum': actor.defenseLife || parameter.lifeCostPerUnit == 0
                    ? parameter.maximum
                    : ((actor.hp - skill.definition.lifeCost) ~/
                              parameter.lifeCostPerUnit)
                          .clamp(0, parameter.maximum),
                'lifeCostPerUnit': parameter.lifeCostPerUnit,
                'mpCostPerUnit': parameter.mpCostPerUnit,
                'countTargets': parameter.countTargets,
                'allowedValues': parameter.allowedValues,
                'markCostId': parameter.markCostId,
                if (parameter.maximumValue != null)
                  'maximumValue': _amount(
                    0,
                    parameter.maximumValue,
                    actor,
                    actor,
                  ),
              },
            'requirementsMet':
                !skill.definition.passive &&
                (!skill.definition.beforeCards ||
                    _canPrepareSkillCards(actor, skill.definition)) &&
                (!skill.definition.beforeAttack ||
                    actor.actionsRemaining > 0) &&
                (actor.defenseLife ||
                    skill.definition.lifeCost == 0 ||
                    actor.hp >= skill.definition.lifeCost) &&
                _conditionMatches(skill.definition.when, actor, actor) &&
                _skillTargetCandidates(actor, skill.definition).length >=
                    skill.definition.minTargets,
            'targetCandidates': _skillTargetCandidates(actor, skill.definition),
          },
      ],
      'skillModules': _moduleOptions(actor),
      'triggerState': [
        for (final t in actor.traits)
          {
            'instanceId': t.instanceId,
            'counters': Map<String, int>.of(t.counters),
            'uses': {
              for (final entry in t.triggerMemory.uses.entries)
                entry.key.toString(): entry.value,
            },
          },
        for (final t in actor.statuses)
          {
            'instanceId': t.instanceId,
            'counters': Map<String, int>.of(t.counters),
            'uses': {
              for (final entry in t.triggerMemory.uses.entries)
                entry.key.toString(): entry.value,
            },
          },
      ],
    };
  }

  List<String> _skillTargetCandidates(
    CharacterInstance actor,
    SkillDefinition skill,
  ) => [
    for (final player in state.players)
      if (_skillTargetAllowed(actor, skill, player.character))
        player.character.instanceId,
  ];

  Map<String, Object?> _skillView(SkillInstance s) => {
    'instanceId': s.instanceId,
    'definitionId': s.definition.id,
    'cooldown': s.cooldown,
    if (_interactionRulesVersion >= 18 && s.cooldownAnchor != null)
      'cooldownAnchor': s.cooldownAnchor!.toJson(),
    'leasedOut': s.leasedOut,
    'borrowed': s.borrowed,
    'remainingUses': s.remainingUses,
    'revealed': s.revealed,
    'passive': s.definition.passive,
  };
}
