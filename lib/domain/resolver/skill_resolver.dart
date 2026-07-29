/// Parses common skill payload fields used by response skills.
class SkillResolver {
  const SkillResolver._();

  static String? readTargetActionId(Map<String, dynamic> data) {
    final actionId = data['responseTargetActionId'] ?? data['targetActionId'];
    if (actionId == null) {
      return null;
    }
    if (actionId is! String || actionId.isEmpty) {
      throw StateError('responseTargetActionId must be a non-empty string');
    }
    return actionId;
  }

  static int readForcedResult(
    Map<String, dynamic> data, {
    required String skillName,
  }) {
    final result = data['forcedResult'];
    if (result is! int) {
      throw StateError('$skillName requires forcedResult as an integer');
    }
    if (result < 1) {
      throw StateError('forcedResult must be a positive integer');
    }
    return result;
  }
}
