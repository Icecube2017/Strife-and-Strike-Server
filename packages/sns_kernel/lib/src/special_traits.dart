part of 'engine.dart';

final class _ObservedAction {
  _ObservedAction(
    this.actor,
    this.targets,
    this.cards,
    this.start, {
    required this.recordable,
    required this.countsAsAction,
    this.paidMp = 0,
  });
  final CharacterInstance actor;
  final List<String> targets;
  List<CardInstance> cards;
  final int start;
  final bool recordable;
  final bool countsAsAction;
  final int paidMp;
  final List<(int, int)> excludedEventRanges = [];
  final Map<String, RecordActionCommand> recordingSelections = {};
}

extension _SpecialTraits on GameKernel {
  void _mechanismChoice(
    CharacterInstance actor,
    List<Map<String, Object?>> options,
    void Function(Map<String, Object?>) resolve,
  ) {
    final player = state.players.firstWhere((p) => p.character == actor);
    final entries = [
      for (final option in options) {'optionId': state.id('option'), ...option},
    ];
    state.choice = PendingChoice(
      id: state.id('choice'),
      playerId: player.id,
      kind: ChoiceKind.mechanism,
      options: entries,
    );
    _choiceContinuation = (id) =>
        resolve(entries.singleWhere((o) => o['optionId'] == id));
    _event('choiceOpened', {
      'choiceId': state.choice!.id,
      'playerId': player.id,
      'kind': 'mechanism',
    });
  }

  StatusInstance _copyStatus(StatusInstance old, {bool restoring = false}) {
    final copy = StatusInstance(
      instanceId: restoring ? state.id('status') : old.instanceId,
      definition: old.definition,
      ownerId: old.ownerId,
      sourceId: old.sourceId,
      anchorPlayerId: old.anchorPlayerId,
      decayAtAnchorEnd: old.decayAtAnchorEnd,
      stacks: old.stacks,
      intensity: old.intensity,
      damageLimit: old.damageLimit,
    )..damageTaken = old.damageTaken;
    copy.usedDamageGuards.addAll(old.usedDamageGuards);
    copy.triggerMemory.counters.addAll(old.triggerMemory.counters);
    copy.triggerMemory.counterWindows.addAll(old.triggerMemory.counterWindows);
    copy.triggerMemory.uses.addAll(old.triggerMemory.uses);
    copy.triggerMemory.useWindows.addAll(old.triggerMemory.useWindows);
    copy.triggerMemory.groupUses.addAll(old.triggerMemory.groupUses);
    copy.triggerMemory.groupWindows.addAll(old.triggerMemory.groupWindows);
    copy.triggerMemory.packetUses.addAll(old.triggerMemory.packetUses);
    return copy;
  }

  void _specialTurnStart(CharacterInstance actor) {
    final recovery = actor.traits
        .where((t) => t.definition.continuationRecoverySides != null)
        .firstOrNull;
    if (actor.alive && actor.lifeLocked && recovery != null) {
      _rollAsync(actor, recovery.definition.continuationRecoverySides!, 1, (
        result,
      ) {
        if (recovery.definition.continuationRecoverySuccess.contains(result)) {
          final before = actor.hp;
          actor.setLifeIgnoringContinuation(1);
          _event('lifeRestored', {
            'actorId': actor.instanceId,
            'before': before,
            'hp': 1,
          });
        } else {
          _event('continuationFailed', {'actorId': actor.instanceId});
          _commitDeath(actor);
        }
      });
      return;
    }
    if (!actor.alive ||
        !actor.traits.any(
          (t) => t.definition.resourceAbilities.legacyDefenseDiscard,
        ) ||
        _blocked(actor, (s) => s.blockTraits)) {
      return;
    }
    final cards = actor.hand.where((c) => !c.disabled).toList();
    if (cards.isEmpty) return;
    _mechanismChoice(
      actor,
      [
        {'action': 'skip'},
        for (final c in cards)
          {
            'action': 'defenseDiscard',
            'instanceId': c.instanceId,
            'definitionId': c.definition.id,
          },
      ],
      (o) {
        if (o['action'] == 'skip') return;
        final card = cards.singleWhere((c) => c.instanceId == o['instanceId']);
        actor.hand.remove(card);
        state.discardPile.add(card);
        actor.permanentModifiers.update(
          Stat.defense,
          (n) => n + 3,
          ifAbsent: () => 3,
        );
        _event('cardsLost', {
          'actorId': actor.instanceId,
          'count': 1,
          if (_interactionRulesVersion >= 5) 'cards': [card.instanceId],
        });
        _event('defenseIncreased', {'actorId': actor.instanceId, 'amount': 3});
      },
    );
  }

