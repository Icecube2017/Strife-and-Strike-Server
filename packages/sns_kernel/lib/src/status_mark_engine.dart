part of 'engine.dart';

extension _StatusMarkEngine on GameKernel {
  bool _isStatusEffect(StatusDefinition? definition) =>
      _interactionRulesVersion < 7 || definition?.isStatusEffect != false;

  // Anomalies can carry negative polarity for scoring without belonging to
  // the negative-effect category. Keep historical filtering only for replay.
  bool _matchesNegativeCleanse(StatusDefinition definition) =>
      definition.negative &&
      (_interactionRulesVersion < 16 ||
          (_isStatusEffect(definition) &&
              definition.category == StatusCategory.normal));

  List<Map<String, Object?>> _globalEffectView() {
    if (state.statusApplicationBlocks.isEmpty &&
        state.round >= state.blockStatusUntilRound) {
      return [];
    }
    final definitions = catalog.cards.values
        .where(
          (card) =>
              card.effects.any((effect) => effect is BlockStatusApplication),
        )
        .toList();
    final definitionId = definitions.length == 1 ? definitions.single.id : null;
    return [
      for (final block in state.statusApplicationBlocks.entries)
        if (block.value > 0)
          {
            'kind': 'statusApplicationBlock',
            if (definitionId != null) 'definitionId': definitionId,
            'anchorPlayerId': block.key,
            'remainingAnchorTurns': block.value,
          },
      if (state.round < state.blockStatusUntilRound)
        {
          'kind': 'statusApplicationBlock',
          if (definitionId != null) 'definitionId': definitionId,
          'untilRound': state.blockStatusUntilRound,
        },
    ];
  }

  void _flipMarks(
    CharacterInstance actor,
    CharacterInstance holder,
    FlipMarks effect,
  ) {
    final first = _markCount(holder, effect.first);
    final second = _markCount(holder, effect.second);
    final total = first + second;
    if (total == 0) return;
    final left = effect.mode == 'first'
        ? total
        : effect.mode == 'second'
        ? 0
        : second;
    final right = total - left;
    _modifyMark(
      actor,
      holder,
      ModifyMark(effect.first, amount: left, set: true),
      1,
    );
    _modifyMark(
      actor,
      holder,
      ModifyMark(effect.second, amount: right, set: true),
      1,
    );
  }

  int _markCount(CharacterInstance holder, String id, {String? sourceId}) {
    if (_previewMode) throw const PreviewBoundary('unprojectedMarks');
    return holder.marks
        .where(
          (m) =>
              m.definition.id == id &&
              (sourceId == null ||
                  !m.definition.sourceScoped ||
                  m.sourceId == sourceId),
        )
        .fold(0, (sum, m) => sum + m.count);
  }

  int _modifyMark(
    CharacterInstance actor,
    CharacterInstance holder,
    ModifyMark effect,
    int multiplier, {
    bool preserveSource = false,
    String? originalSourceId,
  }) {
    final definition = _require(catalog.marks, effect.markId);
    final previousLimits = _resourceLimits(holder);
    final sourceId = definition.sourceScoped
        ? (preserveSource ? originalSourceId : actor.instanceId)
        : null;
    var mark = holder.marks
        .where(
          (m) => m.definition.id == definition.id && m.sourceId == sourceId,
        )
        .firstOrNull;
    final old = mark?.count ?? 0;
    final amount =
        _amount(effect.amount, effect.value, actor, holder) * multiplier;
    var count = ((effect.set ? 0 : old) + amount).clamp(
      0,
      definition.playerCountBonus != null
          ? setup.players.length + definition.playerCountBonus!
          : definition.maxCount ?? 1000000,
    );
    if (definition.group != null && definition.groupLimit != null) {
      final others = holder.marks
          .where((m) => m != mark && m.definition.group == definition.group)
          .fold(0, (n, m) => n + m.count);
      count = count.clamp(
        0,
        (definition.groupLimit! - others).clamp(0, 1000000),
      );
    }
    if (count == 0) {
      if (mark != null) holder.marks.remove(mark);
    } else if (mark == null) {
      mark = MarkInstance(
        instanceId: state.id('mark'),
        definition: definition,
        ownerId: holder.instanceId,
        sourceId: sourceId,
        count: count,
        references: effect.references,
      );
      holder.marks.add(mark);
    } else {
      mark.count = count;
      mark.references.addAll(effect.references);
    }
    if (count != old) {
      _performance.markChange(actor, holder, old, count);
      if (definition.visibility == MarkVisibility.public && count > old) {
        final ally =
            state.players.firstWhere((p) => p.character == actor).teamId ==
            state.players.firstWhere((p) => p.character == holder).teamId;
        _performance.otherEffect(
          actor,
          holder,
          positive: ally,
          kind: 'markGrant',
        );
      }
      _event('markChanged', {
        'targetId': holder.instanceId,
        'sourceId': sourceId,
        'markId': definition.id,
        'amount': count - old,
        'count': count,
      });
      _logResourceLimitChanges(holder, previousLimits, source: actor);
    }
    return count - old;
  }

