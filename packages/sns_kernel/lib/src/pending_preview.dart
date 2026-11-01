part of 'engine.dart';

/// A declaration projection, not a save or a serialization of execution callbacks.
/// Other players' submissions are deliberately absent, even after they submit.
extension KernelPendingPreview on GameKernel {
  Map<String, Object?>? _pendingPreviewSnapshot(String viewerId) {
    final pending = state.pending;
    if (pending == null) return null;
    final blockers = <String>{};
    if (_interruptibleSkills.containsKey(pending.id)) {
      blockers.add('unprojectedResponseContinuation');
    }
    if (_automaticRestores.isNotEmpty || _automaticActor != null) {
      blockers.add('unprojectedParentContinuation');
    }
    if (pending.kind == PendingKind.dice) {
      blockers.add('unprojectedDiceContinuation');
    }
    final skill = pending.skill;
    if (skill != null && !pending.suppressedEffects) {
      final effects = _walkEffects(skill.definition.effects).toList();
      if (skill.definition.mechanism == SkillMechanism.replayRecord) {
        blockers.add('unprojectedActionRecord');
      }
      if (effects.whereType<ConditionalEffect>().any((e) => e.snapshot)) {
        blockers.add('unprojectedDeclarationConditions');
      }
      // A leading preselection was made before payment. Do not ask again or
      // reveal it to another viewer while reconstructing a pending skill.
      final first = skill.definition.effects.firstOrNull;
      if (skill.definition.preselectAll ||
          first is ChooseTargets ||
          first is ChooseCards ||
          (first is ChooseEffect &&
              !first.random &&
              const [
                ChoiceKind.character,
                ChoiceKind.status,
                ChoiceKind.discardPileCard,
                ChoiceKind.deckCard,
              ].contains(first.kind)) ||
          first is SelectOptionEffect ||
          first is GenerateChosenCard) {
        blockers.add('unprojectedAbilityPreparation');
      }
    }
    if (state.players.any(
      (p) => p.character.traits.any(
        (t) => t.definition.mechanisms.configurations.any(
          (c) => c is! SkillRefundRule,
        ),
      ),
    )) {
      blockers.add('unprojectedPendingMechanisms');
    }
    final armed = <Map<String, Object?>>[];
    for (final attack in pending.armedAttacks) {
      final ref = _previewArmReference(attack.rule);
      if (ref == null) {
        blockers.add('unprojectedPreparedAttack');
      } else {
        armed.add({...ref, 'targetId': attack.targetId});
      }
    }
    return {
      'actionId': pending.id,
      'windowId': pending.windowId,
      'kind': pending.kind.name,
      'actorId': pending.actorId,
      'targets': pending.targets.toList(),
      'cards': [
        for (final c in pending.cards)
          {
            'instanceId': c.instanceId,
            'definitionId': c.definition.id,
            'reinforced': c.reinforced,
          },
      ],
      if (skill != null) 'skill': {..._skillView(skill), 'uses': skill.uses},
      'number': pending.number,
      'suppressedEffects': pending.suppressedEffects,
      if (pending.constraintAction) 'constraintAction': true,
      'diceSides': pending.diceSides,
      'diceResult': pending.diceResult,
      'diceCount': pending.diceCount,
      if (pending.diceRoll != null) 'diceRoll': pending.diceRoll!.toJson(),
      'baseDiceSides': pending.baseDiceSides,
      'forcedDiceSides': pending.forcedDiceSides,
      'deferredDiceBonus': pending.deferredDiceBonus,
      'attackPowerBonus': pending.attackPowerBonus,
      'committedAttackBonus': _committedAttackBonus,
      'armedAttacks': armed,
      'openedVersion': pending.openedVersion,
      'participantIds': pending.responders.toList(),
      'ownSubmission': pending.submissions[viewerId] == null
          ? null
          : KernelRecoveryCodec.command(pending.submissions[viewerId]!),
      // Only counts/progress, never another player's skill, target or parameters.
      'unknownSubmissionCount': pending.submissions.keys
          .where((id) => id != viewerId)
          .length,
      'blockedBy': blockers.toList(),
    };
  }

  Map<String, Object?>? _previewArmReference(ArmAttack rule) {
    for (final skill in catalog.skills.values) {
      final effects = _walkEffects(skill.effects).toList();
      final index = effects.indexWhere((e) => identical(e, rule));
      if (index >= 0) return {'skillId': skill.id, 'effectIndex': index};
    }
    return null;
  }

