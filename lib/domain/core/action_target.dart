import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';

/// Describes a target at action declaration time.
///
/// A target may be a concrete entity or a selector that expands to several
/// characters when the action is resolved.
abstract class ActionTarget {}

class CharacterTarget implements ActionTarget {
  final Character character;
  CharacterTarget(this.character);
}

class PlayerTarget implements ActionTarget {
  final Player player;
  PlayerTarget(this.player);
}

class AllCharactersTarget implements ActionTarget {}

/// Selects every character whose owner's team differs from the source team.
///
/// This selector requires a [CharacterTarget] or [PlayerTarget] source so the
/// resolver can determine which team is hostile.
class AllEnemiesTarget implements ActionTarget {}

/// Selects every character whose owner's team matches the source team.
///
/// This selector requires a [CharacterTarget] or [PlayerTarget] source.
class AllAlliesTarget implements ActionTarget {}

/// Selects all allies other than the source character.
///
/// This selector requires a [CharacterTarget] source because a player source
/// does not identify one character to exclude.
class AllAlliesExceptSelfTarget implements ActionTarget {}
