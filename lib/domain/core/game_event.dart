import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';

abstract class GameEvent {
  final GameContext context;
  GameEvent(this.context);
}

/// 简单事件总线
class EventBus {
  final Map<Type, List<Function>> _listeners = {};
  
  void on<T extends GameEvent>(void Function(T) handler) {
    _listeners.putIfAbsent(T, () => []).add(handler);
  }
  
  void emit<T extends GameEvent>(T event) {
    final list = _listeners[T.runtimeType];
    if (list != null) {
      for (final handler in list) {
        handler(event);
      }
    }
  }
}

class CharacterChangedEvent extends GameEvent {
  Character character;
  CharacterChangedEvent(
    super.context,
    this.character
  );
}

class CharacterTeamChangedEvent extends GameEvent {
  Character character;
  int newTeam;
  CharacterTeamChangedEvent(
    super.context,
    this.character,
    this.newTeam
  );
}

class GameStartEvent extends GameEvent {
  GameStartEvent(super.context);
}

class CharacterInitializedEvent extends GameEvent {
  Character character;
  CharacterInitializedEvent(
    super.context,
    this.character
  );
}

class RoundStartEvent extends GameEvent {
  RoundStartEvent(
    super.context
  );
}

class TurnStartEvent extends GameEvent {
  TurnStartEvent(
    super.context
  );
}


class CardDrawnEvent extends GameEvent {
  Character character;
  PropCard card;
  CardDrawnEvent(
    super.context,
    this.character,
    this.card
  );
}

class TurnEndEvent extends GameEvent {
  TurnEndEvent(
    super.context
  );
}

class PhaseChangedEvent extends GameEvent {
  TurnPhase nextPhase;
  PhaseChangedEvent(
    super.context,
    this.nextPhase
  );
}

class BeforeDamageEvent extends GameEvent {
  BeforeDamageEvent(
    super.context
  );
}

class DamageDealtEvent extends GameEvent {
  CharacterTarget? source;
  CharacterTarget target;
  Damage damage;
  DamageDealtEvent(
    super.context,
    this.source,
    this.target,
    this.damage
  );
}

class AfterDamageEvent extends GameEvent {
  AfterDamageEvent(
    super.context
  );
}

class HealDealtEvent extends GameEvent {
  CharacterTarget? source;
  CharacterTarget target;
  int healedHp;

  HealDealtEvent(
    super.context,
    this.source,
    this.target,
    this.healedHp
  );
}

class CharacterDiedEvent extends GameEvent {
  Character character;
  CharacterDiedEvent(
    super.context,
    this.character
  );
}

class MovepointChangedEvent extends GameEvent {
  MovepointChangedEvent(
    super.context
  );
}

class CardPlayedEvent extends GameEvent {
  CardPlayedEvent(
    super.context
  );
}

class StatusDecayedEvent extends GameEvent {
  StatusDecayedEvent(
    super.context
  );
}

class StatusDroppedEvent extends GameEvent {
  StatusDroppedEvent(
    super.context
  );
}
