import 'dart:convert';
import 'dart:io';

import 'package:sns_server/development/ai/ai.dart';
import 'package:sns_server/development/ai/io.dart';

void main(List<String> arguments) {
  try {
    _main(arguments);
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}

void _main(List<String> arguments) {
  if (arguments.isEmpty || arguments.contains('--help')) {
    stdout.writeln(
      '''
Offline AI lab (no database, HTTP, Flutter or training dependencies)
  dart run bin/ai_lab.dart scenarios
  dart run bin/ai_lab.dart smoke --games 1000 --paired --out ai/runs/smoke
  dart run bin/ai_lab.dart benchmark --games 20
  dart run bin/ai_lab.dart freeze --out ai/runs/bootstrap-001
  dart run bin/ai_lab.dart replay --case <failure.json> --content <frozen-content.json>
Options: --scenarios ai/scenarios/full-match --content content/content_items.json
         --seed 7 --policy rules|random --opponent rules|random --max-decisions 10000
The run output may contain private fixture data; it is for offline development.''',
    );
    return;
  }
  final options = <String, String>{};
  for (var i = 1; i < arguments.length; i++) {
    final key = arguments[i];
    if (!key.startsWith('--')) {
      throw FormatException('Unexpected argument: $key');
    }
    options[key.substring(
      2,
    )] = i + 1 < arguments.length && !arguments[i + 1].startsWith('--')
        ? arguments[++i]
        : 'true';
  }
  String option(String key, String fallback) => options[key] ?? fallback;
  const supported = {
    'out',
    'baseline',
    'content',
    'scenarios',
    'case',
    'games',
    'seed',
    'policy',
    'opponent',
    'max-decisions',
    'paired',
    'trace',
  };
  if (options.keys.any((key) => !supported.contains(key))) {
    throw const FormatException('Unsupported AI lab option');
  }
  final content = option('content', 'content/content_items.json');
  final output = options['out'];
  if (arguments.first == 'freeze') {
    if (output == null) throw const FormatException('freeze requires --out');
    freezeAiRun(
      output,
      content,
      option('baseline', '.dart_tool/ai-baseline-20261029.jsonl'),
    );
    stdout.writeln('Frozen offline experiment: $output');
    return;
  }
  if (arguments.first == 'replay') {
    final file = options['case'];
    if (file == null) throw const FormatException('replay requires --case');
    final saved = readAiJson(file);
    final scenario = AiScenario.parse(
      Map<String, dynamic>.from(saved['scenario'] as Map),
      readAiJson(content),
    );
    final arena = AiArena.restore(
      scenario,
      Map<String, dynamic>.from((saved['arena'] ?? saved['kernel']) as Map),
    );
    stdout.writeln(
      jsonEncode({'restored': true, 'decision': arena.decision()?.toJson()}),
    );
    return;
  }
  final scenarios = loadAiScenarios(
    option('scenarios', 'ai/scenarios/full-match'),
    content,
  );
  if (arguments.first == 'scenarios') {
    stdout.writeln(
      jsonEncode([
        for (final s in scenarios)
          {
            'id': s.id,
            'players': s.setup.players.length,
            'initialVersion': s.create().state.version,
          },
      ]),
    );
    return;
  }
  if (!const ['smoke', 'benchmark'].contains(arguments.first)) {
    throw FormatException('Unknown AI lab command: ${arguments.first}');
  }
  final games = int.parse(option('games', '20'));
  final seed = int.parse(option('seed', '7'));
  final maximum = int.parse(option('max-decisions', '10000'));
  if (games < 1 || maximum < 1) {
    throw const FormatException('games and max-decisions must be positive');
  }
  final paired = options['paired'] == 'true';
  if (paired && games.isOdd) {
    throw const FormatException('--paired requires an even game count');
  }
  AiPolicy policy(String name, int seed) => switch (name) {
    'rules' => AiRulePolicy(seed),
    'random' => AiRandomPolicy(seed),
    _ => throw FormatException('Unknown policy $name'),
  };
  final results = <Map<String, Object?>>[];
  final samples = <int>[];
  final timer = Stopwatch()..start();
  for (var n = 0; n < games; n++) {
    final group = paired ? n ~/ 2 : n;
    var scenario = scenarios[group % scenarios.length];
    if (paired && n.isOdd) scenario = scenario.reverseSeats();
    final episodeSeed = seed + group;
    final arena = AiArena(
      scenario,
      seed: episodeSeed,
      maximumDecisions: maximum,
    );
    final playerIds = scenario.setup.players.map((p) => p.id).toList()..sort();
    final firstTeam = scenario.setup.players
        .singleWhere((p) => p.id == playerIds.first)
        .teamId;
    final result = arena.run({
      for (final p in arena.game.state.players)
        p.id: policy(
          p.teamId == firstTeam
              ? option('policy', 'rules')
              : option('opponent', 'random'),
          episodeSeed * 31 + p.id.codeUnits.fold(0, (a, b) => a + b),
        ),
    }, trace: options['trace'] == 'true');
    result['seed'] = episodeSeed;
    result['primaryTeamId'] = firstTeam;
    result['seatOrder'] = scenario.setup.players.map((p) => p.id).toList();
    results.add(result);
    samples.addAll(arena.decisionMicroseconds);
    if (output != null && result['truncated'] == true) {
      writeAiJson('$output/failures/game-$n.json', arena.failureCase());
    }
    if ((n + 1) % 100 == 0) stderr.writeln('AI lab: ${n + 1}/$games episodes');
  }
  timer.stop();
  samples.sort();
  final commands = results.fold<int>(
    0,
    (n, r) => n + (r['kernelCommands']! as int),
  );
  final decisions = results.fold<int>(
    0,
    (n, r) => n + (r['decisions']! as int),
  );
  final commandKinds = <String, int>{};
  for (final r in results) {
    for (final entry in (r['commandKinds']! as Map<String, int>).entries) {
      commandKinds.update(
        entry.key,
        (value) => value + entry.value,
        ifAbsent: () => entry.value,
      );
    }
  }
  final report = <String, Object?>{
    'reportVersion': 1,
    'games': games,
    'paired': paired,
    'completed': results.where((r) => r['terminated'] == true).length,
    'truncated': results.where((r) => r['truncated'] == true).length,
    'technicalFailures': results
        .where((r) => r['reason'] == 'technicalFailure')
        .length,
    'primaryPolicy': option('policy', 'rules'),
    'opponentPolicy': option('opponent', 'random'),
    'primaryWins': results
        .where(
          (r) =>
              r['terminated'] == true &&
              (r['outcome'] as Map?)?['winnerTeamId'] == r['primaryTeamId'],
        )
        .length,
    'opponentWins': results
        .where(
          (r) =>
              r['terminated'] == true &&
              (r['outcome'] as Map?)?['draw'] != true &&
              (r['outcome'] as Map?)?['winnerTeamId'] != r['primaryTeamId'],
        )
        .length,
    'draws': results
        .where((r) => (r['outcome'] as Map?)?['draw'] == true)
        .length,
    'averageDecisions': decisions / games,
    'maximumDecisions': results
        .map((r) => r['decisions']! as int)
        .reduce((a, b) => a > b ? a : b),
    'kernelCommands': commands,
    'commandKinds': commandKinds,
    'decisions': decisions,
    'elapsedSeconds': timer.elapsedMicroseconds / 1000000,
    'kernelCommandsPerSecond': commands * 1000000 / timer.elapsedMicroseconds,
    'decisionsPerSecond': decisions * 1000000 / timer.elapsedMicroseconds,
    'candidateGenerationP50Microseconds': samples.isEmpty
        ? null
        : samples[samples.length ~/ 2],
    'candidateGenerationP95Microseconds': samples.isEmpty
        ? null
        : samples[(samples.length * .95).floor().clamp(0, samples.length - 1)],
    'scenarios': scenarios.map((s) => s.id).toList(),
    'episodes': results,
  };
  if (output != null) writeAiJson('$output/report.json', report);
  stdout.writeln(jsonEncode({...report}..remove('episodes')));
  if (report['truncated'] != 0) exitCode = 1;
}
