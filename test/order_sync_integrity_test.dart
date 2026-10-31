import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database db;
  late Product firstProduct;
  late Product secondProduct;
  final orders = OrderRepository();

  Future<Map<String, dynamic>> queuedPayload(
      String type, String localId) async {
    final rows = await db.query('sync_queue',
        where: 'entity_type = ? AND entity_id = ?', whereArgs: [type, localId]);
    return jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> transactionFor(String orderId) async {
    final rows = await db
        .query('transactions', where: 'order_id = ?', whereArgs: [orderId]);
    return queuedPayload('transaction', rows.single['id'] as String);
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-sync-integrity-');
    await databaseFactory.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({'saved_printers': <String>[]});
    db = await AppDatabase.instance.database;
    await db.delete('additional_charges');
    final products = ProductRepository();
    firstProduct =
        await products.createProduct(name: 'Menu Sama', price: 10000);
    secondProduct =
        await products.createProduct(name: 'Menu Sama', price: 20000);
    await CashierRepository().openShift(openedBy: 'Kasir Test', openingCash: 0);
  });

  tearDownAll(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  setUp(() => db.delete('sync_queue'));

  test('product identity survives add, partial transfer and payment', () async {
    final source = await orders.createOrder(tableNumber: 'ID-A', items: [
      OrderItemInput(productId: firstProduct.id, qty: 3),
    ]);
    await orders.addItemToOrder(orderId: source.id, items: [
      OrderItemInput(productId: secondProduct.id, qty: 1),
    ]);
    final sourceItems = await orders.getOrderItems(source.id);
    expect(sourceItems.map((i) => i.productId).toSet(),
        {firstProduct.id, secondProduct.id});
    final sourcePayload = await queuedPayload('order', source.id);
    expect((sourcePayload['items'] as List).map((i) => i['product_id']).toSet(),
        {firstProduct.id, secondProduct.id});

    final target = await orders.createOrder(tableNumber: 'ID-B', items: [
      OrderItemInput(productId: secondProduct.id, qty: 1),
    ]);
    final original =
        sourceItems.firstWhere((i) => i.productId == firstProduct.id);
    await orders.transferItemQty(
        itemId: original.id, qty: 1, targetOrderId: target.id);
    final transferred = (await orders.getOrderItems(target.id))
        .singleWhere((i) => i.productId == firstProduct.id);
    expect(transferred.id, isNot(original.id));
    expect(transferred.qty, 1);
    expect(transferred.productId, firstProduct.id);

    await orders.processPayment(
        orderId: target.id, paymentMethod: 'cash', paidAmount: 30000);
    final payload = await transactionFor(target.id);
    final items = (payload['items'] as List).cast<Map>();
    expect(items.map((i) => i['product_id']).toSet(),
        {firstProduct.id, secondProduct.id});
    expect(items.map((i) => i['id']), contains(transferred.id));
    final stored = await db.query('transaction_items');
    expect(stored.map((i) => i['product_id']).toSet(),
        containsAll([firstProduct.id, secondProduct.id]));
  });

  test('two offline partial voids retain two independent audit events',
      () async {
    final order = await orders.createOrder(tableNumber: 'VOID', items: [
      OrderItemInput(productId: firstProduct.id, qty: 5),
    ]);
    final item = (await orders.getOrderItems(order.id)).single;
    await orders.voidOrderItem(itemId: item.id, qty: 1, voidedBy: 'Manager');
    await orders.voidOrderItem(itemId: item.id, qty: 2, voidedBy: 'Manager');

    final jobs = await db.query('sync_queue',
        where: 'entity_type = ?', whereArgs: ['order_item_void']);
    expect(jobs.length, 2);
    expect(jobs.map((j) => j['entity_id']).toSet().length, 2);
    final payloads =
        jobs.map((j) => jsonDecode(j['payload'] as String) as Map).toList();
    expect(payloads.map((p) => p['local_id']).toSet(), {item.id});
    expect(payloads.map((p) => p['event_id']).toSet(),
        jobs.map((j) => j['entity_id']).toSet());
    expect(payloads.map((p) => p['qty']).toSet(), {1, 2});
    expect((await orders.getOrderItems(order.id)).single.qty, 2);
  });

  test('single payment has a zoned timestamp and preserves tender/change',
      () async {
    final order = await orders.createOrder(tableNumber: 'CASH', items: [
      OrderItemInput(productId: firstProduct.id, qty: 1),
    ]);
    await orders.processPayment(
        orderId: order.id, paymentMethod: 'cash', paidAmount: 20000);
    final payload = await transactionFor(order.id);
    final payment = (payload['payments'] as List).single as Map;
    expect(payment['created_at'], payload['transaction_date']);
    expect(payment['created_at'], endsWith('Z'));
    expect(payment['amount'], 20000);
    expect(payload['change_amount'], 10000);
  });

  test('split payment keeps each original payment timestamp', () async {
    final order = await orders.createOrder(tableNumber: 'SPLIT', items: [
      OrderItemInput(productId: secondProduct.id, qty: 1),
    ]);
    await orders.splitBillPayment(
        orderId: order.id, amount: 5000, paymentMethod: 'card');
    final earlier = DateTime.now().subtract(const Duration(hours: 4));
    await db.update('payments', {'created_at': earlier.toIso8601String()},
        where: 'order_id = ?', whereArgs: [order.id]);
    await orders.splitBillPayment(
        orderId: order.id, amount: 15000, paymentMethod: 'cash');
    final payload = await transactionFor(order.id);
    final payments = (payload['payments'] as List).cast<Map>();
    expect(payments.length, 2);
    expect(payments.first['created_at'], earlier.toUtc().toIso8601String());
    expect(payments.last['created_at'], payload['transaction_date']);
    expect(payments.every((p) => (p['created_at'] as String).endsWith('Z')),
        isTrue);
  });

  test(
      'backfill replaces an older success after a committed offline partial payment',
      () async {
    final order =
        await orders.createOrder(tableNumber: 'CRASH-REVISION', items: [
      OrderItemInput(productId: secondProduct.id, qty: 1),
    ]);
    await db.update('sync_queue', {'status': 'success'},
        where: "entity_type = 'order' AND entity_id = ?",
        whereArgs: [order.id]);
    final revision = order.updatedAt.add(const Duration(seconds: 1));
    final paymentId = Ulid.generate();
    // Reproduce process death after the money commits but before enqueue.
    await db.transaction((txn) async {
      await txn.insert('payments', {
        'id': paymentId,
        'order_id': order.id,
        'amount': 2500,
        'payment_method': 'card',
        'created_by': 'Kasir',
        'created_at': revision.toIso8601String(),
      });
      await txn.update(
          'orders',
          {
            'paid_amount': 2500,
            'payment_status': 'partial',
            'updated_at': revision.toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [order.id]);
    });
    expect(await orders.enqueueUnsyncedActiveOrders(), greaterThanOrEqualTo(1));
    final pending = await db.query('sync_queue',
        where: "entity_type = 'order' AND entity_id = ? AND status = 'pending'",
        whereArgs: [order.id]);
    expect(pending.length, 1);
    final payload = jsonDecode(pending.single['payload'] as String) as Map;
    expect(payload['payment_info']['paid_amount'], 2500);
    expect(payload['payment_info']['restore']['payments'][0]['id'], paymentId);
    expect(DateTime.parse(payload['updated_at']), revision.toUtc());
    final before = await db.query('sync_queue', orderBy: 'id');
    expect(await orders.enqueueUnsyncedActiveOrders(), 0);
    expect(await db.query('sync_queue', orderBy: 'id'), before,
        reason: 'matching current revisions must not churn the outbox');
  });

  test(
      'backfill retries malformed or failed latest revisions and upgrades old snapshots',
      () async {
    final order =
        await orders.createOrder(tableNumber: 'BACKFILL-RETRY', items: [
      OrderItemInput(productId: firstProduct.id, qty: 1),
    ]);
    Future<Map<String, Object?>> current() async =>
        (await db.query('sync_queue',
                where: "entity_type = 'order' AND entity_id = ?",
                whereArgs: [order.id],
                orderBy: 'id DESC',
                limit: 1))
            .single;
    final original = await current();
    final oldPayload = jsonDecode(original['payload'] as String) as Map;
    (oldPayload['payment_info'] as Map).remove('restore');
    await db.update(
        'sync_queue', {'payload': jsonEncode(oldPayload), 'status': 'success'},
        where: 'id = ?', whereArgs: [original['id']]);
    await orders.enqueueUnsyncedActiveOrders();
    var latest = await current();
    expect(latest['id'], isNot(original['id']));
    expect(
        jsonDecode(latest['payload'] as String)['payment_info']['restore']
            ['version'],
        1);

    for (final change in [
      {'payload': '{malformed', 'status': 'pending'},
      {'status': 'failed'},
    ]) {
      final previousId = latest['id'];
      await db.update('sync_queue', change,
          where: 'id = ?', whereArgs: [previousId]);
      await orders.enqueueUnsyncedActiveOrders();
      latest = await current();
      expect(latest['id'], isNot(previousId));
      expect(latest['status'], 'pending');
      expect(jsonDecode(latest['payload'] as String)['local_id'], order.id);
    }
    expect(await orders.enqueueUnsyncedActiveOrders(), 0);
  });

  test(
      'concurrent backfills and partial payments retain only the latest pending snapshot',
      () async {
    final order =
        await orders.createOrder(tableNumber: 'SNAPSHOT-RACE', items: [
      OrderItemInput(productId: secondProduct.id, qty: 2),
    ]);
    await db.delete('sync_queue',
        where: "entity_type = 'order' AND entity_id = ?",
        whereArgs: [order.id]);
    await Future.wait([
      orders.enqueueUnsyncedActiveOrders(),
      orders.splitBillPayment(
          orderId: order.id, amount: 1000, paymentMethod: 'cash'),
      orders.enqueueUnsyncedActiveOrders(),
      orders.splitBillPayment(
          orderId: order.id, amount: 2000, paymentMethod: 'card'),
      orders.enqueueUnsyncedActiveOrders(),
    ]);
    final current = (await orders.getOrderById(order.id))!;
    expect(current.paidAmount, 3000);
    final queued = await db.query('sync_queue',
        where: "entity_type = 'order' AND entity_id = ? AND status = 'pending'",
        whereArgs: [order.id]);
    expect(queued.length, 1);
    final payload = jsonDecode(queued.single['payload'] as String) as Map;
    expect(payload['payment_info']['paid_amount'], current.paidAmount);
    expect(DateTime.parse(payload['updated_at']), current.updatedAt.toUtc());
    final payments =
        (payload['payment_info']['restore']['payments'] as List).cast<Map>();
    expect(payments.map((p) => p['amount']).toSet(), {1000, 2000});
    expect(await orders.enqueueUnsyncedActiveOrders(), 0);
  });

  test(
      'one kitchen line advances parent revision and snapshot without changing overall status',
      () async {
    final order =
        await orders.createOrder(tableNumber: 'KITCHEN-REVISION', items: [
      OrderItemInput(productId: firstProduct.id, qty: 1),
      OrderItemInput(productId: secondProduct.id, qty: 1),
    ]);
    final item = (await orders.getOrderItems(order.id)).first;
    final stale = (await db.query('sync_queue',
            where: "entity_type = 'order' AND entity_id = ?",
            whereArgs: [order.id]))
        .single;
    await orders.updateItemStatus(item.id, 'ready');
    final updated = (await orders.getOrderById(order.id))!;
    expect(updated.orderStatus, 'cooking');
    final changed = (await orders.getOrderItems(order.id))
        .firstWhere((line) => line.id == item.id);
    expect(updated.updatedAt, changed.updatedAt);
    expect(updated.updatedAt.isAfter(order.updatedAt), isTrue);
    final snapshot = await queuedPayload('order', order.id);
    expect(
        (snapshot['items'] as List)
            .singleWhere((line) => line['id'] == item.id)['status'],
        'ready');

    // Leave only the previous acknowledgement, as if enqueue was interrupted.
    await db.delete('sync_queue',
        where: "entity_type = 'order' AND entity_id = ?",
        whereArgs: [order.id]);
    await db.insert('sync_queue', {...stale, 'status': 'success'});
    await orders.enqueueUnsyncedActiveOrders();
    final pending = (await db.query('sync_queue',
            where:
                "entity_type = 'order' AND entity_id = ? AND status = 'pending'",
            whereArgs: [order.id]))
        .single;
    final recovered = jsonDecode(pending['payload'] as String) as Map;
    expect(
        (recovered['items'] as List)
            .singleWhere((line) => line['id'] == item.id)['status'],
        'ready');
    expect(DateTime.parse(recovered['updated_at']), updated.updatedAt.toUtc());
  });
}
