import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/state.dart';

/// Copy history and candidate policy; kernel owns the actual skill execution.
final class SkillCopyModule {
  final Map<String, Set<String>> _used = {};
  Iterable<SkillInstance> candidates(
    String actorId,
    Iterable<SkillDefinition> publicHistory,
    SkillInstance owned,
  ) sync* {
    final used = _used[actorId] ?? const <String>{};
    for (final definition in publicHistory) {
      if (definition.passive ||
          definition.mechanism == SkillMechanism.copyPublicSkill ||
          (!owned.definition.copyPolicy.allowExclusive &&
              definition.exclusive) ||
          (!owned.definition.copyPolicy.allowRepeat &&
              used.contains(definition.id))) {
        continue;
      }
      yield SkillInstance(owned.instanceId, definition)
        ..cooldown = owned.cooldown
        ..cooldownAnchor = owned.cooldownAnchor
        ..remainingUses = owned.remainingUses;
    }
  }

  void markUsed(
    String actorId,
    String definitionId, {
    bool allowRepeat = false,
  }) {
    if (!_used.putIfAbsent(actorId, () => {}).add(definitionId) &&
        !allowRepeat) {
      throw StateError('Skill already copied');
    }
  }
}
