part of 'content_loader.dart';

void _queryKeys(_Json q, Set<String> allowed) {
  for (final key in q.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('Unknown query filter: $key');
    }
  }
}

CardQuery _cardQuery(_Json q) {
  _queryKeys(q, {
    'cardIds',
    'excludeCardIds',
    'anyTags',
    'allTags',
    'excludeTags',
    'minimumTags',
    'maximumTags',
    'attacks',
    'isLimited',
    'disabled',
    'minimumMpCost',
    'maximumMpCost',
    'selection',
  });
  return CardQuery(
    cardIds: _strings(q, 'cardIds'),
    excludeCardIds: _strings(q, 'excludeCardIds'),
    anyTags: _strings(q, 'anyTags'),
    allTags: _strings(q, 'allTags'),
    excludeTags: _strings(q, 'excludeTags'),
    minimumTags: _integer(q, 'minimumTags'),
    maximumTags: q['maximumTags'] as int?,
    attacks: q['attacks'] as bool?,
    isLimited: q['isLimited'] as bool?,
    disabled: q['disabled'] as bool?,
    minimumMpCost: _value(q, 'minimumMpCost'),
    maximumMpCost: _value(q, 'maximumMpCost'),
    selection: q['selection'] as String?,
  );
}

MarkQuery _markQuery(_Json q) {
  _queryKeys(q, {
    'markIds',
    'excludeMarkIds',
    'group',
    'source',
    'minimumCount',
    'maximumCount',
    'selection',
  });
  return MarkQuery(
    markIds: _strings(q, 'markIds'),
    excludeMarkIds: _strings(q, 'excludeMarkIds'),
    group: q['group'] as String?,
    source: q['source'] as String?,
    minimumCount: _value(q, 'minimumCount'),
    maximumCount: _value(q, 'maximumCount'),
    selection: q['selection'] as String?,
  );
}

SkillQuery _skillQuery(_Json q) {
  _queryKeys(q, {
    'skillIds',
    'excludeSkillIds',
    'exclusive',
    'passive',
    'borrowed',
    'minimumCooldown',
    'maximumCooldown',
    'selection',
  });
  return SkillQuery(
    skillIds: _strings(q, 'skillIds'),
    excludeSkillIds: _strings(q, 'excludeSkillIds'),
    exclusive: q['exclusive'] as bool?,
    passive: q['passive'] as bool?,
    borrowed: q['borrowed'] as bool?,
    minimumCooldown: _value(q, 'minimumCooldown'),
    maximumCooldown: _value(q, 'maximumCooldown'),
    selection: q['selection'] as String?,
  );
}

CollectionQuery _collectionQuery(_Json d, {bool selection = false}) {
  final name = (selection ? d['kind'] : d['field']) as String;
  final kind = CollectionKind.values.byName(switch (name) {
    'card' => 'cards',
    'status' => 'statuses',
    'mark' => 'marks',
    'skill' => 'skills',
    'character' => 'characters',
    _ => name,
  });
  final q = (selection ? d['query'] : d['filter']) as _Json? ?? {};
  if (kind == CollectionKind.statuses && !selection) {
    _queryKeys(q, {
      'statusId',
      'statusIds',
      'excludeStatusIds',
      'negative',
      'hasIntensity',
      'decayingOnly',
      'extendableOnly',
      'instanceId',
      'includeAnomalies',
      'minimumIntensity',
      'maximumIntensity',
      'minimumStacks',
      'maximumStacks',
      'source',
      'selection',
      'latest',
      'chosen',
    });
  }
  if (kind == CollectionKind.characters || kind == CollectionKind.records) {
    _queryKeys(q, {'when', 'selection'});
  }
  return CollectionQuery(
    kind: kind,
    aggregate: QueryAggregate.values.byName(
      d['aggregate'] as String? ?? 'count',
    ),
    property: d['property'] as String?,
    zone: CardZone.values.byName(d['zone'] as String? ?? 'hand'),
    among: d['among'] == null
        ? null
        : EffectTarget.values.byName(d['among'] as String),
    includeDead: _bool(d, 'includeDead'),
    variable: d['variable'] as String?,
    cards: kind == CollectionKind.cards ? _cardQuery(q) : const CardQuery(),
    statuses: kind == CollectionKind.statuses
        ? _statusQuery(q)
        : const StatusQuery(),
    marks: kind == CollectionKind.marks ? _markQuery(q) : const MarkQuery(),
    skills: kind == CollectionKind.skills ? _skillQuery(q) : const SkillQuery(),
    characters: CharacterQuery(
      when: kind == CollectionKind.characters || kind == CollectionKind.records
          ? _condition(q['when'])
          : null,
      selection: q['selection'] as String?,
    ),
  );
}
