import 'dart:async';
import 'dart:convert';

import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/application/content/client_content.dart';
import 'package:sns_server/application/dto/choice_presentation.dart';
import 'package:sns_server/application/logging/public_event_projection.dart';
import 'package:sns_server/application/services/pending_damage_preview.dart';
import 'package:sns_server/infrastructure/repo/game_checkpoint_repo.dart';

part 'durable_game_service.dart';

/// Application entry point for the definition-driven kernel. No database or
/// transport dependency; HTTP/CLI/tests all submit the same typed commands.
final class KernelGameService {
  KernelGameService(
    this.catalog, {
    this.contentSource,
    this.checkpointRepo,
    this.onPersistenceError,
    this.onRecoveryError,
    this.finishedGameRetention = const Duration(minutes: 10),
    DateTime Function()? now,
    Timer Function(Duration, void Function())? schedule,
  }) : _now = now ?? DateTime.now,
       _schedule = schedule ?? Timer.new;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _schedule;
  final Map<String, _ResponseDeadline> _deadlines = {};
  final ContentCatalog catalog;
  final String? contentSource;
  final GameCheckpointRepo? checkpointRepo;
  final Duration finishedGameRetention;
  final Map<String, Timer> _archiveTimers = {};
  final void Function(Object, StackTrace)? onPersistenceError;
  final void Function(String gameId, Object error, StackTrace stack)?
  onRecoveryError;
  final Set<String> _failedRestores = {};
  final Set<String> _archivedGameIds = {};
  final Map<String, String> _gameContent = {};
  final Map<String, Future<void>> _writeQueues = {};
  final Set<String> _uncertainWrites = {};
  final Set<String> _aborting = {};
  bool _disposed = false;
  late final String? contentHash = contentSource == null
      ? null
      : clientContentHash(contentSource!);
  final Map<String, GameKernel> _games = {};
  final Map<String, Map<int, String>> _eventTimes = {};
  Map<int, String> _timesFor(GameKernel game, {int? since}) {
    final id = game.state.gameId;
    final previous = _eventTimes[id] ?? const <int, String>{};
    final start = since ?? _games[id]?.state.events.length ?? 0;
    final at = _now().toUtc().toIso8601String();
    return {
      ...previous,
      for (final event in game.state.events.skip(start)) event.sequence: at,
    };
  }

  final Map<String, Map<String, _Receipt>> _receipts = {};
  final Map<String, StreamController<_GameUpdate>> _updates = {};
  final Map<String, ({int version, Map<String, PreviewResult> players})>
  _pendingPreviews = {};

  bool hasGame(String id) => _games.containsKey(id);

  /// Stored archives and failed saves reserve their game/room without a kernel.
  bool hasGameRecord(String id) =>
      hasGame(id) ||
      _failedRestores.contains(id) ||
      _archivedGameIds.contains(id);

  Map<String, Object?> startGame(GameSetup setup) {
    if (checkpointRepo != null) throw StateError('Use durable game start');
    if (_games.containsKey(setup.gameId)) {
      throw StateError('Game already exists');
    }
    final game = GameKernel(catalog, setup)..start();
    _eventTimes[setup.gameId] = _timesFor(game, since: 0);
    _games[setup.gameId] = game;
    if (contentSource != null) _gameContent[setup.gameId] = contentSource!;
    _receipts[setup.gameId] = {};
    _updates[setup.gameId] = StreamController<_GameUpdate>.broadcast();
    return _publicView(setup.gameId, game);
  }

  /// Synchronous transitions are serialized by Dart's isolate. Successful
  /// retries return the original version and never repeat payment or effects.
  int submit(
    String gameId,
    KernelCommand command, {
    required String commandId,
    required int expectedVersion,
  }) {
    if (checkpointRepo != null) {
      throw StateError('Use durable command submission');
    }
    if (_aborting.contains(gameId)) throw StateError('Game is being aborted');
    _expireDue(gameId);
    final game = _get(gameId);
    final key = jsonEncode([command.playerId, commandId]);
    final signature = jsonEncode([expectedVersion, _signature(command)]);
    final cached = _receipts[gameId]![key];
    if (cached != null) {
      if (cached.signature != signature) {
        throw StateError('Command ID reused with different content');
      }
      return cached.version;
    }
    final since = game.state.events.length;
    game.submit(command, expectedVersion: expectedVersion);
    _eventTimes[gameId] = _timesFor(game, since: since);
    _receipts[gameId]![key] = _Receipt(signature, game.state.version);
    _publish(gameId, game);
    return game.state.version;
  }

  Stream<Map<String, Object?>> subscribe(String gameId) {
    _get(gameId);
    return _updates[gameId]!.stream.map((update) => update.publicView);
  }

  /// Snapshots are captured at commit, not reconstructed when an async listener
  /// runs: public and private projections always describe the same version.
  Stream<Map<String, Object?>> subscribeForPlayer(
    String gameId,
    String playerId,
  ) {
    _get(gameId).privateView(playerId);
    return _updates[gameId]!.stream.map(
      (update) => {
        ...update.publicView,
        'private': update.privateViews[playerId],
      },
    );
  }

