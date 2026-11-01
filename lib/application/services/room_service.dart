import 'dart:async';
import 'dart:math';

import 'package:sns_server/application/dto/room_dto.dart';
import 'package:sns_server/application/dto/room_rules.dart';
import 'package:sns_server/infrastructure/repo/room_repo.dart';

part 'room_expiration.dart';

enum RoomStatus { waiting, banning, selecting, ready, starting, inGame, closed }

/// Lobby selection, not a mutable combat character. The kernel creates instances.
final class RoomPlayer {
  const RoomPlayer({
    required this.id,
    required this.name,
    this.characterDefinitionId,
    this.teamId,
  });
  final String id;
  final String name;
  final String? characterDefinitionId;
  final String? teamId;
}

class Room {
  Room({
    required this.id,
    required this.players,
    String? hostPlayerId,
    this.maxPlayers = 4,
    this.rules = const RoomRules(),
    this.status = RoomStatus.waiting,
    this.roomCode,
    this.version = 0,
    this.draftRequired = true,
    this.allDisconnectedAt,
    List<String> characterPool = const [],
    Map<String, List<String>> bans = const {},
    Set<String> spectators = const {},
  }) : hostPlayerId = hostPlayerId ?? players.first.id,
       characterPool = List.of(characterPool),
       spectators = Set.of(spectators),
       bans = {
         for (final entry in bans.entries) entry.key: List.of(entry.value),
       };
  final String id;
  final String hostPlayerId;
  final String? roomCode;
  int version;
  final bool draftRequired;
  final List<String> characterPool;
  final Map<String, List<String>> bans;
  final List<RoomPlayer> players;
  final Set<String> spectators;
  final int maxPlayers;
  final RoomRules rules;
  RoomStatus status;
  DateTime? allDisconnectedAt;
}

class RoomService {
  RoomService(
    this._repo, {
    this.offlineRoomLifetime = const Duration(minutes: 20),
    DateTime Function()? now,
    Timer Function(Duration, void Function())? schedule,
    this.onExpirationError,
  }) : _now = now ?? DateTime.now,
       _schedule = schedule ?? Timer.new;
  final RoomRepo _repo;
  final Duration offlineRoomLifetime;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _schedule;
  final void Function(String roomId, Object error, StackTrace stack)?
  onExpirationError;
  final Map<String, Set<Object>> _connections = {};
  final Map<String, _RoomExpiry> _expirations = {};
  Future<void> Function(Room closedRoom)? _expireStorage;
  bool _disposed = false;
  final Map<String, Room> _rooms = {};
  final Map<String, String> _codes = {};
  final Map<String, StreamController<RoomResponse>> _updates = {};
  final Random _codesRandom = Random.secure();
  Future<void> _creations = Future<void>.value();
  int _sequence = 0;
  final Map<String, Future<void>> _writes = {};

