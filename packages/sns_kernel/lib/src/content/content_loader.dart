import 'dart:convert';
import 'package:sns_kernel/src/content/content_syntax.dart';
import 'package:sns_kernel/src/kernel.dart';

part 'query_loader.dart';

/// Executable content is explicitly authored; wiki prose is never executed.
/// This adapter has no IO and performs no external wiki/schema verification.
final class ExecutableContent {
  ExecutableContent(
    this.catalog,
    this.decks,
    this.selectedDeck,
    this.skillPool,
  );

  final ContentCatalog catalog;
  final Map<String, CardPack> decks;
  final CardPack selectedDeck;
  List<String> get deck => selectedDeck.expand();
  final List<String> skillPool;

  /// Explicit development subset; the configured deck always keeps every card.
  List<String> get playableDeck =>
      List.unmodifiable(deck.where(catalog.cards.containsKey));

  Map<String, int> get unsupportedDeckCards {
    final counts = <String, int>{};
    for (final id in deck.where((id) => !catalog.cards.containsKey(id))) {
      counts.update(id, (n) => n + 1, ifAbsent: () => 1);
    }
    return Map.unmodifiable(counts);
  }

  factory ExecutableContent.decode(String source, {String? deckId}) {
    final root = compileContentSyntax(
      jsonDecode(source) as Map<String, dynamic>,
    );
    if (root['resourceAbilitiesVersion'] != null &&
        root['resourceAbilitiesVersion'] != 1) {
      throw const FormatException('Unsupported resource abilities version');
    }
    for (final raw in root['traits'] as List? ?? []) {
      final row = raw as Map<String, dynamic>;
      final modules = row.remove('mechanisms');
      if (modules == null) continue;
      if (modules is! Map<String, dynamic>) {
        throw const FormatException('Trait mechanisms must be an object');
      }
      for (final entry in modules.entries) {
        final field = _mechanismFields[entry.key];
        if (field == null) {
          throw FormatException('Unknown trait mechanism: ${entry.key}');
        }
        if (row.containsKey(field)) {
          throw FormatException('Duplicate trait mechanism: ${entry.key}');
        }
        row[field] = entry.value;
      }
    }
    if (root['formatVersion'] != 2) {
      throw const FormatException('Unsupported executable content format');
    }
    final catalog = ContentCatalog(
      version: root['version'] as String,
      variables: _rows(root, 'variables').map(
        (v) => VariableDefinition(
          id: v['id'] as String,
          namespace: v['namespace'] as String,
          type: VariableType.values.byName(v['type'] as String),
          scope: VariableScope.values.byName(v['scope'] as String? ?? 'owner'),
          visibility: VariableVisibility.values.byName(
            v['visibility'] as String? ?? 'owner',
          ),
          reset: CounterReset.values.byName(v['reset'] as String? ?? 'never'),
          initial: v['initial'],
          maxEntries: _integer(v, 'maxEntries', 128),
          minimum: v['minimum'] as num?,
          maximum: v['maximum'] as num?,
        ),
      ),
      templates: _rows(root, 'templates').map(
        (d) => TemplateDefinition(
          id: d['id'] as String,
          hp: d['hp'] as int,
          attack: d['attack'] as int,
          defense: d['defense'] as int,
        ),
      ),
      races: _rows(root, 'races').map(
        (d) => RaceDefinition(
          id: d['id'] as String,
          initialMp: d['initialMp'] as int,
          maxMp: d['maxMp'] as int,
          regenMp: d['regenMp'] as int,
          initialMpValue: _value(d, 'initialMpValue'),
          regenMpValue: _value(d, 'regenMpValue'),
          counters: _counters(d),
          triggers: _triggers(d),
          regenInterval: _integer(d, 'regenInterval', 1),
          regenPhase: MpRegenPhase.values.byName(
            d['regenPhase'] as String? ?? 'turnStart',
          ),
          regenMode: MpRegenMode.values.byName(
            d['regenMode'] as String? ?? 'periodic',
          ),
        ),
      ),
      characters: _rows(root, 'characters').map(
        (d) => CharacterDefinition(
          id: d['id'] as String,
          templateId: d['templateId'] as String,
          raceId: d['raceId'] as String,
          traits: _strings(d, 'traits'),
          skills: _strings(d, 'skills'),
        ),
      ),
      traits: _rows(root, 'traits').map(
        (d) => TraitDefinition(
          mechanisms: _decodeMechanismBindings(d),
          id: d['id'] as String,
          onHit: _effects(d, 'onHit'),
          attackModifiers: _rows(
            d,
            'attackModifiers',
          ).map(_attackModifier).toList(),
          borrowAttackCard: _bool(d, 'borrowAttackCard'),
          cardMaxTagDiscount: _bool(d, 'cardMaxTagDiscount'),
          actionMpDiscount: _integer(d, 'actionMpDiscount'),
          openingSkillBonus: _integer(d, 'openingSkillBonus'),
          attackDiceBonusValue: _value(d, 'attackDiceBonusValue'),
          defaultAttackDiceSides: d['defaultAttackDiceSides'] as int?,
          attackDiceGrowth: d['attackDiceGrowth'] == null
              ? null
              : AttackDiceGrowth(
                  variable:
                      (d['attackDiceGrowth'] as _Json)['variable'] as String,
                  threshold:
                      (d['attackDiceGrowth'] as _Json)['threshold'] as int,
                ),
          cardEffectOverrides: {
            for (final entry
                in (d['cardEffectOverrides'] as _Json? ?? {}).entries)
              entry.key: _effects({'effects': entry.value}, 'effects'),
          },
          freeCardTags: _strings(d, 'freeCardTags').toSet(),
          refundNonDamagingAction: _bool(d, 'refundNonDamagingAction'),
          statusGainMultipliers: (d['statusGainMultipliers'] as _Json? ?? {})
              .cast<String, int>(),
          waiveSkillSurcharge: _bool(d, 'waiveSkillSurcharge'),
          damageGuards: _rows(d, 'damageGuards').map(_damageGuard).toList(),
          resourceAbilities: _resourceAbilities(
            d,
            legacy: root['resourceAbilitiesVersion'] == null,
          ),
          resourcePolicy: ResourcePolicy.values.byName(
            d['resourcePolicy'] as String? ?? 'normal',
          ),
          markStatBonuses: _rows(d, 'markStatBonuses')
              .map(
                (b) => MarkStatBonus(
                  markId: b['markId'] as String,
                  modifiersPerCount: _stats(b, 'modifiersPerCount'),
                  fromSelf: b['fromSelf'] as bool? ?? true,
                ),
              )
              .toList(),
          statusStatBonuses: _rows(d, 'statusStatBonuses')
              .map(
                (b) => StatusStatBonus(
                  allStatuses: _strings(b, 'allStatuses'),
                  modifiers: _stats(b, 'modifiers'),
                ),
              )
              .toList(),
          attackDuel: d['attackDuel'] == null
              ? null
              : _attackDuel(d['attackDuel'] as _Json),
          modifiers: _stats(d, 'modifiers'),
          attackHpThreshold: (d['attackHpThreshold'] as num?)?.toDouble(),
          attackDamageMultiplier: _number(d, 'attackDamageMultiplier', 1),
          damageRewrite: d['damageRewrite'] as int?,
          healingRewrite: d['healingRewrite'] as int?,
          healingRewriteIgnoresModifiers: _bool(
            d,
            'healingRewriteIgnoresModifiers',
          ),
          healingRewriteBlockedBy: d['healingRewriteBlockedBy'] == null
              ? null
              : _statusQuery(d['healingRewriteBlockedBy'] as _Json),
          damageAura: d['damageAura'] == null
              ? null
              : DamageAura(
                  scope: EffectTarget.values.byName(
                    (d['damageAura'] as _Json)['scope'] as String? ?? 'all',
                  ),
                  when: _condition((d['damageAura'] as _Json)['when']),
                  factor: _number(d['damageAura'] as _Json, 'factor', 1),
                  flat: _integer(d['damageAura'] as _Json, 'flat'),
                ),
          outgoingDuel: d['outgoingDuel'] == null
              ? null
              : OutgoingDuel(
                  victory: _effects(d['outgoingDuel'] as _Json, 'victory'),
                  after: _effects(d['outgoingDuel'] as _Json, 'after'),
                ),
          immuneStatuses: _strings(d, 'immuneStatuses'),
          endMarkChoices: _strings(d, 'endMarkChoices'),
          endMarkCount: _integer(d, 'endMarkCount', 1),
          active: d['active'] == null
              ? null
              : _traitAction(d['active'] as _Json),
          attackStatuses: _rows(d, 'attackStatuses')
              .map(
                (r) => AttackStatusRule(
                  statusId: r['statusId'] as String,
                  stacks: _integer(r, 'stacks', 1),
                  intensity: _integer(r, 'intensity', 1),
                  tags: _strings(r, 'tags'),
                  tagStacks: _integer(r, 'tagStacks'),
                  tagIntensity: _integer(r, 'tagIntensity'),
                ),
              )
              .toList(),
          battleContinuation: _bool(d, 'battleContinuation'),
          battleContinuationThroughRound:
              d['battleContinuationThroughRound'] as int?,
          incomingDamageMultiplier: _number(d, 'incomingDamageMultiplier', 1),
          rerollOfferCost: d['rerollOfferCost'] as int?,
          suppressedCardTags: _strings(d, 'suppressedCardTags').toSet(),
          suppressedCardMinTags: d['suppressedCardMinTags'] as int?,
          attackCompanionTags: _strings(d, 'attackCompanionTags').toSet(),
          healingForbidden: _bool(d, 'healingForbidden'),
          continuationRecoverySides: d['continuationRecoverySides'] as int?,
          continuationRecoverySuccess:
              (d['continuationRecoverySuccess'] as List? ?? const [])
                  .cast<int>(),
          triggers: _triggers(d),
          attackDiceRule: d['attackDiceRule'] == null
              ? null
              : _attackDiceRule(d['attackDiceRule'] as _Json),
          attackFormula: d['attackFormula'] == null
              ? null
              : AttackFormula(
                  kind: DamageKind.values.byName(
                    (d['attackFormula'] as _Json)['kind'] as String? ?? 'real',
                  ),
                  attackOffset: _integer(
                    d['attackFormula'] as _Json,
                    'attackOffset',
                  ),
                ),
          incomingAttackTargetWhen: _condition(d['incomingAttackTargetWhen']),
          incomingAttack: d['incomingAttack'] == null
              ? null
              : _incomingAttack(d['incomingAttack'] as _Json),
          attackAura: d['attackAura'] == null
              ? null
              : _attackAura(d['attackAura'] as _Json),
          attackDiceSequence: d['attackDiceSequence'] == null
              ? null
              : _attackDiceSequence(d['attackDiceSequence'] as _Json),
          counters: _counters(d),
        ),
      ),
      cards: _rows(root, 'cards').map(
        (d) => CardDefinition(
          response: d['response'] == null
              ? null
              : CardResponse.values.byName(d['response'] as String),
          id: d['id'] as String,
          mirrorCardId: d['mirrorCardId'] as String?,
          onHit: _effects(d, 'onHit'),
          mpCost: _integer(d, 'mpCost', 1),
          actionCostBonus: _integer(d, 'actionCostBonus'),
          attackModifiers: _rows(
            d,
            'attackModifiers',
          ).map(_attackModifier).toList(),
          attacks: d['attacks'] as bool? ?? true,
          isLimited: _bool(d, 'isLimited'),
          attacksWithCardIds: _strings(d, 'attacksWithCardIds').toSet(),
          statusStackMultipliers:
              (d['statusStackMultipliers'] as Map<String, dynamic>? ?? {}).map(
                (key, value) => MapEntry(key, value as int),
              ),
          effects: _effects(d, 'effects'),
          tags: _strings(d, 'tags').toSet(),
          attackBonus: _integer(d, 'attackBonus'),
          defenseBonus: _integer(d, 'defenseBonus'),
          attackMultiplier: _number(d, 'attackMultiplier', 1),
          defenseMultiplier: _number(d, 'defenseMultiplier', 1),
          finalDamageBonus: _integer(d, 'finalDamageBonus'),
          finalDamageMultiplier: _number(d, 'finalDamageMultiplier', 1),
          diceSides: d['diceSides'] as int?,
          reinforcedDiceSides: d['reinforcedDiceSides'] as int?,
          diceBonus: _integer(d, 'diceBonus'),
          ignoreDefense: _bool(d, 'ignoreDefense'),
          ignoreDodge: _bool(d, 'ignoreDodge'),
          clearDodge: _bool(d, 'clearDodge'),
          clearShield: _bool(d, 'clearShield'),
          damageKind: DamageKind.values.byName(
            d['damageKind'] as String? ?? 'physical',
          ),
          piercesContinuation: _bool(d, 'piercesContinuation'),
        ),
      ),
      skills: _rows(root, 'skills').map(
        (d) => SkillDefinition(
          id: d['id'] as String,
          markCosts: _rows(d, 'markCosts')
              .map((c) => MarkCost(c['markId'] as String, c['amount'] as int))
              .toList(),
          cooldown: _integer(d, 'cooldown'),
          cooldownValue: _value(d, 'cooldownValue'),
          cooldownBranches: _rows(d, 'cooldownBranches')
              .map(
                (b) => CooldownBranch(
                  _condition(b['when'])!,
                  _integer(b, 'cooldown'),
                ),
              )
              .toList(),
          anytime: _bool(d, 'anytime'),
          preselectAll: _bool(d, 'preselectAll'),
          beforeAttack: _bool(d, 'beforeAttack'),
          beforeCards: _bool(d, 'beforeCards'),
          excludeSelfTarget: _bool(d, 'excludeSelfTarget'),
          lifeCost: _integer(d, 'lifeCost'),
          lifeCostValue: _value(d, 'lifeCostValue'),
          numberParameter: d['numberParameter'] == null
              ? null
              : NumberParameter(
                  allowedValues:
                      ((d['numberParameter'] as Map)['allowedValues']
                                  as List? ??
                              [])
                          .cast<int>(),
                  markCostId:
                      (d['numberParameter'] as Map)['markCostId'] as String?,
                  countTargets: _bool(
                    Map<String, dynamic>.from(d['numberParameter'] as Map),
                    'countTargets',
                  ),
                  minimum: _integer(
                    Map<String, dynamic>.from(d['numberParameter'] as Map),
                    'minimum',
                    1,
                  ),
                  maximum: _integer(
                    Map<String, dynamic>.from(d['numberParameter'] as Map),
                    'maximum',
                    10000,
                  ),
                  maximumValue: _value(
                    Map<String, dynamic>.from(d['numberParameter'] as Map),
                    'maximumValue',
                  ),
                  mpCostPerUnit: _integer(
                    Map<String, dynamic>.from(d['numberParameter'] as Map),
                    'mpCostPerUnit',
                  ),
                  lifeCostPerUnit: _integer(
                    Map<String, dynamic>.from(d['numberParameter'] as Map),
                    'lifeCostPerUnit',
                  ),
                ),
          checkpoint: d['checkpoint'] == null
              ? null
              : _checkpoint(Map<String, dynamic>.from(d['checkpoint'] as Map)),
          mpSurcharge: _integer(d, 'mpSurcharge'),
          mpCost: _integer(d, 'mpCost'),
          when: _condition(d['when']),
          targetWhen: _condition(d['targetWhen']),
          statCosts: _stats(d, 'statCosts'),
          passive: _bool(d, 'passive'),
          triggers: _triggers(d),
          counters: _counters(d),
          exclusive: _bool(d, 'exclusive'),
          copyPolicy: SkillCopyPolicy(
            allowExclusive:
                (d['copyPolicy'] as _Json?)?['allowExclusive'] as bool? ?? true,
            allowRepeat:
                (d['copyPolicy'] as _Json?)?['allowRepeat'] as bool? ?? false,
          ),
          replayPolicy: ReplayPolicy(
            damageFactor: _number(
              d['replayPolicy'] as _Json? ?? {},
              'damageFactor',
              .5,
            ),
            healingFactor: _number(
              d['replayPolicy'] as _Json? ?? {},
              'healingFactor',
              .25,
            ),
          ),
          mechanism: SkillMechanism.values.byName(
            d['mechanism'] as String? ?? 'ordinary',
          ),
          timing: SkillTiming.values.byName(d['timing'] as String? ?? 'main'),
          minTargets: _integer(d, 'minTargets'),
          maxTargets: _integer(d, 'maxTargets', 1),
          effects: _effects(d, 'effects'),
        ),
      ),
      marks: _rows(root, 'marks').map(
        (d) => MarkDefinition(
          id: d['id'] as String,
          maxCount: d['maxCount'] as int?,
          playerCountBonus: d['playerCountBonus'] as int?,
          sourceScoped: d['sourceScoped'] as bool? ?? true,
          visibility: MarkVisibility.values.byName(
            d['visibility'] as String? ?? 'public',
          ),
          group: d['group'] as String?,
          groupLimit: d['groupLimit'] as int?,
        ),
      ),
      statuses: _rows(root, 'statuses').map(
        (d) => StatusDefinition(
          neutral: _bool(d, 'neutral'),
          isStatusEffect: d['isStatusEffect'] as bool? ?? true,
          exclusiveGroup: d['exclusiveGroup'] as String?,
          expireOnAction: _bool(d, 'expireOnAction'),
          category: StatusCategory.values.byName(
            d['category'] as String? ?? 'normal',
          ),
          hasIntensity: d['hasIntensity'] as bool? ?? true,
          swapBaseAttackDefense: _bool(d, 'swapBaseAttackDefense'),
          blockNegative: _bool(d, 'blockNegative'),
          consumeOnNegative: _bool(d, 'consumeOnNegative'),
          cleanseNegativeOnApply: _bool(d, 'cleanseNegativeOnApply'),
          redirectAllies: _bool(d, 'redirectAllies'),
          attackDicePerIntensity: _integer(d, 'attackDicePerIntensity'),
          attackFlatPerIntensity: _integer(d, 'attackFlatPerIntensity'),
          outgoingPhysicalFlatPerIntensity: _integer(
            d,
            'outgoingPhysicalFlatPerIntensity',
          ),
          mpRecoveryFlatPerIntensity: _integer(d, 'mpRecoveryFlatPerIntensity'),
          active: d['active'] == null
              ? null
              : _statusAction(d['active'] as _Json),
          damageGuards: _rows(d, 'damageGuards').map(_damageGuard).toList(),
          triggers: _triggers(d),
          counters: _counters(d),
          id: d['id'] as String,
          onHit: _effects(d, 'onHit'),
          decay: StatusDecay.values.byName(
            d['decay'] as String? ?? 'anchoredRound',
          ),
          maxStacks: d['maxStacks'] as int?,
          maxIntensity: d['maxIntensity'] as int?,
          opposingStatusId: d['opposingStatusId'] as String?,
          addIntensity: _bool(d, 'addIntensity'),
          negative: _bool(d, 'negative'),
          dodge: _bool(d, 'dodge'),
          actionFailureSides: d['actionFailureSides'] as int?,
          invulnerable: _bool(d, 'invulnerable'),
          battleContinuation: _bool(d, 'battleContinuation'),
          blockAttack: _bool(d, 'blockAttack'),
          blockCards: _bool(d, 'blockCards'),
          blockSkills: _bool(d, 'blockSkills'),
          blockTraits: _bool(d, 'blockTraits'),
          blockDraw: _bool(d, 'blockDraw'),
          blockDrawPhase: _bool(d, 'blockDrawPhase'),
          blockAttackCards: _bool(d, 'blockAttackCards'),
          blockMpRegen: _bool(d, 'blockMpRegen'),
          skipTurn: _bool(d, 'skipTurn'),
          blockStatus: _bool(d, 'blockStatus'),
          settleAtAnchor: _bool(d, 'settleAtAnchor'),
          followApplicationPhase: _bool(d, 'followApplicationPhase'),
          ignoreShield: _bool(d, 'ignoreShield'),
          shieldOverflowBarrier: _bool(d, 'shieldOverflowBarrier'),
          attackFactor: _number(d, 'attackFactor', 1),
          healingBonusPerIntensity: _number(d, 'healingBonusPerIntensity'),
          incomingDamageBonusPerIntensity: _number(
            d,
            'incomingDamageBonusPerIntensity',
          ),
          incomingAttackBonusPerIntensity: _number(
            d,
            'incomingAttackBonusPerIntensity',
          ),
          outgoingAttackBonusPerIntensity: _number(
            d,
            'outgoingAttackBonusPerIntensity',
          ),
          mpRegenPerIntensity: _integer(d, 'mpRegenPerIntensity'),
          actionMpDiscount: _integer(d, 'actionMpDiscount'),
          skillMpSurcharge: _integer(d, 'skillMpSurcharge'),
          traitMpSurcharge: _integer(d, 'traitMpSurcharge'),
          maxHandCap: d['maxHandCap'] as int?,
          cardMpCap: d['cardMpCap'] as int?,
          attackDiceSides: d['attackDiceSides'] as int?,
          consumeOnAttackRoll: _bool(d, 'consumeOnAttackRoll'),
          incomingDefenseBonusPerIntensity: _integer(
            d,
            'incomingDefenseBonusPerIntensity',
          ),
          reinforceFirstCard: _bool(d, 'reinforceFirstCard'),
          modifiersPerIntensity: _stats(d, 'modifiersPerIntensity'),
          turnStart: _effects(d, 'turnStart'),
          turnEnd: _effects(d, 'turnEnd'),
        ),
      ),
    );
    final decks = _readDecks(root['deck']);
    final selectedId = deckId ?? decks.keys.first;
    final selected = decks[selectedId];
    if (selected == null) throw FormatException('Unknown deck ID: $selectedId');
    return ExecutableContent(
      catalog,
      decks,
      selected,
      List.unmodifiable(_strings(root, 'skillPool')),
    );
  }
}

