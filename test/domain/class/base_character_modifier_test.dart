import 'package:sns_server/domain/class/character.dart';
import 'package:sns_server/domain/core/core.dart';
import 'package:sns_server/domain/core/enum.dart';
import 'package:sns_server/domain/data/ids.dart';
import 'package:test/test.dart';

void main() {
  group('BaseCharacter modifiers', () {
    test('applyModifier and removeModifier can add and rollback attack', () {
      final character = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      )..attack = 20;
      final modifier = ModifierImpl(
        PropertyType.attack,
        10,
        ModifierType.additive,
      );

      character.applyModifier(modifier);

      expect(character.attack, 30);
      expect(character.modifiers, contains(same(modifier)));

      character.removeModifier(modifier);

      expect(character.attack, 20);
      expect(character.modifiers, isNot(contains(same(modifier))));
    });

    test(
      'applyModifier and removeModifier can rollback multiplicative changes',
      () {
        final character = BaseCharacter(
          'char_actor',
          TemplateId.defensive.id,
          RaceId.human.id,
          const {},
          [],
          [],
        )..attack = 20;
        final modifier = ModifierImpl(
          PropertyType.attack,
          2,
          ModifierType.multiplicative,
        );

        character.applyModifier(modifier);
        expect(character.attack, 40);

        character.removeModifier(modifier);
        expect(character.attack, 20);
      },
    );

    test('applyModifier and removeModifier can restore overridden values', () {
      final character = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      )..defense = 8;
      final modifier = ModifierImpl(
        PropertyType.defense,
        99,
        ModifierType.override,
      );

      character.applyModifier(modifier);
      expect(character.defense, 99);

      character.removeModifier(modifier);
      expect(character.defense, 8);
    });

    test('resolves additive modifiers before multiplicative modifiers', () {
      final character = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      )..attack = 20;
      final multiplier = ModifierImpl(
        PropertyType.attack,
        2,
        ModifierType.multiplicative,
      );
      final bonus = ModifierImpl(
        PropertyType.attack,
        5,
        ModifierType.additive,
      );

      character
        ..applyModifier(multiplier)
        ..applyModifier(bonus);

      expect(character.attack, 50);

      character.removeModifier(bonus);
      expect(character.attack, 40);
      character.removeModifier(multiplier);
      expect(character.attack, 20);
    });

    test('uses the highest override regardless of other modifiers', () {
      final character = BaseCharacter(
        'char_actor',
        TemplateId.defensive.id,
        RaceId.human.id,
        const {},
        [],
        [],
      )..defense = 8;
      final bonus = ModifierImpl(
        PropertyType.defense,
        10,
        ModifierType.additive,
      );
      final lowOverride = ModifierImpl(
        PropertyType.defense,
        50,
        ModifierType.override,
      );
      final highOverride = ModifierImpl(
        PropertyType.defense,
        99,
        ModifierType.override,
      );

      character
        ..applyModifier(bonus)
        ..applyModifier(lowOverride)
        ..applyModifier(highOverride);
      expect(character.defense, 99);

      character.removeModifier(highOverride);
      expect(character.defense, 50);
      character.removeModifier(lowOverride);
      expect(character.defense, 18);
    });

    test('maps damage and heal statistic properties through PropertyType', () {
      final character =
          BaseCharacter(
              'char_actor',
              TemplateId.defensive.id,
              RaceId.human.id,
              const {},
              [],
              [],
            )
            ..damageStats.dealtByTurn = 3
            ..healStats.receivedTotal = 4;
      final dealtModifier = ModifierImpl(
        PropertyType.damageDealtByTurn,
        2,
        ModifierType.additive,
      );
      final healedModifier = ModifierImpl(
        PropertyType.healReceivedTotal,
        6,
        ModifierType.additive,
      );

      character
        ..applyModifier(dealtModifier)
        ..applyModifier(healedModifier);

      expect(character.damageStats.dealtByTurn, 5);
      expect(character.healStats.receivedTotal, 10);
    });
  });
}
