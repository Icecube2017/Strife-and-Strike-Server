import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/team_host.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/state.dart';

final class MentalGateModule {
  MentalGateModule(this.host);
  final TeamMechanismHost host;
  final Set<String> _passedMentalActions = {};
  void releaseDead(CharacterInstance source) {
    if (!source.traits.any(
      (t) => t.definition.mechanisms.get<NegativeMpAura>() != null,
    )) {
      return;
    }
    for (final player in host.players) {
      final target = player.character;
      if (!target.alive || target.mp >= 0 || !host.enemy(source, target)) {
        continue;
      }
      host.resetNegativeMp(source, target);
    }
  }

  int floor(CharacterInstance actor) {
    var floor = 0;
    for (final p in host.players) {
      if (!p.character.alive || !host.enemy(p.character, actor)) continue;
      for (final t in p.character.traits) {
        final value = t.definition.mechanisms.get<NegativeMpAura>()?.floor ?? 0;
        if (value < floor) floor = value;
      }
    }
    return floor;
  }

  bool gate(CharacterInstance actor, void Function() resume) {
    if (_passedMentalActions.remove(actor.instanceId)) return false;
    if (host.isAutomatic(actor)) return false;
    final living = host.players.where((p) => p.character.alive).toList();
    final checks = <(CharacterInstance, NegativeMpAura)>[];
    for (var i = 0; i < living.length; i++) {
      final owner = living[i].character;
      if (!host.enemy(owner, actor) || host.traitsBlocked(owner)) {
        continue;
      }
      if (living[(i + 1) % living.length].character != actor &&
          living[(i + living.length - 1) % living.length].character != actor) {
        continue;
      }
      for (final t in owner.traits) {
        final rule = t.definition.mechanisms.get<NegativeMpAura>();
        if (rule != null) checks.add((owner, rule));
      }
    }
    if (checks.isEmpty) return false;
    if (host.previewMode) throw const PreviewBoundary('mentalGateRequired');
    final resumePrepared = host.preserveContinuation(resume);
    void next(int i) {
      if (i == checks.length) {
        _passedMentalActions.add(actor.instanceId);
        try {
          resumePrepared();
        } finally {
          _passedMentalActions.remove(actor.instanceId);
        }
        return;
      }
      final (owner, rule) = checks[i];
      host.roll(actor, rule.sides, 1, (roll) {
        if (roll != rule.failure) {
          next(i + 1);
          return;
        }
        host.failMentalAction(actor, owner);
      });
    }

    next(0);
    return true;
  }
}
