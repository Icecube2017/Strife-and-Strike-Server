part of 'engine.dart';

extension KernelRecovery on GameKernel {
  static const compatibility = 'kernel-v2-recovery-1';

  Map<String, Object?> recoveryCheckpoint() =>
      jsonDecode(
            jsonEncode({
              'schemaVersion': 1,
              'diceDataVersion': 1,
              'abilityLogVersion': 1,
              'interactionLogVersion': 1,
              'performanceLogVersion': 1,
              'statisticsRulesVersion': _statisticsRulesVersion,
              if (_statisticsRulesVersion >= 2)
                'supportScoreRules': _supportScoreRules.toJson(),
              'effectViewVersion': 1,
              'pileViewVersion': 1,
              'statusChoiceQueryVersion': _statusChoiceQueryVersion,
              'damageAmountVersion': _damageAmountVersion,
              'interactionRulesVersion': _interactionRulesVersion,
              if (_privateRecordViews) 'privateRecordViewVersion': 1,
              'firstRoundMpRecovery': _firstRoundMpRecovery,
              'compatibility': compatibility,
              'contentVersion': catalog.version,
              'setup': KernelRecoveryCodec.setup(setup),
              if (scenario != null) 'scenario': scenario!.toJson(),
              'inputs': _recoveryInputs,
              'random': _recoveryRandom,
              'version': state.version,
              'randomState': state.randomState,
              'verification': _recoveryVerification(),
            }),
          )
          as Map<String, Object?>;

  String _recoveryVerification({
    bool legacyDice = false,
    bool legacyAbilityLogs = false,
    bool legacyInteractionLogs = false,
    bool legacyPerformance = false,
    bool legacyCardHandLoss = false,
    bool legacyEffectViews = false,
    bool legacyPileView = false,
  }) {
    final public = publicView();
    if (legacyPileView) public.remove('drawPileCount');
    if (legacyEffectViews) {
      // Only omit newly added presentation fields from old verification views.
      public.remove('globalEffects');
      for (final player in public['players']! as List) {
        for (final status in (player as Map)['statuses'] as List) {
          (status as Map).remove('isStatusEffect');
        }
      }
    }
    // Performance scores were added by an observer without changing combat.
    // Old checkpoints verify against their original combat-only projection.
    final statistics = legacyPerformance
        ? _statistics.snapshot()
        : statisticsView();
    if (legacyPerformance) public['statistics'] = statistics;
    if (legacyDice && public['pending'] is Map) {
      (public['pending']! as Map).remove('diceRoll');
    }
    const addedDiceFields = {
      'roll',
      'diceRoll',
      'rollId',
      'rollIds',
      'dieIndex',
      'previousRollId',
    };
    const enrichedDiceEvents = {
      'diceRolled',
      'diceChanged',
      'damageCalculated',
      'damageDiceSelected',
      'diceReplaced',
    };
    return jsonEncode({
      'public': public,
      'private': {for (final p in state.players) p.id: privateView(p.id)},
      'statistics': statistics,
      'events': [
        for (final e in state.events)
          {
            'sequence': e.sequence,
            'type': e.type,
            'data': {
              for (final entry in e.data.entries)
                if (!(legacyDice &&
                        enrichedDiceEvents.contains(e.type) &&
                        addedDiceFields.contains(entry.key)) &&
                    !(legacyAbilityLogs && entry.key == 'logTargetIds') &&
                    !(legacyInteractionLogs &&
                        _interactionLogFields.contains(entry.key)) &&
                    !(legacyCardHandLoss && entry.key == 'handLossCount'))
                  entry.key: entry.value,
            },
          },
      ],
    });
  }

  static GameKernel restore(
    ContentCatalog catalog,
    Map<String, dynamic> saved,
  ) {
    if (saved['privateRecordViewVersion'] != null &&
        saved['privateRecordViewVersion'] != 1) {
      throw StateError('Unsupported private record view version');
    }
    final damageVersion = saved['damageAmountVersion'];
    if (damageVersion != null &&
        (damageVersion is! int || (damageVersion != 0 && damageVersion != 1))) {
      throw StateError('Unsupported damage amount version');
    }
    final queryVersion = saved['statusChoiceQueryVersion'];
    if ((queryVersion != null &&
            (queryVersion is! int ||
                (queryVersion != 0 && queryVersion != 1))) ||
        (saved['abilityLogVersion'] != null &&
            saved['abilityLogVersion'] != 1) ||
        (saved['interactionLogVersion'] != null &&
            saved['interactionLogVersion'] != 1) ||
        (saved['performanceLogVersion'] != null &&
            saved['performanceLogVersion'] != 1) ||
        (saved['effectViewVersion'] != null &&
            saved['effectViewVersion'] != 1) ||
        (saved['diceDataVersion'] != null && saved['diceDataVersion'] != 1) ||
        saved['schemaVersion'] != 1 ||
        saved['compatibility'] != compatibility ||
        saved['contentVersion'] != catalog.version) {
      throw StateError('Unsupported recovery format or content version');
    }
    if (queryVersion != null) {
      return _restore(catalog, saved, queryVersion as int);
    }
    // Unversioned saves straddle the alias fix. Accept a historical policy only
    // when its entire replay (including IDs, events and random tape) verifies.
    try {
      return _restore(catalog, saved, 1);
    } catch (error, stack) {
      try {
        return _restore(catalog, saved, 0);
      } catch (_) {
        Error.throwWithStackTrace(error, stack);
      }
    }
  }

