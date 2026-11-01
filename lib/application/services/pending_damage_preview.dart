import 'package:sns_kernel/sns_kernel.dart';

final class _BranchRequired implements Exception {
  const _BranchRequired(this.upper, {this.choice = false});
  final int upper;
  final bool choice;
}

/// Server-only settlement on replay-verified isolated kernels. Only numeric
/// damage to public characters leaves this class; no hands, choices or RNG tape.
final class PendingDamagePreview {
  /// Enrich only with the already-public declaration, never queued responses.
  /// A complete buff/heal settlement with no damage intent needs no damage card.
  static Map<String, Object?>? presentation(
    GameKernel game,
    Map<String, Object?> result,
  ) {
    final pending = game.publicView()['pending']! as Map;
    final roll = pending['diceRoll'] as Map?;
    final origin = roll?['context'] as Map?;
    final actionId = origin?['action_id'] ?? pending['actionId'];
    final cardBatch = pending['kind'] == 'dice'
        ? game.state.events
              .where(
                (event) =>
                    event.type == 'cardsPlayed' &&
                    event.data['actionId'] == actionId,
              )
              .lastOrNull
        : null;
    final declaredCards = <String>[
      for (final card in pending['cards'] as List)
        (card as Map)['definitionId'] as String,
    ];
    if (declaredCards.isEmpty && cardBatch != null) {
      for (final instance in cardBatch.data['cards']! as List) {
        final declaration = game.state.events
            .where(
              (event) =>
                  event.type == 'cardPlayed' &&
                  event.sequence > cardBatch.sequence &&
                  event.data['instanceId'] == instance,
            )
            .firstOrNull;
        if (declaration?.data['cardId'] case final String id) {
          declaredCards.add(id);
        }
      }
    }
    if (declaredCards.isEmpty &&
        origin?['purpose'] == 'card' &&
        origin?['definition_id'] is String) {
      declaredCards.add(origin!['definition_id'] as String);
    }
    final actor = game.state.players
        .where(
          (player) =>
              player.id == pending['actorId'] ||
              player.character.instanceId == pending['actorId'],
        )
        .firstOrNull;
    final attack =
        pending['kind'] == 'attack' || origin?['purpose'] == 'attack';
    final branches = result['branches']! as List;
    final damage = branches.any((raw) {
      final branch = raw as Map;
      return branch['damageObserved'] == true ||
          (branch['targets'] as Map).values.any((rawTarget) {
            final target = rawTarget as Map;
            return [
              'mainDamage',
              'attachmentDamage',
              'independentDamage',
            ].any((key) => (target[key] as int? ?? 0) > 0);
          }) ||
          (branch['steps'] as List? ?? []).any((rawStep) {
            final step = rawStep as Map;
            return step['type'] == 'damage' &&
                (step['data'] as Map?)?['kind'] != 'lifeLoss';
          });
    });
    if (result['complete'] == true && !attack && !damage) return null;
    return {
      ...result,
      'sourceAction': {
        'actionId': actionId,
        'kind': pending['kind'],
        if (actor != null) 'actorId': actor.character.instanceId,
        'targets': cardBatch?.data['targets'] ?? pending['targets'],
        if (pending['skillId'] != null) 'skillId': pending['skillId'],
        if (origin?['definition_id'] != null)
          'definitionId': origin!['definition_id'],
        if (origin?['purpose'] != null) 'purpose': origin!['purpose'],
        'cardIds': declaredCards,
      },
    };
  }

