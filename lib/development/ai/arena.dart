import 'dart:convert';

import 'package:sns_kernel/sns_kernel.dart';

import 'package:sns_server/development/ai/policies.dart';
import 'package:sns_server/development/ai/scenario.dart';

final class AiArena {
  AiArena(this.scenario, {int seed = 1, this.maximumDecisions = 10000})
    : game = scenario.create(seed: seed) {
    _baseKernel = game.recoveryCheckpoint();
  }
  AiArena.restore(
    this.scenario,
    Map<String, dynamic> saved, {
    int? maximumDecisions,
  }) : maximumDecisions =
           maximumDecisions ?? saved['maximumDecisions'] as int? ?? 10000,
       game = GameKernel.restore(
         scenario.catalog,
         saved['arenaVersion'] == 1
             ? Map<String, dynamic>.from(saved['kernel'] as Map)
             : saved,
       ) {
    _baseKernel = saved['baseKernel'] is Map
        ? Map<String, Object?>.from(saved['baseKernel'] as Map)
        : game.recoveryCheckpoint();
    if (saved['arenaVersion'] == 1) {
      decisionCount = saved['decisionCount']! as int;
      commandCount = saved['commandCount']! as int;
      _epoch = saved['epoch']! as int;
      _idleVersion = saved['idleVersion']! as int;
      _idleIndex = saved['idleIndex']! as int;
      _idlePlayers = (saved['idlePlayers']! as List).cast<String>();
      _cardPrefix.addAll((saved['cardPrefix'] as List? ?? []).cast<String>());
      _cardEditVersion = saved['cardEditVersion'] as int? ?? game.state.version;
      _cardEdits = saved['cardEdits'] as int? ?? 0;
      commandKinds.addAll(Map<String, int>.from(saved['commandKinds'] as Map));
      truncatedReason = saved['truncatedReason'] as String?;
      _committed.addAll([
        for (final row in saved['committedCommands'] as List? ?? [])
          Map<String, dynamic>.from(row as Map),
      ]);
    }
  }
  final AiScenario scenario;
  final GameKernel game;
  final int maximumDecisions;
  int decisionCount = 0;
  int commandCount = 0;
  int _epoch = 0;
  int _idleVersion = -1;
  int _idleIndex = 0;
  List<String> _idlePlayers = [];
  final List<String> _cardPrefix = [];
  int _cardEditVersion = -1;
  int _cardEdits = 0;
  AiDecision? _current;
  final List<int> decisionMicroseconds = [];
  final Map<String, int> commandKinds = {};
  String? truncatedReason;
  Object? failure;
  String? failureStack;
  late final Map<String, Object?> _baseKernel;
  final List<Map<String, dynamic>> _committed = [];
  Map<String, Object?>? _failedCommand;

  AiDecision? decision() {
    if (game.state.finished || truncatedReason != null) return null;
    if (decisionCount >= maximumDecisions) {
      truncatedReason = 'decisionLimit';
      return null;
    }
    if (_current != null && _current!.gameVersion == game.state.version) {
      return _current;
    }
    if (_cardEditVersion != game.state.version) {
      _cardEditVersion = game.state.version;
      _cardEdits = 0;
      _cardPrefix.clear();
    }
    final timer = Stopwatch()..start();
    AiDecision? value;
    final forced =
        game.state.choice != null ||
        game.state.preparation != null ||
        game.state.pending != null ||
        game.state.phase != GamePhase.action;
    if (forced) {
      value = game.aiDecision();
    } else {
      if (_idleVersion != game.state.version) {
        _idleVersion = game.state.version;
        _idleIndex = 0;
        _idlePlayers = [
          for (final p in game.state.players)
            if (p.character.alive &&
                p != game.state.activePlayer &&
                (p.character.skills.any((s) => s.definition.anytime) ||
                    p.character.traits.any(
                      (t) => t.definition.active?.anytime ?? false,
                    )))
              p.id,
        ];
      }
      while (_idleIndex < _idlePlayers.length) {
        value = game.aiDecision(playerId: _idlePlayers[_idleIndex]);
        if (value!.candidates.any((c) => c.command != null)) break;
        _idleIndex++;
        value = null;
      }
      value ??= game.aiDecision(
        cardPrefix: scenario.definition['trainingMode'] == 'fullMatch'
            ? _cardPrefix
            : null,
        allowCardEdits:
            _cardEdits < 32 + 2 * game.state.activePlayer.character.hand.length,
      );
    }
    timer.stop();
    decisionMicroseconds.add(timer.elapsedMicroseconds);
    if (value == null) return null;
    return _current = AiDecision.reidentified(
      value,
      '${value.decisionId}:$_epoch',
    );
  }

