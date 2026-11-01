part of 'engine.dart';

/// Declarative storage is separate from trigger-local legacy counters.
extension _VariableEngine on GameKernel {
  bool _eventVariableInput(VariableInput input) =>
      input.source != VariableSource.literal &&
      input.source != VariableSource.expression &&
      input.source != VariableSource.selfId &&
      input.source != VariableSource.selectedId &&
      input.source != VariableSource.variable;

  void _checkVariableInput(VariableInput input, String type) {
    if (input.source == VariableSource.variable) {
      final d = _require(catalog.variables, input.variable ?? '');
      if (input.value != null ||
          input.subject == ValueSubject.previousPlayer ||
          !(switch (type) {
            'number' => d.type == VariableType.number,
            'strings' => d.type == VariableType.set,
            'list' => d.type == VariableType.set || d.type == VariableType.list,
            'record' => true,
            _ => false,
          })) {
        throw StateError('Invalid variable reference');
      }
      return;
    }
    if (input.source == VariableSource.expression) {
      if (input.value == null || (type != 'number' && type != 'record')) {
        throw StateError('Variable expression requires numeric input');
      }
      _checkValue(input.value!);
      return;
    }
    if (input.value != null) {
      throw StateError('Variable value requires expression source');
    }
    final valid = switch (type) {
      'number' =>
        input.source == VariableSource.eventAmount ||
            (input.source == VariableSource.literal &&
                input.literal is num &&
                (input.literal! as num).isFinite),
      'string' =>
        [
              VariableSource.selfId,
              VariableSource.selectedId,
              VariableSource.eventSource,
              VariableSource.eventTarget,
              VariableSource.eventDefinition,
            ].contains(input.source) ||
            (input.source == VariableSource.literal && input.literal is String),
      'strings' =>
        input.source == VariableSource.eventTags ||
            [
              VariableSource.selfId,
              VariableSource.selectedId,
              VariableSource.eventSource,
              VariableSource.eventTarget,
              VariableSource.eventDefinition,
            ].contains(input.source) ||
            (input.source == VariableSource.literal &&
                (input.literal is String ||
                    (input.literal is List &&
                        (input.literal! as List).every((v) => v is String)))),
      'list' =>
        input.source == VariableSource.eventTags ||
            (input.source == VariableSource.literal && input.literal is List),
      'record' =>
        input.source == VariableSource.eventRecord ||
            input.source == VariableSource.literal,
      _ => false,
    };
    if (!valid) throw StateError('Invalid variable input for $type');
    if (input.source == VariableSource.literal) _freezeVariable(input.literal);
  }

  void _checkVariableEffect(ModifyVariable e) {
    if (e.storageSubject == ValueSubject.previousPlayer) {
      throw StateError('Variable storage subject must be self or selected');
    }
    final d = _require(catalog.variables, e.variable);
    final valid = switch (e.operation) {
      VariableOperation.assign || VariableOperation.clear => true,
      VariableOperation.add => d.type == VariableType.number,
      VariableOperation.setAdd ||
      VariableOperation.setRemove => d.type == VariableType.set,
      VariableOperation.mapSet ||
      VariableOperation.mapAdd ||
      VariableOperation.mapRemove => d.type == VariableType.map,
      VariableOperation.append ||
      VariableOperation.listSet ||
      VariableOperation.listInsert ||
      VariableOperation.listRemove => d.type == VariableType.list,
    };
    if (!valid) {
      throw StateError('Variable operation does not match type: ${e.variable}');
    }
    if (e.operation == VariableOperation.clear) return;
    if (const [
      VariableOperation.listSet,
      VariableOperation.listInsert,
      VariableOperation.listRemove,
    ].contains(e.operation)) {
      _checkVariableInput(e.key, 'number');
      if (e.operation != VariableOperation.listRemove) {
        _checkVariableInput(e.input, 'record');
      }
      return;
    }
    if ([
      VariableOperation.mapSet,
      VariableOperation.mapAdd,
      VariableOperation.mapRemove,
    ].contains(e.operation)) {
      _checkVariableInput(e.key, 'string');
      if (e.operation != VariableOperation.mapRemove) {
        _checkVariableInput(e.input, 'number');
      }
    } else if (e.operation == VariableOperation.assign) {
      if (e.input.source == VariableSource.variable) {
        _checkVariableInput(e.input, 'record');
        if (_require(catalog.variables, e.input.variable!).type != d.type) {
          throw StateError('Variable copy requires matching types');
        }
      } else if (e.input.source == VariableSource.literal) {
        _normalizeVariable(d, e.input.literal);
      } else if (d.type == VariableType.number) {
        _checkVariableInput(e.input, 'number');
      } else if (d.type == VariableType.set || d.type == VariableType.list) {
        _checkVariableInput(e.input, 'list');
      } else {
        throw StateError('Map assignment requires literal map');
      }
    } else {
      _checkVariableInput(e.input, switch (d.type) {
        VariableType.number => 'number',
        VariableType.set => 'strings',
        VariableType.list => 'record',
        VariableType.map => 'number',
      });
    }
  }

