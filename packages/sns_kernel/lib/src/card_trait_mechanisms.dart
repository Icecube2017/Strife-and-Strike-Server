part of 'engine.dart';

extension _CardTraitMechanisms on GameKernel {
  int? _skillRefundDivisor(CharacterInstance actor) =>
      _blocked(actor, (s) => s.blockTraits)
      ? null
      : actor.traits
            .map((t) => t.definition.mechanisms.get<SkillRefundRule>()?.divisor)
            .whereType<int>()
            .firstOrNull;
  bool _negateSkills(CharacterInstance actor) =>
      _skillRefundDivisor(actor) != null;

  void _checkCardTraitRules(TraitDefinition trait) =>
      _mechanismValidator.validate(trait);

  bool _companionCard(CharacterInstance actor, CardInstance card) =>
      !_blocked(actor, (s) => s.blockTraits) &&
      card.definition.isLimited &&
      actor.traits.any(
        (t) =>
            card.definition.tags.any(t.definition.attackCompanionTags.contains),
      );

  bool _tagNeedsTarget(CharacterInstance actor, List<CardInstance> cards) =>
      !_blocked(actor, (s) => s.blockTraits) &&
      actor.traits.any((t) {
        final r = t.definition.mechanisms.get<TagRewards>();
        if (r == null) return false;
        return cards.any(
          (c) => c.definition.tags.any(
            (tag) => [
              ...?r.effects[tag],
              ...?r.boostedEffects[tag],
            ].any((e) => e.target == EffectTarget.selected),
          ),
        );
      });

  bool _enemy(CharacterInstance a, CharacterInstance b) =>
      state.players.firstWhere((p) => p.character == a).teamId !=
      state.players.firstWhere((p) => p.character == b).teamId;

  void _negativeMpCrossed(
    CharacterInstance source,
    CharacterInstance target,
    int previous,
  ) {
    if (previous >= 0 && target.mp < 0) {
      _event('negativeMpEntered', {
        'sourceId': source.instanceId,
        'targetId': target.instanceId,
      });
    }
  }

  void _clearProtection(
    CharacterInstance actor,
    CharacterInstance target,
    ClearProtection rule,
  ) {
    if (rule.shield) {
      final amount = target.shield;
      _performance.shieldRemoved(actor, target, amount);
      target.shield = 0;
      if (amount > 0) {
        _performance.otherEffect(
          actor,
          target,
          positive: false,
          kind: 'shield',
        );
        _event('shieldCleared', {
          'actorId': actor.instanceId,
          'targetId': target.instanceId,
          'amount': amount,
        });
      }
    }
    for (final status in target.statuses.toList()) {
      if ((rule.dodge && status.definition.dodge) ||
          (rule.positive && !status.definition.negative)) {
        _consumeStatus(
          target,
          status,
          amount: status.stacks,
          statisticsSource: actor,
        );
      }
    }
  }
}
