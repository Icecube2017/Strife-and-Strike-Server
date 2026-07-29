import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_state.dart';

/// Owns pending-action stack mechanics and response mutations.
class StackResolver {
  StackResolver(this._state);

  final GameState _state;

  Future<void> resolve({
    required Future<bool> Function(Character actor, PendingAction action)
    resolveAction,
    required bool Function() checkVictory,
  }) async {
    _state.flowState = FlowState.resolvingStack;
    _state.decision = null;
    _state.waitingPlayerId = null;
    _state.priorityPlayerId = null;
    _state.eligibleResponderIds.clear();
    _state.passedPlayerIds.clear();

    while (_state.pendingStack.isNotEmpty) {
      final action = _state.pendingStack.removeLast();
      if (action.isCancelled) {
        action.stage = PendingActionStage.cancelled;
        continue;
      }
      final actor = _state.characterById[action.actorCharacterId];
      if (actor == null) {
        throw StateError(
          'Character ${action.actorCharacterId} not found during stack resolution',
        );
      }

      _state.resolvingActionId = action.actionId;
      try {
        action.stage = PendingActionStage.resolving;
        applyMutationsFromPayload(
          action.payload,
          defaultTargetActionId: action.parentActionId,
        );
        if (await resolveAction(actor, action)) return;
        syncResolutionState(action);
        action..isResolved = true
        ..stage = PendingActionStage.resolved;
      } finally {
        _state.resolvingActionId = null;
      }
      if (checkVictory()) return;
    }
  }

  String? getMutationBlockReason(
    Map<String, dynamic> payload, {
    String? defaultTargetActionId,
  }) {
    try {
      final mutations = extractMutations(
        payload,
        defaultTargetActionId: defaultTargetActionId,
      );
      if (mutations.isEmpty) return null;
      if (_state.flowState != FlowState.responseWindow) {
        return 'Stack mutations can only be submitted during a response window';
      }
      for (final mutation in mutations) {
        final actionId = mutation.targetActionId;
        if (actionId == null) {
          return 'Response action must specify a target action to modify';
        }
        final target = _getAction(actionId);
        switch (mutation.type) {
          case StackMutationType.cancelAction:
            break;
          case StackMutationType.replaceTarget:
            final id = mutation.newTargetId;
            if (id == null || id.isEmpty) {
              return 'replaceTarget mutation requires a non-empty newTargetId';
            }
            final reason = _retargetReason(target, id);
            if (reason != null) return reason;
          case StackMutationType.patchPayload:
            if (mutation.payloadPatch.isEmpty) {
              return 'patchPayload mutation requires a non-empty payloadPatch';
            }
            final id = mutation.payloadPatch['targetId'];
            if (id != null) {
              if (id is! String) {
                return 'payloadPatch.targetId must be a string';
              }
              final reason = _retargetReason(target, id);
              if (reason != null) return reason;
            }
          case StackMutationType.setPayloadField:
            final field = mutation.payloadField;
            if (field == null || field.isEmpty) {
              return 'setPayloadField mutation requires a non-empty payloadField';
            }
            if (field == 'targetId') {
              if (mutation.value is! String) {
                return 'setPayloadField mutation requires targetId to be a string';
              }
              final reason = _retargetReason(target, mutation.value as String);
              if (reason != null) return reason;
            }
          case StackMutationType.removePayloadField:
            if (mutation.payloadField == null ||
                mutation.payloadField!.isEmpty) {
              return 'removePayloadField mutation requires a non-empty payloadField';
            }
          case StackMutationType.setDiceResult:
            final result = mutation.value;
            final request = target.resolutionState.diceRequest;
            final roll = target.resolutionState.diceRoll;
            if (result is! int) {
              return 'setDiceResult mutation requires an integer value';
            }
            if (request == null || roll == null) {
              return 'setDiceResult can only target an action with a resolved dice roll';
            }
            if (result < 1 || result > request.sides) {
              return 'setDiceResult must be between 1 and ${request.sides}';
            }
        }
      }
      return null;
    } catch (error) {
      return error is StateError ? error.message : error.toString();
    }
  }

