import 'dart:convert';

import 'package:sns_server/application/dto/room_rules.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';

abstract class RoomRepo {
  Future<void> save(Room room);
  Future<bool> create(Room room);
  Future<Room?> findById(String roomId);
  Future<void> delete(String roomId);
  Future<List<Room>> loadAll();
}

class InMemoryRoomRepo implements RoomRepo {
  final Map<String, Room> _store = {};

  @override
  Future<bool> create(Room room) async {
    if (_store.containsKey(room.id) ||
        _store.values.any(
          (r) => room.roomCode != null && r.roomCode == room.roomCode,
        )) {
      return false;
    }
    await save(room);
    return true;
  }

  @override
  Future<void> save(Room room) async =>
      _store[room.id] = roomFromJson(roomToJson(room));

  @override
  Future<Room?> findById(String roomId) async =>
      _store[roomId] == null ? null : roomFromJson(roomToJson(_store[roomId]!));

  @override
  Future<List<Room>> loadAll() async => [
    for (final room in _store.values) roomFromJson(roomToJson(room)),
  ];

  @override
  Future<void> delete(String roomId) async => _store.remove(roomId);
}

class SqliteRoomRepo implements RoomRepo {
  SqliteRoomRepo(this._db);
  final DbConnection _db;
  List<Object?> _values(Room room) => [
    room.id,
    room.roomCode,
    jsonEncode(roomToJson(room)),
  ];
  @override
  Future<bool> create(Room room) async {
    _db.database.execute(
      'INSERT INTO rooms (id, room_code, snapshot) VALUES (?, ?, ?) ON CONFLICT DO NOTHING',
      _values(room),
    );
    return _db.database.updatedRows == 1;
  }

  @override
  Future<void> save(Room room) async {
    _db.database.execute(
      'INSERT INTO rooms (id, room_code, snapshot) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET room_code = excluded.room_code, snapshot = excluded.snapshot',
      _values(room),
    );
  }

  Room _read(Map<String, Object?> row) => roomFromJson(
    jsonDecode(row['snapshot']! as String) as Map<String, dynamic>,
  );
  @override
  Future<Room?> findById(String roomId) async {
    final rows = _db.database.select(
      'SELECT snapshot FROM rooms WHERE id = ?',
      [roomId],
    );
    return rows.isEmpty ? null : _read(rows.first);
  }

  @override
  Future<List<Room>> loadAll() async => [
    for (final row in _db.database.select(
      'SELECT snapshot FROM rooms ORDER BY id',
    ))
      _read(row),
  ];
  @override
  Future<void> delete(String roomId) async {
    _db.database.execute('DELETE FROM rooms WHERE id = ?', [roomId]);
  }
}

Map<String, Object?> roomToJson(Room room) => {
  'id': room.id,
  'roomCode': room.roomCode,
  'hostPlayerId': room.hostPlayerId,
  ..._lobbyJson(room),
  'status': room.status.name,
  'allDisconnectedAt': room.allDisconnectedAt?.toUtc().toIso8601String(),
  'maxPlayers': room.maxPlayers,
  'rules': room.rules.toJson(),
  'spectators': room.spectators.toList(),
  'players': [
    for (final p in room.players)
      {
        'id': p.id,
        'name': p.name,
        'characterDefinitionId': p.characterDefinitionId,
        'teamId': p.teamId,
      },
  ],
};
Room roomFromJson(Map<String, dynamic> json) => Room(
  id: json['id'] as String,
  roomCode: json['roomCode'] as String?,
  hostPlayerId: json['hostPlayerId'] as String?,
  allDisconnectedAt: json['allDisconnectedAt'] == null
      ? null
      : DateTime.parse(json['allDisconnectedAt'] as String).toUtc(),
  version: json['version'] as int? ?? 0,
  status: json['status'] == 'ready' && json['draftRequired'] == null
      ? RoomStatus.starting
      : RoomStatus.values.byName(json['status'] as String),
  draftRequired: json['draftRequired'] as bool? ?? false,
  characterPool: (json['characterPool'] as List? ?? const []).cast<String>(),
  bans: {
    for (final entry in (json['bans'] as Map<String, dynamic>? ?? {}).entries)
      entry.key: (entry.value as List).cast<String>(),
  },
  maxPlayers: json['maxPlayers'] as int,
  rules: RoomRules.fromJson(json['rules'], restored: true),
  spectators: (json['spectators'] as List? ?? []).cast<String>().toSet(),
  players: [
    for (final p in (json['players'] as List).cast<Map<String, dynamic>>())
      RoomPlayer(
        id: p['id'] as String,
        name: p['name'] as String,
        characterDefinitionId: p['characterDefinitionId'] as String?,
        teamId: p['teamId'] as String?,
      ),
  ],
);

Map<String, Object?> _lobbyJson(Room room) => {
  'version': room.version,
  'draftRequired': room.draftRequired,
  'characterPool': room.characterPool,
  'bans': room.bans,
};
