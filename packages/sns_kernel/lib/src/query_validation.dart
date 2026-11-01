part of 'engine.dart';

extension _QueryValidation on GameKernel {
  Iterable<EffectValue> _cardQueryValues(CardQuery q) sync* {
    if (q.minimumMpCost != null) yield q.minimumMpCost!;
    if (q.maximumMpCost != null) yield q.maximumMpCost!;
  }

  Iterable<EffectValue> _statusQueryValues(StatusQuery q) sync* {
    if (q.minimumStacks != null) yield q.minimumStacks!;
    if (q.minimumIntensityValue != null) yield q.minimumIntensityValue!;
    if (q.maximumStacks != null) yield q.maximumStacks!;
    if (q.maximumIntensity != null) yield q.maximumIntensity!;
  }

  Iterable<EffectValue> _markQueryValues(MarkQuery q) sync* {
    if (q.minimumCount != null) yield q.minimumCount!;
    if (q.maximumCount != null) yield q.maximumCount!;
  }

  Iterable<EffectValue> _skillQueryValues(SkillQuery q) sync* {
    if (q.minimumCooldown != null) yield q.minimumCooldown!;
    if (q.maximumCooldown != null) yield q.maximumCooldown!;
  }

  Iterable<EffectValue> _collectionValues(CollectionQuery q) sync* {
    yield* _cardQueryValues(q.cards);
    yield* _statusQueryValues(q.statuses);
    yield* _markQueryValues(q.marks);
    yield* _skillQueryValues(q.skills);
    yield* _conditionValues(q.characters.when);
    for (final ref in _collectionReferences(q)) {
      yield EffectValue(reference: ref);
    }
  }

  Iterable<String> _collectionReferences(CollectionQuery q) sync* {
    for (final ref in [
      q.cards.selection,
      q.statuses.selection,
      q.statuses.source,
      q.marks.selection,
      q.marks.source,
      q.skills.selection,
      q.characters.selection,
    ]) {
      if (ref != null) yield ref;
    }
  }

  Iterable<String> _directQueryEffectReferences(EffectDefinition e) sync* {
    CardQuery? cards;
    StatusQuery? statuses;
    MarkQuery? marks;
    SkillQuery? skills;
    if (e is ChooseCards) cards = e.query;
    if (e is GenerateChosenCard) cards = e.query;
    if (e is RandomDiscard) cards = e.query;
    if (e is MoveCards) cards = e.query;
    if (e is EditStatus) statuses = e.query;
    if (e is TransferStatus) statuses = e.query;
    if (e is EditMarks) marks = e.query;
    if (e is TransferMarks) marks = e.query;
    if (e is EditSkills) skills = e.query;
    if (e is ModifyCooldown) skills = e.query;
    if (e is ChooseEffect) {
      cards = e.cardQuery;
      statuses = e.statusQuery;
      skills = e.skillQuery;
    }
    if (e is ChooseObjects) yield* _collectionReferences(e.query);
    for (final ref in [
      cards?.selection,
      statuses?.selection,
      statuses?.source,
      marks?.selection,
      marks?.source,
      skills?.selection,
    ]) {
      if (ref != null) yield ref;
    }
  }

  Iterable<String> _queryEffectReferences(EffectDefinition e) sync* {
    yield* _directQueryEffectReferences(e);
    for (final value in _effectValues(e).expand(_valueTree)) {
      if (value.reference != null) yield value.reference!;
    }
  }

  Iterable<EffectValue> _queryEffectValues(EffectDefinition e) sync* {
    if (e is ChooseObjects) {
      yield e.minimum;
      yield e.maximum;
      yield* _collectionValues(e.query);
    }
    if (e is ChooseTargets) {
      if (e.minimumValue != null) yield e.minimumValue!;
      if (e.maximumValue != null) yield e.maximumValue!;
    }
    if (e is GrantActions && e.value != null) yield e.value!;
    if (e is PayMp && e.value != null) yield e.value!;
    if (e is ModifyCooldown) {
      if (e.value != null) yield e.value!;
      yield* _skillQueryValues(e.query);
    }
    if (e is RandomDiscard) {
      if (e.value != null) yield e.value!;
      yield* _cardQueryValues(e.query);
    }
    if (e is ChooseCards) {
      yield e.minimum;
      yield e.maximum;
      yield* _cardQueryValues(e.query);
    }
    if (e is GenerateChosenCard) yield* _cardQueryValues(e.query);
    if (e is ChooseEffect) {
      yield* _cardQueryValues(e.cardQuery);
      yield* _skillQueryValues(e.skillQuery);
      yield* _statusQueryValues(e.statusQuery);
    }
    if (e is EditStatus) yield* _statusQueryValues(e.query);
    if (e is TransferStatus) yield* _statusQueryValues(e.query);
    if (e is EditMarks) {
      yield e.amount;
      yield* _markQueryValues(e.query);
    }
    if (e is TransferMarks) {
      if (e.amount != null) yield e.amount!;
      yield* _markQueryValues(e.query);
    }
    if (e is EditSkills) {
      yield e.amount;
      yield* _skillQueryValues(e.query);
    }
    if (e is MoveCards) {
      if (e.amount != null) yield e.amount!;
      yield* _cardQueryValues(e.query);
    }
  }