  void _checkVariableCondition(VariableCondition c) {
    final d = _require(catalog.variables, c.variable);
    if (c.subject == ValueSubject.previousPlayer) {
      throw StateError('Variable condition subject must be self or selected');
    }
    final numeric = [
      VariableComparison.equals,
      VariableComparison.atLeast,
      VariableComparison.atMost,
    ].contains(c.comparison);
    if (numeric
        ? (d.type != VariableType.number &&
              !(d.type == VariableType.map &&
                  (c.key != null || c.keySource != VariableSource.literal)))
        : d.type != VariableType.set) {
      throw StateError('Variable condition does not match type');
    }
    if ((c.key != null || c.keySource != VariableSource.literal) &&
        d.type != VariableType.map) {
      throw StateError('Variable condition key requires map');
    }
    if (c.key != null || c.keySource != VariableSource.literal) {
      _checkVariableInput(
        VariableInput(source: c.keySource, literal: c.key),
        'string',
      );
    }
    _checkVariableInput(
      c.input,
      numeric
          ? 'number'
          : c.comparison == VariableComparison.contains
          ? 'string'
          : 'list',
    );
    if (!numeric &&
        c.input.source == VariableSource.literal &&
        c.input.literal is List &&
        (c.input.literal! as List).any((v) => v is! String)) {
      throw StateError('Set condition requires string entries');
    }
  }

  void _checkVariableValue(EffectValue v) {
    if (![
      ValueField.variableNumber,
      ValueField.variableSize,
      ValueField.variableMapValue,
      ValueField.variableNewTagCount,
      ValueField.variableListValue,
    ].contains(v.field)) {
      return;
    }
    final d = _require(catalog.variables, v.variable ?? '');
    final valid = switch (v.field!) {
      ValueField.variableNumber => d.type == VariableType.number,
      ValueField.variableSize => d.type != VariableType.number,
      ValueField.variableMapValue =>
        d.type == VariableType.map &&
            (v.variableKey != null ||
                v.variableKeySource != VariableSource.literal),
      ValueField.variableNewTagCount => d.type == VariableType.set,
      ValueField.variableListValue =>
        d.type == VariableType.list && v.variableIndex != null,
      _ => false,
    };
    if (!valid) throw StateError('Variable expression does not match type');
    if (v.variableIndex != null) _checkValue(v.variableIndex!);
    if (v.field == ValueField.variableMapValue) {
      _checkVariableInput(
        VariableInput(source: v.variableKeySource, literal: v.variableKey),
        'string',
      );
    }
  }

