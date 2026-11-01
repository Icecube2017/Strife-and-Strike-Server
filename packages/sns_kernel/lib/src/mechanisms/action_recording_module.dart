import 'package:sns_kernel/src/mechanisms/bindings.dart';
import 'package:sns_kernel/src/state.dart';

final class RecordedAction {
  RecordedAction(this.id, this.actorId, this.damage, List<CardInstance> cards)
    : cards = List.unmodifiable(
        cards.map(
          (c) =>
              CardInstance(c.instanceId, c.definition)
                ..reinforced = c.reinforced,
        ),
      );
  final String id;
  final String actorId;
  final int damage;
  final List<CardInstance> cards;
}

/// Bounded history and committed replay cards live here, not in GameKernel.
/// Payment, target selection and replay execution remain kernel operations.
final class ActionRecordingModule {
  ActionRecordingModule({this.maxRecords = 5, this.maxPerRound = 2});
  final int maxRecords, maxPerRound;
  final Map<String, List<RecordedAction>> _records = {};
  final Map<String, RecordedAction> _committed = {};
  final Map<String, (int, int)> _uses = {};
  Map<String, List<RecordedAction>> get records => Map.unmodifiable({
    for (final entry in _records.entries)
      entry.key: List<RecordedAction>.unmodifiable(entry.value),
  });
  Map<String, RecordedAction> get committed => Map.unmodifiable(_committed);
  void commit(String owner, RecordedAction record) {
    if (!(_records[owner]?.remove(record) ?? false)) {
      throw StateError('Record is not owned');
    }
    _committed[record.id] = record;
  }

  RecordedAction? takeCommitted(String? id) => _committed.remove(id);
  void clearCommitted() => _committed.clear();
  void restoreCommitted(Map<String, RecordedAction> snapshot) {
    _committed
      ..clear()
      ..addAll(snapshot);
  }

  bool canRecord(String owner, int round, {ActionRecordingRule? rule}) {
    final previous = _uses[owner];
    final used = previous?.$1 == round ? previous!.$2 : 0;
    return (_records[owner]?.length ?? 0) < (rule?.capacity ?? maxRecords) &&
        used < (rule?.perRound ?? maxPerRound);
  }

  void record(
    String owner,
    int round,
    RecordedAction record, {
    ActionRecordingRule? rule,
  }) {
    if (!canRecord(owner, round, rule: rule)) {
      throw StateError('Action recording limit reached');
    }
    if (_records.values.expand((r) => r).any((r) => r.id == record.id) ||
        _committed.containsKey(record.id)) {
      throw StateError('Duplicate action record');
    }
    final previous = _uses[owner];
    final used = previous?.$1 == round ? previous!.$2 : 0;
    _records.putIfAbsent(owner, () => []).add(record);
    _uses[owner] = (round, used + 1);
  }
}