  static PreviewResult run(GameKernel source, {int maximumBranches = 16}) {
    if (maximumBranches < 1 || maximumBranches > 256) {
      throw ArgumentError.value(
        maximumBranches,
        'maximumBranches',
        'must be 1..256',
      );
    }
    final window = source.state.pending!;
    final queue = <List<int>>[[]];
    final branches = <Map<String, Object?>>[];
    final notes = <String>{};
    final assumptions = <String>{'assumesNoResponses'};
    var attempts = 0;
    while (queue.isNotEmpty &&
        branches.length < maximumBranches &&
        attempts++ < maximumBranches * 8) {
      final trace = queue.removeLast();
      var cursor = 0;
      int branch(int upper, {bool choice = false}) {
        if (upper == 1) return 0;
        if (cursor == trace.length) {
          throw _BranchRequired(upper, choice: choice);
        }
        return trace[cursor++];
      }

      final game = source.forkPendingPreview(branch);
      final start = game.state.events.length;
      var complete = true;
      try {
        for (var step = 0; step < 64; step++) {
          final pending = game.state.pending;
          if (pending != null) {
            if (pending.responseExpired && pending.waitingPlayerId != null) {
              game.submit(
                PassCommand(pending.waitingPlayerId!, pending.windowId),
              );
            } else {
              game.expireResponse(pending.windowId);
            }
            continue;
          }
          final choice = game.state.choice;
          if (choice != null) {
            // Keep the existing no-optional-response assumption explicit.
            // Mandatory public choices execute their real continuations on forks.
            final skip = choice.options
                .where(
                  (o) =>
                      o['skip'] == true ||
                      o['done'] == true ||
                      const {'skip', 'done', 'pass'}.contains(o['action']),
                )
                .firstOrNull;
            if (skip != null) {
              assumptions.add('assumesOptionalChoicesSkipped');
              game.submit(
                ChooseCommand(
                  choice.playerId,
                  choice.id,
                  skip['optionId']! as String,
                ),
              );
              continue;
            }
            if (_visibleChoice(choice)) {
              final option =
                  choice.options[branch(choice.options.length, choice: true)];
              game.submit(
                ChooseCommand(
                  choice.playerId,
                  choice.id,
                  option['optionId']! as String,
                ),
              );
              continue;
            }
          }
          final preparation = game.state.preparation;
          if (choice == null && (preparation?.ready ?? false)) {
            game.submit(
              ConfirmAbilityCommand(preparation!.playerId, preparation.id),
            );
            continue;
          }
          if (choice != null || game.state.preparation != null) {
            notes.add('interactionRequired');
            complete = false;
          }
          break;
        }
        if (game.state.pending != null ||
            game.state.choice != null ||
            game.state.preparation != null) {
          notes.add('settlementLimit');
          complete = false;
        }
        branches.add(_damage(game, start, complete: complete));
      } on _BranchRequired catch (need) {
        if (trace.length >= 48 || queue.length >= 1024) {
          notes.add(need.choice ? 'choiceBranchLimit' : 'randomBranchLimit');
          branches.add(_damage(game, start, complete: false));
        } else {
          // Large option lists must still reach damage on sampled branches.
          // Report an observed range, never claim it covers omitted outcomes.
          final count = need.upper.clamp(0, 64).clamp(0, 1024 - queue.length);
          if (count < need.upper) {
            notes.add(need.choice ? 'choiceBranchLimit' : 'randomBranchLimit');
          }
          for (var i = count - 1; i >= 0; i--) {
            queue.add([...trace, i]);
          }
        }
        // Kernel validation uses StateError for rejected branches.
        // ignore: avoid_catching_errors
      } on StateError {
        notes.add('partialSettlement');
        branches.add(_damage(game, start, complete: false));
      }
    }
    if (queue.isNotEmpty) notes.add('branchBudgetExceeded');
    return PreviewResult(
      version: source.state.version,
      mode: PreviewMode.pendingAction,
      windowId: window.windowId,
      complete: notes.isEmpty,
      branches: branches,
      assumptions: assumptions.toList(),
      limitations: notes.toList(),
    );
  }

  static bool _visibleChoice(PendingChoice choice) =>
      choice.options.isNotEmpty &&
      choice.options.every(
        (option) =>
            option['hidden'] != true &&
            option['optionId'] is String &&
            (!const {
                  ChoiceKind.takeCard,
                  ChoiceKind.discardCard,
                  ChoiceKind.returnCardToDeck,
                }.contains(choice.kind) ||
                (option['definitionId'] is String &&
                    option['instanceId'] is String &&
                    option['targetId'] is String)),
      );

  static Map<String, Object?> _damage(
    GameKernel game,
    int start, {
    required bool complete,
  }) {
    final targets = <String, Map<String, int>>{
      for (final player in game.state.players)
        player.character.instanceId: {
          'mainDamage': 0,
          'attachmentDamage': 0,
          'independentDamage': 0,
          'hpLost': 0,
          'shieldLost': 0,
          'lifeLost': 0,
          'healing': 0,
          'counterDamage': 0,
        },
    };
    for (final event in game.state.events.skip(start)) {
      if (event.type != 'damage' || event.data['kind'] == 'lifeLoss') continue;
      final target = targets[event.data['targetId']];
      if (target == null) continue;
      final component = event.data['attack'] != true
          ? 'independentDamage'
          : event.data['component'] == 'main'
          ? 'mainDamage'
          : 'attachmentDamage';
      target[component] = target[component]! + damageBeforeShield(event.data);
    }
    return {
      'targets': targets,
      'damageObserved': game.state.events
          .skip(start)
          .any((e) => e.type == 'damage' && e.data['kind'] != 'lifeLoss'),
      'damageTargetIds': {
        for (final event in game.state.events.skip(start))
          if (event.type == 'damage' && event.data['kind'] != 'lifeLoss')
            event.data['targetId'],
      }.toList(),
      'steps': <Object?>[],
      if (!complete) 'stoppedAt': 'interactionRequired',
    };
  }
}
