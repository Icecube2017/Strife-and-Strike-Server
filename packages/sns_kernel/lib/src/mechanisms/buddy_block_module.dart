import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/team_host.dart';
import 'package:sns_kernel/src/state.dart';

final class BuddyBlockModule {
  BuddyBlockModule(this.host);
  final TeamMechanismHost host;
  final Set<String> _releasingBuddyMp = {};
  List<(CharacterInstance, BuddyBlockRule)> _targetFeeRules(
    List<String> targets,
  ) => [
    for (final player in host.players)
      if (player.character.alive && !host.traitsBlocked(player.character))
        for (final trait in player.character.traits)
          if (trait.definition.mechanisms.get<BuddyBlockRule>()
              case final rule?)
            if (targets.any((id) {
              final target = host.character(id);
              return target.alive &&
                  target != player.character &&
                  !host.enemy(player.character, target);
            }))
              (player.character, rule),
  ];
  int surcharge(List<String> targets) =>
      _targetFeeRules(targets).fold(0, (n, r) => n + r.$2.surcharge);
  void reward(List<String> targets) {
    for (final (owner, rule) in _targetFeeRules(targets)) {
      host.effects(owner, [], [ModifyMp(rule.recovery)]);
      host.emit('targetFeeApplied', {
        'actorId': owner.instanceId,
        'amount': rule.surcharge,
      });
    }
  }

  void onFact(String type, Map<String, Object?> data) {
    if (!const {'mpChanged', 'mpRegenerated', 'mpSpent'}.contains(type)) return;
    final id = data['targetId'] ?? data['actorId'];
    if (id is! String) return;
    final owner = host.character(id);
    if (!owner.alive || host.traitsBlocked(owner)) return;
    final rule = owner.traits
        .map((t) => t.definition.mechanisms.get<BuddyBlockRule>())
        .whereType<BuddyBlockRule>()
        .firstOrNull;
    if (rule == null) return;
    final delta = (data['amount'] as int? ?? 0) * (type == 'mpSpent' ? -1 : 1);
    final full =
        delta > 0 &&
        owner.mp == owner.value(Stat.maxMp) &&
        owner.mp - delta < owner.mp;
    final empty = delta < 0 && owner.mp == 0;
    if (!full && !empty) return;
    if (full && _releasingBuddyMp.add(owner.instanceId)) {
      try {
        host.payMp(owner, owner.mp);
        final friends = host.players
            .map((p) => p.character)
            .where((c) => c.alive && !host.enemy(owner, c))
            .toList();
        for (final friend in friends) {
          for (final status
              in friend.statuses
                  .where(
                    (s) => rule.includeAnomalies
                        ? s.definition.negative ||
                              s.definition.category == StatusCategory.anomaly
                        : s.definition.isStatusEffect &&
                              s.definition.category == StatusCategory.normal &&
                              s.definition.negative,
                  )
                  .toList()) {
            host.consumeStatus(friend, status, amount: status.stacks);
          }
        }
        host.effects(owner, friends.map((c) => c.instanceId).toList(), [
          ModifyMp(rule.recovery, target: EffectTarget.selected),
        ]);
        host.emit('buddyFullMpReleased', {'actorId': owner.instanceId});
      } finally {
        _releasingBuddyMp.remove(owner.instanceId);
      }
      return;
    }
    if (!empty || rule.drainAmount == 0) return;
    host.enqueueFirst(() {
      if (!owner.alive || host.traitsBlocked(owner)) return;
      final enemies = host.players
          .map((p) => p.character)
          .where((c) => c.alive && host.enemy(owner, c))
          .toList();
      if (enemies.isEmpty) return;
      host.choose(
        owner,
        [
          {'action': 'skipBuddyDrain', 'skip': true},
          for (final enemy in enemies)
            {'action': 'buddyDrain', 'targetId': enemy.instanceId},
        ],
        (choice) {
          if (choice['skip'] != true) {
            host.runAbility(
              owner,
              [choice['targetId']! as String],
              [ModifyMp(-rule.drainAmount, target: EffectTarget.selected)],
              () {},
            );
          }
        },
      );
    });
  }
}
