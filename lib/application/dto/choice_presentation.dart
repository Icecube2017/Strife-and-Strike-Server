import 'package:sns_kernel/sns_kernel.dart';

/// Transport-only hints. They never participate in kernel recovery verification.
Map<String, Object?> projectChoicePresentation(
  Map<String, Object?> view,
  ContentCatalog catalog,
) {
  final choice = view['choice'];
  if (choice is! Map ||
      choice['playerId'] != view['playerId'] ||
      choice['options'] is! List) {
    return view;
  }
  final kind = choice['kind'];
  final preset =
      const {
        'deckCard',
        'discardPileCard',
        'attackCard',
        'discardCard',
        'takeCard',
        'returnCardToDeck',
      }.contains(kind)
      ? 'cardList'
      : kind == 'character'
      ? 'targets'
      : 'options';
  Map<String, Object?>? source;
  if (kind == 'abilityOption') {
    // A settlement choice explicitly identifies its skill. This takes
    // precedence over an inherited card/roll context such as Refreshment.
    final skills = <String>{};
    for (final option in choice['options'] as List) {
      if (option is! Map) continue;
      final id = option['skillId'] ?? option['definitionId'];
      if (id is String && catalog.skills.containsKey(id)) {
        skills.add(id);
      }
    }
    if (skills.length == 1) {
      source = {'kind': 'skill', 'definitionId': skills.single};
    }
  }
  return {
    ...view,
    'choice': {
      ...choice,
      if (source != null) 'source': source,
      'presentation': {
        'schemaVersion': 1,
        'preset': preset,
        'selection': 'single',
      },
    },
  };
}
