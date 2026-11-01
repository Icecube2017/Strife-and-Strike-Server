import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class DreamCraftHost implements MechanismChoiceHost {
  void consumeStatus(
    CharacterInstance actor,
    StatusInstance status, {
    int amount,
  });
  void applyStatus(
    CharacterInstance source,
    CharacterInstance target,
    ApplyStatus effect,
    int multiplier,
  );
  void payMp(CharacterInstance actor, int amount);
  void discardCards(CharacterInstance actor, List<CardInstance> cards);
}

final class DreamCraftModule {
  DreamCraftModule(this.host);
  final DreamCraftHost host;
  void convert(CharacterInstance actor) {
    if (!actor.alive) return;
    for (final trait in actor.traits) {
      final rule = trait.definition.mechanisms.get<DreamCraftRule>();
      if (rule == null ||
          host.traitsBlocked(actor, exceptStatus: rule.fromStatus)) {
        continue;
      }
      final dreams = actor.statuses
          .where((s) => s.definition.id == rule.fromStatus)
          .toList();
      for (final dream in dreams) {
        final stacks = dream.stacks, intensity = dream.intensity;
        host.consumeStatus(actor, dream, amount: stacks);
        host.applyStatus(
          actor,
          actor,
          ApplyStatus(rule.toStatus, stacks: stacks, intensity: intensity),
          1,
        );
      }
    }
  }

  void atStart(CharacterInstance actor) {
    // Conversion is intentionally earlier than trait-block checks and recovery.
    // Dream blocks traits; it must not prevent its own prescribed conversion.
    for (final trait in actor.traits) {
      final rule = trait.definition.mechanisms.get<DreamCraftRule>();
      if (rule == null) continue;
      if (!actor.alive ||
          host.traitsBlocked(actor) ||
          actor.hand.where((c) => !c.disabled).length < rule.discardCount ||
          (!actor.noMp && actor.mp < rule.mpCost)) {
        continue;
      }
      final selected = <CardInstance>[];
      void choose() {
        host.choose(
          actor,
          [
            {'action': 'cancel'},
            for (final card in actor.hand.where(
              (c) => !c.disabled && !selected.contains(c),
            ))
              {
                'action': 'discardForDream',
                'instanceId': card.instanceId,
                'definitionId': card.definition.id,
              },
          ],
          (o) {
            if (o['action'] == 'cancel') return;
            selected.add(
              actor.hand.singleWhere((c) => c.instanceId == o['instanceId']),
            );
            if (selected.length < rule.discardCount) {
              choose();
              return;
            }
            host.choose(
              actor,
              [
                {'action': 'cancel'},
                {
                  'action': 'confirmDream',
                  'mpCost': rule.mpCost,
                  'discardCardInstanceIds': selected
                      .map((c) => c.instanceId)
                      .toList(),
                },
              ],
              (confirm) {
                if (confirm['action'] == 'cancel') return;
                if (!actor.noMp && actor.mp < rule.mpCost) {
                  throw StateError('Insufficient MP');
                }
                host.payMp(actor, rule.mpCost);
                host.discardCards(actor, selected);
                host.emit('cardsLost', {
                  'actorId': actor.instanceId,
                  'count': selected.length,
                  'reason': 'traitCost',
                });
                host.applyStatus(
                  actor,
                  actor,
                  ApplyStatus(
                    rule.toStatus,
                    stacks: rule.statusStacks,
                    intensity: rule.statusIntensity,
                  ),
                  1,
                );
                host.emit('traitTriggered', {
                  'actorId': actor.instanceId,
                  'traitId': trait.definition.id,
                  'logTargetIds': List<String>.unmodifiable([actor.instanceId]),
                });
              },
            );
          },
        );
      }

      choose();
      return;
    }
  }

  void offerRemoval(CharacterInstance actor) {
    if (!actor.alive || host.traitsBlocked(actor)) return;
    final rule = actor.traits
        .map((t) => t.definition.mechanisms.get<DreamCraftRule>())
        .whereType<DreamCraftRule>()
        .firstOrNull;
    if (rule == null ||
        !actor.statuses.any((s) => s.definition.id == rule.toStatus)) {
      return;
    }
    host.choose(
      actor,
      [
        {'action': 'keepDream'},
        {'action': 'clearDream'},
      ],
      (o) {
        if (o['action'] == 'clearDream') {
          for (final status
              in actor.statuses
                  .where((s) => s.definition.id == rule.toStatus)
                  .toList()) {
            host.consumeStatus(actor, status, amount: status.stacks);
          }
        }
      },
    );
  }
}