typedef _Json = Map<String, dynamic>;

/// A named card pack. Quantities are definitions, not mutable card instances.
final class CardPack {
  CardPack(this.id, this.name, Map<String, int> content)
    : content = Map.unmodifiable(content);
  final String id;
  final String name;
  final Map<String, int> content;

  List<String> expand() => List.unmodifiable([
    for (final entry in content.entries)
      for (var i = 0; i < entry.value; i++) entry.key,
  ]);
}

Map<String, CardPack> _readDecks(Object? value) {
  if (value is! List || value.isEmpty) {
    throw const FormatException('deck must be a non-empty array of card packs');
  }
  final packs = <String, CardPack>{};
  for (final entry in value) {
    if (entry is! Map<String, dynamic>) {
      throw const FormatException(
        'Deck entry must contain id, name and content',
      );
    }
    final id = entry['id'];
    final name = entry['name'] ?? id;
    final content = entry['content'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        content is! Map<String, dynamic>) {
      throw const FormatException(
        'Deck requires id/name strings and a content object',
      );
    }
    if (packs.containsKey(id)) throw FormatException('Duplicate deck ID: $id');
    final counts = <String, int>{};
    for (final card in content.entries) {
      final amount = card.value;
      if (card.key.trim().isEmpty || amount is! int || amount < 0) {
        throw const FormatException(
          'Deck content must map card UUIDs to non-negative integers',
        );
      }
      counts[card.key] = amount;
    }
    packs[id] = CardPack(id, name, counts);
  }
  return Map.unmodifiable(packs);
}

