part of 'room_service.dart';

/// One authenticated SSE connection. Multiple room/game streams may coexist.
final class RoomConnection {
  RoomConnection._(this._release);
  final Future<void> Function() _release;
  Future<void>? _closed;
  Future<void> close() => _closed ??= _release();
}

final class _RoomExpiry {
  _RoomExpiry(this.at, {this.presenceSaved = true});
  final DateTime at;
  bool presenceSaved;
  Timer? timer;
}

extension RoomExpiration on RoomService {
  /// Configure the coordinated room/match deletion before arming any timers.
  Future<void> startExpiration(
    Future<void> Function(Room closedRoom) expireStorage,
  ) async {
    if (_disposed) throw StateError('Room service disposed');
    if (_expireStorage != null) return;
    _expireStorage = expireStorage;
    for (final id in _rooms.keys.toList()) {
      await _serialize(id, () async {
        final room = _rooms[id];
        if (room == null || (_connections[id]?.isNotEmpty ?? false)) return;
        // A previously connected room has lost its connections on restart.
        // Persisted offline timestamps keep their original absolute deadline.
        if (room.allDisconnectedAt == null) {
          room.allDisconnectedAt = _now().toUtc();
          _scheduleRoomExpiry(room, presenceSaved: false);
          await _checkRoomExpiry(id, _expirations[id]!);
        } else {
          _scheduleRoomExpiry(room);
          if (!_now().toUtc().isBefore(_expirations[id]!.at)) {
            await _checkRoomExpiry(id, _expirations[id]!);
          }
        }
      });
    }
  }

  Future<RoomConnection> connect(String key, String playerId) {
    final id = _get(key).id;
    return _serialize(id, () async {
      if (_disposed) throw StateError('Room service disposed');
      var current = _get(id);
      _requireMember(current, playerId);
      final expiry = _expirations[id];
      if (expiry != null && !_now().toUtc().isBefore(expiry.at)) {
        await _checkRoomExpiry(id, expiry);
        current = _get(id);
      }
      if (_connections[id]?.isEmpty ?? true) {
        final room = roomFromJson(roomToJson(current))
          ..allDisconnectedAt = null;
        await _repo.save(room);
        _rooms[id] = room;
        _expirations.remove(id)?.timer?.cancel();
      }
      final token = Object();
      (_connections[id] ??= {}).add(token);
      return RoomConnection._(() => _disconnect(id, token));
    });
  }

  /// Public spectators do not keep a room alive. An archived game can outlive it.
  Future<RoomConnection?> connectForGame(String gameId, String playerId) async {
    final room = _rooms.values
        .where((r) => 'game_${r.id}' == gameId)
        .firstOrNull;
    if (room == null || !room.players.any((p) => p.id == playerId)) return null;
    return connect(room.id, playerId);
  }

  Future<void> _disconnect(String id, Object token) async {
    if (_disposed) return;
    await _serialize(id, () async {
      if (_disposed) return;
      final tokens = _connections[id];
      if (tokens == null || !tokens.remove(token) || tokens.isNotEmpty) return;
      _connections.remove(id);
      final current = _rooms[id];
      if (current == null) return;
      final room = roomFromJson(roomToJson(current))
        ..allDisconnectedAt = _now().toUtc();
      _rooms[id] = room;
      _scheduleRoomExpiry(room, presenceSaved: false);
      final expiry = _expirations[id];
      if (expiry != null) {
        await _checkRoomExpiry(id, expiry);
      } else {
        // Presence may be recorded before startup enables expiration.
        try {
          await _repo.save(room);
        } catch (error, stack) {
          onExpirationError?.call(id, error, stack);
        }
      }
    });
  }

  void _scheduleRoomExpiry(Room room, {bool presenceSaved = true}) {
    if (_expireStorage == null || _disposed || room.allDisconnectedAt == null) {
      return;
    }
    _expirations.remove(room.id)?.timer?.cancel();
    final expiry = _RoomExpiry(
      room.allDisconnectedAt!.add(offlineRoomLifetime),
      presenceSaved: presenceSaved,
    );
    _expirations[room.id] = expiry;
    _armRoomExpiry(room.id, expiry);
  }

  void _armRoomExpiry(String id, _RoomExpiry expiry, {bool retry = false}) {
    if (_disposed || !identical(_expirations[id], expiry)) return;
    expiry.timer?.cancel();
    final remaining = expiry.at.difference(_now().toUtc());
    expiry.timer = _schedule(
      retry
          ? const Duration(seconds: 1)
          : remaining.isNegative
          ? Duration.zero
          : remaining,
      () {
        unawaited(_serialize(id, () => _checkRoomExpiry(id, expiry)));
      },
    );
  }

  Future<void> _checkRoomExpiry(String id, _RoomExpiry expiry) async {
    if (_disposed ||
        !identical(_expirations[id], expiry) ||
        (_connections[id]?.isNotEmpty ?? false)) {
      return;
    }
    final room = _rooms[id];
    if (room == null) return;
    try {
      if (!expiry.presenceSaved) {
        await _repo.save(room);
        expiry.presenceSaved = true;
      }
      if (_now().toUtc().isBefore(expiry.at)) {
        _armRoomExpiry(id, expiry);
        return;
      }
      final closed = roomFromJson(roomToJson(room))
        ..status = RoomStatus.closed
        ..version = room.version + 1;
      await _expireStorage!(closed);
      final updates = _updates.remove(id);
      updates?.add(_response(closed, closeReason: 'expired'));
      if (updates != null) unawaited(updates.close());
      _rooms.remove(id);
      if (room.roomCode != null) _codes.remove(room.roomCode);
      _forgetRoomPresence(id);
    } catch (error, stack) {
      onExpirationError?.call(id, error, stack);
      _armRoomExpiry(id, expiry, retry: true);
    }
  }

  void _forgetRoomPresence(String id) {
    _expirations.remove(id)?.timer?.cancel();
    _connections.remove(id);
  }
}