  List<StackMutation> extractMutations(
    Map<String, dynamic> payload, {
    String? defaultTargetActionId,
  }) {
    final mutations = <StackMutation>[];
    final raw = payload['responseMutations'];
    if (raw != null && raw is! List) {
      throw StateError('responseMutations must be a JSON array');
    }
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) {
          throw StateError('Each response mutation must be a JSON object');
        }
        mutations.add(
          _mutationFromMap(
            Map<String, dynamic>.from(entry),
            defaultTargetActionId,
          ),
        );
      }
    }
    if (payload['responseEffect'] != null) {
      mutations.add(_mutationFromMap(payload, defaultTargetActionId));
    }
    return mutations;
  }

  void applyMutationsFromPayload(
    Map<String, dynamic> payload, {
    String? defaultTargetActionId,
  }) {
    for (final mutation in extractMutations(
      payload,
      defaultTargetActionId: defaultTargetActionId,
    )) {
      _applyMutation(mutation);
    }
  }

  void applyPostDispatchMutations(PendingAction action) {
    final raw = action.payload['_postDispatchResponseMutations'];
    if (raw == null) return;
    if (raw is! List) {
      throw StateError('_postDispatchResponseMutations must be a JSON array');
    }
    for (final entry in raw) {
      if (entry is! Map) {
        throw StateError(
          'Each post-dispatch response mutation must be a JSON object',
        );
      }
      _applyMutation(
        _mutationFromMap(
          Map<String, dynamic>.from(entry),
          action.parentActionId,
        ),
      );
    }
  }

  void syncResolutionState(PendingAction action) {
    final payload = action.payload;
    final target = payload['targetId'];
    if (target is String && target.isNotEmpty) {
      action.resolutionState.targetCharacterId = target;
    }
    final request = payload['_resolvedDiceRequest'];
    if (request is DiceRequest) {
      action.resolutionState.diceRequest = request;
      action.stage = PendingActionStage.diceResolved;
    }
    final roll = payload['_resolvedDiceRoll'];
    if (roll is DiceRoll) {
      action.resolutionState
        ..diceRoll = roll
        ..damageMultiplier = roll.damageMultiplier;
      action.stage = PendingActionStage.diceResolved;
    }
    final baseDamage = payload['_resolvedBaseDamage'];
    if (baseDamage is int) action.resolutionState.baseDamage = baseDamage;
    final damage = payload['_resolvedDamage'];
    if (damage is Damage) {
      action.resolutionState.pendingDamage = damage;
      action.stage = PendingActionStage.damagePrepared;
    }
  }

  void applyDiceResultMutation(PendingAction action, int result) {
    final request = action.resolutionState.diceRequest;
    final roll = action.resolutionState.diceRoll;
    if (request == null || roll == null) {
      throw StateError(
        'setDiceResult can only target an action with a resolved dice roll',
      );
    }
    if (result < 1 || result > request.sides) {
      throw StateError('setDiceResult must be between 1 and ${request.sides}');
    }
    final updatedRequest = request.copyWith(forcedResult: result);
    final history = List<int>.from(roll.history);
    if (history.isEmpty) history.add(roll.rawResult);
    if (history.last != result) history.add(result);
    final updatedRoll = roll.copyWith(
      request: updatedRequest,
      finalResult: result,
      damageMultiplier: result.toDouble(),
      wasForced: true,
      history: history,
    );
    action.payload['_resolvedDiceRequest'] = updatedRequest;
    action.payload['_resolvedDiceRoll'] = updatedRoll;
    action.resolutionState
      ..diceRequest = updatedRequest
      ..diceRoll = updatedRoll
      ..damageMultiplier = updatedRoll.damageMultiplier;
    if (action.actionType == ActionType.attackCard &&
        action.payload['_resolvedBaseDamage'] is int) {
      final baseDamage = action.payload['_resolvedBaseDamage'] as int;
      action.payload['_resolvedDamage'] = Damage(
        (baseDamage * updatedRoll.damageMultiplier).round(),
        DamageType.physical,
        DamageSource.action,
        updatedRoll.finalResult,
      );
    }
    syncResolutionState(action);
    _refreshResponseDecision(action);
  }

  Map<String, dynamic> buildResponsePayload(
    PendingAction action, {
    required bool forceOpen,
  }) {
    final payload = <String, dynamic>{
      'actionId': action.actionId,
      'actionType': action.actionType.name,
      'stage': action.stage.name,
      'forceOpened': forceOpen,
    };
    for (final field in ['traitId', 'skillId', 'trigger']) {
      final value = action.payload[field];
      if (value is String && value.isNotEmpty) payload[field] = value;
    }
    final state = action.resolutionState;
    if (state.targetCharacterId != null) {
      payload['targetId'] = state.targetCharacterId;
    }
    if (state.diceRequest != null) {
      final request = state.diceRequest!;
      payload['diceRequest'] = {
        'requestId': request.requestId,
        'sides': request.sides,
        if (request.forcedResult != null) 'forcedResult': request.forcedResult,
        'reason': request.reason.name,
        if (request.relatedActionId != null)
          'relatedActionId': request.relatedActionId,
      };
    }
    if (state.diceRoll != null) {
      final roll = state.diceRoll!;
      payload['diceRoll'] = {
        'rawResult': roll.rawResult,
        'finalResult': roll.finalResult,
        'damageMultiplier': roll.damageMultiplier,
        'wasForced': roll.wasForced,
        'wasRerolled': roll.wasRerolled,
        'history': roll.history,
      };
    }
    if (state.baseDamage != null) payload['baseDamage'] = state.baseDamage;
    if (state.pendingDamage != null) {
      final damage = state.pendingDamage!;
      payload['pendingDamage'] = {
        'amount': damage.amount,
        'type': damage.type.name,
        'source': damage.source.name,
        if (damage.diceResult != null) 'diceResult': damage.diceResult,
      };
    }
    return payload;
  }

  StackMutation _mutationFromMap(
    Map<String, dynamic> raw,
    String? defaultTargetActionId,
  ) {
    final typeName = raw['responseEffect'] ?? raw['effect'];
    if (typeName is! String || typeName.isEmpty) {
      throw StateError('Response mutation requires a string responseEffect');
    }
    final type = StackMutationType.values
        .where((candidate) => candidate.name == typeName)
        .firstOrNull;
    if (type == null) throw StateError('Unknown responseEffect: $typeName');
    final patch = raw['payloadPatch'];
    if (patch != null && patch is! Map) {
      throw StateError('payloadPatch must be a JSON object');
    }
    return StackMutation(
      type: type,
      targetActionId:
          _optionalString(raw, 'responseTargetActionId') ??
          _optionalString(raw, 'targetActionId') ??
          defaultTargetActionId,
      payloadField: _optionalString(raw, 'payloadField'),
      value: raw.containsKey('value') ? raw['value'] : raw['payloadValue'],
      newTargetId: _optionalString(raw, 'newTargetId'),
      payloadPatch: patch == null
          ? const {}
          : Map<String, dynamic>.from(patch as Map),
    );
  }

  void _applyMutation(StackMutation mutation) {
    final id = mutation.targetActionId;
    if (id == null) {
      throw StateError(
        'Response action must specify a target action to modify',
      );
    }
    final index = _state.pendingStack.indexWhere(
      (action) => action.actionId == id,
    );
    if (index < 0) {
      throw StateError('Target action $id not found in pending stack');
    }
    final target = _state.pendingStack[index];
    switch (mutation.type) {
      case StackMutationType.cancelAction:
        target.isCancelled = true;
        target.stage = PendingActionStage.cancelled;
        _state.pendingStack.removeAt(index);
      case StackMutationType.replaceTarget:
        final value = mutation.newTargetId;
        if (value == null || value.isEmpty) {
          throw StateError(
            'replaceTarget mutation requires a non-empty newTargetId',
          );
        }
        target.payload['targetId'] = value;
        target.resolutionState.targetCharacterId = value;
      case StackMutationType.patchPayload:
        if (mutation.payloadPatch.isEmpty) {
          throw StateError(
            'patchPayload mutation requires a non-empty payloadPatch',
          );
        }
        target.payload.addAll(mutation.payloadPatch);
        final value = mutation.payloadPatch['targetId'];
        if (value is String && value.isNotEmpty) {
          target.resolutionState.targetCharacterId = value;
        }
      case StackMutationType.setPayloadField:
        final field = mutation.payloadField;
        if (field == null || field.isEmpty) {
          throw StateError(
            'setPayloadField mutation requires a non-empty payloadField',
          );
        }
        target.payload[field] = mutation.value;
        if (field == 'targetId' &&
            mutation.value is String &&
            (mutation.value as String).isNotEmpty) {
          target.resolutionState.targetCharacterId = mutation.value as String;
        }
      case StackMutationType.removePayloadField:
        final field = mutation.payloadField;
        if (field == null || field.isEmpty) {
          throw StateError(
            'removePayloadField mutation requires a non-empty payloadField',
          );
        }
        target.payload.remove(field);
        if (field == 'targetId') {
          target.resolutionState.targetCharacterId = null;
        }
      case StackMutationType.setDiceResult:
        if (mutation.value is! int) {
          throw StateError('setDiceResult mutation requires an integer value');
        }
        applyDiceResultMutation(target, mutation.value as int);
    }
  }

  PendingAction _getAction(String id) {
    final action = _state.pendingStack
        .where((entry) => entry.actionId == id)
        .firstOrNull;
    if (action == null) {
      throw StateError('Target action $id not found in pending stack');
    }
    return action;
  }

  String? _retargetReason(PendingAction action, String id) {
    final target = _state.characterById[id];
    if (target == null) return 'Target character $id not found';
    if (!target.isAlive) return 'Target character $id is not alive';
    if (action.actionType == ActionType.attack && action.actorCharacterId == id) {
      return 'Character cannot target itself with a normal attack';
    }
    return null;
  }

  String? _optionalString(Map<String, dynamic> payload, String field) {
    final value = payload[field];
    if (value == null) return null;
    if (value is! String) throw StateError('$field must be a string');
    return value;
  }

  void _refreshResponseDecision(PendingAction action) {
    final decision = _state.decision;
    if (decision == null || decision.payload['actionId'] != action.actionId) {
      return;
    }
    _state.decision = DecisionContext(
      decisionId: decision.decisionId,
      type: decision.type,
      allowedPlayerIds: List<String>.from(decision.allowedPlayerIds),
      payload: buildResponsePayload(
        action,
        forceOpen: decision.payload['forceOpened'] == true,
      ),
    );
  }
}
