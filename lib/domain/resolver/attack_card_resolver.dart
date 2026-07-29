import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/propcard.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/resolver/dice_resolver.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';

/// Resolves attack-card declarations, card effects, dice, and damage.
class AttackCardResolver {
  AttackCardResolver(this._context, [DiceResolver? diceResolver])
    : _diceResolver = diceResolver ?? DiceResolver(_context);

  final GameContext _context;
  final DiceResolver _diceResolver;

  Future<DiceRoll> resolveDicePhase(
    Character actor,
    PendingAction action,
  ) async {
    final request =
        action.resolutionState.diceRequest ?? _createDiceRequest(actor, action);
    action.resolutionState.diceRequest = request;
    action.payload['_resolvedDiceRequest'] = request;

    final roll = await _diceResolver.resolve(actor, request);
    action.payload['_resolvedDiceRequest'] = roll.request;
    action.payload['_resolvedDiceRoll'] = roll;
    return roll;
  }

  /// Executes already-confirmed attack cards and applies damage using the revealed die.
  Future<void> resolveAttackCard(
    Character actor,
    Map<String, dynamic> payload,
  ) async {
    final target = _resolveTarget(payload);
    final cards = _resolveCards(actor, payload);
    await _playCards(actor, target, cards, payload);

    final roll = payload['_resolvedDiceRoll'];
    if (roll is! DiceRoll) {
      final request = _createStandaloneDiceRequest(actor, target, payload);
      final resolvedRoll = await _diceResolver.resolve(actor, request);
      payload['_resolvedDiceRequest'] = resolvedRoll.request;
      payload['_resolvedDiceRoll'] = resolvedRoll;
    }

    final finalRoll = payload['_resolvedDiceRoll'] as DiceRoll;
    final baseDamage = _calculateBaseDamage(actor, target.character);
    final damage = Damage(
      (baseDamage * finalRoll.damageMultiplier).round(),
      DamageType.physical,
      DamageSource.action,
      finalRoll.finalResult,
    );
    payload
      ..['_resolvedTargetId'] = target.character.id
      ..['_resolvedBaseDamage'] = baseDamage
      ..['_resolvedDamage'] = damage;

    await _applyDamage(actor, target, damage);
  }

  /// Executes a non-damaging card action with the same card-selection protocol.
  Future<void> resolveLimitedCard(
    Character actor,
    Map<String, dynamic> payload,
  ) async {
    final target = _resolveTarget(payload);
    final cards = _resolveCards(actor, payload);
    await _playCards(actor, target, cards, payload);
  }

  Future<void> _playCards(
    Character actor,
    CharacterTarget target,
    List<PropCard> cards,
    Map<String, dynamic> payload,
  ) async {
    final cardIds = cards.map((card) => card.id).toList(growable: false);
    for (final card in cards) {
      await card.playCard(
        _context,
        actor,
        target: target,
        params: Map<String, dynamic>.from(payload)
          ..['isReinforced'] = card.isReinforced
          ..['isDisabled'] = card.isDisabled
          ..['resolvedCardId'] = card.id
          ..['resolvedCardIds'] = cardIds,
      );
    }
    _context.eventBus.emit(
      CardPlayedEvent(
        _context,
        CharacterTarget(actor),
        target,
        cards,
        cards.length,
      ),
    );
  }

  DiceRequest _createDiceRequest(Character actor, PendingAction action) =>
      _createDiceRequestForTarget(
        actor,
        _resolveTarget(action.payload),
        action.payload,
        requestId: '${action.actionId}_damage_dice',
        relatedActionId: action.actionId,
      );

  DiceRequest _createStandaloneDiceRequest(
    Character actor,
    CharacterTarget target,
    Map<String, dynamic> payload,
  ) {
    final actionId = _readPendingActionId(payload);
    return _createDiceRequestForTarget(
      actor,
      target,
      payload,
      requestId: actionId == null
          ? 'dice_${actor.id}_${DateTime.now().microsecondsSinceEpoch}'
          : '${actionId}_damage_dice',
      relatedActionId: actionId,
    );
  }