Iterable<_Json> _rows(_Json d, String key) =>
    (d[key] as List<dynamic>? ?? []).cast<_Json>();
List<String> _strings(_Json d, String key) =>
    (d[key] as List<dynamic>? ?? []).cast<String>();
int _integer(_Json d, String key, [int fallback = 0]) =>
    d[key] is Map ? fallback : d[key] as int? ?? fallback;
double _number(_Json d, String key, [double fallback = 0]) =>
    (d[key] as num?)?.toDouble() ?? fallback;
bool _bool(_Json d, String key) => d[key] as bool? ?? false;
Map<Stat, int> _stats(_Json d, String key) => {
  for (final entry in (d[key] as _Json? ?? {}).entries)
    Stat.values.byName(entry.key): entry.value as int,
};

EffectValue? _value(_Json d, [String key = 'value']) {
  final raw =
      d[key] ??
      (key == 'value' ? d[d['op'] == 'draw' ? 'count' : 'amount'] : null);
  if (raw == null || (key == 'value' && raw is num)) return null;
  if (raw is num) return EffectValue(constant: raw.toDouble());
  if (raw is! Map<String, dynamic>) {
    throw const FormatException(
      'Numeric expression must be a number or object',
    );
  }
  var v = raw;
  final ref = v['ref'] as String?;
  final simpleFields = {
    'hp',
    'maxHp',
    'missingHp',
    'attack',
    'defense',
    'mp',
    'handCount',
    'shield',
    'damageThisTurn',
    'damageThisRound',
  };
  final eventFields = {
    'amount': 'eventAmount',
    'skillCooldown': 'eventSkillCooldown',
    'attackBaseDamage': 'eventAttackBaseDamage',
    'statusIntensity': 'eventStatusIntensity',
    'statusStackDelta': 'eventStatusStackDelta',
  };
  if (ref != null) {
    final parts = ref.split('.');
    if (parts.length == 2 &&
        ['self', 'target'].contains(parts[0]) &&
        simpleFields.contains(parts[1])) {
      v = {...v}..remove('ref');
      v['field'] = parts[1];
      v['subject'] = parts[0] == 'self' ? 'self' : 'selected';
    } else if (ref.startsWith('event.') &&
        eventFields.containsKey(ref.substring(6))) {
      v = {...v}..remove('ref');
      v['field'] = eventFields[ref.substring(6)];
    } else if (ref == 'game.round' ||
        ref == 'input.number' ||
        ref == 'status.intensity') {
      v = {...v}..remove('ref');
      v['field'] = ref == 'game.round'
          ? 'globalRound'
          : ref == 'input.number'
          ? 'inputNumber'
          : 'statusIntensity';
    }
  }
  final subject = ValueSubject.values.byName(v['subject'] as String? ?? 'self');
  return EffectValue(
    reference: v['ref'] as String?,
    collection: CollectionKind.values.any((k) => k.name == v['field'])
        ? _collectionQuery(v)
        : null,
    among: EffectTarget.values.byName(v['among'] as String? ?? 'enemies'),
    includeDead: _bool(v, 'includeDead'),
    includeSummoned: _bool(v, 'includeSummoned'),
    markIds: _strings(v, 'markIds'),
    operation: v['op'] == null
        ? null
        : ValueOperation.values.byName(v['op'] as String),
    arguments: (v['args'] as List? ?? [])
        .map(
          (a) => a is num
              ? EffectValue(constant: a.toDouble())
              : _value({'value': a})!,
        )
        .toList(),
    statusId: v['statusId'] as String?,
    summonKind: v['summonKind'] as String?,
    tags: _strings(v, 'tags'),
    counter: v['counter'] as String?,
    variable: v['variable'] as String?,
    variableKey: v['variableKey'] as String?,
    variableIndex: _value(v, 'index'),
    variableProperty: v['property'] as String?,
    variableKeySource: VariableSource.values.byName(
      v['variableKeySource'] as String? ?? 'literal',
    ),
    markId: v['markId'] as String?,
    markFromSelf: v['markFromSelf'] as bool? ?? true,
    perIntensity: _bool(v, 'perIntensity'),
    constant: _number(v, 'constant'),
    field: v['field'] == null
        ? null
        : CollectionKind.values.any((k) => k.name == v['field'])
        ? ValueField.collection
        : ValueField.values.byName(v['field'] as String),
    subject: subject,
    factor: _number(v, 'factor', 1),
  );
}

