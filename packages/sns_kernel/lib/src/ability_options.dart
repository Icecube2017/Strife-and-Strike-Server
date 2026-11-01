part of 'engine.dart';

extension _AbilityOptions on GameKernel {
  void _checkChoiceCondition(ConditionDefinition? condition, [int depth = 0]) {
    if (depth > 16) throw StateError('Choice condition is too deeply nested');
    if (condition is PredicateCondition) {
      if (![
            'eq',
            'ne',
            'gt',
            'gte',
            'lt',
            'lte',
            'contains',
            'intersects',
            'disjoint',
          ].contains(condition.op) ||
          condition.arguments.length != 2) {
        throw StateError('Invalid predicate');
      }
      for (final a in condition.arguments) {
        if (a.reference != null) _checkReference(a.reference!);
        if (a.expression != null) _checkValue(a.expression!);
      }
    } else if (condition is AllCondition) {
      if (condition.conditions.isEmpty || condition.conditions.length > 32) {
        throw StateError('Invalid all condition');
      }
      for (final c in condition.conditions) {
        _checkChoiceCondition(c, depth + 1);
      }
    } else if (condition is NotCondition) {
      _checkChoiceCondition(condition.condition, depth + 1);
    } else if (condition is ValueCondition) {
      _checkValue(condition.left);
      _checkValue(condition.right);
    } else if (condition is AnyCondition) {
      if (condition.conditions.isEmpty || condition.conditions.length > 32) {
        throw StateError('Invalid any condition');
      }
      for (final c in condition.conditions) {
        _checkChoiceCondition(c, depth + 1);
      }
    } else if (condition is RelationCondition) {
      if (![
        EffectTarget.self,
        EffectTarget.all,
        EffectTarget.allies,
        EffectTarget.enemies,
        EffectTarget.others,
      ].contains(condition.among)) {
        throw StateError('Invalid relation query');
      }
    } else if (condition is LivingCountCondition) {
      if (condition.atLeast < 0 ||
          condition.atLeast > 1024 ||
          ![
            EffectTarget.all,
            EffectTarget.allies,
            EffectTarget.enemies,
            EffectTarget.others,
            EffectTarget.self,
          ].contains(condition.among)) {
        throw StateError('Invalid living count');
      }
      _checkChoiceCondition(condition.when, depth + 1);
    } else if (condition is HpRatioCondition) {
      if (!condition.fraction.isFinite ||
          condition.fraction < 0 ||
          condition.fraction > 1) {
        throw StateError('Invalid HP ratio');
      }
    } else if (condition is HasStatusQueryCondition) {
      _checkStatusQuery(condition.query);
    } else if (condition is HasStatusCondition) {
      _require(catalog.statuses, condition.statusId);
    } else if (condition is MarkCondition) {
      _require(catalog.marks, condition.markId);
    } else if (condition is VariableCondition) {
      _checkVariableCondition(condition);
    } else if (condition is CounterEqualsCondition) {
      throw StateError('Target filters cannot query legacy counters');
    }
  }

  void _checkAbilityOptions(SelectOptionEffect effect) {
    final ids = effect.options.map((o) => o.id).toSet();
    if (effect.options.isEmpty ||
        effect.options.length > 32 ||
        ids.length != effect.options.length ||
        effect.options.any(
          (o) => !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(o.id),
        )) {
      throw StateError('Invalid ability options');
    }
    for (final option in effect.options) {
      _checkChoiceCondition(option.when);
      _checkEffects(option.effects);
    }
  }

