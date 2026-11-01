part of 'engine.dart';

extension _DiceFlow on GameKernel {
  RollContext _rollContext(
    CharacterInstance actor, {
    RollPurpose? purpose,
    String? actionId,
  }) => RollContext(
    actorId: actor.instanceId,
    purpose:
        purpose ??
        _rollOrigin?.purpose ??
        (_effectStatus != null || _currentTrigger?.status != null
            ? RollPurpose.status
            : _currentTrigger?.trait != null
            ? RollPurpose.trait
            : RollPurpose.effect),
    actionId:
        actionId ?? _rollOrigin?.actionId ?? _currentTrigger?.fact.actionId,
    definitionId:
        _rollOrigin?.definitionId ??
        _effectStatus?.definition.id ??
        _currentTrigger?.status?.definition.id ??
        _currentTrigger?.trait?.definition.id ??
        _currentTrigger?.skill?.definition.id,
  );

  String _nextRollId() =>
      '${state.gameId}:${_previewMode ? 'preview:' : ''}dice:${state.diceHistory.length + 1}';
  RollResult _storeRoll(RollResult result) {
    state.diceHistory[result.id] = result;
    return result;
  }

  RollResult _rollResult(
    CharacterInstance actor,
    int sides,
    int count, {
    RollContext? context,
  }) {
    final spec = DiceSpec.uniform(sides, count: count);
    final id = _nextRollId();
    final values = <int>[];
    RollResult? completed;
    for (var i = 0; i < count; i++) {
      final die = _nextInt(sides) + 1;
      values.add(die);
      if (i == count - 1) {
        completed = _storeRoll(
          RollResult(
            id: id,
            context: context ?? _rollContext(actor),
            spec: spec,
            values: values,
          ),
        );
      }
      _event('diceRolled', {
        'actorId': actor.instanceId,
        'sides': sides,
        'result': die,
        'rollId': id,
        'dieIndex': i,
        if (completed != null) 'roll': completed.toJson(),
      });
    }
    return completed!;
  }

  // Scalar continuation compatibility for ordinary effect operations.
  void _rollAsync(
    CharacterInstance actor,
    int sides,
    int count,
    void Function(int) complete, {
    bool damageRoll = false,
    RollPurpose? purpose,
    RollContext? origin,
  }) => _rollResultAsync(
    actor,
    sides,
    count,
    (result) => complete(result.finalTotal),
    damageRoll: damageRoll,
    context: origin ?? _rollContext(actor, purpose: purpose),
  );

  void _rollResultAsync(
    CharacterInstance actor,
    int sides,
    int count,
    void Function(RollResult) complete, {
    RollResult Function()? generate,
    bool damageRoll = false,
    bool chosen = false,
    RollResult? selectedResult,
    RollContext? context,
  }) {
    RollResult produce() {
      if (generate == null) {
        return _rollResult(actor, sides, count, context: context);
      }
      final result = generate();
      _event('diceRolled', {
        'actorId': actor.instanceId,
        'sides': sides,
        'count': count,
        'result': result.finalTotal,
        'reroll': true,
        'rollId': result.id,
        'roll': result.toJson(),
      });
      return result;
    }

    if (damageRoll && !chosen) {
      _chooseDamageRoll(
        actor,
        produce,
        (value) => _rollResultAsync(
          actor,
          sides,
          count,
          complete,
          generate: generate,
          damageRoll: true,
          chosen: true,
          selectedResult: value,
          context: context,
        ),
      );
      return;
    }
    final result = selectedResult ?? produce();
    final player = state.players.firstWhere((p) => p.character == actor);
    final pending = PendingResolution(
      id: state.id('roll'),
      kind: PendingKind.dice,
      actorId: player.id,
      targets: const [],
      diceSides: sides,
      diceCount: count,
      diceRoll: result,
    );
    if (!state.players.any(
      (p) => p.character.skills.any(
        (s) => _responseProblem(p, s, pending) == null,
      ),
    )) {
      _offerReroll(
        actor,
        sides,
        count,
        result,
        (value) => complete(_storeRoll(value)),
        generate: generate,
        damageRoll: damageRoll,
      );
      return;
    }
    if (state.pending != null || _diceContinuation != null) {
      throw StateError('A dice window is already open');
    }
    _diceContinuation = (value) => _offerReroll(
      actor,
      sides,
      count,
      value,
      (resolved) => complete(_storeRoll(resolved)),
      generate: generate,
      damageRoll: damageRoll,
    );
    _openResponse(pending);
  }

  void _setPendingDice(
    PendingResolution pending,
    int value, {
    String? sourceId,
  }) {
    final original = pending.diceRoll;
    if (original == null) {
      pending.diceResult = value;
      return;
    }
    pending.setDiceRoll(
      _storeRoll(
        original.modified(
          RollModification(DiceAdjustment.replace, value, sourceId: sourceId),
        ),
      ),
    );
  }
}
