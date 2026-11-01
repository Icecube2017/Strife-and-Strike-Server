/// Committed damage has one amount: after mitigation, before shield absorption.
/// Legacy journals used the post-shield remainder; keep their interpretation
/// explicit so recovery and client projections never add shield twice.
int damageBeforeShield(Map<String, Object?> data) {
  final amount = data['amount'] as int? ?? 0;
  return data['amountIncludesShield'] == true
      ? amount
      : amount + (data['shieldAbsorbed'] as int? ?? 0);
}

int damageAfterShield(Map<String, Object?> data) =>
    data['amountIncludesShield'] == true
    ? (damageBeforeShield(data) - (data['shieldAbsorbed'] as int? ?? 0)).clamp(
        0,
        1000000000,
      )
    : data['amount'] as int? ?? 0;

/// Only these two numeric damage parameters leave the kernel. HP changes,
/// overkill, conversion and recovery metadata remain internal facts/statistics.
Map<String, Object?> damageWireData(Map<String, Object?> data) => {
  for (final key in const [
    'sourceId',
    'targetId',
    'kind',
    'attack',
    'independent',
    'statusId',
    'packetId',
    'actionId',
    'component',
  ])
    if (data.containsKey(key)) key: data[key],
  'amount': damageBeforeShield(data),
  'shieldAbsorbed': data['shieldAbsorbed'] as int? ?? 0,
};
