import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_state.dart';
import 'package:sns_server/domain/core/stack_resolver.dart';

/// Validates action declarations before they are placed on the resolution stack.
class ActionValidator {
  ActionValidator(this._state, this._stackResolver);

  final GameState _state;
  final StackResolver _stackResolver;

  String? validate(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    if (_state.isFinished || _state.flowState == FlowState.finished) {
      return 'Game already finished';
    }
    if (character.isNotActionable()) return 'Character is not actionable';

    final owner = _ownerOf(character);
    if (owner == null) return 'Character owner not found';

    final flowReason = _flowReason(owner.id);
    if (flowReason != null) return flowReason;

    final payloadReason = _payloadReason(type, payload);
    if (payloadReason != null) return payloadReason;

    final targetReason = _targetReason(character, type, payload);
    if (targetReason != null) return targetReason;

    final cardReason = _playCardTypeReason(character, type, payload);
    if (cardReason != null) return cardReason;

    return _stackResolver.getMutationBlockReason(
      payload,
      defaultTargetActionId: _state.pendingStack.isNotEmpty
          ? _state.pendingStack.last.actionId
          : null,
    );
  }

  Player? _ownerOf(Character character) {
    for (final player in _state.players) {
      if (player.characters.contains(character)) return player;
    }
    return null;
  }

  String? _flowReason(String ownerPlayerId) {
    switch (_state.flowState) {
      case FlowState.mainDecision:
        if (_state.activePlayerId != ownerPlayerId) {
          return 'Only the active player can act during the main decision window';
        }
        if (_state.waitingPlayerId != null &&
            _state.waitingPlayerId != ownerPlayerId) {
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

  String? _payloadReason(ActionType type, Map<String, dynamic> payload) {
    switch (type) {
      case ActionType.attack:
        return _missingField(payload, 'targetId');
      case ActionType.playCard:
        return 'playCard must be resolved to attackCard or limitedCard before engine dispatch';
      case ActionType.attackCard:
      case ActionType.limitedCard:
        return _playCardPayloadReason(payload);
      case ActionType.skill:
        return _missingField(payload, 'skillId');
      case ActionType.trait:
        return _missingField(payload, 'traitId');
      case ActionType.passPriority:
        return 'passPriority must be submitted through the dedicated priority command';
    }
  }

  String? _targetReason(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    final targetId = payload['targetId'];
    if (targetId == null) return null;
    if (targetId is! String) return 'Action targetId must be a string';
    final target = _state.characterById[targetId];
    if (target == null) return 'Target character $targetId not found';
    if (!target.isAlive) return 'Target character $targetId is not alive';
    if (type == ActionType.attack && target.id == character.id) {
      return 'Character cannot target itself with a normal attack';
    }
    return null;
  }

  String? _playCardPayloadReason(Map<String, dynamic> payload) {
    final selections = payload['cardSelections'];
    if (selections == null) {
      return 'Missing required action field: cardSelections';
    }
    if (selections is! List) return 'Action cardSelections must be a list';
    if (selections.isEmpty) return 'Action cardSelections must not be empty';
    for (var index = 0; index < selections.length; index++) {
      final selection = selections[index];
      if (selection is! Map) {
        return 'Action cardSelections[$index] must be an object';
      }
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

  String? _playCardTypeReason(
    Character character,
    ActionType type,
    Map<String, dynamic> payload,
  ) {
    if (type != ActionType.attackCard && type != ActionType.limitedCard) {
      return null;
    }
    try {
      final cards = _resolveSelectedCards(character, payload);
      final inferred = cards.any((card) => card.isAttackLimited)
          ? ActionType.limitedCard
          : ActionType.attackCard;
      return inferred == type
          ? null
          : 'Selected cards imply action type ${inferred.name}, not ${type.name}';
    } on StateError catch (error) {
      return error.message.toString();
    }
  }

  List<PropCard> _resolveSelectedCards(
    Character character,
    Map<String, dynamic> payload,
  ) {
    final rawSelections = payload['cardSelections'];
    if (rawSelections is! List) {
      throw StateError('Action cardSelections must be a list');
    }
    final cards = <PropCard>[];
    final reserved = <int>{};
    for (final raw in rawSelections) {
      if (raw is! Map) {
        throw StateError('Each card selection must be an object');
      }
      final selection = Map<String, dynamic>.from(raw);
      final cardId = selection['cardId'];
      if (cardId is! String || cardId.isEmpty) {
        throw StateError(
          'Action cardSelections[].cardId must be a non-empty string',
        );
      }
      final handIndex = selection['handIndex'];
      if (handIndex is int) {
        if (handIndex < 0 || handIndex >= character.hand.length) {
          throw StateError('handIndex $handIndex is out of range');
        }
        if (!reserved.add(handIndex)) {
          throw StateError('handIndex $handIndex is selected more than once');
        }
        final card = character.hand[handIndex];
        if (card.id != cardId) {
          throw StateError(
            'handIndex $handIndex points to ${card.id}, not the requested card $cardId',
          );
        }
        cards.add(card);
        continue;
      }
      if (handIndex != null) {
        throw StateError(
          'Action cardSelections[].handIndex must be an integer',
        );
      }
      final matches = <MapEntry<int, PropCard>>[];
      for (var index = 0; index < character.hand.length; index++) {
        if (!reserved.contains(index) && character.hand[index].id == cardId) {
          matches.add(MapEntry(index, character.hand[index]));
        }
      }
      if (matches.isEmpty) {
        throw StateError('Card $cardId not found in character hand');
      }
      final first = matches.first.value;
      if (matches.length > 1 &&
          matches.any(
            (entry) =>
                entry.value.isDisabled != first.isDisabled ||
                entry.value.isReinforced != first.isReinforced ||
                entry.value.isAttackLimited != first.isAttackLimited,
          )) {
        throw StateError(
          'Multiple card instances with id $cardId have different runtime states; provide handIndex',
        );
      }
      reserved.add(matches.first.key);
      cards.add(first);
    }
    return cards;
  }

  String? _missingField(Map<String, dynamic> payload, String field) =>
      payload[field] == null ? 'Missing required action field: $field' : null;
}