  void _beginObservedAction(
    CharacterInstance actor,
    List<String> targets,
    List<CardInstance> cards, {
    bool recordable = true,
    bool countsAsAction = true,
    int paidMp = 0,
  }) {
    _observedAction = _ObservedAction(
      actor,
      List.of(targets),
      List.of(cards),
      state.events.length,
      recordable: recordable,
      countsAsAction: countsAsAction,
      paidMp: paidMp,
    );
  }

  void _finishObservedAction() {
    final action = _observedAction;
    if (action == null) return;
    _observedAction = null;
    _flow.addFirst(() => _offerSupportAttack(action));
    final events = state.events
        .skip(action.start)
        .where(
          (e) =>
              !action.excludedEventRanges.any(
                (r) => e.sequence > r.$1 && e.sequence <= r.$2,
              ) &&
              e.type == 'damage' &&
              e.data['independent'] != true &&
              e.data['sourceId'] == action.actor.instanceId,
        )
        .toList();
    _refundNonDamagingAction(action);
    final total = events.fold(0, (n, e) => n + (e.data['amount']! as int));
    final attackDamage = <String, int>{};
    final baseDamage = <String, int>{};
    final hpDamage = <String, int>{};
    for (final event in events.where(
      (e) =>
          e.data['attack'] == true &&
          e.data['kind'] != DamageKind.lifeLoss.name,
    )) {
      final target = event.data['targetId']! as String;
      final actual = (event.data['actualHpLost'] as int? ?? 0).clamp(
        0,
        (event.data['hpBefore'] as int? ?? 1000000000).clamp(0, 1000000000),
      );
      hpDamage.update(target, (n) => n + actual, ifAbsent: () => actual);
      if (event.data['component'] == 'main') {
        baseDamage.update(
          target,
          (n) => n + (event.data['baseDamage'] as int? ?? 0),
          ifAbsent: () => event.data['baseDamage'] as int? ?? 0,
        );
      }
      attackDamage.update(
        target,
        (n) => n + (event.data['amount']! as int),
        ifAbsent: () => event.data['amount']! as int,
      );
    }
    for (final entry in attackDamage.entries.where((e) => e.value > 0)) {
      _event('attackDamageDealt', {
        'sourceId': action.actor.instanceId,
        'targetId': entry.key,
        'amount': entry.value,
        'baseDamage': baseDamage[entry.key] ?? 0,
        'hpLost': hpDamage[entry.key] ?? 0,
        'attack': true,
      });
      _event('attackDamageReceived', {
        'sourceId': action.actor.instanceId,
        'targetId': entry.key,
        'amount': _damageAmountVersion == 0
            ? hpDamage[entry.key] ?? 0
            : entry.value,
        if (_damageAmountVersion >= 1) ...{
          'hpLost': hpDamage[entry.key] ?? 0,
          'actualHpLost': hpDamage[entry.key] ?? 0,
          'physicalMagicalDamage': events
              .where(
                (e) =>
                    e.data['targetId'] == entry.key &&
                    (e.data['kind'] == DamageKind.physical.name ||
                        e.data['kind'] == DamageKind.magical.name),
              )
              .fold<int>(0, (n, e) => n + (e.data['amount'] as int? ?? 0)),
        },
        'physicalMagicalHpLost': events
            .where(
              (e) =>
                  e.data['targetId'] == entry.key &&
                  (e.data['kind'] == DamageKind.physical.name ||
                      e.data['kind'] == DamageKind.magical.name),
            )
            .fold<int>(0, (n, e) => n + (e.data['actualHpLost'] as int? ?? 0)),
        'attack': true,
      });
    }

    // Only attacks and played cards count as actions for action-end triggers.
    // Skills keep their damage bookkeeping without activating those triggers.
    if (_interactionRulesVersion < 6 || action.countsAsAction) {
      _event('observedActionResolved', {
        'actorId': action.actor.instanceId,
        'targets': action.targets,
      });
    }
    final primary = action.targets.firstOrNull;
    final recordedDamage = events
        .where(
          (e) =>
              e.data['targetId'] == primary &&
              (_interactionRulesVersion == 0 || e.data['attack'] == true),
        )
        .fold(0, (n, e) => n + damageBeforeShield(e.data));
    _flowSteps([
      () => _healConvertedDamage(action.actor, total),
      if (action.recordable && _interactionRulesVersion == 0)
        for (final player in state.players)
          () => _legacyRecordAction(player.character, action, recordedDamage),
      if (action.recordable)
        for (final entry in action.recordingSelections.entries)
          () {
            final holder = _player(entry.key).character;
            final trait = holder.traits
                .where((t) => t.instanceId == entry.value.traitInstanceId)
                .firstOrNull;
            final rule = trait?.definition.mechanisms
                .get<ActionRecordingRule>();
            if (!holder.alive ||
                _blocked(holder, (s) => s.blockTraits) ||
                rule == null ||
                !_recordingModule.canRecord(
                  holder.instanceId,
                  state.round,
                  rule: rule,
                )) {
              return;
            }
            final selected = entry.value.cardInstanceId;
            final record = RecordedAction(
              state.id('record'),
              action.actor.instanceId,
              recordedDamage,
              action.cards.where((c) => c.instanceId == selected).toList(),
            );
            _recordingModule.record(
              holder.instanceId,
              state.round,
              record,
              rule: rule,
            );
            _event('actionRecorded', {
              'actorId': holder.instanceId,
              'recordId': record.id,
              'damage': record.damage,
              'cards': [for (final c in record.cards) c.definition.id],
            });
          },
    ]);
  }