  /// Start from already-paid declaration state: never replay the command,
  /// consume its cards/MP/CD again, or roll its committed attack dice again.
  void restorePreviewPending(Map<String, dynamic> snapshot) {
    if (!_previewMode) throw StateError('previewOnly');
    final raw = snapshot['pendingAction'] as Map<String, dynamic>;
    final skill = raw['skill'] as Map<String, dynamic>?;
    final actor = _player(raw['actorId'] as String).character;
    final declaredSkill = skill == null
        ? null
        : actor.skills
                  .where(
                    (s) =>
                        s.instanceId == skill['instanceId'] &&
                        s.definition.id == skill['definitionId'],
                  )
                  .firstOrNull ??
              (SkillInstance(
                  skill['instanceId'] as String,
                  catalog.skills[skill['definitionId']]!,
                )
                ..cooldown = skill['cooldown'] as int
                ..cooldownAnchor = skill['cooldownAnchor'] is Map
                    ? AnchorExpiry.fromJson(
                        Map<String, dynamic>.from(
                          skill['cooldownAnchor'] as Map,
                        ),
                      )
                    : null
                ..remainingUses = skill['remainingUses'] as int?
                ..revealed = true
                ..uses = skill['uses'] as int);
    final pending = PendingResolution(
      id: raw['actionId'] as String,
      kind: PendingKind.values.byName(raw['kind'] as String),
      actorId: raw['actorId'] as String,
      targets: (raw['targets'] as List).cast<String>(),
      skill: declaredSkill,
      cards: [
        for (final card in raw['cards'] as List)
          CardInstance(
            card['instanceId'] as String,
            catalog.cards[card['definitionId']]!,
          )..reinforced = card['reinforced'] as bool,
      ],
      number: raw['number'] as int?,
      suppressedEffects: raw['suppressedEffects'] as bool,
      constraintAction: raw['constraintAction'] as bool? ?? false,
      diceSides: raw['diceSides'] as int,
      diceResult: raw['diceResult'] as int,
      diceCount: raw['diceCount'] as int,
      diceRoll: raw['diceRoll'] == null
          ? null
          : RollResult.fromJson(raw['diceRoll'] as Map<String, dynamic>),
      baseDiceSides: raw['baseDiceSides'] as int,
      forcedDiceSides: raw['forcedDiceSides'] as int?,
      deferredDiceBonus: raw['deferredDiceBonus'] as int,
      attackPowerBonus: raw['attackPowerBonus'] as int,
      armedAttacks: [
        for (final arm in raw['armedAttacks'] as List)
          ArmedAttack(
            _walkEffects(
                  catalog.skills[arm['skillId']]!.effects,
                ).elementAt(arm['effectIndex'] as int)
                as ArmAttack,
            arm['targetId'] as String?,
          ),
      ],
    )..responseWindowId = raw['windowId'] as String;
    pending.openedVersion = raw['openedVersion'] as int;
    pending.responders.addAll((raw['participantIds'] as List).cast<String>());
    state.pending = pending;
    _committedAttackBonus = raw['committedAttackBonus'] as int;
    if (pending.diceRoll != null) _storeRoll(pending.diceRoll!);
    state.discardPile.addAll(pending.cards);
  }

  void validatePreviewResponse(String viewerId, KernelCommand response) {
    if (!_previewMode) throw StateError('previewOnly');
    final pending = state.pending!;
    if (response.playerId != viewerId ||
        !pending.responders.contains(viewerId)) {
      throw StateError('notResponseParticipant');
    }
    switch (response) {
      case UseSkillCommand():
        _validateResponse(_player(viewerId), response, pending);
      case PassCommand():
        if (response.pendingActionId != pending.windowId) {
          throw StateError('stalePreviewWindow');
        }
      default:
        throw StateError('invalidPreviewResponse');
    }
  }

  /// Hidden responses are replaced by pass only in this simulation.
  void runPreviewPending(String viewerId, KernelCommand? response) {
    if (!_previewMode) throw StateError('previewOnly');
    final pending = state.pending!;
    if (response != null) {
      validatePreviewResponse(viewerId, response);
      pending.submissions[viewerId] = response;
    }
    for (final id in pending.responders) {
      pending.submissions.putIfAbsent(
        id,
        () => PassCommand(id, pending.windowId),
      );
    }
    _finishResponsesIfReady();
    _pumpFlow();
  }
}
