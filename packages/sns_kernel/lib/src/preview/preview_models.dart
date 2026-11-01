import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sns_kernel/src/commands.dart';

const previewCompatibility = 'kernel-v2-preview-27';
Object? _freeze(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable({
    for (final e in value.entries) e.key as String: _freeze(e.value),
  }),
  List() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

/// Hash semantic JSON, not whitespace. Neither Wiki prose nor a version name
/// alone identifies the executable definitions used for a particular game.
String executableContentHash(String source) => sha256
    .convert(utf8.encode(jsonEncode(_canonical(jsonDecode(source)))))
    .toString();

final class PreviewState {
  PreviewState(Map<String, Object?> json)
    : data = _freeze(json)! as Map<String, Object?> {
    if (data['schemaVersion'] != 1 ||
        data['kernelCompatibility'] != previewCompatibility) {
      throw const FormatException('incompatiblePreviewSnapshot');
    }
  }
  final Map<String, Object?> data;
  int get version => data['version']! as int;
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
}

enum PreviewMode { action, pendingAction, response }

/// A tentative response uses the same option IDs and inputs as a real response.
/// Identity and window are supplied separately, never taken from this payload.
final class PreviewResponse {
  PreviewResponse({
    required this.optionId,
    List<String> targetIds = const [],
    this.diceResult,
    this.number,
    this.cardInstanceId,
    this.copiedSkillId,
    this.recordId,
    this.reverse = false,
  }) : targetIds = List.unmodifiable(targetIds);
  final String optionId;
  final List<String> targetIds;
  final int? diceResult;
  final int? number;
  final String? cardInstanceId;
  final String? copiedSkillId;
  final String? recordId;
  final bool reverse;

  factory PreviewResponse.fromJson(Map<String, dynamic> data) {
    const fields = {
      'optionId',
      'targetIds',
      'diceResult',
      'number',
      'cardInstanceId',
      'copiedSkillId',
      'recordId',
      'reverse',
    };
    if (data.keys.any((k) => !fields.contains(k)) ||
        data['optionId'] is! String ||
        (data['optionId'] as String).isEmpty) {
      throw const FormatException('invalidPreviewResponse');
    }
    final targets = data['targetIds'] ?? <String>[];
    if (targets is! List ||
        targets.length > 32 ||
        targets.any((v) => v is! String || v.isEmpty) ||
        [
          'diceResult',
          'number',
        ].any((k) => data[k] != null && data[k] is! int) ||
        ['cardInstanceId', 'copiedSkillId', 'recordId'].any(
          (k) =>
              data[k] != null &&
              (data[k] is! String || (data[k] as String).isEmpty),
        ) ||
        (data['reverse'] != null && data['reverse'] is! bool)) {
      throw const FormatException('invalidPreviewResponse');
    }
    return PreviewResponse(
      optionId: data['optionId'] as String,
      targetIds: targets.cast<String>(),
      diceResult: data['diceResult'] as int?,
      number: data['number'] as int?,
      cardInstanceId: data['cardInstanceId'] as String?,
      copiedSkillId: data['copiedSkillId'] as String?,
      recordId: data['recordId'] as String?,
      reverse: data['reverse'] as bool? ?? false,
    );
  }

  KernelCommand command(String playerId, String windowId) {
    if (optionId.startsWith('card:') && optionId.length > 5) {
      if (targetIds.isNotEmpty ||
          diceResult != null ||
          number != null ||
          cardInstanceId != null ||
          copiedSkillId != null ||
          recordId != null ||
          reverse) {
        throw const FormatException('invalidPreviewOption');
      }
      return RespondCardCommand(playerId, windowId, optionId.substring(5));
    }
    if (optionId == 'pass') {
      if (targetIds.isNotEmpty ||
          diceResult != null ||
          number != null ||
          cardInstanceId != null ||
          copiedSkillId != null ||
          recordId != null ||
          reverse) {
        throw const FormatException('invalidPreviewPass');
      }
      return PassCommand(playerId, windowId);
    }
    if (!optionId.startsWith('skill:') || optionId.length == 6) {
      throw const FormatException('invalidPreviewOption');
    }
    return UseSkillCommand(
      playerId,
      optionId.substring(6),
      targetIds: targetIds,
      diceResult: diceResult,
      number: number,
      cardInstanceId: cardInstanceId,
      copiedSkillId: copiedSkillId,
      recordId: recordId,
      reverse: reverse,
      pendingActionId: windowId,
    );
  }
}

final class PreviewRequest {
  PreviewRequest({
    required this.playerId,
    required this.version,
    this.targetId,
    this.mode = PreviewMode.action,
    this.windowId,
    this.response,
    List<String> cardInstanceIds = const [],
    this.maximumBranches = 128,
  }) : cardInstanceIds = List.unmodifiable(cardInstanceIds);
  final String playerId;
  final String? targetId;
  final int version;
  final PreviewMode mode;
  final String? windowId;
  final PreviewResponse? response;
  final List<String> cardInstanceIds;
  final int maximumBranches;

  factory PreviewRequest.fromJson(
    Map<String, dynamic> data, {
    required String playerId,
  }) {
    const fields = {
      'playerId',
      'version',
      'targetId',
      'mode',
      'windowId',
      'response',
      'cardInstanceIds',
      'maximumBranches',
    };
    final mode = data['mode'] ?? 'action';
    final cards = data['cardInstanceIds'] ?? <String>[];
    final limit = data['maximumBranches'] ?? 128;
    if (data.keys.any((k) => !fields.contains(k)) ||
        data['version'] is! int ||
        mode is! String ||
        !PreviewMode.values.any((v) => v.name == mode) ||
        (data['playerId'] != null && data['playerId'] != playerId) ||
        cards is! List ||
        cards.length > 32 ||
        cards.any((c) => c is! String || c.isEmpty) ||
        limit is! int ||
        limit < 1 ||
        limit > 256 ||
        ['targetId', 'windowId'].any(
          (k) =>
              data[k] != null &&
              (data[k] is! String || (data[k] as String).isEmpty),
        ) ||
        (data['response'] != null &&
            data['response'] is! Map<String, dynamic>)) {
      throw const FormatException('invalidPreviewRequest');
    }
    final request = PreviewRequest(
      playerId: playerId,
      version: data['version'] as int,
      mode: PreviewMode.values.byName(mode),
      targetId: data['targetId'] as String?,
      windowId: data['windowId'] as String?,
      cardInstanceIds: cards.cast<String>(),
      maximumBranches: limit,
      response: data['response'] == null
          ? null
          : PreviewResponse.fromJson(data['response'] as Map<String, dynamic>),
    );
    request.validate();
    return request;
  }

  void validate() {
    if (mode == PreviewMode.action
        ? targetId == null ||
              targetId!.isEmpty ||
              windowId != null ||
              response != null
        : windowId == null ||
              windowId!.isEmpty ||
              targetId != null ||
              cardInstanceIds.isNotEmpty ||
              (mode == PreviewMode.response
                  ? response == null
                  : response != null)) {
      throw const FormatException('invalidPreviewModeInputs');
    }
  }
}

final class PreviewResult {
  PreviewResult({
    required this.version,
    required this.complete,
    this.mode = PreviewMode.action,
    this.windowId,
    List<String> assumptions = const ['assumesNoResponses'],
    required List<Map<String, Object?>> branches,
    required List<String> limitations,
  }) : assumptions = List.unmodifiable(assumptions),
       branches = _freeze(branches)! as List<Object?>,
       limitations = List.unmodifiable(limitations);
  final int version;
  final PreviewMode mode;
  final String? windowId;
  final List<String> assumptions;

  /// Complete enumeration of the known projection, not a guarantee that other
  /// players will pass or that unprojected mechanisms cannot change the result.
  final bool complete;
  final List<Object?> branches;
  final List<String> limitations;
  Map<String, Object?> toJson() {
    final ranges = <String, Map<String, int>>{};
    for (final item in branches) {
      final branch = item! as Map;
      for (final entry in (branch['targets']! as Map).entries) {
        final range = ranges.putIfAbsent(entry.key as String, () => {});
        for (final metric in (entry.value as Map).entries) {
          if (metric.value is! int) continue;
          final value = metric.value as int;
          final key = metric.key as String;
          range['${key}Min'] =
              range['${key}Min'] == null || value < range['${key}Min']!
              ? value
              : range['${key}Min']!;
          range['${key}Max'] =
              range['${key}Max'] == null || value > range['${key}Max']!
              ? value
              : range['${key}Max']!;
        }
      }
    }
    return {
      'version': version,
      'mode': mode.name,
      if (windowId != null) 'windowId': windowId,
      'assumptions': assumptions,
      'complete': complete,
      'conditional': true,
      'rangeMeaning': complete
          ? 'knownProjectionAllBranches'
          : 'observedBranchesOnly',
      'ranges': ranges,
      'branches': branches,
      'limitations': limitations,
    };
  }
}

final class PreviewBoundary implements Exception {
  const PreviewBoundary(this.reason);
  final String reason;
}
