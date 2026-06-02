import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/core/register.dart';
import 'package:sns_server/domain/data/assets.dart';

/// 游戏引擎
class GameEngine {
  GameEngine(GameState state) 
    : _state = state,
      _context = _GameContextImpl(state),
      _eventBus = state.eventBus;

  final GameState _state;
  final GameContext _context;
  final EventBus _eventBus;
  //final Assets assets = Assets();

  /// 初始化
  Future<void> initEngine() async {
    //assets.loadRacesJson();
    //assets.loadTemplatesJson();
    //assets.loadCardPacks();
    registryAllCards();
  }
  
  /// 启动游戏
  Future<void> startGame() async {
    // 第0回合
    _eventBus.emit(RoundStartEvent(_context));
    // 第1回合
    await _nextTurn();
  }
  
  /// 下一回合
  Future<void> _nextTurn() async {
    // 检查胜利条件
    if (_checkVictory()) return;
    
    // 切换玩家
    _state.currentPlayerIndex = (_state.currentPlayerIndex + 1) % _state.players.length;
    if (_state.currentPlayerIndex == 0) _state.currentRound++;
    
    final player = _state.players[_state.currentPlayerIndex];
    // 每个玩家一个角色
    final character = player.characters.first;
    await _processTurn(player, character);
    await _nextTurn();
  }
  
  /// 处理一个玩家的完整回合
  Future<void> _processTurn(Player player, Character character) async {
    _eventBus.emit(TurnStartEvent(_context));
    
    // 开始阶段
    _state.currentPhase = TurnPhase.start;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.start));
    // 触发开始阶段效果
    for (final effect in character.state) {
      await effect.onTurnStart(_context, character);
    }
    
    // 摸牌阶段
    _state.currentPhase = TurnPhase.draw;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.draw));
    await character.drawCard(_context, 2);
    
    // 行动阶段
    _state.currentPhase = TurnPhase.action;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.action));
    
    // 弃牌阶段
    _state.currentPhase = TurnPhase.discard;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.discard));
    if (character.hand.length > character.maxHand) {
    }
    
    // 结束阶段
    _state.currentPhase = TurnPhase.end;
    _eventBus.emit(PhaseChangedEvent(_context, TurnPhase.end));
    for (final effect in character.state) {
      await effect.onTurnEnd(_context, character);
    }

    // 行动点回复
  }
  
  /// 角色执行动作
  Future<void> processAction(Character character, ActionType type, dynamic data) async {
    if (character.isNotActionable()) {
      
    }
  }
  
  bool _checkVictory() {
    // 检查胜利条件：计算存活队伍
    // ...
    return false;
  }
}

/// 游戏上下文实现
class _GameContextImpl implements GameContext {
  final GameState _state;
  _GameContextImpl(this._state);

  @override
  GameState get state => _state;
  @override
  EventBus get eventBus => _state.eventBus;

  @override
  Iterable<Player> getAllPlayers() => List.unmodifiable(_state.players);

  @override
  Player? getCurrentPlayer() {
    if (_state.currentPlayerIndex < 0 || _state.currentPlayerIndex >= _state.players.length) {
      return null;
    }
    return _state.players[_state.currentPlayerIndex];
  }

  @override
  int getCurrentRound() => _state.currentRound;

  @override
  int getCurrentTurnIndex() => _state.currentPlayerIndex;

  @override
  Character? getCharacterById(String id) => _state.characterById[id];
}
