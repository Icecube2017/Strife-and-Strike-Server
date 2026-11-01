import '../state.dart';

/// Committed data, kept separate from contribution weights and score policy.
final class MatchDataStatistics {
  final Set<int> _seen = {};
  final Map<String, Map<String, int>> _resources = {};
  final Map<String, Map<String, int>> _protection = {};
  final Map<String, Set<String>> _hand = {};
  final Map<String, int> _mp = {}, _shield = {}, _hp = {};
  final Map<String, int> _lifeCosts = {};
  final Map<String, Set<int>> _aliveRounds = {};
  final Map<String, int> _death = {};
  int? _start, _end;
  static const resourceKeys = [
    'cardsGained',
    'cardsPlayed',
    'cardsDiscarded',
    'mpGained',
    'mpSpent',
    'actions',
    'attacks',
    'skills',
  ];

  void _add(
    Map<String, Map<String, int>> table,
    String id,
    String key,
    int amount,
  ) {
    if (amount <= 0) return;
    table
        .putIfAbsent(id, () => {})
        .update(key, (v) => v + amount, ifAbsent: () => amount);
  }

  void record(KernelEvent event, KernelState state) {
    if (!_seen.add(event.sequence)) return;
    final d = event.data;
    for (final p in state.players) {
      final c = p.character;
      final id = c.instanceId;
      // Damage already has its own exact fact. Other committed HP decreases
      // include fees, theft, max-life clipping and explicit life assignments.
      if (event.type != 'damage' && !c.defenseLife) {
        final lost =
            ((_hp[id] ?? c.hp).clamp(0, 1000000000) - c.hp.clamp(0, 1000000000))
                .clamp(0, 1000000000);
        _lifeCosts.update(id, (n) => n + lost, ifAbsent: () => lost);
      }
      _hp[id] = c.hp;
      final hand = c.hand.map((card) => card.instanceId).toSet(),
          mp = c.mp,
          shield = c.shield;
      _add(
        _resources,
        id,
        'cardsGained',
        hand.difference(_hand[id] ?? hand).length,
      );
      _add(
        _resources,
        id,
        'mpGained',
        (mp - (_mp[id] ?? mp)).clamp(0, 1000000000),
      );
      _add(
        _protection,
        id,
        'shieldGained',
        (shield - (_shield[id] ?? shield)).clamp(0, 1000000000),
      );
      _hand[id] = hand;
      _mp[id] = mp;
      _shield[id] = shield;
      if (c.alive && state.round > 0) {
        (_aliveRounds[id] ??= {}).add(state.round);
      }
      _resources.putIfAbsent(id, () => {});
    }
    final actor = (d['actorId'] ?? d['sourceId'] ?? d['targetId']) as String?;
    if (actor != null) {
      switch (event.type) {
        case 'cardsPlayed':
          _add(
            _resources,
            actor,
            'cardsPlayed',
            d['handLossCount'] as int? ?? 0,
          );
        case 'cardsDiscarded':
          _add(
            _resources,
            actor,
            'cardsDiscarded',
            (d['cards'] as List? ?? []).length,
          );
        case 'mpSpent':
          _add(_resources, actor, 'mpSpent', d['amount'] as int? ?? 0);
        case 'actionCommitted' || 'mentalActionFailed':
          _add(_resources, actor, 'actions', 1);
        case 'attackDeclared':
          _add(_resources, actor, 'attacks', 1);
        case 'skillUsed' || 'skillTriggered':
          _add(_resources, actor, 'skills', 1);
      }
    }
    if (event.type == 'gameStarted') _start = event.sequence;
    if (event.type == 'gameFinished') _end = event.sequence;
    if (event.type == 'characterDied') {
      _death[d['instanceId']! as String] = event.sequence;
    }
  }

  Map<String, Object?> resources(String id) => {
    for (final k in resourceKeys) k: _resources[id]?[k] ?? 0,
  };
  Map<String, Object?> protection(String id) => {
    'shieldGained': _protection[id]?['shieldGained'] ?? 0,
  };
  Map<String, Object?> lifeCosts(String id) => {'hpLost': _lifeCosts[id] ?? 0};
  Map<String, Object?> get resourceTotals => {
    for (final k in resourceKeys)
      k: _resources.values.fold<int>(0, (n, v) => n + (v[k] ?? 0)),
  };
  Map<String, Object?> get protectionTotals => {
    'shieldGained': _protection.values.fold<int>(
      0,
      (n, v) => n + (v['shieldGained'] ?? 0),
    ),
  };
  Map<String, Object?> get lifeCostTotals => {
    'hpLost': _lifeCosts.values.fold<int>(0, (a, b) => a + b),
  };
  Map<String, Object?> survival(KernelState state) => {
    for (final p in state.players)
      p.character.instanceId: {
        'rounds': _aliveRounds[p.character.instanceId]?.length ?? 0,
        'startSequence': _start,
        'endSequence': p.character.alive
            ? _end
            : _death[p.character.instanceId],
        'alive': p.character.alive,
      },
  };
}