  void _legacyRecordAction(
    CharacterInstance holder,
    _ObservedAction action,
    int damage,
  ) {
    if (!holder.alive || _blocked(holder, (s) => s.blockTraits)) return;
    final rule = holder.traits
        .map((t) => t.definition.mechanisms.get<ActionRecordingRule>())
        .whereType<ActionRecordingRule>()
        .firstOrNull;
    if (rule == null ||
        !_recordingModule.canRecord(
          holder.instanceId,
          state.round,
          rule: rule,
        )) {
      return;
    }
    _mechanismChoice(
      holder,
      [
        {'action': 'record'},
        {'action': 'skip'},
      ],
      (o) {
        if (o['action'] != 'record') return;
        final record = RecordedAction(
          state.id('record'),
          action.actor.instanceId,
          damage,
          action.cards,
        );
        _recordingModule.record(
          holder.instanceId,
          state.round,
          record,
          rule: rule,
        );
        _event('actionRecorded', {
          'actorId': holder.instanceId,
          'recordId': record.id,
          'damage': record.damage,
          'cards': [for (final c in record.cards) c.definition.id],
        });
      },
    );
  }

  void _healConvertedDamage(CharacterInstance actor, int total) {
    if (!actor.alive || _blocked(actor, (s) => s.blockTraits)) return;
    for (final trait in actor.traits) {
      final entries =
          trait.definition.resourceAbilities.damageHealing.entries
              .where((e) => total >= e.key)
              .toList()
            ..sort((a, b) => b.key.compareTo(a.key));
      if (entries.isNotEmpty) {
        _heal(
          actor,
          actor,
          ((actor.value(Stat.maxHp) - actor.hp) * entries.first.value).floor(),
        );
      }
    }
  }

  void _closeSpecialRound() {
    if (state.round > 1) {
      for (final player in state.players) {
        final actor = player.character;
        if (actor.idleDrawCount > 0 &&
            (_specialRoundDamage[actor.instanceId] ?? 0) == 0) {
          _bonusDrawPending.add(actor.instanceId);
        }
      }
    }
    _specialRoundDamage.clear();
  }

  void _specialDrawBonus(CharacterInstance actor) {
    if (!_bonusDrawPending.remove(actor.instanceId) ||
        actor.idleDrawCount <= 0 ||
        !actor.alive ||
        _blocked(actor, (s) => s.blockTraits || s.blockDrawPhase)) {
      return;
    }
    final others = state.players
        .map((p) => p.character)
        .where((c) => c.alive && c != actor)
        .toList();
    final highest = others.fold(0, (n, c) => c.hp > n ? c.hp : n);
    final candidates = others
        .where((c) => c.hp == highest && c.hand.any((card) => !card.disabled))
        .toList();
    _mechanismChoice(
      actor,
      [
        {'action': 'drawTwo'},
        for (final c in candidates)
          if (actor.idleTakeCount > 0)
            {
              'action': 'takeRandom',
              'targetId': c.instanceId,
              'count': actor.idleTakeCount,
            },
      ],
      (o) {
        if (o['action'] == 'drawTwo') {
          _draw(actor, actor.idleDrawCount, source: actor);
          return;
        }
        final owner = _character(o['targetId']! as String);
        final available = owner.hand.where((c) => !c.disabled).length;
        final takeCount = actor.idleTakeCount.clamp(0, available);
        for (var i = 0; i < takeCount; i++) {
          final cards = owner.hand.where((c) => !c.disabled).toList();
          if (cards.isEmpty) return;
          final card = cards[_nextInt(cards.length)];
          final before = actor.hand.length;
          owner.hand.remove(card);
          actor.hand.add(card);
          _performance.resourceChange(
            actor,
            owner,
            -1,
            resource: StatisticsResource.hand,
          );
          _performance.resourceChange(
            actor,
            actor,
            1,
            resource: StatisticsResource.hand,
          );
          _handCountIncreased(actor, before, source: owner);
          _event('cardsLost', {'actorId': owner.instanceId, 'count': 1});
          _event('cardTaken', {
            'actorId': actor.instanceId,
            'ownerId': owner.instanceId,
          });
        }
      },
    );
  }
}
