import 'dart:convert';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:sns_server/application/dto/user_dto.dart';
import 'package:sns_server/infrastructure/repo/refresh_token_repo.dart';
import 'package:sns_server/infrastructure/repo/user_repo.dart';

class AuthException implements Exception {
  final int statusCode;
  final String message;

  AuthException(this.message, {this.statusCode = 400});

  @override
  String toString() => message;
}

class AuthenticatedUser {
  final int id;
  final String username;
  final String? email;
  final String? phoneNumber;
  final String? pronoun;
  final int permission;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  AuthenticatedUser({
    required this.id,
    required this.username,
    required this.permission,
    this.email,
    this.phoneNumber,
    this.pronoun,
    this.createdAt,
    this.updatedAt,
  });

  UserView toView() => UserView(
    id: id,
    username: username,
    permission: permission,
    email: email,
    phoneNumber: phoneNumber,
    pronoun: pronoun,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class AuthService {
  AuthService(
    this._users,
    this._refreshTokens, {
    required String jwtSecret,
    this.accessTokenTtl = const Duration(hours: 1),
    this.refreshTokenTtl = const Duration(days: 30),
  }) : _jwtSecret = jwtSecret;

  final UserRepo _users;
  final RefreshTokenRepo _refreshTokens;
  final String _jwtSecret;
  final Duration accessTokenTtl;
  final Duration refreshTokenTtl;
  final Random _random = Random.secure();

  Future<AuthResponse> register(RegisterUserRequest request) async {
    _validateUsername(request.username);
    _validatePassword(request.password);

    final existing = await _users.findByUsername(request.username);
    if (existing != null) {
      throw AuthException('Username already exists', statusCode: 409);
    }

    final passwordHash = BCrypt.hashpw(request.password, BCrypt.gensalt());
    final user = await _users.create(
      CreateUserData(
        username: request.username,
        passwordHash: passwordHash,
        email: _blankToNull(request.email),
        phoneNumber: _blankToNull(request.phoneNumber),
        pronoun: _blankToNull(request.pronoun),
      ),
    );
    return _issueAuthResponse(_toAuthenticatedUser(user));
  }

  Future<AuthResponse> login(LoginUserRequest request) async {
    final user = await _users.findByUsername(request.username);
    if (user == null || !BCrypt.checkpw(request.password, user.passwordHash)) {
      throw AuthException('Invalid username or password', statusCode: 401);
    }
    return _issueAuthResponse(_toAuthenticatedUser(user));
  }

  Future<AuthResponse> refresh(RefreshTokenRequest request) async {
    final tokenHash = _hashRefreshToken(request.refreshToken);
    final record = await _refreshTokens.findByTokenHash(tokenHash);
    if (record == null || !record.isActive) {
      throw AuthException('Invalid refresh token', statusCode: 401);
    }

    final user = await _users.findById(record.userId);
    if (user == null) {
      throw AuthException('User not found', statusCode: 401);
    }

    await _refreshTokens.revokeByTokenHash(tokenHash);
    return _issueAuthResponse(_toAuthenticatedUser(user));
  }

  Future<AuthenticatedUser> verifyBearer(String? authorizationHeader) async {
    final token = _extractBearerToken(authorizationHeader);
    final claims = _verifyAccessToken(token);
    final subject = claims['sub'] as String?;
    if (subject == null) {
      throw AuthException('Invalid token subject', statusCode: 401);
    }

    final userId = int.tryParse(subject);
    if (userId == null) {
      throw AuthException('Invalid token subject', statusCode: 401);
    }

    final user = await _users.findById(userId);
    if (user == null) {
      throw AuthException('User not found', statusCode: 401);
    }
    return _toAuthenticatedUser(user);
  }

  Future<void> logout(RefreshTokenRequest request) async {
    await _refreshTokens.revokeByTokenHash(
      _hashRefreshToken(request.refreshToken),
    );
  }

  Future<AuthResponse> _issueAuthResponse(AuthenticatedUser user) async {
    final accessToken = _signAccessToken(user);
    final refreshToken = _generateSecureToken();
    await _refreshTokens.create(
      userId: user.id,
      tokenHash: _hashRefreshToken(refreshToken),
      expiresAt: DateTime.now().toUtc().add(refreshTokenTtl),
    );
    return AuthResponse(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: accessTokenTtl.inSeconds,
      user: user.toView(),
    );
  }

  String _generateSecureToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return _base64UrlNoPadding(bytes);
  }

  String _signAccessToken(AuthenticatedUser user) {
    final now = DateTime.now().toUtc();
    final issuedAt = now.millisecondsSinceEpoch ~/ 1000;
    final expiresAt = now.add(accessTokenTtl).millisecondsSinceEpoch ~/ 1000;
    final header = _base64UrlJson({'alg': 'HS256', 'typ': 'JWT'});
    final payload = _base64UrlJson({
      'iss': 'sns_server',
      'sub': user.id.toString(),
      'username': user.username,
      'permission': user.permission,
      'iat': issuedAt,
      'exp': expiresAt,
    });
    final signingInput = '$header.$payload';
    final signature = _sign(signingInput);
    return '$signingInput.$signature';
  }

  Map<String, dynamic> _verifyAccessToken(String token) {
    final parts = token.split('.');
    if (parts.length != 3) {
      throw AuthException('Invalid token', statusCode: 401);
    }

    final signingInput = '${parts[0]}.${parts[1]}';
    final expectedSignature = _sign(signingInput);
    if (!_constantTimeEquals(expectedSignature, parts[2])) {
      throw AuthException('Invalid token signature', statusCode: 401);
    }

    try {
      final header =
          jsonDecode(utf8.decode(base64Url.decode(_padBase64(parts[0]))))
              as Map<String, dynamic>;
      if (header['alg'] != 'HS256') {
        throw AuthException('Unsupported token algorithm', statusCode: 401);
      }

      final payload =
          jsonDecode(utf8.decode(base64Url.decode(_padBase64(parts[1]))))
              as Map<String, dynamic>;
      final exp = payload['exp'] as int?;
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      if (exp == null || exp <= now) {
        throw AuthException('Token expired', statusCode: 401);
      }
      return payload;
    } on AuthException {
      rethrow;
    } on Object {
      throw AuthException('Invalid token payload', statusCode: 401);
    }
  }

  String _sign(String signingInput) {
    final mac = Hmac(sha256, utf8.encode(_jwtSecret));
    return _base64UrlNoPadding(
      mac.convert(utf8.encode(signingInput)).bytes,
    );
  }

  String _base64UrlJson(Map<String, dynamic> value) =>
      _base64UrlNoPadding(utf8.encode(jsonEncode(value)));

  String _base64UrlNoPadding(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  String _padBase64(String value) {
    final padding = value.length % 4;
    if (padding == 0) return value;
    return value.padRight(value.length + (4 - padding), '=');
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  String _extractBearerToken(String? authorizationHeader) {
    if (authorizationHeader == null ||
        !authorizationHeader.startsWith('Bearer ')) {
      throw AuthException('Unauthorized', statusCode: 401);
    }
    final token = authorizationHeader.substring('Bearer '.length).trim();
    if (token.isEmpty) {
      throw AuthException('Unauthorized', statusCode: 401);
    }
    return token;
  }

  String _hashRefreshToken(String refreshToken) {
    return sha256.convert(utf8.encode(refreshToken)).toString();
  }

  AuthenticatedUser _toAuthenticatedUser(UserRecord user) => AuthenticatedUser(
    id: user.id,
    username: user.username,
    permission: user.permission,
    email: user.email,
    phoneNumber: user.phoneNumber,
    pronoun: user.pronoun,
    createdAt: user.createdAt,
    updatedAt: user.updatedAt,
  );

  void _validateUsername(String username) {
    if (username.trim().isEmpty) {
      throw AuthException('Username is required');
    }
    if (username.length > 64) {
      throw AuthException('Username is too long');
    }
  }

  void _validatePassword(String password) {
    if (password.length < 8) {
      throw AuthException('Password must be at least 8 characters');
    }
    if (utf8.encode(password).length > 72) {
      throw AuthException('Password is too long for bcrypt');
    }
  }

  String? _blankToNull(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }
}
