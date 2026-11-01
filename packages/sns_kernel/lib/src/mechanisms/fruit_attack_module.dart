import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class FruitAttackHost implements MechanismChoiceHost {
  CharacterInstance character(String id);
  int markCount(CharacterInstance actor, String id, {String? sourceId});
  void effects(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
  );
  void consumeStatus(
    CharacterInstance actor,
    StatusInstance status, {
    int amount,
  });
  void runAbility(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
    void Function() complete,
  );
}

final class FruitAttackModule {
  FruitAttackModule(this.host);
  final FruitAttackHost host;
  final Map<String, Map<String, int>> _fruitDiceAdjustments = {};
  int adjustmentFor(String actionId, String targetId) =>
      _fruitDiceAdjustments[actionId]?[targetId] ?? 0;
  void finishAction(String actionId) => _fruitDiceAdjustments.remove(actionId);
  void offer(CharacterInstance attacker, PendingResolution pending) {
    final offers =
        <(CharacterInstance, CharacterInstance, TraitInstance, int)>[];
    for (final id in pending.targets) {
      final target = host.character(id);
      for (final pair in [(attacker, target, 1), (target, attacker, -1)]) {
        if (!pair.$1.alive || host.traitsBlocked(pair.$1)) continue;
        for (final trait in pair.$1.traits) {
          if (trait.definition.mechanisms.get<FruitAttackRule>() != null) {
            offers.add((pair.$1, pair.$2, trait, pair.$3));
          }
        }
      }
    }
    void next(int i) {
      if (!attacker.alive || i == offers.length) return;
      final (owner, other, trait, direction) = offers[i];
      final rule = trait.definition.mechanisms.get<FruitAttackRule>()!;
      if (!owner.alive ||
          !other.alive ||
          host.markCount(owner, rule.markId, sourceId: owner.instanceId) <
              rule.markCost) {
        next(i + 1);
        return;
      }
      host.choose(
        owner,
        [
          {'action': 'skip'},
          {
            'action': 'spendFruit',
            'traitId': trait.definition.id,
            'targetId': other.instanceId,
          },
        ],
        (o) {
          if (o['action'] == 'skip') {
            next(i + 1);
            return;
          }
          host.effects(
            owner,
            [owner.instanceId],
            [ModifyMark(rule.markId, amount: -rule.markCost)],
          );
          final status = other.statuses
              .where((s) => s.definition.id == rule.clearStatus)
              .firstOrNull;
          host.emit('traitTriggered', {
            'actorId': owner.instanceId,
            'traitId': trait.definition.id,
            'logTargetIds': List<String>.unmodifiable([
              status != null || direction == 1
                  ? other.instanceId
                  : owner.instanceId,
            ]),
          });
          if (status != null) {
            host.consumeStatus(other, status, amount: status.stacks);
            next(i + 1);
            return;
          }
          final targetId = direction == 1 ? other.instanceId : owner.instanceId;
          final adjustments = _fruitDiceAdjustments.putIfAbsent(
            pending.id,
            () => {},
          );
          adjustments.update(
            targetId,
            (n) => n + direction * rule.diceDelta,
            ifAbsent: () => direction * rule.diceDelta,
          );
          host.emit('attackDiceAdjusted', {
            'sourceId': owner.instanceId,
            'targetId': targetId,
            'actionId': pending.id,
            'amount': direction * rule.diceDelta,
          });
          host.runAbility(
            owner,
            [other.instanceId],
            [DamageEffect(rule.damage, kind: DamageKind.magical)],
            () => next(i + 1),
          );
        },
      );
    }

    next(0);
  }
}
