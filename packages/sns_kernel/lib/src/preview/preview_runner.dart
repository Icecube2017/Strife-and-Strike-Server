import 'dart:convert';
import 'package:sns_kernel/src/content/wire_content.dart';
import 'package:sns_kernel/src/kernel.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';

final class _NeedRandom implements Exception {
  const _NeedRandom(this.upper);
  final int upper;
}

final class PreviewRunner {
  const PreviewRunner(this.catalog, {required this.contentHash});
  final ContentCatalog catalog;
  final String contentHash;
  PreviewResult run(PreviewState state, PreviewRequest request) {
    request.validate();
    final snapshot = state.toJson();
    final notes = (snapshot['limitations'] as List).cast<String>().toSet();
    if (snapshot['contentHash'] != contentHash) {
      throw StateError('contentHashMismatch');
    }
    if (state.version != request.version) {
      throw StateError('stalePreviewVersion');
    }
    if (snapshot['viewerId'] != request.playerId) {
      throw StateError('forbiddenPreviewViewer');
    }
    if (request.maximumBranches < 1 || request.maximumBranches > 256) {
      throw ArgumentError('maximumBranches must be 1..256');
    }
    final pendingMode = request.mode != PreviewMode.action;
    final assumptions = <String>[
      pendingMode ? 'assumesOtherResponsesPass' : 'assumesNoResponses',
    ];
    final declaration = snapshot['pendingAction'] as Map<String, dynamic>?;
    PreviewResult unavailable(String reason) => PreviewResult(
      version: state.version,
      mode: request.mode,
      windowId: request.windowId,
      assumptions: assumptions,
      complete: false,
      branches: [],
      limitations: {...notes, reason}.toList(),
    );
    KernelCommand? candidate;
    if (pendingMode) {
      notes.remove('assumesNoResponses');
      if (declaration == null || snapshot['pendingAvailable'] != true) {
        return unavailable('notResponseWindow');
      }
      if (declaration['windowId'] != request.windowId) {
        throw StateError('stalePreviewWindow');
      }
      if ((declaration['unknownSubmissionCount'] as int) > 0) {
        assumptions.add('ignoresUnknownSubmittedResponses');
      }
      final own = declaration['ownSubmission'] as Map<String, dynamic>?;
      final submitted = own == null
          ? null
          : KernelRecoveryCodec.readCommand(own);
      candidate =
          request.response?.command(request.playerId, request.windowId!) ??
          submitted;
      if (submitted != null) {
        assumptions.add('includesOwnSubmittedResponse');
        if (candidate != null &&
            jsonEncode(KernelRecoveryCodec.command(candidate)) !=
                jsonEncode(KernelRecoveryCodec.command(submitted))) {
          throw StateError('responseAlreadySubmitted');
        }
      }
      final blockers = (declaration['blockedBy'] as List).cast<String>();
      if (blockers.isNotEmpty) {
        notes.addAll(blockers);
        return unavailable('pendingProjectionIncomplete');
      }
      if (candidate != null) {
        final validation = KernelPreviewProjection.restore(
          catalog,
          snapshot,
          (_) => throw StateError('previewValidationRandom'),
        );
        validation.restorePreviewPending(snapshot);
        try {
          validation.validatePreviewResponse(request.playerId, candidate);
        } on PreviewBoundary catch (e) {
          return unavailable(e.reason);
        }
      }
    } else {
      if (snapshot['available'] != true ||
          snapshot['activePlayerId'] != request.playerId) {
        return unavailable('notActionWindow');
      }
      final own = (snapshot['players'] as List).cast<Map>().firstWhere(
        (p) => p['playerId'] == request.playerId,
      );
      if (own['hasUnprojectedAttack'] == true) {
        return unavailable('unprojectedPreparedAttack');
      }
    }
    final pending = <List<int>>[[]];
    final branches = <Map<String, Object?>>[];
    var attempts = 0;
    var complete = true;
    while (pending.isNotEmpty && attempts < request.maximumBranches * 4) {
      final trace = pending.removeLast();
      attempts++;
      var cursor = 0;
      final game = KernelPreviewProjection.restore(catalog, snapshot, (upper) {
        if (cursor == trace.length) throw _NeedRandom(upper);
        return trace[cursor++];
      });
      try {
        if (pendingMode) {
          game.restorePreviewPending(snapshot);
          game.runPreviewPending(request.playerId, candidate);
        } else {
          final command = request.cardInstanceIds.isEmpty
              ? AttackCommand(request.playerId, request.targetId!)
              : PlayCardsCommand(
                  request.playerId,
                  request.cardInstanceIds,
                  targetId: request.targetId,
                );
          game.submit(command, expectedVersion: request.version);
        }
        var windows = 0;
        while (game.state.pending != null &&
            game.state.choice == null &&
            game.state.preparation == null &&
            windows++ < 16) {
          final window = game.state.pending!;
          for (final playerId in List<String>.of(window.waitingPlayerIds)) {
            if (game.state.pending != window) break;
            game.submit(PassCommand(playerId, window.windowId));
          }
        }

        if (game.state.choice != null ||
            game.state.preparation != null ||
            game.state.pending != null) {
          complete = false;
          notes.add('interactionRequired');
        }
        branches.add(_branch(game, trace));
        if (branches.length >= request.maximumBranches && pending.isNotEmpty) {
          complete = false;
          break;
        }
      } on _NeedRandom catch (need) {
        if (trace.length >= 16 ||
            need.upper > 64 ||
            pending.length + need.upper > 1024) {
          complete = false;
          notes.add('randomBranchLimit');
          continue;
        }
        for (var value = need.upper - 1; value >= 0; value--) {
          pending.add([...trace, value]);
        }
      } on PreviewBoundary catch (e) {
        complete = false;
        notes.add(e.reason);
        branches.add(_branch(game, trace, stoppedAt: 'unknownInformation'));
      } on StateError {
        complete = false;
        notes.add('branchRejected');
        if (game.state.events.isNotEmpty) {
          branches.add(_branch(game, trace, stoppedAt: 'rejected'));
        }
      }
    }
    if (pending.isNotEmpty) {
      complete = false;
      notes.add('branchBudgetExceeded');
    }
    return PreviewResult(
      version: state.version,
      mode: request.mode,
      windowId: request.windowId,
      assumptions: assumptions,
      complete: complete,
      branches: branches,
      limitations: notes.toList(),
    );
  }