  void step(String decisionId, int candidateIndex) {
    final current = decision();
    if (current == null ||
        current.decisionId != decisionId ||
        current.gameVersion != game.state.version) {
      throw StateError('Stale or closed AI decision');
    }
    if (candidateIndex < 0 || candidateIndex >= current.candidates.length) {
      throw RangeError.index(candidateIndex, current.candidates);
    }
    final candidate = current.candidates[candidateIndex];
    if (candidate.adapterAction != null) {
      _cardEdits++;
      switch (candidate.adapterAction) {
        case 'selectCard':
          _cardPrefix.add(candidate.features['cardInstanceId']! as String);
        case 'unselectCard':
          _cardPrefix.removeLast();
        case 'cancelCardSelection':
          _cardPrefix.clear();
        default:
          throw StateError('Unknown adapter action');
      }
    } else if (candidate.command == null) {
      if (current.phase != 'opportunity') {
        throw StateError('Invalid idle yield');
      }
      _idleIndex++;
    } else {
      _failedCommand = KernelRecoveryCodec.command(candidate.command!);
      game.submit(candidate.command!, expectedVersion: current.gameVersion);
      _committed.add(Map<String, dynamic>.from(_failedCommand!));
      _failedCommand = null;
      _cardPrefix.clear();
      commandCount++;
      commandKinds.update(candidate.kind, (v) => v + 1, ifAbsent: () => 1);
    }
    decisionCount++;
    _epoch++;
    _current = null;
  }

  Map<String, Object?> run(
    Map<String, AiPolicy> policies, {
    bool trace = false,
  }) {
    final timer = Stopwatch()..start();
    final actions = <Map<String, Object?>>[];
    try {
      while (!game.state.finished) {
        final d = decision();
        if (d == null) break;
        final policy = policies[d.actorId];
        if (policy == null) throw StateError('No policy for ${d.actorId}');
        final selected = policy.select(d);
        if (trace) {
          actions.add({
            'decisionId': d.decisionId,
            'actorId': d.actorId,
            'candidateIndex': selected.index,
            'score': selected.score,
            'reason': selected.reason,
            'candidate': d.candidates[selected.index].toJson(),
          });
        }
        step(d.decisionId, selected.index);
      }
    } catch (error, stack) {
      truncatedReason = 'technicalFailure';
      failure = error;
      failureStack = '$stack';
    }
    timer.stop();
    final terminated = game.state.finished && truncatedReason == null;
    return {
      'scenarioId': scenario.id,
      'terminated': terminated,
      'truncated': !terminated,
      'reason': truncatedReason,
      'outcome': terminated ? game.publicView()['outcome'] : null,
      'decisions': decisionCount,
      'kernelCommands': commandCount,
      'elapsedMicroseconds': timer.elapsedMicroseconds,
      'commandKinds': commandKinds,
      if (failure != null) 'error': '$failure',
      if (trace) 'trace': actions,
    };
  }

  Map<String, Object?> failureCase() {
    // A faulty effect may throw after mutating state but before submit records
    // its input. Preserve the last committed node, plus the failing command.
    var consistent = game;
    if (failure != null) {
      consistent = GameKernel.restore(
        scenario.catalog,
        jsonDecode(jsonEncode(_baseKernel)) as Map<String, dynamic>,
      );
      for (final command in _committed) {
        consistent.submit(KernelRecoveryCodec.readCommand(command));
      }
    }
    final saved = consistent.recoveryCheckpoint();
    return {
      'caseVersion': 1,
      'scenario': scenario.definition,
      'reason': truncatedReason,
      'error': '$failure',
      'stack': failureStack,
      'kernel': saved,
      'arena': {...checkpoint(), 'kernel': saved, 'truncatedReason': null},
      if (_failedCommand != null) 'failedCommand': _failedCommand,
      if (_current != null) 'decision': _current!.toJson(),
      'reproduction': 'Restore with frozen content and this kernel checkpoint.',
    };
  }

  Map<String, Object?> checkpoint() =>
      jsonDecode(
            jsonEncode({
              'arenaVersion': 1,
              'kernel': game.recoveryCheckpoint(),
              'baseKernel': _baseKernel,
              'committedCommands': _committed,
              'maximumDecisions': maximumDecisions,
              'decisionCount': decisionCount,
              'commandCount': commandCount,
              'epoch': _epoch,
              'idleVersion': _idleVersion,
              'idleIndex': _idleIndex,
              'idlePlayers': _idlePlayers,
              'cardPrefix': _cardPrefix,
              'cardEditVersion': _cardEditVersion,
              'cardEdits': _cardEdits,
              'commandKinds': commandKinds,
              'truncatedReason': truncatedReason,
            }),
          )
          as Map<String, Object?>;
}
