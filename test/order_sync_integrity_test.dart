import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database db;
  late Product firstProduct;
  late Product secondProduct;
  final orders = OrderRepository();

  Future<Map<String, dynamic>> queuedPayload(String type, String localId) async {
    final rows = await db.query('sync_queue',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [type, localId]);
    return jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> transactionFor(String orderId) async {
    final rows = await db.query('transactions',
        where: 'order_id = ?', whereArgs: [orderId]);
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
    firstProduct = await products.createProduct(name: 'Menu Sama', price: 10000);
    secondProduct = await products.createProduct(name: 'Menu Sama', price: 20000);
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
    final original = sourceItems.firstWhere((i) => i.productId == firstProduct.id);
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

  test('two offline partial voids retain two independent audit events', () async {
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
    final payloads = jobs
        .map((j) => jsonDecode(j['payload'] as String) as Map)
        .toList();
    expect(payloads.map((p) => p['local_id']).toSet(), {item.id});
    expect(payloads.map((p) => p['event_id']).toSet(),
        jobs.map((j) => j['entity_id']).toSet());
    expect(payloads.map((p) => p['qty']).toSet(), {1, 2});
    expect((await orders.getOrderItems(order.id)).single.qty, 2);
  });

  test('single payment has a zoned timestamp and preserves tender/change', () async {
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
    expect(payments.every((p) => (p['created_at'] as String).endsWith('Z')), isTrue);
  });
}
