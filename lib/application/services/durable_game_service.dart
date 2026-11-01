part of 'kernel_game_service.dart';

extension DurableKernelGames on KernelGameService {
  /// Terminal archive metadata is sufficient for releasing its room. Reading
  /// this does not resume play or waive deterministic recovery validation.
  Future<bool> hasFinishedArchive(String id) async {
    final live = _games[id];
    if (live != null) return live.state.finished;
    final saved = await checkpointRepo?.findById(id);
    return _isFinishedArchive(id, saved);
  }

  /// Index terminal metadata without running historical code. This never
  /// installs a kernel or provides unverified game state to a client.
  bool _isFinishedArchive(String id, Map<String, dynamic>? saved) {
    if (saved == null ||
        saved['schemaVersion'] != 1 ||
        saved['gameId'] != id ||
        saved['finished'] != true ||
        saved['version'] is! int) {
      return false;
    }
    final kernel = saved['kernel'];
    if (kernel is! Map || kernel['version'] != saved['version']) return false;
    try {
      final raw = kernel['verification'];
      final verification = raw is String ? jsonDecode(raw) : raw;
      if (verification is! Map || verification['public'] is! Map) return false;
      final public = verification['public'] as Map;
      return public['gameId'] == id &&
          public['version'] == saved['version'] &&
          public['phase'] == 'finished' &&
          public['outcome'] is Map;
    } on FormatException {
      return false;
    }
  }

  Future<void> requireFinishedGame(String id) async {
    if (await hasFinishedArchive(id)) return;
    await ensureGameLoaded(id);
    if (!_get(id).state.finished) throw StateError('gameStillRunning');
  }

  Map<int, String> _readDocumentTimes(Map<String, Object?> document) => {
    for (final entry in (document['eventTimes']! as Map).entries)
      int.parse(entry.key as String): entry.value as String,
  };
  void _scheduleArchive(String id) {
    if (checkpointRepo == null || _disposed) return;
    _archiveTimers.remove(id)?.cancel();
    _archiveTimers[id] = _schedule(finishedGameRetention, () {
      unawaited(
        _serialized(id, () async {
          if (_games[id]?.state.finished ?? false) {
            removeGame(id);
            _archivedGameIds.add(id);
          }
        }).catchError(
          (Object error, StackTrace stack) =>
              onPersistenceError?.call(error, stack),
        ),
      );
    });
  }

  /// Finished games remain in storage and are rehydrated on demand after eviction.
  Future<void> ensureGameLoaded(String id) async {
    if (checkpointRepo == null || _games.containsKey(id)) return;
    await _serialized(id, () async {
      if (_games.containsKey(id)) return;
      final saved = await checkpointRepo!.findById(id);
      if (saved == null) {
        _failedRestores.remove(id);
        _archivedGameIds.remove(id);
        throw StateError('Unknown game: $id');
      }
      try {
        final restored = _verifyDocument(saved);
        _installDocument(restored);
      } catch (error, stack) {
        _failedRestores.add(id);
        onRecoveryError?.call(id, error, stack);
        throw StateError('gameRecoveryFailed');
      }
      await _expireDurably(id);
    });
  }

  String? _hashFor(String id) =>
      _gameContent[id] == null ? null : clientContentHash(_gameContent[id]!);

