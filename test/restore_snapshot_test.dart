import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/services/reservation_service.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late Database db;
  late Map<String, dynamic> response;
  late String orderId, itemId, paymentId, shiftId, movementId, chargeSyncId;
  final repo = OrderRepository();
  const originalTime = '2026-09-18T07:30:00Z';
  const reservationId = 'cloud-reservation-recover';

  Map<String, dynamic> getOrder() =>
      (response['data']['unpaid_orders'] as List).first as Map<String, dynamic>;

  Map<String, dynamic> getPay() {
    final raw = getOrder()['payment_info'];
    return raw is String ? jsonDecode(raw) as Map<String, dynamic> : raw;
  }

  Future<void> seedCharge(String syncId,
      {String name = 'PB1', int active = 1}) async {
    await db.insert('additional_charges', {
      'sync_id': syncId,
      'name': name,
      'charge_type': 'percentage',
      'value': 10.0,
      'is_active': active,
    });
  }

  CloudReservation reservation(double paid) => CloudReservation(
        id: reservationId,
        customerName: 'Tamu',
        customerPhone: '08123',
        pax: 2,
        date: '2026-09-19',
        time: '19:00',
        items: const [],
        total: 109000,
        paidAmount: paid,
        remaining: 109000 - paid,
        status: 'confirmed',
        notes: '',
      );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pos-restore-snapshot-');
    await databaseFactory.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({
      'saved_printers': <String>[],
      'outlet_cloud_env': 'development',
      'outlet_cloud_api_url': 'http://127.0.0.1:${server.port}',
      'outlet_cloud_api_key': 'isolated-key',
      'outlet_cloud_outlet_id': 'isolated-outlet',
    });
    db = await AppDatabase.instance.database;
    orderId = Ulid.generate();
    itemId = Ulid.generate();
    paymentId = Ulid.generate();
    shiftId = Ulid.generate();
    movementId = Ulid.generate();
    chargeSyncId = Ulid.generate();
    response = {
      'success': true,
      'data': <String, dynamic>{
        'additional_charges': [
          {
            'local_id': chargeSyncId,
            'name': 'PB1',
            'charge_type': 'percentage',
            'value': 10,
            'is_active': true
          },
        ],
        'open_shifts': [
          {
            'id': 'canonical-shift',
            'local_id': shiftId,
            'opened_by': 'Kasir',
            'opened_at': '2026-09-19T03:00:00Z',
            'opening_cash': 50000
          },
        ],
        'unpaid_orders': [
          {
            'id': 'canonical-order',
            'local_id': orderId,
            'table_number': 'R1',
            'customer_name': 'Tamu',
            'pax': 2,
            'status': 'cooking',
            'total_amount': 109000,
            'created_at': originalTime,
            'updated_at': originalTime,
            'items': [
              {
                'id': itemId,
                'product_id': Ulid.generate(),
                'category_id': Ulid.generate(),
                'product_name': 'Paket',
                'qty': 1,
                'price': 100000,
                'destination': 'kitchen',
                'status': 'ready',
                'notes': 'Tidak pedas',
                'addons': '[{"id":"extra","name":"Keju","price":5000}]',
                'waiter_name': 'Pelayan',
                'is_additional': 1,
                'created_at': originalTime,
                'updated_at': originalTime
              },
            ],
            'payment_info': {
              'paid_amount': 25000,
              'payment_status': 'partial',
              'restore': {
                'version': 1,
                'reservation_id': reservationId,
                'created_by': 'Kasir Asal',
                'customer_phone': '08123',
                'customer_id': 'customer-source',
                'is_holding': 0,
                'is_merged': 0,
                'merged_from': null,
                'discount_note': 'Member',
                'payments': [
                  {
                    'id': paymentId,
                    'amount': 25000,
                    'payment_method': 'reservasi_dp',
                    'payment_note': 'Transfer DP lama',
                    'created_by': 'Admin',
                    'created_at': originalTime
                  },
                ],
                'charges': [
                  {
                    'sync_id': chargeSyncId,
                    'is_auto': true,
                    'name': 'PB1',
                    'charge_type': 'percentage',
                    'value': 10,
                    'applied_amount': 10000,
                    'created_at': originalTime,
                    'updated_at': originalTime
                  },
                  {
                    'sync_id': null,
                    'is_auto': false,
                    'name': 'Diskon',
                    'charge_type': 'fixed',
                    'value': 1000,
                    'applied_amount': -1000,
                    'created_at': originalTime,
                    'updated_at': originalTime
                  },
                ],
              },
            },
          },
        ],
        'cash_movements': [
          {
            'id': 'canonical-movement',
            'local_id': movementId,
            'shift_id': shiftId,
            'movement_type': 'in',
            'amount': 1000,
            'counterpart_name': 'Modal',
            'note': 'Catatan',
            'created_at': originalTime
          },
        ],
      },
    };
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });
  tearDownAll(() => server.close(force: true));

  test(
      'string snapshot restores DP and charges, top-up and settlement preserve history',
      () async {
    final seedId = Ulid.generate();
    await seedCharge(seedId); // same name is deliberately not an identity match
    getOrder()['payment_info'] = jsonEncode(getPay());
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result, {'shifts': 1, 'orders': 1, 'movements': 1});
    final restored = (await repo.getOrderById(orderId))!;
    expect(restored.paidAmount, 25000);
    expect(restored.reservationId, reservationId);
    expect(restored.createdBy, 'Kasir Asal');
    expect(restored.customerPhone, '08123');
    expect(restored.discountNote, 'Member');
    final item = (await repo.getOrderItems(orderId)).single;
    expect(item.id, itemId);
    expect(item.notes, 'Tidak pedas');
    expect(item.addons, contains('Keju'));
    expect(item.waiterName, 'Pelayan');
    expect(item.isAdditional, 1);
    expect(item.createdAt.toUtc(), DateTime.parse(originalTime));
    final masters = await db.query('additional_charges');
    final master = masters.singleWhere((m) => m['sync_id'] == chargeSyncId);
    expect(masters.singleWhere((m) => m['sync_id'] == seedId)['is_active'], 0);
    final charges = await repo.getOrderCharges(orderId);
    expect(charges.singleWhere((c) => c.isAuto).chargeId, master['id']);
    expect(charges.singleWhere((c) => c.isManual).appliedAmount, -1000);

    for (var i = 0; i < 2; i++) {
      final opened = await ReservationService.instance.openAsOrder(
          reservation: reservation(40000),
          tableNumber: 'NEVER-MOVE',
          cashierName: 'Kasir');
      expect(opened.order.id, orderId);
      expect(opened.order.paidAmount, 40000);
    }
    final again = await CloudSyncService.instance.restoreFromCloud();
    expect(again['orders'], 0);
    expect(again['skipped_existing'], 3);
    expect((await repo.getOrderById(orderId))!.paidAmount, 40000);
    expect((await repo.getOrderItems(orderId)).single.id, itemId);
    expect((await repo.getOrderCharges(orderId)).length, 2);

    await repo.processPayment(
        orderId: orderId,
        paymentMethod: 'cash',
        paidAmount: 69000,
        createdBy: 'Kasir');
    final tx =
        (await db.query('sync_queue', where: "entity_type = 'transaction'"))
            .single;
    final payload = jsonDecode(tx['payload'] as String) as Map;
    expect(payload['reservation_id'], reservationId);
    final payments = (payload['payments'] as List).cast<Map>();
    expect(payments.map((p) => p['amount']), [25000, 15000, 69000]);
    expect(payments.first['payment_method'], 'reservasi_dp');
    expect(DateTime.parse(payments.first['created_at'] as String),
        DateTime.parse(originalTime));
    expect(payments.first['payment_note'], 'Transfer DP lama');
    expect(
        (await db.query('payments', where: 'id = ?', whereArgs: [paymentId]))
            .length,
        1);
    await CloudSyncService.instance.restoreFromCloud();
    expect((await repo.getOrderById(orderId))!.isPaid, isTrue);
    expect((await db.query('payments')).length, 3);
  });

  test('second restore preserves local offline edits and closed shifts',
      () async {
    await CloudSyncService.instance.restoreFromCloud();
    await db.update('order_items', {'notes': 'Perubahan offline'},
        where: 'id = ?', whereArgs: [itemId]);
    await db.update(
        'cashier_shifts', {'status': 'closed', 'notes': 'Sudah tutup'},
        where: 'id = ?', whereArgs: [shiftId]);
    await db.update('cashier_cash_movements', {'amount': 2000},
        where: 'id = ?', whereArgs: [movementId]);
    final before = await db.query('orders');
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['skipped_existing'], 3);
    expect(await db.query('orders'), before);
    expect(
        (await repo.getOrderItems(orderId)).single.notes, 'Perubahan offline');
    expect((await db.query('cashier_shifts')).single['status'], 'closed');
    expect((await db.query('cashier_cash_movements')).single['amount'], 2000);
  });

  test('recovered bill occupies existing table without reopening settled bill',
      () async {
    final tableId = Ulid.generate();
    await db.insert('tables', {
      'id': tableId,
      'table_number': 'R1',
      'capacity': 8,
      'status': 'available',
    });
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['orders'], 1);
    final table = (await db.query('tables')).single;
    expect(table['id'], tableId);
    expect(table['capacity'], 8);
    expect(table['status'], 'occupied');
    expect((await repo.getActiveOrdersByTable())['R1']?.id, orderId);

    // A repeated old cloud response must not occupy the table again after
    // the locally retained bill has been settled and the table released.
    await db.update('orders', {'payment_status': 'paid', 'paid_amount': 109000},
        where: 'id = ?', whereArgs: [orderId]);
    await db.update('tables', {'status': 'available'},
        where: 'id = ?', whereArgs: [tableId]);
    final repeated = await CloudSyncService.instance.restoreFromCloud();
    expect(repeated['orders'], 0);
    expect((await db.query('tables')).single['status'], 'available');
  });

  test('fresh install creates a missing named table for its recovered bill',
      () async {
    expect(await db.query('tables'), isEmpty);
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['orders'], 1);
    final table = (await db.query('tables')).single;
    expect(table['table_number'], 'R1');
    expect(table['status'], 'occupied');
    expect(table['id'], hasLength(26));
  });

  test('another local bill on the recovered table prevents atomic restore',
      () async {
    final localOrder = Ulid.generate();
    final tableId = Ulid.generate();
    await db.insert('tables', {
      'id': tableId,
      'table_number': 'R1',
      'capacity': 6,
      'status': 'occupied',
    });
    await db.insert('orders', {
      'id': localOrder,
      'table_number': 'R1',
      'total_amount': 1000,
    });
    await seedCharge(chargeSyncId);
    final before = (await db.query('tables')).single;
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['error'], contains('tagihan lokal lain'));
    expect((await db.query('orders')).single['id'], localOrder);
    expect((await db.query('tables')).single, before);
    expect(await db.query('cashier_shifts'), isEmpty);
    expect(await db.query('payments'), isEmpty);
    expect(await db.query('order_items'), isEmpty);
  });

  test('unnamed normal bill refuses recovery instead of becoming hidden',
      () async {
    getOrder().remove('table_number');
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['error'], contains('Nama meja'));
    expect(await db.query('orders'), isEmpty);
    expect(await db.query('tables'), isEmpty);
    expect(await db.query('cashier_shifts'), isEmpty);
    expect(await db.query('additional_charges'), isEmpty);
  });

  for (final flag in ['is_holding', 'is_merged']) {
    test('$flag recovery does not create or occupy a cashier table', () async {
      getPay()['restore'][flag] = 1;
      final result = await CloudSyncService.instance.restoreFromCloud();
      expect(result['orders'], 1);
      expect(await db.query('tables'), isEmpty);
    });
  }

  test('legacy string retains paid balance and blocks both payment paths',
      () async {
    getOrder()['payment_info'] =
        jsonEncode({'paid_amount': 25000, 'payment_status': 'partial'});
    getOrder()['total_amount'] = 100000;
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['orders'], 1);
    expect((await repo.getOrderById(orderId))!.paidAmount, 25000);
    expect(await db.query('payments'), isEmpty);
    final incomplete =
        throwsA(predicate((e) => '$e'.contains('belum lengkap')));
    await expectLater(
        repo.processPayment(
            orderId: orderId, paymentMethod: 'cash', paidAmount: 84000),
        incomplete);
    await expectLater(
        repo.splitBillPayment(
            orderId: orderId, amount: 1000, paymentMethod: 'cash'),
        incomplete);
    expect(await db.query('transactions'), isEmpty);
    expect((await repo.getOrderById(orderId))!.paidAmount, 25000);
  });

  test('legacy order with missing charge details refuses recovery atomically',
      () async {
    getOrder()['payment_info'] =
        jsonEncode({'paid_amount': 0, 'payment_status': 'unpaid'});
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['error'],
        contains('biaya atau diskon order lama belum lengkap'));
    expect(await db.query('orders'), isEmpty);
    expect(await db.query('cashier_shifts'), isEmpty);
    expect(await db.query('additional_charges'), isEmpty);
  });

  test('mismatched snapshot payment sum rolls back masters, shifts and orders',
      () async {
    final seedId = Ulid.generate();
    await seedCharge(seedId);
    getPay()['restore']['payments'][0]['amount'] = 24000;
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['error'], contains('pembayaran cloud belum lengkap'));
    expect(await db.query('orders'), isEmpty);
    expect(await db.query('order_items'), isEmpty);
    expect(await db.query('payments'), isEmpty);
    expect(await db.query('cashier_shifts'), isEmpty);
    expect((await db.query('additional_charges')).single['sync_id'], seedId);
    expect((await db.query('additional_charges')).single['is_active'], 1);
  });

  test(
      'working register never guesses a charge by name or activates missing masters',
      () async {
    await CashierRepository().openShift(openedBy: 'Lokal', openingCash: 0);
    await seedCharge(Ulid.generate());
    response['data']['open_shifts'] = [];
    response['data']['cash_movements'] = [];
    final before = await db.query('additional_charges');
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['error'], contains('Master biaya belum tersedia'));
    expect(await db.query('additional_charges'), before);
    expect(await db.query('orders'), isEmpty);
  });

  test(
      'stable item identity collision rolls back without replacing unrelated order',
      () async {
    await seedCharge(chargeSyncId);
    final otherOrder = Ulid.generate();
    await db.insert('orders',
        {'id': otherOrder, 'table_number': 'LOCAL', 'total_amount': 1});
    await db.insert('order_items', {
      'id': itemId,
      'order_id': otherOrder,
      'product_name': 'Lokal',
      'qty': 1,
      'price': 1,
      'destination': 'bar'
    });
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result['error'], isNotNull);
    expect((await db.query('orders')).single['id'], otherOrder);
    expect((await db.query('order_items')).single['product_name'], 'Lokal');
    expect(await db.query('cashier_shifts'), isEmpty);
    expect(await db.query('payments'), isEmpty);
  });

  test(
      'unsupported snapshot and malformed response never mutate fresh database',
      () async {
    await seedCharge(Ulid.generate());
    final before = await db.query('additional_charges');
    getPay()['restore']['version'] = 2;
    expect((await CloudSyncService.instance.restoreFromCloud())['error'],
        contains('Versi'));
    response['data']['unpaid_orders'] = 'not-json';
    expect((await CloudSyncService.instance.restoreFromCloud())['error'],
        isNotNull);
    expect(await db.query('additional_charges'), before);
    expect(await db.query('orders'), isEmpty);
    expect(await db.query('cashier_shifts'), isEmpty);
  });

  test(
      'actual order outbox serializes portable recovery fields with original payment time',
      () async {
    final productId = Ulid.generate();
    await db.insert('products',
        {'id': productId, 'name': 'Menu', 'price': 100000, 'stock': 1});
    await seedCharge(chargeSyncId);
    await CashierRepository().openShift(openedBy: 'Kasir', openingCash: 0);
    final created = await repo.createOrder(
        tableNumber: 'SNAPSHOT',
        reservationId: reservationId,
        customerPhone: '08123',
        createdBy: 'Pembuat',
        items: [
          OrderItemInput(productId: productId, qty: 1, notes: 'Catatan asli')
        ]);
    await repo.splitBillPayment(
        orderId: created.id,
        amount: 25000,
        paymentMethod: 'reservasi_dp',
        note: 'DP asli',
        createdBy: 'Admin');
    final originalPayment = (await db.query('payments')).single;
    await db.update(
        'payments',
        {
          'created_at': DateTime.parse(originalTime).toLocal().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [originalPayment['id']]);
    await db.delete('sync_queue', where: "entity_type = 'order'");
    await repo.enqueueUnsyncedActiveOrders();
    final queued =
        (await db.query('sync_queue', where: "entity_type = 'order'")).single;
    final payload = jsonDecode(queued['payload'] as String) as Map;
    final restore = payload['payment_info']['restore'] as Map;
    expect(restore['version'], 1);
    expect(restore['reservation_id'], reservationId);
    expect(restore['created_by'], 'Pembuat');
    final payment = (restore['payments'] as List).single as Map;
    expect(payment['id'], originalPayment['id']);
    expect(DateTime.parse(payment['created_at']), DateTime.parse(originalTime));
    expect(payment['payment_method'], 'reservasi_dp');
    expect(payment['payment_note'], 'DP asli');
    final charge = (restore['charges'] as List).single as Map;
    expect(charge['sync_id'], chargeSyncId);
    expect(charge['is_auto'], true);
    expect(charge.containsKey('charge_id'), false);
    final item = (payload['items'] as List).single as Map;
    expect(item['id'], (await repo.getOrderItems(created.id)).single.id);
    expect(item['notes'], 'Catatan asli');
    expect(item['addons'], '');
    expect(item['created_at'], endsWith('Z'));
    expect(item['updated_at'], endsWith('Z'));
  });
}