  /// Used to roll back a room start that failed to persist its lobby status.
  void removeGame(String gameId) {
    _archivedGameIds.remove(gameId);
    _deadlines.remove(gameId)?.timer?.cancel();
    _archiveTimers.remove(gameId)?.cancel();
    _games.remove(gameId);
    _eventTimes.remove(gameId);
    _pendingPreviews.remove(gameId);
    _gameContent.remove(gameId);
    _receipts.remove(gameId);
    final updates = _updates.remove(gameId);
    if (updates != null) unawaited(updates.close());
  }

  Map<String, Object?> getState(String gameId) {
    _expireDue(gameId);
    return _publicView(gameId, _get(gameId));
  }

  Map<String, Object?> getPrivateState(String gameId, String playerId) {
    _expireDue(gameId);
    final game = _get(gameId);
    return _withDeadline(gameId, _privateView(game, playerId));
  }

  Map<String, Object?> getPlayerState(String gameId, String playerId) {
    _expireDue(gameId);
    final game = _get(gameId);
    final private = _privateView(game, playerId);
    return {
      ..._publicView(gameId, game),
      'private': _withDeadline(gameId, private),
    };
  }

  Map<String, Object?> _privateView(GameKernel game, String playerId) {
    final hash = _hashFor(game.state.gameId);
    return {
      ...projectChoicePresentation(
        machineStateView(game.privateView(playerId)),
        game.catalog,
      ),
      if (hash != null) ...{
        'pendingPreview':
            game.state.finished ||
                game.state.pending == null ||
                game.state.choice != null ||
                game.state.preparation != null
            ? null
            : _pendingPreview(game, playerId, hash),
      },
    };
  }

  Map<String, Object?>? _pendingPreview(
    GameKernel game,
    String playerId,
    String hash,
  ) {
    final id = game.state.gameId;
    var cached = _pendingPreviews[id];
    if (cached?.version != game.state.version) {
      cached = (
        version: game.state.version,
        players: <String, PreviewResult>{},
      );
      _pendingPreviews[id] = cached;
    }
    try {
      final result = cached!.players
          .putIfAbsent('*', () => PendingDamagePreview.run(game))
          .toJson();
      return PendingDamagePreview.presentation(game, result);
    } catch (_) {
      // Ad-hoc or legacy kernels may not be replayable; keep the viewer-specific safe fallback.
    }
    final result = cached!.players.putIfAbsent(playerId, () {
      try {
        return PreviewRunner(game.catalog, contentHash: hash).run(
          PreviewState({
            ...game.previewSnapshot(playerId),
            'contentHash': hash,
          }),
          PreviewRequest(
            playerId: playerId,
            version: game.state.version,
            mode: PreviewMode.pendingAction,
            windowId: game.state.pending!.windowId,
            maximumBranches: 16,
          ),
        );
      } catch (_) {
        // An optional hint must never fail a committed transition or its SSE.
        return PreviewResult(
          version: game.state.version,
          mode: PreviewMode.pendingAction,
          windowId: game.state.pending!.windowId,
          assumptions: const ['assumesOtherResponsesPass'],
          complete: false,
          branches: const [],
          limitations: const ['previewUnavailable'],
        );
      }
    });
    return PendingDamagePreview.presentation(game, result.toJson());
  }

  Map<String, Object?> getPreviewState(String gameId, String playerId) {
    _expireDue(gameId);
    if (_hashFor(gameId) == null) {
      throw StateError('Executable content unavailable for preview');
    }
    final game = _get(gameId);
    return {...game.previewSnapshot(playerId), 'contentHash': _hashFor(gameId)};
  }

  Map<String, Object?> getPreviewContent(String gameId, String playerId) {
    _get(gameId).privateView(playerId);
    return getPublicContent(gameId);
  }

  /// Pinned executable definitions only; no hands, previews or private state.
  Map<String, Object?> getPublicContent(String gameId) {
    _get(gameId);
    if (_gameContent[gameId] == null) {
      throw StateError('Executable content unavailable for preview');
    }
    return ClientContent(_gameContent[gameId]!).json;
  }

  Map<String, Object?> previewAttack(String gameId, PreviewRequest request) =>
      preview(gameId, request);

  Map<String, Object?> preview(String gameId, PreviewRequest request) {
    final snapshot = PreviewState(getPreviewState(gameId, request.playerId));
    return PreviewRunner(
      _get(gameId).catalog,
      contentHash: _hashFor(gameId)!,
    ).run(snapshot, request).toJson();
  }

  void dispose() {
    _disposed = true;
    for (final id in _games.keys.toList()) {
      removeGame(id);
    }
  }

  Map<String, Object?> _publicView(String id, GameKernel game) => _withDeadline(
    id,
    {
      ...machineStateView(game.publicView()..remove('actionRecords')),
      'statistics': _statisticsWithTimes(id, game),
      'logEvents': projectPublicLogEvents(
        game,
        timestamps: _eventTimes[id] ?? const {},
      ),
    },
  );

