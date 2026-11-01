import 'package:sns_kernel/sns_kernel.dart';

abstract interface class AiPolicy {
  String get id;
  AiSelection select(AiDecision decision);
  Map<String, Object?> checkpoint();
}

AiPolicy restoreAiPolicy(Map<String, dynamic> saved) {
  final id = saved['policyId'];
  if (id == 'random-v1') {
    final state = saved['state'];
    if (state is! int || state < 1 || state >= 2147483647) {
      throw const FormatException('Invalid policy RNG state');
    }
    return AiRandomPolicy(1).._state = state;
  }
  if (id == 'rules-v1') {
    final random = restoreAiPolicy(
      Map<String, dynamic>.from(saved['random'] as Map),
    );
    return AiRulePolicy._(random as AiRandomPolicy);
  }
  throw const FormatException('Unsupported opponent policy checkpoint');
}

final class AiSelection {
  const AiSelection(this.index, this.score, this.reason);
  final int index;
  final double score;
  final String reason;
}

/// Separate deterministic RNG: a policy never reads the game's RNG or seed.
final class AiRandomPolicy implements AiPolicy {
  AiRandomPolicy(int seed) : _state = seed.abs() % 2147483646 + 1;
  int _state;
  @override
  String get id => 'random-v1';
  @override
  Map<String, Object?> checkpoint() => {'policyId': id, 'state': _state};
  int next(int maximum) {
    _state = (_state * 48271) % 2147483647;
    return _state % maximum;
  }

  @override
  AiSelection select(AiDecision decision) =>
      AiSelection(next(decision.candidates.length), 0, 'uniformLegalCandidate');
}

/// A transparent baseline, not a learned model or damage-preview oracle.
final class AiRulePolicy implements AiPolicy {
  AiRulePolicy(int seed) : _random = AiRandomPolicy(seed);
  AiRulePolicy._(this._random);
  final AiRandomPolicy _random;
  @override
  String get id => 'rules-v1';
  @override
  Map<String, Object?> checkpoint() => {
    'policyId': id,
    'random': _random.checkpoint(),
  };
  @override
  AiSelection select(AiDecision decision) {
    final scores = [for (final c in decision.candidates) _score(decision, c)];
    final best = scores.reduce((a, b) => a > b ? a : b);
    final ties = [
      for (var i = 0; i < scores.length; i++)
        if (scores[i] == best) i,
    ];
    return AiSelection(
      ties[_random.next(ties.length)],
      best,
      'visibleResourcesAndEffects',
    );
  }

  double _score(AiDecision d, AiCandidate c) {
    if (c.kind == 'selectCard') {
      if (c.features['canCommit'] != true) return -10002;
      if (d.candidates.any((entry) => entry.kind == 'playCards')) return -10003;
    }
    if (c.kind == 'unselectCard') return -10004;
    if (c.kind == 'cancelCardSelection') return -10001;
    final f = c.features;
    final public = d.observation['public']! as Map;
    final private = d.observation['private']! as Map;
    final players = (public['players']! as List).cast<Map<String, dynamic>>();
    final own = players.singleWhere((p) => p['playerId'] == d.actorId);
    num number(Map<String, dynamic> row, String key) =>
        row[key] is num ? row[key] as num : 0;
    switch (c.kind) {
      case 'yield':
      case 'endTurn':
      case 'pass':
        return 0;
      case 'cancelAbility':
        return -10;
      case 'confirmAbility':
        return 20;
      case 'beginResponse':
        return -5;
      case 'respondCard':
        return 25;
      case 'recordAction':
        return 2;
      case 'choose':
        final option = f['option']! as Map;
        if (option['skip'] == true ||
            option['done'] == true ||
            const {'skip', 'pass', 'done'}.contains(option['action'])) {
          return -1;
        }
        return option['hidden'] == true ? 1 : 2;
      case 'discard':
        return 0;
    }
    final targets = (f['targets'] as List? ?? []).cast<String>();
    final target =
        players.where((p) => targets.contains(p['characterId'])).firstOrNull ??
        (c.kind == 'selectCard' &&
                (f['attack'] == true || number(f, 'damage') > 0)
            ? players
                  .where(
                    (p) => p['teamId'] != own['teamId'] && p['alive'] == true,
                  )
                  .firstOrNull
            : null);
    final hostile = target != null && target['teamId'] != own['teamId'];
    var harm = number(f, 'damage').toDouble();
    if (f['attack'] == true) harm += number(f, 'attackPower') * 1.5;
    var score = target == null ? 0.0 : harm * (hostile ? 1 : -1.5);
    if (hostile && harm >= number(target, 'hp') + number(target, 'shield')) {
      score += 500;
    }
    final recipient = target ?? own;
    final missing = (number(recipient, 'maxHp') - number(recipient, 'hp'))
        .clamp(0, 1000000);
    final healing = number(f, 'healing').clamp(0, missing);
    score += healing * (hostile ? -1 : 0.8);
    score += number(f, 'shield') * (hostile ? -0.5 : 0.4);
    score += number(f, 'draw') * 15 + number(f, 'selfStatusBenefit');
    score += number(f, 'targetStatusBenefit') * (hostile ? -1 : 1);
    score -= number(f, 'mpCost') * 6;
    if (f['cancel'] == true) {
      final pending = public['pending'] as Map?;
      final source = players
          .where((p) => p['playerId'] == pending?['actorId'])
          .firstOrNull;
      score += source?['teamId'] != own['teamId'] ? 40 : -100;
    }
    if (f['diceResult'] is int) score += number(f, 'diceResult');
    if (c.kind == 'activateTrait' || c.kind == 'activateStatus') score += 3;
    if (private['cards'] is List &&
        (private['cards']! as List).length > 5 &&
        c.kind == 'playCards') {
      score += 5;
    }
    return score;
  }
}
