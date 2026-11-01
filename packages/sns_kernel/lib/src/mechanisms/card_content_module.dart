import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class CardContentHost implements MechanismChoiceHost {
  bool get previewMode;
  VariableState variableCell(String id, CharacterInstance owner);
  void modifyVariable(
    CharacterInstance actor,
    CharacterInstance target,
    ModifyVariable effect,
  );
  void effects(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
  );
  void runAbility(
    CharacterInstance actor,
    List<String> targets,
    List<EffectDefinition> effects,
    void Function() complete, {
    bool independentDamage,
  });
  CardInstance physicalCard(CharacterInstance actor, CardInstance card);
  void sequence(List<void Function()> steps);
}

final class CardContentModule {
  CardContentModule(this.host);
  final CardContentHost host;
  final Map<String, int> _tagDice = {};
  final Map<String, List<EffectDefinition>> _tagHits = {};
  final Map<String, List<EffectDefinition>> _rotatingHits = {};
  int diceBonus(String actionId) => _tagDice[actionId] ?? 0;
  List<EffectDefinition> tagEffects(String actionId) =>
      List.unmodifiable(_tagHits[actionId] ?? const []);
  List<EffectDefinition> rotatingEffects(String actionId) =>
      List.unmodifiable(_rotatingHits[actionId] ?? const []);
  void finishAction(String actionId) {
    _tagDice.remove(actionId);
    _tagHits.remove(actionId);
    _rotatingHits.remove(actionId);
  }

  bool suppressed(
    CharacterInstance actor,
    CardInstance card,
  ) => actor.traits.any(
    (t) =>
        card.definition.tags.any(t.definition.suppressedCardTags.contains) ||
        (t.definition.suppressedCardMinTags != null &&
            card.definition.tags.length >= t.definition.suppressedCardMinTags!),
  );

  CardInstance effectiveCard(
    CharacterInstance actor,
    CardInstance card, {
    Set<String> blockedTags = const {},
  }) {
    if (!suppressed(actor, card) &&
        !card.definition.tags.any(blockedTags.contains)) {
      return card;
    }
    final d = card.definition;
    return CardInstance(
      card.instanceId,
      CardDefinition(
        id: d.id,
        mpCost: d.mpCost,
        actionCostBonus: d.actionCostBonus,
        attacks: d.attacks,
        isLimited: d.isLimited,
        attacksWithCardIds: d.attacksWithCardIds,
        tags: d.tags,
      ),
    );
  }

  List<(RotatingCardEffects, int)> _rotationRules(CharacterInstance actor) {
    if (host.traitsBlocked(actor)) return [];
    final result = <(RotatingCardEffects, int)>[];
    for (final trait in actor.traits) {
      final rule = trait.definition.mechanisms.get<RotatingCardEffects>();
      if (rule == null) continue;
      if (host.previewMode) {
        throw const PreviewBoundary('unprojectedRotationHistory');
      }
      result.add((
        rule,
        (host.variableCell(rule.variable, actor).value as num).toInt() %
            rule.entries.length,
      ));
    }
    return result;
  }

  List<CardInstance> project(
    CharacterInstance actor,
    List<CardInstance> cards,
  ) {
    if (cards.isEmpty) return cards;
    final tags = <String>{};
    for (final (rule, cursor) in _rotationRules(actor)) {
      final count = cards.length < rule.suppressFirst
          ? cards.length
          : rule.suppressFirst;
      for (var i = 0; i < count; i++) {
        tags.addAll(
          rule.entries[(cursor + i) % rule.entries.length].suppressedTags,
        );
      }
    }
    return cards
        .map((card) => effectiveCard(actor, card, blockedTags: tags))
        .toList();
  }

