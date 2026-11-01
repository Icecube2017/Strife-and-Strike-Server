import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class NightmareHost implements MechanismChoiceHost {
  Iterable<PlayerInstance> get players;
  List<KernelEvent> get events;
  CharacterInstance character(String id);
  int markCount(CharacterInstance actor, String id, {String? sourceId});
  void heal(CharacterInstance source, CharacterInstance target, int amount);
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  );
  VariableState variableCell(String id, CharacterInstance owner);
}

final class NightmareModule {
  NightmareModule(this.host);
  final NightmareHost host;
  List<(CharacterInstance, NightmareRule)> _nightmareRules() => [
    for (final p in host.players)
      if (p.character.alive && !host.traitsBlocked(p.character))
        for (final t in p.character.traits)
          if (t.definition.mechanisms.get<NightmareRule>() != null)
            (p.character, t.definition.mechanisms.get<NightmareRule>()!),
  ];

  List<CharacterInstance> _fruitHolders(NightmareRule rule) => [
    for (final p in host.players)
      if (p.character.alive &&
          !host.traitsBlocked(p.character) &&
          p.character.traits.any((t) => t.definition.id == rule.fruitTraitId))
        p.character,
  ];

  int damageBonus(StatusInstance? status) {
    if (status == null) return 0;
    // Multiple copies provide presence, not multiple copies of the same aura.
    final rule = _nightmareRules()
        .where((e) => e.$2.statusId == status.definition.id)
        .firstOrNull
        ?.$2;
    if (rule == null) return 0;
    return _fruitHolders(rule).fold<int>(
          0,
          (n, c) =>
              n + host.markCount(c, rule.fruitMarkId, sourceId: c.instanceId),
        ) *
        rule.damagePerFruit;
  }

  void healDamage(
    StatusInstance? status,
    CharacterInstance target,
    int eventStart,
  ) {
    if (status == null) return;
    final entry = _nightmareRules()
        .where((e) => e.$2.statusId == status.definition.id)
        .firstOrNull;
    if (entry == null) return;
    final (ruleOwner, rule) = entry;
    final lost = host.events
        .skip(eventStart)
        .where(
          (e) =>
              e.type == 'damage' &&
              e.data['targetId'] == target.instanceId &&
              e.data['statusId'] == status.definition.id,
        )
        .fold<int>(0, (n, e) => n + (e.data['hpLost'] as int? ?? 0));
    final recipients = rule.healingTraitId == null
        ? _fruitHolders(rule)
        : [
            for (final p in host.players)
              if (p.character.alive &&
                  !host.traitsBlocked(p.character) &&
                  p.character.traits.any(
                    (t) => t.definition.id == rule.healingTraitId,
                  ))
                p.character,
          ];
    for (final holder in recipients) {
      host.heal(
        rule.healFromRuleOwner
            ? ruleOwner
            : status.sourceId == null
            ? target
            : host.character(status.sourceId!),
        holder,
        (lost * rule.healingFactor).floor(),
      );
    }
  }

  void settlementCompleted(CharacterInstance owner, StatusInstance status) {
    final rules = _nightmareRules()
        .where((e) => e.$2.statusId == status.definition.id)
        .toList();
    if (rules.isEmpty) return;
    host.emit('statusSettled', {
      'targetId': owner.instanceId,
      'sourceId': status.sourceId,
      'statusId': status.definition.id,
      'instanceId': status.instanceId,
    });
    for (final (holder, rule) in rules) {
      host.modifyVariable(
        holder,
        holder,
        ModifyVariable(
          rule.countVariable,
          operation: VariableOperation.add,
          input: const VariableInput(literal: 1),
        ),
      );
      final count = (host.variableCell(rule.countVariable, holder).value as num)
          .toInt();
      if (count < rule.every) continue;
      host.modifyVariable(
        holder,
        holder,
        ModifyVariable(
          rule.countVariable,
          operation: VariableOperation.add,
          input: VariableInput(literal: -rule.every),
        ),
      );
      host.modifyVariable(
        holder,
        holder,
        ModifyVariable(
          rule.intensityVariable,
          operation: VariableOperation.add,
          input: VariableInput(literal: rule.intensityGain),
        ),
      );
      host.emit('statusIntensityGrowth', {
        'actorId': holder.instanceId,
        'statusId': rule.statusId,
        'amount': rule.intensityGain,
      });
    }
  }
}
