import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class ResourceReserveHost implements MechanismChoiceHost {
  Iterable<PlayerInstance> get players;
  int get playerCount;
  int get round;
  bool get previewMode;
  bool isAutomatic(CharacterInstance actor);
  bool enemy(CharacterInstance a, CharacterInstance b);
  CharacterInstance character(String id);
  CharacterInstance liveTarget(String id);
  void Function() preserveContinuation(void Function() resume);
  MarkDefinition markDefinition(String id);
  int markCount(CharacterInstance actor, String id, {String? sourceId});
  void modifyMark(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyMark effect,
    int multiplier,
  );
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  );
  VariableState variableCell(String id, CharacterInstance owner);
  void discardCards(CharacterInstance actor, List<CardInstance> cards);
  void payMp(CharacterInstance actor, int amount);
  void effects(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
  );
  void runAbility(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
    void Function() complete,
  );
}

final class ResourceReserveModule {
  ResourceReserveModule(this.host);
  final ResourceReserveHost host;
  final Set<String> _passedReserveActions = {};
  void finishAction() => _passedReserveActions.clear();
  int convertRecovery(CharacterInstance actor, int recovery) {
    for (final trait in actor.traits) {
      final rule = trait.definition.mechanisms.get<TimeReserveRule>();
      if (rule == null ||
          recovery < rule.recoveryMpCost ||
          !hasRoom(actor, rule, gain: rule.recoveryMarkGain)) {
        continue;
      }
      host.modifyMark(
        actor,
        actor,
        ModifyMark(rule.markId, amount: rule.recoveryMarkGain),
        1,
      );
      host.emit('mpConvertedToReserve', {
        'actorId': actor.instanceId,
        'markId': rule.markId,
        'amount': rule.recoveryMarkGain,
      });
      return recovery - rule.recoveryMpCost;
    }
    return recovery;
  }

  bool discard(CharacterInstance actor) {
    if (host.traitsBlocked(actor)) return false;
    final rule = actor.traits
        .map((t) => t.definition.mechanisms.get<DiscardReserveRule>())
        .whereType<DiscardReserveRule>()
        .firstOrNull;
    if (rule == null) return false;
    final cards = actor.hand.where((c) => !c.disabled).toList();
    host.discardCards(actor, cards);
    if (cards.isNotEmpty) {
      host.emit('cardsDiscarded', {
        'actorId': actor.instanceId,
        'cards': cards.map((c) => c.instanceId).toList(),
      });
    }
    final mp = actor.mp.clamp(0, 1000000);
    if (mp > 0) host.payMp(actor, mp);
    host.modifyVariable(
      actor,
      actor,
      ModifyVariable(
        rule.variable,
        operation: VariableOperation.add,
        input: VariableInput(literal: mp),
      ),
    );
    host.effects(actor, [], [
      ShieldEffect(cards.length * rule.shieldPerCard + mp * rule.shieldPerMp),
    ]);
    host.emit('discardReserveStored', {
      'actorId': actor.instanceId,
      'count': cards.length,
      'amount': mp,
    });
    return true;
  }

  int claim(CharacterInstance actor) {
    if (host.traitsBlocked(actor)) return 0;
    var bonus = 0;
    for (final trait in actor.traits) {
      final rule = trait.definition.mechanisms.get<DiscardReserveRule>();
      if (rule == null) continue;
      bonus += (host.variableCell(rule.variable, actor).value as num).toInt();
      host.modifyVariable(
        actor,
        actor,
        ModifyVariable(
          rule.variable,
          operation: VariableOperation.assign,
          input: const VariableInput(literal: 0),
        ),
      );
    }
    return bonus;
  }

  bool hasRoom(CharacterInstance actor, TimeReserveRule rule, {int gain = 1}) {
    final definition = host.markDefinition(rule.markId);
    final cap = definition.playerCountBonus == null
        ? definition.maxCount ?? 1000000
        : host.playerCount + definition.playerCountBonus!;
    return host.markCount(actor, rule.markId) + gain <= cap;
  }

  void collectOverflow(String type, Map<String, Object?> data) {
    if (!const {'mpChanged', 'mpRegenerated'}.contains(type)) return;
    final overflow = data['overflow'] as int? ?? 0;
    if (overflow <= 0) return;
    for (final player in host.players) {
      final actor = player.character;
      if (!actor.alive || host.traitsBlocked(actor)) continue;
      for (final trait in actor.traits) {
        final rule = trait.definition.mechanisms.get<TimeReserveRule>();
        if (rule == null || rule.overflowMarkGain == 0) continue;
        host.modifyMark(
          actor,
          actor,
          ModifyMark(rule.markId, amount: overflow * rule.overflowMarkGain),
          1,
        );
      }
    }
  }

  String? manualDisabledReason(CharacterInstance actor, TimeReserveRule rule) {
    if (host.markCount(actor, rule.markId) == 0) return 'insufficientMarks';
    if (usesThisRound(actor, rule) >= rule.maxUsesPerRound) {
      return 'usageLimit';
    }
    return null;
  }

