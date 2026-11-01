import 'package:sns_kernel/src/definitions.dart';
import 'package:sns_kernel/src/mechanisms/choice_host.dart';
import 'package:sns_kernel/src/state.dart';

abstract interface class SkillBorrowHost implements MechanismChoiceHost {
  Iterable<PlayerInstance> get players;
  int get round;
  AnchorExpiry? naturalExpiry(int rounds);
  bool naturalExpiryDue(AnchorExpiry expiry, {bool atEnd});
  String nextId(String prefix);
  void draw(CharacterInstance actor, int count);
}

final class SkillLease {
  SkillLease(
    this.owner,
    this.original,
    this.borrower,
    this.copy,
    this.expires, {
    this.anchor,
  });
  final CharacterInstance owner;
  final SkillInstance original;
  final CharacterInstance borrower;
  final SkillInstance copy;
  final int expires;
  AnchorExpiry? anchor;
}

final class SkillBorrowModule {
  SkillBorrowModule(this.host);
  final SkillBorrowHost host;
  final List<SkillLease> _skillLeases = [];
  void offer(
    CharacterInstance borrower, {
    SkillBorrowRule rule = const SkillBorrowRule(),
    void Function()? complete,
  }) {
    if (!borrower.alive || host.traitsBlocked(borrower)) {
      complete?.call();
      return;
    }
    final choices = <String, (CharacterInstance, SkillInstance)>{};
    for (final player in host.players) {
      final owner = player.character;
      if (!owner.alive || identical(owner, borrower)) continue;
      for (final skill in owner.skills) {
        if ((!rule.revealedOnly || skill.revealed) &&
            (rule.allowExclusive || !skill.definition.exclusive) &&
            !skill.leasedOut &&
            !skill.borrowed) {
          choices[skill.instanceId] = (owner, skill);
        }
      }
    }
    host.choose(
      borrower,
      [
        {'action': 'skip'},
        if (rule.drawCount > 0) {'action': 'draw'},
        for (final e in choices.entries)
          {
            'action': 'borrow',
            'instanceId': e.key,
            'targetId': e.value.$1.instanceId,
            'definitionId': e.value.$2.definition.id,
          },
      ],
      (o) {
        if (o['action'] == 'draw') {
          host.draw(borrower, rule.drawCount);
          complete?.call();
          return;
        }
        if (o['action'] != 'borrow') {
          complete?.call();
          return;
        }
        final (owner, original) = choices[o['instanceId']]!;
        final copy = SkillInstance(host.nextId('skill'), original.definition)
          ..borrowed = true
          ..revealed = true
          ..cooldown = original.cooldown
          ..uses = original.uses
          ..remainingUses = original.remainingUses;
        original.leasedOut = true;
        borrower.skills.add(copy);
        _skillLeases.add(
          SkillLease(
            owner,
            original,
            borrower,
            copy,
            host.round + rule.durationRounds,
            anchor: rule.clock == DurationClock.anchoredRound
                ? host.naturalExpiry(rule.durationRounds)
                : null,
          ),
        );
        host.emit('skillBorrowed', {
          'actorId': borrower.instanceId,
          'targetId': owner.instanceId,
          'definitionId': copy.definition.id,
          'instanceId': copy.instanceId,
        });
        complete?.call();
      },
    );
  }

  void remapAnchors(AnchorExpiry Function(AnchorExpiry) remap) {
    for (final lease in _skillLeases) {
      if (lease.anchor != null) lease.anchor = remap(lease.anchor!);
    }
  }

  void expire({bool natural = false, bool atEnd = false}) {
    for (final lease in _skillLeases.toList()) {
      if (lease.anchor case final anchor?) {
        if (!natural || !host.naturalExpiryDue(anchor, atEnd: atEnd)) continue;
      } else if (natural || lease.expires > host.round) {
        continue;
      }
      lease.original.leasedOut = false;
      lease.borrower.skills.remove(lease.copy);
      _skillLeases.remove(lease);
      host.emit('skillReturned', {
        'actorId': lease.borrower.instanceId,
        'targetId': lease.owner.instanceId,
        'definitionId': lease.original.definition.id,
      });
    }
  }
}