  Future<T> _serialized<T>(String id, Future<T> Function() operation) {
    final previous = _writeQueues[id] ?? Future<void>.value();
    final next = previous.then((_) {
      if (_disposed) {
        throw StateError('Game service disposed');
      }
      return operation();
    });
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _writeQueues[id] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_writeQueues[id], tail)) _writeQueues.remove(id);
      }),
    );
    return next;
  }

  Future<void> _persist(
    String id,
    Map<String, Object?> document, {
    required int? expectedVersion,
  }) async {
    try {
      await checkpointRepo!.save(
        id,
        document,
        expectedVersion: expectedVersion,
      );
    } catch (error, stack) {
      // A lost DB acknowledgement does not mean the write was rolled back.
      // Read back the exact save before deciding whether to commit the candidate.
      try {
        final stored = await checkpointRepo!.findById(id);
        if (stored != null &&
            executableContentHash(jsonEncode(stored)) ==
                executableContentHash(jsonEncode(document))) {
          return;
        }
        if (stored?['version'] != expectedVersion) _uncertainWrites.add(id);
      } catch (_) {
        _uncertainWrites.add(id);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _refreshUncertain(String id) async {
    if (!_uncertainWrites.contains(id)) return;
    final saved = await checkpointRepo!.findById(id);
    if (saved == null) {
      _uncertainWrites.remove(id);
      return;
    }
    final item = _verifyDocument(saved);
    final (game, receipts, deadline, source, times) = item;
    final current = _games[id];
    if (current == null) {
      _installDocument(item);
    } else {
      if (game.state.version < current.state.version) {
        throw StateError('Storage version is older than live game');
      }
      if (game.state.version != current.state.version) {
        _games[id] = game;
        _eventTimes[id] = times;
        _receipts[id] = receipts;
        _gameContent[id] = source;
        _installDeadline(id, deadline);
        _publish(id, game);
      }
    }
    _uncertainWrites.remove(id);
  }

  Map<String, Object?> _saveDocument(
    GameKernel game,
    Map<String, _Receipt> receipts,
    _ResponseDeadline? deadline,
    String source,
  ) => {
    'schemaVersion': 1,
    'gameId': game.state.gameId,
    'version': game.state.version,
    'finished': game.state.finished,
    'contentSource': source,
    'contentHash': executableContentHash(source),
    'kernel': game.recoveryCheckpoint(),
    'eventTimes': {
      for (final entry in _timesFor(game).entries) '${entry.key}': entry.value,
    },
    'receipts': {
      for (final entry in receipts.entries)
        entry.key: {
          'signature': entry.value.signature,
          'version': entry.value.version,
        },
    },
    'deadline': deadline == null
        ? null
        : {
            'windowId': deadline.windowId,
            'at': deadline.at.toUtc().toIso8601String(),
          },
  };

  _ResponseDeadline? _nextDeadline(GameKernel game) {
    final pending = game.state.pending;
    if (pending == null || pending.responseExpired || game.state.finished) {
      return null;
    }
    final old = _deadlines[game.state.gameId];
    if (old?.windowId == pending.windowId) {
      return old;
    }
    return _ResponseDeadline(
      pending.windowId,
      _now().toUtc().add(Duration(seconds: game.rules.responseTimeoutSeconds)),
    );
  }

  void _installDeadline(String id, _ResponseDeadline? deadline) {
    _deadlines.remove(id)?.timer?.cancel();
    if (deadline != null) {
      _deadlines[id] = deadline;
      _armDeadline(id, deadline);
    }
  }

  Future<Map<String, Object?>> startGamePersisted(GameSetup setup) {
    if (checkpointRepo == null) {
      return Future.value(startGame(setup));
    }
    return _serialized(setup.gameId, () async {
      if (_failedRestores.contains(setup.gameId)) {
        throw StateError('gameRecoveryFailed');
      }
      if (_archivedGameIds.contains(setup.gameId)) {
        throw StateError('Game already exists');
      }
      final recovering = _uncertainWrites.contains(setup.gameId);
      await _refreshUncertain(setup.gameId);
      if (_games.containsKey(setup.gameId)) {
        if (recovering) {
          final actual = KernelRecoveryCodec.setup(_get(setup.gameId).setup)
            ..remove('seed');
          final requested = KernelRecoveryCodec.setup(setup)..remove('seed');
          if (executableContentHash(jsonEncode(actual)) ==
              executableContentHash(jsonEncode(requested))) {
            return _publicView(setup.gameId, _get(setup.gameId));
          }
        }
        throw StateError('Game already exists');
      }
      if (contentSource == null) {
        throw StateError('Durable games require executable content source');
      }
      final game = GameKernel(catalog, setup)..start();
      final deadline = _nextDeadline(game);
      final document = _saveDocument(game, {}, deadline, contentSource!);
      await _persist(
        setup.gameId,
        document,
        expectedVersion: null,
      );
      _eventTimes[setup.gameId] = _readDocumentTimes(document);
      _games[setup.gameId] = game;
      _gameContent[setup.gameId] = contentSource!;
      _receipts[setup.gameId] = {};
      _updates[setup.gameId] = StreamController<_GameUpdate>.broadcast();
      _installDeadline(setup.gameId, deadline);
      return _publicView(setup.gameId, game);
    });
  }

  Future<int> submitPersisted(
    String gameId,
    KernelCommand command, {
    required String commandId,
    required int expectedVersion,
  }) {
    if (checkpointRepo == null) {
      return Future.value(
        submit(
          gameId,
          command,
          commandId: commandId,
          expectedVersion: expectedVersion,
        ),
      );
    }
    return _serialized(gameId, () async {
      await _expireDurably(gameId);
      final current = _get(gameId);
      final key = jsonEncode([command.playerId, commandId]);
      final signature = jsonEncode([expectedVersion, _signature(command)]);
      final cached = _receipts[gameId]![key];
      if (cached != null) {
        if (cached.signature != signature) {
          throw StateError('Command ID reused with different content');
        }
        return cached.version;
      }
      // Work on an isolated reconstructed kernel. Failed writes expose no fees,
      // choices, RNG advances or notifications, and can be safely retried.
      final next = GameKernel.restore(
        current.catalog,
        Map<String, dynamic>.from(current.recoveryCheckpoint()),
      )..submit(command, expectedVersion: expectedVersion);
      final receipts = {
        ..._receipts[gameId]!,
        key: _Receipt(signature, next.state.version),
      };
      final deadline = _nextDeadline(next);
      final document = _saveDocument(
        next,
        receipts,
        deadline,
        _gameContent[gameId]!,
      );
      await _persist(
        gameId,
        document,
        expectedVersion: current.state.version,
      );
      _eventTimes[gameId] = _readDocumentTimes(document);
      _games[gameId] = next;
      _receipts[gameId] = receipts;
      _installDeadline(gameId, deadline);
      _publish(gameId, next);
      return next.state.version;
    });
  }

  Future<void> _expireDurably(String id) async {
    await _refreshUncertain(id);
    final deadline = _deadlines[id];
    if (deadline == null || _now().toUtc().isBefore(deadline.at)) return;
    final current = _get(id);
    final next = GameKernel.restore(
      current.catalog,
      Map<String, dynamic>.from(current.recoveryCheckpoint()),
    );
    if (!next.expireResponse(deadline.windowId)) return;
    final nextDeadline = _nextDeadline(next);
    final document = _saveDocument(
      next,
      _receipts[id]!,
      nextDeadline,
      _gameContent[id]!,
    );
    await _persist(
      id,
      document,
      expectedVersion: current.state.version,
    );
    _eventTimes[id] = _readDocumentTimes(document);
    _games[id] = next;
    _installDeadline(id, nextDeadline);
    _publish(id, next);
  }

  Future<void> restoreGames() async {
    if (checkpointRepo == null) return;
    if (_games.isNotEmpty ||
        _failedRestores.isNotEmpty ||
        _archivedGameIds.isNotEmpty) {
      throw StateError('Restore requires an empty game service');
    }
    final saves = await checkpointRepo!.loadAll();
    // Only active games need executable state at startup. Completed archives
    // reserve their IDs and stay on disk until an explicit history query.
    final restored =
        <
          (
            GameKernel,
            Map<String, _Receipt>,
            _ResponseDeadline?,
            String,
            Map<int, String>,
          )
        >[];
    for (final saved in saves) {
      final id = saved['gameId'] as String;
      try {
        if (_isFinishedArchive(id, saved)) {
          _archivedGameIds.add(id);
          continue;
        }
        restored.add(_verifyDocument(saved));
      } catch (error, stack) {
        _failedRestores.add(id);
        onRecoveryError?.call(id, error, stack);
      }
    }
    for (final item in restored) {
      _installDocument(item);
    }
    for (final id in _games.keys.toList()) {
      try {
        await _serialized(id, () => _expireDurably(id));
      } catch (error, stack) {
        // The original deadline remains armed and retries its durable timeout.
        onPersistenceError?.call(error, stack);
      }
    }
  }

  (
    GameKernel,
    Map<String, _Receipt>,
    _ResponseDeadline?,
    String,
    Map<int, String>,
  )
  _verifyDocument(Map<String, dynamic> saved) {
    if (saved['schemaVersion'] != 1) {
      throw StateError('Unsupported server recovery format');
    }
    final source = saved['contentSource'] as String;
    if (executableContentHash(source) != saved['contentHash']) {
      throw StateError('Saved content hash mismatch');
    }
    final game = GameKernel.restore(
      ExecutableContent.decode(source).catalog,
      saved['kernel'] as Map<String, dynamic>,
    );
    if (game.state.gameId != saved['gameId'] ||
        game.state.version != saved['version'] ||
        game.state.finished != saved['finished']) {
      throw StateError('Saved game metadata mismatch');
    }
    final receipts = <String, _Receipt>{
      for (final entry in (saved['receipts'] as Map<String, dynamic>).entries)
        entry.key: _Receipt(
          (entry.value as Map<String, dynamic>)['signature'] as String,
          (entry.value as Map<String, dynamic>)['version'] as int,
        ),
    };
    final raw = saved['deadline'] as Map<String, dynamic>?;
    final deadline = raw == null
        ? null
        : _ResponseDeadline(
            raw['windowId'] as String,
            DateTime.parse(raw['at'] as String).toUtc(),
          );
    if (deadline?.windowId !=
        (game.state.finished || (game.state.pending?.responseExpired ?? false)
            ? null
            : game.state.pending?.windowId)) {
      throw StateError('Saved response deadline mismatch');
    }
    final times = <int, String>{};
    for (final entry in (saved['eventTimes'] as Map? ?? const {}).entries) {
      final sequence = int.tryParse('${entry.key}');
      final at = entry.value is String
          ? DateTime.tryParse(entry.value as String)
          : null;
      if (sequence != null &&
          sequence > 0 &&
          sequence <= game.state.events.length &&
          at != null) {
        times[sequence] = at.toUtc().toIso8601String();
      }
    }
    return (game, receipts, deadline, source, times);
  }

  void _installDocument(
    (
      GameKernel,
      Map<String, _Receipt>,
      _ResponseDeadline?,
      String,
      Map<int, String>,
    )
    item,
  ) {
    final (game, receipts, deadline, source, times) = item;
    final id = game.state.gameId;
    _failedRestores.remove(id);
    _archivedGameIds.remove(id);
    _games[id] = game;
    _eventTimes[id] = times;
    _receipts[id] = receipts;
    _gameContent[id] = source;
    _updates[id] = StreamController<_GameUpdate>.broadcast();
    _installDeadline(id, deadline);
    if (game.state.finished) {
      unawaited(_updates[id]!.close());
      _scheduleArchive(id);
    }
  }

  /// Abort is a service lifecycle operation, never a winning kernel command.
  Future<void> abortGamePersisted(
    String id,
    String endedBy, {
    bool allowNonParticipant = false,
    Future<void> Function(int version)? erase,
  }) => _serialized(id, () async {
    await _refreshUncertain(id);
    final game = _get(id);
    if (game.state.finished) throw StateError('Game already finished');
    if (!allowNonParticipant &&
        !game.state.players.any((p) => p.id == endedBy)) {
      throw StateError('Player is not in game');
    }
    _aborting.add(id);
    try {
      if (erase != null) {
        await erase(game.state.version);
      } else {
        await checkpointRepo?.delete(id);
      }
      _publishTermination(id, game, reason: 'aborted', endedBy: endedBy);
      _uncertainWrites.remove(id);
      removeGame(id);
    } finally {
      _aborting.remove(id);
    }
  });

  /// Expiration can also remove an unreadable unfinished checkpoint; it does
  /// not need to replay a match that all players have abandoned. Finished
  /// archives are preserved even when their room code is released.
  Future<void> expireRoomGamePersisted(
    String id, {
    required Future<void> Function(int? version, {required bool finished})
    erase,
  }) => _serialized(id, () async {
    final saved = await checkpointRepo?.findById(id);
    final game = _games[id];
    final version = checkpointRepo == null
        ? game?.state.version
        : saved?['version'] as int?;
    final finished = checkpointRepo == null
        ? game?.state.finished ?? false
        : saved?['finished'] == true;
    if (checkpointRepo != null && game != null && saved == null) {
      throw StateError('Live game has no persisted checkpoint');
    }
    _aborting.add(id);
    try {
      await erase(version, finished: finished);
      if (!finished) {
        if (game != null) _publishTermination(id, game, reason: 'roomExpired');
        _failedRestores.remove(id);
        _uncertainWrites.remove(id);
        removeGame(id);
      }
    } finally {
      _aborting.remove(id);
    }
  });

  void _publishTermination(
    String id,
    GameKernel game, {
    required String reason,
    String? endedBy,
  }) {
    final version = game.state.version + 1;
    final terminal = {
      ..._publicView(id, game),
      'statistics': _statisticsWithTimes(id, game, endedAt: _now().toUtc()),
      'version': version,
      'phase': 'finished',
      'pending': null,
      'choice': null,
      'preparation': null,
      'responseWindow': null,
      'outcome': null,
      'serverTime': _now().toUtc().toIso8601String(),
      'termination': {
        'reason': reason,
        if (endedBy != null) 'endedBy': endedBy,
        'saved': false,
      },
    };
    _updates[id]?.add(
      _GameUpdate(terminal, {
        for (final player in game.state.players)
          player.id: {
            'playerId': player.id,
            'version': version,
            'choice': null,
            'preparation': null,
            'responseWindow': null,
            'pendingPreview': null,
            'preview': null,
          },
      }),
    );
  }

  Future<void> removeGamePersisted(String id) async {
    if (checkpointRepo == null) {
      removeGame(id);
      return;
    }
    await _serialized(id, () async {
      await checkpointRepo!.delete(id);
      removeGame(id);
    });
  }
}
