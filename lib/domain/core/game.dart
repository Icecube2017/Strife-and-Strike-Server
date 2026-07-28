import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/trait.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/core/register.dart';

/// 游戏引擎
class GameEngine {
  /// 使用给定状态创建游戏引擎实例。
  GameEngine(GameState state)
      : _state = state,
        _context = _GameContextImpl(state),
        _eventBus = state.eventBus;

  final GameState _state;
  final GameContext _context;
  final EventBus _eventBus;

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
    _eventBus..emit(GameStartEvent(_context))
    ..emit(RoundStartEvent(_context));
    await _enterTurn(_state.players.first);
  }

  /// 检查角色在当前流程下是否可以提交指定动作。
  String? getActionBlockReason(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    if (_state.isFinished || _state.flowState == FlowState.finished) {
      return 'Game already finished';
    }
    if (character.isNotActionable()) {
      return 'Character is not actionable';
    }
    final owner = _ownerOfCharacter(character);
    if (owner == null) {
      return 'Character owner not found';
    }

    final flowReason = _getFlowActionBlockReason(owner.id);
    if (flowReason != null) {
      return flowReason;
    }

    final payloadReason = _getPayloadActionBlockReason(type, payload);
    if (payloadReason != null) {
      return payloadReason;
    }

    final targetReason = _getTargetActionBlockReason(character, type, payload);
    if (targetReason != null) {
      return targetReason;
    }

    final playCardTypeReason = _getPlayCardTypeBlockReason(character, type, payload);
    if (playCardTypeReason != null) {
      return playCardTypeReason;
    }

    final stackMutationReason = _getStackMutationBlockReason(payload);
    if (stackMutationReason != null) {
      return stackMutationReason;
    }

    return null;
  }

  /// 检查当前流程是否允许该玩家提交动作。
  String? _getFlowActionBlockReason(String ownerPlayerId) {
    switch (_state.flowState) {
      case FlowState.mainDecision:
        if (_state.activePlayerId != ownerPlayerId) {
          return 'Only the active player can act during the main decision window';
        }
        if (_state.waitingPlayerId != null && _state.waitingPlayerId != ownerPlayerId) {
          return 'Engine is waiting for another player';
        }
        return null;
      case FlowState.responseWindow:
        if (_state.priorityPlayerId != ownerPlayerId) {
          return 'Player does not currently hold response priority';
        }
        if (_state.eligibleResponderIds.isNotEmpty &&
            !_state.eligibleResponderIds.contains(ownerPlayerId)) {
          return 'Player is not an eligible responder';
        }
        return null;
      case FlowState.forcedDecision:
        return 'Engine is waiting for a forced decision';
      case FlowState.discardDecision:
        return 'Engine is waiting for a discard decision';
      case FlowState.bootstrapping:
      case FlowState.turnOpening:
      case FlowState.resolvingStack:
      case FlowState.turnClosing:
      case FlowState.finished:
        return 'Game is not currently accepting actions';
    }
  }

  /// 检查动作载荷是否满足基础字段要求。
  String? _getPayloadActionBlockReason(
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    switch (type) {
      case ActionType.attack:
        return _getMissingPayloadFieldReason(payload, 'targetId');
      case ActionType.playCard:
        return 'playCard must be resolved to attackCard or limitedCard before engine dispatch';
      case ActionType.attackCard:
        return _getPlayCardPayloadReason(payload);
      case ActionType.limitedCard:
        return _getPlayCardPayloadReason(payload);
      case ActionType.skill:
        return _getMissingPayloadFieldReason(payload, 'skillId');
      case ActionType.trait:
        return _getMissingPayloadFieldReason(payload, 'traitId');
      case ActionType.passPriority:
        return 'passPriority must be submitted through the dedicated priority command';
    }
  }

  /// 检查动作目标是否合法。
  String? _getTargetActionBlockReason(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    final targetId = payload['targetId'];
    if (targetId == null) {
      return null;
    }
    if (targetId is! String) {
      return 'Action targetId must be a string';
    }

    final target = _state.characterById[targetId];
    if (target == null) {
      return 'Target character $targetId not found';
    }
    if (!target.isAlive) {
      return 'Target character $targetId is not alive';
    }
    if (type == ActionType.attack && target.id == character.id) {
      return 'Character cannot target itself with a normal attack';
    }

    return null;
  }

  /// 检查多卡出牌动作是否携带了合法的 cardSelections。
  String? _getPlayCardPayloadReason(Map<String, dynamic> payload) {
    final rawSelections = payload['cardSelections'];
    if (rawSelections == null) {
      return 'Missing required action field: cardSelections';
    }
    if (rawSelections is! List) {
      return 'Action cardSelections must be a list';
    }
    if (rawSelections.isEmpty) {
      return 'Action cardSelections must not be empty';
    }

    for (var index = 0; index < rawSelections.length; index++) {
      final rawSelection = rawSelections[index];
      if (rawSelection is! Map) {
        return 'Action cardSelections[$index] must be an object';
      }
      final selection = Map<String, dynamic>.from(rawSelection);
      final cardId = selection['cardId'];
      if (cardId is! String || cardId.isEmpty) {
        return 'Action cardSelections[$index].cardId must be a non-empty string';
      }
      final handIndex = selection['handIndex'];
      if (handIndex != null && handIndex is! int) {
        return 'Action cardSelections[$index].handIndex must be an integer';
      }
    }

    return null;
  }

  /// 检查多卡出牌动作的声明类型是否与所选卡牌的真实类型一致。
  String? _getPlayCardTypeBlockReason(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    if (type != ActionType.attackCard && type != ActionType.limitedCard) {
      return null;
    }

    try {
      final selectedCards = _resolveSelectedPlayCards(character, payload);
      final inferredType = selectedCards.any((card) => card.isAttackLimited)
          ? ActionType.limitedCard
          : ActionType.attackCard;
      if (inferredType != type) {
        return 'Selected cards imply action type ${inferredType.name}, not ${type.name}';
      }
      return null;
    } on StateError catch (error) {
      return error.message.toString();
    }
  }

  /// 根据 cardSelections 从角色手牌中解析本次将要打出的卡牌实例。
  List<PropCard> _resolveSelectedPlayCards(
    Character character,
    Map<String, dynamic> payload,
  ) {
    final rawSelections = payload['cardSelections'];
    if (rawSelections is! List) {
      throw StateError('Action cardSelections must be a list');
    }

    final selectedCards = <PropCard>[];
    final reservedHandIndices = <int>{};
    for (final rawSelection in rawSelections) {
      if (rawSelection is! Map) {
        throw StateError('Each card selection must be an object');
      }
      final selection = Map<String, dynamic>.from(rawSelection);
      selectedCards.add(
        _resolveSingleSelectedPlayCard(
          character: character,
          selection: selection,
          reservedHandIndices: reservedHandIndices,
        ),
      );
    }
    return selectedCards;
  }

  /// 解析 cardSelections 中的单张卡牌引用。
  PropCard _resolveSingleSelectedPlayCard({
    required Character character,
    required Map<String, dynamic> selection,
    required Set<int> reservedHandIndices,
  }) {
    final cardId = selection['cardId'];
    if (cardId is! String || cardId.isEmpty) {
      throw StateError('Action cardSelections[].cardId must be a non-empty string');
    }

    final handIndex = selection['handIndex'];
    if (handIndex != null) {
      if (handIndex is! int) {
        throw StateError('Action cardSelections[].handIndex must be an integer');
      }
      if (handIndex < 0 || handIndex >= character.hand.length) {
        throw StateError('handIndex $handIndex is out of range');
      }
      if (reservedHandIndices.contains(handIndex)) {
        throw StateError('handIndex $handIndex is selected more than once');
      }

      final indexedCard = character.hand[handIndex];
      if (indexedCard.id != cardId) {
        throw StateError(
          'handIndex $handIndex points to ${indexedCard.id}, not the requested card $cardId',
        );
      }

      reservedHandIndices.add(handIndex);
      return indexedCard;
    }

    final matchedEntries = <MapEntry<int, PropCard>>[];
    for (var index = 0; index < character.hand.length; index++) {
      if (reservedHandIndices.contains(index)) {
        continue;
      }
      final card = character.hand[index];
      if (card.id == cardId) {
        matchedEntries.add(MapEntry(index, card));
      }
    }

    if (matchedEntries.isEmpty) {
      throw StateError('Card $cardId not found in character hand');
    }
    if (matchedEntries.length == 1) {
      reservedHandIndices.add(matchedEntries.single.key);
      return matchedEntries.single.value;
    }

    final firstMatch = matchedEntries.first.value;
    final hasDifferentRuntimeState = matchedEntries.any(
      (entry) =>
          entry.value.isDisabled != firstMatch.isDisabled ||
          entry.value.isReinforced != firstMatch.isReinforced ||
          entry.value.isAttackLimited != firstMatch.isAttackLimited,
    );
    if (hasDifferentRuntimeState) {
      throw StateError(
        'Multiple card instances with id $cardId have different runtime states; provide handIndex',
      );
    }

    reservedHandIndices.add(matchedEntries.first.key);
    return matchedEntries.first.value;
  }

  /// 检查响应动作声明的栈修改规则是否合法。
  String? _getStackMutationBlockReason(Map<String, dynamic> payload) {
    try {
      final mutations = _extractStackMutationsFromPayload(
        payload,
        defaultTargetActionId: _state.pendingStack.isNotEmpty ? _state.pendingStack.last.actionId : null,
      );
      if (mutations.isEmpty) {
        return null;
      }
      if (_state.flowState != FlowState.responseWindow) {
        return 'Stack mutations can only be submitted during a response window';
      }

      for (final mutation in mutations) {
        final targetActionId = mutation.targetActionId;
        if (targetActionId == null) {
          return 'Response action must specify a target action to modify';
        }

        final targetAction = _getPendingActionById(targetActionId);
        switch (mutation.type) {
          case StackMutationType.cancelAction: {
            break;
          }
          case StackMutationType.replaceTarget: {
            final newTargetId = mutation.newTargetId;
            if (newTargetId == null || newTargetId.isEmpty) {
              return 'replaceTarget mutation requires a non-empty newTargetId';
            }
            final reason = _getRetargetBlockReason(targetAction, newTargetId);
            if (reason != null) {
              return reason;
            }
            break;
          }
          case StackMutationType.patchPayload: {
            if (mutation.payloadPatch.isEmpty) {
              return 'patchPayload mutation requires a non-empty payloadPatch';
            }
            final patchedTargetId = mutation.payloadPatch['targetId'];
            if (patchedTargetId != null) {
              if (patchedTargetId is! String) {
                return 'payloadPatch.targetId must be a string';
              }
              final reason = _getRetargetBlockReason(targetAction, patchedTargetId);
                if (reason != null) {
                  return reason;
                }
              }
            break;
          }
          case StackMutationType.setPayloadField: {
            final payloadField = mutation.payloadField;
            if (payloadField == null || payloadField.isEmpty) {
              return 'setPayloadField mutation requires a non-empty payloadField';
            }
            if (payloadField == 'targetId') {
              final nextTargetId = mutation.value;
              if (nextTargetId is! String) {
                return 'setPayloadField mutation requires targetId to be a string';
              }
              final reason = _getRetargetBlockReason(targetAction, nextTargetId);
                if (reason != null) {
                  return reason;
                }
              }
            break;
          }
          case StackMutationType.removePayloadField: {
            final payloadField = mutation.payloadField;
            if (payloadField == null || payloadField.isEmpty) {
              return 'removePayloadField mutation requires a non-empty payloadField';
            }
            break;
          }
          case StackMutationType.setDiceResult: {
            final forcedResult = mutation.value;
            if (forcedResult is! int) {
              return 'setDiceResult mutation requires an integer value';
            }
            final diceRequest = targetAction.resolutionState.diceRequest;
            final diceRoll = targetAction.resolutionState.diceRoll;
            if (diceRequest == null || diceRoll == null) {
              return 'setDiceResult can only target an action with a resolved dice roll';
            }
            if (forcedResult < 1 || forcedResult > diceRequest.sides) {
              return 'setDiceResult must be between 1 and ${diceRequest.sides}';
            }
            break;
          }
        }
      }

      return null;
    } catch (error) {
      return _stackMutationErrorMessage(error);
    }
  }

  /// 检查栈上动作被改目标后是否仍满足基础目标规则。
  String? _getRetargetBlockReason(PendingAction targetAction, String newTargetId) {
    final target = _state.characterById[newTargetId];
    if (target == null) {
      return 'Target character $newTargetId not found';
    }
    if (!target.isAlive) {
      return 'Target character $newTargetId is not alive';
    }
    if (targetAction.actionType == ActionType.attack &&
        targetAction.actorCharacterId == newTargetId) {
      return 'Character cannot target itself with a normal attack';
    }
    return null;
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
      final responsePayload = Map<String, dynamic>.from(_state.decision?.payload ?? const {});
      _state.priorityPlayerId = nextPriorityPlayerId;
      _state.waitingPlayerId = nextPriorityPlayerId;
      _state.decision = DecisionContext(
        decisionId: 'response_${_state.currentTurn}_${_state.nextActionSequence}',
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

    _eventBus..emit(TurnStartEvent(_context))
    ..emit(PhaseChangedEvent(_context, TurnPhase.start));
    await _runStartPhase(character);
    if (_state.isFinished || _state.flowState == FlowState.responseWindow) return;
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
  Future<void> processAction(Character character, ActionType type, dynamic data) async {
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
      parentActionId: _state.pendingStack.isNotEmpty ? _state.pendingStack.last.actionId : null,
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
        throw StateError('passPriority must be submitted through the dedicated priority command');
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
      payload: _buildResponseWindowPayload(
        pendingAction,
        forceOpen: forceOpen,
      ),
    );
    return true;
  }

  /// 解析待结算栈直到所有动作完成。
  Future<void> _resolveStack() async {
    _state.flowState = FlowState.resolvingStack;
    _state.decision = null;
    _state.waitingPlayerId = null;
    _state.priorityPlayerId = null;
    _state.eligibleResponderIds.clear();
    _state.passedPlayerIds.clear();

    while (_state.pendingStack.isNotEmpty) {
      final pendingAction = _state.pendingStack.removeLast();
      if (pendingAction.isCancelled) {
        pendingAction.stage = PendingActionStage.cancelled;
        continue;
      }

      final actor = _state.characterById[pendingAction.actorCharacterId];
      if (actor == null) {
        throw StateError(
          'Character ${pendingAction.actorCharacterId} not found during stack resolution',
        );
      }

      _state.resolvingActionId = pendingAction.actionId;
      try {
        pendingAction.stage = PendingActionStage.resolving;
        _applyStackMutations(pendingAction);
        final paused = await _resolvePendingAction(actor, pendingAction);
        if (paused) {
          return;
        }
        _syncPendingActionResolutionStateFromPayload(pendingAction);
        pendingAction.isResolved = true;
        pendingAction.stage = PendingActionStage.resolved;
      } finally {
        _state.resolvingActionId = null;
      }

      if (_checkVictory()) {
        return;
      }
    }
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
        await _dispatchAction(actor, pendingAction.actionType, pendingAction.payload);
        _applyPostDispatchStackMutations(pendingAction);
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
    _syncPendingActionResolutionStateFromPayload(pendingAction);
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
        throw StateError('Trait dice-driven action is missing a resolved dice roll');
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
      throw StateError('Trait dice-driven action failed to resolve a dice roll');
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
      final diceRoll = await _resolveDice(actor, preparedDiceRequest);
      pendingAction.payload['_resolvedDiceRequest'] = diceRoll.request;
      pendingAction.payload['_resolvedDiceRoll'] = diceRoll;
      _materializePostDiceResolutionState(pendingAction);
      _syncPendingActionResolutionStateFromPayload(pendingAction);
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
        .where((player) => player.characters.any((character) => character.isAlive))
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
        winnerTeamId: aliveTeams.length == 1 ? aliveTeams.first.toString() : null,
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
        character..initCharacter()
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

  /// 在响应动作后恢复到可继续决策的状态。
  void _resumeDecisionAfterReaction() {
    if (_state.activePlayerId == null) {
      return;
    }

    final activePlayer = _state.playerById[_state.activePlayerId!];
    if (activePlayer == null) {
      return;
    }

    _openMainDecisionForPlayer(activePlayer);
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

  /// 从动作载荷中提取对栈上旧动作的修改声明。
  List<StackMutation> _extractStackMutationsFromPayload(
    Map<String, dynamic> payload, {
    String? defaultTargetActionId,
  }) {
    final mutations = <StackMutation>[];
    final rawMutations = payload['responseMutations'];
    if (rawMutations != null && rawMutations is! List) {
      throw StateError('responseMutations must be a JSON array');
    }
    if (rawMutations is List) {
      for (final rawMutation in rawMutations) {
        if (rawMutation is! Map) {
          throw StateError('Each response mutation must be a JSON object');
        }
        mutations.add(
          _stackMutationFromMap(
            Map<String, dynamic>.from(rawMutation),
            defaultTargetActionId: defaultTargetActionId,
          ),
        );
      }
    }

    final rawEffect = payload['responseEffect'];
    if (rawEffect != null) {
      mutations.add(
        _stackMutationFromMap(
          payload,
          defaultTargetActionId: defaultTargetActionId,
        ),
      );
    }

    return mutations;
  }

  /// 将单条响应修改载荷解析为内部栈修改对象。
  StackMutation _stackMutationFromMap(
    Map<String, dynamic> rawMutation, {
    String? defaultTargetActionId,
  }) {
    final rawType = rawMutation['responseEffect'] ?? rawMutation['effect'];
    if (rawType is! String || rawType.isEmpty) {
      throw StateError('Response mutation requires a string responseEffect');
    }

    StackMutationType? mutationType;
    for (final candidate in StackMutationType.values) {
      if (candidate.name == rawType) {
        mutationType = candidate;
        break;
      }
    }
    if (mutationType == null) {
      throw StateError('Unknown responseEffect: $rawType');
    }

    final rawPatch = rawMutation['payloadPatch'];
    late final Map<String, dynamic> payloadPatch;
    if (rawPatch == null) {
      payloadPatch = const <String, dynamic>{};
    } else if (rawPatch is Map) {
      payloadPatch = Map<String, dynamic>.from(rawPatch);
    } else {
      throw StateError('payloadPatch must be a JSON object');
    }

    final targetActionId =
        _readOptionalString(rawMutation, 'responseTargetActionId') ??
        _readOptionalString(rawMutation, 'targetActionId') ??
        defaultTargetActionId;

    return StackMutation(
      type: mutationType,
      targetActionId: targetActionId,
      payloadField: _readOptionalString(rawMutation, 'payloadField'),
      value: rawMutation.containsKey('value') ? rawMutation['value'] : rawMutation['payloadValue'],
      newTargetId: _readOptionalString(rawMutation, 'newTargetId'),
      payloadPatch: payloadPatch,
    );
  }

  /// 将响应动作声明的修改应用到仍在栈中的旧动作。
  void _applyStackMutations(PendingAction pendingAction) {
    final mutations = _extractStackMutationsFromPayload(
      pendingAction.payload,
      defaultTargetActionId: pendingAction.parentActionId,
    );
    for (final mutation in mutations) {
      _applySingleStackMutation(mutation);
    }
  }

  /// 应用动作在派发后生成的响应修改。
  void _applyPostDispatchStackMutations(PendingAction pendingAction) {
    final rawMutations = pendingAction.payload['_postDispatchResponseMutations'];
    if (rawMutations == null) {
      return;
    }
    if (rawMutations is! List) {
      throw StateError('_postDispatchResponseMutations must be a JSON array');
    }

    for (final rawMutation in rawMutations) {
      if (rawMutation is! Map) {
        throw StateError('Each post-dispatch response mutation must be a JSON object');
      }
      final mutation = _stackMutationFromMap(
        Map<String, dynamic>.from(rawMutation),
        defaultTargetActionId: pendingAction.parentActionId,
      );
      _applySingleStackMutation(mutation);
    }
  }

  /// 应用单条栈修改规则。
  void _applySingleStackMutation(StackMutation mutation) {
    final targetActionId = mutation.targetActionId;
    if (targetActionId == null) {
      throw StateError('Response action must specify a target action to modify');
    }

    final targetIndex = _findPendingActionIndexById(targetActionId);
    if (targetIndex < 0) {
      throw StateError('Target action $targetActionId not found in pending stack');
    }

    final targetAction = _state.pendingStack[targetIndex];
    switch (mutation.type) {
      case StackMutationType.cancelAction: {
        targetAction.isCancelled = true;
        targetAction.stage = PendingActionStage.cancelled;
        _state.pendingStack.removeAt(targetIndex);
        break;
      }
      case StackMutationType.replaceTarget: {
        final newTargetId = mutation.newTargetId;
        if (newTargetId == null || newTargetId.isEmpty) {
          throw StateError('replaceTarget mutation requires a non-empty newTargetId');
        }
        targetAction.payload['targetId'] = newTargetId;
        targetAction.resolutionState.targetCharacterId = newTargetId;
        break;
      }
      case StackMutationType.patchPayload: {
        if (mutation.payloadPatch.isEmpty) {
          throw StateError('patchPayload mutation requires a non-empty payloadPatch');
        }
        targetAction.payload.addAll(mutation.payloadPatch);
        final targetId = mutation.payloadPatch['targetId'];
        if (targetId is String && targetId.isNotEmpty) {
          targetAction.resolutionState.targetCharacterId = targetId;
        }
        break;
      }
      case StackMutationType.setPayloadField: {
        final payloadField = mutation.payloadField;
        if (payloadField == null || payloadField.isEmpty) {
          throw StateError('setPayloadField mutation requires a non-empty payloadField');
        }
        targetAction.payload[payloadField] = mutation.value;
        if (payloadField == 'targetId' &&
            mutation.value is String &&
            (mutation.value as String).isNotEmpty) {
          targetAction.resolutionState.targetCharacterId = mutation.value as String;
        }
        break;
      }
      case StackMutationType.removePayloadField: {
        final payloadField = mutation.payloadField;
        if (payloadField == null || payloadField.isEmpty) {
          throw StateError('removePayloadField mutation requires a non-empty payloadField');
        }
        targetAction.payload.remove(payloadField);
        if (payloadField == 'targetId') {
          targetAction.resolutionState.targetCharacterId = null;
        }
        break;
      }
      case StackMutationType.setDiceResult: {
        final forcedResult = mutation.value;
        if (forcedResult is! int) {
          throw StateError('setDiceResult mutation requires an integer value');
        }
        _applyDiceResultMutation(targetAction, forcedResult);
        break;
      }
    }
  }

  /// 从动作 payload 中提取本次结算产生的中间态，回填到 PendingAction。
  void _syncPendingActionResolutionStateFromPayload(PendingAction pendingAction) {
    final payload = pendingAction.payload;
    final targetId = payload['targetId'];
    if (targetId is String && targetId.isNotEmpty) {
      pendingAction.resolutionState.targetCharacterId = targetId;
    }

    final diceRequest = payload['_resolvedDiceRequest'];
    if (diceRequest is DiceRequest) {
      pendingAction.resolutionState.diceRequest = diceRequest;
      pendingAction.stage = PendingActionStage.diceResolved;
    }

    final diceRoll = payload['_resolvedDiceRoll'];
    if (diceRoll is DiceRoll) {
      pendingAction.resolutionState.diceRoll = diceRoll;
      pendingAction.resolutionState.damageMultiplier = diceRoll.damageMultiplier;
      pendingAction.stage = PendingActionStage.diceResolved;
    }

    final baseDamage = payload['_resolvedBaseDamage'];
    if (baseDamage is int) {
      pendingAction.resolutionState.baseDamage = baseDamage;
    }

    final resolvedDamage = payload['_resolvedDamage'];
    if (resolvedDamage is Damage) {
      pendingAction.resolutionState.pendingDamage = resolvedDamage;
      pendingAction.stage = PendingActionStage.damagePrepared;
    }
  }

  /// 将一次 setDiceResult 修改应用到目标动作，并回填所有派生中间态。
  void _applyDiceResultMutation(PendingAction targetAction, int forcedResult) {
    final diceRequest = targetAction.resolutionState.diceRequest;
    final diceRoll = targetAction.resolutionState.diceRoll;
    if (diceRequest == null || diceRoll == null) {
      throw StateError('setDiceResult can only target an action with a resolved dice roll');
    }
    if (forcedResult < 1 || forcedResult > diceRequest.sides) {
      throw StateError('setDiceResult must be between 1 and ${diceRequest.sides}');
    }

    final updatedRequest = diceRequest.copyWith(forcedResult: forcedResult);
    final nextHistory = List<int>.from(diceRoll.history);
    if (nextHistory.isEmpty) {
      nextHistory.add(diceRoll.rawResult);
    }
    if (nextHistory.last != forcedResult) {
      nextHistory.add(forcedResult);
    }

    final updatedRoll = diceRoll.copyWith(
      request: updatedRequest,
      finalResult: forcedResult,
      damageMultiplier: forcedResult.toDouble(),
      wasForced: true,
      history: nextHistory,
    );
    targetAction.payload['_resolvedDiceRequest'] = updatedRequest;
    targetAction.payload['_resolvedDiceRoll'] = updatedRoll;
    targetAction.resolutionState
      ..diceRequest = updatedRequest
      ..diceRoll = updatedRoll
      ..damageMultiplier = updatedRoll.damageMultiplier;

    _materializePostDiceResolutionState(targetAction);
    _syncPendingActionResolutionStateFromPayload(targetAction);
    _refreshResponseWindowDecisionForAction(targetAction);
  }

  /// 若当前响应窗口展示的是该动作，则刷新公开快照。
  void _refreshResponseWindowDecisionForAction(PendingAction targetAction) {
    final decision = _state.decision;
    if (decision == null || decision.payload['actionId'] != targetAction.actionId) {
      return;
    }

    _state.decision = DecisionContext(
      decisionId: decision.decisionId,
      type: decision.type,
      allowedPlayerIds: List<String>.from(decision.allowedPlayerIds),
      payload: _buildResponseWindowPayload(
        targetAction,
        forceOpen: decision.payload['forceOpened'] == true,
      ),
    );
  }


  /// 构造响应窗口公开给客户端的动作快照。
  Map<String, dynamic> _buildResponseWindowPayload(
    PendingAction pendingAction, {
    required bool forceOpen,
  }) {
    final payload = <String, dynamic>{
      'actionId': pendingAction.actionId,
      'actionType': pendingAction.actionType.name,
      'stage': pendingAction.stage.name,
      'forceOpened': forceOpen,
    };
    final traitId = pendingAction.payload['traitId'];
    if (traitId is String && traitId.isNotEmpty) {
      payload['traitId'] = traitId;
    }
    final skillId = pendingAction.payload['skillId'];
    if (skillId is String && skillId.isNotEmpty) {
      payload['skillId'] = skillId;
    }
    final trigger = pendingAction.payload['trigger'];
    if (trigger is String && trigger.isNotEmpty) {
      payload['trigger'] = trigger;
    }

    final targetCharacterId = pendingAction.resolutionState.targetCharacterId;
    if (targetCharacterId != null) {
      payload['targetId'] = targetCharacterId;
    }

    final diceRequest = pendingAction.resolutionState.diceRequest;
    if (diceRequest != null) {
      payload['diceRequest'] = {
        'requestId': diceRequest.requestId,
        'sides': diceRequest.sides,
        if (diceRequest.forcedResult != null) 'forcedResult': diceRequest.forcedResult,
        'reason': diceRequest.reason.name,
        if (diceRequest.relatedActionId != null) 'relatedActionId': diceRequest.relatedActionId,
      };
    }

    final diceRoll = pendingAction.resolutionState.diceRoll;
    if (diceRoll != null) {
      payload['diceRoll'] = {
        'rawResult': diceRoll.rawResult,
        'finalResult': diceRoll.finalResult,
        'damageMultiplier': diceRoll.damageMultiplier,
        'wasForced': diceRoll.wasForced,
        'wasRerolled': diceRoll.wasRerolled,
        'history': diceRoll.history,
      };
    }

    final baseDamage = pendingAction.resolutionState.baseDamage;
    if (baseDamage != null) {
      payload['baseDamage'] = baseDamage;
    }

    final pendingDamage = pendingAction.resolutionState.pendingDamage;
    if (pendingDamage != null) {
      payload['pendingDamage'] = {
        'amount': pendingDamage.amount,
        'type': pendingDamage.type.name,
        'source': pendingDamage.source.name,
        if (pendingDamage.diceResult != null) 'diceResult': pendingDamage.diceResult,
      };
    }

    return payload;
  }

  /// 通过动作标识读取仍未结算的待处理动作。
  PendingAction _getPendingActionById(String actionId) {
    final index = _findPendingActionIndexById(actionId);
    if (index < 0) {
      throw StateError('Target action $actionId not found in pending stack');
    }
    return _state.pendingStack[index];
  }

  /// 在当前待结算栈中查找指定动作的位置。
  int _findPendingActionIndexById(String actionId) {
    return _state.pendingStack.indexWhere((action) => action.actionId == actionId);
  }

  /// 读取响应规则中的可选字符串字段并在类型错误时抛出明确异常。
  String? _readOptionalString(Map<String, dynamic> payload, String field) {
    final value = payload[field];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw StateError('$field must be a string');
    }
    return value;
  }

  /// 统一格式化栈修改规则的解析错误。
  String _stackMutationErrorMessage(Object error) {
    if (error is StateError) {
      return error.message.toString();
    }
    return error.toString();
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

  /// 统一解析一次独立掷骰。
  Future<DiceRoll> _resolveDice(
    Character actor,
    DiceRequest request,
  ) async {
    final beforeDiceEvent = BeforeDiceEvent(_context, request);
    _eventBus.emit(beforeDiceEvent);

    final resolvedRequest = beforeDiceEvent.request;
    if (resolvedRequest.sides <= 0) {
      throw StateError('Dice sides must be greater than zero');
    }

    final rawResult = await actor.rollDice(_context, resolvedRequest.sides);
    final forcedResult = _readForcedDiceResult(resolvedRequest);
    final finalResult = forcedResult ?? rawResult;
    final initialRoll = DiceRoll(
      request: resolvedRequest,
      rawResult: rawResult,
      finalResult: finalResult,
      damageMultiplier: finalResult.toDouble(),
      wasForced: forcedResult != null,
      wasRerolled: false,
      history: [
        rawResult,
        if (forcedResult != null && forcedResult != rawResult) finalResult,
      ],
      payload: Map<String, dynamic>.from(resolvedRequest.payload),
    );

    final afterDiceEvent = AfterDiceEvent(
      _context,
      resolvedRequest,
      initialRoll,
    );
    _eventBus.emit(afterDiceEvent);

    var resolvedRoll = afterDiceEvent.roll;
    if (!identical(resolvedRoll.request, afterDiceEvent.request)) {
      resolvedRoll = resolvedRoll.copyWith(request: afterDiceEvent.request);
    }

    _eventBus.emit(
      DiceResolvedEvent(
        _context,
        afterDiceEvent.request,
        resolvedRoll,
      ),
    );
    return resolvedRoll;
  }

  /// 校验并读取掷骰请求中的强制结果。
  int? _readForcedDiceResult(DiceRequest request) {
    final rawForcedResult = request.forcedResult;
    if (rawForcedResult == null) {
      return null;
    }
    if (rawForcedResult < 1 || rawForcedResult > request.sides) {
      throw StateError(
        'forcedResult must be an integer between 1 and ${request.sides}',
      );
    }
    return rawForcedResult;
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
      final nextPlayer = _state.players[(startIndex + offset) % _state.players.length];
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

  /// 返回动作载荷缺失字段时的错误信息。
  String? _getMissingPayloadFieldReason(Map<String, dynamic> payload, String field) {
    if (payload[field] == null) {
      return 'Missing required action field: $field';
    }
    return null;
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
    if (_state.currentPlayerIndex < 0 || _state.currentPlayerIndex >= _state.players.length) {
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
