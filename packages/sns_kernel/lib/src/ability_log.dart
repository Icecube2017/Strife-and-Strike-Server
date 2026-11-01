part of 'engine.dart';

const _interactionLogFields = {
  'logCardInstanceId',
  'logActorId',
  'logSkillId',
  'logInputNumber',
  'logDiceResult',
  'logMode',
};

/// Presentation facts only; never changes triggers, costs or settlement order.
extension _AbilityLog on GameKernel {
  Map<Stat, int> _resourceLimits(CharacterInstance holder) => {
    Stat.maxHp: holder.value(Stat.maxHp),
    Stat.maxMp: holder.value(Stat.maxMp),
    if (_statisticsRulesVersion >= 2) Stat.maxHand: holder.value(Stat.maxHand),
  };

  void _logResourceLimitChanges(
    CharacterInstance holder,
    Map<Stat, int> before, {
    CharacterInstance? source,
  }) {
    if (_interactionRulesVersion < 6) return;
    for (final entry in before.entries) {
      final after = holder.value(entry.key);
      if (after == entry.value) continue;
      if (source != null) {
        _performance.statChange(source, holder, entry.key, after - entry.value);
      }
      if (entry.key == Stat.maxHand) continue;
      // Record display facts without running rule observers a second time.
      state.events.add(
        KernelEvent(
          state.events.length + 1,
          'statModified',
          _freezeEventData({
            if (source != null) 'sourceId': source.instanceId,
            'targetId': holder.instanceId,
            'stat': entry.key.name,
            'before': entry.value,
            'amount': after - entry.value,
            'result': after,
          }),
          round: state.round,
          turn: state.actualTurn + 1,
          phase: state.phase.name,
          extraTurn: state.extraTurn,
        ),
      );
    }
  }

  void _addLogDetails(int index, Map<String, Object?> details) {
    if (index < 0 || index >= state.events.length || details.isEmpty) return;
    final event = state.events[index];
    state.events[index] = KernelEvent(
      event.sequence,
      event.type,
      {...event.data, ...details},
      round: event.round,
      turn: event.turn,
    );
  }

  List<String> _abilityLogTargets(int start, List<String> declared) {
    const effects = {
      'damage',
      'healed',
      'shieldGained',
      'shieldTransferred',
      'lifeRestored',
      'lifeSet',
      'statModified',
      'mpChanged',
      'statusApplied',
      'statusModified',
      'statusRemoved',
      'markChanged',
      'cardsDrawn',
      'cardsLost',
      'skillDrawn',
      'handCardMoved',
      'handCardsDisabled',
      'cardTaken',
      'cardReturned',
      'attackRedirected',
      'damageRedirected',
      'statusActivated',
      'variableChanged',
    };
    final publicIds = state.players.map((p) => p.character.instanceId).toSet();
    final targets = <String>{};
    for (final event in state.events.skip(start)) {
      if (!effects.contains(event.type)) continue;
      final id =
          event.data['targetId'] ??
          event.data['ownerId'] ??
          event.data['actorId'];
      if (id is String && publicIds.contains(id)) targets.add(id);
    }
    return List.unmodifiable(
      targets.isEmpty ? declared.where(publicIds.contains).toSet() : targets,
    );
  }

  void _finishAbilityLog(int index, int start, List<String> declared) {
    if (index < 0 || index >= state.events.length) return;
    final event = state.events[index];
    // Add resolved recipients to the same immutable fact without replaying it.
    state.events[index] = KernelEvent(
      event.sequence,
      event.type,
      {...event.data, 'logTargetIds': _abilityLogTargets(start, declared)},
      round: event.round,
      turn: event.turn,
    );
  }
}
