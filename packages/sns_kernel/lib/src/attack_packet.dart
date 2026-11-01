import 'package:sns_kernel/src/definitions.dart';

/// One target's immutable attack plan. Dynamic amounts are frozen before any
/// packet from the same action resolves; mutable characters are never stored here.
final class AttackPacket {
  AttackPacket({
    required this.id,
    required this.actionId,
    required this.sourceId,
    required this.targetId,
    required this.amount,
    required this.kind,
    required this.piercesContinuation,
    required List<AttackPacketEffect> onHit,
    this.baseDamage = 0,
    this.attachmentDamageMultiplier = 1,
    this.ignoreDodge = false,
    this.groupAttack = false,
    this.ignoreShield = false,
    this.clearDodge = false,
    this.clearShield = false,
  }) : onHit = List.unmodifiable(onHit);

  final String id;
  final String actionId;
  final String sourceId;
  final String targetId;
  final int amount;
  final int baseDamage;
  final double attachmentDamageMultiplier;
  final DamageKind kind;
  final bool piercesContinuation;
  final bool ignoreDodge;
  final bool groupAttack;
  final bool ignoreShield;
  final bool clearDodge;
  final bool clearShield;
  final List<AttackPacketEffect> onHit;
}

final class AttackPacketEffect {
  const AttackPacketEffect(
    this.definitionId,
    this.effect,
    this.multiplier, {
    this.sourceId,
  });
  final String? sourceId;
  final String definitionId;
  final EffectDefinition effect;
  final int multiplier;
}
