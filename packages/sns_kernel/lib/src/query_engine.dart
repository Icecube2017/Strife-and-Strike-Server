part of 'engine.dart';

extension _ContentQueries on GameKernel {
  String? _cardOwnerId(CardInstance card) => state.players
      .map((p) => p.character)
      .where((c) => c.hand.contains(card))
      .firstOrNull
      ?.instanceId;

  Map<String, Object?> _cardQueryData(CardInstance c, [String? owner]) => {
    'instanceId': c.instanceId,
    'definitionId': c.definition.id,
    if (owner != null) 'ownerId': owner,
    'tags': c.definition.tags.toList(),
    'tagCount': c.definition.tags.length,
    'mpCost': c.definition.mpCost,
    'attacks': c.definition.attacks,
    'isLimited': c.definition.isLimited,
    'disabled': c.disabled,
  };

  Map<String, Object?> _statusQueryData(StatusInstance s) => {
    'instanceId': s.instanceId,
    'definitionId': s.definition.id,
    'ownerId': s.ownerId,
    'sourceId': s.sourceId,
    'stacks': s.stacks,
    'intensity': s.intensity,
    'negative': s.definition.negative,
    'hasIntensity': s.definition.hasIntensity,
    'anomaly': s.definition.category == StatusCategory.anomaly,
    'statusEffect': _isStatusEffect(s.definition),
    'decaying': s.definition.decay != StatusDecay.none,
    'maxStacks': s.definition.maxStacks ?? 1000000,
  };

  Map<String, Object?> _markQueryData(MarkInstance m) => {
    'instanceId': m.instanceId,
    'definitionId': m.definition.id,
    'ownerId': m.ownerId,
    'sourceId': m.sourceId,
    'count': m.count,
    'group': m.definition.group,
  };

  Map<String, Object?> _skillQueryData(SkillInstance s, String owner) => {
    'instanceId': s.instanceId,
    'definitionId': s.definition.id,
    'ownerId': owner,
    'cooldown': s.cooldown,
    'mpCost': s.definition.mpCost,
    'uses': s.uses,
    'exclusive': s.definition.exclusive,
    'passive': s.definition.passive,
    'borrowed': s.borrowed,
  };

  Map<String, Object?> _characterQueryData(CharacterInstance c) => {
    'instanceId': c.instanceId,
    'definitionId': c.definition.id,
    'ownerId': c.instanceId,
    'hp': c.hp,
    'missingHp': (c.value(Stat.maxHp) - c.hp).clamp(0, 1000000),
    'maxHp': c.value(Stat.maxHp),
    'mp': c.mp,
    'maxMp': c.value(Stat.maxMp),
    'attack': c.value(Stat.attack),
    'defense': c.value(Stat.defense),
    'handCount': c.hand.length,
    'shield': c.shield,
  };

  List<Map<String, Object?>> _boundQueryRows(
    String ref,
    CollectionKind kind,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final value = _referenceValue(ref, actor, target);
    if (value is! Map ||
        value['kind'] != kind.name ||
        value['items'] is! List) {
      throw StateError('Selection has the wrong object type: $ref');
    }
    return (value['items'] as List)
        .map((r) => Map<String, Object?>.from(r as Map))
        .toList();
  }

  bool _matchesSelection(
    String? ref,
    CollectionKind kind,
    Map<String, Object?> row,
    CharacterInstance actor,
    CharacterInstance target,
  ) =>
      ref == null ||
      _boundQueryRows(
        ref,
        kind,
        actor,
        target,
      ).any((r) => r['instanceId'] == row['instanceId']);

  bool _queryRange(
    Object? raw,
    EffectValue? minimum,
    EffectValue? maximum,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final n = raw! as num;
    return (minimum == null || n >= _numberValue(minimum, actor, target)) &&
        (maximum == null || n <= _numberValue(maximum, actor, target));
  }

  bool _matchesCardData(
    Map<String, Object?> c,
    CardQuery q,
    CharacterInstance actor,
    CharacterInstance target,
  ) {
    final tags = (c['tags']! as List).cast<String>();
    return (q.cardIds.isEmpty || q.cardIds.contains(c['definitionId'])) &&
        !q.excludeCardIds.contains(c['definitionId']) &&
        (q.anyTags.isEmpty || q.anyTags.any(tags.contains)) &&
        q.allTags.every(tags.contains) &&
        !q.excludeTags.any(tags.contains) &&
        tags.length >= q.minimumTags &&
        (q.maximumTags == null || tags.length <= q.maximumTags!) &&
        (q.attacks == null || c['attacks'] == q.attacks) &&
        (q.isLimited == null || c['isLimited'] == q.isLimited) &&
        (q.disabled == null || c['disabled'] == q.disabled) &&
        _queryRange(
          c['mpCost'],
          q.minimumMpCost,
          q.maximumMpCost,
          actor,
          target,
        ) &&
        _matchesSelection(q.selection, CollectionKind.cards, c, actor, target);
  }

  bool _matchesCard(
    CardInstance c,
    CardQuery q,
    CharacterInstance actor,
    CharacterInstance target,
  ) => _matchesCardData(_cardQueryData(c), q, actor, target);