ConditionDefinition? _condition(Object? value) {
  if (value == null) return null;
  if (value is! Map<String, dynamic>) {
    throw const FormatException('when must be an object');
  }
  final op = value['op'];
  if ([
    'eq',
    'ne',
    'gt',
    'gte',
    'lt',
    'lte',
    'contains',
    'intersects',
    'disjoint',
  ].contains(op)) {
    final args = value['args'] as List;
    return PredicateCondition(
      op as String,
      args.map((a) {
        if (a is Map<String, dynamic>) {
          if (a.keys.length == 1 && a['ref'] is String) {
            return RuleOperand(reference: a['ref'] as String);
          }
          return RuleOperand(expression: _value({'value': a}));
        }
        return RuleOperand(literal: a);
      }).toList(),
    );
  }
  if (op == 'all') {
    return AllCondition(
      ((value['args'] ?? value['conditions']) as List)
          .map((c) => _condition(c)!)
          .toList(),
    );
  }
  if (op == 'not') {
    final args = value['args'] as List?;
    if (args != null && args.length != 1) {
      throw const FormatException('not takes one condition');
    }
    return NotCondition(
      _condition(args == null ? value['condition'] : args.single)!,
    );
  }
  if (op == 'value') {
    return ValueCondition(
      _value({'value': value['left']})!,
      _value({'value': value['right']})!,
      comparison: NumericComparison.values.byName(
        value['comparison'] as String? ?? 'equals',
      ),
    );
  }
  if (op == 'relation') {
    return RelationCondition(
      among: EffectTarget.values.byName(value['among'] as String? ?? 'allies'),
    );
  }
  if (op == 'livingCount') {
    return LivingCountCondition(
      among: EffectTarget.values.byName(value['among'] as String? ?? 'allies'),
      excludeSelf: _bool(value, 'excludeSelf'),
      selectedOnly: _bool(value, 'selectedOnly'),
      atLeast: _integer(value, 'atLeast', 1),
      when: _condition(value['when']),
    );
  }
  if (op == 'hpBelowFraction') {
    return HpRatioCondition(
      (value['fraction'] as num).toDouble(),
      subject: ValueSubject.values.byName(
        value['subject'] as String? ?? 'self',
      ),
    );
  }
  if (op == 'any') {
    return AnyCondition(
      ((value['args'] ?? value['conditions']) as List)
          .map((c) => _condition(c)!)
          .toList(),
    );
  }
  if (op == 'variable') {
    return VariableCondition(
      value['variable'] as String,
      comparison: VariableComparison.values.byName(
        value['comparison'] as String,
      ),
      input: _variableInput(value['input']),
      key: value['key'] as String?,
      keySource: VariableSource.values.byName(
        value['keySource'] as String? ?? 'literal',
      ),
      subject: ValueSubject.values.byName(
        value['subject'] as String? ?? 'self',
      ),
    );
  }
  if (op == 'counterEquals') {
    return CounterEqualsCondition(
      value['counter'] as String,
      value['amount'] as int,
    );
  }
  if (op == 'hasMark') {
    return MarkCondition(
      value['markId'] as String,
      minimum: _integer(value, 'minimum', 1),
      subject: EffectTarget.values.byName(
        value['subject'] as String? ?? 'selected',
      ),
      fromSelf: value['fromSelf'] as bool? ?? true,
      negate: _bool(value, 'negate'),
    );
  }
  if (op == 'playedCard') {
    return PlayedCardCondition(_strings(value, 'cardIds').toSet());
  }
  if (op == 'hasStatusQuery') {
    return HasStatusQueryCondition(
      _statusQuery(value['query'] as _Json? ?? {}),
    );
  }
  if (op == 'hasStatus') return HasStatusCondition(value['statusId'] as String);
  if (op == 'hasShield') return const HasShieldCondition();
  if (op != 'isLowest' && op != 'isHighest') {
    throw FormatException('Unsupported condition: $op');
  }
  final subject = switch (value['subject'] ?? 'target') {
    'self' => EffectTarget.self,
    'target' => EffectTarget.selected,
    _ => throw const FormatException(
      'Condition subject must be self or target',
    ),
  };
  final among = EffectTarget.values.byName(
    value['among'] as String? ?? 'enemies',
  );
  if (![
    EffectTarget.all,
    EffectTarget.allies,
    EffectTarget.enemies,
  ].contains(among)) {
    throw const FormatException(
      'Condition among must be all, allies or enemies',
    );
  }
  return StatExtremumCondition(
    stat: Stat.values.byName(value['stat'] as String),
    highest: op == 'isHighest',
    subject: subject,
    among: among,
  );
}

