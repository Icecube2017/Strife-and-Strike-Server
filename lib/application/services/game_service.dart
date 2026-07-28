import 'dart:async';
import 'dart:collection';

import 'package:sns_server/application/commands/game_command.dart';
import 'package:sns_server/application/dto/game_dto.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game.dart';
import 'package:sns_server/domain/core/game_state.dart';

/// 一局游戏运行时
class GameRuntime {
  final String gameId;
  final GameState state;
  final GameEngine engine;
  int version = 0;

  /// 用于串行化命令，避免并发踩状态
  final Queue<_PendingCommand> _commandQueue = Queue();
  bool _processing = false;

  /// SSE/WS 订阅者
  final List<StreamController<PublicGameView>> _subscribers = [];

  GameRuntime({required this.gameId, required this.state})
      : engine = GameEngine(state);

  /// 提交命令（幂等键由上层去重后调用此方法）
  Future<CommandResult> submit(GameCommand cmd) {
    final completer = Completer<CommandResult>();
    _commandQueue.add(_PendingCommand(cmd, completer));
    _drainQueue();
    return completer.future;
  }

  void _drainQueue() {
    if (_processing || _commandQueue.isEmpty) return;
    _processing = true;
    _processNext();
  }

  Future<void> _processNext() async {
    while (_commandQueue.isNotEmpty) {
      final pending = _commandQueue.removeFirst();
      try {
        final result = await _execute(pending.command);
        pending.completer.complete(result);
      } catch (e) {
        pending.completer.complete(
          CommandResult(success: false, error: e.toString(), newVersion: version),
        );
      }
    }
    _processing = false;
  }

  Future<CommandResult> _execute(GameCommand cmd) async {
    if (cmd.clientVersion != version) {
      throw StateError('Version conflict: expected $version, got ${cmd.clientVersion}');
    }

    switch (cmd) {
      case EndTurnCommand():
        _assertPlayerCanEndTurn(cmd.playerId);
        await engine.endTurn();
      case PassPriorityCommand():
        await engine.passPriority(cmd.playerId);
      case AttackCommand():
        final character = _resolveOwnedCharacter(
          playerId: cmd.playerId,
          characterId: cmd.attackerCharacterId,
        );
        await engine.processAction(character, ActionType.attack, {
          'targetId': cmd.targetCharacterId,
        });
      case PlayCardCommand():
        final character = _resolveDefaultCharacter(cmd.playerId);
        final inferredActionType = _inferPlayCardActionType(
          character: character,
          selections: cmd.cardSelections,
        );
        await engine.processAction(character, inferredActionType, {
          'cardSelections': cmd.cardSelections.map((selection) => selection.toJson()).toList(),
          'targetId': cmd.targetCharacterId,
        });
      case UseSkillCommand():
        final character = _resolveOwnedCharacter(
          playerId: cmd.playerId,
          characterId: cmd.characterId,
        );
        await engine.processAction(character, ActionType.skill, {
          'skillId': cmd.skillId,
          ...cmd.params,
        });
      case UseTraitCommand():
        final character = _resolveOwnedCharacter(
          playerId: cmd.playerId,
          characterId: cmd.characterId,
        );
        await engine.processAction(character, ActionType.trait, {
          'traitId': cmd.traitId,
          ...cmd.params,
        });
      default:
        throw StateError('Unknown command type: ${cmd.runtimeType}');
    }

    version++;
    _broadcast();
    return CommandResult(success: true, newVersion: version);
  }

  /// 获取公开视图（支持 sinceVersion 快速判断）
  PublicGameView getPublicView() {
    final currentPlayer = _resolveCurrentPublicPlayer();
    return PublicGameView(
      gameId: gameId,
      version: version,
      currentRound: state.currentRound,
      currentTurn: state.currentTurn,
      currentPlayerId: currentPlayer.id,
      currentPhase: state.currentPhase.name,
      characters: state.characterById.values
          .map((c) => CharacterPublicView(
                characterId: c.id,
                currentHp: c.currentHp,
                maxHp: c.maxHp,
                attack: c.attack,
                defense: c.defense,
                currentMp: c.currentMp,
                maxMp: c.maxMp,
                isAlive: c.isAlive,
                statusIds: c.state.map((s) => s.id).toList(),
              ))
          .toList(),
    );
  }

  PlayerPrivateView getPrivateView(String playerId) {
    final player = state.players.firstWhere(
      (p) => p.id == playerId,
      orElse: () => throw StateError('Player $playerId not found'),
    );
    return PlayerPrivateView(
      playerId: playerId,
      // cards: player.currentCharacter.hand.map((c) => c.toJson()).toList(),
      cards: []
    );
  }

  Stream<PublicGameView> subscribe() {
    final ctrl = StreamController<PublicGameView>.broadcast();
    _subscribers.add(ctrl);
    return ctrl.stream;
  }

  void _broadcast() {
    final view = getPublicView();
    for (final ctrl in _subscribers) {
      if (!ctrl.isClosed) ctrl.add(view);
    }
  }

  void _assertPlayerCanEndTurn(String playerId) {
    if (state.activePlayerId != playerId) {
      throw StateError('Only the active player can end the turn');
    }
  }

