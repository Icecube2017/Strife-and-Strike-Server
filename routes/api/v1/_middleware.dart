import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/cache/game_cache.dart';
import 'package:sns_server/infrastructure/clock_rng/clock.dart';
import 'package:sns_server/infrastructure/clock_rng/rng.dart';
import 'package:sns_server/infrastructure/messaging/sse_messaging.dart';
import 'package:sns_server/infrastructure/repo/game_repo.dart';
import 'package:sns_server/infrastructure/repo/room_repo.dart';

// 单例，整个进程共享
final _roomRepo = InMemoryRoomRepo();
final _gameRepo = InMemoryGameRepo();
final _roomService = RoomService();
final _gameService = GameService(_roomService);
final _sseMessaging = SseMessaging();
final _gameCache = GameCache();
final _clock = SystemClock();
final _rng = SystemRng();

Handler middleware(Handler handler) {
  return handler
      .use(provider<RoomService>((_) => _roomService))
      .use(provider<GameService>((_) => _gameService))
      .use(provider<SseMessaging>((_) => _sseMessaging))
      .use(provider<GameCache>((_) => _gameCache))
      .use(provider<RoomRepo>((_) => _roomRepo))
      .use(provider<GameRepo>((_) => _gameRepo))
      .use(provider<AppClock>((_) => _clock))
      .use(provider<AppRng>((_) => _rng))
      .use(_authMiddleware);
}

// 鉴权中间件（Structure.md §4：_middleware 鉴权、日志、trace id）
Handler _authMiddleware(Handler handler) {
  return (context) async {
    final path = context.request.uri.path;
    // /health 和 /auth 不需要鉴权
    if (path.endsWith('/health') || path.contains('/auth')) {
      return handler(context);
    }
    final token = context.request.headers['Authorization'];
    if (token == null || !token.startsWith('Bearer ')) {
      return Response.json(
        statusCode: 401,
        body: {'error': 'Unauthorized'},
      );
    }
    // TODO: 验证 JWT；此处仅检查存在性
    return handler(context);
  };
}
