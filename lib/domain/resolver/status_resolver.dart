import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/status.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';

/// Owns status application, layer duration, direct state changes, and removal.
class StatusResolver {
  StatusResolver(this._context);

  final GameContext _context;

  Future<Status> apply(
    Character owner,
    Status incoming, {
    int stacks = 1,
    int intensity = 1,
    int extraPlayerTurns = 0,
  }) async {
    if (stacks <= 0) throw ArgumentError.value(stacks, 'stacks');
    if (intensity < 0) throw ArgumentError.value(intensity, 'intensity');
    if (extraPlayerTurns < 0) {
      throw ArgumentError.value(extraPlayerTurns, 'extraPlayerTurns');
    }

    final existing = _find(owner, incoming.id);
    final status = existing ?? incoming;
    final isNew = existing == null;
    if (isNew) {
      await status.ownerTransfer(_context, owner);
      owner.state.add(status);
    }

    if (isNew) {
      status
        ..setStacks(stacks)
        ..initializeStackFractions(
          _context.getAllPlayers().length + extraPlayerTurns,
        );
    } else {
      status.setStacks(status.stacks + stacks);
      if (extraPlayerTurns > 0) {
        status.setStackFractions(
          status.stackFractions + extraPlayerTurns,
        );
      }
    }
    status.setIntensity(_mergedIntensity(status, intensity, isNew));

    if (isNew) {
      await status.onAttached(_context);
    } else {
      await status.onChanged(_context);
    }
    _context.eventBus.emit(StatusAppliedEvent(_context, owner, status));
    return status;
  }

  Future<void> setIntensity(Character owner, String statusId, int value) async {
    final status = _require(owner, statusId)..setIntensity(value);
    await status.onChanged(_context);
  }

  Future<void> changeIntensity(
    Character owner,
    String statusId,
    int delta,
  ) => setIntensity(
    owner,
    statusId,
    _require(owner, statusId).intensity + delta,
  );

  Future<void> setStacks(
    Character owner,
    String statusId,
    int value, {
    int extraPlayerTurns = 0,
  }) async {
    if (value < 0) throw ArgumentError.value(value, 'value');
    if (extraPlayerTurns < 0) {
      throw ArgumentError.value(extraPlayerTurns, 'extraPlayerTurns');
    }
    final status = _require(owner, statusId);
    status.setStacks(value);
    if (extraPlayerTurns > 0) {
      status.setStackFractions(status.stackFractions + extraPlayerTurns);
    }
    await _afterStackChange(owner, status);
  }

  Future<void> changeStacks(
    Character owner,
    String statusId,
    int delta, {
    int extraPlayerTurns = 0,
  }) => setStacks(
    owner,
    statusId,
    _require(owner, statusId).stacks + delta,
    extraPlayerTurns: extraPlayerTurns,
  );

  /// Call exactly once after each normal player turn, never for extra turns.
  Future<void> advanceBasePlayerTurn() async {
    _context.state.basePlayerTurnIndex++;
    for (final owner in _context.getAllPlayers().expand(
      (player) => player.characters,
    )) {
      for (final status in List<Status>.of(owner.state)) {
        final remaining = status.stackFractions - 1;
        status.setStackFractions(remaining);
        if (status.stackFractions > 0) continue;
        status.setStacks(status.stacks - 1);
        _context.eventBus.emit(StatusDecayedEvent(_context, owner, status));
        await _afterStackChange(owner, status);
        if (owner.state.contains(status)) {
          status.setStackFractions(status.initialStackFractions);
        }
      }
    }
  }

  Future<void> remove(Character owner, String statusId) async {
    final status = _require(owner, statusId);
    owner.state.remove(status);
    await status.onRemoved(_context);
    _context.eventBus.emit(StatusDroppedEvent(_context, owner, status));
  }

  Future<void> _afterStackChange(Character owner, Status status) async {
    if (status.stacks == 0) {
      await remove(owner, status.id);
      return;
    }
    await status.onChanged(_context);
  }

  int _mergedIntensity(Status status, int incoming, bool isNew) {
    if (isNew) return incoming;
    return switch (status.stacking) {
      StatusStacking.max =>
        status.intensity > incoming ? status.intensity : incoming,
      StatusStacking.add => status.intensity + incoming,
    };
  }

  Status? _find(Character owner, String statusId) {
    for (final status in owner.state) {
      if (status.id == statusId) return status;
    }
    return null;
  }

  Status _require(Character owner, String statusId) =>
      _find(owner, statusId) ??
      (throw StateError('Status $statusId is not attached to ${owner.id}'));
}
