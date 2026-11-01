/// HTTP sends codes and numeric/ID parameters; client owns all wording.
Map<String, Object?> apiError(Object error, {String? code}) {
  final message = switch (error) {
    final StateError e => e.message,
    final FormatException e => e.message,
    final ArgumentError e => e.message?.toString() ?? '',
    _ => '',
  };
  final mp = RegExp(
    r'^Insufficient MP: actor=([^,]+), current=(-?\d+), required=(-?\d+), minimum=(-?\d+)$',
  ).firstMatch(message);
  if (code == null && mp != null) {
    return {
      'success': false,
      'errorCode': 'insufficientMp',
      'params': {
        'actorId': mp[1],
        'current': int.parse(mp[2]!),
        'required': int.parse(mp[3]!),
        'minimum': int.parse(mp[4]!),
      },
    };
  }
  final resolved =
      code ??
      switch (message) {
        'Game already finished' => 'gameFinished',
        'Only the host can abort' => 'hostRequired',
        'Only the host can close' => 'hostRequired',
        'Only the host can start' => 'hostRequired',
        'Only the host can change room settings' => 'hostRequired',
        'Only the host can begin selection' => 'hostRequired',
        'Player is not a room member' => 'roomNotMember',
        'Room is not accepting players' => 'roomClosed',
        'Player already joined' => 'alreadyJoined',
        'Room is full' => 'roomFull',
        'Room settings are locked' => 'roomSettingsLocked',
        'Teams are locked' => 'teamsLocked',
        'Invalid team for room mode' => 'invalidTeam',
        'Character selection is not complete' => 'selectionIncomplete',
        'Characters or teams are incomplete' => 'teamsIncomplete',
        'At least two players are required' => 'notEnoughPlayers',
        'Draft already started' => 'draftStarted',
        'All players must choose a team' => 'teamSelectionRequired',
        'Every configured team needs a member' => 'emptyTeam',
        'Not enough playable characters' => 'notEnoughCharacters',
        'Ban quota could leave too few characters' => 'invalidBanQuota',
        'Invalid Ban quota' => 'invalidBanQuota',
        'Invalid Ban selection' => 'invalidBanSelection',
        'Character is already banned' => 'characterAlreadyBanned',
        'Ban is already confirmed' => 'banConfirmed',
        'Not a Ban phase' => 'notBanPhase',
        'Not a character selection phase' => 'notSelectionPhase',
        'Character is already confirmed' => 'characterConfirmed',
        'Character is unavailable' => 'characterUnavailable',
        'Room is not in a game' => 'roomNotInGame',
        'Command ID reused with different content' => 'commandIdReused',
        'Player is dead' => 'playerDead',
        'No actions remaining' => 'noActionsRemaining',
        'Game is being aborted' => 'gameAborting',
        'Skill is on cooldown' => 'skillCooldown',
        'Invalid or stale choice' => 'invalidChoice',
        'Card instance is not owned' => 'cardNotOwned',
        'Card instance is disabled' => 'cardDisabled',
        'Skills are blocked' => 'skillsBlocked',
        'Invalid MP cost' => 'invalidMpCost',
        _ when message.startsWith('Invalid MP cost:') => 'invalidMpCost',
        _ when error is FormatException || error is ArgumentError =>
          'invalidRequest',
        _ when message.startsWith('Unknown') => 'notFound',
        _ when message.startsWith('Version conflict') => 'versionConflict',
        _ when RegExp(r'^[a-z][A-Za-z0-9]*$').hasMatch(message) => message,
        _ => 'operationRejected',
      };
  return {'success': false, 'errorCode': resolved};
}
