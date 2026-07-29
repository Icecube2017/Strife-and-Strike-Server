import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';

/// Resolves a dice request and emits its lifecycle events.
class DiceResolver {
  DiceResolver(this._context);

  final GameContext _context;

  Future<DiceRoll> resolve(Character actor, DiceRequest request) async {
    final beforeEvent = BeforeDiceEvent(_context, request);
    _context.eventBus.emit(beforeEvent);

    final resolvedRequest = beforeEvent.request;
    if (resolvedRequest.sides <= 0) {
      throw StateError('Dice sides must be greater than zero');
    }

    final rawResult = await actor.rollDice(_context, resolvedRequest.sides);
    final forcedResult = _readForcedResult(resolvedRequest);
    final finalResult = forcedResult ?? rawResult;
    final initialRoll = DiceRoll(
      request: resolvedRequest,
      rawResult: rawResult,
      finalResult: finalResult,
      damageMultiplier: finalResult.toDouble(),
      wasForced: forcedResult != null,
      history: [
        rawResult,
        if (forcedResult != null && forcedResult != rawResult) finalResult,
      ],
      payload: Map<String, dynamic>.from(resolvedRequest.payload),
    );

    final afterEvent = AfterDiceEvent(_context, resolvedRequest, initialRoll);
    _context.eventBus.emit(afterEvent);
    var resolvedRoll = afterEvent.roll;
    if (!identical(resolvedRoll.request, afterEvent.request)) {
      resolvedRoll = resolvedRoll.copyWith(request: afterEvent.request);
    }

    _context.eventBus.emit(
      DiceResolvedEvent(_context, afterEvent.request, resolvedRoll),
    );
    return resolvedRoll;
  }

  int? _readForcedResult(DiceRequest request) {
    final result = request.forcedResult;
    if (result == null) return null;
    if (result < 1 || result > request.sides) {
      throw StateError(
        'forcedResult must be an integer between 1 and ${request.sides}',
      );
    }
    return result;
  }
}