  Future<T> _serialize<T>(String id, Future<T> Function() operation) {
    final next = (_writes[id] ?? Future<void>.value()).then((_) => operation());
    final tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _writes[id] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_writes[id], tail)) {
          _writes.remove(id);
        }
      }),
    );
    return next;
  }

  Future<void> restoreRooms() async {
    final rooms = await _repo.loadAll();
    if (_rooms.isNotEmpty) {
      throw StateError('Restore requires empty room service');
    }
    _rooms.addEntries(rooms.map((r) => MapEntry(r.id, r)));
    for (final room in rooms) {
      if (room.roomCode != null) {
        if (_codes.containsKey(room.roomCode)) {
          throw StateError('Duplicate saved room code');
        }
        _codes[room.roomCode!] = room.id;
      }
      _updates[room.id] = StreamController<RoomResponse>.broadcast();
    }
  }

  Future<RoomResponse> createRoom(
    CreateRoomRequest req, [
    String? characterDefinitionId,
  ]) {
    final operation = _creations.then(
      (_) => _createRoom(req, characterDefinitionId),
    );
    _creations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<RoomResponse> _createRoom(
    CreateRoomRequest req,
    String? characterDefinitionId,
  ) async {
    if (req.rules.bansPerPlayer < 1 || req.rules.bansPerPlayer > 3) {
      throw StateError('Invalid Ban quota');
    }
    if (req.maxPlayers < 2 || req.maxPlayers > 8) {
      throw StateError('A room needs 2 to 8 seats');
    }
    final id = 'room_${DateTime.now().microsecondsSinceEpoch}_${++_sequence}';
    final first = _codesRandom.nextInt(9000);
    for (var offset = 0; offset < 9000; offset++) {
      final code = '${1000 + (first + offset) % 9000}';
      if (_codes.containsKey(code)) {
        continue;
      }
      final room = Room(
        id: id,
        allDisconnectedAt: _now().toUtc(),
        roomCode: code,
        draftRequired: characterDefinitionId == null,
        maxPlayers: req.maxPlayers,
        rules: req.rules,
        players: [
          RoomPlayer(
            id: req.hostPlayerId,
            name: req.hostPlayerName,
            characterDefinitionId: characterDefinitionId,
            teamId: req.rules.teamMode == RoomTeamMode.freeForAll
                ? (characterDefinitionId == null
                      ? 'player:${req.hostPlayerId}'
                      : '0')
                : null,
          ),
        ],
      );
      if (!await _repo.create(room)) {
        continue;
      }
      _rooms[id] = room;
      _codes[code] = id;
      _updates[id] = StreamController<RoomResponse>.broadcast();
      _scheduleRoomExpiry(room);
      return _response(room);
    }
    throw StateError('No available four-digit room codes');
  }

  Future<RoomResponse> joinRoom(
    String roomId,
    JoinRoomRequest req, [
    String? characterDefinitionId,
  ]) {
    final id = _get(roomId).id;
    return _serialize(id, () => _joinRoom(id, req, characterDefinitionId));
  }

  Future<RoomResponse> _joinRoom(
    String roomId,
    JoinRoomRequest req,
    String? characterDefinitionId,
  ) async {
    final room = roomFromJson(roomToJson(_get(roomId)));
    if (room.status == RoomStatus.closed) {
      throw StateError('Room is not accepting players');
    }
    if (room.players.any((p) => p.id == req.playerId) ||
        room.spectators.contains(req.playerId)) {
      throw StateError('Player already joined');
    }
    if (room.status != RoomStatus.waiting) {
      room.spectators.add(req.playerId);
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
      return _response(room);
    }
    if (room.players.length >= room.maxPlayers) {
      throw StateError('Room is full');
    }
    room.players.add(
      RoomPlayer(
        id: req.playerId,
        name: req.playerName,
        characterDefinitionId: characterDefinitionId,
        teamId: room.rules.teamMode == RoomTeamMode.freeForAll
            ? (room.draftRequired
                  ? 'player:${req.playerId}'
                  : '${room.players.length}')
            : null,
      ),
    );
    room.version++;
    await _repo.save(room);
    _commitRoom(room);
    return _response(room);
  }

  List<RoomPlayer> getPlayers(String roomId) =>
      List.unmodifiable(_get(roomId).players);

  bool isSpectatorForGame(String gameId, String playerId) => _rooms.values.any(
    (r) => 'game_${r.id}' == gameId && r.spectators.contains(playerId),
  );

  Future<RoomResponse> setSpectating(
    String key,
    JoinRoomRequest user, {
    required bool spectating,
  }) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final room = roomFromJson(roomToJson(_get(id)));
      _requireMember(room, user.playerId);
      if (room.status == RoomStatus.closed) {
        throw StateError('Room is not accepting players');
      }
      final wasSpectator = room.spectators.contains(user.playerId);
      if (wasSpectator == spectating) return _response(room);
      if (spectating) {
        if (room.status != RoomStatus.waiting) {
          throw StateError('spectatorModeLocked');
        }
        room.players.removeWhere((p) => p.id == user.playerId);
        room.spectators.add(user.playerId);
      } else {
        if (room.status != RoomStatus.waiting) {
          throw StateError('spectatorModeLocked');
        }
        if (room.players.length >= room.maxPlayers) {
          throw StateError('Room is full');
        }
        room.spectators.remove(user.playerId);
        room.players.add(
          RoomPlayer(
            id: user.playerId,
            name: user.playerName,
            teamId: room.rules.teamMode == RoomTeamMode.freeForAll
                ? 'player:${user.playerId}'
                : null,
          ),
        );
      }
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
      return _response(room);
    });
  }

  Future<void> leaveSpectating(String key, String playerId) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final room = roomFromJson(roomToJson(_get(id)));
      if (!room.spectators.remove(playerId)) {
        throw StateError('spectatorRequired');
      }
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
    });
  }

  Future<void> leaveRoom(
    String key,
    String playerId, {
    Future<void> Function(String gameId)? validateFinished,
  }) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final current = _get(id);
      _requireMember(current, playerId);
      if (current.hostPlayerId == playerId) {
        throw StateError('hostCannotLeaveRoom');
      }
      final spectator = current.spectators.contains(playerId);
      if (!spectator && current.status == RoomStatus.starting) {
        throw StateError('roomStarting');
      }
      if (!spectator && current.status == RoomStatus.inGame) {
        if (validateFinished == null) throw StateError('gameStillRunning');
        await validateFinished('game_$id');
      }
      final room = roomFromJson(roomToJson(current));
      room.spectators.remove(playerId);
      room.players.removeWhere((p) => p.id == playerId);
      room.bans.remove(playerId);
      if (!spectator &&
          const {
            RoomStatus.banning,
            RoomStatus.selecting,
            RoomStatus.ready,
          }.contains(room.status)) {
        room.status = RoomStatus.waiting;
        room.bans.clear();
        for (var i = 0; i < room.players.length; i++) {
          final p = room.players[i];
          room.players[i] = RoomPlayer(
            id: p.id,
            name: p.name,
            teamId: p.teamId,
          );
        }
      }
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
    });
  }

  String getHostId(String roomId) => _get(roomId).hostPlayerId;

  Future<void> renamePlayer(String playerId, String nickname) async {
    for (final id in _rooms.keys.toList()) {
      await _serialize(id, () async {
        final current = _rooms[id];
        if (current == null || !current.players.any((p) => p.id == playerId)) {
          return;
        }
        final room = roomFromJson(roomToJson(current));
        final index = room.players.indexWhere((p) => p.id == playerId);
        final old = room.players[index];
        room.players[index] = RoomPlayer(
          id: old.id,
          name: nickname,
          characterDefinitionId: old.characterDefinitionId,
          teamId: old.teamId,
        );
        room.version++;
        await _repo.save(room);
        _commitRoom(room);
      });
    }
  }

  RoomRules getRules(String roomId) => _get(roomId).rules;

  void assertCanStart(String roomId, String playerId) {
    final room = _get(roomId);
    if (room.status != RoomStatus.ready &&
        !(room.status == RoomStatus.waiting && !room.draftRequired)) {
      throw StateError('Character selection is not complete');
    }
    if (room.players.any(
      (p) => p.characterDefinitionId == null || p.teamId == null,
    )) {
      throw StateError('Characters or teams are incomplete');
    }
    if (room.hostPlayerId != playerId) {
      throw StateError('Only the host can start');
    }
    if (room.players.length < 2) {
      throw StateError('At least two players are required');
    }
  }

  Future<void> reserveStart(String key, String playerId) {
    final id = _get(key).id;
    return _serialize(id, () async {
      assertCanStart(id, playerId);
      final room = roomFromJson(roomToJson(_get(id)))
        ..status = RoomStatus.starting;
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
    });
  }

  Future<void> cancelStart(String key) {
    final id = _get(key).id;
    return _serialize(id, () async {
      if (_get(id).status != RoomStatus.starting) {
        return;
      }
      final room = roomFromJson(roomToJson(_get(id)))
        ..status = _get(id).draftRequired
            ? RoomStatus.ready
            : RoomStatus.waiting;
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
    });
  }

  Future<void> markInGame(String key) {
    final roomId = _get(key).id;
    return _serialize(roomId, () async {
      final room = roomFromJson(roomToJson(_get(roomId)))
        ..status = RoomStatus.inGame;
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
    });
  }

  /// Repair a crash between durable game creation and lobby-status persistence.
  Future<void> reconcileGames(bool Function(String) hasGame) async {
    for (final room in _rooms.values.toList()) {
      if (room.status != RoomStatus.inGame && hasGame('game_${room.id}')) {
        await markInGame(room.id);
      } else if (room.status == RoomStatus.starting &&
          !hasGame('game_${room.id}')) {
        await cancelStart(room.id);
      }
    }
  }

  List<(String, String)> get completedDrafts => [
    for (final room in _rooms.values)
      if (room.status == RoomStatus.ready &&
          room.draftRequired &&
          room.players.isNotEmpty)
        (room.id, room.hostPlayerId),
  ];

  String gameIdForRoom(String key) => 'game_${_get(key).id}';

  String roomIdForGame(String gameId) =>
      _rooms.values
          .where((room) => 'game_${room.id}' == gameId)
          .firstOrNull
          ?.id ??
      (throw StateError('Unknown game room: $gameId'));

  Future<RoomResponse> closeAfterAbort(
    String key,
    String hostId,
    Future<void> Function(Room replacement) persist,
  ) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final current = _get(id);
      if (current.hostPlayerId != hostId) {
        throw StateError('Only the host can abort');
      }
      if (current.status != RoomStatus.inGame) {
        throw StateError('Room is not in a game');
      }
      final room = roomFromJson(roomToJson(current))
        ..status = RoomStatus.closed
        ..version = current.version + 1;
      await persist(room);
      final response = _response(room);
      final updates = _updates.remove(id);
      updates?.add(response);
      if (updates != null) unawaited(updates.close());
      _rooms.remove(id);
      _forgetRoomPresence(id);
      if (room.roomCode != null) _codes.remove(room.roomCode);
      return response;
    });
  }

  Future<void> deleteAbortedRoom(Room room) => _repo.delete(room.id);

  /// Close a lobby/draft only after its persistent record was removed. Starting
  /// and active matches must use the coordinated game lifecycle instead.
  Future<RoomResponse> closeRoom(
    String key,
    String hostId, {
    Future<void> Function(String gameId)? validateFinished,
  }) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final current = _get(id);
      if (current.hostPlayerId != hostId) {
        throw StateError('Only the host can close');
      }
      if (current.status == RoomStatus.starting) {
        throw StateError('Room settings are locked');
      }
      if (current.status == RoomStatus.inGame) {
        if (validateFinished == null) {
          throw StateError('Room settings are locked');
        }
        await validateFinished('game_${current.id}');
      }
      final closed = roomFromJson(roomToJson(current))
        ..status = RoomStatus.closed
        ..version = current.version + 1;
      await _repo.delete(id);
      final response = _response(
        closed,
        closeReason: current.status == RoomStatus.inGame ? 'completed' : null,
      );
      final updates = _updates.remove(id);
      updates?.add(response);
      if (updates != null) unawaited(updates.close());
      _rooms.remove(id);
      _forgetRoomPresence(id);
      if (current.roomCode != null) _codes.remove(current.roomCode);
      return response;
    });
  }

  String resolveRoomId(String key) => _get(key).id;
  Room _get(String key) =>
      _rooms[_codes[key] ?? key] ?? (throw StateError('Unknown room: $key'));

  void _commitRoom(Room room) {
    _rooms[room.id] = room;
    _updates[room.id]?.add(_response(room));
  }

  RoomResponse getRoom(String key, String viewerId) {
    final room = _get(key);
    _requireMember(room, viewerId);
    return _response(room);
  }

  Stream<RoomResponse> subscribe(String key, String viewerId) {
    final room = _get(key);
    _requireMember(room, viewerId);
    return _updates[room.id]!.stream;
  }

  void _requireMember(Room room, String playerId) {
    if (!room.players.any((p) => p.id == playerId) &&
        !room.spectators.contains(playerId)) {
      throw StateError('Player is not a room member');
    }
  }

  void _requirePlayer(Room room, String playerId) {
    _requireMember(room, playerId);
    if (room.spectators.contains(playerId)) {
      throw StateError('spectatorReadOnly');
    }
  }

  Future<RoomResponse> updateSettings(
    String key,
    String playerId, {
    RoomRules? rules,
    Map<String, dynamic>? ruleChanges,
    int? maxPlayers,
  }) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final current = _get(id);
      if (current.hostPlayerId != playerId) {
        throw StateError('Only the host can change room settings');
      }
      if (current.status != RoomStatus.waiting) {
        throw StateError('Room settings are locked');
      }
      if (maxPlayers != null &&
          (maxPlayers < 2 ||
              maxPlayers > 8 ||
              maxPlayers < current.players.length)) {
        throw StateError('Invalid room capacity');
      }
      if (rules != null && ruleChanges != null) {
        throw StateError('Specify rules or rule changes');
      }
      final updatedRules = ruleChanges == null
          ? rules
          : RoomRules.fromJson({...current.rules.toJson(), ...ruleChanges});
      if (updatedRules != null &&
          (updatedRules.bansPerPlayer < 1 || updatedRules.bansPerPlayer > 3)) {
        throw StateError('Invalid Ban quota');
      }
      final room = roomFromJson({
        ...roomToJson(current),
        if (updatedRules != null) 'rules': updatedRules.toJson(),
        if (maxPlayers != null) 'maxPlayers': maxPlayers,
      });
      if (current.rules.teamMode != room.rules.teamMode) {
        for (var i = 0; i < room.players.length; i++) {
          final p = room.players[i];
          room.players[i] = RoomPlayer(
            id: p.id,
            name: p.name,
            characterDefinitionId: p.characterDefinitionId,
            teamId: room.rules.teamMode == RoomTeamMode.freeForAll
                ? 'player:${p.id}'
                : null,
          );
        }
      }
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
      return _response(room);
    });
  }

  Future<RoomResponse> setTeam(String key, String playerId, String teamId) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final room = roomFromJson(roomToJson(_get(id)));
      _requirePlayer(room, playerId);
      if (room.status != RoomStatus.waiting || room.rules.randomSeats) {
        throw StateError('Teams are locked');
      }
      final allowed = switch (room.rules.teamMode) {
        RoomTeamMode.freeForAll => <String>{},
        RoomTeamMode.twoTeams => {'1', '2'},
        RoomTeamMode.threeTeams => {'1', '2', '3'},
      };
      if (!allowed.contains(teamId)) {
        throw StateError('Invalid team for room mode');
      }
      final index = room.players.indexWhere((p) => p.id == playerId);
      final p = room.players[index];
      room.players[index] = RoomPlayer(
        id: p.id,
        name: p.name,
        characterDefinitionId: p.characterDefinitionId,
        teamId: teamId,
      );
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
      return _response(room);
    });
  }

  Future<RoomResponse> beginDraft(
    String key,
    String hostId,
    Iterable<String> characters,
  ) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final room = roomFromJson(roomToJson(_get(id)));
      if (room.hostPlayerId != hostId) {
        throw StateError('Only the host can begin selection');
      }
      if (room.status != RoomStatus.waiting) {
        throw StateError('Draft already started');
      }
      if (room.players.length < 2) {
        throw StateError('At least two players are required');
      }
      if (room.rules.randomSeats) {
        room.players.shuffle(_codesRandom);
        final teams = switch (room.rules.teamMode) {
          RoomTeamMode.freeForAll => 0,
          RoomTeamMode.twoTeams => 2,
          RoomTeamMode.threeTeams => 3,
        };
        for (var i = 0; i < room.players.length; i++) {
          final p = room.players[i];
          room.players[i] = RoomPlayer(
            id: p.id,
            name: p.name,
            teamId: teams == 0 ? 'player:${p.id}' : '${i % teams + 1}',
          );
        }
      } else if (room.rules.teamMode != RoomTeamMode.freeForAll) {
        final groups = <String, List<RoomPlayer>>{};
        for (final p in room.players) {
          groups.putIfAbsent(p.teamId ?? '', () => []).add(p);
        }
        final keys = groups.keys.toList()..sort();
        room.players.clear();
        for (var i = 0; groups.values.any((g) => i < g.length); i++) {
          for (final key in keys) {
            if (i < groups[key]!.length) room.players.add(groups[key]![i]);
          }
        }
      }
      if (room.players.any((p) => p.teamId == null)) {
        throw StateError('All players must choose a team');
      }
      final expectedTeams = switch (room.rules.teamMode) {
        RoomTeamMode.freeForAll => room.players.length,
        RoomTeamMode.twoTeams => 2,
        RoomTeamMode.threeTeams => 3,
      };
      if (room.players.map((p) => p.teamId).toSet().length != expectedTeams) {
        throw StateError('Every configured team needs a member');
      }
      room.characterPool
        ..clear()
        ..addAll(characters.toSet());
      if (room.characterPool.length < room.players.length) {
        throw StateError('Not enough playable characters');
      }
      if (room.rules.banEnabled &&
          room.rules.bansPerPlayer * room.players.length >
              room.characterPool.length - room.players.length) {
        throw StateError('Ban quota could leave too few characters');
      }
      for (var i = 0; i < room.players.length; i++) {
        final p = room.players[i];
        room.players[i] = RoomPlayer(id: p.id, name: p.name, teamId: p.teamId);
      }
      room.bans.clear();
      room.status = room.rules.banEnabled && room.rules.bansPerPlayer > 0
          ? RoomStatus.banning
          : RoomStatus.selecting;
      if (room.status == RoomStatus.selecting) _enterSelection(room);
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
      return _response(room);
    });
  }

  Future<RoomResponse> submitBans(
    String key,
    String playerId,
    List<String> characterIds,
  ) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final room = roomFromJson(roomToJson(_get(id)));
      _requirePlayer(room, playerId);
      if (characterIds.length > room.rules.bansPerPlayer ||
          characterIds.toSet().length != characterIds.length ||
          characterIds.any((c) => !room.characterPool.contains(c))) {
        throw StateError('Invalid Ban selection');
      }
      if (room.bans.containsKey(playerId)) {
        if (room.bans[playerId]!.toSet().length ==
                characterIds.toSet().length &&
            room.bans[playerId]!.toSet().containsAll(characterIds)) {
          return _response(room);
        }
        throw StateError('Ban is already confirmed');
      }
      if (room.status != RoomStatus.banning) {
        throw StateError('Not a Ban phase');
      }
      final taken = room.bans.values.expand((ids) => ids).toSet();
      if (characterIds.any(taken.contains)) {
        throw StateError('Character is already banned');
      }
      room.bans[playerId] = List.of(characterIds);
      if (room.bans.length == room.players.length) {
        _enterSelection(room);
      }
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
      return _response(room);
    });
  }

  Future<RoomResponse> confirmCharacter(
    String key,
    String playerId,
    String characterId,
  ) {
    final id = _get(key).id;
    return _serialize(id, () async {
      final current = _get(id);
      _requirePlayer(current, playerId);
      final p = current.players.singleWhere((p) => p.id == playerId);
      if (p.characterDefinitionId == characterId &&
          current.status != RoomStatus.waiting &&
          current.status != RoomStatus.banning) {
        return _response(current);
      }
      if (current.status != RoomStatus.selecting) {
        throw StateError('Not a character selection phase');
      }
      if (p.characterDefinitionId != null) {
        throw StateError('Character is already confirmed');
      }
      if (!_availableCharacters(current).contains(characterId)) {
        throw StateError('Character is unavailable');
      }
      final room = roomFromJson(roomToJson(current));
      final index = room.players.indexWhere((p) => p.id == playerId);
      room.players[index] = RoomPlayer(
        id: p.id,
        name: p.name,
        characterDefinitionId: characterId,
        teamId: p.teamId,
      );
      if (room.players.every((p) => p.characterDefinitionId != null)) {
        room.status = RoomStatus.ready;
      }
      room.version++;
      await _repo.save(room);
      _commitRoom(room);
      return _response(room);
    });
  }

  void _enterSelection(Room room) {
    room.status = RoomStatus.selecting;
    if (!room.rules.randomCharacters) return;
    final available = _availableCharacters(room)..shuffle(_codesRandom);
    if (available.length < room.players.length) {
      throw StateError('Not enough playable characters');
    }
    for (var i = 0; i < room.players.length; i++) {
      final p = room.players[i];
      room.players[i] = RoomPlayer(
        id: p.id,
        name: p.name,
        teamId: p.teamId,
        characterDefinitionId: available[i],
      );
    }
    room.status = RoomStatus.ready;
  }

  List<String> _availableCharacters(Room room) {
    final unavailable = {
      for (final choices in room.bans.values) ...choices,
      for (final p in room.players)
        if (p.characterDefinitionId != null) p.characterDefinitionId!,
    };
    return room.characterPool.where((id) => !unavailable.contains(id)).toList();
  }

  void dispose() {
    _disposed = true;
    for (final expiry in _expirations.values) {
      expiry.timer?.cancel();
    }
    _expirations.clear();
    _connections.clear();
    for (final stream in _updates.values) {
      unawaited(stream.close());
    }
    _updates.clear();
  }

  RoomResponse _response(Room room, {String? closeReason}) => RoomResponse(
    closeReason: closeReason,
    roomId: room.id,
    roomCode: room.roomCode,
    version: room.version,
    phase: switch (room.status) {
      RoomStatus.waiting => 'lobby',
      RoomStatus.banning => 'ban',
      RoomStatus.selecting => 'selection',
      RoomStatus.ready => 'selectionComplete',
      RoomStatus.starting => 'starting',
      RoomStatus.inGame => 'inGame',
      RoomStatus.closed => 'closed',
    },
    fullCharacterPool: room.characterPool,
    characterPool: _availableCharacters(room),
    banSubmittedPlayerIds: room.bans.keys.toList(),
    bannedCharacterIds: room.bans.values.expand((ids) => ids).toSet().toList(),
    maxPlayers: room.maxPlayers,
    hostPlayerId: room.hostPlayerId,
    spectatorIds: Set.unmodifiable(room.spectators),
    gameId: room.status == RoomStatus.inGame ? 'game_${room.id}' : null,
    players: [
      for (final p in room.players)
        {
          'playerId': p.id,
          'nickname': p.name,
          'characterId': p.characterDefinitionId,
          'teamId': p.teamId,
        },
    ],
    rules: room.rules,
    status: room.status.name,
    playerIds: room.players.map((p) => p.id).toList(),
  );
}
