import 'dart:convert';
import 'dart:io';

import 'package:sns_kernel/sns_kernel.dart';
import 'package:sns_server/development/search/public_world.dart';
import 'package:sns_server/development/search/shallow_search.dart';

Map<String, Object?> runJob(
  ContentCatalog catalog,
  Map<String, dynamic> content,
  Map<String, dynamic> job,
) {
  final world = PublicSearchWorld(
    catalog,
    content,
    searchMap(job['observation']),
  );
  if (job['training'] == true && world.trainingConcerns.isNotEmpty) {
    return {
      'available': false,
      'reason': 'projectionConcerns',
      'trainingConcerns': world.trainingConcerns,
    };
  }
  return ShallowPublicSearch(world).run(
    candidates: searchRows(job['candidates']),
    priors: (job['priors'] as List).map((n) => (n as num).toDouble()).toList(),
    simulations: searchInt(job['simulations'], 32),
    horizon: searchInt(job['horizon'], 24),
    maxDepth: searchInt(job['maxDepth'], 6),
    maxTurnAdvances: searchInt(job['maxTurnAdvances'], 2),
    maxMilliseconds: searchInt(job['maxMilliseconds'], 1500),
    maxSelectedCards: searchInt(job['maxSelectedCards'], 3),
    seed: searchInt(job['seed'], 1),
  );
}

/// Independent batch probe. Never reads a server game, save or actual RNG tape.
Future<void> main(List<String> args) async {
  try {
    final i = args.indexOf('--content');
    if (i < 0 || i + 1 >= args.length) {
      throw ArgumentError('--content is required');
    }
    final raw = File(args[i + 1]).readAsStringSync();
    final content = searchMap(jsonDecode(raw));
    final catalog = ExecutableContent.decode(raw).catalog;
    if (args.contains('--jsonl')) {
      stdout.writeln(
        jsonEncode({'ready': true, 'protocol': 'search-jsonl-v1', 'pid': pid}),
      );
      await for (final line
          in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
        Object? id;
        try {
          final request = searchMap(jsonDecode(line));
          id = request['id'];
          final result = runJob(catalog, content, searchMap(request['job']));
          stdout.writeln(jsonEncode({'id': id, 'ok': true, 'result': result}));
        } catch (error) {
          stdout.writeln(
            jsonEncode({'id': id, 'ok': false, 'error': '$error'}),
          );
        }
      }
      return;
    }
    final request = searchMap(
      jsonDecode(await stdin.transform(utf8.decoder).join()),
    );
    final results = <Map<String, Object?>>[];
    for (final job in searchRows(request['jobs'])) {
      final result = runJob(catalog, content, job);
      results.add(result);
      stderr.writeln(
        'search budget=${result['simulations']} available=${result['available']} time_us=${result['elapsedMicroseconds']}',
      );
    }
    stdout.writeln(jsonEncode({'ok': true, 'results': results}));
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    stdout.writeln(jsonEncode({'ok': false, 'error': '$error'}));
    exitCode = 1;
  }
}
