import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/data/ids.dart';

/// A visible, character-bound effect with a shared layer-decay cadence.
abstract class Status extends Identifiable {
  Character get owner;
  int get stacks;
  int get intensity;
  StatusStacking get stacking;
  int get stackFractions;
  int get initialStackFractions;

  void setIntensity(int value);
  void setStacks(int value);
  void initializeStackFractions(int value);
  void setStackFractions(int value);

  Future<void> onAttached(GameContext context);
  Future<void> onChanged(GameContext context);
  Future<void> onRemoved(GameContext context);
  Future<void> onTurnStart(GameContext context);
  Future<void> onTurnEnd(GameContext context);
  Future<void> ownerTransfer(GameContext context, Character newOwner);
}

// Hidden statuses follow the same lifecycle but are not exposed to clients.
abstract class HiddenStatus extends Identifiable {
  Character get owner;
  int get stacks;
  int get intensity;
}

abstract class Stuff extends Identifiable {
  int get stacks;
  int get intensity;
  int get value;
  String get text;
}

class BaseStatus implements Status {
  BaseStatus(this.id, {this.stacking = StatusStacking.max});

  @override
  final String id;
  @override
  late Character owner;
  @override
  final StatusStacking stacking;

  int _intensity = 0;
  int _stacks = 0;
  int _stackFractions = 0;
  int _initialStackFractions = 0;

  @override
  int get intensity => _intensity;
  @override
  int get stacks => _stacks;
  @override
  int get stackFractions => _stackFractions;
  @override
  int get initialStackFractions => _initialStackFractions;

  @override
  void setIntensity(int value) {
    _intensity = value < 0 ? 0 : value;
  }

  @override
  void setStacks(int value) {
    _stacks = value < 0 ? 0 : value;
  }

  @override
  void initializeStackFractions(int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'value', 'must be positive');
    }
    _initialStackFractions = value;
    _stackFractions = value;
  }

  @override
  void setStackFractions(int value) {
    _stackFractions = value < 0 ? 0 : value;
  }

  @override
  Future<void> onAttached(GameContext context) async {}

  @override
  Future<void> onChanged(GameContext context) async {}

  @override
  Future<void> onRemoved(GameContext context) async {}

  @override
  Future<void> onTurnStart(GameContext context) async {}

  @override
  Future<void> onTurnEnd(GameContext context) async {}

  @override
  Future<void> ownerTransfer(GameContext context, Character newOwner) async {
    owner = newOwner;
  }
}

class StatusFrost extends BaseStatus {
  StatusFrost() : super('status_frost');
}

class StatusFrozen extends BaseStatus {
  StatusFrozen() : super('status_frozen');
}

class StatusDreaming extends BaseStatus {
  StatusDreaming() : super('status_dreaming');
}

class StatusStellula extends BaseStatus {
  StatusStellula() : super('status_stellula');
}

class StatusStrength extends BaseStatus {
  StatusStrength() : super(StatusId.strength.id, stacking: StatusStacking.add);

  Modifier? _attackModifier;

  @override
  Future<void> onAttached(GameContext context) => _refreshModifier();

  @override
  Future<void> onChanged(GameContext context) => _refreshModifier();

  @override
  Future<void> onRemoved(GameContext context) async {
    final modifier = _attackModifier;
    if (modifier != null) {
      owner.removeModifier(modifier);
      _attackModifier = null;
    }
  }

  Future<void> _refreshModifier() async {
    final previous = _attackModifier;
    if (previous != null) {
      owner.removeModifier(previous);
    }
    if (intensity == 0) {
      _attackModifier = null;
      return;
    }
    final modifier = ModifierImpl(
      PropertyType.attack,
      5 * intensity,
      ModifierType.additive,
    );
    owner.applyModifier(modifier);
    _attackModifier = modifier;
  }
}
