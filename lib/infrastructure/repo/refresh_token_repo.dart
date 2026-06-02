import 'package:postgres/postgres.dart';
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

class PgRefreshTokenRepo implements RefreshTokenRepo {
  PgRefreshTokenRepo(this._db);

  final DbConnection _db;

  @override
  Future<RefreshTokenRecord> create({
    required int userId,
    required String tokenHash,
    required DateTime expiresAt,
  }) async {
    final result = await _db.pool.execute(
      Sql.named('''
        INSERT INTO refresh_tokens (user_id, token_hash, expires_at)
        VALUES (@userId, @tokenHash, @expiresAt)
        RETURNING
          id,
          user_id,
          token_hash,
          expires_at,
          revoked_at,
          created_at,
          updated_at
      '''),
      parameters: {
        'userId': userId,
        'tokenHash': tokenHash,
        'expiresAt': expiresAt,
      },
    );
    return _fromRow(result.first);
  }

  @override
  Future<RefreshTokenRecord?> findByTokenHash(String tokenHash) async {
    final result = await _db.pool.execute(
      Sql.named('''
        SELECT
          id,
          user_id,
          token_hash,
          expires_at,
          revoked_at,
          created_at,
          updated_at
        FROM refresh_tokens
        WHERE token_hash = @tokenHash
        LIMIT 1
      '''),
      parameters: {'tokenHash': tokenHash},
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first);
  }

  @override
  Future<void> revokeByTokenHash(String tokenHash) => _db.pool.execute(
    Sql.named('''
          UPDATE refresh_tokens
          SET revoked_at = now(), updated_at = now()
          WHERE token_hash = @tokenHash AND revoked_at IS NULL
        '''),
    parameters: {'tokenHash': tokenHash},
  );

  RefreshTokenRecord _fromRow(ResultRow row) => RefreshTokenRecord(
    id: row[0]! as int,
    userId: row[1]! as int,
    tokenHash: row[2]! as String,
    expiresAt: row[3]! as DateTime,
    revokedAt: row[4] as DateTime?,
    createdAt: row[5] as DateTime?,
    updatedAt: row[6] as DateTime?,
  );
}