List<EffectDefinition> _effects(_Json d, String key) => _rows(d, key).map((e) {
  final op = e['op'] as String;
  final phase = op == 'blockStatusApplication'
      ? EffectPhase.values.byName(e['phase'] as String? ?? 'resolve')
      : EffectPhase.resolve;
  if (e['phase'] == 'ruleSetup' && op != 'blockStatusApplication') {
    throw FormatException('ruleSetup is not supported for effect: $op');
  }
  final target = EffectTarget.values.byName(
    e['target'] as String? ??
        ([
              'damage',
              'applyStatus',
              'removeStatuses',
              'editStatus',
              'addStatus',
              'transferStatus',
            ].contains(op)
            ? 'selected'
            : 'self'),
  );
  return switch (op) {
    'modifyVariable' => ModifyVariable(
      e['variable'] as String,
      operation: VariableOperation.values.byName(e['operation'] as String),
      storageSubject: ValueSubject.values.byName(
        e['storageSubject'] as String? ?? 'selected',
      ),
      input: _variableInput(e['input']),
      key: _variableInput(e['key']),
      target: target,
    ),
    'selectOption' => SelectOptionEffect(
      _rows(e, 'options')
          .map(
            (o) => AbilityOption(
              id: o['id'] as String,
              label: o['label'] as String? ?? '',
              when: _condition(o['when']),
              effects: _effects(o, 'effects'),
            ),
          )
          .toList(),
      chooser: ChoiceChooser.values.byName(e['chooser'] as String? ?? 'actor'),
    ),
    'generateChosenCard' => GenerateChosenCard(
      use: GeneratedCardUse.values.byName(e['use'] as String? ?? 'nextAttack'),
      exclude: _strings(e, 'exclude'),
      consumeAction: _bool(e, 'consumeAction'),
      query: _cardQuery(e['query'] as _Json? ?? {}),
    ),
    'chooseCards' => ChooseCards(
      minimum: _value(e, 'min')!,
      maximum: _value(e, 'max')!,
      minimumTags: _integer(e, 'minimumTags'),
      anyTags: _strings(e, 'anyTags'),
      query: _cardQuery(e['query'] as _Json? ?? {}),
      bind: e['bind'] as String?,
      destination: CardDestination.values.byName(
        e['destination'] as String? ?? 'discard',
      ),
      recipient: EffectTarget.values.byName(
        e['recipient'] as String? ?? 'selected',
      ),
      target: target,
    ),
    'chooseTargets' => ChooseTargets(
      bind: e['bind'] as String,
      minimum: _integer(e, 'min', 1),
      maximum: _integer(e, 'max', 1),
      minimumValue: e['min'] is Map ? _value(e, 'min') : null,
      maximumValue: e['max'] is Map ? _value(e, 'max') : null,
      when: _condition(e['when']),
      from: EffectTarget.values.byName(e['from'] as String? ?? 'all'),
    ),
    'withTargets' => WithTargets(e['ref'] as String, _effects(e, 'effects')),
    'choose' => ChooseEffect(
      ChoiceKind.values.byName(e['kind'] as String),
      minimumDeckCopies: _integer(e, 'minimumDeckCopies'),
      random: _bool(e, 'random'),
      reveal: _bool(e, 'reveal'),
      amount: _integer(e, 'amount', 1),
      chooser: ChoiceChooser.values.byName(e['chooser'] as String? ?? 'actor'),
      optional: _bool(e, 'optional'),
      preserveSelected: _bool(e, 'preserveSelected'),
      excludeSelected: _bool(e, 'excludeSelected'),
      when: _condition(e['when']),
      statusQuery: e['kind'] == 'status' || e['kind'] == 'extendStatus'
          ? _choiceStatusQuery(e)
          : const StatusQuery(),
      statusQueryFromAlias: e.containsKey('statusQuery'),
      cardQuery:
          const [
            'discardPileCard',
            'deckCard',
            'takeCard',
            'discardCard',
            'returnCardToDeck',
          ].contains(e['kind'])
          ? _cardQuery(e['query'] as _Json? ?? {})
          : const CardQuery(),
      skillQuery: e['kind'] == 'resetCooldown'
          ? _skillQuery(e['query'] as _Json? ?? {})
          : const SkillQuery(),
      includeMissing: _bool(e, 'includeMissing'),
      effects: _effects(e, 'effects'),
      target: target,
    ),
    'chooseObjects' => ChooseObjects(
      query: _collectionQuery(e, selection: true),
      bind: e['bind'] as String,
      minimum: _value(e, 'min') ?? const EffectValue(constant: 1),
      maximum: _value(e, 'max') ?? const EffectValue(constant: 1),
      reveal: _bool(e, 'reveal'),
      chooser: ChoiceChooser.values.byName(e['chooser'] as String? ?? 'actor'),
      target: target,
    ),
    'editMarks' => EditMarks(
      query: _markQuery(e['query'] as _Json? ?? {}),
      mode: StatusEditMode.values.byName(e['mode'] as String? ?? 'add'),
      amount: _value(e, 'amount') ?? const EffectValue(),
      target: target,
    ),
    'transferMarks' => TransferMarks(
      query: _markQuery(e['query'] as _Json? ?? {}),
      to: EffectTarget.values.byName(e['to'] as String? ?? 'self'),
      amount: _value(e, 'amount'),
      target: target,
    ),
    'editSkills' => EditSkills(
      query: _skillQuery(e['query'] as _Json? ?? {}),
      mode: StatusEditMode.values.byName(e['mode'] as String? ?? 'add'),
      amount: _value(e, 'amount') ?? const EffectValue(),
      target: target,
    ),
    'moveCards' || 'copyCards' => MoveCards(
      query: _cardQuery(e['query'] as _Json? ?? {}),
      zone: CardZone.values.byName(e['zone'] as String? ?? 'hand'),
      destination: CardDestination.values.byName(
        e['destination'] as String? ?? 'hand',
      ),
      recipient: EffectTarget.values.byName(
        e['recipient'] as String? ?? 'self',
      ),
      copy: op == 'copyCards',
      random: _bool(e, 'random'),
      amount: _value(e, 'amount'),
      target: target,
    ),
    'editStatus' || 'addStatus' => EditStatus(
      query: _statusQuery(e['query'] as _Json? ?? {}),
      mode: StatusEditMode.values.byName(e['mode'] as String? ?? 'add'),
      createIfMissing: e['op'] == 'addStatus',
      initialStacks: _value(e, 'initialStacks'),
      initialIntensity: _value(e, 'initialIntensity'),
      stacks: _value(e, 'stacks'),
      intensity: _value(e, 'intensity'),
      target: target,
    ),
    'transferStatus' => TransferStatus(
      query: _statusQuery(e['query'] as _Json? ?? {}),
      to: EffectTarget.values.byName(e['to'] as String? ?? 'self'),
      target: target,
    ),
    'armTrigger' => ArmTrigger(_triggers(e)),
    'discardHand' => const DiscardHand(),
    'steal' => StealEffect(
      hp: _integer(e, 'hp'),
      attack: _integer(e, 'attack'),
    ),
    'swapStatuses' => const SwapStatuses(),
    'swapHands' => const SwapHands(),
    'convertStatus' => ConvertStatus(
      fromStatusId: e['fromStatusId'] as String?,
      toStatusId: e['toStatusId'] as String,
      count: _value(e, 'count')!,
      intensity: _integer(e, 'intensity', 1),
      target: target,
    ),
    'settleStatus' => SettleStatus(
      e['statusId'] as String,
      triggerIndex: _integer(e, 'triggerIndex'),
      ignoreLimits: _bool(e, 'ignoreLimits'),
      phase: e['phase'] == null
          ? null
          : SchedulePhase.values.byName(e['phase'] as String),
      allStacks: _bool(e, 'allStacks'),
      target: target,
    ),
    'modifyActionDice' => ModifyActionDice(_integer(e, 'amount')),
    'clearProtection' => ClearProtection(
      shield: e['shield'] as bool? ?? true,
      dodge: e['dodge'] as bool? ?? true,
      positive: _bool(e, 'positive'),
      target: target,
    ),
    'summonUnit' => SummonUnit(
      e['kind'] as String,
      count: _integer(e, 'count', 1),
      target: target,
    ),
    'restrictCardTag' => RestrictCardTag(
      rounds: _integer(e, 'rounds', 1),
      clock: DurationClock.values.byName(
        e['clock'] as String? ?? 'globalRound',
      ),
      target: target,
    ),
    'disableHandCards' => DisableHandCards(
      count: _integer(e, 'count', 2),
      rounds: _integer(e, 'rounds', 1),
      otherwise: _effects(e, 'otherwise'),
      target: target,
    ),
    'drawSkill' => DrawSkill(
      uses: _integer(e, 'uses', 1),
      count: _integer(e, 'count', 1),
    ),
    'blockStatusApplication' => BlockStatusApplication(
      _integer(e, 'rounds', 1),
      phase: phase,
    ),
    'modifyAttackPower' => ModifyAttackPower(
      _integer(e, 'amount'),
      value: _value(e),
    ),
    'modifyAttack' => ModifyAttack(
      _integer(e, 'amount'),
      value: _value(e),
      multiplier: _number(e, 'multiplier', 1),
    ),
    'setCounter' => SetCounter(
      e['counter'] as String,
      _integer(e, 'amount'),
      add: _bool(e, 'add'),
    ),
    'conditional' => ConditionalEffect(
      _condition(e['when'])!,
      eachTarget: _bool(e, 'eachTarget'),
      snapshot: _bool(e, 'snapshot'),
      _effects(e, 'effects'),
      otherwise: _effects(e, 'otherwise'),
      target: e['target'] == null ? EffectTarget.selected : target,
    ),
    'roll' => RollEffect(
      damageRoll: _bool(e, 'damageRoll'),
      bind: e['bind'] as String?,
      sides: _integer(e, 'sides'),
      count: _integer(e, 'count', 1),
      success: (e['success'] as List<dynamic>? ?? []).cast<int>(),
      atMost: _value(e, 'atMost'),
      atLeast: _value(e, 'atLeast'),
      eachTarget: _bool(e, 'eachTarget'),
      roller: ChoiceChooser.values.byName(e['roller'] as String? ?? 'target'),
      target: target,
      effects: _effects(e, 'effects'),
      otherwise: _effects(e, 'otherwise'),
    ),
    'diceContest' => DiceContest(
      sides: _integer(e, 'sides', 4),
      factor: _integer(e, 'factor', 50),
      bonus: _integer(e, 'bonus', 1),
    ),
    'modifyMark' => ModifyMark(
      e['markId'] as String,
      amount: _integer(e, 'amount', 1),
      value: _value(e),
      set: _bool(e, 'set'),
      references: (e['references'] as _Json? ?? {}).cast<String, String>(),
      target: target,
    ),
    'impact' => ImpactEffect(target: target),
    'modifyStat' => ModifyStat(
      Stat.values.byName(e['stat'] as String),
      _integer(e, 'amount'),
      onClamp: _effects(e, 'onClamp'),
      value: _value(e),
      oncePerAction: _bool(e, 'oncePerAction'),
      target: target,
    ),
    'convertShieldToLife' => ConvertShieldToLife(
      factor: _number(e, 'factor', 1),
      target: target,
    ),
    'generateRandomAction' => const GenerateRandomAction(),
    'borrowSkill' => BorrowSkillEffect(rule: _skillBorrowRule(e)),
    'captureSave' => const CaptureSave(),
    'checkContinuation' => CheckContinuation(
      sides: _integer(e, 'sides', 6),
      success: (e['success'] as List? ?? [1, 5, 6]).cast<int>(),
      restoreHp: _integer(e, 'restoreHp', 1),
    ),
    'restoreLife' => RestoreLife(
      _integer(e, 'amount'),
      value: _value(e, 'amount'),
      target: target,
    ),
    'setLife' => SetLife(
      _integer(e, 'amount'),
      value: _value(e, 'amount'),
      target: target,
    ),
    'heal' => HealEffect(
      _integer(e, 'amount'),
      value: _value(e),
      sourceTraitId: e['sourceTraitId'] as String?,
      targetTraitId: e['targetTraitId'] as String?,
      target: target,
    ),
    'damage' => DamageEffect(
      _integer(e, 'amount'),
      value: _value(e),
      target: target,
      kind: DamageKind.values.byName(e['kind'] as String? ?? 'physical'),
      sourceless: _bool(e, 'sourceless'),
      fromStatusSource: _bool(e, 'fromStatusSource'),
      onDamage: _effects(e, 'onDamage'),
    ),
    'transferShield' => TransferShield(_integer(e, 'limit'), target: target),
    'removeSummons' => RemoveSummons(e['kind'] as String, target: target),
    'transferReceivedDamage' => TransferReceivedDamage(target: target),
    'redirectAttack' => RedirectAttack(
      cap: _integer(e, 'cap'),
      overflowUnit: _integer(e, 'overflowUnit'),
      markId: e['markId'] as String,
    ),
    'armAttack' => ArmAttack(
      target: target,
      fixedMaximum: _bool(e, 'fixedMaximum'),
      onHit: _effects(e, 'onHit'),
      after: _effects(e, 'after'),
      rotationTake: _integer(e, 'rotationTake', 2),
      rotationBonus: (e['rotationBonus'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(int.parse(k), _effects({'effects': v}, 'effects')),
      ),
      damageMultiplier: (e['damageMultiplier'] as num?)?.toDouble() ?? 1,
      diceCount: _integer(e, 'diceCount', 1),
      copyDamage: _bool(e, 'copyDamage'),
      copyDamageBasis: AttackCopyBasis.values.byName(
        e['copyDamageBasis'] as String? ?? 'actualDamage',
      ),
      reciprocalDice: _bool(e, 'reciprocalDice'),
    ),
    'stealLife' => StealLife(
      _integer(e, 'amount'),
      value: _value(e),
      healNominal: _bool(e, 'healNominal'),
      fromStatusSource: _bool(e, 'fromStatusSource'),
      target: target,
    ),
    'shield' => ShieldEffect(
      _integer(e, 'amount'),
      value: _value(e),
      target: target,
    ),
    'schedule' => ScheduleEffect(
      phase: SchedulePhase.values.byName(e['phase'] as String),
      after: _integer(e, 'after', 1),
      captureValues: _bool(e, 'captureValues'),
      effects: _effects(e, 'effects'),
      target: target,
    ),
    'reverseTurnOrder' => const ReverseTurnOrder(),
    'modifyStatus' => ModifyAppliedStatus(
      e['statusId'] as String,
      stacks: _integer(e, 'stacks'),
      intensity: _integer(e, 'intensity'),
      target: target,
    ),
    'grantExtraTurns' => GrantExtraTurns(_integer(e, 'count'), target: target),
    'healToFraction' => HealToFraction(_number(e, 'fraction'), target: target),
    'grantActions' => GrantActions(
      _integer(e, 'count'),
      value: e['count'] is Map ? _value(e, 'count') : null,
      target: target,
    ),
    'draw' => DrawEffect(
      _integer(e, 'count'),
      value: _value(e),
      target: target,
    ),
    'randomDiscard' => RandomDiscard(
      _integer(e, 'count'),
      value: e['count'] is Map ? _value(e, 'count') : null,
      query: _cardQuery(e['query'] as _Json? ?? {}),
      target: target,
    ),
    'equalizeHand' => EqualizeHand(target: target),
    'swapResources' => SwapResources(
      hp: e['hp'] as bool? ?? true,
      mp: e['mp'] as bool? ?? true,
      target: target,
    ),
    'applyStatus' => ApplyStatus(
      e['statusId'] as String,
      stacks: _integer(e, 'stacks', 1),
      stacksValue:
          _value(e, 'stacksValue') ??
          (e['stacks'] is Map ? _value(e, 'stacks') : null),
      intensity: _integer(e, 'intensity', 1),
      intensityValue:
          _value(e, 'intensityValue') ??
          (e['intensity'] is Map ? _value(e, 'intensity') : null),
      refreshSource: _bool(e, 'refreshSource'),
      ignoreNegativeProtection: _strings(e, 'ignoreNegativeProtection'),
      damageLimit: e['damageLimit'] as int?,
      target: target,
    ),
    'payLife' => PayLife(_value(e)!),
    'payMp' => PayMp(
      _integer(e, 'amount'),
      value: _value(e),
      target: e['target'] == null ? EffectTarget.self : target,
    ),
    'flipMarks' => FlipMarks(
      e['first'] as String,
      e['second'] as String,
      mode: e['mode'] as String? ?? 'toggle',
      target: target,
    ),
    'forceNextAttackTarget' => ForceNextAttackTarget(target: target),
    'armAttackTransfer' => ArmAttackTransfer(
      followAttackTarget: _bool(e, 'followAttackTarget'),
    ),
    'useTimeReserve' => const UseTimeReserve(),
    'modifyMp' => ModifyMp(
      _integer(e, 'amount'),
      value: _value(e),
      target: target,
    ),
    'transferMp' => TransferMp(_integer(e, 'amount', 1), target: target),
    'modifyCooldown' => ModifyCooldown(
      _integer(e, 'amount'),
      value: _value(e),
      query: _skillQuery(e['query'] as _Json? ?? {}),
      usedSkillOnly: _bool(e, 'usedSkillOnly'),
      skillId: e['skillId'] as String?,
      target: target,
    ),
    'modifyOwnStatus' => ModifyOwnStatus(
      stacks: _integer(e, 'stacks'),
      intensity: _integer(e, 'intensity'),
    ),
    'removeStatuses' => RemoveStatuses(
      negativeOnly: _bool(e, 'negativeOnly'),
      includeAnomalies: e['includeAnomalies'] as bool? ?? true,
      statusId: e['statusId'] as String?,
      target: target,
    ),
    'setDiceResult' => const SetDiceResult(),
    'cancelCard' => const CancelCard(),
    'cancelSkill' => CancelSkill(
      discardCount: _integer(e, 'discardCount'),
      othersOnly: _bool(e, 'othersOnly'),
    ),
    _ => throw FormatException('Unsupported effect operation: $op'),
  };
}).toList();

List<CounterDefinition> _counters(_Json d) => _rows(d, 'counters')
    .map(
      (c) => CounterDefinition(
        id: c['id'] as String,
        initial: _integer(c, 'initial'),
        reset: CounterReset.values.byName(c['reset'] as String? ?? 'never'),
        maximum: c['maximum'] as int?,
      ),
    )
    .toList();

List<TriggerDefinition> _triggers(_Json d) => _rows(d, 'triggers').map((t) {
  final threshold = t['threshold'] as _Json?;
  return TriggerDefinition(
    timing: TriggerTiming.values.byName(t['timing'] as String),
    when: _condition(t['when']),
    guard: _condition(t['guard']),
    scope: TriggerScope.values.byName(t['scope'] as String? ?? 'self'),
    effects: _effects(t, 'effects'),
    minimumAmount: t['minimumAmount'] as int?,
    maximumAmount: t['maximumAmount'] as int?,
    maximumDamageThisRound: t['maximumDamageThisRound'] as int?,
    maximumHandCount: t['maximumHandCount'] as int?,
    maximumHpFraction: (t['maximumHpFraction'] as num?)?.toDouble(),
    minimumHp: t['minimumHp'] as int?,
    attackOnly: _bool(t, 'attackOnly'),
    excludeIndependent: _bool(t, 'excludeIndependent'),
    ownerTurnOnly: _bool(t, 'ownerTurnOnly'),
    recordOnly: _bool(t, 'recordOnly'),
    ignoreSuppression: _bool(t, 'ignoreSuppression'),
    otherSourceOnly: _bool(t, 'otherSourceOnly'),
    negativeStatusOnly: _bool(t, 'negativeStatusOnly'),
    tag: t['tag'] as String?,
    definitionId: t['definitionId'] as String?,
    minimumSharedTagCount: t['minimumSharedTagCount'] as int?,
    damageKind: t['damageKind'] == null
        ? null
        : DamageKind.values.byName(t['damageKind'] as String),
    maxUses: t['maxUses'] as int?,
    repeatPerAmount: _bool(t, 'repeatPerAmount'),
    scaleWithIntensity: t['scaleWithIntensity'] as bool? ?? true,
    oncePerPacket: _bool(t, 'oncePerPacket'),
    limitGroup: t['limitGroup'] as String?,
    limitWindow: CounterReset.values.byName(
      t['limitWindow'] as String? ?? 'never',
    ),
    threshold: threshold == null
        ? null
        : CounterThreshold(
            threshold['counter'] as String,
            threshold['every'] as int,
          ),
    counterUpdates: _rows(t, 'counterUpdates')
        .map(
          (c) => CounterUpdate(
            c['counter'] as String,
            amount: _integer(c, 'amount'),
            eventAmountFactor: _integer(c, 'eventAmountFactor'),
            value: c['amount'] is Map ? _value(c, 'amount') : null,
          ),
        )
        .toList(),
  );
}).toList();

StatusAction _statusAction(_Json d) => StatusAction(
  lifeCostPerIntensity: _integer(d, 'lifeCostPerIntensity'),
  removeSelf: d['removeSelf'] as bool? ?? true,
  effects: _effects(d, 'effects'),
);

TraitAction _traitAction(_Json d) => TraitAction(
  anytime: _bool(d, 'anytime'),
  options: (d['options'] as _Json? ?? {}).map(
    (id, option) => MapEntry(id, _traitAction(option as _Json)),
  ),
  markCosts: _rows(
    d,
    'markCosts',
  ).map((c) => MarkCost(c['markId'] as String, c['amount'] as int)).toList(),
  requireFullMp: _bool(d, 'requireFullMp'),
  mpCost: _integer(d, 'mpCost'),
  discardCount: _integer(d, 'discardCount'),
  maxUsesPerRound: d['maxUsesPerRound'] as int?,
  limitWindow: CounterReset.values.byName(
    d['limitWindow'] as String? ?? 'round',
  ),
  extraActions: _integer(d, 'extraActions'),
  attackBonus: _integer(d, 'attackBonus'),
  effects: _effects(d, 'effects'),
  markLayers: d['markLayers'] as String?,
  markIntensity: d['markIntensity'] as String?,
  layersPerMark: _integer(d, 'layersPerMark', 1),
  intensityPerMark: _integer(d, 'intensityPerMark', 2),
  fallbackLayersPerMark: _integer(d, 'fallbackLayersPerMark', 1),
);

StatusQuery _choiceStatusQuery(_Json effect) {
  if (effect.containsKey('query') && effect.containsKey('statusQuery')) {
    throw const FormatException('Choose uses one status query');
  }
  return _statusQuery(
    (effect['query'] ?? effect['statusQuery']) as _Json? ?? {},
  );
}

StatusQuery _statusQuery(_Json q) => StatusQuery(
  statusIds: _strings(q, 'statusIds'),
  excludeStatusIds: _strings(q, 'excludeStatusIds'),
  decayingOnly: _bool(q, 'decayingOnly'),
  extendableOnly: _bool(q, 'extendableOnly'),
  instanceId: q['instanceId'] as String?,
  statusId: q['statusId'] as String?,
  negative: q['negative'] as bool?,
  hasIntensity: q['hasIntensity'] as bool?,
  includeAnomalies: _bool(q, 'includeAnomalies'),
  minimumIntensity: q['minimumIntensity'] is num
      ? q['minimumIntensity'] as int
      : null,
  minimumIntensityValue: q['minimumIntensity'] is Map
      ? _value(q, 'minimumIntensity')
      : null,
  minimumStacks: _value(q, 'minimumStacks'),
  maximumStacks: _value(q, 'maximumStacks'),
  maximumIntensity: _value(q, 'maximumIntensity'),
  source: q['source'] as String?,
  selection: q['selection'] as String?,
  latest: _bool(q, 'latest'),
  chosen: _bool(q, 'chosen'),
);

AttackDuelDefinition _attackDuel(_Json d) {
  final failure = _integer(d, 'failureBonus', 1);
  final victory = _integer(d, 'victoryAttack', 5);
  final counter = d['counter'] as String? ?? 'duel_bonus';
  if (failure < 0 ||
      victory < 0 ||
      !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(counter)) {
    throw const FormatException('Invalid attackDuel configuration');
  }
  return AttackDuelDefinition(
    counter: counter,
    failureBonus: failure,
    victoryAttack: victory,
  );
}

VariableInput _variableInput(Object? raw) {
  if (raw == null) return const VariableInput();
  if (raw is! Map<String, dynamic>) return VariableInput(literal: raw);
  if (raw['ref'] case final String ref) {
    const sources = {
      'self.id': VariableSource.selfId,
      'target.id': VariableSource.selectedId,
      'event.amount': VariableSource.eventAmount,
      'event.tagNames': VariableSource.eventTags,
      'event.source': VariableSource.eventSource,
      'event.target': VariableSource.eventTarget,
      'event.definition': VariableSource.eventDefinition,
      'event.record': VariableSource.eventRecord,
    };
    if (sources.containsKey(ref)) return VariableInput(source: sources[ref]!);
    if (ref.startsWith('variables.')) {
      return VariableInput(
        source: VariableSource.variable,
        variable: ref.substring(10),
      );
    }
    return VariableInput(
      source: VariableSource.expression,
      value: _value({'value': raw}),
    );
  }
  if (raw['op'] != null || raw['query'] != null || raw['field'] != null) {
    return VariableInput(
      source: VariableSource.expression,
      value: _value({'value': raw}),
    );
  }
  return VariableInput(
    source: VariableSource.values.byName(raw['source'] as String? ?? 'literal'),
    variable: raw['variable'] as String?,
    subject: ValueSubject.values.byName(raw['subject'] as String? ?? 'self'),
    literal: raw['literal'],
    value: _value(raw),
  );
}

AttackDiceSequence _attackDiceSequence(_Json d) => AttackDiceSequence(
  values: (d['values'] as List).cast<int>(),
  positionVariable: d['positionVariable'] as String,
  diceSides: _integer(d, 'diceSides', 4),
  replaceDiceSides: d['replaceDiceSides'] as bool? ?? true,
);

DamageGuard _damageGuard(_Json g) => DamageGuard(
  perDamageInstance: _bool(g, 'perDamageInstance'),
  when: _condition(g['when']),
  traitBlockExceptions: _strings(g, 'traitBlockExceptions'),
  kinds: (g['kinds'] == null ? ['physical', 'magical'] : _strings(g, 'kinds'))
      .map(DamageKind.values.byName)
      .toList(),
  rollSides: g['rollSides'] as int?,
  oncePerAttack: _bool(g, 'oncePerAttack'),
  effectsOncePerAttack: _bool(g, 'effectsOncePerAttack'),
  groupAttackOnly: _bool(g, 'groupAttackOnly'),
  success: (g['success'] as List? ?? []).cast<int>(),
  flatPerIntensity: _integer(g, 'flatPerIntensity'),
  factor: _number(g, 'factor', 1),
  once: _bool(g, 'once'),
  consumeStacks: _integer(g, 'consumeStacks'),
  effects: _effects(g, 'effects'),
);

AttackModifier _attackModifier(_Json m) => AttackModifier(
  when: _condition(m['when']),
  attackBonus: _integer(m, 'attackBonus'),
  finalDamageBonus: _integer(m, 'finalDamageBonus'),
  finalDamageValue: _value(m, 'finalDamageValue'),
  finalDamageMultiplier: _number(m, 'finalDamageMultiplier', 1),
  ignoreDefenseAmount: _integer(m, 'ignoreDefenseAmount'),
  ignoreDefenseRatio: _number(m, 'ignoreDefenseRatio'),
  clearDodge: _bool(m, 'clearDodge'),
  ignoreShield: _bool(m, 'ignoreShield'),
  ignoreDodge: _bool(m, 'ignoreDodge'),
);

AttackDiceRule _attackDiceRule(_Json d) => AttackDiceRule(
  mode: AttackDiceMode.values.byName(d['mode'] as String),
  offset: _integer(d, 'offset'),
  roundUp: _bool(d, 'roundUp'),
  oddRemainderFixedOne: _bool(d, 'oddRemainderFixedOne'),
);
IncomingAttackRule _incomingAttack(_Json d) => IncomingAttackRule(
  ignoreCardFinalDamage: _bool(d, 'ignoreCardFinalDamage'),
  finalDamageReductionValue: _value(d, 'finalDamageReductionValue'),
  reduceAttachments: _bool(d, 'reduceAttachments'),
  blockGroupAttackEffects: _bool(d, 'blockGroupAttackEffects'),
  useBaseDice: _bool(d, 'useBaseDice'),
  diceCap: d['diceCap'] as int?,
);
AttackAura _attackAura(_Json d) => AttackAura(
  scope: EffectTarget.values.byName(d['scope'] as String? ?? 'allies'),
  strengthenedOnly: _bool(d, 'strengthenedOnly'),
  thresholdReduction: _integer(d, 'thresholdReduction'),
  attackModifiers: List.unmodifiable(
    _rows(d, 'attackModifiers').map(_attackModifier),
  ),
  onHit: List.unmodifiable(_effects(d, 'onHit')),
  finalDamageMultiplier: _number(d, 'finalDamageMultiplier', 1),
);

CheckpointRule _checkpoint(Map<String, dynamic> d) => CheckpointRule(
  at: SkillCheckpoint.values.byName(d['at'] as String),
  minimumDamage: _integer(d, 'minimumDamage'),
  maximumTargetHp: _integer(d, 'maximumTargetHp', 300),
  extraTurns: _integer(d, 'extraTurns', 1),
  attackOnly: d['attackOnly'] as bool? ?? false,
  damageFactor: (d['damageFactor'] as num?)?.toDouble() ?? 1,
  restoreHp: d['restoreHp'] as int?,
  shield: _integer(d, 'shield'),
  shieldRounds: _integer(d, 'shieldRounds'),
  shieldClock: DurationClock.values.byName(
    d['shieldClock'] as String? ?? 'globalRound',
  ),
  kinds: d['kinds'] == null
      ? const [DamageKind.physical, DamageKind.magical, DamageKind.real]
      : (d['kinds'] as List)
            .map((v) => DamageKind.values.byName(v as String))
            .toList(),
);

DamageResourceRule _damageResource(_Json d) => DamageResourceRule(
  variable: d['variable'] as String,
  turnGain: _integer(d, 'turnGain'),
  factor: _number(d, 'factor'),
  threshold: _integer(d, 'threshold'),
  targetStatusId: d['targetStatusId'] as String,
  targetStatusStacks: _integer(d, 'targetStatusStacks', 2),
  targetStatusIntensity: _integer(d, 'targetStatusIntensity', 1),
  selfStatusId: d['selfStatusId'] as String,
  selfStatusStacks: _integer(d, 'selfStatusStacks', 1),
  selfStatusIntensity: _integer(d, 'selfStatusIntensity', 3),
  reactionLockStatusId: d['reactionLockStatusId'] as String?,
  reactionLockRounds: _integer(d, 'reactionLockRounds', 1),
);
DecreeRule _decree(_Json d) => DecreeRule(
  statusIds: (d['statusIds'] as List).cast<String>(),
  roundVariable: d['roundVariable'] as String,
  lastVariable: d['lastVariable'] as String,
  blockedBy: d['blockedBy'] as String,
  statusStacks: _integer(d, 'statusStacks', 1),
  statusIntensity: _integer(d, 'statusIntensity', 1),
  maxUsesPerTargetPerRound: _integer(d, 'maxUsesPerTargetPerRound', 1),
  usesVariable: d['usesVariable'] as String?,
);
DreamCraftRule _dreamCraft(_Json d) => DreamCraftRule(
  fromStatus: d['fromStatus'] as String,
  toStatus: d['toStatus'] as String,
  mpCost: _integer(d, 'mpCost', 2),
  discardCount: _integer(d, 'discardCount', 1),
  statusStacks: _integer(d, 'statusStacks', 1),
  statusIntensity: _integer(d, 'statusIntensity', 1),
);
FruitAttackRule _fruitAttack(_Json d) => FruitAttackRule(
  markId: d['markId'] as String,
  clearStatus: d['clearStatus'] as String,
  damage: _integer(d, 'damage', 75),
  diceDelta: _integer(d, 'diceDelta', 2),
  markCost: _integer(d, 'markCost', 1),
);
NightmareRule _nightmare(_Json d) => NightmareRule(
  statusId: d['statusId'] as String,
  fruitTraitId: d['fruitTraitId'] as String,
  fruitMarkId: d['fruitMarkId'] as String,
  intensityVariable: d['intensityVariable'] as String,
  countVariable: d['countVariable'] as String,
  damagePerFruit: _integer(d, 'damagePerFruit', 30),
  healingFactor: _number(d, 'healingFactor', .6),
  healingTraitId: d['healingTraitId'] as String?,
  healFromRuleOwner: _bool(d, 'healFromRuleOwner'),
  every: _integer(d, 'every', 9),
  intensityGain: _integer(d, 'intensityGain', 1),
);
SummonDefenseRule _summonDefense(_Json d) => SummonDefenseRule(
  kind: d['kind'] as String,
  historyVariable: d['historyVariable'] as String,
  baseCap: _integer(d, 'baseCap', 2),
  maxCap: _integer(d, 'maxCap', 5),
  hpPerSlot: _integer(d, 'hpPerSlot', 200),
  rollSides: _integer(d, 'rollSides', 10),
  blockHealing: _bool(d, 'blockHealing'),
);

LifeThresholdRule _lifeThreshold(_Json d) => LifeThresholdRule(
  below: _integer(d, 'below'),
  variable: d['variable'] as String,
  effects: _effects(d, 'effects'),
);
CardLifeRule _cardLifeRule(_Json d) => CardLifeRule(
  threshold: _integer(d, 'threshold'),
  highTags: _strings(d, 'highTags').toSet(),
  lowTags: _strings(d, 'lowTags').toSet(),
  highEffects: _effects(d, 'highEffects'),
  lowEffects: _effects(d, 'lowEffects'),
  lowOptional: d['lowOptional'] as bool? ?? true,
);
NegativeMpAura _negativeMpAura(_Json d) => NegativeMpAura(
  floor: _integer(d, 'floor', -2),
  sides: _integer(d, 'sides', 6),
  failure: _integer(d, 'failure', 3),
);
TagRewards _tagRewards(_Json d) => TagRewards(
  threshold: _integer(d, 'threshold', 5),
  effects: (d['effects'] as _Json).map(
    (k, v) => MapEntry(k, _effects({'effects': v}, 'effects')),
  ),
  boostedEffects: (d['boostedEffects'] as _Json? ?? {}).map(
    (k, v) => MapEntry(k, _effects({'effects': v}, 'effects')),
  ),
);
PreyRule _prey(_Json d) => PreyRule(
  outgoingFactor: _number(d, 'outgoingFactor', 1.2),
  incomingFactor: _number(d, 'incomingFactor', .8),
);

RotatingCardEffects _rotatingCardEffects(_Json d) => RotatingCardEffects(
  variable: d['variable'] as String,
  suppressFirst: _integer(d, 'suppressFirst', 2),
  entries: _rows(d, 'entries')
      .map(
        (e) => RotatingCardEffect(
          suppressedTags: _strings(e, 'suppressedTags').toSet(),
          effects: _effects(e, 'effects'),
        ),
      )
      .toList(),
);

const _mechanismFields = <String, String>{
  'life_threshold': 'lifeThreshold',
  'card_life_rule': 'cardLifeRule',
  'negative_mp_aura': 'negativeMpAura',
  'tag_rewards': 'tagRewards',
  'prey': 'prey',
  'rotating_card_effects': 'rotatingCardEffects',
  'time_reserve': 'timeReserve',
  'buddy_block': 'buddyBlock',
  'support_stance': 'supportStance',
  'damage_share': 'damageShare',
  'discard_reserve': 'discardReserve',
  'dream_craft': 'dreamCraft',
  'fruit_attack': 'fruitAttack',
  'nightmare': 'nightmare',
  'summon_defense': 'summonDefense',
  'damage_resource': 'damageResource',
  'decree': 'decree',
  'turn_save': 'saveAtTurnStart',
  'save_at_turn_start': 'saveAtTurnStart',
  'action_recording': 'recordActions',
  'record_actions': 'recordActions',
  'borrow_skill_at_turn_start': 'borrowSkillAtTurnStart',
  'shield_life_cycle': 'shieldLifeCycle',
  'generated_action_on_shield': 'generatedActionOnShield',
  'choose_damage_roll': 'chooseDamageRoll',
  'skill_refund_divisor': 'skillRefundDivisor',
};

MechanismBindings _decodeMechanismBindings(_Json d) {
  final modules = <Object>[];
  final lifeThreshold = d['lifeThreshold'] == null
      ? null
      : _lifeThreshold(d['lifeThreshold'] as _Json);
  if (lifeThreshold != null) modules.add(lifeThreshold);
  final cardLifeRule = d['cardLifeRule'] == null
      ? null
      : _cardLifeRule(d['cardLifeRule'] as _Json);
  if (cardLifeRule != null) modules.add(cardLifeRule);
  final negativeMpAura = d['negativeMpAura'] == null
      ? null
      : _negativeMpAura(d['negativeMpAura'] as _Json);
  if (negativeMpAura != null) modules.add(negativeMpAura);
  final tagRewards = d['tagRewards'] == null
      ? null
      : _tagRewards(d['tagRewards'] as _Json);
  if (tagRewards != null) modules.add(tagRewards);
  final prey = d['prey'] == null ? null : _prey(d['prey'] as _Json);
  if (prey != null) modules.add(prey);
  final rotatingCardEffects = d['rotatingCardEffects'] == null
      ? null
      : _rotatingCardEffects(d['rotatingCardEffects'] as _Json);
  if (rotatingCardEffects != null) modules.add(rotatingCardEffects);
  final timeReserve = d['timeReserve'] == null
      ? null
      : TimeReserveRule(
          markId: d['timeReserve']['markId'] as String,
          statusId: d['timeReserve']['statusId'] as String,
          variable: d['timeReserve']['variable'] as String,
          strength: (d['timeReserve']['strength'] as int?) ?? 4,
          manualUse: d['timeReserve']['manualUse'] == true,
          recoveryMpCost: _integer(
            d['timeReserve'] as _Json,
            'recoveryMpCost',
            1,
          ),
          recoveryMarkGain: _integer(
            d['timeReserve'] as _Json,
            'recoveryMarkGain',
            1,
          ),
          overflowMarkGain: _integer(
            d['timeReserve'] as _Json,
            'overflowMarkGain',
            1,
          ),
          mpPerMark: _integer(d['timeReserve'] as _Json, 'mpPerMark', 1),
          intensityPerMark: _integer(
            d['timeReserve'] as _Json,
            'intensityPerMark',
            1,
          ),
          statusStacks: _integer(d['timeReserve'] as _Json, 'statusStacks', 1),
          maxUsesPerRound: _integer(
            d['timeReserve'] as _Json,
            'maxUsesPerRound',
            1,
          ),
          usesVariable: d['timeReserve']['usesVariable'] as String?,
        );
  if (timeReserve != null) modules.add(timeReserve);
  final buddyBlock = d['buddyBlock'] == null
      ? null
      : BuddyBlockRule(
          surcharge: (d['buddyBlock']['surcharge'] as int?) ?? 1,
          recovery: (d['buddyBlock']['recovery'] as int?) ?? 1,
          drainAmount: _integer(d['buddyBlock'] as _Json, 'drainAmount', 1),
          includeAnomalies:
              d['buddyBlock']['includeAnomalies'] as bool? ?? true,
        );
  if (buddyBlock != null) modules.add(buddyBlock);
  final supportStance = d['supportStance'] == null
      ? null
      : SupportStanceRule(
          statusId: d['supportStance']['statusId'] as String,
          defenseVariable: d['supportStance']['defenseVariable'] as String,
          attackVariable: d['supportStance']['attackVariable'] as String,
          currentVariable: d['supportStance']['currentVariable'] as String,
          previousVariable: d['supportStance']['previousVariable'] as String,
          damageThreshold:
              (d['supportStance']['damageThreshold'] as int?) ?? 300,
          rollSides: _integer(d['supportStance'] as _Json, 'rollSides', 4),
          rollCount: _integer(d['supportStance'] as _Json, 'rollCount', 1),
          statusStacks: _integer(
            d['supportStance'] as _Json,
            'statusStacks',
            1,
          ),
          previousHitsBelow: _integer(
            d['supportStance'] as _Json,
            'previousHitsBelow',
            2,
          ),
          defenseUses: _integer(d['supportStance'] as _Json, 'defenseUses', 1),
          attackUses: _integer(d['supportStance'] as _Json, 'attackUses', 1),
          cooldownReduction: _integer(
            d['supportStance'] as _Json,
            'cooldownReduction',
            1,
          ),
          startRound: _integer(d['supportStance'] as _Json, 'startRound', 2),
        );
  if (supportStance != null) modules.add(supportStance);
  final damageShare = d['damageShare'] == null
      ? null
      : DamageShareRule(
          factor: (d['damageShare']['factor'] as num?)?.toDouble() ?? .5,
          sourceStatusId: d['damageShare']['sourceStatusId'] as String,
          intensityGain: (d['damageShare']['intensityGain'] as int?) ?? 2,
        );
  if (damageShare != null) modules.add(damageShare);
  final discardReserve = d['discardReserve'] == null
      ? null
      : DiscardReserveRule(
          variable: d['discardReserve']['variable'] as String,
          shieldPerCard: (d['discardReserve']['shieldPerCard'] as int?) ?? 30,
          shieldPerMp: (d['discardReserve']['shieldPerMp'] as int?) ?? 30,
        );
  if (discardReserve != null) modules.add(discardReserve);
  final dreamCraft = d['dreamCraft'] == null
      ? null
      : _dreamCraft(d['dreamCraft'] as _Json);
  if (dreamCraft != null) modules.add(dreamCraft);
  final fruitAttack = d['fruitAttack'] == null
      ? null
      : _fruitAttack(d['fruitAttack'] as _Json);
  if (fruitAttack != null) modules.add(fruitAttack);
  final nightmare = d['nightmare'] == null
      ? null
      : _nightmare(d['nightmare'] as _Json);
  if (nightmare != null) modules.add(nightmare);
  final summonDefense = d['summonDefense'] == null
      ? null
      : _summonDefense(d['summonDefense'] as _Json);
  if (summonDefense != null) modules.add(summonDefense);
  final damageResource = d['damageResource'] == null
      ? null
      : _damageResource(d['damageResource'] as _Json);
  if (damageResource != null) modules.add(damageResource);
  final decree = d['decree'] == null ? null : _decree(d['decree'] as _Json);
  if (decree != null) modules.add(decree);
  final skillRefundDivisor = (d['skillRefundDivisor'] as int?) == null
      ? null
      : SkillRefundRule(d['skillRefundDivisor'] as int);
  if (skillRefundDivisor != null) modules.add(skillRefundDivisor);
  if (d['saveAtTurnStart'] != null && d['saveAtTurnStart'] != false) {
    final r = d['saveAtTurnStart'] is Map
        ? d['saveAtTurnStart'] as _Json
        : <String, dynamic>{};
    modules.add(
      TurnSaveRule(
        automaticCapture: r['automaticCapture'] as bool? ?? true,
        allowOwnTurn: _bool(r, 'allowOwnTurn'),
        maxUses: _integer(r, 'maxUses', 1),
        restoreMp: r['restoreMp'] as bool? ?? true,
        restoreHand: r['restoreHand'] as bool? ?? true,
        restoreStatuses: r['restoreStatuses'] as bool? ?? true,
        restoreCooldowns: r['restoreCooldowns'] as bool? ?? true,
      ),
    );
  }
  if (d['recordActions'] != null && d['recordActions'] != false) {
    final r = d['recordActions'] is Map
        ? d['recordActions'] as _Json
        : <String, dynamic>{};
    modules.add(
      ActionRecordingRule(
        capacity: _integer(r, 'capacity', 5),
        perRound: _integer(r, 'perRound', 2),
      ),
    );
  }
  if (_bool(d, 'borrowSkillAtTurnStart')) modules.add(const SkillBorrowRule());
  if (_bool(d, 'shieldLifeCycle')) modules.add(const ShieldLifeCycleRule());
  if (_bool(d, 'generatedActionOnShield')) {
    modules.add(const GeneratedShieldActionRule());
  }
  if (d['chooseDamageRoll'] != null && d['chooseDamageRoll'] != false) {
    final raw = d['chooseDamageRoll'];
    if (raw != true && raw is! Map<String, dynamic>) {
      throw const FormatException(
        'choose_damage_roll must be a boolean or object',
      );
    }
    modules.add(
      DamageRollChoiceRule(
        rollCount: raw is Map<String, dynamic>
            ? _integer(raw, 'rollCount', 2)
            : 2,
      ),
    );
  }
  return MechanismBindings(modules);
}

ResourceAbilities _resourceAbilities(_Json d, {required bool legacy}) {
  final raw = d['resourceAbilities'] as _Json?;
  if (raw == null && legacy) {
    if (d['resourcePolicy'] == 'defenseLife') {
      return ResourceAbilities(
        shieldDefenseFactor: .04,
        legacyDefenseDiscard: true,
      );
    }
    if (d['resourcePolicy'] == 'healthActions') {
      return ResourceAbilities(
        cardLifeCost: 24,
        damageHealing: {64: .1, 124: .14, 184: .18},
        idleDrawCount: 2,
      );
    }
  }
  final r = raw ?? <String, dynamic>{};
  return ResourceAbilities(
    cardLifeCost: _integer(r, 'cardLifeCost'),
    damageHealing: {
      for (final e in (r['damageHealing'] as _Json? ?? {}).entries)
        int.parse(e.key): (e.value as num).toDouble(),
    },
    idleDrawCount: _integer(r, 'idleDrawCount'),
    idleTakeCount: _integer(r, 'idleTakeCount', 1),
    defenseLossPerDamage: _number(r, 'defenseLossPerDamage', .02),
    shieldDefenseFactor: _number(r, 'shieldDefenseFactor'),
    shieldDefenseTurns: _integer(r, 'shieldDefenseTurns', 1),
  );
}

SkillBorrowRule _skillBorrowRule(_Json r) => SkillBorrowRule(
  drawCount: _integer(r, 'drawCount', 1),
  durationRounds: _integer(r, 'durationRounds', 1),
  clock: DurationClock.values.byName(r['clock'] as String? ?? 'globalRound'),
  revealedOnly: r['revealedOnly'] as bool? ?? true,
  allowExclusive: _bool(r, 'allowExclusive'),
);
