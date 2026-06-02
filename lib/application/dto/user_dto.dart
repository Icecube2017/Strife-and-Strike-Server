class RegisterUserRequest {
  final String username;
  final String password;
  final String? email;
  final String? phoneNumber;
  final String? pronoun;

  RegisterUserRequest({
    required this.username,
    required this.password,
    this.email,
    this.phoneNumber,
    this.pronoun,
  });

  factory RegisterUserRequest.fromJson(Map<String, dynamic> json) =>
      RegisterUserRequest(
        username: json['username'] as String,
        password: json['password'] as String,
        email: json['email'] as String?,
        phoneNumber: json['phoneNumber'] as String?,
        pronoun: json['pronoun'] as String?,
      );
}

class LoginUserRequest {
  final String username;
  final String password;

  LoginUserRequest({
    required this.username,
    required this.password,
  });

  factory LoginUserRequest.fromJson(Map<String, dynamic> json) =>
      LoginUserRequest(
        username: json['username'] as String,
        password: json['password'] as String,
      );
}

class RefreshTokenRequest {
  final String refreshToken;

  RefreshTokenRequest({required this.refreshToken});

  factory RefreshTokenRequest.fromJson(Map<String, dynamic> json) =>
      RefreshTokenRequest(refreshToken: json['refreshToken'] as String);
}

class UserView {
  final int id;
  final String username;
  final String? email;
  final String? phoneNumber;
  final String? pronoun;
  final int permission;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  UserView({
    required this.id,
    required this.username,
    required this.permission,
    this.email,
    this.phoneNumber,
    this.pronoun,
    this.createdAt,
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    if (email != null) 'email': email,
    if (phoneNumber != null) 'phoneNumber': phoneNumber,
    if (pronoun != null) 'pronoun': pronoun,
    'permission': permission,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };
}

class AuthResponse {
  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final int expiresIn;
  final UserView user;

  AuthResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.user,
    this.tokenType = 'Bearer',
  });

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'token': accessToken,
    'tokenType': tokenType,
    'expiresIn': expiresIn,
    'user': user.toJson(),
  };
}