  void _checkVariableContext(EffectDefinition e, {required bool allowEvent}) {
    Iterable<VariableInput> conditionInputs(ConditionDefinition? c) sync* {
      if (c is VariableCondition) {
        yield c.input;
        if (c.key != null || c.keySource != VariableSource.literal) {
          yield VariableInput(source: c.keySource, literal: c.key);
        }
      }
      if (c is LivingCountCondition && c.selectedOnly && !allowEvent) {
        throw StateError('Selected query requires a trigger');
      }
      if (c is LivingCountCondition) yield* conditionInputs(c.when);
      if (c is AnyCondition) {
        for (final nested in c.conditions) {
          yield* conditionInputs(nested);
        }
      }
    }

    final inputs = <VariableInput>[
      if (e is ModifyVariable && e.operation != VariableOperation.clear)
        e.input,
      if (e is ModifyVariable &&
          [
            VariableOperation.mapSet,
            VariableOperation.mapAdd,
            VariableOperation.mapRemove,
            VariableOperation.listSet,
            VariableOperation.listInsert,
            VariableOperation.listRemove,
          ].contains(e.operation))
        e.key,
      if (e is ConditionalEffect) ...conditionInputs(e.when),
      if (e is ChooseEffect) ...conditionInputs(e.when),
    ];
    if (!allowEvent &&
        (_queryEffectReferences(e).any((r) => r.startsWith('event.')) ||
            inputs.any(_eventVariableInput) ||
            _effectValues(e)
                .expand(_valueTree)
                .any(
                  (v) =>
                      v.field == ValueField.variableNewTagCount ||
                      (v.field == ValueField.variableMapValue &&
                          _eventVariableInput(
                            VariableInput(source: v.variableKeySource),
                          )),
                ))) {
      throw StateError('Event variable input requires a trigger');
    }
  }

  Object _freezeVariable(Object? value, [int depth = 0]) {
    if (depth > 12) throw StateError('Variable data is too deeply nested');
    if (value is String || value is bool) return value!;
    if (value is num && value.isFinite) return value;
    if (value is List && value.length <= 1024) {
      return List<Object>.unmodifiable(
        value.map((v) => _freezeVariable(v, depth + 1)),
      );
    }
    if (value is Map &&
        value.length <= 1024 &&
        value.keys.every((k) => k is String)) {
      return Map<String, Object>.unmodifiable(
        value.map(
          (k, v) => MapEntry(k as String, _freezeVariable(v, depth + 1)),
        ),
      );
    }
    throw StateError('Variable data must be finite JSON values without null');
  }

  Object _initialVariable(VariableDefinition d) => _normalizeVariable(
    d,
    d.initial ??
        switch (d.type) {
          VariableType.number => 0,
          VariableType.set || VariableType.list => <Object>[],
          VariableType.map => <String, Object>{},
        },
  );

  Object _normalizeVariable(VariableDefinition d, Object? value) {
    switch (d.type) {
      case VariableType.number:
        if (value is! num || !value.isFinite) {
          throw StateError('Variable ${d.id} requires a number');
        }
        return value.clamp(
          d.minimum ?? double.negativeInfinity,
          d.maximum ?? double.infinity,
        );
      case VariableType.set:
        if (value is! Iterable || value.any((v) => v is! String)) {
          throw StateError('Variable ${d.id} requires string set');
        }
        return List<String>.unmodifiable(
          value.cast<String>().toSet().take(d.maxEntries),
        );
      case VariableType.map:
        if (value is! Map ||
            value.keys.any((k) => k is! String) ||
            value.values.any((v) => v is! num || !v.isFinite)) {
          throw StateError('Variable ${d.id} requires string-to-number map');
        }
        return Map<String, num>.unmodifiable(
          Map.fromEntries(
            value.entries
                .take(d.maxEntries)
                .map((e) => MapEntry(e.key as String, e.value as num)),
          ),
        );
      case VariableType.list:
        if (value is! List) throw StateError('Variable ${d.id} requires list');
        return _freezeVariable(value.take(d.maxEntries).toList());
    }
  }

  void _checkVariableDefinitions() {
    final identifier = RegExp(r'^[a-z][a-z0-9_]*$');
    for (final d in catalog.variables.values) {
      if (!identifier.hasMatch(d.id) ||
          !identifier.hasMatch(d.namespace) ||
          d.maxEntries <= 0 ||
          d.maxEntries > 1024 ||
          (d.minimum != null && !d.minimum!.isFinite) ||
          (d.maximum != null && !d.maximum!.isFinite) ||
          (d.minimum != null && d.maximum != null && d.minimum! > d.maximum!) ||
          (d.type != VariableType.number &&
              (d.minimum != null || d.maximum != null)) ||
          (d.scope != VariableScope.owner &&
              [
                CounterReset.ownerTurn,
                CounterReset.personalRound,
              ].contains(d.reset)) ||
          (d.scope != VariableScope.owner &&
              d.visibility == VariableVisibility.owner) ||
          (d.scope == VariableScope.game &&
              d.visibility != VariableVisibility.public &&
              d.visibility != VariableVisibility.hidden)) {
        throw StateError('Invalid variable definition: ${d.id}');
      }
      _initialVariable(d);
    }
  }

