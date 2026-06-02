import 'package:postgres/postgres.dart';

/// 全局连接池，_middleware.dart 中初始化并注入
class DbConnection {
  DbConnection._(this.pool);

  final Pool pool;

  static Future<DbConnection> open({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
    int maxConnections = 10,
  }) async {
    final endpoint = Endpoint(
      host: host,        
      port: port,
      database: database,
      username: username,
      password: password,      );
    final pool = Pool.withEndpoints(
      [endpoint],
      settings: PoolSettings(maxConnectionCount: maxConnections),
    );
    return DbConnection._(pool);
  }

  Future<void> close() => pool.close();
}
