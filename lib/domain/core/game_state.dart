import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
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
  int realCurrentTurn = 0;
  
  TurnPhase currentPhase = TurnPhase.start;

  List<PropCard> drawPile;
  List<PropCard> discardPile;

  EventBus eventBus;
  
  GameState(this.players, this.drawPile, this.discardPile) : eventBus = EventBus();
}
