import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:sns_server/application/content/client_content.dart';
import 'package:sns_server/application/content/content_loader.dart';
import 'package:sns_server/application/dto/api_error.dart';
import 'package:sns_server/application/services/auth_service.dart';
import 'package:sns_server/application/services/game_service.dart';
import 'package:sns_server/application/services/kernel_game_service.dart';
import 'package:sns_server/application/services/room_service.dart';
import 'package:sns_server/infrastructure/clock_rng/clock.dart';
import 'package:sns_server/infrastructure/clock_rng/rng.dart';
import 'package:sns_server/infrastructure/db/db_connection.dart';
import 'package:sns_server/infrastructure/repo/game_abort_store.dart';
import 'package:sns_server/infrastructure/repo/game_checkpoint_repo.dart';
import 'package:sns_server/infrastructure/repo/refresh_token_repo.dart';
import 'package:sns_server/infrastructure/repo/room_expiry_store.dart';
import 'package:sns_server/infrastructure/repo/room_repo.dart';
import 'package:sns_server/infrastructure/repo/user_repo.dart';

// SQLite and service singletons, lazily initialized once per server process.
late final DbConnection _db;
late final RoomRepo _roomRepo;
late final UserRepo _userRepo;
late final RefreshTokenRepo _refreshTokenRepo;
late final AuthService _authService;
late final RoomService _roomService;
late final GameService _gameService;
late final KernelGameService _kernelService;
late final ClientContent _clientContent;

Future<void>? _initialization;
bool _disposed = false;

/// Call after closing the HTTP listener to release timers, streams and SQLite.
Future<void> disposeServices() async {
  if (_disposed || _initialization == null) return;
  await _initialization;
  _disposed = true;
  _roomService.dispose();
  _kernelService.dispose();
  await _db.close();
}

Future<void> _init() => _initialization ??= _initializeServices();

Future<void> _initializeServices() async {
  _db = await DbConnection.open(
    path: Platform.environment['SQLITE_PATH'] ?? 'data/server/sns.sqlite',
  );

  _roomRepo = SqliteRoomRepo(_db);
  _userRepo = SqliteUserRepo(_db);
  _refreshTokenRepo = SqliteRefreshTokenRepo(_db);
  _authService = AuthService(
    _userRepo,
    _refreshTokenRepo,
    jwtSecret: Platform.environment['JWT_SECRET'] ?? 'dev_secret_change_me',
  );
  _roomService = RoomService(
    _roomRepo,
    onExpirationError: (id, error, stack) =>
        stderr.writeln('Room expiration failed: roomId=$id; $error'),
  );
  final contentSource = await File(
    Platform.environment['GAME_CONTENT_PATH'] ?? 'content/content_items.json',
  ).readAsString();
  final content = ExecutableContent.decode(
    contentSource,
    deckId: Platform.environment['GAME_DECK_ID'],
  );
  _clientContent = ClientContent(
    contentSource,
    deckId: content.selectedDeck.id,
  );
  if (content.unsupportedDeckCards.isNotEmpty) {
    stderr.writeln(
      'Deck ${content.selectedDeck.id}: '
      '${content.playableDeck.length}/${content.deck.length} playable cards; '
      'unimplemented cards excluded: ${content.unsupportedDeckCards}',
    );
  }
  final kernel = _kernelService = KernelGameService(
    content.catalog,
    contentSource: contentSource,
    checkpointRepo: SqliteGameCheckpointRepo(_db),
    onPersistenceError: (error, stack) =>
        stderr.writeln('Game checkpoint persistence failed: $error'),
    onRecoveryError: (id, error, stack) =>
        stderr.writeln('Game checkpoint recovery failed: gameId=$id; $error'),
  );
  await _roomService.restoreRooms();
  await kernel.restoreGames();
  await _roomService.reconcileGames(kernel.hasGameRecord);
  _gameService = GameService(
    _roomService,
    kernel,
    deck: content.playableDeck,
    commonSkills: content.skillPool,
    abortStore: SqliteGameAbortStore(_db),
    expiryStore: SqliteRoomExpiryStore(_db),
  );
  await _gameService.startRoomExpiration();
  await _gameService.resumeCompletedDrafts();
}

Handler middleware(Handler handler) {
  return (context) async {
    await _init();
    return handler
        .use(provider<RoomService>((_) => _roomService))
        .use(provider<GameService>((_) => _gameService))
        .use(provider<ClientContent>((_) => _clientContent))
        .use(provider<AuthService>((_) => _authService))
        .use(provider<RoomRepo>((_) => _roomRepo))
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
      return await handler
          .use(provider<AuthenticatedUser>((_) => user))
          .call(context);
    } on AuthException catch (e) {
      return Response.json(
        statusCode: e.statusCode,
        body: apiError(
          e,
          code: e.statusCode == 401
              ? 'authenticationFailed'
              : 'authenticationRejected',
        ),
      );
    }
  };
}

bool _isPublicPath(String path) =>
    path == '/api/v1/content' ||
    path.endsWith('/health') ||
    path.endsWith('/auth') ||
    path.endsWith('/auth/login') ||
    path.endsWith('/auth/register') ||
    path.endsWith('/auth/refresh') ||
    path.endsWith('/auth/logout');
