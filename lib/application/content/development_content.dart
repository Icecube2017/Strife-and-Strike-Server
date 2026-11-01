import 'package:sns_server/domain/kernel/kernel.dart';

/// Explicit local development content, not a claim of full assets support.
/// Replace this injected catalog when real executable content is authored.
ContentCatalog developmentCatalog() => ContentCatalog(
  version: 'development-v1',
  templates: const [
    TemplateDefinition(id: 'balanced', hp: 1350, attack: 95, defense: 35),
  ],
  races: const [
    RaceDefinition(id: 'human', initialMp: 2, maxMp: 5, regenMp: 2),
  ],
  characters: [
    CharacterDefinition(
      id: 'practice',
      templateId: 'balanced',
      raceId: 'human',
    ),
  ],
  cards: [
    CardDefinition(id: 'blade', effects: const [ModifyStat(Stat.attack, 10)]),
    CardDefinition(
      id: 'healing',
      attacks: false,
      effects: const [HealEffect(120)],
    ),
  ],
  skills: [
    SkillDefinition(
      id: 'practice_heal',
      cooldown: 2,
      effects: const [HealEffect(100)],
    ),
    SkillDefinition(
      id: 'practice_shield',
      cooldown: 2,
      effects: const [ShieldEffect(100)],
    ),
    SkillDefinition(
      id: 'practice_hit',
      cooldown: 2,
      minTargets: 1,
      effects: const [DamageEffect(60)],
    ),
    SkillDefinition(
      id: 'practice_draw',
      cooldown: 2,
      effects: const [DrawEffect(1)],
    ),
  ],
);

List<String> developmentDeck() => [
  for (var i = 0; i < 20; i++) ...['blade', 'healing'],
];
List<String> developmentSkillPool() => [
  for (var i = 0; i < 2; i++) ...[
    'practice_heal',
    'practice_shield',
    'practice_hit',
    'practice_draw',
  ],
];
