import 'dart:convert';
import 'dart:io';

import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/development/ai/scenario.dart';

Map<String, dynamic> readAiJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void writeAiJson(String path, Object? value) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(value)}\n',
    );
}

List<AiScenario> loadAiScenarios(String path, String contentPath) {
  final content = readAiJson(contentPath);
  final catalog = ExecutableContent.decode(jsonEncode(content)).catalog;
  final entity = File(path);
  final files =
      entity.existsSync()
            ? [entity]
            : Directory(path)
                  .listSync()
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.json'))
                  .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) throw StateError('No AI scenarios found at $path');
  return [
    for (final f in files)
      AiScenario.parse(readAiJson(f.path), content, catalog: catalog),
  ];
}

Map<String, Object?> aiBaselineReport(String path) {
  final tests = <int, Map<String, dynamic>>{};
  final results = <Map<String, Object?>>[];
  final errors = <int, List<String>>{};
  var passed = 0;
  for (final line in File(path).readAsLinesSync()) {
    Map<String, dynamic> row;
    try {
      row = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      continue;
    }
    switch (row['type']) {
      case 'testStart':
        final test = Map<String, dynamic>.from(row['test'] as Map);
        tests[test['id']! as int] = test;
      case 'error':
        errors
            .putIfAbsent(row['testID']! as int, () => [])
            .add('${row['error']}');
      case 'testDone':
        if (row['hidden'] == true || row['skipped'] == true) continue;
        if (row['result'] == 'success') {
          passed++;
        } else {
          final id = row['testID']! as int;
          results.add({
            'name': tests[id]?['name'],
            'errors': errors[id] ?? [],
            'classification': 'preexistingRequiresRuleReview',
          });
        }
    }
  }
  return {
    'passed': passed,
    'failed': results.length,
    'failures': results,
    'trainingGate':
        'Only declared restricted scenarios; not full-content clearance.',
  };
}

void freezeAiRun(String directory, String contentPath, String baselinePath) {
  final root = Directory(directory);
  if (root.existsSync()) {
    throw StateError('Run directory already exists: $directory');
  }
  root.createSync(recursive: true);
  File(contentPath).copySync('$directory/content.json');
  for (final base in [
    'packages/sns_kernel/lib',
    'lib/development/ai',
    'bin',
    'ai/scenarios',
    'ai/src/sns_ai',
    'ai/tests',
    'ai/configs',
    'test/domain/ai',
  ]) {
    if (!Directory(base).existsSync()) continue;
    for (final f in Directory(
      base,
    ).listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') &&
          !f.path.endsWith('.json') &&
          !f.path.endsWith('.py')) {
        continue;
      }
      final target = File('$directory/source/${f.path}')
        ..parent.createSync(recursive: true);
      f.copySync(target.path);
    }
  }
  for (final name in [
    'pubspec.yaml',
    'pubspec.lock',
    'packages/sns_kernel/pubspec.yaml',
    'packages/sns_kernel/pubspec.lock',
    'analysis_options.yaml',
    'ai/coverage.json',
    'ai/README.md',
    'ai/BASELINE.md',
    'ai/pyproject.toml',
    'ai/requirements.lock.txt',
    'docs/AI_GYMNASIUM.md',
    'docs/AI_TRAINING_PLAYBOOK.md',
  ]) {
    if (File(name).existsSync()) {
      final target = File('$directory/source/$name')
        ..parent.createSync(recursive: true);
      File(name).copySync(target.path);
    }
  }
  final executable = File('$directory/source/content/content_items.json')
    ..parent.createSync(recursive: true);
  File(contentPath).copySync(executable.path);
  final content = readAiJson(contentPath);
  writeAiJson('$directory/manifest.json', {
    'experimentId': root.absolute.path.split(Platform.pathSeparator).last,
    'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
    'dartVersion': Platform.version,
    'operatingSystem': Platform.operatingSystem,
    'observationSchema': 1,
    'numericObservationSchema': 2,
    'actionSchema': 2,
    'scenarioVersion': 1,
    'kernelInteractionRulesVersion': 18,
    'rulesVersion': 'sns-ai-rules-1',
    'balanceRevision': '2026-10-29.1',
    'wikiRevision': content['wikiRevision'],
    'sourceSnapshot': 'source',
    'contentFile': 'content.json',
    'modelTrained': false,
    'productionServerTouched': false,
  });
  if (File(baselinePath).existsSync()) {
    final baseline = aiBaselineReport(baselinePath);
    writeAiJson('$directory/baseline.json', baseline);
    File('$directory/baseline.md').writeAsStringSync(
      '# Offline AI baseline\n\n'
      'Before implementation: ${baseline['passed']} passed, ${baseline['failed']} failed.\n\n'
      'All failures require rule review before full-content training. '
      'The four declared characters are enabled only in restricted smoke scenarios.\n\n'
      'See source/ai/README.md, source/ai/BASELINE.md and source/ai/coverage.json.\n'
      'Kernel and AI source snapshots are included because the working tree is uncommitted.\n',
    );
  }
}
