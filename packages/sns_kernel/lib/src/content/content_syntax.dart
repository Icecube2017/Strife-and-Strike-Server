/// Compile the authoring language into the existing typed execution IR.
/// Compatibility spelling stays at this boundary, never in new content.
library;

typedef _Json = Map<String, dynamic>;

Map<String, dynamic> compileContentSyntax(Map<String, dynamic> root) {
  void check(Map<String, dynamic> row, Set<String> allowed) {
    for (final cost in row['costs'] as List? ?? []) {
      if (!allowed.contains((cost as Map)['resource'])) {
        throw FormatException(
          'Cost resource not supported by this definition: ${cost['resource']}',
        );
      }
    }
    for (final option in (row['options'] as Map? ?? {}).values) {
      check(option as Map<String, dynamic>, allowed);
    }
  }

  for (final row in root['cards'] as List? ?? []) {
    check(row as Map<String, dynamic>, {'mp'});
  }
  for (final row in root['skills'] as List? ?? []) {
    check(row as Map<String, dynamic>, {'mp', 'life', 'mark', 'stat'});
  }
  for (final row in root['traits'] as List? ?? []) {
    if ((row as Map)['active'] case final Map<String, dynamic> active) {
      check(active, {'mp', 'mark', 'handCard'});
    }
  }
  for (final row in root['statuses'] as List? ?? []) {
    if ((row as Map)['active'] case final Map<String, dynamic> active) {
      check(active, <String>{});
    }
  }
  return _compile(root)! as Map<String, dynamic>;
}

Object? _compile(Object? value) {
  if (value is List) return value.map(_compile).toList();
  if (value is! Map<String, dynamic>) return value;
  final d = <String, dynamic>{
    for (final e in value.entries)
      e.key: ['literal', 'initial', 'references'].contains(e.key)
          ? e.value
          : _compile(e.value),
  };
  if (d['query'] is String) {
    if (d.containsKey('field')) {
      throw const FormatException('Use one numeric query');
    }
    d['field'] = d.remove('query');
  }
  if (d.containsKey('on')) {
    if (d.containsKey('timing')) {
      throw const FormatException('Use on, not both trigger spellings');
    }
    d['timing'] = d.remove('on');
    if (d.containsKey('accumulate')) {
      if (d.containsKey('counterUpdates')) {
        throw const FormatException('Use one counter accumulation form');
      }
      d['counterUpdates'] = d.remove('accumulate');
    }
    final limit = d.remove('limit') as _Json?;
    if (limit != null) {
      d['maxUses'] = limit['count'];
      d['limitWindow'] = limit['per'] ?? 'never';
      if (limit['group'] != null) d['limitGroup'] = limit['group'];
    }
    final repeat = d.remove('repeat') as _Json?;
    if (repeat != null) {
      d['repeatPerAmount'] = repeat['perEventUnit'] ?? false;
      d['scaleWithIntensity'] = repeat['scaleWithIntensity'] ?? true;
      d['oncePerPacket'] = repeat['oncePerPacket'] ?? false;
    }
  }
  if (d['costs'] != null) _compileCosts(d);
  if (d['checkpoint'] case final Map<String, dynamic> checkpoint) {
    if (checkpoint.containsKey('filter') || checkpoint.containsKey('effects')) {
      final compiled = <String, dynamic>{
        'at': checkpoint['at'],
        if (checkpoint.containsKey('extraTurns'))
          'extraTurns': checkpoint['extraTurns'],
        ...?checkpoint['filter'] as _Json?,
      };
      final seen = <String>{};
      for (final raw in checkpoint['effects'] as List? ?? []) {
        final effect = raw as _Json;
        if (!seen.add(effect['op'] as String)) {
          throw const FormatException('Repeated checkpoint operation');
        }
        switch (effect['op']) {
          case 'scalePendingDamage':
            compiled['damageFactor'] = effect['factor'];
          case 'restoreLife':
            compiled['restoreHp'] = effect['amount'];
          case 'shield':
            compiled['shield'] = effect['amount'];
            final duration = effect['duration'] as _Json?;
            if (!const [
              'globalRound',
              'anchoredRound',
            ].contains(duration?['clock'])) {
              throw const FormatException(
                'Checkpoint shield needs a supported duration clock',
              );
            }
            compiled['shieldRounds'] = duration!['after'];
            compiled['shieldClock'] = duration['clock'];
          default:
            throw FormatException(
              'Unsupported settlement operation: ${effect['op']}',
            );
        }
      }
      d['checkpoint'] = compiled;
    }
  }
  if (d['op'] == 'prepareAttack') {
    final attack = d['attack'] as _Json? ?? {};
    final damage = attack['damage'] as _Json? ?? {};
    final dice = attack['dice'] as _Json? ?? {};
    final after = d['after'] as _Json? ?? {};
    final reply = d['reply'] as _Json?;
    final copy = after['copyDamage'] as _Json?;
    if (copy != null &&
        (!const ['actualDamage', 'actualHpLost'].contains(copy['basis']) ||
            copy['kind'] != 'primary')) {
      throw const FormatException('Unsupported attack copy basis');
    }
    if (reply != null &&
        reply['dice'] != null &&
        (reply['dice'] as _Json)['count'] != (dice['count'] ?? 1)) {
      throw const FormatException(
        'Reciprocal dice count must equal prepared dice count',
      );
    }
    if (reply != null &&
        (reply['against'] != 'self' ||
            reply['target'] != 'primaryTarget' ||
            reply['consume'] != 'roll')) {
      throw const FormatException('Unsupported reciprocal attack lifecycle');
    }
    final prepared = {
      'op': 'armAttack',
      'target': d['target'] ?? 'self',
      'damageMultiplier': damage['factor'] ?? 1,
      'diceCount': dice['count'] ?? 1,
      'fixedMaximum': dice['fixedMaximum'] ?? false,
      'onHit': attack['onHit'] ?? <Object?>[],
      'after': attack['after'] ?? <Object?>[],
      'rotationBonus': attack['rotationBonus'] ?? <String, Object?>{},
      'rotationTake': attack['rotationTake'] ?? 2,
      'copyDamage': copy != null,
      'copyDamageBasis': copy?['basis'] ?? 'actualDamage',
      'reciprocalDice': reply != null,
    };
    d
      ..clear()
      ..addAll(prepared);
  }
  if (d['op'] == 'choose' && d.containsKey('bind')) {
    if (d['kind'] != 'character' || d.containsKey('effects')) {
      throw const FormatException(
        'Bound choose is a character selection node; put effects after it',
      );
    }
    d['op'] = 'chooseTargets';
  }
  if (d['op'] == 'draw' && d.containsKey('amount')) {
    if (d.containsKey('count')) {
      throw const FormatException('Use one draw amount');
    }
    d['count'] = d.remove('amount');
  }
  if (d['op'] != null && d['target'] is Map<String, dynamic>) {
    final target = d['target'] as Map<String, dynamic>;
    if (target.keys.length != 1 || target['ref'] is! String) {
      throw const FormatException('Target must be a reference');
    }
    d['target'] = 'selected';
    return {
      'op': 'withTargets',
      'ref': target['ref'],
      'effects': [d],
    };
  }
  return d;
}