  bool _matchesStatusData(
    Map<String, Object?> s,
    StatusQuery q,
    CharacterInstance actor,
    CharacterInstance target,
  ) =>
      (s['statusEffect'] == true ||
          q.statusId != null ||
          q.statusIds.isNotEmpty ||
          q.instanceId != null ||
          q.selection != null) &&
      (q.statusIds.isEmpty || q.statusIds.contains(s['definitionId'])) &&
      !q.excludeStatusIds.contains(s['definitionId']) &&
      (q.minimumStacks == null ||
          (s['stacks']! as int) >=
              _amount(0, q.minimumStacks, actor, target)) &&
      (q.maximumStacks == null ||
          (s['stacks']! as int) <=
              _amount(0, q.maximumStacks, actor, target)) &&
      (!q.decayingOnly || s['decaying'] == true) &&
      (!q.extendableOnly ||
          (s['anomaly'] == false &&
              (s['stacks']! as int) < (s['maxStacks']! as int))) &&
      (q.instanceId == null || s['instanceId'] == q.instanceId) &&
      (!q.chosen || s['instanceId'] == _chosenStatus?.instanceId) &&
      (q.statusId == null || s['definitionId'] == q.statusId) &&
      (q.minimumIntensity == null ||
          (s['intensity']! as int) >= q.minimumIntensity!) &&
      _queryRange(
        s['intensity'],
        q.minimumIntensityValue,
        q.maximumIntensity,
        actor,
        target,
      ) &&
      (q.negative == null || s['negative'] == q.negative) &&
      (q.hasIntensity == null || s['hasIntensity'] == q.hasIntensity) &&
      (q.includeAnomalies || s['anomaly'] == false) &&
      (q.source == null ||
          s['sourceId'] == _referenceValue(q.source!, actor, target)) &&
      _matchesSelection(q.selection, CollectionKind.statuses, s, actor, target);

  bool _matchesMarkData(
    Map<String, Object?> m,
    MarkQuery q,
    CharacterInstance actor,
    CharacterInstance target,
  ) =>
      (q.markIds.isEmpty || q.markIds.contains(m['definitionId'])) &&
      !q.excludeMarkIds.contains(m['definitionId']) &&
      (q.group == null || m['group'] == q.group) &&
      (q.source == null ||
          m['sourceId'] == _referenceValue(q.source!, actor, target)) &&
      _queryRange(m['count'], q.minimumCount, q.maximumCount, actor, target) &&
      _matchesSelection(q.selection, CollectionKind.marks, m, actor, target);

  bool _matchesSkillData(
    Map<String, Object?> s,
    SkillQuery q,
    CharacterInstance actor,
    CharacterInstance target,
  ) =>
      (q.skillIds.isEmpty || q.skillIds.contains(s['definitionId'])) &&
      !q.excludeSkillIds.contains(s['definitionId']) &&
      (q.exclusive == null || s['exclusive'] == q.exclusive) &&
      (q.passive == null || s['passive'] == q.passive) &&
      (q.borrowed == null || s['borrowed'] == q.borrowed) &&
      _queryRange(
        s['cooldown'],
        q.minimumCooldown,
        q.maximumCooldown,
        actor,
        target,
      ) &&
      _matchesSelection(q.selection, CollectionKind.skills, s, actor, target);

  List<CardInstance> _queryCards(
    CardZone zone,
    List<CharacterInstance> owners,
  ) => switch (zone) {
    CardZone.hand => owners.expand((c) => c.hand).toList(),
    CardZone.drawPile => state.drawPile.toList(),
    CardZone.discardPile => state.discardPile.toList(),
    CardZone.action => _effectCards.toList(),
    CardZone.initialDeck => [
      for (final (i, id) in setup.deck.indexed)
        CardInstance('initial_$i', catalog.cards[id]!),
    ],
  };

  String? _querySelection(CollectionQuery q) => switch (q.kind) {
    CollectionKind.cards => q.cards.selection,
    CollectionKind.statuses => q.statuses.selection,
    CollectionKind.marks => q.marks.selection,
    CollectionKind.skills => q.skills.selection,
    CollectionKind.characters => q.characters.selection,
    CollectionKind.records => null,
  };

