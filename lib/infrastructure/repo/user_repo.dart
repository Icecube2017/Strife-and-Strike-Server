import 'package:sns_server/infrastructure/db/db_connection.dart';

class UserRecord {
  final int id;
  final String username;
  final String? nickname;
  String get displayName => nickname ?? username;
  final String passwordHash;
  final int permission;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  UserRecord({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.permission,
    this.nickname,
    this.createdAt,
    this.updatedAt,
  });
}

class CreateUserData {
  final String username;
  final String? nickname;
  String get displayName => nickname ?? username;
  final String passwordHash;
  final int permission;

  CreateUserData({
    required this.username,
    required this.passwordHash,
    this.nickname,
    this.permission = 0,
  });
}

abstract class UserRepo {
  Future<UserRecord> create(CreateUserData data);
  Future<UserRecord?> findById(int id);
  Future<UserRecord?> findByUsername(String username);
  Future<UserRecord> updateNickname(int id, String nickname);
}

class InMemoryUserRepo implements UserRepo {
  final Map<int, UserRecord> _usersById = {};
  int _nextId = 1;

  @override
  Future<UserRecord> create(CreateUserData data) async {
    final now = DateTime.now();
    final user = UserRecord(
      id: _nextId++,
      username: data.username,
      nickname: data.displayName,
      passwordHash: data.passwordHash,
      permission: data.permission,
      createdAt: now,
      updatedAt: now,
    );
    _usersById[user.id] = user;
    return user;
  }

  @override
  Future<UserRecord> updateNickname(int id, String nickname) async {
    final old = _usersById[id]!;
    return _usersById[id] = UserRecord(
      id: id,
      username: old.username,
      passwordHash: old.passwordHash,
      permission: old.permission,
      nickname: nickname,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<UserRecord?> findById(int id) async => _usersById[id];

  @override
  Future<UserRecord?> findByUsername(String username) async {
    for (final user in _usersById.values) {
      if (user.username == username) return user;
    }
    return null;
  }
}

class SqliteUserRepo implements UserRepo {
  SqliteUserRepo(this._db);
  final DbConnection _db;
  @override
  Future<UserRecord> create(CreateUserData data) async {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.database.execute(
      'INSERT INTO users (username, password, permission, created_at, updated_at, nickname) VALUES (?, ?, ?, ?, ?, ?)',
      [
        data.username,
        data.passwordHash,
        data.permission,
        now,
        now,
        data.displayName,
      ],
    );
    return (await findById(_db.database.lastInsertRowId))!;
  }

  @override
  Future<UserRecord?> findById(int id) async {
    final rows = _db.database.select('SELECT * FROM users WHERE id = ?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<UserRecord?> findByUsername(String username) async {
    final rows = _db.database.select('SELECT * FROM users WHERE username = ?', [
      username,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<UserRecord> updateNickname(int id, String nickname) async {
    _db.database.execute(
      'UPDATE users SET nickname = ?, updated_at = ? WHERE id = ?',
      [nickname, DateTime.now().toUtc().toIso8601String(), id],
    );
    return (await findById(id))!;
  }

  UserRecord _fromRow(Map<String, Object?> row) => UserRecord(
    nickname: row['nickname'] as String?,
    id: row['id']! as int,
    username: row['username']! as String,
    passwordHash: row['password']! as String,
    permission: row['permission']! as int,
    createdAt: DateTime.parse(row['created_at']! as String),
    updatedAt: DateTime.parse(row['updated_at']! as String),
  );
}
