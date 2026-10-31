import 'dart:convert';

/// Resolve confirmations to the exact outbox rows sent in this batch.
/// Audit events retain their source item's local_id; event_id distinguishes
/// repeated void/park/pull operations while offline. Older servers may omit
/// event_id, but a local_id confirmation is usable only when unambiguous.
Set<int> confirmedSyncQueueIds(
    List<Map<String, dynamic>> rows, List<dynamic> results) {
  final sent = rows.map((row) {
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
    } catch (_) {
      payload = const {};
    }
    return (
      id: row['id'] as int,
      type: row['entity_type'] as String,
      localId: (payload['local_id'] ?? payload['id'] ?? row['entity_id'])
          .toString(),
      eventId: payload['event_id']?.toString() ?? '',
    );
  }).toList();
  final acknowledgements = results.whereType<Map>().toList();
  final confirmed = <int>{};

  bool compatibleType(Map result, String type) =>
      result['entity_type'] == null || result['entity_type'] == type;

  for (final item in sent) {
    final byEvent = item.eventId.isEmpty
        ? const <Map>[]
        : acknowledgements
            .where((r) =>
                r['event_id'] == item.eventId && compatibleType(r, item.type))
            .toList();
    if (byEvent.isNotEmpty) {
      if (byEvent.length == 1 && byEvent.single['status'] == 'success') {
        confirmed.add(item.id);
      }
      continue;
    }

    final legacy = acknowledgements
        .where((r) =>
            (r['event_id'] == null || r['event_id'] == '') &&
            r['local_id'] == item.localId &&
            compatibleType(r, item.type))
        .toList();
    if (legacy.length != 1 || legacy.single['status'] != 'success') continue;

    final result = legacy.single;
    final candidates = sent.where((candidate) =>
        candidate.localId == item.localId &&
        compatibleType(result, candidate.type));
    if (candidates.length == 1) confirmed.add(item.id);
  }
  return confirmed;
}
