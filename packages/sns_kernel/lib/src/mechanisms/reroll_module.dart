import 'package:sns_kernel/src/dice.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class RerollHost implements MechanismChoiceHost {
  Iterable<PlayerInstance> get players;
  int get round;
  bool get previewMode;
  void payMp(CharacterInstance actor, int amount);
  RollResult trackRoll(RollResult result);
  void rollResult(
    CharacterInstance actor,
    int sides,
    int count,
    void Function(RollResult) complete, {
    RollResult Function()? generate,
    bool damageRoll,
    RollContext? context,
  });
}

final class RerollModule {
  RerollModule(this.host);
  final RerollHost host;
  final Set<TraitInstance> _rerollingTraits = {};
  void offer(
    CharacterInstance roller,
    int sides,
    int count,
    RollResult original,
    void Function(RollResult) complete, {
    RollResult Function()? generate,
    bool damageRoll = false,
    bool locked = false,
  }) {
    if (locked) {
      complete(original);
      return;
    }
    if (host.previewMode) {
      if (host.players.any(
        (p) =>
            p.character.traits.any((t) => t.definition.rerollOfferCost != null),
      )) {
        throw const PreviewBoundary('rerollChoiceRequired');
      }
      complete(original);
      return;
    }
    final offers = <(CharacterInstance, TraitInstance)>[
      for (final player in host.players)
        for (final trait in player.character.traits)
          if (player.character.alive &&
              !host.traitsBlocked(player.character) &&
              trait.definition.rerollOfferCost != null &&
              !_rerollingTraits.contains(trait) &&
              (trait.activeRound != host.round || trait.activeUses == 0) &&
              (player.character.noMp ||
                  player.character.mp >= trait.definition.rerollOfferCost!))
            (player.character, trait),
    ];
    void next(int index, RollResult result) {
      if (index == offers.length) {
        complete(result);
        return;
      }
      final (holder, trait) = offers[index];
      if (!holder.alive ||
          host.traitsBlocked(holder) ||
          (trait.activeRound == host.round && trait.activeUses > 0)) {
        next(index + 1, result);
        return;
      }
      host.choose(
        holder,
        [
          {'action': 'skip', 'result': result.finalTotal},
          {
            'action': 'reroll',
            'result': result.finalTotal,
            'sides': sides,
            'count': count,
          },
        ],
        (o) {
          if (o['action'] == 'skip') {
            next(index + 1, result);
            return;
          }
          _rerollingTraits.add(trait);
          host.rollResult(
            roller,
            sides,
            count,
            (candidateResult) {
              final candidate = host.trackRoll(
                candidateResult.linked(rerollOf: result.id),
              );
              _rerollingTraits.remove(trait);
              host.choose(
                holder,
                [
                  {
                    'action': 'keep',
                    'result': result.finalTotal,
                    'candidate': candidate.finalTotal,
                  },
                  if (holder.noMp ||
                      holder.mp >= trait.definition.rerollOfferCost!)
                    {
                      'action': 'replace',
                      'result': result.finalTotal,
                      'candidate': candidate.finalTotal,
                      'mpCost': trait.definition.rerollOfferCost,
                    },
                ],
                (decision) {
                  if (decision['action'] == 'replace') {
                    host.payMp(holder, trait.definition.rerollOfferCost!);
                    trait
                      ..activeRound = host.round
                      ..activeUses = 1;
                    host.emit('diceReplaced', {
                      'actorId': holder.instanceId,
                      'targetId': roller.instanceId,
                      'before': result.finalTotal,
                      'previousRollId': result.id,
                      'rollId': candidate.id,
                      'result': candidate.finalTotal,
                    });
                    next(
                      index + 1,
                      host.trackRoll(
                        candidate.linked(
                          rerollOf: result.id,
                          replacesRollId: result.id,
                        ),
                      ),
                    );
                  } else {
                    next(index + 1, result);
                  }
                },
              );
            },
            context: result.context,
            generate: generate,
            damageRoll: damageRoll,
          );
        },
      );
    }

    next(0, original);
  }
}