  List<CardInstance> assemble(
    CharacterInstance actor,
    String actionId,
    List<CardInstance> cards,
  ) {
    final originals = [
      for (final card in cards) host.physicalCard(actor, card),
    ];
    final projected = project(actor, originals);
    if (cards.isEmpty) return projected;
    for (final (rule, cursor) in _rotationRules(actor)) {
      final effects = <EffectDefinition>[];
      for (var i = 0; i < cards.length; i++) {
        final entry = (cursor + i) % rule.entries.length;
        effects.addAll(rule.entries[entry].effects);
        for (final armed in actor.armedAttacks) {
          if (i < armed.rule.rotationTake) {
            effects.addAll(armed.rule.rotationBonus[entry] ?? const []);
          }
        }
      }
      _rotatingHits.putIfAbsent(actionId, () => []).addAll(effects);
      host.modifyVariable(
        actor,
        actor,
        ModifyVariable(
          rule.variable,
          operation: VariableOperation.assign,
          input: VariableInput(
            literal: (cursor + cards.length) % rule.entries.length,
          ),
        ),
      );
      host.emit('attackEffectsRotated', {
        'actorId': actor.instanceId,
        'count': cards.length,
      });
    }
    return projected;
  }

  void checkLife(CharacterInstance actor) {
    if (!actor.alive || host.traitsBlocked(actor)) return;
    for (final t in actor.traits) {
      final rule = t.definition.mechanisms.get<LifeThresholdRule>();
      if (rule == null || actor.hp >= rule.below) continue;
      if (host.previewMode) {
        throw const PreviewBoundary('unprojectedLifeThresholdHistory');
      }
      final cell = host.variableCell(rule.variable, actor);
      if ((cell.value as num) != 0) continue;
      host.modifyVariable(
        actor,
        actor,
        ModifyVariable(
          rule.variable,
          operation: VariableOperation.assign,
          input: const VariableInput(literal: 1),
        ),
      );
      host.effects(actor, const [], rule.effects);
      host.emit('lifeThresholdActivated', {
        'actorId': actor.instanceId,
        'threshold': rule.below,
        'traitId': t.definition.id,
      });
    }
  }

  void runCardRules(
    CharacterInstance actor,
    List<String> targets,
    CardInstance card,
    List<CardInstance> group,
    String? actionId,
    void Function() complete,
  ) {
    if (!actor.alive || host.traitsBlocked(actor)) {
      complete();
      return;
    }
    final steps = <void Function()>[];
    for (final t in actor.traits) {
      final life = t.definition.mechanisms.get<CardLifeRule>();
      if (life != null) {
        steps.add(() {
          if (!actor.alive) return;
          final high = actor.hp >= life.threshold;
          if (!card.definition.tags.any(
            (high ? life.highTags : life.lowTags).contains,
          )) {
            return;
          }
          final effects = high ? life.highEffects : life.lowEffects;
          if (!high && life.lowOptional) {
            host.choose(
              actor,
              [
                {'action': 'accept'},
                {'action': 'skip'},
              ],
              (o) {
                if (o['action'] == 'accept') {
                  host.runAbility(actor, targets, effects, () {});
                }
              },
            );
          } else {
            host.runAbility(actor, targets, effects, () {});
          }
        });
      }
      final rewards = t.definition.mechanisms.get<TagRewards>();
      if (rewards != null) {
        final boost =
            group.fold<int>(0, (n, c) => n + c.definition.tags.length) >=
            rewards.threshold;
        final table = boost
            ? {...rewards.effects, ...rewards.boostedEffects}
            : rewards.effects;
        for (final tag in card.definition.tags) {
          for (final effect in table[tag] ?? const <EffectDefinition>[]) {
            steps.add(() {
              if (!actor.alive) return;
              if (effect is ModifyActionDice) {
                if (actionId != null) {
                  _tagDice.update(
                    actionId,
                    (n) => n + effect.amount,
                    ifAbsent: () => effect.amount,
                  );
                }
              } else if (effect is DamageEffect && actionId != null) {
                _tagHits.putIfAbsent(actionId, () => []).add(effect);
              } else {
                host.runAbility(
                  actor,
                  targets,
                  [effect],
                  () {},
                  independentDamage: effect is DamageEffect,
                );
              }
            });
          }
        }
      }
    }
    host.sequence([...steps, complete]);
  }
}
