import 'dart:math' as math;

import 'package:sns_kernel/sns_kernel.dart';

/// Training-only feedback. Matches the client MatchRating policy (2026-10-30),
/// including enemy-only damage and excluding shield absorption from received.
/// Never inserted into the policy's observation or consulted for legality.
Map<String, Object?> aiRatingFeedback(GameKernel game, String learnerId) {
  final statistics = game.statisticsView();
  final player = game.state.players.singleWhere((p) => p.id == learnerId);
  final id = player.character.instanceId;
  final teams = {
    for (final p in game.state.players) p.character.instanceId: p.teamId,
  };
  double number(Object? v) =>
      v is num && v.isFinite && v >= 0 ? v.toDouble() : 0;
  var damage = 0.0;
  var received = 0.0;
  for (final raw in statistics['pairs']! as List) {
    final pair = raw as Map;
    final source = pair['sourceId'];
    final target = pair['targetId'];
    if (!teams.containsKey(source) ||
        !teams.containsKey(target) ||
        source == target ||
        teams[source] == teams[target]) {
      continue;
    }
    final amounts = pair['damage'] as Map? ?? {};
    final hp = number(amounts['hpLost']);
    final converted = number(amounts['convertedToDefense']);
    if (source == id) {
      damage += hp + converted + number(amounts['shieldAbsorbed']);
    }
    if (target == id) received += hp + converted;
  }
  final support =
      ((statistics['bySource']! as Map)[id] as Map)['support'] as Map;
  final control = number(support['control']);
  final enhancement = number(support['enhancement']);
  final rating =
      .35 * math.sqrt(damage / 10) +
      .25 * math.sqrt(received / 10) +
      .2 * math.sqrt(control) +
      .2 * math.sqrt(enhancement);
  return {
    'ratingPolicy': 'client-match-rating-20261030',
    'rating': rating,
    'damage': damage,
    'received': received,
    'control': control,
    'enhancement': enhancement,
  };
}
