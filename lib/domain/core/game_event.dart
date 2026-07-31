import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/status.dart';
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
    final list = _listeners[event.runtimeType];
    if (list != null) {
      for (final handler in list) {
        handler(event);
      }
    }
  }
}

class CharacterChangedEvent extends GameEvent {
  Character character;
  CharacterChangedEvent(super.context, this.character);
}

class CharacterTeamChangedEvent extends GameEvent {
  Character character;
  int newTeam;
  CharacterTeamChangedEvent(super.context, this.character, this.newTeam);
}

class GameStartEvent extends GameEvent {
  GameStartEvent(super.context);
}

class CharacterInitializedEvent extends GameEvent {
  Character character;
  CharacterInitializedEvent(super.context, this.character);
}

class RoundStartEvent extends GameEvent {
  RoundStartEvent(super.context);
}

class TurnStartEvent extends GameEvent {
  TurnStartEvent(super.context);
}

class TurnEndEvent extends GameEvent {
  TurnEndEvent(super.context);
}

class PhaseChangedEvent extends GameEvent {
  TurnPhase nextPhase;
  PhaseChangedEvent(super.context, this.nextPhase);
}

class BeforeDiceEvent extends GameEvent {
  DiceRequest request;
  BeforeDiceEvent(
    super.context,
    this.request,
  );
}

class AfterDiceEvent extends GameEvent {
  DiceRequest request;
  DiceRoll roll;
  AfterDiceEvent(
    super.context,
    this.request,
    this.roll,
  );
}

class DiceResolvedEvent extends GameEvent {
  DiceRequest request;
  DiceRoll roll;
  DiceResolvedEvent(
    super.context,
    this.request,
    this.roll,
  );
}

class BeforeDamageEvent extends GameEvent {
  CharacterTarget? source;
  CharacterTarget target;
  Damage damage;
  BeforeDamageEvent(super.context, this.source, this.target, this.damage);
}

class DamageDealtEvent extends GameEvent {
  CharacterTarget? source;
  CharacterTarget target;
  Damage damage;
  DamageDealtEvent(super.context, this.source, this.target, this.damage);
}

class AfterDamageEvent extends GameEvent {
  CharacterTarget? source;
  CharacterTarget target;
  Damage damage;
  AfterDamageEvent(super.context, this.source, this.target, this.damage);
}

class HealDealtEvent extends GameEvent {
  CharacterTarget? source;
  CharacterTarget target;
  int healedHp;

  HealDealtEvent(super.context, this.source, this.target, this.healedHp);
}

class CharacterDiedEvent extends GameEvent {
  Character character;
  CharacterDiedEvent(super.context, this.character);
}

class MovepointChangedEvent extends GameEvent {
  MovepointChangedEvent(super.context);
}

class CardDrawnEvent extends GameEvent {
  Character character;
  List<PropCard> cards;
  int count;
  CardDrawnEvent(super.context, this.character, this.cards, this.count);
}

class CardPlayedEvent extends GameEvent {
  CharacterTarget source;
  CharacterTarget target;
  List<PropCard> cards;
  int count;
  CardPlayedEvent(
    super.context,
    this.source,
    this.target,
    this.cards,
    this.count,
  );
}

class CardDiscardedEvent extends GameEvent {
  Character character;
  List<PropCard> cards;
  int count;
  CardDiscardedEvent(super.context, this.character, this.cards, this.count);
}

class CardGrabbedEvent extends GameEvent {
  CardGrabbedEvent(super.context);
}

class CardGaveEvent extends GameEvent {
  CardGaveEvent(super.context);
}

class StatusAppliedEvent extends GameEvent {
  final Character owner;
  final Status status;

  StatusAppliedEvent(super.context, this.owner, this.status);
}

class StatusDecayedEvent extends GameEvent {
  final Character owner;
  final Status status;

  StatusDecayedEvent(super.context, this.owner, this.status);
}

class StatusDroppedEvent extends GameEvent {
  final Character owner;
  final Status status;

  StatusDroppedEvent(super.context, this.owner, this.status);
}