  bool _leadingSelectionAvailable(
    CharacterInstance actor,
    List<String> selected,
    List<EffectDefinition> effects, {
    bool skillTargeting = false,
  }) {
    if (effects.isEmpty) return true;
    final first = effects.first;
    if (first is GenerateChosenCard) {
      return setup.deck.any(
        (id) =>
            !first.exclude.contains(id) &&
            _matchesCard(
              CardInstance('definition_$id', catalog.cards[id]!),
              first.query,
              actor,
              actor,
            ),
      );
    }
    if (first is ChooseCards) {
      return _handCandidates(actor, selected, first).length >=
          _amount(0, first.minimum, actor, actor);
    }
    if (first is ChooseObjects) {
      return _objectCandidates(
            actor,
            selected,
            first,
            enemiesOnly:
                _interactionRulesVersion >= 23 &&
                skillTargeting &&
                _boundTargetsHarm(first.bind, effects.skip(1)),
          ).length >=
          _amount(0, first.minimum, actor, actor);
    }
    if (first is ChooseTargets) {
      return _effectTargets(actor, selected, first.target)
              .where(
                (c) =>
                    c.alive &&
                    _conditionMatches(first.when, actor, c) &&
                    (_interactionRulesVersion < 23 ||
                        !skillTargeting ||
                        !_boundTargetsHarm(first.bind, effects.skip(1)) ||
                        _enemy(actor, c)),
              )
              .length >=
          _amount(first.minimum, first.minimumValue, actor, actor);
    }
    if (first is PayMp) {
      return actor.noMp ||
          actor.mp >=
              _amount(
                first.amount,
                first.value,
                actor,
                actor,
              ).clamp(0, 1000000);
    }
    if (first is ArmAttackTransfer) return actor.armedStatusTransfer == null;
    if (first is SelectOptionEffect) {
      return first.options.any(
        (o) =>
            _conditionMatches(o.when, actor, actor) &&
            _leadingSelectionAvailable(
              actor,
              selected,
              o.effects,
              skillTargeting: skillTargeting,
            ),
      );
    }
    if (first is ChooseEffect && first.kind == ChoiceKind.discardPileCard) {
      return first.optional ||
          state.discardPile.any(
            (c) =>
                !c.disabled && _matchesCard(c, first.cardQuery, actor, actor),
          );
    }
    if (first is ChooseEffect && first.kind == ChoiceKind.deckCard) {
      return first.optional || _copyableDeckCards(first, actor).isNotEmpty;
    }
    if (first is! ChooseEffect ||
        (first.kind != ChoiceKind.character &&
            first.kind != ChoiceKind.status)) {
      return true;
    }
    if (first.optional) return true;
    return _effectTargets(actor, selected, first.target).any(
      (c) =>
          c.alive &&
          (_interactionRulesVersion < 23 ||
              !skillTargeting ||
              first.random ||
              first.preserveSelected ||
              !_selectedEffectsHarm(first.effects) ||
              _enemy(actor, c)) &&
          _conditionMatches(first.when, actor, c) &&
          (first.kind == ChoiceKind.character ||
              _selectionStatuses(c, first, actor: actor).isNotEmpty) &&
          _leadingSelectionAvailable(
            actor,
            first.preserveSelected ? selected : [c.instanceId],
            first.effects,
            skillTargeting: skillTargeting,
          ),
    );
  }

  void _openAbilityOption(
    CharacterInstance actor,
    List<String> selected,
    SelectOptionEffect effect,
    void Function(AbilityOption) select,
    void Function() complete, {
    bool preparing = false,
  }) {
    if (!preparing &&
        _preparedOptions.isNotEmpty &&
        identical(_preparedOptions.first.$1, effect)) {
      select(_preparedOptions.removeFirst().$2);
      return;
    }
    final options = effect.options
        .where(
          (o) =>
              _conditionMatches(o.when, actor, actor) &&
              _leadingSelectionAvailable(actor, selected, o.effects),
        )
        .toList();
    if (options.isEmpty) {
      complete();
      return;
    }
    final chooser = effect.chooser == ChoiceChooser.target
        ? _character(selected.single)
        : actor;
    final player = state.players.firstWhere((p) => p.character == chooser);
    final choice = PendingChoice(
      id: state.id('choice'),
      playerId: player.id,
      kind: ChoiceKind.abilityOption,
      options: [
        for (final o in options) {'optionId': o.id, 'label': o.label},
      ],
    );
    state.choice = choice;
    _choiceContinuation = (id) =>
        select(options.singleWhere((o) => o.id == id));
    _event('choiceOpened', {
      'choiceId': choice.id,
      'playerId': player.id,
      'kind': choice.kind.name,
    });
  }
}