  String _variableHolder(VariableDefinition d, CharacterInstance actor) =>
      switch (d.scope) {
        VariableScope.owner => actor.instanceId,
        VariableScope.team =>
          state.players.firstWhere((p) => p.character == actor).teamId,
        VariableScope.game => state.gameId,
      };

  VariableState _variableCell(String id, CharacterInstance actor) {
    if (_previewMode) throw const PreviewBoundary('unprojectedVariables');
    final d = _require(catalog.variables, id);
    final key = (id, _variableHolder(d, actor));
    final window = _window(d.reset, actor);
    final cell = state.variables.putIfAbsent(
      key,
      () => VariableState(_initialVariable(d), window),
    );
    if (cell.window != window) {
      cell
        ..value = _initialVariable(d)
        ..window = window;
    }
    return cell;
  }

  void _resetVariableWindows() {
    for (final d in catalog.variables.values) {
      for (final p in state.players) {
        _variableCell(d.id, p.character);
      }
    }
  }

  Object _variableInput(
    VariableInput input,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final fact = _currentTrigger?.fact;
    if (_eventVariableInput(input) && fact == null) {
      throw StateError('Event variable input requires trigger context');
    }
    return switch (input.source) {
      VariableSource.variable => _variableCell(
        input.variable!,
        input.subject == ValueSubject.self ? actor : target,
      ).value,
      VariableSource.selfId => actor.instanceId,
      VariableSource.selectedId => target.instanceId,
      VariableSource.literal => _freezeVariable(input.literal),
      VariableSource.expression => _numberValue(input.value!, actor, target),
      VariableSource.eventAmount => fact!.amount,
      VariableSource.eventTags => List<String>.unmodifiable(fact!.tags.keys),
      VariableSource.eventSource => fact!.source ?? '',
      VariableSource.eventTarget => fact!.target ?? '',
      VariableSource.eventDefinition => fact!.definitionId ?? '',
      VariableSource.eventRecord => _freezeVariable({
        'timing': fact!.timing.name,
        'amount': fact.amount,
        'sourceId': fact.source ?? '',
        'targetId': fact.target ?? '',
        'definitionId': fact.definitionId ?? '',
        'tags': fact.tags.keys.toList(),
      }),
    };
  }

