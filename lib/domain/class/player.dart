import 'package:sns_server/domain/class/character.dart';

class Player {
  final String id;
  final String name;
  final List<Character> characters; // 支持多角色
  Character currentCharacter;
  // 队伍标识，用于团队战
  int teamId;
  
  Player(this.id, this.name, this.characters, this.teamId) : currentCharacter = characters[0];
}
