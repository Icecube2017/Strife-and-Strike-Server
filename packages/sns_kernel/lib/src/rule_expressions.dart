part of 'engine.dart';

extension _RuleExpressions on GameKernel {
  Map<String, Object?> _freezeEventData(Map<String, Object?> data) {
    Object? freeze(Object? v) => switch (v) {
      List<int>() => List<int>.unmodifiable(v),
      List<String>() => List<String>.unmodifiable(v),
      Map<String, int>() => Map<String, int>.unmodifiable(v),
      Map<String, String>() => Map<String, String>.unmodifiable(v),
      Map() => Map<String, Object?>.unmodifiable(
        v.map((k, value) => MapEntry(k as String, freeze(value))),
      ),
      List() => List<Object?>.unmodifiable(v.map(freeze)),
      _ => v,
    };
    return freeze(data)! as Map<String, Object?>;
  }

  bool _requiresAttack(ConditionDefinition? c) => switch (c) {
    PredicateCondition() =>
      c.op == 'eq' &&
          c.arguments.length == 2 &&
          c.arguments[0].reference == 'event.attack' &&
          c.arguments[1].literal == true,
    AllCondition() => c.conditions.any(_requiresAttack),
    _ => false,
  };

  void _checkReference(String ref) {
    final parts = ref.split('.');
    if (parts.first == 'item' &&
        parts.length >= 2 &&
        parts.length <= 8 &&
        parts.skip(1).every((p) => p.isNotEmpty)) {
      if (_recordQueryValidationDepth == 0) {
        throw StateError('Item references require a record query');
      }
      return;
    }
    if (parts.length == 2 && parts.first == 'variables') {
      _require(catalog.variables, parts.last);
      return;
    }
    final allowed = <String, Set<String>>{
      'self': {
        'id',
        'hp',
        'maxHp',
        'missingHp',
        'attack',
        'defense',
        'mp',
        'maxMp',
        'handCount',
        'shield',
        'damageThisTurn',
        'damageThisRound',
        'activeTurn',
        'alive',
      },
      'target': {
        'id',
        'hp',
        'maxHp',
        'missingHp',
        'attack',
        'defense',
        'mp',
        'maxMp',
        'handCount',
        'shield',
        'damageThisTurn',
        'damageThisRound',
        'activeTurn',
        'alive',
      },
      'game': {'round', 'extraTurn'},
      'input': {'number'},
      'status': {'intensity'},
      'event': {
        'amount',
        'source',
        'target',
        'definition',
        'damageKind',
        'attack',
        'independent',
        'negativeStatus',
        'tags',
        'tagNames',
        'tagsMaxCount',
        'skillCooldown',
        'attackBaseDamage',
        'statusIntensity',
        'statusStackDelta',
        'hpLost',
        'actualHpLost',
        'shieldAbsorbed',
        'packetId',
        'actionId',
        'result',
        'sides',
        'count',
        'overflow',
        'nominalAmount',
        'actorId',
        'targetId',
        'sourceId',
        'instanceId',
        'round',
      },
    };
    final valid =
        parts.length == 2 &&
        (parts.first == 'local'
            ? RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(parts.last)
            : (allowed[parts.first]?.contains(parts.last) ?? false));
    if (!valid) throw StateError('Invalid rule reference: $ref');
  }

  int _counterDelta(CounterUpdate update, _TriggerInvocation entry) {
    if (update.value == null) {
      return update.amount + entry.fact.amount * update.eventAmountFactor;
    }
    final previous = _currentTrigger;
    _currentTrigger = entry;
    try {
      return _numberValue(update.value!, entry.owner, entry.owner).floor();
    } finally {
      _currentTrigger = previous;
    }
  }

  void _validateNamedResults(
    List<EffectDefinition> effects, [
    Set<String>? inherited,
  ]) {
    final names = {...?inherited};
    void reference(String? ref) {
      if (ref != null &&
          ref.startsWith('local.') &&
          !names.contains(ref.substring(6))) {
        throw StateError('Local result is not bound: $ref');
      }
    }

    for (final e in effects) {
      for (final ref in _queryEffectReferences(e)) {
        reference(ref);
      }
      for (final root in _effectValues(e)) {
        for (final v in _valueTree(root)) {
          reference(v.reference);
        }
      }
      if (e is ChooseObjects || (e is ChooseCards && e.bind != null)) {
        final bind = e is ChooseObjects ? e.bind : (e as ChooseCards).bind!;
        if (!names.add(bind)) {
          throw StateError('Local result is already bound: $bind');
        }
      } else if (e is ChooseTargets) {
        if (!names.add(e.bind)) {
          throw StateError('Local result is already bound: ${e.bind}');
        }
      } else if (e is WithTargets) {
        reference(e.reference);
        _validateNamedResults(e.effects, names);
      } else if (e is RollEffect) {
        if (e.bind != null && !names.add(e.bind!)) {
          throw StateError('Local result is already bound: ${e.bind}');
        }
        _validateNamedResults(e.effects, names);
        _validateNamedResults(e.otherwise, names);
      } else if (e is ConditionalEffect) {
        _validateNamedResults(e.effects, names);
        _validateNamedResults(e.otherwise, names);
      } else if (e is SelectOptionEffect) {
        for (final o in e.options) {
          _validateNamedResults(o.effects, names);
        }
      } else if (e is ChooseEffect) {
        _validateNamedResults(e.effects, names);
      } else if (e is ScheduleEffect) {
        for (final child in _walkEffects(e.effects)) {
          if (_directQueryEffectReferences(
            child,
          ).any((r) => r.startsWith('local.') || r.startsWith('event.'))) {
            throw StateError(
              'Resolve transient object queries before scheduling',
            );
          }
        }
        // Target bindings must be resolved before scheduling; captured numeric
        // expressions are frozen by the scheduler instead of stored as locals.
        for (final child in _walkEffects(e.effects).whereType<WithTargets>()) {
          if (child.reference.startsWith('local.')) {
            throw StateError('Resolve local targets before scheduling');
          }
        }
        _validateNamedResults(e.effects, names);
      }
    }
  }

