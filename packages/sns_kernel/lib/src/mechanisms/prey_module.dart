import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/state.dart';

/// Capabilities provided by the kernel. No RNG, damage or death submission.
abstract interface class PreyHost {
  bool get previewMode;
  bool traitsBlocked(CharacterInstance actor);
  CharacterInstance character(String id);
  CardInstance effectiveCard(CharacterInstance actor, CardInstance card);
  String nextId(String prefix);
  HeldCard holdCard({
    required String id,
    required String actionId,
    required CharacterInstance owner,
    required CardInstance card,
    bool revealed,
  });
  CardInstance takeCard(HeldCard card);
  void discardCard(CardInstance card);
  void returnCard(CharacterInstance owner, CardInstance card);
  void emit(String type, Map<String, Object?> data);
  void choose(
    CharacterInstance actor,
    List<Map<String, Object?>> options,
    void Function(Map<String, Object?>) resolve,
  );
  void sequence(List<void Function()> steps);
}

final class PreyCard {
  PreyCard(this.held, this.holderId, this.rule);
  final HeldCard held;
  final String holderId;
  final PreyRule rule;
}

/// Owns custody associations and per-action adjustments for this mechanism.
/// Called at explicit declaration, response, completion and death stages.
final class PreyModule {
  PreyModule(this.host);
  final PreyHost host;
  final List<PreyCard> _preyCards = [];
  final Map<String, Set<String>> _preyActivatedCards = {};
  final Map<String, Map<String, double>> _preyFactors = {};
  List<PreyCard> get cards => List.unmodifiable(_preyCards);
  void restoreCard(HeldCard card, String holderId, PreyRule rule) {
    if (_preyCards.any(
      (p) =>
          p.held.card.instanceId == card.card.instanceId ||
          (p.held.owner == card.owner && p.holderId == holderId),
    )) {
      throw StateError('Duplicate restored prey');
    }
    _preyCards.add(PreyCard(card, holderId, rule));
  }

  bool wasActivated(String? actionId, String cardId) =>
      _preyActivatedCards[actionId]?.contains(cardId) ?? false;
  double factorFor(String actionId, String targetId) =>
      _preyFactors[actionId]?[targetId] ?? 1;
  void finishAction(String actionId) {
    _preyFactors.remove(actionId);
    _preyActivatedCards.remove(actionId);
  }

  void activate(
    CharacterInstance actor,
    List<String> targets,
    String actionId,
    List<CardInstance> cards,
  ) {
    if (targets.isEmpty || host.traitsBlocked(actor)) return;
    final prey = _preyCards
        .where((p) => p.held.owner == actor && p.holderId == targets.first)
        .firstOrNull;
    if (prey == null) return;
    _consumePrey(prey);
    cards.add(host.effectiveCard(actor, prey.held.card));
    _preyActivatedCards
        .putIfAbsent(actionId, () => {})
        .add(prey.held.card.instanceId);
    _preyFactors.putIfAbsent(actionId, () => {})[targets.first] =
        prey.rule.outgoingFactor;
    host.emit('preyActivated', {
      'actorId': actor.instanceId,
      'targetId': targets.first,
      'amount': ((prey.rule.outgoingFactor - 1) * 100).round(),
      'instanceId': prey.held.card.instanceId,
    });
  }

  void _consumePrey(PreyCard prey) {
    _preyCards.remove(prey);
    host.takeCard(prey.held);
    host.discardCard(prey.held.card);
  }

  void offerDefense(CharacterInstance actor, PendingResolution pending) {
    final steps = <void Function()>[];
    for (final id in pending.targets) {
      final target = host.character(id);
      final prey = _preyCards
          .where(
            (p) => p.held.owner == target && p.holderId == actor.instanceId,
          )
          .firstOrNull;
      if (prey == null || !target.alive || host.traitsBlocked(target)) {
        continue;
      }
      steps.add(
        () => host.choose(
          target,
          [
            {'action': 'consumePrey'},
            {'action': 'skip'},
          ],
          (o) {
            if (o['action'] != 'consumePrey') return;
            _consumePrey(prey);
            final factors = _preyFactors.putIfAbsent(pending.id, () => {});
            factors.update(
              id,
              (n) => n * prey.rule.incomingFactor,
              ifAbsent: () => prey.rule.incomingFactor,
            );
            host.emit('preyDefended', {
              'actorId': target.instanceId,
              'targetId': actor.instanceId,
              'instanceId': prey.held.card.instanceId,
            });
          },
        ),
      );
    }
    host.sequence(steps);
  }

  void offerPlacement(CharacterInstance actor, PendingResolution pending) {
    if (!actor.alive || pending.targets.isEmpty || host.traitsBlocked(actor)) {
      return;
    }
    final rule = actor.traits
        .map((t) => t.definition.mechanisms.get<PreyRule>())
        .whereType<PreyRule>()
        .firstOrNull;
    final target = host.character(pending.targets.first);
    if (rule == null ||
        !target.alive ||
        _preyCards.any(
          (p) => p.held.owner == actor && p.holderId == target.instanceId,
        )) {
      return;
    }
    final cards = actor.hand.where((c) => !c.disabled).toList();
    if (cards.isEmpty) return;
    if (host.previewMode) {
      throw const PreviewBoundary('preyCustodyChoiceRequired');
    }
    host.choose(
      actor,
      [
        for (final c in cards)
          {
            'action': 'placePrey',
            'instanceId': c.instanceId,
            'definitionId': c.definition.id,
          },
        {'action': 'skip'},
      ],
      (o) {
        if (o['action'] == 'skip') return;
        final card = cards.singleWhere((c) => c.instanceId == o['instanceId']);
        final held = host.holdCard(
          id: host.nextId('prey'),
          actionId: host.nextId('preyCustody'),
          owner: actor,
          card: card,
          revealed: true,
        );
        _preyCards.add(PreyCard(held, target.instanceId, rule));
        host.emit('cardsLost', {
          'actorId': actor.instanceId,
          'count': 1,
          'reason': 'prey',
        });
        host.emit('preyPlaced', {
          'actorId': actor.instanceId,
          'targetId': target.instanceId,
          'instanceId': card.instanceId,
          'definitionId': card.definition.id,
        });
      },
    );
  }

  void releaseDead(CharacterInstance dead) {
    for (final prey
        in _preyCards
            .where((p) => p.held.owner == dead || p.holderId == dead.instanceId)
            .toList()) {
      _preyCards.remove(prey);
      final card = host.takeCard(prey.held);
      final owner = prey.held.owner;
      final returned =
          owner != dead &&
          owner.alive &&
          owner.hand.length < owner.value(Stat.maxHand);
      if (returned) {
        host.returnCard(owner, card);
      } else {
        host.discardCard(card);
      }
      host.emit('preyReleased', {
        'actorId': owner.instanceId,
        'targetId': dead.instanceId,
        'instanceId': card.instanceId,
        'destination': returned ? 'hand' : 'discardPile',
      });
    }
  }
}
