import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class DecreeHost implements MechanismChoiceHost {
  Iterable<PlayerInstance> get players;
  int get round;
  String get anchorPlayerId;
  VariableState variableCell(String id, CharacterInstance owner);
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  );
  CharacterInstance liveTarget(String id);
  int traitCost(CharacterInstance actor, TraitAction action);
  String? traitDisabled(
    CharacterInstance actor,
    TraitInstance trait, {
    TraitAction? option,
  });
  void payMp(CharacterInstance actor, int amount);
  void applyStatus(
    CharacterInstance source,
    CharacterInstance target,
    ApplyStatus effect,
    int multiplier, {
    String? anchorPlayerId,
  });
  void finishResolution();
}

final class DecreeModule {
  DecreeModule(this.host);
  final DecreeHost host;
  int _uses(CharacterInstance actor, DecreeRule rule, String targetId) {
    final rounds = host.variableCell(rule.roundVariable, actor).value as Map;
    if (rounds[targetId] != host.round) return 0;
    if (rule.usesVariable == null) return 1;
    return ((host.variableCell(rule.usesVariable!, actor).value
                    as Map)[targetId]
                as num? ??
            0)
        .toInt();
  }

  List<Map<String, Object?>> choices(CharacterInstance actor, DecreeRule rule) {
    final last = host.variableCell(rule.lastVariable, actor).value as Map;
    return [
      for (final p in host.players)
        if (p.character.alive &&
            _uses(actor, rule, p.character.instanceId) <
                rule.maxUsesPerTargetPerRound)
          for (final entry in rule.statusIds.indexed)
            if (last[p.character.instanceId] != entry.$1)
              {
                'action': 'decree',
                'targetId': p.character.instanceId,
                'statusId': entry.$2,
                'index': entry.$1,
              },
    ];
  }

  void offer(
    CharacterInstance actor,
    TraitInstance trait,
    TraitAction action,
    DecreeRule rule,
  ) {
    host.choose(
      actor,
      [
        {'action': 'cancel'},
        ...choices(actor, rule),
      ],
      (choice) {
        if (choice['action'] == 'cancel') return;
        host.choose(
          actor,
          [
            {'action': 'cancel'},
            {
              ...choice,
              'action': 'confirm',
              'mpCost': host.traitCost(actor, action),
            },
          ],
          (confirm) {
            if (confirm['action'] == 'cancel') return;
            final reason = host.traitDisabled(actor, trait, option: action);
            if (reason != null) throw StateError(reason);
            final target = host.liveTarget(choice['targetId']! as String);
            final used = _uses(actor, rule, target.instanceId);
            if (used >= rule.maxUsesPerTargetPerRound) {
              throw StateError('Decree usage limit reached');
            }
            host.payMp(actor, host.traitCost(actor, action));
            host.applyStatus(
              actor,
              target,
              ApplyStatus(
                choice['statusId']! as String,
                stacks: rule.statusStacks,
                intensity: rule.statusIntensity,
              ),
              1,
              anchorPlayerId: host.anchorPlayerId,
            );
            for (final entry in [
              (rule.roundVariable, host.round),
              (rule.lastVariable, choice['index']! as int),
              if (rule.usesVariable != null) (rule.usesVariable!, used + 1),
            ]) {
              host.modifyVariable(
                actor,
                target,
                ModifyVariable(
                  entry.$1,
                  operation: VariableOperation.mapSet,
                  storageSubject: ValueSubject.self,
                  key: VariableInput(literal: target.instanceId),
                  input: VariableInput(literal: entry.$2),
                ),
              );
            }
            host.emit('traitTriggered', {
              'actorId': actor.instanceId,
              'traitId': trait.definition.id,
              'logTargetIds': List<String>.unmodifiable([target.instanceId]),
            });
            host.finishResolution();
          },
        );
      },
    );
  }
}
