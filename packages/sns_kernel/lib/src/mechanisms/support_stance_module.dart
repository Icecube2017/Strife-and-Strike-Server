import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/team_host.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/state.dart';

final class SupportStanceModule {
  SupportStanceModule(this.host);
  final TeamMechanismHost host;
  Iterable<SupportStanceRule> _supportRules(CharacterInstance actor) => actor
      .traits
      .map((t) => t.definition.mechanisms.get<SupportStanceRule>())
      .whereType<SupportStanceRule>();
  int _numberVariable(CharacterInstance actor, String id) =>
      (host.variableCell(id, actor).value as num).toInt();
  void _setNumberVariable(CharacterInstance actor, String id, int value) =>
      host.modifyVariable(
        actor,
        actor,
        ModifyVariable(
          id,
          operation: VariableOperation.assign,
          input: VariableInput(literal: value),
        ),
      );

  void atStart(
    CharacterInstance actor, {
    int round = 2,
    bool enforceStartRound = true,
  }) {
    for (final rule in _supportRules(actor)) {
      _setNumberVariable(actor, rule.defenseVariable, 0);
      _setNumberVariable(actor, rule.attackVariable, 0);
      if ((enforceStartRound && round < rule.startRound) ||
          host.traitsBlocked(actor) ||
          _numberVariable(actor, rule.previousVariable) >=
              rule.previousHitsBelow) {
        continue;
      }
      host.roll(actor, rule.rollSides, rule.rollCount, (result) {
        _setNumberVariable(actor, rule.defenseVariable, rule.defenseUses);
        _setNumberVariable(actor, rule.attackVariable, rule.attackUses);
        host.effects(actor, [], [
          ApplyStatus(
            rule.statusId,
            stacks: rule.statusStacks,
            intensity: result,
            target: EffectTarget.self,
          ),
        ]);
        host.emit('supportStanceEntered', {
          'actorId': actor.instanceId,
          'intensity': result,
        });
      });
    }
  }

  void onFact(String type, Map<String, Object?> data) {
    if (type == 'roundStarted') {
      for (final player in host.players) {
        for (final rule in _supportRules(player.character)) {
          _setNumberVariable(
            player.character,
            rule.previousVariable,
            _numberVariable(player.character, rule.currentVariable),
          );
          _setNumberVariable(player.character, rule.currentVariable, 0);
        }
      }
      return;
    }
    if (type != 'attackDamageReceived' || (data['amount'] as int? ?? 0) <= 0) {
      return;
    }
    final actor = host.character(data['targetId']! as String);
    for (final rule in _supportRules(actor)) {
      _setNumberVariable(
        actor,
        rule.currentVariable,
        _numberVariable(actor, rule.currentVariable) + 1,
      );
      if ((data['amount']! as int) > rule.damageThreshold &&
          !host.traitsBlocked(actor) &&
          rule.cooldownReduction > 0) {
        host.effects(actor, [], [ModifyCooldown(-rule.cooldownReduction)]);
      }
    }
  }

  void redirect(CharacterInstance attacker, PendingResolution pending) {
    if (host.previewMode &&
        host.players.any((p) => _supportRules(p.character).isNotEmpty)) {
      throw const PreviewBoundary('unprojectedSupportHistory');
    }
    final targets = pending.targets.toList();
    final guardians = host.players.map((p) => p.character).toList();
    for (final guardian in guardians) {
      if (!guardian.alive ||
          guardian == attacker ||
          host.traitsBlocked(guardian)) {
        continue;
      }
      for (final rule in _supportRules(guardian)) {
        if (_numberVariable(guardian, rule.defenseVariable) == 0) continue;
        final index = targets.indexWhere((id) {
          final target = host.character(id);
          return target.alive &&
              target != guardian &&
              !host.enemy(guardian, target);
        });
        if (index < 0) continue;
        final old = targets[index];
        targets[index] = guardian.instanceId;
        _setNumberVariable(
          guardian,
          rule.defenseVariable,
          _numberVariable(guardian, rule.defenseVariable) - 1,
        );
        host.emit('attackTargetRedirected', {
          'actorId': attacker.instanceId,
          'sourceId': guardian.instanceId,
          'targetId': old,
          'replacementId': guardian.instanceId,
          'actionId': pending.id,
        });
      }
    }
    pending.targets = List.unmodifiable(targets.toSet());
  }

  void offerAttack(
    CharacterInstance actor,
    List<String> targets, {
    required bool recordable,
  }) {
    if (!actor.alive ||
        !recordable ||
        targets.isEmpty ||
        host.traitsBlocked(actor)) {
      return;
    }
    final target = host.character(targets.first);
    if (!target.alive) return;
    for (final rule in _supportRules(actor)) {
      if (_numberVariable(actor, rule.attackVariable) == 0) continue;
      final candidates = host.players
          .map((p) => p.character)
          .where(
            (c) =>
                c.alive &&
                c != actor &&
                c != target &&
                !host.enemy(actor, c) &&
                host.attackAllowed(c, target) &&
                (c.extraTurnAttackTarget == null ||
                    c.extraTurnAttackTarget == target.instanceId) &&
                (c.nextAttackTargetId == null ||
                    c.nextAttackTargetId == target.instanceId),
          )
          .toList();
      if (candidates.isEmpty) return;
      candidates.sort((a, b) {
        final power = b.value(Stat.attack).compareTo(a.value(Stat.attack));
        return power != 0
            ? power
            : host.actionSeat(a).compareTo(host.actionSeat(b));
      });
      final ally = candidates.first;
      host.choose(
        actor,
        [
          {'action': 'skipSupportAttack', 'skip': true},
          {
            'action': 'supportAttack',
            'targetId': target.instanceId,
            'allyId': ally.instanceId,
          },
        ],
        (choice) {
          if (choice['skip'] == true) return;
          _setNumberVariable(
            actor,
            rule.attackVariable,
            _numberVariable(actor, rule.attackVariable) - 1,
          );
          host.emit('supportAttackStarted', {
            'actorId': actor.instanceId,
            'sourceId': ally.instanceId,
            'targetId': target.instanceId,
          });
          host.automaticAttack(ally, target);
        },
      );
      return;
    }
  }
}
