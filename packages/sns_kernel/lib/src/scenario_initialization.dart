part of 'engine.dart';

extension _ScenarioInitialization on GameKernel {
  void _initializeScenario() {
    final initial = scenario;
    if (initial == null) return;
    int integer(Map<String, Object?> row, String key, int fallback) {
      final v = row[key] ?? fallback;
      if (v is! int) throw StateError('Scenario $key must be an integer');
      return v;
    }

    List<Map<String, Object?>> rows(Map<String, Object?> row, String key) {
      final v = row[key] ?? const <Object?>[];
      if (v is! List || v.any((e) => e is! Map)) {
        throw StateError('Scenario $key must be a list of objects');
      }
      return [for (final e in v) Map<String, Object?>.from(e as Map)];
    }

    String definition(Map<String, Object?> row) {
      final id = row['definitionId'];
      if (id is! String || id.isEmpty) {
        throw StateError('Scenario definitionId is required');
      }
      return id;
    }

    void checkFields(Map<String, Object?> row, Set<String> allowed) {
      if (row.keys.any((key) => !allowed.contains(key))) {
        throw StateError('Unsupported scenario object field');
      }
      if (row['decayPhase'] != null &&
          row['decayPhase'] != 'turnStart' &&
          row['decayPhase'] != 'turnEnd') {
        throw StateError('Invalid scenario decay phase');
      }
    }

    String playerReference(Object? id, String fallback) {
      if (id == null) return fallback;
      if (id is! String) throw StateError('Invalid scenario player reference');
      return _player(id).id;
    }

    for (final entry in initial.players.entries) {
      final actor = _player(entry.key).character;
      final row = entry.value;
      const keys = {
        'hp',
        'mp',
        'shield',
        'hand',
        'skills',
        'statuses',
        'marks',
      };
      if (row.keys.any((k) => !keys.contains(k))) {
        throw StateError('Unsupported scenario field for ${entry.key}');
      }
      if (row.containsKey('skills')) {
        actor.skills.clear();
        for (final s in rows(row, 'skills')) {
          checkFields(s, {
            'definitionId',
            'cooldown',
            'remainingUses',
            'revealed',
            'anchorPlayerId',
            'decayPhase',
          });
          final d = _require(catalog.skills, definition(s));
          final cd = integer(s, 'cooldown', 0);
          final uses = s['remainingUses'];
          if (cd < 0 || (uses != null && (uses is! int || uses < 1))) {
            throw StateError('Invalid scenario skill cooldown or uses');
          }
          final revealed = s['revealed'] ?? d.exclusive;
          if (revealed is! bool) {
            throw StateError('Invalid scenario revelation');
          }
          final skill = SkillInstance(state.id('skill'), d)
            ..cooldown = cd
            ..remainingUses = uses as int?
            ..revealed = revealed;
          if (cd > 0) {
            final anchor = playerReference(s['anchorPlayerId'], entry.key);
            skill.cooldownAnchor = AnchorExpiry(
              playerId: anchor,
              turn: _player(anchor).character.turnsStarted + cd,
              atEnd: s['decayPhase'] == 'turnEnd',
            );
          }
          if (revealed) state.publicSkillHistory[d.id] = d;
          actor.skills.add(skill);
        }
      }
      for (final s in rows(row, 'statuses')) {
        checkFields(s, {
          'definitionId',
          'stacks',
          'intensity',
          'sourcePlayerId',
          'anchorPlayerId',
          'decayPhase',
        });
        final d = _require(catalog.statuses, definition(s));
        final stacks = integer(s, 'stacks', 1);
        final intensity = integer(s, 'intensity', 1);
        if (stacks < 1 ||
            intensity < 0 ||
            (d.maxStacks != null && stacks > d.maxStacks!)) {
          throw StateError('Invalid scenario status stacks or intensity');
        }
        final source = playerReference(s['sourcePlayerId'], entry.key);
        actor.statuses.add(
          StatusInstance(
            instanceId: state.id('status'),
            definition: d,
            ownerId: actor.instanceId,
            sourceId: _player(source).character.instanceId,
            anchorPlayerId: playerReference(s['anchorPlayerId'], source),
            stacks: stacks,
            intensity: intensity,
            decayAtAnchorEnd: s['decayPhase'] == 'turnEnd',
          ),
        );
      }
      for (final m in rows(row, 'marks')) {
        checkFields(m, {'definitionId', 'count', 'sourcePlayerId'});
        final d = _require(catalog.marks, definition(m));
        final count = integer(m, 'count', 1);
        final maximum = d.playerCountBonus != null
            ? setup.players.length + d.playerCountBonus!
            : d.maxCount ?? 1000000;
        final grouped = actor.marks
            .where((mark) => mark.definition.group == d.group)
            .fold<int>(0, (n, mark) => n + mark.count);
        if (count < 1 ||
            count > maximum ||
            (d.group != null &&
                d.groupLimit != null &&
                grouped + count > d.groupLimit!)) {
          throw StateError('Invalid scenario mark count');
        }
        final source = playerReference(m['sourcePlayerId'], entry.key);
        actor.marks.add(
          MarkInstance(
            instanceId: state.id('mark'),
            definition: d,
            ownerId: actor.instanceId,
            sourceId: d.sourceScoped
                ? _player(source).character.instanceId
                : null,
            count: count,
          ),
        );
      }
      final hp = integer(row, 'hp', actor.hp);
      final mp = integer(row, 'mp', actor.mp);
      final shield = integer(row, 'shield', 0);
      if ((!actor.defenseLife && (hp <= 0 || hp > actor.value(Stat.maxHp))) ||
          (actor.defenseLife && hp != 0) ||
          mp < 0 ||
          mp > actor.value(Stat.maxMp) ||
          shield < 0) {
        throw StateError('Scenario resources outside their valid range');
      }
      actor.hp = hp;
      actor.mp = mp;
      actor.shield = shield;
      final hand = row['hand'] ?? const <String>[];
      if (hand is! List || hand.any((e) => e is! String)) {
        throw StateError('Invalid scenario hand');
      }
      for (final id in hand) {
        final index = state.drawPile.indexWhere((c) => c.definition.id == id);
        if (index < 0) {
          throw StateError('Scenario hand card is absent from deck: $id');
        }
        actor.hand.add(state.drawPile.removeAt(index));
      }
    }
  }
}
