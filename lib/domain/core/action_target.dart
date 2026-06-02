import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';

abstract class ActionTarget {
  // 标记接口
}

class CharacterTarget implements ActionTarget {
  final Character character;
  CharacterTarget(this.character);
}

class PlayerTarget implements ActionTarget {
  final Player player;
  PlayerTarget(this.player);
}

class AllCharactersTarget implements ActionTarget {}

