import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/services/sync_acknowledgements.dart';

Map<String, dynamic> queued(int id, String type, String localId,
        {String? eventId}) =>
    {
      'id': id,
      'entity_type': type,
      'entity_id': eventId ?? localId,
      'payload': jsonEncode({
        'local_id': localId,
        if (eventId != null) 'event_id': eventId,
      }),
    };

void main() {
  test('repeated void events are confirmed independently, in any order', () {
    final rows = [
      queued(1, 'order_item_void', 'item', eventId: 'event-a'),
      queued(2, 'order_item_void', 'item', eventId: 'event-b'),
    ];
    final result = confirmedSyncQueueIds(rows, [
      {
        'entity_type': 'order_item_void',
        'local_id': 'item',
        'event_id': 'event-b',
        'status': 'failed',
      },
      {
        'entity_type': 'order_item_void',
        'local_id': 'item',
        'event_id': 'event-a',
        'status': 'success',
      },
    ]);
    expect(result, {1});
  });

  test('legacy acknowledgement cannot confirm two events for one item', () {
    expect(
      confirmedSyncQueueIds([
        queued(1, 'order_item_void', 'item', eventId: 'a'),
        queued(2, 'order_item_void', 'item', eventId: 'b'),
      ], [
        {'entity_type': 'order_item_void', 'local_id': 'item', 'status': 'success'},
      ]),
      isEmpty,
    );
  });

  test('legacy single event remains compatible but unknown events do not', () {
    final rows = [queued(1, 'order_item_void', 'item', eventId: 'event')];
    expect(confirmedSyncQueueIds(rows, [
      {'local_id': 'item', 'status': 'success'},
    ]), {1});
    expect(confirmedSyncQueueIds(rows, [
      {'local_id': 'item', 'event_id': 'different-event', 'status': 'success'},
    ]), isEmpty);
  });

  test('same local ID across entity types cannot cross-confirm', () {
    final rows = [queued(1, 'order', 'same'), queued(2, 'transaction', 'same')];
    expect(confirmedSyncQueueIds(rows, [
      {'entity_type': 'order', 'local_id': 'same', 'status': 'success'},
      {'entity_type': 'transaction', 'local_id': 'same', 'status': 'failed'},
    ]), {1});
    expect(confirmedSyncQueueIds(rows, [
      {'local_id': 'same', 'status': 'success'},
    ]), isEmpty);
  });

  test('missing, failed and contradictory confirmations remain pending', () {
    final rows = [queued(1, 'product', 'product')];
    expect(confirmedSyncQueueIds(rows, []), isEmpty);
    expect(confirmedSyncQueueIds(rows, [
      {'local_id': 'product', 'status': 'failed'},
    ]), isEmpty);
    expect(confirmedSyncQueueIds(rows, [
      {'local_id': 'product', 'status': 'success'},
      {'local_id': 'product', 'status': 'failed'},
    ]), isEmpty);
  });

  group('rejectedSyncQueueErrors', () {
    test('explicit rejection carries the cloud reason', () {
      final rows = [
        queued(1, 'transaction', 'trx'),
        queued(2, 'order', 'order'),
      ];
      final rejected = rejectedSyncQueueErrors(rows, [
        {'entity_type': 'transaction', 'local_id': 'trx', 'status': 'success'},
        {
          'entity_type': 'order',
          'local_id': 'order',
          'status': 'failed',
          'error': 'produk harus cocok; ditemukan 0',
        },
      ]);
      expect(rejected, {2: 'produk harus cocok; ditemukan 0'});
    });

    test('void events are matched by event id, not by item', () {
      final rows = [
        queued(1, 'order_item_void', 'item', eventId: 'event-a'),
        queued(2, 'order_item_void', 'item', eventId: 'event-b'),
      ];
      final rejected = rejectedSyncQueueErrors(rows, [
        {
          'entity_type': 'order_item_void',
          'local_id': 'item',
          'event_id': 'event-b',
          'status': 'failed',
          'error': 'ditemukan 2',
        },
        {
          'entity_type': 'order_item_void',
          'local_id': 'item',
          'event_id': 'event-a',
          'status': 'success',
        },
      ]);
      expect(rejected, {2: 'ditemukan 2'});
    });

    test('missing, ambiguous or cross-type answers are not rejections', () {
      final rows = [queued(1, 'order', 'same')];
      expect(rejectedSyncQueueErrors(rows, []), isEmpty);
      expect(
          rejectedSyncQueueErrors(rows, [
            {'entity_type': 'transaction', 'local_id': 'same', 'status': 'failed'},
          ]),
          isEmpty);
      expect(
          rejectedSyncQueueErrors(rows, [
            {'local_id': 'same', 'status': 'failed'},
            {'local_id': 'same', 'status': 'failed'},
          ]),
          isEmpty);
    });

    test('rejection without a reason still gets a readable message', () {
      final rejected = rejectedSyncQueueErrors([queued(1, 'order', 'o')], [
        {'entity_type': 'order', 'local_id': 'o', 'status': 'failed'},
      ]);
      expect(rejected[1], 'Ditolak cloud tanpa keterangan');
    });
  });
}