  Map<String, int> _markCosts(List<MarkCost> costs) {
    final result = <String, int>{};
    for (final cost in costs) {
      result.update(
        cost.markId,
        (n) => n + cost.amount,
        ifAbsent: () => cost.amount,
      );
    }
    return result;
  }

  bool _canPayMarks(CharacterInstance actor, List<MarkCost> costs) =>
      _markCosts(costs).entries.every(
        (e) => _markCount(actor, e.key, sourceId: actor.instanceId) >= e.value,
      );
  void _payMarkCosts(CharacterInstance actor, List<MarkCost> costs) {
    for (final cost in _markCosts(costs).entries) {
      _modifyMark(actor, actor, ModifyMark(cost.key, amount: -cost.value), 1);
    }
  }

  List<Map<String, Object?>> _markView(
    CharacterInstance actor,
    String? viewer,
  ) {
    final owner = state.players.firstWhere((p) => p.character == actor).id;
    return [
      for (final mark in actor.marks)
        if (mark.definition.visibility == MarkVisibility.public ||
            viewer == owner)
          {
            'instanceId': mark.instanceId,
            'definitionId': mark.definition.id,
            'sourceId': mark.sourceId,
            'count': mark.count,
            'references': Map<String, String>.of(mark.references),
          },
    ];
  }

  int _mpRecovery(CharacterInstance actor, int amount) {
    if (amount <= 0) return amount;
    final recovery =
        (amount +
                actor.statuses.fold<int>(
                  0,
                  (n, s) =>
                      n + s.definition.mpRecoveryFlatPerIntensity * s.intensity,
                ))
            .clamp(0, 1000000);
    if (recovery == 0 ||
        actor.noMp ||
        actor.mp >= actor.value(Stat.maxMp) ||
        _blocked(actor, (s) => s.blockTraits)) {
      return recovery;
    }
    return _reserveModule.convertRecovery(actor, recovery);
  }

  void _activateStatus(
    CharacterInstance actor,
    String instanceId, {
    bool validateOnly = false,
  }) {
    final status = actor.statuses
        .where((s) => s.instanceId == instanceId)
        .firstOrNull;
    final action = status?.definition.active;
    if (status == null || action == null) {
      throw StateError('Status has no active option');
    }
    if (validateOnly) return;
    _damageAsync(
      null,
      actor,
      action.lifeCostPerIntensity * status.intensity,
      DamageKind.lifeLoss,
      () {
        if (action.removeSelf && actor.statuses.contains(status)) {
          _consumeStatus(actor, status, amount: status.stacks);
        }
        _runAbility(actor, [actor.instanceId], action.effects, () {
          _event('statusActivated', {
            'actorId': actor.instanceId,
            'instanceId': instanceId,
          });
          _afterResolution();
        }, multiplier: status.intensity);
      },
    );
  }
}
