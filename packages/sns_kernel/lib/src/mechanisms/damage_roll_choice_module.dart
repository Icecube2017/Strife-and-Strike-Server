import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/dice.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class DamageRollChoiceHost implements MechanismChoiceHost {
  bool get previewMode;
}

final class DamageRollChoiceModule {
  DamageRollChoiceModule(this.host);
  final DamageRollChoiceHost host;
  void choose(
    CharacterInstance actor,
    RollResult Function() generate,
    void Function(RollResult) complete, {
    bool locked = false,
  }) {
    final trait = !host.traitsBlocked(actor)
        ? actor.traits
              .where((t) => t.definition.mechanisms.has<DamageRollChoiceRule>())
              .firstOrNull
        : null;
    final count =
        trait?.definition.mechanisms.get<DamageRollChoiceRule>()?.rollCount ??
        1;
    if (locked || trait == null || count == 1) {
      complete(generate());
      return;
    }
    if (host.previewMode) {
      throw const PreviewBoundary('damageDiceChoiceRequired');
    }
    host.choose(
      actor,
      [
        {'action': 'single', 'traitId': trait.definition.id},
        {
          'action': 'double',
          'traitId': trait.definition.id,
          'rollCount': count,
        },
      ],
      (o) {
        final first = generate();
        if (o['action'] == 'single') {
          complete(first);
          return;
        }
        final rolls = [first, for (var i = 1; i < count; i++) generate()];
        host.choose(
          actor,
          [
            for (var i = 0; i < rolls.length; i++)
              {
                'action': 'selectRoll',
                'index': i,
                'result': rolls[i].finalTotal,
              },
          ],
          (choice) {
            final selected = rolls[choice['index']! as int];
            final result = selected.finalTotal;
            host.emit('damageDiceSelected', {
              'actorId': actor.instanceId,
              'traitId': trait.definition.id,
              'results': rolls.map((r) => r.finalTotal).toList(),
              'rollIds': rolls.map((r) => r.id).toList(),
              'index': choice['index'],
              'result': result,
            });
            complete(selected);
          },
        );
      },
    );
  }
}
