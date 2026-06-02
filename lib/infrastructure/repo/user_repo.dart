import 'package:postgres/postgres.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';

class UserRecord {
  final int id;
  final String username;
  final String passwordHash;
  final String? email;
  final String? phoneNumber;
  final String? pronoun;
  final int permission;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  UserRecord({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.permission,
    this.email,
    this.phoneNumber,
    this.pronoun,
    this.createdAt,
    this.updatedAt,
  });
}

class CreateUserData {
  final String username;
  final String passwordHash;
  final String? email;
  final String? phoneNumber;
  final String? pronoun;
  final int permission;

  CreateUserData({
    required this.username,
    required this.passwordHash,
    this.email,
    this.phoneNumber,
    this.pronoun,
    this.permission = 0,
  });
}

abstract class UserRepo {
  Future<UserRecord> create(CreateUserData data);
  Future<UserRecord?> findById(int id);
  Future<UserRecord?> findByUsername(String username);
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
      passwordHash: data.passwordHash,
      email: data.email,
      phoneNumber: data.phoneNumber,
      pronoun: data.pronoun,
      permission: data.permission,
      createdAt: now,
      updatedAt: now,
    );
    _usersById[user.id] = user;
    return user;
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

class PgUserRepo implements UserRepo {
  PgUserRepo(this._db);

  final DbConnection _db;

  @override
  Future<UserRecord> create(CreateUserData data) async {
    final result = await _db.pool.execute(
      Sql.named('''
        INSERT INTO users (
          username,
          password,
          email,
          phone_number,
          pronoun,
          permission
        )
        VALUES (
          @username,
          @password,
          @email,
          @phoneNumber,
          @pronoun,
          @permission
        )
        RETURNING
          id,
          username,
          password,
          email,
          phone_number,
          pronoun,
          permission,
          created_at,
          updated_at
      '''),
      parameters: {
        'username': data.username,
        'password': data.passwordHash,
        'email': data.email,
        'phoneNumber': data.phoneNumber,
        'pronoun': data.pronoun,
        'permission': data.permission,
      },
    );
    return _fromRow(result.first);
  }

  @override
  Future<UserRecord?> findById(int id) async {
    final result = await _db.pool.execute(
      Sql.named('''
        SELECT
          id,
          username,
          password,
          email,
          phone_number,
          pronoun,
          permission,
          created_at,
          updated_at
        FROM users
        WHERE id = @id
      '''),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first);
  }

  @override
  Future<UserRecord?> findByUsername(String username) async {
    final result = await _db.pool.execute(
      Sql.named('''
        SELECT
          id,
          username,
          password,
          email,
          phone_number,
          pronoun,
          permission,
          created_at,
          updated_at
        FROM users
        WHERE username = @username
        LIMIT 1
      '''),
      parameters: {'username': username},
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first);
  }

  UserRecord _fromRow(ResultRow row) => UserRecord(
    id: row[0]! as int,
    username: row[1]! as String,
    passwordHash: row[2]! as String,
    email: row[3] as String?,
    phoneNumber: row[4] as String?,
    pronoun: row[5] as String?,
    permission: row[6]! as int,
    createdAt: row[7] as DateTime?,
    updatedAt: row[8] as DateTime?,
  );
}