  Character _resolveDefaultCharacter(String playerId) {
    final player = _getPlayer(playerId);
    return player.currentCharacter;
  }

  ActionType _inferPlayCardActionType({
    required Character character,
    required List<PlayCardSelection> selections,
  }) {
    final cards = _resolvePlayCardSelections(
      character: character,
      selections: selections,
    );
    return cards.any((card) => card.isAttackLimited)
        ? ActionType.limitedCard
        : ActionType.attackCard;
  }

  List<PropCard> _resolvePlayCardSelections({
    required Character character,
    required List<PlayCardSelection> selections,
  }) {
    if (selections.isEmpty) {
      throw StateError('cardSelections must not be empty');
    }

    final resolvedCards = <PropCard>[];
    final reservedHandIndices = <int>{};
    for (final selection in selections) {
      resolvedCards.add(
        _resolveSinglePlayCardSelection(
          character: character,
          selection: selection,
          reservedHandIndices: reservedHandIndices,
        ),
      );
    }
    return resolvedCards;
  }

  PropCard _resolveSinglePlayCardSelection({
    required Character character,
    required PlayCardSelection selection,
    required Set<int> reservedHandIndices,
  }) {
    if (selection.handIndex != null) {
      final handIndex = selection.handIndex!;
      if (handIndex < 0 || handIndex >= character.hand.length) {
        throw StateError('handIndex $handIndex is out of range');
      }
      if (reservedHandIndices.contains(handIndex)) {
        throw StateError('handIndex $handIndex is selected more than once');
      }

      final indexedCard = character.hand[handIndex];
      if (indexedCard.id != selection.cardId) {
        throw StateError(
          'handIndex $handIndex points to ${indexedCard.id}, not the requested card ${selection.cardId}',
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
      if (card.id == selection.cardId) {
        matchedEntries.add(MapEntry(index, card));
      }
    }

    if (matchedEntries.isEmpty) {
      throw StateError('Card ${selection.cardId} not found in character hand');
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
        'Multiple card instances with id ${selection.cardId} have different runtime states; provide handIndex',
      );
    }

    reservedHandIndices.add(matchedEntries.first.key);
    return matchedEntries.first.value;
  }

  Character _resolveOwnedCharacter({
    required String playerId,
    required String characterId,
  }) {
    final player = _getPlayer(playerId);
    final character = state.characterById[characterId];
    if (character == null) {
      throw StateError('Character $characterId not found');
    }
    if (!player.characters.contains(character)) {
      throw StateError('Character $characterId does not belong to player $playerId');
    }
    return character;
  }

  Player _resolveCurrentPublicPlayer() {
    final activePlayerId = state.activePlayerId;
    if (activePlayerId != null) {
      return _getPlayer(activePlayerId);
    }
    return state.players[state.currentPlayerIndex];
  }

  Player _getPlayer(String playerId) {
    final player = state.playerById[playerId];
    if (player == null) {
      throw StateError('Player $playerId not found');
    }
    return player;
  }
}

/// 游戏服务：管理所有局的生命周期
class GameService {
  final RoomService _roomService;
  final Map<String, GameRuntime> _runtimes = {};
  /// 幂等去重：commandId -> result
  final Map<String, CommandResult> _commandCache = {};

  GameService(this._roomService);

  /// 从房间创建游戏
  Future<String> startGame(String roomId, List<PropCard> drawPile) async {
    final players = _roomService.getPlayers(roomId);
    final state = _buildState(players, drawPile);
    final gameId = 'game_$roomId';
    final runtime = GameRuntime(gameId: gameId, state: state);
    _runtimes[gameId] = runtime;
    await _roomService.markInGame(roomId);
    await runtime.engine.initEngine();
    // 游戏开始事件（不 await，让回合推进在后台运行）
    await runtime.engine.startGame();
    return gameId;
  }

  Future<CommandResult> handleCommand(String gameId, GameCommand cmd) async {
    // 幂等去重
    if (_commandCache.containsKey(cmd.commandId)) {
      return _commandCache[cmd.commandId]!;
    }
    final runtime = _getRuntime(gameId);
    final result = await runtime.submit(cmd);
    _commandCache[cmd.commandId] = result;
    return result;
  }

  PublicGameView getState(String gameId) => _getRuntime(gameId).getPublicView();

  PlayerPrivateView getPrivateView(String gameId, String playerId) =>
      _getRuntime(gameId).getPrivateView(playerId);

  Stream<PublicGameView> subscribe(String gameId) => _getRuntime(gameId).subscribe();

  GameRuntime _getRuntime(String gameId) {
    final rt = _runtimes[gameId];
    if (rt == null) throw StateError('Game $gameId not found');
    return rt;
  }

  GameState _buildState(List<Player> players, List<PropCard> drawPile) {
    final state = GameState(players, drawPile, []);
    for (final player in players) {
      for (final character in player.characters) {
        state.characterById[character.id] = character;
      }
      state.playerById[player.id] = player;
    }
    return state;
  }
}

class _PendingCommand {
  final GameCommand command;
  final Completer<CommandResult> completer;
  _PendingCommand(this.command, this.completer);
}
