part of 'engine.dart';

typedef _EndDecayStatus = (CharacterInstance, StatusInstance);

extension _StatusDecayTiming on GameKernel {
  void _mpRecoveryNode(
    CharacterInstance actor, {
    MpRegenPhase phase = MpRegenPhase.turnStart,
    bool skipped = false,
  }) {
    if (_interactionRulesVersion < 15) {
      _regenerateMp(actor, phase: phase);
      return;
    }
    if (actor.race.regenPhase != phase) return;
    final anchor = state.players.firstWhere((p) => p.character == actor).id;
    // Freeze before recovery triggers. An instance attached during this node
    // starts aging at the next node, rather than losing its first layer now.
    final aging = [
      for (final player in state.players)
        for (final status in player.character.statuses)
          if (status.definition.decay == StatusDecay.anchorMpRecovery &&
              status.anchorPlayerId == anchor)
            (player.character, status),
    ];
    _flowSteps([
      if (!skipped) () => _regenerateMp(actor, phase: phase),
      if (!skipped)
        () => _flowSteps([
          // The holder receives the effect at their own recovery node; this
          // does not age an instance attached by another character.
          for (final status in List<StatusInstance>.of(actor.statuses))
            () {
              if (!actor.alive ||
                  !actor.statuses.contains(status) ||
                  status.definition.decay != StatusDecay.anchorMpRecovery) {
                return;
              }
              _runAbility(
                actor,
                [actor.instanceId],
                status.definition.turnStart,
                () {
                  if (status.definition.turnStart.isNotEmpty) {
                    _statusSettlementCompleted(actor, status);
                  }
                },
                multiplier: status.intensity,
                statusOrigin: status,
              );
            },
        ]),
      // Age only at the attachment seat's recovery node, after all of its own
      // MP effects. In particular, a self-applied final layer still takes effect.
      for (final (owner, status) in aging)
        () {
          if (owner.alive &&
              owner.statuses.contains(status) &&
              status.anchorPlayerId == anchor) {
            _consumeStatus(owner, status);
          }
        },
    ]);
  }

  bool _usesEndAnchorDecay(
    StatusDefinition definition,
    String anchorPlayerId,
  ) =>
      _interactionRulesVersion >= 12 &&
      (_isStatusEffect(definition) ||
          (_interactionRulesVersion >= 14 &&
              definition.followApplicationPhase)) &&
      definition.decay == StatusDecay.anchoredRound &&
      _endingAnchorPlayerId == anchorPlayerId;

  List<_EndDecayStatus> _beginAnchorEnd() {
    if (_interactionRulesVersion < 12) return const [];
    state.phase = GamePhase.end;
    _endingAnchorPlayerId = state.activePlayer.id;
    // Capture before any end-phase effects: a newly attached instance waits
    // until this seat's next end, while existing instances still age once.
    return [
      for (final player in state.players)
        for (final status in player.character.statuses)
          if (status.decayAtAnchorEnd &&
              status.anchorPlayerId == _endingAnchorPlayerId)
            (player.character, status),
    ];
  }

  void _endAnchorDecay(List<_EndDecayStatus> scheduled) {
    if (_interactionRulesVersion < 12) return;
    final anchorPlayerId = _endingAnchorPlayerId;
    bool stillAnchored(CharacterInstance owner, StatusInstance status) =>
        owner.alive &&
        owner.statuses.contains(status) &&
        status.decayAtAnchorEnd &&
        status.anchorPlayerId == anchorPlayerId;
    _flowSteps([
      // Finish every anchor-timed settlement before removing any layer, so
      // other states' modifiers remain available throughout the end phase.
      for (final (owner, status) in scheduled)
        () {
          if (stillAnchored(owner, status) &&
              status.definition.settleAtAnchor) {
            _runAbility(
              owner,
              [owner.instanceId],
              status.definition.turnStart,
              () {
                if (status.definition.turnStart.isNotEmpty) {
                  _statusSettlementCompleted(owner, status);
                }
              },
              multiplier: status.intensity,
              statusOrigin: status,
            );
          }
        },
      for (final (owner, status) in scheduled)
        () {
          if (stillAnchored(owner, status)) _consumeStatus(owner, status);
        },
      () {
        if (anchorPlayerId != null) {
          _expireHandCardsAtAnchor(anchorPlayerId, atEnd: true);
          _expireNaturalDurations(anchorPlayerId, atEnd: true);
          _tickSkillCooldowns(anchorPlayerId, atEnd: true);
        }
        _endingAnchorPlayerId = null;
      },
    ]);
  }
}
