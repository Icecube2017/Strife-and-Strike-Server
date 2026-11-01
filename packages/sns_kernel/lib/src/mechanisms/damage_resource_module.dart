import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class DamageResourceHost implements MechanismChoiceHost {
  CharacterInstance character(String id);
  VariableState variableCell(String id, CharacterInstance owner);
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  );
  void applyStatus(
    CharacterInstance source,
    CharacterInstance target,
    ApplyStatus effect,
    int multiplier,
  );
  void consumeStatus(
    CharacterInstance actor,
    StatusInstance status, {
    int amount = 1,
  });
  void queueDamageReaction(
    CharacterInstance actor,
    CharacterInstance target,
    int amount,
    ApplyStatus status,
  );
}

final class DamageResourceModule {
  DamageResourceModule(this.host);
  final DamageResourceHost host;
  void onFact(String type, Map<String, Object?> data) {
    if (type != 'damage' && type != 'attackDamageReceived') return;
    if (type == 'damage' &&
        (data['attack'] == true || data['kind'] == DamageKind.lifeLoss.name)) {
      return;
    }
    final targetId = data['targetId'] as String?;
    if (targetId == null) return;
    final target = host.character(targetId);
    if (!target.alive || host.traitsBlocked(target)) return;
    // Unmarked raw events belong to historical journals, whose resource gain
    // used HP loss. New damage and attack summaries use the unified amount.
    final amount = type == 'damage' && data['amountIncludesShield'] != true
        ? data['actualHpLost'] as int? ?? 0
        : data['amount'] as int? ?? 0;
    if (amount <= 0) return;
    final physicalMagical = type == 'attackDamageReceived'
        ? data['physicalMagicalDamage'] as int? ??
              data['physicalMagicalHpLost'] as int? ??
              0
        : (data['kind'] == DamageKind.physical.name ||
              data['kind'] == DamageKind.magical.name)
        ? amount
        : 0;
    for (final trait in target.traits) {
      final resource = trait.definition.mechanisms.get<DamageResourceRule>();
      if (resource == null) continue;
      host.modifyVariable(
        target,
        target,
        ModifyVariable(
          resource.variable,
          operation: VariableOperation.add,
          input: VariableInput(literal: (amount * resource.factor).floor()),
        ),
      );
      if (physicalMagical < resource.threshold) continue;
      final accumulated =
          (host.variableCell(resource.variable, target).value as num).toInt();
      host.modifyVariable(
        target,
        target,
        ModifyVariable(resource.variable, operation: VariableOperation.clear),
      );
      final sourceId = data['sourceId'] as String?;
      host.applyStatus(
        target,
        target,
        ApplyStatus(
          resource.selfStatusId,
          stacks: resource.selfStatusStacks,
          intensity: resource.selfStatusIntensity,
        ),
        1,
      );
      // The reaction's lock is independent of the removable/immune debuff.
      // A repeated reaction restarts its single natural-round timer.
      if (resource.reactionLockStatusId case final lockId?) {
        final previous = target.statuses
            .where((s) => s.definition.id == lockId)
            .firstOrNull;
        if (previous != null) {
          // End-phase decay captures existing instances before settlement.
          // Replace the timer so that capture cannot age a fresh reaction.
          host.consumeStatus(target, previous, amount: previous.stacks);
        }
        if (resource.reactionLockRounds > 0) {
          host.applyStatus(
            target,
            target,
            ApplyStatus(lockId, stacks: resource.reactionLockRounds),
            1,
          );
        }
      }
      host.emit('resourceReaction', {
        'actorId': target.instanceId,
        'amount': accumulated,
        'targetId': sourceId,
      });
      if (sourceId == null) continue;
      final source = host.character(sourceId);
      host.queueDamageReaction(
        target,
        source,
        accumulated,
        ApplyStatus(
          resource.targetStatusId,
          stacks: resource.targetStatusStacks,
          intensity: resource.targetStatusIntensity,
        ),
      );
    }
  }
}
