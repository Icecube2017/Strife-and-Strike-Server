import 'package:sns_server/domain/kernel/kernel.dart';

enum RoomTeamMode { freeForAll, twoTeams, threeTeams }

/// Lobby settings freeze before drafting; only combat settings enter the kernel.
final class RoomRules {
  const RoomRules({
    this.useLegacyDamageFormula = false,
    this.banEnabled = false,
    this.randomSeats = true,
    this.randomCharacters = false,
    this.finalDuel = false,
    this.bansPerPlayer = 1,
    this.teamMode = RoomTeamMode.freeForAll,
    this.responseTimeoutSeconds = 30,
  });
  final bool useLegacyDamageFormula;
  final bool banEnabled;
  final bool randomSeats;
  final bool randomCharacters;
  final bool finalDuel;
  final int bansPerPlayer;
  final RoomTeamMode teamMode;
  static const responseTimeoutOptions = [30, 60, 90, 120];
  final int responseTimeoutSeconds;
  factory RoomRules.fromJson(Object? value, {bool restored = false}) {
    if (value == null) {
      return RoomRules(randomSeats: !restored);
    }
    if (value is! Map<String, dynamic>) {
      throw const FormatException('rules must be an object');
    }
    if (value.keys.any(
      (key) => !{
        'useLegacyDamageFormula',
        'banEnabled',
        'randomSeats',
        'randomCharacters',
        'finalDuel',
        'bansPerPlayer',
        'teamMode',
        'responseTimeoutSeconds',
      }.contains(key),
    )) {
      throw const FormatException('Unknown room rule');
    }
    for (final key in [
      'useLegacyDamageFormula',
      'banEnabled',
      'randomSeats',
      'randomCharacters',
      'finalDuel',
    ]) {
      if (value[key] != null && value[key] is! bool) {
        throw FormatException('$key must be boolean');
      }
    }
    final bans = value['bansPerPlayer'] ?? 1;
    if (bans is! int || bans < 0 || bans > 82) {
      throw const FormatException('bansPerPlayer must be between 0 and 82');
    }
    final mode = value['teamMode'] ?? 'freeForAll';
    final timeout = value['responseTimeoutSeconds'] ?? 30;
    if (timeout is! int || !responseTimeoutOptions.contains(timeout)) {
      throw const FormatException('Invalid responseTimeoutSeconds');
    }
    if (mode is! String || !RoomTeamMode.values.any((m) => m.name == mode)) {
      throw const FormatException('Invalid teamMode');
    }
    return RoomRules(
      useLegacyDamageFormula: value['useLegacyDamageFormula'] as bool? ?? false,
      banEnabled: value['banEnabled'] as bool? ?? false,
      randomSeats: value['randomSeats'] as bool? ?? !restored,
      randomCharacters: value['randomCharacters'] as bool? ?? false,
      finalDuel: value['finalDuel'] as bool? ?? false,
      bansPerPlayer: bans,
      teamMode: RoomTeamMode.values.byName(mode),
      responseTimeoutSeconds: timeout,
    );
  }
  Map<String, Object?> toJson() => {
    'useLegacyDamageFormula': useLegacyDamageFormula,
    'banEnabled': banEnabled,
    'randomSeats': randomSeats,
    'randomCharacters': randomCharacters,
    'finalDuel': finalDuel,
    'bansPerPlayer': bansPerPlayer,
    'teamMode': teamMode.name,
    'responseTimeoutSeconds': responseTimeoutSeconds,
  };
  GameRules applyTo(GameRules defaults) => defaults.withLegacyDamageFormula(
    enabled: useLegacyDamageFormula,
    responseTimeoutSeconds: responseTimeoutSeconds,
    duelEnabled: finalDuel,
    duelRound: 12,
    duelAttackBonus: 0,
    duelHealingMultiplier: 1,
    duelDamageMultiplier: 1.5,
  );
}
