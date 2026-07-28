import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/game_context.dart';
import 'package:sns_server/domain/core/game_event.dart';

/// 接口
abstract class Status extends Identifiable {
  Character get owner;
  int get stacks;
  int get intensity;

  Future<void> onTurnStart(GameContext context, Character owner);
  Future<void> onTurnEnd(GameContext context, Character owner);
  Future<void> setStatus(GameContext context, List<int> value);
  Future<void> ownerTransfer(GameContext context, Character newOwner);
}

enum StatusStacking {
  max, // 取最高强度，层数累加
  add, // 强度和层数直接相加
}

// 隐藏状态，和Status实现逻辑一致
abstract class Stuff extends Identifiable {
  int get stacks;
  int get intensity;
  int get value;
  String get text;
}

class BaseStatus implements Status{
  @override
  final String id;
  @override
  late Character owner;
  @override
  int stacks = 0;
  @override
  int intensity = 0;

  BaseStatus(
    this.id,
  );

  @override
  Future<void> onTurnStart(GameContext context, Character owner) async {
    // TODO: implement onTurnStart
    throw UnimplementedError();
  }

  @override
  Future<void> onTurnEnd(GameContext context, Character owner) async {
    stacks -= 1;
    context.eventBus.emit(StatusDecayedEvent(context));
    if (stacks == 0) {
      context.eventBus.emit(StatusDroppedEvent(context));
    }
  }

  @override
  Future<void> setStatus(GameContext context, List<int> value) async {
    stacks = value[0];
    intensity = value[1];
    // TODO: implement stack
    throw UnimplementedError();
  }

  @override
  Future<void> ownerTransfer(GameContext context, Character newOwner) async {
    owner = newOwner;
    return;
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
