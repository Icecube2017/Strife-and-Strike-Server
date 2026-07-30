import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/class/player.dart';
import 'package:sns_server/domain/core/action_target.dart';
import 'package:sns_server/domain/core/game_context.dart';

/// Expands semantic action targets into the concrete character targets that
/// effects and game events operate on.
class TargetResolver {
  TargetResolver(this._context);

  final GameContext _context;

  List<CharacterTarget> resolve(
    ActionTarget target, {
    ActionTarget? source,
  }) {
    switch (target) {
      case CharacterTarget():
        return [target];
      case PlayerTarget(:final player):
        return player.characters.map(CharacterTarget.new).toList();
      case AllCharactersTarget():
        return _context
            .getAllPlayers()
            .expand((player) => player.characters)
            .map(CharacterTarget.new)
            .toList();
      case AllEnemiesTarget():
        final sourcePlayer = _resolveSourcePlayer(source);
        return _context
            .getAllPlayers()
            .where((player) => player.teamId != sourcePlayer.teamId)
            .expand((player) => player.characters)
            .map(CharacterTarget.new)
            .toList();
      case AllAlliesTarget():
        final sourcePlayer = _resolveSourcePlayer(source);
        return _context
            .getAllPlayers()
            .where((player) => player.teamId == sourcePlayer.teamId)
            .expand((player) => player.characters)
            .map(CharacterTarget.new)
            .toList();
      case AllAlliesExceptSelfTarget():
        final sourceCharacter = _resolveSourceCharacter(source);
        return resolve(AllAlliesTarget(), source: source)
            .where(
              (target) => !identical(target.character, sourceCharacter),
            )
            .toList();
      default:
        throw UnsupportedError('Unsupported action target: $target');
    }
  }

  Player _resolveSourcePlayer(ActionTarget? source) {
    return switch (source) {
      PlayerTarget(:final player) => player,
      CharacterTarget(:final character) => _context.getAllPlayers().firstWhere(
        (player) => player.characters.contains(character),
        orElse: () => throw StateError(
          'Source character ${character.id} does not belong to a player',
        ),
      ),
      _ => throw StateError(
        'Team target requires a CharacterTarget or PlayerTarget source',
      ),
    };
  }

  Character _resolveSourceCharacter(ActionTarget? source) {
    return switch (source) {
      CharacterTarget(:final character) => character,
      _ => throw StateError(
        'AllAlliesExceptSelfTarget requires a CharacterTarget source',
      ),
    };
  }
}