  void _modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  ) {
    final d = _require(catalog.variables, effect.variable);
    final cell = _variableCell(
      d.id,
      effect.storageSubject == ValueSubject.self ? actor : target,
    );
    if (effect.operation == VariableOperation.clear) {
      cell.value = _initialVariable(d);
      return;
    }
    final input =
        const [
          VariableOperation.mapRemove,
          VariableOperation.listRemove,
        ].contains(effect.operation)
        ? null
        : _variableInput(effect.input, actor, target);
    Object next;
    switch (effect.operation) {
      case VariableOperation.assign:
        next = input!;
      case VariableOperation.add:
        next = (cell.value as num) + (input! as num);
      case VariableOperation.setAdd:
      case VariableOperation.setRemove:
        final entries = (cell.value as List).cast<String>().toSet();
        final items = input is String
            ? [input]
            : (input! as List).cast<String>();
        if (effect.operation == VariableOperation.setAdd) {
          entries.addAll(items);
        } else {
          entries.removeAll(items);
        }
        next = entries.toList();
      case VariableOperation.mapSet:
      case VariableOperation.mapAdd:
      case VariableOperation.mapRemove:
        final key = _variableInput(effect.key, actor, target) as String;
        final entries = Map<String, num>.from(cell.value as Map);
        if (key.isEmpty) return;
        if (effect.operation == VariableOperation.mapRemove) {
          entries.remove(key);
        } else if (entries.containsKey(key) || entries.length < d.maxEntries) {
          entries[key] = effect.operation == VariableOperation.mapSet
              ? input! as num
              : (entries[key] ?? 0) + (input! as num);
        }
        next = entries;
      case VariableOperation.listSet:
      case VariableOperation.listInsert:
      case VariableOperation.listRemove:
        final index = (_variableInput(effect.key, actor, target) as num)
            .floor();
        final entries = List<Object?>.of(cell.value as List);
        final inserting = effect.operation == VariableOperation.listInsert;
        if (index < 0 ||
            index > entries.length ||
            (!inserting && index == entries.length)) {
          throw StateError('List index out of range');
        }
        if (effect.operation == VariableOperation.listRemove) {
          entries.removeAt(index);
        } else if (inserting) {
          if (entries.length < d.maxEntries) entries.insert(index, input);
        } else {
          entries[index] = input;
        }
        next = entries;
      case VariableOperation.append:
        next = [...cell.value as List, input];
      case VariableOperation.clear:
        return;
    }
    cell.value = _normalizeVariable(d, next);
  }

  bool _variableCondition(
    VariableCondition c,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final subject = c.subject == ValueSubject.self ? actor : target;
    final stored = _variableCell(c.variable, subject).value;
    final actual = c.key == null && c.keySource == VariableSource.literal
        ? stored
        : (stored as Map)[_variableInput(
                VariableInput(source: c.keySource, literal: c.key),
                actor,
                target,
              )] ??
              0;
    final expected = _variableInput(c.input, actor, target);
    return switch (c.comparison) {
      VariableComparison.equals => actual == expected,
      VariableComparison.atLeast => (actual as num) >= (expected as num),
      VariableComparison.atMost => (actual as num) <= (expected as num),
      VariableComparison.contains => (actual as List).contains(expected),
      VariableComparison.intersects => (expected as List).any(
        (v) => (actual as List).contains(v),
      ),
      VariableComparison.disjoint => !(expected as List).any(
        (v) => (actual as List).contains(v),
      ),
    };
  }

  num _variableNumber(
    EffectValue v,
    CharacterInstance subject,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final stored = _variableCell(v.variable!, subject).value;
    return switch (v.field!) {
      ValueField.variableListValue => _listNumericValue(
        stored as List,
        v,
        actor,
        target,
      ),
      ValueField.variableNumber => stored as num,
      ValueField.variableSize =>
        stored is Map ? stored.length : (stored as List).length,
      ValueField.variableMapValue =>
        (stored as Map)[_variableInput(
                  VariableInput(
                    source: v.variableKeySource,
                    literal: v.variableKey,
                  ),
                  actor,
                  target,
                )]
                as num? ??
            0,
      ValueField.variableNewTagCount =>
        _currentTrigger!.fact.tags.keys
            .where((t) => !(stored as List).contains(t))
            .length,
      _ => throw StateError('Not a variable expression'),
    };
  }

  num _listNumericValue(
    List<dynamic> list,
    EffectValue v,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final index = _amount(0, v.variableIndex, actor, target);
    if (index < 0 || index >= list.length) return 0;
    final value = list[index];
    if (v.variableProperty != null) {
      return _recordNumber(
        value is Map ? Map<String, Object?>.from(value) : {},
        v.variableProperty!,
      );
    }
    if (value is! num || !value.isFinite) {
      throw StateError('List value is not numeric');
    }
    return value;
  }

  List<Map<String, Object?>> _variableView([String? playerId]) {
    final viewer = playerId == null ? null : _player(playerId);
    final rows = <Map<String, Object?>>[];
    for (final d in catalog.variables.values) {
      if (d.visibility == VariableVisibility.hidden) continue;
      final holders = <String>{};
      for (final p in state.players) {
        final holder = _variableHolder(d, p.character);
        if (!holders.add(holder)) continue;
        final visible =
            d.visibility == VariableVisibility.public ||
            (viewer != null &&
                (d.visibility == VariableVisibility.owner
                    ? holder == viewer.character.instanceId
                    : d.scope == VariableScope.team
                    ? holder == viewer.teamId
                    : p.teamId == viewer.teamId));
        if (!visible) continue;
        rows.add({
          'id': d.id,
          'namespace': d.namespace,
          'scope': d.scope.name,
          'holderId': holder,
          'value': state.variables[(d.id, holder)]!.value,
        });
      }
    }
    return rows;
  }
}
