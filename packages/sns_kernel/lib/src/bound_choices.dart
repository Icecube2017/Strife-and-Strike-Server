part of 'engine.dart';

extension _BoundChoices on GameKernel {
  void _openBoundChoice(
    CharacterInstance actor,
    List<String> selected,
    ChooseTargets effect,
    void Function(List<String>) complete, {
    AttackPacket? attackPacket,
    bool enemiesOnly = false,
  }) {
    final minimum = _amount(effect.minimum, effect.minimumValue, actor, actor);
    final maximum = _amount(effect.maximum, effect.maximumValue, actor, actor);
    if (minimum < 0 || maximum < minimum || maximum > 1024) {
      throw StateError('Invalid character choice range');
    }
    final chosen = <String>[];
    final locals = _abilityLocals;
    final trigger = _currentTrigger;
    final player = state.players.firstWhere((p) => p.character == actor);
    void open() {
      final oldLocals = _abilityLocals;
      final oldTrigger = _currentTrigger;
      _abilityLocals = locals;
      _currentTrigger = trigger;
      late List<CharacterInstance> candidates;
      var blockedCandidates = false;
      try {
        final eligible = _effectTargets(actor, selected, effect.target)
            .where(
              (c) =>
                  c.alive &&
                  (!enemiesOnly || _enemy(actor, c)) &&
                  !chosen.contains(c.instanceId) &&
                  _conditionMatches(effect.when, actor, c),
            )
            .toList();
        candidates = eligible
            .where((c) => _attackEffectTargetAllowed(c, attackPacket))
            .toList();
        blockedCandidates = candidates.length != eligible.length;
      } finally {
        _abilityLocals = oldLocals;
        _currentTrigger = oldTrigger;
      }
      if (chosen.length >= maximum || candidates.isEmpty) {
        if (chosen.length < minimum) {
          if (blockedCandidates) {
            complete(const []);
            return;
          }
          throw StateError('Not enough eligible character choices');
        }
        complete(List.unmodifiable(chosen));
        return;
      }
      final resolved = <String, String>{};
      final options = <Map<String, Object?>>[
        for (final c in candidates)
          {'optionId': state.id('option'), 'targetId': c.instanceId},
      ];
      for (final option in options) {
        resolved[option['optionId']! as String] = option['targetId']! as String;
      }
      final done = chosen.length >= minimum ? state.id('option') : null;
      if (done != null) {
        options.add({'optionId': done, 'done': true, 'skip': true});
      }
      final choice = PendingChoice(
        id: state.id('choice'),
        playerId: player.id,
        kind: ChoiceKind.character,
        options: options,
        details: {
          'bind': effect.bind,
          'min': minimum,
          'max': maximum,
          'selectedTargetIds': List<String>.unmodifiable(chosen),
        },
      );
      state.choice = choice;
      _choiceContinuation = (id) {
        if (id == done) {
          complete(List.unmodifiable(chosen));
          return;
        }
        chosen.add(resolved[id]!);
        open();
      };
      _event('choiceOpened', {
        'choiceId': choice.id,
        'playerId': player.id,
        'kind': choice.kind.name,
      });
    }

    open();
  }
}
