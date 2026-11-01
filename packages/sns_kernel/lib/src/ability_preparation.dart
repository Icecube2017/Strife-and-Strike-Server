part of 'engine.dart';

final class _PreparedSelection {
  _PreparedSelection(this.effect, this.target, this.status);
  final ChooseEffect effect;
  final CharacterInstance? target;
  final StatusInstance? status;
}

extension _AbilityPreparation on GameKernel {
  // Only leading, state-independent target/status selections can precede payment.
  // A mutation, roll, conditional or blind card operation starts settlement.
  bool _prepareAbility(
    CharacterInstance actor,
    List<EffectDefinition> effects,
    List<String> selected,
    int mpCost,
    void Function() commit, {
    Map<String, Object?> input = const {},
    bool collectAll = false,
  }) {
    if (identical(_automaticActor, actor) ||
        _committingPrepared ||
        effects.isEmpty ||
        (effects.first is ChooseEffect &&
            (effects.first as ChooseEffect).random) ||
        (effects.first is! GenerateChosenCard &&
            effects.first is! ChooseCards &&
            effects.first is! ChooseObjects &&
            effects.first is! ChooseTargets &&
            effects.first is! SelectOptionEffect &&
            !(effects.first is ChooseEffect &&
                [
                  ChoiceKind.character,
                  ChoiceKind.status,
                  ChoiceKind.discardPileCard,
                  ChoiceKind.deckCard,
                ].contains((effects.first as ChooseEffect).kind)))) {
      return false;
    }
    final skillTargeting = input['kind'] == 'useSkill';
    if (!_leadingSelectionAvailable(
      actor,
      selected,
      effects,
      skillTargeting: skillTargeting,
    )) {
      if (effects.first is ChooseObjects) {
        throw StateError('Not enough eligible object choices');
      }
      if (effects.first is ChooseTargets) {
        throw StateError('Not enough eligible character choices');
      }
      if (effects.first is ChooseEffect &&
          [
            ChoiceKind.discardPileCard,
            ChoiceKind.deckCard,
          ].contains((effects.first as ChooseEffect).kind)) {
        throw StateError('No available card choice');
      }
      return false;
    }
    if (state.preparation != null) throw StateError('Preparation already open');
    final player = state.players.firstWhere((p) => p.character == actor);
    final preparation = PendingPreparation(
      state.id('preparation'),
      player.id,
      actor.noMp ? 0 : mpCost,
      {
        ...input,
        if (actor.cardLifeCost > 0 && input['kind'] == 'playCards')
          'lifeCost':
              (input['cardInstanceIds']! as List).length * actor.cardLifeCost,
      },
    );
    state.preparation = preparation;
    _preparedBindings.clear();
    _preparedHandCards.clear();
    _preparedObjectChoices.clear();
    _preparedGeneratedCards.clear();
    _preparedSelections.clear();
    _preparedOptions.clear();
    _preparedCardChoices.clear();
    _preparationCommit = commit;
    void ready() {
      preparation.ready = true;
      _event('abilityPrepared', {
        'preparationId': preparation.id,
        'playerId': player.id,
      });
    }

    final preparationLocals = <String, Object?>{};
    void collect(
      List<EffectDefinition> remaining,
      List<String> targets,
      void Function() complete,
    ) {
      if (remaining.isEmpty) {
        complete();
        return;
      }
      final oldNumber = _abilityNumber;
      _abilityNumber = input['number'] as int? ?? oldNumber;
      final oldLocals = _abilityLocals;
      _abilityLocals = preparationLocals;
      try {
        final e = remaining.first;
        if (e is ChooseEffect && e.random) {
          ready();
          return;
        }
        if (e is GenerateChosenCard) {
          _openGeneratedChoice(actor, e, (definition, target) {
            _preparedGeneratedCards[e] = (definition, target);
            preparation.selections.add({
              'definitionId': definition.id,
              if (target != null) 'targetId': target,
            });
            collect(remaining.sublist(1), targets, complete);
          });
          return;
        }
        if (e is ChooseCards) {
          _openHandChoice(actor, targets, e, (cards) {
            _preparedHandCards[e] = cards;
            if (e.bind != null) {
              preparationLocals[e.bind!] = _objectBinding(
                e.bind!,
                CollectionKind.cards,
                cards.map((c) => _cardQueryData(c, _cardOwnerId(c))).toList(),
              );
            }
            preparation.selections.add({
              'cardInstanceIds': cards.map((c) => c.instanceId).toList(),
            });
            collect(remaining.sublist(1), targets, complete);
          });
          return;
        }
        if (e is ChooseObjects) {
          _openObjectChoice(
            actor,
            targets,
            e,
            (rows) {
              _preparedObjectChoices[e] = rows;
              preparationLocals[e.bind] = _objectBinding(
                e.bind,
                e.query.kind,
                rows,
              );
              preparation.selections.add({
                'bind': e.bind,
                'selectedCount': rows.length,
              });
              collect(remaining.sublist(1), targets, complete);
            },
            enemiesOnly:
                _interactionRulesVersion >= 23 &&
                skillTargeting &&
                _boundTargetsHarm(e.bind, remaining.skip(1)),
          );
          return;
        }
        if (e is ChooseTargets) {
          _openBoundChoice(
            actor,
            targets,
            e,
            (ids) {
              _preparedBindings[e] = List.unmodifiable(ids);
              preparationLocals[e.bind] = List<String>.unmodifiable(ids);
              preparation.selections.add({
                'bind': e.bind,
                'targetIds': List<String>.unmodifiable(ids),
              });
              collect(remaining.sublist(1), targets, complete);
            },
            enemiesOnly:
                _interactionRulesVersion >= 23 &&
                skillTargeting &&
                _boundTargetsHarm(e.bind, remaining.skip(1)),
          );
          return;
        }
        if (e is SelectOptionEffect) {
          _openAbilityOption(
            actor,
            targets,
            e,
            (option) {
              _preparedOptions.add((e, option));
              preparation.selections.add({'optionId': option.id});
              collect(
                option.effects,
                targets,
                () => collect(remaining.sublist(1), targets, complete),
              );
            },
            ready,
            preparing: true,
          );
          return;
        }
        if (e is ChooseEffect &&
            [
              ChoiceKind.discardPileCard,
              ChoiceKind.deckCard,
            ].contains(e.kind)) {
          _openChoice(
            actor,
            targets,
            e,
            1,
            ({required bool didChoose}) {},
            onPrepared: (action, option) {
              _preparedCardChoices.add((e, action, option['skip'] != true));
              preparation.selections.add(option);
              collect(
                option['skip'] == true ? const [] : e.effects,
                targets,
                () => collect(remaining.sublist(1), targets, complete),
              );
            },
          );
          return;
        }
        if (e is! ChooseEffect ||
            (e.kind != ChoiceKind.character && e.kind != ChoiceKind.status)) {
          if (collectAll) {
            collect(remaining.sublist(1), targets, complete);
            return;
          }
          ready();
          return;
        }
        _openSelection(
          actor,
          targets,
          e,
          1,
          const [],
          null,
          0,
          ready,
          skillTargeting: skillTargeting,
          onSelect: (target, status) {
            _preparedSelections.add(_PreparedSelection(e, target, status));
            preparation.selections.add({
              if (target != null)
                'targetId': target.instanceId
              else
                'skip': true,
              if (status != null && status.stacks > 0)
                'statusInstanceId': status.instanceId,
              if (status != null && status.stacks == 0) ...{
                'statusDefinitionId': status.definition.id,
                'statusExists': false,
              },
            });
            if (target == null) {
              collect(remaining.sublist(1), targets, complete);
              return;
            }
            collect(
              e.effects,
              e.preserveSelected ? targets : [target.instanceId],
              () => collect(remaining.sublist(1), targets, complete),
            );
          },
        );
      } finally {
        _abilityLocals = oldLocals;
        _abilityNumber = oldNumber;
      }
    }

    collect(effects, selected, ready);
    return true;
  }

