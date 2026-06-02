import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/core/game_event.dart';
import 'package:sns_server/domain/core/game_state.dart';

/// 提供游戏当前状态的只读访问
abstract class GameContext {
  GameState get state;
  EventBus get eventBus;
  // 便捷方法
  Iterable<Player> getAllPlayers();
  // 获取当前回合玩家等
  Player? getCurrentPlayer();
  int getCurrentRound();
  int getCurrentTurnIndex();

  Character? getCharacterById(String id);
}
