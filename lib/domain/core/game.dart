import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/action_validator.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/dice_resolver.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/core/register.dart';
import 'package:sns_server/domain/core/stack_resolver.dart';

/// 游戏引擎
class GameEngine {
  /// 使用给定状态创建游戏引擎实例。
  GameEngine(GameState state)
    : _state = state,
      _context = _GameContextImpl(state),
      _eventBus = state.eventBus {
    _stackResolver = StackResolver(state);
    _actionValidator = ActionValidator(state, _stackResolver);
    _diceResolver = DiceResolver(_context);
  }

  final GameState _state;
  final GameContext _context;
  final EventBus _eventBus;
  late final StackResolver _stackResolver;
  late final ActionValidator _actionValidator;
  late final DiceResolver _diceResolver;

  /// 初始化注册表、索引和被动效果绑定。
  Future<void> initEngine() async {
    registryAllCards();
    registryAllTraits();
    registryAllSkills();
    _indexEntities();
    await _bindCharacterEffects();
    _resetFlowState();
  }

  /// 启动游戏并推进到首个主行动决策点。
  Future<void> startGame() async {
    if (_state.players.isEmpty) {
      throw StateError('Cannot start game without players');
    }

    _resetFlowState();
    _state.currentRound = 1;
    _state.currentTurn = 1;
    _state.currentPlayerIndex = 0;
    _state.activePlayerId = _state.players.first.id;
    _state.priorityPlayerId = _state.players.first.id;
    _state.waitingPlayerId = _state.players.first.id;
    _state.flowState = FlowState.turnOpening;
    _eventBus
      ..emit(GameStartEvent(_context))
      ..emit(RoundStartEvent(_context));
    await _enterTurn(_state.players.first);
  }

  /// 检查角色在当前流程下是否可以提交指定动作。
  String? getActionBlockReason(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    return _actionValidator.validate(character, type, payload);
  }

  /// 结束当前主动玩家的回合。
  Future<void> endTurn() async {
    _assertNotFinished();

    final player = _currentPlayer;
    final character = player.currentCharacter;

    if (_state.activePlayerId != player.id) {
      throw StateError('Only the active player can end the turn');
    }
    if (_state.flowState != FlowState.mainDecision &&
        _state.flowState != FlowState.discardDecision) {
      throw StateError('Turn can only end from a decision window');
    }

    await _runDiscardPhase(character);
    if (_state.flowState == FlowState.discardDecision) {
      return;
    }

    await _runEndPhase(character);

    if (_checkVictory()) {
      return;
    }

    await _advanceToNextPlayerTurn();
  }

  /// 在响应窗口中放弃当前优先权。
  Future<void> passPriority(String playerId) async {
    _assertNotFinished();

    if (_state.flowState != FlowState.responseWindow) {
      throw StateError('Priority can only be passed during a response window');
    }
    if (_state.priorityPlayerId != playerId) {
      throw StateError('Player does not currently hold response priority');
    }

    _state.passedPlayerIds.add(playerId);
    final nextPriorityPlayerId = _nextEligibleResponderAfter(playerId);
    if (nextPriorityPlayerId != null) {
      final responsePayload = Map<String, dynamic>.from(
        _state.decision?.payload ?? const {},
      );
      _state.priorityPlayerId = nextPriorityPlayerId;
      _state.waitingPlayerId = nextPriorityPlayerId;
      _state.decision = DecisionContext(
        decisionId:
            'response_${_state.currentTurn}_${_state.nextActionSequence}',
        type: DecisionType.response,
        allowedPlayerIds: [nextPriorityPlayerId],
        payload: responsePayload,
      );
      return;
    }

    await _resolveStack();
    if (_checkVictory()) {
      return;
    }
    if (_state.flowState == FlowState.responseWindow) {
      return;
    }

    await _resumeFlowAfterStackResolution();
  }

