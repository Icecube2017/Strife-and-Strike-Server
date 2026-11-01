import 'package:sns_server/domain/kernel/kernel.dart';

/// HTTP choices -> typed kernel commands. Authenticated identity is authoritative.
final class KernelCommandRequest {
  const KernelCommandRequest({
    required this.commandId,
    required this.clientVersion,
    required this.command,
  });
  final String commandId;
  final int clientVersion;
  final KernelCommand command;

  factory KernelCommandRequest.fromJson(
    Map<String, dynamic> json, {
    required String playerId,
  }) {
    String string(Map<String, dynamic> source, String key) {
      final value = source[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('$key must be a non-empty string');
      }
      return value;
    }

    final commandId = string(json, 'commandId');
    final version = json['clientVersion'];
    if (version is! int || version < 0) {
      throw const FormatException('clientVersion must be non-negative');
    }
    if (json['playerId'] != null && json['playerId'] != playerId) {
      throw const FormatException('playerId must match authenticated identity');
    }
    final raw = json['payload'] ?? <String, dynamic>{};
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('payload must be an object');
    }
    List<String> strings(String key, {bool optional = false}) {
      final value = raw[key];
      if (value == null && optional) return const [];
      if (value is! List || value.any((e) => e is! String || e.isEmpty)) {
        throw FormatException('$key must be a list of instance IDs');
      }
      return value.cast<String>();
    }

    String? optionalString(String key) =>
        raw[key] == null ? null : string(raw, key);
    if (raw['reverse'] != null && raw['reverse'] is! bool) {
      throw const FormatException('reverse must be boolean');
    }
    if (raw['number'] != null && raw['number'] is! int) {
      throw const FormatException('number must be an integer');
    }
    final type = string(json, 'actionType');
    final KernelCommand command;
    switch (type) {
      case 'beginResponse':
        command = BeginResponseCommand(
          playerId,
          string(raw, 'windowId'),
          string(raw, 'optionId'),
        );
      case 'respond':
        final windowId = string(raw, 'windowId');
        final optionId = string(raw, 'optionId');
        if (optionId == 'pass') {
          command = PassCommand(playerId, windowId);
        } else if (optionId.startsWith('card:') && optionId.length > 5) {
          command = RespondCardCommand(
            playerId,
            windowId,
            optionId.substring(5),
          );
        } else if (optionId.startsWith('record:') && optionId.length > 7) {
          command = RecordActionCommand(
            playerId,
            windowId,
            optionId.substring(7),
            cardInstanceId: optionalString('cardInstanceId'),
          );
        } else if (optionId.startsWith('skill:') && optionId.length > 6) {
          final result = raw['diceResult'];
          if (result != null && result is! int) {
            throw const FormatException('diceResult must be an integer');
          }
          command = UseSkillCommand(
            playerId,
            optionId.substring(6),
            pendingActionId: windowId,
            copiedSkillId: optionalString('copiedSkillId'),
            diceResult: result as int?,
            number: raw['number'] as int?,
            cardInstanceId: optionalString('cardInstanceId'),
            targetIds: strings('targetIds', optional: true),
          );
        } else {
          throw const FormatException('Unknown response option');
        }
      case 'activateTrait':
        command = ActivateTraitCommand(
          playerId,
          string(raw, 'traitInstanceId'),
          cardInstanceIds: strings('cardInstanceIds', optional: true),
          mode: optionalString('mode') ?? 'self',
        );
      case 'activateStatus':
        command = ActivateStatusCommand(
          playerId,
          string(raw, 'statusInstanceId'),
        );
      case 'confirmAbility':
        command = ConfirmAbilityCommand(playerId, string(raw, 'preparationId'));
      case 'cancelAbility':
        command = CancelAbilityCommand(playerId, string(raw, 'preparationId'));
      case 'choose':
        command = ChooseCommand(
          playerId,
          string(raw, 'choiceId'),
          string(raw, 'optionId'),
        );
      case 'attack':
        command = AttackCommand(playerId, string(raw, 'targetId'));
      case 'playCards':
        command = PlayCardsCommand(
          playerId,
          strings('cardInstanceIds'),
          targetId: optionalString('targetId'),
        );
      case 'useSkill':
        final result = raw['diceResult'];
        if (result != null && result is! int) {
          throw const FormatException('diceResult must be an integer');
        }
        command = UseSkillCommand(
          playerId,
          string(raw, 'skillInstanceId'),
          targetIds: strings('targetIds', optional: true),
          diceResult: result as int?,
          number: raw['number'] as int?,
          cardInstanceId: optionalString('cardInstanceId'),
          pendingActionId: optionalString('pendingActionId'),
          copiedSkillId: optionalString('copiedSkillId'),
          recordId: optionalString('recordId'),
          reverse: raw['reverse'] as bool? ?? false,
        );
      case 'endTurn':
        command = EndTurnCommand(playerId);
      case 'discard':
        command = DiscardCommand(playerId, strings('cardInstanceIds'));
      case 'pass':
        command = PassCommand(playerId, string(raw, 'pendingActionId'));
      default:
        throw FormatException('Unsupported actionType: $type');
    }
    return KernelCommandRequest(
      commandId: commandId,
      clientVersion: version,
      command: command,
    );
  }
}
