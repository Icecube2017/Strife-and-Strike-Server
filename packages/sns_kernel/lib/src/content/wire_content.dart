import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sns_kernel/src/preview/preview_models.dart';

const _presentationFields = {
  'name',
  'description',
  'label',
  'text',
  'comment',
  'notes',
};

/// Stable display lookup key; the network carries no readable option wording.
String presentationLabelCode(String label) =>
    'text_${sha256.convert(utf8.encode(label))}';
// These hold gameplay data, not definition metadata. Dictionary keys and literal
// values must survive even when they happen to spell "name" or "description".
const _dataFields = {'initial', 'literal', 'references'};
const _stateDataFields = {
  'value',
  'counters',
  'uses',
  'revealedCards',
  'reciprocalDice',
  'restrictedCardTags',
  'anchoredCardTags',
};
const _registryFields = {
  'mechanisms',
  'options',
  'modifiers',
  'content',
  'cardEffectOverrides',
  'statusGainMultipliers',
  'rotationBonus',
};

Object? _copy(Object? value) => switch (value) {
  Map() => {for (final e in value.entries) e.key as String: _copy(e.value)},
  List() => value.map(_copy).toList(),
  _ => value,
};
Object? _project(
  Object? value, {
  bool registry = false,
  bool snapshot = false,
}) {
  if (value is List) {
    return value.map((v) => _project(v, snapshot: snapshot)).toList();
  }
  if (value is! Map) return value;
  return <String, Object?>{
    if (snapshot && !registry && value['label'] is String)
      'labelCode': presentationLabelCode(value['label'] as String),
    for (final e in value.entries)
      if (registry || !_presentationFields.contains(e.key))
        e.key as String:
            (_dataFields.contains(e.key) ||
                (snapshot && _stateDataFields.contains(e.key)))
            ? _copy(e.value)
            : _project(
                e.value,
                registry: e.value is Map && _registryFields.contains(e.key),
                snapshot: snapshot,
              ),
  };
}

/// A detached executable bundle for clients. Source remarks remain on server.
Map<String, Object?> clientExecutionContent(String source) =>
    _project(jsonDecode(source))! as Map<String, Object?>;
String clientContentHash(String source) =>
    executableContentHash(jsonEncode(clientExecutionContent(source)));

/// For network projections only; recovery continues using the full kernel view.
Map<String, Object?> machineStateView(Map<String, Object?> view) =>
    _project(view, snapshot: true)! as Map<String, Object?>;
