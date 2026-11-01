import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// One local connection for a single server process. Schema upgrades are atomic.
class DbConnection {
  DbConnection._(this.database);
  final Database database;
  static Future<DbConnection> open({
    String path = 'data/server/sns.sqlite',
  }) async {
    if (path.trim().isEmpty) throw ArgumentError.value(path, 'path');
    if (path != ':memory:') {
      await File(path).absolute.parent.create(recursive: true);
    }
    final db = sqlite3.open(path);
    try {
      db
        ..execute('PRAGMA foreign_keys = ON')
        ..execute('PRAGMA busy_timeout = 5000');
      final version =
          db.select('PRAGMA user_version').first.values.first! as int;
      if (version > 2) {
        throw StateError('SQLite schema is newer than this server');
      }
      db
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('PRAGMA synchronous = FULL');
      if (version == 0) {
        db.execute('BEGIN IMMEDIATE');
        try {
          db
            ..execute('''
            CREATE TABLE users (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              username TEXT NOT NULL UNIQUE,
              password TEXT NOT NULL,
              permission INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE TABLE refresh_tokens (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              user_id INTEGER NOT NULL REFERENCES users(id),
              token_hash TEXT NOT NULL UNIQUE,
              expires_at TEXT NOT NULL,
              revoked_at TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            CREATE INDEX refresh_tokens_user_id ON refresh_tokens(user_id);
            CREATE TABLE rooms (
              id TEXT PRIMARY KEY NOT NULL,
              room_code TEXT UNIQUE,
              snapshot TEXT NOT NULL
            );
            CREATE TABLE game_checkpoints (
              id TEXT PRIMARY KEY NOT NULL,
              version INTEGER NOT NULL CHECK(version >= 0),
              finished INTEGER NOT NULL CHECK(finished IN (0, 1)),
              checkpoint TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );
            PRAGMA user_version = 1;
          ''')
            ..execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
      if (version < 2) {
        db.execute('BEGIN IMMEDIATE');
        try {
          db
            ..execute('ALTER TABLE users ADD COLUMN nickname TEXT')
            ..execute('UPDATE users SET nickname = username')
            ..execute('PRAGMA user_version = 2')
            ..execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
      return DbConnection._(db);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  Future<void> close() async => database.close();
}
