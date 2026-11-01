part of 'definitions.dart';

enum CollectionKind { cards, statuses, marks, skills, characters, records }

enum QueryAggregate { count, exists, sum, min, max }

enum CardZone { hand, drawPile, discardPile, initialDeck, action }

final class CardQuery {
  const CardQuery({
    this.cardIds = const [],
    this.excludeCardIds = const [],
    this.anyTags = const [],
    this.allTags = const [],
    this.excludeTags = const [],
    this.minimumTags = 0,
    this.maximumTags,
    this.attacks,
    this.isLimited,
    this.disabled,
    this.minimumMpCost,
    this.maximumMpCost,
    this.selection,
  });
  final List<String> cardIds;
  final List<String> excludeCardIds;
  final List<String> anyTags;
  final List<String> allTags;
  final List<String> excludeTags;
  final int minimumTags;
  final int? maximumTags;
  final bool? attacks;
  final bool? isLimited;
  final bool? disabled;
  final EffectValue? minimumMpCost;
  final EffectValue? maximumMpCost;
  final String? selection;
}

final class MarkQuery {
  const MarkQuery({
    this.markIds = const [],
    this.excludeMarkIds = const [],
    this.group,
    this.source,
    this.minimumCount,
    this.maximumCount,
    this.selection,
  });
  final List<String> markIds;
  final List<String> excludeMarkIds;
  final String? group;

  /// Character reference, e.g. self.id or event.source; omitted means any.
  final String? source;
  final EffectValue? minimumCount;
  final EffectValue? maximumCount;
  final String? selection;
}

final class SkillQuery {
  const SkillQuery({
    this.skillIds = const [],
    this.excludeSkillIds = const [],
    this.exclusive,
    this.passive,
    this.borrowed,
    this.minimumCooldown,
    this.maximumCooldown,
    this.selection,
  });
  final List<String> skillIds;
  final List<String> excludeSkillIds;
  final bool? exclusive;
  final bool? passive;
  final bool? borrowed;
  final EffectValue? minimumCooldown;
  final EffectValue? maximumCooldown;
  final String? selection;
}

final class CharacterQuery {
  const CharacterQuery({this.when, this.selection});
  final ConditionDefinition? when;
  final String? selection;
}

/// A pure query sharing its typed filters with selection and mutation.
final class CollectionQuery {
  const CollectionQuery({
    required this.kind,
    this.aggregate = QueryAggregate.count,
    this.property,
    this.zone = CardZone.hand,
    this.among,
    this.includeDead = false,
    this.variable,
    this.cards = const CardQuery(),
    this.statuses = const StatusQuery(),
    this.marks = const MarkQuery(),
    this.skills = const SkillQuery(),
    this.characters = const CharacterQuery(),
  });
  final CollectionKind kind;
  final QueryAggregate aggregate;
  final String? property;
  final CardZone zone;

  /// Omitted queries only the numeric expression's subject.
  final EffectTarget? among;
  final bool includeDead;
  final String? variable;
  final CardQuery cards;
  final StatusQuery statuses;
  final MarkQuery marks;
  final SkillQuery skills;
  final CharacterQuery characters;
}

/// Select objects without implicitly discarding, resetting or editing them.
final class ChooseObjects extends EffectDefinition {
  const ChooseObjects({
    required this.query,
    required this.bind,
    this.minimum = const EffectValue(constant: 1),
    this.maximum = const EffectValue(constant: 1),
    this.reveal = false,
    this.chooser = ChoiceChooser.actor,
    EffectTarget target = EffectTarget.self,
  }) : super(target);
  final CollectionQuery query;
  final String bind;
  final EffectValue minimum;
  final EffectValue maximum;
  final bool reveal;
  final ChoiceChooser chooser;
}

final class EditMarks extends EffectDefinition {
  const EditMarks({
    this.query = const MarkQuery(),
    this.mode = StatusEditMode.add,
    this.amount = const EffectValue(),
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final MarkQuery query;
  final StatusEditMode mode;
  final EffectValue amount;
}

final class TransferMarks extends EffectDefinition {
  const TransferMarks({
    this.query = const MarkQuery(),
    this.to = EffectTarget.self,
    this.amount,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final MarkQuery query;
  final EffectTarget to;
  final EffectValue? amount;
}

final class EditSkills extends EffectDefinition {
  const EditSkills({
    this.query = const SkillQuery(),
    this.mode = StatusEditMode.add,
    this.amount = const EffectValue(),
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final SkillQuery query;
  final StatusEditMode mode;
  final EffectValue amount;
}

final class MoveCards extends EffectDefinition {
  const MoveCards({
    this.query = const CardQuery(),
    this.zone = CardZone.hand,
    this.destination = CardDestination.hand,
    this.recipient = EffectTarget.self,
    this.copy = false,
    this.random = false,
    this.amount,
    EffectTarget target = EffectTarget.selected,
  }) : super(target);
  final CardQuery query;
  final CardZone zone;
  final CardDestination destination;
  final EffectTarget recipient;
  final bool copy;
  final bool random;
  final EffectValue? amount;
}