  Map<String, Object?> _statisticsWithTimes(
    String id,
    GameKernel game, {
    DateTime? endedAt,
  }) {
    final statistics = game.statisticsView(
      includeScores: game.state.finished || endedAt != null,
    );
    final times = _eventTimes[id] ?? const <int, String>{};
    return {
      ...statistics,
      'survival': {
        for (final entry
            in (statistics['survival']! as Map<String, Object?>).entries)
          entry.key: (() {
            final value = entry.value! as Map<String, Object?>;
            final start = DateTime.tryParse(
              times[value['startSequence']] ?? '',
            );
            final end =
                DateTime.tryParse(times[value['endSequence']] ?? '') ??
                (value['alive'] == true ? endedAt : null);
            return {
              ...value,
              if (start != null) 'startedAt': start.toUtc().toIso8601String(),
              if (end != null) 'endedAt': end.toUtc().toIso8601String(),
              if (start != null && end != null)
                'seconds': end.difference(start).inSeconds.clamp(0, 2147483647),
            };
          })(),
      },
    };
  }

  Map<String, Object?> _withDeadline(String id, Map<String, Object?> view) {
    final window = view['responseWindow'] as Map<String, Object?>?;
    final deadline = _deadlines[id];
    return {
      ...view,
      'serverTime': _now().toUtc().toIso8601String(),
      if (window != null)
        'responseWindow': {
          ...window,
          if (deadline?.windowId == window['windowId'])
            'deadlineAt': deadline!.at.toUtc().toIso8601String(),
        },
    };
  }

  void _syncDeadline(String gameId, GameKernel game) {
    final pending = game.state.pending;
    if (pending?.responseExpired ?? false) {
      _deadlines.remove(gameId)?.timer?.cancel();
      return;
    }
    final existing = _deadlines[gameId];
    if (existing != null && existing.windowId == pending?.windowId) return;
    _deadlines.remove(gameId)?.timer?.cancel();
    if (pending == null || game.state.finished) return;
    final deadline = _ResponseDeadline(
      pending.windowId,
      _now().toUtc().add(Duration(seconds: game.rules.responseTimeoutSeconds)),
    );
    _deadlines[gameId] = deadline;
    _armDeadline(gameId, deadline);
  }

  void _armDeadline(String gameId, _ResponseDeadline deadline) {
    deadline.timer?.cancel();
    final remaining = deadline.at.difference(_now().toUtc());
    deadline.timer = _schedule(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        if (!identical(_deadlines[gameId], deadline)) return;
        if (checkpointRepo != null) {
          unawaited(
            _serialized(gameId, () => _expireDurably(gameId)).catchError((
              Object error,
              StackTrace stack,
            ) {
              onPersistenceError?.call(error, stack);
              if (!_disposed && identical(_deadlines[gameId], deadline)) {
                deadline.timer = _schedule(
                  const Duration(seconds: 1),
                  () => _armDeadline(gameId, deadline),
                );
              }
            }),
          );
        } else if (!_expireDue(gameId)) {
          _armDeadline(gameId, deadline);
        }
      },
    );
  }

  bool _expireDue(String gameId) {
    if (_aborting.contains(gameId)) return false;
    if (checkpointRepo != null) return false;
    final deadline = _deadlines[gameId];
    if (deadline == null || _now().toUtc().isBefore(deadline.at)) return false;
    final game = _get(gameId);
    _deadlines.remove(gameId)?.timer?.cancel();
    final since = game.state.events.length;
    if (game.expireResponse(deadline.windowId)) {
      _eventTimes[gameId] = _timesFor(game, since: since);
      _publish(gameId, game);
    }
    return true;
  }

  void _publish(String gameId, GameKernel game) {
    _syncDeadline(gameId, game);
    final update = _GameUpdate(_publicView(gameId, game), {
      for (final player in game.state.players)
        player.id: _withDeadline(gameId, _privateView(game, player.id)),
    });
    final updates = _updates[gameId]!..add(update);
    if (game.state.finished) {
      unawaited(updates.close());
      _scheduleArchive(gameId);
    }
  }

  GameKernel _get(String id) {
    if (_failedRestores.contains(id)) throw StateError('gameRecoveryFailed');
    final game = _games[id] ?? (throw StateError('Unknown game: $id'));
    if (game.state.finished) _scheduleArchive(id);
    return game;
  }

  Map<String, Object?> _signature(KernelCommand command) =>
      KernelRecoveryCodec.command(command);
}

final class _Receipt {
  const _Receipt(this.signature, this.version);
  final String signature;
  final int version;
}

final class _ResponseDeadline {
  _ResponseDeadline(this.windowId, this.at);
  final String windowId;
  final DateTime at;
  Timer? timer;
}

final class _GameUpdate {
  _GameUpdate(this.publicView, this.privateViews);
  final Map<String, Object?> publicView;
  final Map<String, Map<String, Object?>> privateViews;
}
