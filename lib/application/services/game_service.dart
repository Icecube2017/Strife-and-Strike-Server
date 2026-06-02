import 'dart:async';
import 'dart:collection';

import 'package:sns_server/application/commands/game_command.dart';
import 'package:sns_server/application/dto/game_dto.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game.dart';
import 'package:sns_server/domain/core/game_state.dart';

/// 一局游戏运行时（Structure.md §3：RoomRuntime Actor）
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
    final currentPlayer = state.players[state.currentPlayerIndex];
    if (currentPlayer.id != cmd.playerId) {
      throw StateError('Not your turn');
    }
    if (cmd.clientVersion != version) {
      throw StateError('Version conflict: expected $version, got ${cmd.clientVersion}');
    }

    final character = currentPlayer.currentCharacter;

    switch (cmd) {
      case EndTurnCommand():
        // 继续推进回合（由 engine 内部处理）
        break;
      case AttackCommand():
        await engine.processAction(character, ActionType.attack, {
          'targetId': cmd.targetCharacterId,
        });
      case PlayCardCommand():
        await engine.processAction(character, ActionType.attackCard, {
          'cardId': cmd.cardId,
          'targetId': cmd.targetCharacterId,
        });
      case UseSkillCommand():
        await engine.processAction(character, ActionType.limitedCard, {
          'skillId': cmd.skillId,
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
    final currentPlayer = state.players[state.currentPlayerIndex];
    return PublicGameView(
      gameId: gameId,
      version: version,
      currentRound: state.currentRound,
      currentPlayerId: currentPlayer.id,
      currentPhase: state.currentPhase.name,
      characters: state.characterById.values
          .map((c) => CharacterPublicView(
                characterId: c.id,
                name: c.name,
                currentHp: c.currentHp,
                maxHp: c.maxHp,
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
      handCardIds: player.currentCharacter.hand.map((c) => c.id).toList(),
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
    _roomService.markInGame(roomId);
    await runtime.engine.initEngine();
    // 游戏开始事件（不 await，让回合推进在后台运行）
    unawaited(runtime.engine.startGame());
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
