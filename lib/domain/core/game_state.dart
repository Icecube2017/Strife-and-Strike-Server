import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_event.dart';

class GameState {
  List<Player> players;
  Map<String, Player> playerById = {};
  int currentPlayerIndex = 0;
  Map<String, Character> characterById = {};

  int currentRound = 0;
  int currentTurn = 0;
  int extraTurn = 0;

  // 旧回合推进设计遗留字段，当前 HTTP 驱动模型下暂不使用。  
  // int realCurrentTurn = 0;

  TurnPhase currentPhase = TurnPhase.start;
  FlowState flowState = FlowState.bootstrapping;

  String? activePlayerId;
  String? priorityPlayerId;
  String? waitingPlayerId;
  DecisionContext? decision;
  Set<String> passedPlayerIds = {};
  List<String> eligibleResponderIds = [];
  List<PendingAction> pendingStack = [];
  int nextActionSequence = 0;
  String? resolvingActionId;
  bool isFinished = false;
  GameOutcome? outcome;

  List<PropCard> drawPile;
  List<PropCard> discardPile;

  EventBus eventBus;

  GameState(this.players, this.drawPile, this.discardPile) : eventBus = EventBus();
}
