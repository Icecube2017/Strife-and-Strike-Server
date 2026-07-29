import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';

/// Resolves the effective value of one stat from its base value and modifiers.
class ModifierResolver {
  const ModifierResolver();

  int resolve(int baseValue, Iterable<Modifier> modifiers) {
    final active = modifiers.toList(growable: false);
    final overrides = active
        .where((modifier) => modifier.type == ModifierType.override)
        .map((modifier) => modifier.value);
    if (overrides.isNotEmpty) {
      return overrides.reduce(
        (highest, value) => value > highest ? value : highest,
      );
    }

    var resolved =
        baseValue +
        active
            .where((modifier) => modifier.type == ModifierType.additive)
            .fold<int>(0, (total, modifier) => total + modifier.value);
    for (final modifier in active.where(
      (modifier) => modifier.type == ModifierType.multiplicative,
    )) {
      resolved = (resolved * modifier.value).round();
    }
    return resolved;
  }
}
