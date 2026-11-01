/// Trusted development-only input applied before start, then retained in saves.
/// This is deliberately not accepted by any player command or HTTP endpoint.
final class ScenarioSetup {
  ScenarioSetup(Map<String, Map<String, Object?>> players)
    : players = Map.unmodifiable({
        for (final e in players.entries)
          e.key: _freeze(e.value) as Map<String, Object?>,
      });

  factory ScenarioSetup.fromJson(Map<String, dynamic> json) {
    if (json['scenarioVersion'] != 1 || json['players'] is! Map) {
      throw const FormatException('Unsupported scenario initialization');
    }
    final players = <String, Map<String, Object?>>{};
    for (final e in (json['players'] as Map).entries) {
      if (e.key is! String || e.value is! Map) {
        throw const FormatException('Invalid scenario player');
      }
      players[e.key as String] = Map<String, Object?>.from(e.value as Map);
    }
    return ScenarioSetup(players);
  }

  final Map<String, Map<String, Object?>> players;
  Map<String, Object?> toJson() => {'scenarioVersion': 1, 'players': players};

  static Object? _freeze(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable({
        for (final e in value.entries) e.key as String: _freeze(e.value),
      });
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }
}