  int usesThisRound(CharacterInstance actor, TimeReserveRule rule) {
    if ((host.variableCell(rule.variable, actor).value as num) != host.round) {
      return 0;
    }
    return rule.usesVariable == null
        ? 1
        : (host.variableCell(rule.usesVariable!, actor).value as num).toInt();
  }

  void _recordUse(CharacterInstance actor, TimeReserveRule rule) {
    final count = usesThisRound(actor, rule) + 1;
    for (final entry in [
      (rule.variable, host.round),
      if (rule.usesVariable != null) (rule.usesVariable!, count),
    ]) {
      host.modifyVariable(
        actor,
        actor,
        ModifyVariable(
          entry.$1,
          operation: VariableOperation.assign,
          input: VariableInput(literal: entry.$2),
        ),
      );
    }
  }

  int _spendCount(
    CharacterInstance actor,
    CharacterInstance target,
    TimeReserveRule rule,
  ) => host
      .markCount(actor, rule.markId)
      .clamp(
        0,
        ((target.value(Stat.maxMp) - target.mp) / rule.mpPerMark).ceil(),
      );

  void useManual(
    CharacterInstance actor,
    CharacterInstance target,
    void Function() complete,
  ) {
    final rule = actor.traits
        .map((t) => t.definition.mechanisms.get<TimeReserveRule>())
        .whereType<TimeReserveRule>()
        .where((rule) => rule.manualUse)
        .firstOrNull;
    if (rule == null || host.traitsBlocked(actor)) {
      throw StateError('Time reserve is not available');
    }
    final reason = manualDisabledReason(actor, rule);
    if (reason != null) throw StateError(reason);
    if (!target.alive ||
        host.enemy(actor, target) ||
        target.mp >= target.value(Stat.maxMp)) {
      throw StateError('No eligible time reserve target');
    }
    if (host.previewMode) throw const PreviewBoundary('unprojectedTimeReserve');
    final count = _spendCount(actor, target, rule);
    _recordUse(actor, rule);
    host.modifyMark(actor, actor, ModifyMark(rule.markId, amount: -count), 1);
    host.runAbility(
      actor,
      [target.instanceId],
      [
        ModifyMp(count * rule.mpPerMark, target: EffectTarget.selected),
        ApplyStatus(
          rule.statusId,
          stacks: rule.statusStacks,
          intensity: rule.strength + count * rule.intensityPerMark,
        ),
      ],
      () {
        host.emit('timeReserveUsed', {
          'actorId': actor.instanceId,
          'targetId': target.instanceId,
          'amount': count,
        });
        complete();
      },
    );
  }

  bool offer(CharacterInstance actor, void Function() resume) {
    if (_passedReserveActions.contains(actor.instanceId) ||
        host.isAutomatic(actor) ||
        host.traitsBlocked(actor)) {
      return false;
    }
    final rule = actor.traits
        .map((t) => t.definition.mechanisms.get<TimeReserveRule>())
        .whereType<TimeReserveRule>()
        .firstOrNull;
    if (rule == null || rule.manualUse) return false;
    if (host.previewMode) throw const PreviewBoundary('unprojectedTimeReserve');
    if (host.markCount(actor, rule.markId) == 0 ||
        usesThisRound(actor, rule) >= rule.maxUsesPerRound) {
      return false;
    }
    final targets = host.players
        .map((p) => p.character)
        .where(
          (c) => c.alive && !host.enemy(actor, c) && c.mp < c.value(Stat.maxMp),
        )
        .toList();
    if (targets.isEmpty) return false;
    if (host.previewMode) {
      throw const PreviewBoundary('timeReserveChoiceRequired');
    }
    final resumePrepared = host.preserveContinuation(resume);
    host.choose(
      actor,
      [
        {'action': 'skipTimeReserve', 'skip': true},
        for (final target in targets)
          {'action': 'useTimeReserve', 'targetId': target.instanceId},
      ],
      (option) {
        void finish() {
          _passedReserveActions.add(actor.instanceId);
          resumePrepared();
        }

        if (option['skip'] == true) {
          finish();
          return;
        }
        final target = host.liveTarget(option['targetId']! as String);
        final count = _spendCount(actor, target, rule);
        _recordUse(actor, rule);
        host.modifyMark(
          actor,
          actor,
          ModifyMark(rule.markId, amount: -count),
          1,
        );
        host.runAbility(
          actor,
          [target.instanceId],
          [
            ModifyMp(count * rule.mpPerMark, target: EffectTarget.selected),
            ApplyStatus(
              rule.statusId,
              stacks: rule.statusStacks,
              intensity: rule.strength + count * rule.intensityPerMark,
            ),
          ],
          () {
            host.emit('timeReserveUsed', {
              'actorId': actor.instanceId,
              'targetId': target.instanceId,
              'amount': count,
            });
            finish();
          },
        );
      },
    );
    return true;
  }
}
