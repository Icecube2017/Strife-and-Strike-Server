import 'dart:math';

import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/development/search/bounded_rollout.dart';
import 'package:sns_server/development/search/public_world.dart';

/// Depth-one information-set UCT with bounded rule-policy rollouts. This is an
/// experimental search adviser, not a full ISMCTS or a PPO training algorithm.
final class ShallowPublicSearch {
  ShallowPublicSearch(this.world);
  final PublicSearchWorld world;

  Map<String, Object?> run({
    required List<Map<String, dynamic>> candidates,
    required List<double> priors,
    int simulations = 32,
    int horizon = 24,
    int maxDepth = 6,
    int maxTurnAdvances = 2,
    int maxMilliseconds = 1500,
    int maxSelectedCards = 3,
    int seed = 1,
  }) {
    final limits = SearchLimits(
      depth: maxDepth,
      decisions: horizon,
      turns: maxTurnAdvances,
      milliseconds: maxMilliseconds,
      cards: maxSelectedCards,
    )..validate();
    if (simulations < 1 ||
        simulations > 256 ||
        candidates.length != priors.length) {
      throw ArgumentError('Invalid search budget, horizon or prior shape');
    }
    final timer = Stopwatch()..start();
    final roots = <_Root>[];
    final skipped = <Map<String, Object?>>[];
    final rootSkills = {
      for (final s in searchRows(world.private['skills']))
        s['instanceId']: world.catalog.skills[s['definitionId']],
    };
    final rootTraits = {
      for (final t in searchRows(world.private['traitActions']))
        t['instanceId']: world.catalog.traits[t['definitionId']],
    };
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      final command = searchMap(c['command']);
      var supported = const {
        'attack',
        'endTurn',
        'useSkill',
        'playCards',
        'activateStatus',
      }.contains(command['type']);
      final adapter =
          const {
            'selectCard',
            'unselectCard',
            'cancelCardSelection',
          }.contains(c['kind']) &&
          command.isEmpty;
      if (command['type'] == 'useSkill') {
        supported =
            rootSkills[command['skillInstanceId']]?.mechanism ==
            SkillMechanism.ordinary;
      }
      if (command['type'] == 'activateTrait') {
        final t = rootTraits[command['traitInstanceId']];
        supported = t != null && t.mechanisms.configurations.isEmpty;
      }
      if (supported || adapter) {
        if ((!adapter && command['playerId'] != world.viewer) ||
            !priors[i].isFinite ||
            priors[i] < 0) {
          throw ArgumentError('Invalid root actor or prior');
        }
        roots.add(_Root(i, c, priors[i]));
      } else {
        skipped.add({
          'index': i,
          'kind': c['kind'],
          'reason': 'unsupportedActionOrHistory',
        });
      }
    }
    if (roots.isEmpty || roots.length > 32 || simulations < roots.length) {
      throw StateError('rootCoverageBudgetInsufficient');
    }
    final failures = <String, int>{};
    final stops = <String, int>{};
    var timeExceeded = false;
    var maxObservedDepth = 0;
    var maxObservedDecisions = 0;
    var maxObservedTurns = 0;
    for (var iteration = 0; iteration < simulations; iteration++) {
      if (timer.elapsedMilliseconds >= limits.milliseconds) {
        timeExceeded = true;
        break;
      }
      final root =
          roots.where((r) => r.visits == 0).firstOrNull ??
          roots.reduce(
            (a, b) => _priority(a, iteration + 1) >= _priority(b, iteration + 1)
                ? a
                : b,
          );
      root.visits++;
      try {
        final result = boundedRollout(
          world: world,
          candidate: root.candidate,
          // Paired hidden-world seeds reduce noise between different roots.
          // A root's Nth visit uses the same initial world as other Nth visits.
          random: Random(seed + root.visits * 104729),
          limits: limits,
          expired: () => timer.elapsedMilliseconds >= limits.milliseconds,
          assess: (g) {
            final a = publicSearchAssessment(g, world.viewer);
            return (value: a.value, components: a.components);
          },
        );
        final value = result.value;
        maxObservedDepth = max(maxObservedDepth, result.commands);
        maxObservedDecisions = max(maxObservedDecisions, result.decisions);
        maxObservedTurns = max(maxObservedTurns, result.turnAdvances);
        stops.update(result.reason, (n) => n + 1, ifAbsent: () => 1);
        root
          ..successes += 1
          ..total += value
          ..square += value * value
          ..leafTotal += result.leafValue;
        if (result.rootResolved) {
          root.resolved++;
          for (final entry in result.effects.entries) {
            root.effects.update(
              entry.key,
              (v) => v + entry.value,
              ifAbsent: () => entry.value,
            );
          }
        }
        if (result.game.state.finished) root.terminals++;
      } on SearchDeadline {
        timeExceeded = true;
        break;
      } catch (error) {
        final key = '$error';
        failures.update(key, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    // A failed branch might be the best branch. Never select an alternative
    // merely because its simulations were easier to project.
    final available =
        failures.isEmpty &&
        !timeExceeded &&
        roots.every((r) => r.successes > 0 && r.resolved > 0);
    final sorted = [...roots]..sort((a, b) => b.mean.compareTo(a.mean));
    timer.stop();
    return {
      'searchVersion': 'public-root-uct-v2',
      'available': available,
      'reason': available
          ? null
          : timeExceeded
          ? 'timeBudgetExceeded'
          : 'rootSimulationCoverageFailed',
      if (available) 'candidateIndex': sorted.first.index,
      'simulations': simulations,
      'performedSimulations': roots.fold<int>(0, (n, r) => n + r.visits),
      'successfulSimulations': roots.fold<int>(0, (n, r) => n + r.successes),
      'horizonDecisions': horizon,
      'limits': limits.toJson(),
      'maxObservedCommands': maxObservedDepth,
      'maxObservedDecisions': maxObservedDecisions,
      'maxObservedTurnAdvances': maxObservedTurns,
      'stopReasons': stops,
      'utilityDiscountPerCommand': .95,
      'determinizationSchedule': 'common-seed-per-root-visit',
      'elapsedMicroseconds': timer.elapsedMicroseconds,
      'searchedRootCount': roots.length,
      'totalRootCandidates': candidates.length,
      'recommendationScope': 'supportedRootSubset',
      'coveredPriorMass': roots.fold<double>(0, (n, r) => n + r.prior),
      'trainingConcerns': world.trainingConcerns,
      'skipped': skipped,
      'failures': failures,
      'limitations': [
        ...world.limitations,
        'rootOnlyTreeWithRuleRollouts',
        'noOutOfTurnOpportunitySearch',
        'heuristicLeafValueNotWinProbability',
        'cardCombinationsUseBoundedRuleContinuation',
        'specialTraitModulesNotProjected',
        'otherStatusEffectsNeedRealizedRolloutOrHaveNoDirectValue',
      ],
      'roots': [
        for (final r in sorted)
          {
            'candidateIndex': r.index,
            'command': r.command,
            'kind': r.candidate['kind'],
            'prior': r.prior,
            'visits': r.visits,
            'successful': r.successes,
            'terminalRollouts': r.terminals,
            'meanValue': r.successes == 0 ? null : r.mean,
            'meanLeafValue': r.successes == 0
                ? null
                : r.leafTotal / r.successes,
            'rootEffectsResolved': r.resolved,
            'meanResolvedRootEffect': {
              for (final e in r.effects.entries) e.key: e.value / r.resolved,
            },
            'standardError': r.successes < 2
                ? null
                : sqrt(
                    max(0, r.square / r.successes - r.mean * r.mean) /
                        r.successes,
                  ),
          },
      ],
    };
  }

  double _priority(_Root r, int total) =>
      r.mean +
      .6 * sqrt(log(total + 1) / r.visits) +
      .3 * r.prior * sqrt(total) / (1 + r.visits);
}

final class _Root {
  _Root(this.index, this.candidate, this.prior);
  final int index;
  final Map<String, dynamic> candidate;
  Map<String, dynamic> get command => searchMap(candidate['command']);
  final double prior;
  int visits = 0;
  int successes = 0;
  int terminals = 0;
  int resolved = 0;
  double total = 0;
  double square = 0;
  double leafTotal = 0;
  final effects = <String, double>{};
  double get mean => successes == 0 ? 0 : total / successes;
}

/// Visible material, resources and generic capability locks. No skill IDs,
/// private statistics, opponent cards or real future RNG are consulted.
final class SearchAssessment {
  const SearchAssessment(this.value, this.components);
  final double value;
  final Map<String, double> components;
}

double publicSearchValue(GameKernel game, String viewer) =>
    publicSearchAssessment(game, viewer).value;

SearchAssessment publicSearchAssessment(GameKernel game, String viewer) {
  final public = game.aiObservation(viewer)['public']! as Map;
  final players = searchRows(public['players']);
  final own = players.singleWhere((p) => p['playerId'] == viewer);
  final outcome = searchMap(public['outcome']);
  Map<String, double> material(Map<String, dynamic> p) {
    final result = <String, double>{
      'survival': 0,
      'health': 0,
      'resources': 0,
      'protection': 0,
      'statEnhancement': 0,
      'control': 0,
    };
    if (p['alive'] != true) return result;
    final hp = searchInt(p['hp']) / max(1, searchInt(p['maxHp'], 1));
    final mp = searchInt(p['mp']) / max(1, searchInt(p['maxMp'], 1));
    final flags = <String>{};
    for (final s in searchRows(p['statuses'])) {
      final d = game.catalog.statuses[s['definitionId']];
      if (d == null) continue;
      if (d.skipTurn) flags.addAll(['attack', 'cards', 'skills', 'draw', 'mp']);
      if (d.blockAttack) flags.add('attack');
      if (d.blockCards) flags.add('cards');
      if (d.blockSkills) flags.add('skills');
      if (d.blockTraits) flags.add('traits');
      if (d.blockDraw || d.blockDrawPhase) flags.add('draw');
      if (d.blockMpRegen) flags.add('mp');
    }
    final lock = flags.fold<double>(
      0,
      (n, f) =>
          n +
          switch (f) {
            'attack' || 'cards' => .12,
            'skills' => .1,
            'traits' => .04,
            _ => .06,
          },
    );
    final character = game.catalog.characters[p['definitionId']]!;
    final template = game.catalog.templates[character.templateId]!;
    final race = game.catalog.races[character.raceId]!;
    double relative(String stat, int base) =>
        ((searchInt(p[stat]) - base) / max(1, base)).clamp(-1, 1);
    result['survival'] = .5;
    result['health'] = .5 * hp.clamp(0, 1);
    result['resources'] =
        .08 * mp.clamp(0, 1) +
        .04 * (searchInt(p['handCount']) / 6).clamp(0, 1);
    result['protection'] =
        .08 *
        (searchInt(p['shield']) / max(1, searchInt(p['maxHp'], 1))).clamp(
          0,
          1,
        );
    result['statEnhancement'] =
        .06 * relative('attack', template.attack) +
        .04 * relative('defense', template.defense) +
        .04 * relative('maxHp', template.hp) +
        .02 * relative('maxMp', race.maxMp);
    result['control'] = -lock;
    return result;
  }

  final allies = players.where((p) => p['teamId'] == own['teamId']).toList();
  final enemies = players.where((p) => p['teamId'] != own['teamId']).toList();
  final a = allies.map(material).toList();
  final b = enemies.map(material).toList();
  final components = {
    for (final key in a.first.keys)
      key:
          .8 *
          (a.fold<double>(0, (n, p) => n + p[key]!) / a.length -
              b.fold<double>(0, (n, p) => n + p[key]!) / max(1, b.length)),
  };
  final value = components.values.fold<double>(0, (n, v) => n + v);
  final double finalValue;
  if (outcome.isNotEmpty) {
    finalValue = outcome['draw'] == true
        ? 0
        : outcome['winnerTeamId'] == own['teamId'] ||
              outcome['winnerPlayerId'] == viewer
        ? 1
        : -1;
  } else {
    finalValue = own['alive'] != true ? -1 : value.clamp(-.95, .95);
  }
  return SearchAssessment(finalValue, components);
}
