sealed class KernelCommand {
  const KernelCommand(this.playerId);
  final String playerId;
}

final class AttackCommand extends KernelCommand {
  const AttackCommand(super.playerId, this.targetId);
  final String targetId;
}

final class PlayCardsCommand extends KernelCommand {
  PlayCardsCommand(
    super.playerId,
    List<String> cardInstanceIds, {
    this.targetId,
  }) : cardInstanceIds = List.unmodifiable(cardInstanceIds);
  final List<String> cardInstanceIds;
  final String? targetId;
}

final class UseSkillCommand extends KernelCommand {
  UseSkillCommand(
    super.playerId,
    this.skillInstanceId, {
    List<String> targetIds = const [],
    this.diceResult,
    this.number,
    this.cardInstanceId,
    this.pendingActionId,
    this.copiedSkillId,
    this.recordId,
    this.reverse = false,
  }) : targetIds = List.unmodifiable(targetIds);
  final String skillInstanceId;
  final List<String> targetIds;
  final int? diceResult;
  final int? number;
  final String? cardInstanceId;
  final String? pendingActionId;
  final String? copiedSkillId;
  final String? recordId;
  final bool reverse;
}

final class EndTurnCommand extends KernelCommand {
  const EndTurnCommand(super.playerId);
}

final class DiscardCommand extends KernelCommand {
  DiscardCommand(super.playerId, List<String> cardInstanceIds)
    : cardInstanceIds = List.unmodifiable(cardInstanceIds);
  final List<String> cardInstanceIds;
}

final class PassCommand extends KernelCommand {
  const PassCommand(super.playerId, this.pendingActionId);
  final String pendingActionId;
}

/// Reserve an available response before collecting its remaining parameters.
final class BeginResponseCommand extends KernelCommand {
  const BeginResponseCommand(
    super.playerId,
    this.pendingActionId,
    this.optionId,
  );
  final String pendingActionId, optionId;
}

/// Play one physical hand card in the current response window.
final class RespondCardCommand extends KernelCommand {
  const RespondCardCommand(
    super.playerId,
    this.pendingActionId,
    this.cardInstanceId,
  );
  final String pendingActionId, cardInstanceId;
}

final class ChooseCommand extends KernelCommand {
  const ChooseCommand(super.playerId, this.choiceId, this.optionId);
  final String choiceId;
  final String optionId;
}

final class ActivateStatusCommand extends KernelCommand {
  const ActivateStatusCommand(super.playerId, this.statusInstanceId);
  final String statusInstanceId;
}

final class ActivateTraitCommand extends KernelCommand {
  ActivateTraitCommand(
    super.playerId,
    this.traitInstanceId, {
    List<String> cardInstanceIds = const [],
    this.mode = 'self',
  }) : cardInstanceIds = List.unmodifiable(cardInstanceIds);
  final String traitInstanceId;
  final List<String> cardInstanceIds;
  final String mode;
}

final class ConfirmAbilityCommand extends KernelCommand {
  const ConfirmAbilityCommand(super.playerId, this.preparationId);
  final String preparationId;
}

final class CancelAbilityCommand extends KernelCommand {
  const CancelAbilityCommand(super.playerId, this.preparationId);
  final String preparationId;
}

/// Opt in during the ordinary response window; recording settles with the attack.
final class RecordActionCommand extends KernelCommand {
  const RecordActionCommand(
    super.playerId,
    this.pendingActionId,
    this.traitInstanceId, {
    this.cardInstanceId,
  });
  final String pendingActionId, traitInstanceId;
  final String? cardInstanceId;
}