  void _checkSelectionReference(String? ref) {
    if (ref == null) return;
    _checkReference(ref);
    if (!ref.startsWith('local.')) {
      throw StateError('Selection must reference a local binding');
    }
  }

  void _checkCardQuery(CardQuery q, [int depth = 0]) {
    if (q.minimumTags < 0 ||
        (q.maximumTags != null && q.maximumTags! < q.minimumTags)) {
      throw StateError('Invalid card tag range');
    }
    for (final id in [...q.cardIds, ...q.excludeCardIds]) {
      _require(catalog.cards, id);
    }
    for (final value in _cardQueryValues(q)) {
      _checkValue(value, depth + 1);
    }
    _checkSelectionReference(q.selection);
  }

  void _checkMarkQuery(MarkQuery q, [int depth = 0]) {
    _checkSourceReference(q.source);
    for (final id in [...q.markIds, ...q.excludeMarkIds]) {
      _require(catalog.marks, id);
    }
    for (final value in _markQueryValues(q)) {
      _checkValue(value, depth + 1);
    }
    _checkSelectionReference(q.selection);
  }

  void _checkSkillQuery(SkillQuery q, [int depth = 0]) {
    for (final id in [...q.skillIds, ...q.excludeSkillIds]) {
      _require(catalog.skills, id);
    }
    for (final value in _skillQueryValues(q)) {
      _checkValue(value, depth + 1);
    }
    _checkSelectionReference(q.selection);
  }

  void _checkCollectionQuery(CollectionQuery q, [int depth = 0]) {
    if (++_queryValidationDepth > 16) {
      _queryValidationDepth--;
      throw StateError('Collection query nesting is too deep');
    }
    if (q.kind == CollectionKind.records) _recordQueryValidationDepth++;
    try {
      if (depth > 16) throw StateError('Collection query nesting is too deep');
      final properties = switch (q.kind) {
        CollectionKind.cards => {'mpCost', 'tagCount'},
        CollectionKind.statuses => {'stacks', 'intensity'},
        CollectionKind.marks => {'count'},
        CollectionKind.skills => {'cooldown', 'mpCost', 'uses'},
        CollectionKind.records => <String>{},
        CollectionKind.characters => {
          'hp',
          'missingHp',
          'maxHp',
          'mp',
          'maxMp',
          'attack',
          'defense',
          'handCount',
          'shield',
        },
      };
      if (q.kind != CollectionKind.records &&
          q.property != null &&
          !properties.contains(q.property)) {
        throw StateError('Invalid aggregate property: ${q.property}');
      }
      _checkCardQuery(q.cards, depth);
      _checkMarkQuery(q.marks, depth);
      _checkSkillQuery(q.skills, depth);
      _checkStatusQuery(q.statuses, depth);
      for (final value in _statusQueryValues(q.statuses)) {
        _checkValue(value, depth + 1);
      }
      _checkChoiceCondition(q.characters.when);
      _checkSelectionReference(q.characters.selection);
      if (q.kind == CollectionKind.records &&
          _require(catalog.variables, q.variable ?? '').type !=
              VariableType.list) {
        throw StateError('Record query requires a list variable');
      }
    } finally {
      if (q.kind == CollectionKind.records) _recordQueryValidationDepth--;
      _queryValidationDepth--;
    }
  }

  void _checkQueryEffect(EffectDefinition e) {
    if (e is ScheduleEffect &&
        !e.captureValues &&
        _walkEffects(e.effects).any(
          (c) => _queryEffectReferences(c).any((r) => r.startsWith('local.')),
        )) {
      throw StateError('Deferred local values require captureValues');
    }
    if (e is ScheduleEffect &&
        _walkEffects(e.effects).any((c) => c is ChooseObjects)) {
      throw StateError('Object selections require an active ability frame');
    }
    if (e is RandomDiscard) _checkCardQuery(e.query);
    if (e is ModifyCooldown) _checkSkillQuery(e.query);
    if (e is ChooseCards) {
      _checkCardQuery(e.query);
      if (e.bind != null) _checkBinding(e.bind!);
    }
    if (e is GenerateChosenCard) _checkCardQuery(e.query);
    if (e is ChooseEffect) {
      _checkCardQuery(e.cardQuery);
      _checkSkillQuery(e.skillQuery);
    }
    if (e is ChooseObjects) {
      _checkCollectionQuery(e.query);
      if (e.query.kind == CollectionKind.records) {
        throw StateError('Record queries do not open choices');
      }
      _checkBinding(e.bind);
      if (e.query.among != null) {
        throw StateError('Object selection uses target, not among');
      }
    }
    if (e is EditMarks) _checkMarkQuery(e.query);
    if (e is TransferMarks) _checkMarkQuery(e.query);
    if (e is EditSkills) _checkSkillQuery(e.query);
    if (e is MoveCards) {
      _checkCardQuery(e.query);
      if (!e.copy &&
          (e.zone == CardZone.initialDeck || e.zone == CardZone.action)) {
        throw StateError('This card zone can only be copied');
      }
    }
  }

  void _checkSourceReference(String? ref) {
    if (ref == null) return;
    if (!const {
      'self.id',
      'target.id',
      'event.source',
      'event.target',
      'event.actorId',
      'event.sourceId',
      'event.targetId',
    }.contains(ref)) {
      throw StateError('Source must be a character reference');
    }
  }

  void _checkBinding(String name) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
      throw StateError('Invalid local binding');
    }
  }
}