  static GameKernel _restore(
    ContentCatalog catalog,
    Map<String, dynamic> saved,
    int queryVersion, {
    int Function(int)? randomInt,
  }) {
    final game =
        GameKernel(
            catalog,
            KernelRecoveryCodec.readSetup(
              saved['setup'] as Map<String, dynamic>,
            ),
            randomInt: randomInt,
            statisticsRulesVersion:
                saved['statisticsRulesVersion'] as int? ?? 1,
            scenario: saved['scenario'] == null
                ? null
                : ScenarioSetup.fromJson(
                    Map<String, dynamic>.from(saved['scenario'] as Map),
                  ),
            scoreRules: saved['supportScoreRules'] is Map
                ? SupportScoreRules.fromJson(
                    Map<String, dynamic>.from(
                      saved['supportScoreRules'] as Map,
                    ),
                  )
                : const SupportScoreRules(),
          )
          .._statusChoiceQueryVersion = queryVersion
          .._damageAmountVersion = saved['damageAmountVersion'] as int? ?? 0;
    final interactionVersion = saved['interactionRulesVersion'] as int? ?? 0;
    if (interactionVersion < 0 || interactionVersion > 23) {
      throw StateError('Unsupported interaction rules');
    }
    game._interactionRulesVersion = interactionVersion;
    game._privateRecordViews = saved['privateRecordViewVersion'] == 1;
    if (interactionVersion == 0) {
      for (final p in game.state.players) {
        for (final s in p.character.skills) {
          s.revealed = false;
        }
      }
    }
    final explicitPolicy = saved['firstRoundMpRecovery'];
    if (explicitPolicy != null && explicitPolicy is! bool) {
      throw StateError('Invalid first-round MP recovery policy');
    }
    // Older checkpoints have no rule marker. Infer only from recorded facts,
    // then retain the full replay verification below; never waive MP checks.
    var legacyRecovery = false;
    if (explicitPolicy == null) {
      final verification = jsonDecode(saved['verification'] as String) as Map;
      var round = 0;
      for (final event in verification['events'] as List) {
        if (event['type'] == 'roundStarted') {
          round = event['data']['round'] as int;
        }
        if (round == 1 && event['type'] == 'mpRegenerated') {
          legacyRecovery = true;
          break;
        }
      }
    }
    game._firstRoundMpRecovery = explicitPolicy as bool? ?? legacyRecovery;
    game._replayRandom = [
      for (final d in saved['random'] as List) Map<String, int>.from(d as Map),
    ];
    for (final input in saved['inputs'] as List) {
      switch (input['type']) {
        case 'start':
          game.start();
        case 'command':
          game.submit(
            KernelRecoveryCodec.readCommand(
              input['command'] as Map<String, dynamic>,
            ),
            expectedVersion: input['expectedVersion'] as int?,
          );
        case 'expire':
          if (!game.expireResponse(input['windowId'] as String)) {
            throw StateError('Recovery timeout mismatch');
          }
        default:
          throw StateError('Unknown recovery transition');
      }
    }
    final expected = jsonDecode(saved['verification'] as String) as Map;
    final legacyPerformance =
        saved['performanceLogVersion'] == null &&
        (expected['statistics'] as Map)['performanceSchemaVersion'] == null &&
        ((expected['public'] as Map)['statistics']
                as Map)['performanceSchemaVersion'] ==
            null;
    final actualVerification = game._recoveryVerification(
      legacyDice: saved['diceDataVersion'] == null,
      legacyAbilityLogs: saved['abilityLogVersion'] == null,
      legacyInteractionLogs: saved['interactionLogVersion'] == null,
      legacyPerformance: legacyPerformance,
      legacyEffectViews: saved['effectViewVersion'] == null,
      legacyPileView: saved['pileViewVersion'] == null,
      legacyCardHandLoss:
          saved['performanceLogVersion'] == null &&
          !(expected['events'] as List).any(
            (e) =>
                e['type'] == 'cardsPlayed' &&
                (e['data'] as Map).containsKey('handLossCount'),
          ),
    );
    if (game._replayCursor != game._replayRandom!.length ||
        game.state.version != saved['version'] ||
        game.state.randomState != saved['randomState'] ||
        actualVerification != saved['verification']) {
      final difference = _recoveryDifference(
        expected,
        jsonDecode(actualVerification),
        'verification',
      );
      throw StateError(
        'Recovery verification failed; content or execution differs'
        '${difference == null ? '' : '; first mismatch: $difference'}',
      );
    }
    game._replayRandom = null;
    return game;
  }

  // Report only a field path, never private hands, inputs or saved values.
  static String? _recoveryDifference(
    Object? expected,
    Object? actual,
    String path,
  ) {
    if (expected is Map && actual is Map) {
      for (final key in {...expected.keys, ...actual.keys}) {
        if (!expected.containsKey(key) || !actual.containsKey(key)) {
          return '$path.$key';
        }
        final difference = _recoveryDifference(
          expected[key],
          actual[key],
          '$path.$key',
        );
        if (difference != null) return difference;
      }
      return null;
    }
    if (expected is List && actual is List) {
      if (expected.length != actual.length) return '$path.length';
      for (var i = 0; i < expected.length; i++) {
        final difference = _recoveryDifference(
          expected[i],
          actual[i],
          '$path[$i]',
        );
        if (difference != null) return difference;
      }
      return null;
    }
    return expected == actual ? null : path;
  }

  GameKernel forkPendingPreview(int Function(int) randomInt) {
    final checkpoint =
        jsonDecode(jsonEncode(recoveryCheckpoint())) as Map<String, dynamic>;
    final clone = _restore(
      catalog,
      checkpoint,
      _statusChoiceQueryVersion,
      randomInt: randomInt,
    );
    clone.state.pending?.submissions.clear();
    clone._observedAction?.recordingSelections.clear();
    return clone;
  }
}
