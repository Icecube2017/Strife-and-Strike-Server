import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class SummonDefenseHost {
  Iterable<SummonedUnitInstance> get units;
  void createUnit(
    CharacterInstance actor,
    CharacterInstance owner,
    String kind,
  );
  VariableState variableCell(String id, CharacterInstance owner);
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  );
}

final class SummonDefenseModule {
  SummonDefenseModule(this.host);
  final SummonDefenseHost host;
  int count(CharacterInstance owner, String kind) => host.units
      .where((u) => u.alive && u.ownerId == owner.instanceId && u.kind == kind)
      .length;
  int cap(CharacterInstance owner, SummonDefenseRule rule) =>
      (rule.baseCap +
              (owner.value(Stat.maxHp) - owner.hp).clamp(0, 1000000000) ~/
                  rule.hpPerSlot)
          .clamp(rule.baseCap, rule.maxCap);
  void summon(
    CharacterInstance actor,
    CharacterInstance owner,
    SummonUnit effect,
  ) {
    final rule = owner.traits
        .map((t) => t.definition.mechanisms.get<SummonDefenseRule>())
        .whereType<SummonDefenseRule>()
        .where((r) => r.kind == effect.kind && !r.blockHealing)
        .firstOrNull;
    var spawnCount = effect.count;
    if (rule != null) {
      spawnCount = spawnCount.clamp(
        0,
        (cap(owner, rule) - count(owner, effect.kind)).clamp(0, 1000000),
      );
    }
    for (var i = 0; i < spawnCount; i++) {
      host.createUnit(actor, owner, effect.kind);
    }
    if (spawnCount > 0 && rule != null) {
      host.modifyVariable(
        owner,
        owner,
        ModifyVariable(
          rule.historyVariable,
          operation: VariableOperation.assign,
          input: const VariableInput(literal: 1),
        ),
      );
    }
  }

  bool healingBlocked(CharacterInstance owner) => owner.traits.any((t) {
    final r = t.definition.mechanisms.get<SummonDefenseRule>();
    // Permanent prohibition survives trait-blocking, as an acquired consequence.
    return r != null &&
        r.blockHealing &&
        (host.variableCell(r.historyVariable, owner).value as num) > 0;
  });
}