  List<Map<String, Object?>> _collectionRows(
    CollectionQuery q,
    CharacterInstance actor,
    List<CharacterInstance> owners,
  ) {
    if (_previewMode &&
        (q.kind == CollectionKind.records ||
            q.kind == CollectionKind.marks ||
            q.kind == CollectionKind.skills ||
            (q.kind == CollectionKind.cards &&
                (q.zone != CardZone.action &&
                    (q.zone != CardZone.hand ||
                        owners.any(
                          (c) => _previewHiddenHands.contains(c.instanceId),
                        )))))) {
      throw const PreviewBoundary('unprojectedCollectionQuery');
    }
    if (_previewMode &&
        q.kind == CollectionKind.characters &&
        q.property == 'handCount' &&
        owners.any((c) => _previewHiddenHands.contains(c.instanceId))) {
      throw const PreviewBoundary('unprojectedCollectionQuery');
    }
    final subject = owners.firstOrNull ?? actor;
    final selection = _querySelection(q);
    final rows = selection == null
        ? <Map<String, Object?>>[]
        : _boundQueryRows(selection, q.kind, actor, subject);
    if (selection == null) {
      switch (q.kind) {
        case CollectionKind.cards:
          for (final c in _queryCards(q.zone, owners)) {
            final owner = owners.where((o) => o.hand.contains(c)).firstOrNull;
            rows.add(_cardQueryData(c, owner?.instanceId));
          }
        case CollectionKind.statuses:
          for (final o in owners) {
            rows.addAll(o.statuses.map(_statusQueryData));
          }
        case CollectionKind.marks:
          for (final o in owners) {
            rows.addAll(o.marks.map(_markQueryData));
          }
        case CollectionKind.skills:
          for (final o in owners) {
            rows.addAll(o.skills.map((s) => _skillQueryData(s, o.instanceId)));
          }
        case CollectionKind.records:
          for (final owner in owners) {
            final records = _variableCell(q.variable!, owner).value as List;
            for (final record in records) {
              final row = record is Map
                  ? Map<String, Object?>.from(record)
                  : <String, Object?>{'value': record};
              final previous = _queryRecord;
              _queryRecord = row;
              try {
                if (_conditionMatches(q.characters.when, actor, owner)) {
                  rows.add(row);
                }
              } finally {
                _queryRecord = previous;
              }
            }
          }
        case CollectionKind.characters:
          rows.addAll(
            owners
                .where((o) => _conditionMatches(q.characters.when, actor, o))
                .map(_characterQueryData),
          );
      }
    }
    final result = rows.where((row) {
      final owner =
          state.players
              .map((p) => p.character)
              .where((c) => c.instanceId == row['ownerId'])
              .firstOrNull ??
          subject;
      return switch (q.kind) {
        CollectionKind.cards => _matchesCardData(row, q.cards, actor, owner),
        CollectionKind.statuses => _matchesStatusData(
          row,
          q.statuses,
          actor,
          owner,
        ),
        CollectionKind.marks => _matchesMarkData(row, q.marks, actor, owner),
        CollectionKind.skills => _matchesSkillData(row, q.skills, actor, owner),
        CollectionKind.characters =>
          _conditionMatches(q.characters.when, actor, owner) &&
              _matchesSelection(
                q.characters.selection,
                CollectionKind.characters,
                row,
                actor,
                owner,
              ),
        CollectionKind.records => true,
      };
    }).toList();
    if (q.kind == CollectionKind.statuses &&
        q.statuses.latest &&
        result.isNotEmpty) {
      return [
        for (final owner in owners)
          ...result
              .where((r) => r['ownerId'] == owner.instanceId)
              .toList()
              .reversed
              .take(1),
      ];
    }
    return result;
  }

  double _collectionNumber(
    CollectionQuery q,
    CharacterInstance actor,
    CharacterInstance subject,
  ) {
    final owners =
        (q.among == null
                ? [subject]
                : _effectTargets(actor, [subject.instanceId], q.among!))
            .where((c) => q.includeDead || c.alive)
            .toList();
    final rows = _collectionRows(q, actor, owners);
    if (q.aggregate == QueryAggregate.count) return rows.length.toDouble();
    if (q.aggregate == QueryAggregate.exists) return rows.isEmpty ? 0 : 1;
    final property =
        q.property ??
        switch (q.kind) {
          CollectionKind.cards => 'mpCost',
          CollectionKind.statuses => 'stacks',
          CollectionKind.marks => 'count',
          CollectionKind.skills => 'cooldown',
          CollectionKind.characters => 'hp',
          CollectionKind.records => 'value',
        };
    final values = rows.map((r) => _recordNumber(r, property)).toList();
    if (values.isEmpty) return 0;
    return switch (q.aggregate) {
      QueryAggregate.sum => values.fold(0, (a, b) => a + b),
      QueryAggregate.min => values.reduce((a, b) => a < b ? a : b),
      QueryAggregate.max => values.reduce((a, b) => a > b ? a : b),
      _ => throw StateError('Invalid aggregate'),
    };
  }

  double _recordNumber(Map<String, Object?> row, String property) {
    Object? value = row;
    for (final part in property.split('.')) {
      value = value is Map ? value[part] : null;
    }
    if (value == null) return 0;
    if (value is! num || !value.isFinite) {
      throw StateError(
        'Aggregate property must be finite numeric data: $property',
      );
    }
    return value.toDouble();
  }

  Map<String, Object?> _objectBinding(
    String name,
    CollectionKind kind,
    List<Map<String, Object?>> rows,
  ) => {
    'kind': kind.name,
    'items': rows.map((r) => Map<String, Object?>.unmodifiable(r)).toList(),
  };

  void _bindObjects(
    String name,
    CollectionKind kind,
    List<Map<String, Object?>> rows,
  ) {
    _abilityLocals[name] = _objectBinding(name, kind, rows);
  }
}