  Object? _referenceValue(
    String ref,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final path = ref.split('.');
    final name = path.skip(1).join('.');
    if (path.first == 'item') {
      if (_queryRecord == null) {
        throw StateError('Item reference needs a record query');
      }
      Object? value = _queryRecord;
      for (final key in path.skip(1)) {
        value = value is Map ? value[key] : null;
      }
      return value;
    }
    if (path.first == 'local') return _abilityLocals[name];
    if (path.first == 'variables') return _variableCell(name, actor).value;
    if (path.first == 'game' && name == 'round') return state.round;
    if (path.first == 'game' && name == 'extraTurn') return state.extraTurn;
    if (path.first == 'input' && name == 'number') return _abilityNumber;
    if (path.first == 'status' && name == 'intensity') {
      return _currentTrigger?.intensity ?? 1;
    }
    if (path.first == 'event') {
      final fact = _currentTrigger?.fact;
      if (fact == null) {
        throw StateError('Event reference needs an event frame: $ref');
      }
      return switch (name) {
        'amount' => fact.amount,
        'source' => fact.source,
        'target' => fact.target,
        'definition' => fact.definitionId,
        'damageKind' => fact.kind?.name,
        'attack' => fact.attack,
        'independent' => fact.independent,
        'negativeStatus' => fact.negativeStatus,
        'tags' => fact.tags,
        'tagNames' => List<String>.unmodifiable(fact.tags.keys),
        'tagsMaxCount' => fact.tags.values.fold<int>(
          0,
          (n, v) => n > v ? n : v,
        ),
        'skillCooldown' => fact.skillCooldown,
        'attackBaseDamage' => fact.baseDamage,
        'statusIntensity' => fact.statusIntensity,
        'statusStackDelta' => fact.statusStackDelta,
        'hpLost' => fact.data['hpLost'] ?? fact.amount,
        'shieldAbsorbed' => fact.data['shieldAbsorbed'] ?? 0,
        _ => fact.data[name],
      };
    }
    if (path.first == 'self' || path.first == 'target') {
      final c = path.first == 'self' ? actor : target;
      return switch (name) {
        'id' => c.instanceId,
        'hp' => c.hp,
        'maxHp' => c.value(Stat.maxHp),
        'missingHp' => (c.value(Stat.maxHp) - c.hp).clamp(0, 1000000),
        'attack' => c.value(Stat.attack),
        'defense' => c.value(Stat.defense),
        'mp' => c.mp,
        'maxMp' => c.value(Stat.maxMp),
        'handCount'
            when _previewMode && _previewHiddenHands.contains(c.instanceId) =>
          throw const PreviewBoundary('unknownHandState'),
        'handCount' => c.hand.length,
        'shield' => c.shield,
        'damageThisTurn' when _previewMode => throw const PreviewBoundary(
          'unprojectedCalculationState',
        ),
        'damageThisTurn' => c.damageThisTurn,
        'damageThisRound' when _previewMode => throw const PreviewBoundary(
          'unprojectedCalculationState',
        ),
        'damageThisRound' => c.damageThisRound,
        'activeTurn' => c == state.activePlayer.character,
        'alive' => c.alive,
        _ => throw StateError('Unknown character reference: $ref'),
      };
    }
    throw StateError('Unknown rule reference: $ref');
  }

  Object? _operandValue(
    RuleOperand operand,
    CharacterInstance actor,
    CharacterInstance target,
  ) => operand.reference != null
      ? _referenceValue(operand.reference!, actor, target)
      : operand.expression != null
      ? _numberValue(operand.expression!, actor, target)
      : operand.literal;

  bool _predicate(
    PredicateCondition c,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final a = _operandValue(c.arguments[0], actor, target);
    final b = _operandValue(c.arguments[1], actor, target);
    bool contains(Object? collection, Object? item) => switch (collection) {
      Map() => collection.containsKey(item),
      Iterable() => collection.contains(item),
      _ => false,
    };
    return switch (c.op) {
      'eq' => a == b,
      'ne' => a != b,
      'gt' || 'gte' || 'lt' || 'lte' =>
        a is num &&
            b is num &&
            switch (c.op) {
              'gt' => a > b,
              'gte' => a >= b,
              'lt' => a < b,
              _ => a <= b,
            },
      'contains' => contains(a, b),
      'intersects' => b is Iterable && b.any((v) => contains(a, v)),
      'disjoint' => b is Iterable && !b.any((v) => contains(a, v)),
      _ => throw StateError('Unknown predicate: ${c.op}'),
    };
  }

  bool _triggerCondition(
    ConditionDefinition? condition,
    _TriggerInvocation invocation,
  ) {
    if (condition == null) return true;
    final previous = _currentTrigger;
    _currentTrigger = invocation;
    try {
      final targetId = invocation.fact.target;
      return _conditionMatches(
        condition,
        invocation.owner,
        targetId == null ? invocation.owner : _character(targetId),
      );
    } finally {
      _currentTrigger = previous;
    }
  }
}
