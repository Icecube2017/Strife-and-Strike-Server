import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class TurnSaveHost implements MechanismChoiceHost {
  bool isActivePlayer(CharacterInstance actor);
  String nextId(String prefix);
  int mpFloor(CharacterInstance actor);
  StatusInstance copyStatus(StatusInstance status, {bool restoring});
  void draw(CharacterInstance actor, int count);
  void discardCard(CharacterInstance actor, CardInstance card);
  void enqueueFirst(void Function() continuation);
  void sequence(List<void Function()> steps);
  void drainTriggers();
}

final class CharacterSave {
  CharacterSave(
    this.id,
    this.hp,
    this.mp,
    this.handCount,
    this.statuses,
    this.cooldowns,
  );
  final String id;
  final int hp;
  final int mp;
  final int handCount;
  final List<StatusInstance> statuses;
  final Map<String, int> cooldowns;
  int uses = 0;
  bool get used => uses > 0;
}

final class TurnSaveModule {
  TurnSaveModule(this.host);
  final TurnSaveHost host;
  final Map<String, CharacterSave> _saves = {};
  Map<String, CharacterSave> get saves => Map.unmodifiable(_saves);
  void capture(CharacterInstance actor, {bool explicit = false}) {
    final rule = _rule(actor);
    if (rule == null || (!explicit && !rule.automaticCapture)) return;
    if (!actor.alive ||
        host.traitsBlocked(actor) ||
        !actor.traits.any((t) => t.definition.mechanisms.has<TurnSaveRule>())) {
      return;
    }
    final save = CharacterSave(
      host.nextId('save'),
      actor.hp,
      actor.mp,
      actor.hand.length,
      actor.statuses.map((s) => host.copyStatus(s)).toList(),
      {for (final skill in actor.skills) skill.instanceId: skill.cooldown},
    );
    _saves[actor.instanceId] = save;
    host.emit('saveCreated', {'actorId': actor.instanceId, 'saveId': save.id});
  }

  TurnSaveRule? _rule(CharacterInstance actor) => actor.traits
      .map((t) => t.definition.mechanisms.get<TurnSaveRule>())
      .whereType<TurnSaveRule>()
      .firstOrNull;

  bool restore(CharacterInstance actor) {
    final rule = _rule(actor);
    final save = _saves[actor.instanceId];
    if (rule == null ||
        save == null ||
        save.uses >= rule.maxUses ||
        save.hp <= 0 ||
        (!rule.allowOwnTurn && host.isActivePlayer(actor)) ||
        host.traitsBlocked(actor) ||
        !actor.traits.any((t) => t.definition.mechanisms.has<TurnSaveRule>())) {
      return false;
    }
    save.uses++;
    // Presentation fact only: do not run permanent-death triggers or clear cards.
    host.emit('deathAnnounced', {
      'instanceId': actor.instanceId,
      'restoring': true,
    });
    if (rule.restoreStatuses) {
      actor.statuses
        ..clear()
        ..addAll(save.statuses.map((s) => host.copyStatus(s, restoring: true)));
    }
    actor.hp = save.hp.clamp(1, actor.value(Stat.maxHp));
    if (rule.restoreMp) {
      actor.mp = save.mp.clamp(host.mpFloor(actor), actor.value(Stat.maxMp));
    }
    if (rule.restoreCooldowns) {
      for (final skill in actor.skills) {
        if (save.cooldowns.containsKey(skill.instanceId)) {
          skill.cooldown = save.cooldowns[skill.instanceId]!;
        }
      }
    }
    host.emit('saveRestored', {'actorId': actor.instanceId, 'saveId': save.id});
    if (rule.restoreHand) {
      host.enqueueFirst(() => restoreHandCount(actor, save.handCount));
    }
    return true;
  }

  void restoreHandCount(CharacterInstance actor, int count) {
    if (!actor.alive) return;
    if (actor.hand.length < count) {
      host.draw(actor, count - actor.hand.length);
      return;
    }
    if (actor.hand.length == count) return;
    host.choose(
      actor,
      [
        for (final c in actor.hand)
          {
            'action': 'restoreDiscard',
            'instanceId': c.instanceId,
            'definitionId': c.definition.id,
          },
      ],
      (o) {
        final card = actor.hand.singleWhere(
          (c) => c.instanceId == o['instanceId'],
        );
        host.discardCard(actor, card);
        host.emit('cardsLost', {
          'actorId': actor.instanceId,
          'count': 1,
          'reason': 'saveRestore',
        });
        host.sequence([
          host.drainTriggers,
          () => restoreHandCount(actor, count),
        ]);
      },
    );
  }
}