  DiceRequest _createDiceRequestForTarget(
    Character actor,
    CharacterTarget target,
    Map<String, dynamic> payload, {
    required String requestId,
    required String? relatedActionId,
  }) => DiceRequest(
    requestId: requestId,
    source: CharacterTarget(actor),
    target: target,
    sides: _readDiceSides(payload),
    forcedResult: _readForcedResult(payload),
    reason: DiceRollReason.attackDamage,
    relatedActionId: relatedActionId,
    payload: {
      'actionType': ActionType.attackCard.name,
      'characterId': actor.id,
      'targetId': target.character.id,
    },
  );

  Future<void> _applyDamage(
    Character actor,
    CharacterTarget target,
    Damage damage,
  ) async {
    final beforeEvent = BeforeDamageEvent(
      _context,
      CharacterTarget(actor),
      target,
      damage,
    );
    _context.eventBus.emit(beforeEvent);
    _context.eventBus
      ..emit(
        DamageDealtEvent(
          _context,
          beforeEvent.source,
          beforeEvent.target,
          beforeEvent.damage,
        ),
      )
      ..emit(
        AfterDamageEvent(
          _context,
          beforeEvent.source,
          beforeEvent.target,
          beforeEvent.damage,
        ),
      );
  }

  List<PropCard> _resolveCards(
    Character actor,
    Map<String, dynamic> payload,
  ) {
    final rawSelections = payload['cardSelections'];
    if (rawSelections is! List || rawSelections.isEmpty) {
      throw StateError('cardSelections must be a non-empty list');
    }
    final reservedIndices = <int>{};
    final cards = <PropCard>[];
    for (final rawSelection in rawSelections) {
      if (rawSelection is! Map) {
        throw StateError('Each card selection must be an object');
      }
      final selection = Map<String, dynamic>.from(rawSelection);
      final cardId = selection['cardId'];
      if (cardId is! String || cardId.isEmpty) {
        throw StateError('cardId must be a non-empty string');
      }
      final handIndex = selection['handIndex'];
      final card = _resolveCard(actor, cardId, handIndex, reservedIndices);
      if (card.isDisabled) {
        throw StateError('Card ${card.id} is disabled and cannot be played');
      }
      cards.add(card);
    }
    return cards;
  }

  PropCard _resolveCard(
    Character actor,
    String cardId,
    dynamic rawHandIndex,
    Set<int> reservedIndices,
  ) {
    if (rawHandIndex != null && rawHandIndex is! int) {
      throw StateError('handIndex must be an integer');
    }
    if (rawHandIndex is int) {
      if (rawHandIndex < 0 || rawHandIndex >= actor.hand.length) {
        throw StateError('handIndex $rawHandIndex is out of range');
      }
      if (!reservedIndices.add(rawHandIndex)) {
        throw StateError('handIndex $rawHandIndex is selected more than once');
      }
      final card = actor.hand[rawHandIndex];
      if (card.id != cardId) {
        throw StateError(
          'Card at handIndex $rawHandIndex is ${card.id}, not $cardId',
        );
      }
      return card;
    }

    for (var index = 0; index < actor.hand.length; index++) {
      if (reservedIndices.contains(index)) {
        continue;
      }
      if (actor.hand[index].id == cardId) {
        reservedIndices.add(index);
        return actor.hand[index];
      }
    }
    throw StateError('Card $cardId not found in character hand');
  }

  CharacterTarget _resolveTarget(Map<String, dynamic> payload) {
    final id = payload['targetId'];
    if (id is! String || id.isEmpty) {
      throw StateError('targetId must be a non-empty string when provided');
    }
    final character = _context.getCharacterById(id);
    if (character == null) throw StateError('Target character $id not found');
    return CharacterTarget(character);
  }

  int _calculateBaseDamage(Character actor, Character target) =>
      actor.attack > target.defense
      ? actor.attack - target.defense
      : 5 + actor.attack ~/ 10;

  String? _readPendingActionId(Map<String, dynamic> payload) {
    final id = payload['_pendingActionId'];
    return id is String && id.isNotEmpty ? id : null;
  }

  int _readDiceSides(Map<String, dynamic> payload) {
    final value = payload['diceSides'];
    if (value == null) return 6;
    if (value is! int || value <= 0) {
      throw StateError('diceSides must be a positive integer');
    }
    return value;
  }

  int? _readForcedResult(Map<String, dynamic> payload) {
    final value = payload['forcedResult'];
    if (value == null) return null;
    if (value is! int || value < 1) {
      throw StateError('forcedResult must be a positive integer');
    }
    return value;
  }
}
