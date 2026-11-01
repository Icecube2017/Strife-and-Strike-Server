import 'dart:math';

import 'package:sns_kernel/sns_kernel.dart';

import 'package:sns_server/application/commands/kernel_command_request.dart';
import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/application/services/kernel_game_service.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/repo/game_abort_store.dart';
import 'package:sns_server/infrastructure/repo/room_expiry_store.dart';

/// Room/HTTP facade. All game state and rules live in GameKernel.
class GameService {
  GameService(
    this._rooms,
    this._kernel, {
    required List<String> deck,
    required List<String> commonSkills,
    this.rules = const GameRules(),
    this.abortStore,
    this.expiryStore,
  }) : deck = List.unmodifiable(deck),
       commonSkills = List.unmodifiable(commonSkills);
  final RoomService _rooms;
  final KernelGameService _kernel;
  final List<String> deck;
  final List<String> commonSkills;
  final GameRules rules;
  final GameAbortStore? abortStore;
  final RoomExpiryStore? expiryStore;
  final Set<String> _starting = {};

  Future<void> startRoomExpiration() {
    if (_kernel.checkpointRepo != null && expiryStore == null) {
      throw StateError('Atomic room expiration storage is not configured');
    }
    return _rooms.startExpiration((closedRoom) async {
      // Start reserves the room before taking the kernel queue. Let that
      // operation finish before expiration retries, avoiding inverse locks.
      if (_starting.contains(closedRoom.id)) {
        throw StateError('Room is starting');
      }
      await _kernel.expireRoomGamePersisted(
        'game_${closedRoom.id}',
        erase: (version, {required bool finished}) =>
            _kernel.checkpointRepo == null
            ? _rooms.deleteAbortedRoom(closedRoom)
            : expiryStore!.expire(
                closedRoom,
                'game_${closedRoom.id}',
                expectedGameVersion: version,
                gameFinished: finished,
              ),
      );
    });
  }

  Future<RoomConnection?> connectGamePlayer(String gameId, String playerId) =>
      _rooms.connectForGame(gameId, playerId);

  void requireCharacter(String definitionId) {
    if (!_kernel.catalog.characters.containsKey(definitionId)) {
      throw StateError('Unknown character definition: $definitionId');
    }
  }

  Future<String> startGame(String key, String hostPlayerId) async {
    final roomId = _rooms.resolveRoomId(key);
    _rooms.assertCanStart(roomId, hostPlayerId);
    if (!_starting.add(roomId)) {
      throw StateError('Room is already starting');
    }
    final gameId = _rooms.gameIdForRoom(roomId);
    var created = false;
    var reserved = false;
    if (_kernel.hasGameRecord(gameId)) {
      try {
        await _kernel.ensureGameLoaded(gameId);
        await _rooms.markInGame(roomId);
        return gameId;
      } finally {
        _starting.remove(roomId);
      }
    }
    try {
      await _rooms.reserveStart(roomId, hostPlayerId);
      reserved = true;
      final players = _rooms.getPlayers(roomId);
      await _kernel.startGamePersisted(
        GameSetup(
          gameId: gameId,
          players: [
            for (final p in players)
              PlayerSetup(
                id: p.id,
                characterId: p.characterDefinitionId!,
                teamId: p.teamId!,
              ),
          ],
          deck: deck,
          skillPool: commonSkills,
          rules: _rooms.getRules(roomId).applyTo(rules),
          seed: Random.secure().nextInt(2147483646),
        ),
      );
      created = true;
      await _rooms.markInGame(roomId);
      return gameId;
    } catch (_) {
      if (created) {
        await _kernel.removeGamePersisted(gameId);
      }
      if (reserved) {
        await _rooms.cancelStart(roomId);
      }
      rethrow;
    } finally {
      _starting.remove(roomId);
    }
  }

  Future<void> resumeCompletedDrafts() async {
    for (final (id, host) in _rooms.completedDrafts) {
      await startGame(id, host);
    }
  }

  Map<String, Object?> characterCatalog() {
    return {
      'contentVersion': _kernel.catalog.version,
      'contentHash': _kernel.contentHash,
      'characters': [
        for (final id in selectableCharacterIds)
          {
            'id': id,
            'templateId': _kernel.catalog.characters[id]!.templateId,
            'raceId': _kernel.catalog.characters[id]!.raceId,
            'traitIds': _kernel.catalog.characters[id]!.traits,
            'skillIds': _kernel.catalog.characters[id]!.skills,
          },
      ],
    };
  }