  /// 进入指定玩家的新回合并推进到行动阶段。
  Future<void> _enterTurn(Player player) async {
    final character = player.currentCharacter;
    _state.currentPlayerIndex = _state.players.indexOf(player);
    _state.activePlayerId = player.id;
    _state.priorityPlayerId = player.id;
    _state.waitingPlayerId = player.id;
    _state.passedPlayerIds.clear();
    _state.eligibleResponderIds.clear();
    _state.decision = null;
    _state.currentPhase = TurnPhase.start;
    _state.flowState = FlowState.turnOpening;

    _eventBus
      ..emit(TurnStartEvent(_context))
      ..emit(PhaseChangedEvent(_context, TurnPhase.start));
    await _runStartPhase(character);
    if (_state.isFinished || _state.flowState == FlowState.responseWindow) {
      return;
    }
    await _continueTurnAfterStartPhase(player);
  }

  /// 结算角色在回合开始阶段的状态效果。
  Future<void> _runStartPhase(Character character) async {
    _state.flowState = FlowState.turnOpening;
    for (final effect in List.of(character.state)) {
      await effect.onTurnStart(_context, character);
    }
    for (final trait in List.of(character.traits)) {
      await trait.onTurnStart(_context, character);
      if (_state.flowState == FlowState.responseWindow || _state.isFinished) {
        return;
      }
      final paused = await _runTurnStartTraitDiceAction(character, trait);
      if (paused || _state.isFinished) {
        return;
      }
    }
  }

  /// 在开始阶段执行需要公开掷骰的特质动作。
  Future<bool> _runTurnStartTraitDiceAction(
    Character character,
    Trait trait,
  ) async {
    final relatedActionId = _nextActionId();
    if (trait.createTurnStartDiceRequest(
          _context,
          character,
          relatedActionId: relatedActionId,
        ) ==
        null) {
      return false;
    }

    final owner = _ownerOfCharacter(character);
    if (owner == null) {
      throw StateError('Character owner not found for turn-start trait action');
    }

    final pendingAction = PendingAction(
      actionId: relatedActionId,
      actorPlayerId: owner.id,
      actorCharacterId: character.id,
      actionType: ActionType.trait,
      payload: {
        'traitId': trait.id,
        'trigger': 'turnStart',
        '_pendingActionId': relatedActionId,
      },
    );
    return _resolveTraitPendingAction(character, pendingAction);
  }

