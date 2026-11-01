part of 'engine.dart';

extension _NaturalDurations on GameKernel {
  void _setSkillCooldown(
    SkillInstance skill,
    int value, {
    bool preserveAnchor = true,
  }) {
    if (_interactionRulesVersion >= 18) {
      skill.cooldownAnchor = value <= 0
          ? null
          : preserveAnchor && skill.cooldown > 0 && skill.cooldownAnchor != null
          ? skill.cooldownAnchor
          : _newAnchorExpiry(1);
    }
    skill.cooldown = value;
  }

  void _tickSkillCooldowns(String playerId, {bool atEnd = false}) {
    if (_interactionRulesVersion < 18) return;
    for (final player in state.players) {
      for (final skill in player.character.skills) {
        if (skill.cooldown <= 0) continue;
        final anchor = skill.cooldownAnchor;
        if (anchor == null) {
          if (player.id == playerId && !atEnd) skill.cooldown--;
        } else if (_anchorExpiryDue(anchor, playerId, atEnd: atEnd)) {
          skill.cooldown--;
          skill.cooldownAnchor = skill.cooldown == 0
              ? null
              : AnchorExpiry(
                  playerId: playerId,
                  turn: _player(playerId).character.turnsStarted + 1,
                  atEnd: atEnd,
                );
        }
      }
    }
  }

  AnchorExpiry _newAnchorExpiry(int rounds) => AnchorExpiry(
    playerId: state.activePlayer.id,
    turn: state.activePlayer.character.turnsStarted + rounds,
    atEnd: _endingAnchorPlayerId == state.activePlayer.id,
  );

  bool _anchorExpiryDue(
    AnchorExpiry expiry,
    String playerId, {
    bool atEnd = false,
  }) =>
      expiry.playerId == playerId &&
      expiry.atEnd == atEnd &&
      expiry.turn <= _player(playerId).character.turnsStarted;

  bool _cardTagRestricted(CharacterInstance actor, String tag) =>
      actor.restrictedCardTags.containsKey(tag) ||
      (actor.anchoredCardTags[tag]?.isNotEmpty ?? false);

  void _expireNaturalDurations(String playerId, {bool atEnd = false}) {
    if (_interactionRulesVersion < 14) return;
    bool due(AnchorExpiry expiry) =>
        _anchorExpiryDue(expiry, playerId, atEnd: atEnd);
    for (final player in state.players) {
      final actor = player.character;
      for (final deadlines in actor.anchoredCardTags.values) {
        deadlines.removeWhere(due);
      }
      actor.anchoredCardTags.removeWhere((_, deadlines) => deadlines.isEmpty);
      final expired = actor.temporaryShields
          .where((shield) => shield.anchor != null && due(shield.anchor!))
          .fold<int>(0, (sum, shield) => sum + shield.remaining);
      actor.shield = (actor.shield - expired).clamp(0, 1000000000);
      actor.temporaryShields.removeWhere(
        (shield) => shield.anchor != null && due(shield.anchor!),
      );
    }
    _skillBorrowModule.expire(natural: true, atEnd: atEnd);
  }

  void _reverseDecayAnchors() {
    if (_interactionRulesVersion < 14) return;
    // A duration belongs to the ordinal action seat. Keep its ordinal when
    // direction reverses, without changing its holder, source or remaining time.
    String mirror(String playerId) {
      final index = state.players.indexWhere((p) => p.id == playerId);
      return index < 0
          ? playerId
          : state.players[state.players.length - 1 - index].id;
    }

    AnchorExpiry remap(AnchorExpiry expiry) {
      final next = mirror(expiry.playerId);
      final remaining =
          expiry.turn - _player(expiry.playerId).character.turnsStarted;
      return AnchorExpiry(
        playerId: next,
        turn: _player(next).character.turnsStarted + remaining,
        atEnd: expiry.atEnd,
      );
    }

    final statuses = {
      for (final player in state.players) ...player.character.statuses,
      for (final save in _turnSaveModule.saves.values) ...save.statuses,
    };
    for (final status in statuses) {
      if (status.definition.decay == StatusDecay.anchoredRound ||
          (_interactionRulesVersion >= 15 &&
              status.definition.decay == StatusDecay.anchorMpRecovery)) {
        status.anchorPlayerId = mirror(status.anchorPlayerId);
      }
    }
    final blocks = {
      for (final entry in state.statusApplicationBlocks.entries)
        mirror(entry.key): entry.value,
    };
    state.statusApplicationBlocks
      ..clear()
      ..addAll(blocks);
    final cards = {
      ...state.drawPile,
      ...state.discardPile,
      for (final player in state.players) ...player.character.hand,
      for (final held in state.cardCustody.entries) held.card,
    };
    for (final card in cards) {
      if (card.disabledUntilAnchor != null) {
        card.disabledUntilAnchor = remap(card.disabledUntilAnchor!);
      }
    }
    for (final player in state.players) {
      final actor = player.character;
      for (final skill in actor.skills) {
        if (skill.cooldownAnchor != null) {
          skill.cooldownAnchor = remap(skill.cooldownAnchor!);
        }
      }
      for (final entry in actor.anchoredCardTags.entries.toList()) {
        actor.anchoredCardTags[entry.key] = entry.value.map(remap).toList();
      }
      for (final shield in actor.temporaryShields) {
        if (shield.anchor != null) shield.anchor = remap(shield.anchor!);
      }
    }
    _skillBorrowModule.remapAnchors(remap);
  }
}
