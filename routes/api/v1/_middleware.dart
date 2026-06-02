import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/cache/game_cache.dart';
import 'package:sns_server/infrastructure/clock_rng/clock.dart';
import 'package:sns_server/infrastructure/clock_rng/rng.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';
import 'package:sns_server/infrastructure/messaging/sse_messaging.dart';
import 'package:sns_server/infrastructure/repo/game_repo.dart';
import 'package:sns_server/infrastructure/repo/refresh_token_repo.dart';
import 'package:sns_server/infrastructure/repo/room_repo.dart';
import 'package:sns_server/infrastructure/repo/user_repo.dart';

// 连接池和服务单例，由 _init() 懒初始化
late final DbConnection _db;
late final RoomRepo _roomRepo;
late final GameRepo _gameRepo;
late final UserRepo _userRepo;
late final RefreshTokenRepo _refreshTokenRepo;
late final AuthService _authService;
late final RoomService _roomService;
late final GameService _gameService;
late final SseMessaging _sseMessaging;
late final GameCache _gameCache;

bool _initialized = false;

Future<void> _init() async {
  if (_initialized) return;
  _initialized = true;

  _db = await DbConnection.open(
    host: Platform.environment['PG_HOST'] ?? 'localhost',
    port: int.parse(Platform.environment['PG_PORT'] ?? '5432'),
    database: Platform.environment['PG_DB'] ?? '',
    username: Platform.environment['PG_USER'] ?? '',
    password: Platform.environment['PG_PASS'] ?? '',
  );

  _roomRepo = PgRoomRepo(_db);
  _gameRepo = PgGameRepo(_db);
  _userRepo = PgUserRepo(_db);
  _refreshTokenRepo = PgRefreshTokenRepo(_db);
  _authService = AuthService(
    _userRepo,
    _refreshTokenRepo,
    jwtSecret: Platform.environment['JWT_SECRET'] ?? 'dev_secret_change_me',
  );
  _roomService = RoomService(_roomRepo);
  _gameService = GameService(_roomService);
  _sseMessaging = SseMessaging();
  _gameCache = GameCache();
}

Handler middleware(Handler handler) {
  return (context) async {
    await _init();
    return handler
        .use(provider<RoomService>((_) => _roomService))
        .use(provider<GameService>((_) => _gameService))
        .use(provider<AuthService>((_) => _authService))
        .use(provider<SseMessaging>((_) => _sseMessaging))
        .use(provider<GameCache>((_) => _gameCache))
        .use(provider<RoomRepo>((_) => _roomRepo))
        .use(provider<GameRepo>((_) => _gameRepo))
        .use(provider<UserRepo>((_) => _userRepo))
        .use(provider<RefreshTokenRepo>((_) => _refreshTokenRepo))
        .use(provider<AppClock>((_) => const SystemClock()))
        .use(provider<AppRng>((_) => SystemRng()))
        .use(_authMiddleware)
        .call(context);
  };
}

Handler _authMiddleware(Handler handler) {
  return (context) async {
    final path = context.request.uri.path;
    if (_isPublicPath(path)) {
      return handler(context);
    }

    try {
      final user = await _authService.verifyBearer(
        context.request.headers['Authorization'],
      );
      return handler
          .use(provider<AuthenticatedUser>((_) => user))
          .call(context);
    } on AuthException catch (e) {
      return Response.json(
        statusCode: e.statusCode,
        body: {'error': e.message},
      );
    }
  };
}

bool _isPublicPath(String path) =>
    path.endsWith('/health') ||
    path.endsWith('/auth') ||
    path.endsWith('/auth/login') ||
    path.endsWith('/auth/register') ||
    path.endsWith('/auth/refresh') ||
    path.endsWith('/auth/logout');