void _compileCosts(_Json d) {
  if ([
    'mpCost',
    'lifeCost',
    'markCosts',
    'statCosts',
    'discardCount',
  ].any(d.containsKey)) {
    throw const FormatException('Do not mix costs with legacy fee fields');
  }
  final costs = d.remove('costs') as List;
  final marks = <_Json>[];
  final stats = <String, int>{};
  for (final raw in costs) {
    final cost = raw as _Json;
    final amount = cost['amount'];
    if (amount is Map &&
        cost['resource'] == 'life' &&
        !(amount['op'] == 'multiply' &&
            (amount['args'] as List?)?.any(
                  (x) => x is Map && x['ref'] == 'input.number',
                ) ==
                true)) {
      if (d.containsKey('lifeCostValue')) {
        throw const FormatException('Duplicate life fee');
      }
      d['lifeCostValue'] = amount;
      continue;
    }
    if (amount is Map && const {'life', 'mp'}.contains(cost['resource'])) {
      final field = cost['resource'] == 'mp'
          ? 'mpCostPerUnit'
          : 'lifeCostPerUnit';
      final args = amount['args'] as List? ?? [];
      final unit = args.whereType<int>().firstOrNull;
      final input = args.whereType<Map<String, dynamic>>().firstOrNull;
      if (amount['op'] != 'multiply' ||
          args.length != 2 ||
          unit == null ||
          unit <= 0 ||
          input?['ref'] != 'input.number' ||
          d['numberParameter'] == null) {
        throw const FormatException(
          'Parameterized resource fee must be a positive integer times input.number',
        );
      }
      final parameter = d['numberParameter'] as _Json;
      if (parameter.containsKey(field)) {
        throw const FormatException('Do not mix parameter cost spellings');
      }
      parameter[field] = unit;
      continue;
    }
    if (amount is! int || amount < 0) {
      throw const FormatException('Cost amount must be a nonnegative integer');
    }
    switch (cost['resource']) {
      case 'mp':
        d['mpCost'] = (d['mpCost'] as int? ?? 0) + amount;
      case 'life':
        d['lifeCost'] = (d['lifeCost'] as int? ?? 0) + amount;
      case 'mark':
        if (amount == 0) {
          throw const FormatException('Mark cost must be positive');
        }
        marks.add({'markId': cost['id'], 'amount': amount});
      case 'stat':
        final id = cost['id'] as String;
        stats[id] = (stats[id] ?? 0) + amount;
      case 'handCard':
        d['discardCount'] = (d['discardCount'] as int? ?? 0) + amount;
      default:
        throw FormatException('Unsupported cost resource: ${cost['resource']}');
    }
  }
  if (marks.isNotEmpty) d['markCosts'] = marks;
  if (stats.isNotEmpty) d['statCosts'] = stats;
}
