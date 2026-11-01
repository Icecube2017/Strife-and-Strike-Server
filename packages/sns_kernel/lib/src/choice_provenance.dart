part of 'engine.dart';

extension _ChoiceProvenance on GameKernel {
  void _annotateChoiceSource() {
    final choice = state.choice;
    if (choice == null) return;
    if (choice.details['source'] is Map) return;
    final actor = _player(choice.playerId).character;
    final input = state.preparation?.input;
    final actions = choice.options.map((o) => o['action']).toSet();
    // Standalone mechanisms can open outside the ordinary trigger context.
    bool matches(TraitDefinition trait) {
      final m = trait.mechanisms;
      return actions.contains('generatedTarget') &&
              (m.has<GeneratedShieldActionRule>() ||
                  trait.triggers.any(
                    (t) => _walkEffects(
                      t.effects,
                    ).any((e) => e is GenerateRandomAction),
                  )) ||
          actions.contains('skipTimeReserve') && m.has<TimeReserveRule>() ||
          actions.contains('buddyDrain') && m.has<BuddyBlockRule>() ||
          actions.contains('supportAttack') && m.has<SupportStanceRule>() ||
          actions.contains('spendFruit') && m.has<FruitAttackRule>() ||
          actions.contains('restoreDiscard') && m.has<TurnSaveRule>() ||
          actions.contains('borrow') && m.has<SkillBorrowRule>() ||
          actions.intersection({
                'discardForDream',
                'confirmDream',
                'keepDream',
                'clearDream',
              }).isNotEmpty &&
              m.has<DreamCraftRule>() ||
          actions.contains('decree') && m.has<DecreeRule>() ||
          actions.intersection({'consumePrey', 'placePrey'}).isNotEmpty &&
              m.has<PreyRule>();
    }

    final explicit = choice.options
        .map((o) => o['traitId'])
        .whereType<String>()
        .firstOrNull;
    final definition =
        explicit ??
        actor.traits
            .where((t) => matches(t.definition))
            .firstOrNull
            ?.definition
            .id ??
        _currentTrigger?.trait?.definition.id ??
        _currentTrigger?.skill?.definition.id ??
        _currentTrigger?.status?.definition.id ??
        _rollOrigin?.definitionId ??
        input?['definitionId'] ??
        actor.skills
            .where((s) => s.instanceId == input?['skillInstanceId'])
            .firstOrNull
            ?.definition
            .id ??
        actor.traits
            .where((t) => t.instanceId == input?['traitInstanceId'])
            .firstOrNull
            ?.definition
            .id ??
        _choiceSourceContext?['definitionId'];
    final kind = catalog.traits.containsKey(definition)
        ? 'trait'
        : catalog.skills.containsKey(definition)
        ? 'skill'
        : catalog.statuses.containsKey(definition)
        ? 'status'
        : catalog.cards.containsKey(definition)
        ? 'card'
        : null;
    if (kind == null) return;
    state.choice = PendingChoice(
      id: choice.id,
      playerId: choice.playerId,
      kind: choice.kind,
      options: choice.options,
      details: {
        ...choice.details,
        'source': {'kind': kind, 'definitionId': definition},
      },
    );
  }
}