  List<String> get selectableCharacterIds =>
      _kernel.catalog.characters.keys.where((id) => id != 'practice').toList();
  Future<RoomResponse> beginDraft(String key, String hostId) async {
    final current = _rooms.getRoom(key, hostId);
    if (current.hostPlayerId == hostId &&
        current.rules.randomCharacters &&
        const ['selectionComplete', 'inGame'].contains(current.phase)) {
      // Retrying a timed-out random start must not deal a new set of roles.
      return _startCompletedDraft(current);
    }
    return _startCompletedDraft(
      await _rooms.beginDraft(key, hostId, selectableCharacterIds),
    );
  }

  Future<RoomResponse> submitBans(
    String key,
    String playerId,
    List<String> characterIds,
  ) async => _startCompletedDraft(
    await _rooms.submitBans(key, playerId, characterIds),
  );
  Future<RoomResponse> confirmCharacter(
    String key,
    String playerId,
    String characterId,
  ) async {
    requireCharacter(characterId);
    return _startCompletedDraft(
      await _rooms.confirmCharacter(key, playerId, characterId),
    );
  }

  Future<RoomResponse> _startCompletedDraft(RoomResponse view) async {
    if (view.phase == 'selectionComplete') {
      if (!_starting.contains(view.roomId)) {
        try {
          await startGame(view.roomId, view.hostPlayerId!);
        } catch (_) {
          // A persisted complete selection can retry automatic start safely.
          if (_rooms.getRoom(view.roomId, view.hostPlayerId!).phase !=
              'inGame') {
            rethrow;
          }
        }
      }
      return _rooms.getRoom(view.roomId, view.hostPlayerId!);
    }
    return view;
  }

  Future<RoomResponse> closeRoom(String key, String playerId) =>
      _rooms.closeRoom(
        key,
        playerId,
        validateFinished: (id) async {
          await _kernel.requireFinishedGame(id);
        },
      );

  Future<RoomResponse> abortGame(String gameId, String playerId) async {
    final roomId = _rooms.roomIdForGame(gameId);
    if (_rooms.getHostId(roomId) != playerId) {
      throw StateError('Only the host can abort');
    }
    if (_starting.contains(roomId)) throw StateError('Room is starting');
    // Older clients use abort when their local game could not be loaded. A
    // terminal archive can close the room while preserving the saved result.
    if (!_kernel.hasGame(gameId) && await _kernel.hasFinishedArchive(gameId)) {
      return closeRoom(roomId, playerId);
    }
    if (_kernel.checkpointRepo != null && abortStore == null) {
      throw StateError('Atomic abort storage is not configured');
    }
    // Room and match queues fence concurrent commands and settings writes.
    return _rooms.closeAfterAbort(
      roomId,
      playerId,
      (closedRoom) => _kernel.abortGamePersisted(
        gameId,
        playerId,
        allowNonParticipant: true, // The room host was authenticated above.
        erase: (version) => _kernel.checkpointRepo == null
            ? _rooms.deleteAbortedRoom(closedRoom)
            : abortStore!.abort(gameId, version, closedRoom),
      ),
    );
  }

  int handleCommand(String gameId, KernelCommandRequest request) =>
      _kernel.submit(
        gameId,
        request.command,
        commandId: request.commandId,
        expectedVersion: request.clientVersion,
      );
  Future<int> handleCommandPersisted(
    String gameId,
    KernelCommandRequest request,
  ) => _kernel.submitPersisted(
    gameId,
    request.command,
    commandId: request.commandId,
    expectedVersion: request.clientVersion,
  );
  Future<void> ensureGameLoaded(String id) => _kernel.ensureGameLoaded(id);
  Future<void> requireFinishedGame(String id) =>
      _kernel.requireFinishedGame(id);
  Map<String, Object?> getState(String gameId) => _kernel.getState(gameId);
  Map<String, Object?> getPrivateView(String gameId, String playerId) =>
      _kernel.getPrivateState(gameId, playerId);
  Map<String, Object?> getPlayerState(String gameId, String playerId) =>
      _kernel.getPlayerState(gameId, playerId);
  Map<String, Object?> getPreviewState(String gameId, String playerId) =>
      _kernel.getPreviewState(gameId, playerId);
  Map<String, Object?> getPreviewContent(String gameId, String playerId) =>
      _rooms.isSpectatorForGame(gameId, playerId)
      ? _kernel.getPublicContent(gameId)
      : _kernel.getPreviewContent(gameId, playerId);
  Map<String, Object?> previewAttack(String gameId, PreviewRequest request) =>
      preview(gameId, request);
  Map<String, Object?> preview(String gameId, PreviewRequest request) =>
      _kernel.preview(gameId, request);
  Stream<Map<String, Object?>> subscribeForPlayer(
    String gameId,
    String playerId,
  ) => _kernel.subscribeForPlayer(gameId, playerId);
  Stream<Map<String, Object?>> subscribe(String gameId) =>
      _kernel.subscribe(gameId);
}