  /// 完成开始阶段后的抽牌与行动阶段推进。
  Future<void> _continueTurnAfterStartPhase(Player player) async {
    final character = player.currentCharacter;
    _state.currentPhase = TurnPhase.draw;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.draw));
    await character.drawCard(_context, 2);
    if (_state.isFinished || _state.flowState == FlowState.responseWindow) {
      return;
    }

    _state.currentPhase = TurnPhase.action;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.action));
    _openMainDecisionForPlayer(player);
  }

  /// 处理回合结束前的弃牌需求。
  Future<void> _runDiscardPhase(Character character) async {
    _state.currentPhase = TurnPhase.discard;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.discard));

    final overflow = character.hand.length - character.maxHand;
    if (overflow > 0) {
      _state.flowState = FlowState.discardDecision;
      _state.waitingPlayerId = _state.activePlayerId;
      _state.priorityPlayerId = _state.activePlayerId;
      _state.decision = DecisionContext(
        decisionId: 'discard_${_state.currentTurn}_${_state.currentRound}',
        type: DecisionType.discard,
        allowedPlayerIds: [_state.activePlayerId!],
        payload: {'discardCount': overflow},
      );
      return;
    }

    _state.decision = null;
  }

  /// 结算角色在回合结束阶段的效果和回复。
  Future<void> _runEndPhase(Character character) async {
    _state.currentPhase = TurnPhase.end;
    _state.flowState = FlowState.turnClosing;
    _state.waitingPlayerId = null;
    _state.priorityPlayerId = null;
    _state.decision = null;

    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.end));
    for (final effect in List.of(character.state)) {
      await effect.onTurnEnd(_context, character);
    }
    for (final trait in List.of(character.traits)) {
      await trait.onTurnEnd(_context, character);
    }
    _eventBus.emit(TurnEndEvent(_context));
    await character.regenMp(_context);
  }

  /// 将回合推进到下一名玩家。
  Future<void> _advanceToNextPlayerTurn() async {
    final nextIndex = (_state.currentPlayerIndex + 1) % _state.players.length;
    _state.currentPlayerIndex = nextIndex;
    _state.currentTurn++;

    if (_state.currentPlayerIndex == 0) {
      _state.currentRound++;
      _eventBus.emit(RoundStartEvent(_context));
    }

    await _enterTurn(_state.players[nextIndex]);
  }

  // 旧的自驱动回合接口已废弃，保留注释仅用于迁移参考。
  // Future<void> _nextTurn() async {}
  // Future<void> _processTurn(Player player, Character character) async {}

  /// 处理角色提交的一次动作请求。
  Future<void> processAction(
    Character character,
    ActionType type,
    dynamic data,
  ) async {
    _assertNotFinished();

    final payload = data is Map<String, dynamic>
        ? Map<String, dynamic>.from(data)
        : <String, dynamic>{'value': data};

    final blockReason = getActionBlockReason(character, type, payload);
    if (blockReason != null) {
      throw StateError(blockReason);
    }

    final owner = _ownerOfCharacter(character);
    if (owner == null) {
      throw StateError('Character owner not found');
    }

    final pendingAction = PendingAction(
      actionId: _nextActionId(),
      actorPlayerId: owner.id,
      actorCharacterId: character.id,
      actionType: type,
      payload: payload,
      parentActionId: _state.pendingStack.isNotEmpty
          ? _state.pendingStack.last.actionId
          : null,
      opensResponseWindow: _shouldOpenResponseWindow(type, payload),
    );
    pendingAction.payload['_pendingActionId'] = pendingAction.actionId;
    final targetId = payload['targetId'];
    if (targetId is String && targetId.isNotEmpty) {
      pendingAction.resolutionState.targetCharacterId = targetId;
    }

    _state.pendingStack.add(pendingAction);

    if (pendingAction.opensResponseWindow) {
      final opened = _openResponseWindow(pendingAction);
      if (opened) {
        return;
      }
    }

    await _resolveStack();

    if (_checkVictory()) {
      return;
    }
    if (_state.flowState == FlowState.responseWindow) {
      return;
    }
    await _resumeFlowAfterStackResolution();
  }

  /// 按动作类型分发到具体处理函数。
  Future<void> _dispatchAction(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) async {
    switch (type) {
      case ActionType.attack:
        await _handleAttack(character, payload);
      case ActionType.playCard:
        throw StateError(
          'playCard must be resolved to attackCard or limitedCard before engine dispatch',
        );
      case ActionType.attackCard:
        await _handleAttackCard(character, payload);
      case ActionType.limitedCard:
        await _handleLimitedCard(character, payload);
      case ActionType.skill:
        await _handleSkill(character, payload);
      case ActionType.trait:
        await _handleTrait(character, payload);
      case ActionType.passPriority:
        throw StateError(
          'passPriority must be submitted through the dedicated priority command',
        );
    }
  }

  /// 处理普通攻击动作。
  Future<void> _handleAttack(
    Character character,
    Map<String, dynamic> payload,
  ) async {
    _requirePayloadField(payload, 'targetId');
    await character.act(_context, ActionType.attack, payload);
  }

  /// 处理攻击型卡牌动作。
  Future<void> _handleAttackCard(
    Character character,
    Map<String, dynamic> payload,
  ) async {
    _requirePayloadField(payload, 'cardSelections');
    await character.act(_context, ActionType.attackCard, payload);
  }

  /// 处理限定牌或特殊牌动作。
  Future<void> _handleLimitedCard(
    Character character,
    Map<String, dynamic> payload,
  ) async {
    _requirePayloadField(payload, 'cardSelections');
    await character.act(_context, ActionType.limitedCard, payload);
  }

  /// 处理技能动作。
  Future<void> _handleSkill(
    Character character,
    Map<String, dynamic> payload,
  ) async {
    _requirePayloadField(payload, 'skillId');
    await character.act(_context, ActionType.skill, payload);
  }

  /// 处理特质动作。
  Future<void> _handleTrait(
    Character character,
    Map<String, dynamic> payload,
  ) async {
    _requirePayloadField(payload, 'traitId');
    await character.act(_context, ActionType.trait, payload);
  }

  /// 判断该动作是否需要打开响应窗口。
  bool _shouldOpenResponseWindow(
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    final explicit = payload['opensResponseWindow'];
    if (explicit is bool) {
      return explicit;
    }

    switch (type) {
      case ActionType.attack:
      case ActionType.playCard:
      case ActionType.attackCard:
      case ActionType.limitedCard:
      case ActionType.skill:
      case ActionType.trait:
        return false;
      case ActionType.passPriority:
        return false;
    }
  }

  /// 打开针对最新动作的响应窗口。
  bool _openResponseWindow(
    PendingAction pendingAction, {
    bool forceOpen = false,
  }) {
    final responders = _buildEligibleResponderIds(pendingAction.actorPlayerId);
    if (responders.isEmpty) {
      return false;
    }

    final nextPriorityPlayerId = _nextEligibleResponderAfter(
      pendingAction.actorPlayerId,
      candidates: responders,
    );
    if (nextPriorityPlayerId == null) {
      return false;
    }

    _state.flowState = FlowState.responseWindow;
    _state.eligibleResponderIds = responders;
    _state.passedPlayerIds.clear();
    _state.priorityPlayerId = nextPriorityPlayerId;
    _state.waitingPlayerId = nextPriorityPlayerId;
    pendingAction.stage = PendingActionStage.waitingResponse;
    _state.decision = DecisionContext(
      decisionId: 'response_${pendingAction.actionId}',
      type: DecisionType.response,
      allowedPlayerIds: [nextPriorityPlayerId],
      payload: _stackResolver.buildResponsePayload(
        pendingAction,
        forceOpen: forceOpen,
      ),
    );
    return true;
  }

  /// 解析待结算栈直到所有动作完成。
  Future<void> _resolveStack() async {
    await _stackResolver.resolve(
      resolveAction: _resolvePendingAction,
      checkVictory: _checkVictory,
    );
  }

  /// 解析单个待结算动作；若中途打开响应窗口则返回 true。
  Future<bool> _resolvePendingAction(
    Character actor,
    PendingAction pendingAction,
  ) async {
    switch (pendingAction.actionType) {
      case ActionType.attackCard:
        return _resolveAttackCardPendingAction(actor, pendingAction);
      case ActionType.trait:
        return _resolveTraitPendingAction(actor, pendingAction);
      case ActionType.attack:
      case ActionType.playCard:
      case ActionType.limitedCard:
      case ActionType.skill:
      case ActionType.passPriority:
        await _dispatchAction(
          actor,
          pendingAction.actionType,
          pendingAction.payload,
        );
        _stackResolver.applyPostDispatchMutations(pendingAction);
        return false;
    }
  }

  /// 分两段结算攻击型卡牌：先公开骰子结果，再继续伤害结算。
  Future<bool> _resolveAttackCardPendingAction(
    Character actor,
    PendingAction pendingAction,
  ) async {
    if (_shouldResumeDiceDrivenResolution(pendingAction)) {
      pendingAction.payload.remove('_deferDamageResolution');
      pendingAction.payload['_resumeDamageResolutionOnly'] = true;
      await _handleAttackCard(actor, pendingAction.payload);
      pendingAction.payload.remove('_resumeDamageResolutionOnly');
      return false;
    }

    pendingAction.payload['_deferDamageResolution'] = true;
    await _handleAttackCard(actor, pendingAction.payload);
    pendingAction.payload.remove('_deferDamageResolution');
    _stackResolver.syncResolutionState(pendingAction);
    if (!_hasPreparedDicePhase(pendingAction)) {
      return false;
    }

    final paused = await _resolveStandaloneDicePhase(
      actor,
      pendingAction,
      forceOpen: true,
    );
    if (paused) {
      return true;
    }

    pendingAction.payload['_resumeDamageResolutionOnly'] = true;
    await _handleAttackCard(actor, pendingAction.payload);
    pendingAction.payload.remove('_resumeDamageResolutionOnly');
    return false;
  }

  /// 判断依赖掷骰公开后的动作是否已经完成前半段，可直接恢复结算。
  bool _shouldResumeDiceDrivenResolution(PendingAction pendingAction) {
    return pendingAction.stage == PendingActionStage.waitingResponse ||
        pendingAction.stage == PendingActionStage.diceResolved ||
        pendingAction.stage == PendingActionStage.damagePrepared ||
        pendingAction.resolutionState.diceRequest != null ||
        pendingAction.resolutionState.diceRoll != null ||
        pendingAction.resolutionState.pendingDamage != null ||
        pendingAction.payload['_resolvedDiceRequest'] is DiceRequest ||
        pendingAction.payload['_resolvedDiceRoll'] is DiceRoll ||
        pendingAction.payload['_resolvedDamage'] is Damage;
  }

  /// 判断当前动作是否已经准备好了独立的掷骰阶段。
  bool _hasPreparedDicePhase(PendingAction pendingAction) {
    return pendingAction.resolutionState.diceRequest != null ||
        pendingAction.payload['_resolvedDiceRequest'] is DiceRequest;
  }

  /// 解析带有独立掷骰阶段的特质动作。
  Future<bool> _resolveTraitPendingAction(
    Character actor,
    PendingAction pendingAction,
  ) async {
    final trait = _resolveTraitForPendingAction(actor, pendingAction);
    if (!_isTurnStartTraitDiceAction(pendingAction)) {
      await _handleTrait(actor, pendingAction.payload);
      return false;
    }

    if (_shouldResumeDiceDrivenResolution(pendingAction)) {
      final diceRoll = pendingAction.resolutionState.diceRoll;
      if (diceRoll == null) {
        throw StateError(
          'Trait dice-driven action is missing a resolved dice roll',
        );
      }
      await trait.onTurnStartDiceResolved(_context, actor, diceRoll);
      return false;
    }

    final relatedActionId = pendingAction.actionId;
    final preparedDiceRequest =
        pendingAction.resolutionState.diceRequest ??
        trait.createTurnStartDiceRequest(
          _context,
          actor,
          relatedActionId: relatedActionId,
        );
    if (preparedDiceRequest == null) {
      await _handleTrait(actor, pendingAction.payload);
      return false;
    }

    pendingAction.resolutionState.diceRequest = preparedDiceRequest;
    pendingAction.payload['_resolvedDiceRequest'] = preparedDiceRequest;
    final paused = await _resolveStandaloneDicePhase(
      actor,
      pendingAction,
      forceOpen: true,
    );
    if (paused) {
      return true;
    }

    final diceRoll = pendingAction.resolutionState.diceRoll;
    if (diceRoll == null) {
      throw StateError(
        'Trait dice-driven action failed to resolve a dice roll',
      );
    }
    await trait.onTurnStartDiceResolved(_context, actor, diceRoll);
    return false;
  }

  /// 统一处理 pending action 的独立掷骰阶段，并在需要时打开响应窗口。
  Future<bool> _resolveStandaloneDicePhase(
    Character actor,
    PendingAction pendingAction, {
    required bool forceOpen,
  }) async {
    var preparedDiceRequest = pendingAction.resolutionState.diceRequest;
    if (preparedDiceRequest == null) {
      final payloadDiceRequest = pendingAction.payload['_resolvedDiceRequest'];
      if (payloadDiceRequest is DiceRequest) {
        preparedDiceRequest = payloadDiceRequest;
        pendingAction.resolutionState.diceRequest = payloadDiceRequest;
      }
    }
    if (preparedDiceRequest == null) {
      return false;
    }

    if (pendingAction.resolutionState.diceRoll == null) {
      final diceRoll = await _diceResolver.resolve(actor, preparedDiceRequest);
      pendingAction.payload['_resolvedDiceRequest'] = diceRoll.request;
      pendingAction.payload['_resolvedDiceRoll'] = diceRoll;
      _materializePostDiceResolutionState(pendingAction);
      _stackResolver.syncResolutionState(pendingAction);
    }

    final opened = _openResponseWindow(
      pendingAction,
      forceOpen: forceOpen,
    );
    if (opened) {
      _state.pendingStack.add(pendingAction);
      return true;
    }
    return false;
  }

  /// 在掷骰结束后补齐动作后续需要公开的中间态。
  void _materializePostDiceResolutionState(PendingAction pendingAction) {
    switch (pendingAction.actionType) {
      case ActionType.attackCard:
        _materializeAttackCardPendingDamage(pendingAction);
        return;
      case ActionType.attack:
      case ActionType.playCard:
      case ActionType.limitedCard:
      case ActionType.skill:
      case ActionType.trait:
      case ActionType.passPriority:
        return;
    }
  }

  /// 根据 attackCard 已准备的基础伤害和骰子结果，回填 pendingDamage。
  void _materializeAttackCardPendingDamage(PendingAction pendingAction) {
    final diceRoll = pendingAction.payload['_resolvedDiceRoll'];
    final baseDamage = pendingAction.payload['_resolvedBaseDamage'];
    if (diceRoll is! DiceRoll || baseDamage is! int) {
      return;
    }

    pendingAction.payload['_resolvedDamage'] = Damage(
      (baseDamage * diceRoll.damageMultiplier).round(),
      DamageType.physical,
      DamageSource.action,
      diceRoll.finalResult,
    );
  }

  /// 检查是否已经满足对局胜利条件。
  bool _checkVictory() {
    final alivePlayers = _state.players
        .where(
          (player) => player.characters.any((character) => character.isAlive),
        )
        .toList();
    final aliveTeams = alivePlayers.map((player) => player.teamId).toSet();

    if (aliveTeams.length <= 1 && alivePlayers.isNotEmpty) {
      _state.isFinished = true;
      _state.flowState = FlowState.finished;
      _state.priorityPlayerId = null;
      _state.waitingPlayerId = null;
      _state.decision = null;
      _state.outcome = GameOutcome(
        type: GameOutcomeType.victory,
        winnerPlayerId: alivePlayers.length == 1 ? alivePlayers.first.id : null,
        winnerTeamId: aliveTeams.length == 1
            ? aliveTeams.first.toString()
            : null,
        reason: 'Only one team remains alive',
      );
      return true;
    }

    return false;
  }

  /// 重建玩家和角色的快速索引表。
  void _indexEntities() {
    for (final player in _state.players) {
      _state.playerById[player.id] = player;
      for (final character in player.characters) {
        _state.characterById[character.id] = character;
      }
    }
  }

  /// 绑定角色、状态和特质的运行时效果。
  Future<void> _bindCharacterEffects() async {
    for (final player in _state.players) {
      for (final character in player.characters) {
        character
          ..initCharacter()
          ..registerListeners(_eventBus);

        for (final status in character.state) {
          await status.ownerTransfer(_context, character);
        }

        for (final trait in character.traits) {
          await trait.register(_context, character);
        }
      }
    }
  }

  /// 重置对局流程相关的临时状态。
  void _resetFlowState() {
    _state.flowState = FlowState.bootstrapping;
    _state.activePlayerId = null;
    _state.priorityPlayerId = null;
    _state.waitingPlayerId = null;
    _state.decision = null;
    _state.passedPlayerIds.clear();
    _state.eligibleResponderIds.clear();
    _state.pendingStack.clear();
    _state.nextActionSequence = 0;
    _state.resolvingActionId = null;
    _state.isFinished = false;
    _state.outcome = null;
  }

  /// 为主动玩家打开主行动决策窗口。
  void _openMainDecisionForPlayer(Player player) {
    _state.flowState = FlowState.mainDecision;
    _state.activePlayerId = player.id;
    _state.priorityPlayerId = player.id;
    _state.waitingPlayerId = player.id;
    _state.passedPlayerIds.clear();
    _state.eligibleResponderIds.clear();
    _state.decision = DecisionContext(
      decisionId: 'action_${_state.currentTurn}_${player.id}',
      type: DecisionType.action,
      allowedPlayerIds: [player.id],
    );
  }

  /// 在栈或响应窗口结算完成后恢复主流程。
  Future<void> _resumeFlowAfterStackResolution() async {
    if (_state.isFinished || _state.flowState == FlowState.responseWindow) {
      return;
    }

    final activePlayerId = _state.activePlayerId;
    if (activePlayerId == null) {
      return;
    }
    final activePlayer = _state.playerById[activePlayerId];
    if (activePlayer == null) {
      return;
    }

    if (_state.currentPhase == TurnPhase.start) {
      await _continueTurnAfterStartPhase(activePlayer);
      return;
    }

    _openMainDecisionForPlayer(activePlayer);
  }

  /// 断言当前对局尚未结束。
  void _assertNotFinished() {
    if (_state.isFinished || _state.flowState == FlowState.finished) {
      throw StateError('Game already finished');
    }
  }

  /// 根据角色实例反查所属玩家。
  Player? _ownerOfCharacter(Character character) {
    for (final player in _state.players) {
      if (player.characters.contains(character)) {
        return player;
      }
    }
    return null;
  }

  /// 返回当前流程中被视为行动方的玩家。
  Player get _currentPlayer {
    final activePlayerId = _state.activePlayerId;
    if (activePlayerId != null) {
      final activePlayer = _state.playerById[activePlayerId];
      if (activePlayer != null) {
        return activePlayer;
      }
    }
    return _state.players[_state.currentPlayerIndex];
  }

  /// 生成下一条待结算动作的唯一标识。
  String _nextActionId() {
    _state.nextActionSequence++;
    return 'action_${_state.currentRound}_${_state.currentTurn}_${_state.nextActionSequence}';
  }

  /// 解析 pending action 对应的特质实例。
  Trait _resolveTraitForPendingAction(
    Character actor,
    PendingAction pendingAction,
  ) {
    final rawTraitId = pendingAction.payload['traitId'];
    if (rawTraitId is! String || rawTraitId.isEmpty) {
      throw StateError('Trait pending action requires a non-empty traitId');
    }
    for (final trait in actor.traits) {
      if (trait.id == rawTraitId) {
        return trait;
      }
    }
    throw StateError('Character ${actor.id} does not own trait $rawTraitId');
  }

  /// 判断当前特质动作是否是回合开始阶段的掷骰动作。
  bool _isTurnStartTraitDiceAction(PendingAction pendingAction) {
    return pendingAction.payload['trigger'] == 'turnStart';
  }

  /// 计算某个动作触发后可参与响应的玩家列表。
  List<String> _buildEligibleResponderIds(String actingPlayerId) {
    return _state.players
        .where((player) => player.id != actingPlayerId)
        .map((player) => player.id)
        .toList();
  }

  /// 查找在指定玩家之后的下一个响应优先权持有者。
  String? _nextEligibleResponderAfter(
    String playerId, {
    List<String>? candidates,
  }) {
    final responderCandidates = candidates ?? _state.eligibleResponderIds;
    if (responderCandidates.isEmpty) {
      return null;
    }

    final startIndex = _playerIndex(playerId);
    for (var offset = 1; offset <= _state.players.length; offset++) {
      final nextPlayer =
          _state.players[(startIndex + offset) % _state.players.length];
      if (!responderCandidates.contains(nextPlayer.id)) {
        continue;
      }
      if (_state.passedPlayerIds.contains(nextPlayer.id)) {
        continue;
      }
      return nextPlayer.id;
    }
    return null;
  }

  /// 断言动作载荷中存在指定字段。
  void _requirePayloadField(Map<String, dynamic> payload, String field) {
    final value = payload[field];
    if (value == null) {
      throw StateError('Missing required action field: $field');
    }
  }

  /// 返回指定玩家在座次列表中的索引。
  int _playerIndex(String playerId) {
    final index = _state.players.indexWhere((player) => player.id == playerId);
    if (index < 0) {
      throw StateError('Player $playerId not found in turn order');
    }
    return index;
  }
}

/// 游戏上下文实现
class _GameContextImpl implements GameContext {
  final GameState _state;

  /// 使用当前游戏状态创建上下文视图。
  _GameContextImpl(this._state);

  @override
  /// 返回当前上下文关联的游戏状态。
  GameState get state => _state;
  @override
  /// 返回当前上下文使用的事件总线。
  EventBus get eventBus => _state.eventBus;

  @override
  /// 返回所有玩家的只读视图。
  Iterable<Player> getAllPlayers() => List.unmodifiable(_state.players);

  @override
  /// 返回当前流程对应的玩家。
  Player? getCurrentPlayer() {
    if (_state.activePlayerId != null) {
      return _state.playerById[_state.activePlayerId!];
    }
    if (_state.currentPlayerIndex < 0 ||
        _state.currentPlayerIndex >= _state.players.length) {
      return null;
    }
    return _state.players[_state.currentPlayerIndex];
  }

  @override
  /// 返回当前回合数。
  int getCurrentRound() => _state.currentRound;

  @override
  /// 返回当前玩家索引。
  int getCurrentTurnIndex() => _state.currentPlayerIndex;

  @override
  /// 通过角色标识查找角色实例。
  Character? getCharacterById(String id) => _state.characterById[id];
}