  Map<String, Object?> _branch(
    GameKernel game,
    List<int> trace, {
    String? stoppedAt,
  }) {
    final targets = <String, Map<String, int>>{
      for (final p in game.state.players)
        p.character.instanceId: {
          'mainDamage': 0,
          'attachmentDamage': 0,
          'independentDamage': 0,
          'shieldLost': 0,
          'hpLost': 0,
          'lifeLost': 0,
          'healing': 0,
          'counterDamage': 0,
        },
    };
    final steps = <Map<String, Object?>>[];
    for (final event in game.state.events) {
      final d = event.data;
      if (event.type == 'damage') {
        final t = targets[d['targetId']]!;
        final amount = damageBeforeShield(d);
        final category = d['kind'] == 'lifeLoss'
            ? 'lifeLost'
            : d['attack'] != true
            ? 'independentDamage'
            : d['component'] == 'main'
            ? 'mainDamage'
            : 'attachmentDamage';
        t[category] = t[category]! + amount;
        t['shieldLost'] = t['shieldLost']! + (d['shieldAbsorbed']! as int);
        t['hpLost'] =
            t['hpLost']! + (d['actualHpLost'] as int? ?? d['hpLost']! as int);
      } else if (event.type == 'counterattack') {
        final t = targets[d['targetId']]!;
        t['counterDamage'] = t['counterDamage']! + (d['amount']! as int);
      } else if (event.type == 'healed') {
        final t = targets[d['targetId']]!;
        t['healing'] = t['healing']! + (d['amount']! as int);
      }
      if (const {
        'damageCalculated',
        'diceRolled',
        'attackPacketStarted',
        'damage',
        'healed',
        'counterattack',
        'attackDodged',
        'duelResolved',
        'statusApplied',
        'statusRejected',
        'choiceOpened',
        'skillUsed',
        'responseSkipped',
        'attackRedirected',
        'cardCancelled',
        'diceChanged',
        'actionCancelled',
      }.contains(event.type)) {
        steps.add({
          'type': event.type,
          'data': machineStateView({
            ...(event.type == 'damage' ? damageWireData(d) : d),
            if (d['reason'] is String &&
                !RegExp(
                  r'^[a-z][A-Za-z0-9]*$',
                ).hasMatch(d['reason']! as String))
              'reason': 'operationRejected',
          }),
        });
      }
    }
    return {
      'randomChoices': trace,
      'targets': targets,
      'steps': steps,
      'interaction': game.state.choice == null
          ? null
          : {
              'kind': game.state.choice!.kind.name,
              'playerId': game.state.choice!.playerId,
            },
      'stoppedAt':
          stoppedAt ??
          (game.state.choice != null
              ? 'choice'
              : game.state.preparation != null
              ? 'preparation'
              : game.state.pending != null
              ? 'responseWindow'
              : 'settled'),
    };
  }
}