  Map<String, Object?>? _preparationView([String? viewer]) {
    final p = state.preparation;
    if (p == null) return null;
    if (_interactionRulesVersion >= 2 &&
        viewer != null &&
        viewer != p.playerId) {
      return null;
    }
    return {
      'preparationId': p.id,
      'playerId': p.playerId,
      'stage': p.ready ? 'confirmation' : 'selection',
      if (viewer == p.playerId) ...{
        'canCancel': true,
        'canConfirm': p.ready,
        'mpCost': p.mpCost,
        'input': Map<String, Object?>.of(p.input),
        'selections': p.selections.map(Map<String, Object?>.of).toList(),
      },
    };
  }

  void _submitPreparation(
    PlayerInstance player,
    KernelCommand command, {
    bool validateOnly = false,
  }) {
    final p = state.preparation!;
    final id = switch (command) {
      ConfirmAbilityCommand() => command.preparationId,
      CancelAbilityCommand() => command.preparationId,
      _ => null,
    };
    if (id != p.id ||
        player.id != p.playerId ||
        (command is ConfirmAbilityCommand && !p.ready)) {
      throw StateError('Invalid or stale preparation');
    }
    if (validateOnly) return;
    final commit = _preparationCommit!;
    state.preparation = null;
    state.choice = null;
    _choiceContinuation = null;
    _preparationCommit = null;
    if (command is CancelAbilityCommand) {
      _preparedBindings.clear();
      _preparedHandCards.clear();
      _preparedObjectChoices.clear();
      _preparedGeneratedCards.clear();
      _preparedSelections.clear();
      _preparedOptions.clear();
      _preparedCardChoices.clear();
      _event('abilityPreparationCancelled', {
        'preparationId': p.id,
        'playerId': player.id,
      });
      return;
    }
    _committingPrepared = true;
    try {
      commit();
    } finally {
      _committingPrepared = false;
    }
  }
}
