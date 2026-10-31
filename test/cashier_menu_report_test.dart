import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory directory;

  Future<String> product(String name, String kind,
      {bool deleted = false}) async {
    final id = Ulid.generate();
    await db.insert('products', {
      'id': id,
      'name': name,
      'price': 1000,
      'stock': 0,
      'menu_kind': kind,
      'is_deleted': deleted ? 1 : 0,
    });
    return id;
  }

  Future<String> shift(DateTime start, {DateTime? end}) async {
    final id = Ulid.generate();
    await db.insert('cashier_shifts', {
      'id': id,
      'opened_by': 'Kasir uji',
      'opened_at': start.toIso8601String(),
      'closed_at': end?.toIso8601String(),
      'status': end == null ? 'open' : 'closed',
    });
    return id;
  }

  Map<String, dynamic> item(
          String? productId, String name, int quantity, String? kind) =>
      {
        'product_id': productId,
        'product_name': name,
        'qty': quantity,
        'menu_kind': kind,
      };

  Future<String> sold(DateTime at, List<Map<String, dynamic>> items,
      {String paymentStatus = 'paid',
      String? transactionStatus = 'completed',
      bool voided = false,
      bool cancelledAt = false,
      bool holding = false,
      bool complimentary = false}) async {
    final id = Ulid.generate();
    final total = complimentary
        ? 0
        : items.fold<int>(0, (sum, row) => sum + (row['qty'] as int) * 1000);
    await db.insert('orders', {
      'id': id,
      'table_number': id,
      'total_amount': total,
      'paid_amount': paymentStatus == 'paid' ? total : 0,
      'payment_status': paymentStatus,
      'is_holding': holding ? 1 : 0,
      'voided_at': voided ? at.toIso8601String() : null,
      'complimented_at': complimentary ? at.toIso8601String() : null,
    });
    for (final row in items) {
      await db.insert('order_items', {
        ...row,
        'id': Ulid.generate(),
        'order_id': id,
        'price': 1000,
        'destination': 'kitchen',
      });
    }
    if (transactionStatus != null) {
      await db.insert('transactions', {
        'id': Ulid.generate(),
        'order_id': id,
        'total_amount': total,
        'payment_method': complimentary ? 'compliment' : 'cash',
        'status': transactionStatus,
        'cancelled_at': cancelledAt ? at.toIso8601String() : null,
        'transaction_date': at.toIso8601String(),
      });
    }
    return id;
  }

  Map<String, dynamic> group(Map<String, dynamic> report, String kind) =>
      (report['menu_items_by_kind'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((row) => row['menu_kind'] == kind);

  Future<Map<String, dynamic>> queued(String entity, String id) async {
    final rows = await db.query('sync_queue',
        where: 'entity_type=? AND entity_id=?',
        whereArgs: [entity, id],
        orderBy: 'id DESC');
    return jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>;
  }

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-sold-menu-');
    await databaseFactory.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({'saved_printers': <String>[]});
    db = await AppDatabase.instance.database;
  });
  tearDown(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('sold menu quantities use finalized orders once within the entire shift',
      () async {
    final start = DateTime(2026, 10, 30, 8);
    final end = DateTime(2026, 10, 31, 18);
    final id = await shift(start, end: end);
    final food = await product('Nama katalog berubah', 'food');
    final secondFood = await product('Produk berbeda', 'food');
    final beverage = await product('Kopi', 'beverage');
    final activity = await product('ATV', 'activity');
    final other = await product('Lainnya', 'other');
    final first = await sold(DateTime(2026, 10, 30, 12), [
      item(food, 'Nasi lama', 2, 'food'),
      item(beverage, 'Kopi', 3, 'beverage'),
      item(activity, 'ATV', 1, 'activity'),
      item(other, 'Lainnya', 4, 'other'),
    ]);
    // Two payments and a duplicate historical transaction cannot multiply
    // order-line quantities: the report uses transaction existence only.
    for (final method in ['cash', 'qris']) {
      await db.insert('payments', {
        'id': Ulid.generate(),
        'order_id': first,
        'amount': 5000,
        'payment_method': method,
        'created_by': 'Kasir',
        'created_at': DateTime(2026, 10, 30, 12).toIso8601String(),
      });
    }
    await db.insert('transactions', {
      'id': Ulid.generate(),
      'order_id': first,
      'total_amount': 10000,
      'payment_method': 'cash',
      'status': 'completed',
      'transaction_date': DateTime(2026, 10, 30, 12).toIso8601String(),
    });
    await sold(DateTime(2026, 10, 31, 12), [
      item(food, 'Nasi lama', 5, 'food'),
      item(food, 'Nasi edisi baru', 2, 'food'),
      item(secondFood, 'Nasi lama', 1, 'food'),
    ]);
    await sold(DateTime(2026, 10, 31, 16), [item(food, 'Nasi lama', 3, 'food')],
        complimentary: true);
    await sold(start, [item(food, 'Nasi lama', 1, 'food')]);
    await sold(start.subtract(const Duration(microseconds: 1)),
        [item(food, 'Sebelum shift', 100, 'food')]);
    await sold(end, [item(food, 'Shift berikutnya', 100, 'food')]);
    await sold(DateTime(2026, 10, 31, 17), [item(food, 'Void', 100, 'food')],
        voided: true);
    await sold(
        DateTime(2026, 10, 31, 17), [item(food, 'Cancelled', 100, 'food')],
        transactionStatus: 'cancelled');
    await sold(
        DateTime(2026, 10, 31, 17), [item(food, 'Cancelled at', 100, 'food')],
        cancelledAt: true);
    await sold(DateTime(2026, 10, 31, 17), [item(food, 'Pending', 100, 'food')],
        paymentStatus: 'unpaid', transactionStatus: null);
    await sold(DateTime(2026, 10, 31, 17), [item(food, 'Partial', 100, 'food')],
        paymentStatus: 'partial');
    await sold(DateTime(2026, 10, 31, 17), [item(food, 'Holding', 100, 'food')],
        holding: true);

    final report = await CashierRepository().getShiftReport(id);
    expect(report['crosses_day'], isTrue);
    expect(report['menu_quantity'], 22);
    final groups = report['menu_items_by_kind'] as List;
    expect(groups.map((g) => g['menu_kind']),
        ['food', 'beverage', 'activity', 'other']);
    expect(groups.map((g) => g['label']),
        ['Makanan', 'Minuman', 'Aktivitas', 'Lainnya']);
    expect(groups.map((g) => g['quantity']), [14, 3, 1, 4]);
    final foods = (group(report, 'food')['items'] as List).cast<Map>();
    expect(foods, hasLength(3));
    expect(
        foods.singleWhere((r) =>
            r['product_id'] == food &&
            r['product_name'] == 'Nasi lama')['quantity'],
        11);
    expect(
        foods.singleWhere(
            (r) => r['product_name'] == 'Nasi edisi baru')['quantity'],
        2);
    expect(
        foods.singleWhere((r) => r['product_id'] == secondFood)['quantity'], 1);
  });

  test(
      'new order types survive additions quantity splits transfers merges and outbox',
      () async {
    final repo = OrderRepository();
    final cashier = CashierRepository();
    final opened = await cashier.openShift(openedBy: 'Kasir', openingCash: 0);
    final pid = await product('Nama pertama', 'food');
    final source = await repo.createOrder(tableNumber: '1', items: [
      OrderItemInput(productId: pid, qty: 5),
    ]);
    final original = (await repo.getOrderItems(source.id)).single;
    expect(original.menuKind, 'food');
    await db.update('products', {'menu_kind': 'beverage', 'name': 'Nama kedua'},
        where: 'id=?', whereArgs: [pid]);
    await repo.addItemToOrder(orderId: source.id, items: [
      OrderItemInput(productId: pid, qty: 1),
    ]);
    final target = await repo.createOrder(tableNumber: '2', items: [
      OrderItemInput(productId: pid, qty: 2),
    ]);
    await repo.transferItemQty(
        itemId: original.id, qty: 2, targetOrderId: target.id);
    await repo.mergeOrders(targetOrderId: target.id, sourceOrderId: source.id);
    final items = await repo.getOrderItems(target.id);
    expect(
        items
            .where((i) => i.menuKind == 'food')
            .fold<int>(0, (n, i) => n + i.qty),
        5);
    expect(
        items
            .where((i) => i.menuKind == 'beverage')
            .fold<int>(0, (n, i) => n + i.qty),
        3);
    expect(
        items
            .where((i) => i.menuKind == 'food')
            .every((i) => i.productName == 'Nama pertama'),
        isTrue);
    final unpaid = (await repo.getOrderById(target.id))!;
    await repo.processPayment(
        orderId: target.id,
        paymentMethod: 'cash',
        paidAmount: unpaid.remaining,
        createdBy: 'Kasir');
    final transaction = (await db
            .query('transactions', where: 'order_id=?', whereArgs: [target.id]))
        .single;
    for (final payload in [
      await queued('order', target.id),
      await queued('transaction', transaction['id'] as String)
    ]) {
      final snapshot = (payload['items'] as List).cast<Map>();
      expect(
          snapshot.every((i) => ['food', 'beverage'].contains(i['menu_kind'])),
          isTrue);
      expect(snapshot.where((i) => i['menu_kind'] == 'food'), hasLength(2));
    }
    await cashier.closeShift(shiftId: opened.id, closedBy: 'Kasir');
    final report = (await queued('cashier_shift', opened.id))['report']
        as Map<String, dynamic>;
    expect(report['menu_quantity'], 8);
    expect(group(report, 'food')['quantity'], 5);
    expect(group(report, 'beverage')['quantity'], 3);
    expect((group(report, 'food')['items'] as List).single['product_name'],
        'Nama pertama');
  });

  test(
      'legacy kinds freeze atomically at close and catalog edits cannot change reprints',
      () async {
    final now = DateTime(2026, 10, 31, 18);
    final cashier = CashierRepository(now: () => now);
    final id = await shift(DateTime(2026, 10, 31, 8));
    final pid = await product('Nama sekarang', 'food');
    final orderId = await sold(DateTime(2026, 10, 31, 12),
        [item(pid, 'Nama saat transaksi', 2, null)]);
    expect(group(await cashier.getShiftReport(id), 'food')['quantity'], 2);
    await db
        .execute('''CREATE TRIGGER reject_menu_close BEFORE INSERT ON sync_queue
      WHEN NEW.entity_type='cashier_shift'
      BEGIN SELECT RAISE(ABORT,'test outbox failure'); END''');
    await expectLater(cashier.closeShift(shiftId: id, closedBy: 'Kasir'),
        throwsA(isA<DatabaseException>()));
    expect(
        (await db.query('order_items',
                where: 'order_id=?', whereArgs: [orderId]))
            .single['menu_kind'],
        isNull);
    expect((await cashier.getActiveShift())?.id, id);
    await db.execute('DROP TRIGGER reject_menu_close');
    await cashier.closeShift(shiftId: id, closedBy: 'Kasir');
    expect(
        (await db.query('order_items',
                where: 'order_id=?', whereArgs: [orderId]))
            .single['menu_kind'],
        'food');
    final saved =
        (await queued('cashier_shift', id))['report'] as Map<String, dynamic>;
    await db.update(
        'products', {'menu_kind': 'beverage', 'name': 'Diubah lagi'},
        where: 'id=?', whereArgs: [pid]);
    expect((await cashier.getShiftReport(id))['menu_items_by_kind'],
        saved['menu_items_by_kind']);
    await db.delete('products', where: 'id=?', whereArgs: [pid]);
    final reprint = await cashier.getShiftReport(id);
    expect(reprint['menu_items_by_kind'], saved['menu_items_by_kind']);
    expect((group(reprint, 'food')['items'] as List).single['product_name'],
        'Nama saat transaksi');
  });

  test('handover freezes only finalized items inside its exclusive boundary',
      () async {
    var now = DateTime(2026, 10, 31, 18);
    final cashier = CashierRepository(now: () => now);
    final id = await shift(DateTime(2026, 10, 31, 8));
    final pid = await product('Menu', 'food');
    final earlier = await sold(
        DateTime(2026, 10, 31, 12), [item(pid, 'Menu lama', 2, null)]);
    final boundary = await sold(now, [item(pid, 'Menu berikutnya', 3, null)]);
    final next = await cashier.handoverShift(
        currentShiftId: id, handoverToUserId: 'Kasir berikutnya');
    expect(
        (await db.query('order_items',
                where: 'order_id=?', whereArgs: [earlier]))
            .single['menu_kind'],
        'food');
    expect(
        (await db.query('order_items',
                where: 'order_id=?', whereArgs: [boundary]))
            .single['menu_kind'],
        isNull);
    await db.update('products', {'menu_kind': 'beverage'},
        where: 'id=?', whereArgs: [pid]);
    now = DateTime(2026, 10, 31, 20);
    expect(group(await cashier.getShiftReport(id), 'food')['quantity'], 2);
    expect(group(await cashier.getShiftReport(next.id), 'beverage')['quantity'],
        3);
    await cashier.closeShift(shiftId: next.id, closedBy: 'Kasir berikutnya');
    await db.update('products', {'menu_kind': 'activity'},
        where: 'id=?', whereArgs: [pid]);
    expect(group(await cashier.getShiftReport(next.id), 'beverage')['quantity'],
        3);
    expect(group(await cashier.getShiftReport(id), 'food')['quantity'], 2);
  });

  test(
      'closed legacy unknown and deleted products retain names without inventing past types',
      () async {
    final id =
        await shift(DateTime(2026, 10, 31, 8), end: DateTime(2026, 10, 31, 18));
    final beverage = await product('Jenis sekarang minuman', 'beverage');
    final deleted = await product('Produk terhapus', 'food', deleted: true);
    await sold(DateTime(2026, 10, 31, 12), [
      item('missing-product', 'Aktivitas tersimpan', 3, 'activity'),
      item(null, 'Tanpa produk', 4, null),
      item(deleted, 'Nama historis', 2, 'food'),
      item(beverage, 'Jenis lama tidak diketahui', 5, null),
      item(beverage, 'Jenis tidak valid', 1, 'invalid'),
    ]);
    final report = await CashierRepository().getShiftReport(id);
    expect(report['menu_quantity'], 15);
    expect(group(report, 'food')['quantity'], 2);
    expect(group(report, 'activity')['quantity'], 3);
    expect(group(report, 'beverage')['quantity'], 0);
    expect(group(report, 'other')['quantity'], 10);
    final unknown = (group(report, 'other')['items'] as List).cast<Map>();
    expect(
        unknown.singleWhere(
            (r) => r['product_name'] == 'Tanpa produk')['product_id'],
        isNull);
    expect((group(report, 'activity')['items'] as List).single['product_id'],
        'missing-product');
  });
}
