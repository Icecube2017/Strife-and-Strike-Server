import 'dart:math';

import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/development/ai/policies.dart';
import 'package:sns_server/development/search/public_world.dart';

/// Limits apply between atomic kernel calls; the Python owner also enforces a
/// hard process timeout in case a single kernel call does not return.
final class SearchLimits {
  const SearchLimits({
    this.depth = 6,
    this.decisions = 24,
    this.turns = 2,
    this.milliseconds = 1500,
    this.cards = 3,
  });
  final int depth;
  final int decisions;
  final int turns;
  final int milliseconds;
  final int cards;

  void validate() {
    if (depth < 1 ||
        depth > 12 ||
        decisions < 1 ||
        decisions > 64 ||
        turns < 1 ||
        turns > 4 ||
        milliseconds < 1 ||
        milliseconds > 5000 ||
        cards < 1 ||
        cards > 4) {
      throw ArgumentError('Search limits exceed bounded search contract');
    }
  }

  Map<String, int> toJson() => {
    'maxCommands': depth,
    'maxDecisions': decisions,
    'maxTurnAdvances': turns,
    'maxMilliseconds': milliseconds,
    'maxSelectedCards': cards,
  };
}

final class SearchDeadline implements Exception {
  const SearchDeadline();
}

final class BranchResult {
  BranchResult({
    required this.game,
    required this.commands,
    required this.decisions,
    required this.turnAdvances,
    required this.reason,
    required this.rootResolved,
    required this.value,
    required this.leafValue,
    required this.effects,
  });
  final GameKernel game;
  final int commands;
  final int decisions;
  final int turnAdvances;
  final String reason;
  final bool rootResolved;
  final double value;
  final double leafValue;
  final Map<String, double> effects;
}

/// The evaluator is passed in to keep the mechanics driver independent of its
/// heuristic. Each invocation returns a value and visible utility components.
typedef BranchAssessment = ({double value, Map<String, double> components});

BranchResult boundedRollout({
  required PublicSearchWorld world,
  required Map<String, dynamic> candidate,
  required Random random,
  required SearchLimits limits,
  required bool Function() expired,
  required BranchAssessment Function(GameKernel) assess,
}) {
  void checkTime() {
    if (expired()) throw const SearchDeadline();
  }

  checkTime();
  final game = world.sample(random);
  final before = assess(game);
  var current = before;
  BranchAssessment? resolved;
  final initialTurn = game.state.actualTurn;
  var commands = 0;
  var decisions = 1;
  var accumulated = 0.0;
  var weight = 1.0;
  final prefix = <String>[];
  var mustCommitCards = false;
  bool stable() =>
      game.state.pending == null &&
      game.state.choice == null &&
      game.state.preparation == null;
  void submit(KernelCommand command) {
    checkTime();
    game.submit(command);
    commands++;
    current = assess(game);
    accumulated += weight * .05 * current.value;
    weight *= .95;
    if (resolved == null && stable()) resolved = current;
    checkTime();
  }

  final command = searchMap(candidate['command']);
  if (command.isNotEmpty) {
    submit(KernelRecoveryCodec.readCommand(command));
  } else {
    final f = searchMap(candidate['features']);
    prefix.addAll((f['selectedCardIds'] as List? ?? []).cast<String>());
    switch (candidate['kind']) {
      case 'selectCard':
        prefix.add(f['cardInstanceId'] as String);
        mustCommitCards = true;
      case 'unselectCard':
        if (prefix.isEmpty) throw StateError('emptyCardPrefix');
        prefix.removeLast();
        mustCommitCards = prefix.isNotEmpty;
      case 'cancelCardSelection':
        prefix.clear();
      default:
        throw StateError('unsupportedRootAdapter');
    }
    if (prefix.length > limits.cards ||
        prefix.toSet().length != prefix.length) {
      throw StateError('cardPrefixBeyondSearchLimit');
    }
  }
  final policy = AiRulePolicy(random.nextInt(1 << 30));
  var version = game.state.version;
  var reason = 'decisionLimit';
  while (!game.state.finished) {
    checkTime();
    if (commands >= limits.depth) {
      reason = 'depthLimit';
      break;
    }
    if (game.state.actualTurn - initialTurn >= limits.turns) {
      reason = 'turnLimit';
      break;
    }
    if (decisions >= limits.decisions) break;
    if (version != game.state.version) {
      version = game.state.version;
      prefix.clear();
    }
    final decision = game.aiDecision(
      cardPrefix: prefix,
      allowCardEdits: false,
      maximumProposals: 2048,
    );
    if (decision == null) {
      reason = 'noDecision';
      break;
    }
    var options = decision.candidates
        .where(
          (c) =>
              c.kind != 'unselectCard' &&
              c.kind != 'cancelCardSelection' &&
              (c.kind != 'selectCard' || prefix.length < limits.cards),
        )
        .toList();
    if (mustCommitCards) {
      options = options
          .where((c) => c.kind == 'selectCard' || c.kind == 'playCards')
          .toList();
    }
    if (options.isEmpty) {
      reason = 'noBoundedCardContinuation';
      break;
    }
    final bounded = AiDecision(
      decisionId: decision.decisionId,
      gameVersion: decision.gameVersion,
      actorId: decision.actorId,
      phase: decision.phase,
      observation: decision.observation,
      candidates: options,
    );
    final choice = options[policy.select(bounded).index];
    decisions++;
    if (choice.kind == 'selectCard') {
      prefix.add(choice.features['cardInstanceId']! as String);
    } else if (choice.command != null) {
      submit(choice.command!);
      mustCommitCards = false;
    } else {
      reason = 'noCommand';
      break;
    }
  }
  if (game.state.finished) reason = 'terminal';
  if (game.state.actualTurn - initialTurn > limits.turns) {
    throw StateError('atomicTurnAdvanceBeyondSearchLimit');
  }
  return BranchResult(
    game: game,
    commands: commands,
    decisions: decisions,
    turnAdvances: game.state.actualTurn - initialTurn,
    reason: reason,
    rootResolved: resolved != null,
    value: game.state.finished
        ? current.value
        : accumulated + weight * current.value,
    leafValue: current.value,
    effects: resolved == null
        ? {}
        : {
            for (final key in before.components.keys)
              key: resolved!.components[key]! - before.components[key]!,
          },
  );
}
