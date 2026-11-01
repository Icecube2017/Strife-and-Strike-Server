import 'package:sns_server/infrastructure/db/db_connection.dart';

class RefreshTokenRecord {
  final int id;
  final int userId;
  final String tokenHash;
  final DateTime expiresAt;
  final DateTime? revokedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  RefreshTokenRecord({
    required this.id,
    required this.userId,
    required this.tokenHash,
    required this.expiresAt,
    this.revokedAt,
    this.createdAt,
    this.updatedAt,
  });

  bool get isActive => revokedAt == null && expiresAt.isAfter(DateTime.now());
}

abstract class RefreshTokenRepo {
  Future<RefreshTokenRecord> create({
    required int userId,
    required String tokenHash,
    required DateTime expiresAt,
  });

  Future<RefreshTokenRecord?> findByTokenHash(String tokenHash);
  Future<void> revokeByTokenHash(String tokenHash);
}

class InMemoryRefreshTokenRepo implements RefreshTokenRepo {
  final Map<String, RefreshTokenRecord> _tokensByHash = {};
  int _nextId = 1;

  @override
  Future<RefreshTokenRecord> create({
    required int userId,
    required String tokenHash,
    required DateTime expiresAt,
  }) async {
    final now = DateTime.now();
    final record = RefreshTokenRecord(
      id: _nextId++,
      userId: userId,
      tokenHash: tokenHash,
      expiresAt: expiresAt,
      createdAt: now,
      updatedAt: now,
    );
    _tokensByHash[tokenHash] = record;
    return record;
  }

  @override
  Future<RefreshTokenRecord?> findByTokenHash(String tokenHash) async =>
      _tokensByHash[tokenHash];

  @override
  Future<void> revokeByTokenHash(String tokenHash) async {
    final existing = _tokensByHash[tokenHash];
    if (existing == null) return;
    final now = DateTime.now();
    _tokensByHash[tokenHash] = RefreshTokenRecord(
      id: existing.id,
      userId: existing.userId,
      tokenHash: existing.tokenHash,
      expiresAt: existing.expiresAt,
      revokedAt: now,
      createdAt: existing.createdAt,
      updatedAt: now,
    );
  }
}

class SqliteRefreshTokenRepo implements RefreshTokenRepo {
  SqliteRefreshTokenRepo(this._db);
  final DbConnection _db;
  @override
  Future<RefreshTokenRecord> create({
    required int userId,
    required String tokenHash,
    required DateTime expiresAt,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.database.execute(
      'INSERT INTO refresh_tokens (user_id, token_hash, expires_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
      [userId, tokenHash, expiresAt.toUtc().toIso8601String(), now, now],
    );
    return (await findByTokenHash(tokenHash))!;
  }

  @override
  Future<RefreshTokenRecord?> findByTokenHash(String tokenHash) async {
    final rows = _db.database.select(
      'SELECT * FROM refresh_tokens WHERE token_hash = ?',
      [tokenHash],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return RefreshTokenRecord(
      id: row['id']! as int,
      userId: row['user_id']! as int,
      tokenHash: row['token_hash']! as String,
      expiresAt: DateTime.parse(row['expires_at']! as String),
      revokedAt: row['revoked_at'] == null
          ? null
          : DateTime.parse(row['revoked_at']! as String),
      createdAt: DateTime.parse(row['created_at']! as String),
      updatedAt: DateTime.parse(row['updated_at']! as String),
    );
  }

  @override
  Future<void> revokeByTokenHash(String tokenHash) async {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.database.execute(
      'UPDATE refresh_tokens SET revoked_at = ?, updated_at = ? WHERE token_hash = ? AND revoked_at IS NULL',
      [now, now, tokenHash],
    );
  }
}
