// Real Go API contract on a dedicated disposable outlet:
// POS outbox -> JSONB -> /restore -> CloudSyncService -> SQLite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final env = Platform.environment;
  final url = env['E2E_CLOUD_URL'] ?? '';
  final outlet = env['E2E_RESTORE_OUTLET_ID'] ?? '';
  final key = env['E2E_RESTORE_API_KEY'] ?? '';
  if ([url, outlet, key].any((value) => value.isEmpty)) {
    test('e2e restore snapshot', () {},
        skip:
            'setel E2E_CLOUD_URL, E2E_RESTORE_OUTLET_ID, E2E_RESTORE_API_KEY');
    return;
  }
  late Directory directory;
  late Database db;
  final repo = OrderRepository();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-restore-real-api-');
    await databaseFactory.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_env': 'development',
      'outlet_cloud_api_url': url,
      'outlet_cloud_api_key': key,
      'outlet_cloud_outlet_id': outlet,
      'outlet_code': 'E2ERESTORE',
      'saved_printers': <String>[],
    });
    db = await AppDatabase.instance.database;
  });
  tearDownAll(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test(
      'POS partial snapshot round-trips real API with identities, money and times',
      () async {
    final product = await ProductRepository()
        .createProduct(name: 'Restore E2E', price: 100000);
    await db.update('products', {'menu_kind': 'food'},
        where: 'id = ?', whereArgs: [product.id]);
    final reserved = 'restore-${Ulid.generate()}';
    await repo.createAdditionalCharge(
        name: 'PB1 restore E2E',
        chargeType: 'percentage',
        value: 10,
        isActive: true);
    final master = (await db.query('additional_charges')).single;
    final shift = await CashierRepository()
        .openShift(openedBy: 'Restore E2E', openingCash: 0);
    final order = await repo.createOrder(
        tableNumber: 'RESTORE-E2E',
        reservationId: reserved,
        createdBy: 'Restore E2E',
        items: [
          OrderItemInput(
              productId: product.id, qty: 1, notes: 'Catatan dari POS')
        ]);
    await repo.splitBillPayment(
        orderId: order.id,
        amount: 25000,
        paymentMethod: 'reservasi_dp',
        note: 'DP asli E2E',
        createdBy: 'Admin E2E');
    final original = DateTime.now().toUtc().subtract(const Duration(days: 1));
    await db.update(
        'payments', {'created_at': original.toLocal().toIso8601String()},
        where: 'order_id = ?', whereArgs: [order.id]);
    await db.delete('sync_queue', where: "entity_type = 'order'");
    await repo.enqueueUnsyncedActiveOrders();
    final originalItem = (await repo.getOrderItems(order.id)).single;
    expect(originalItem.menuKind, 'food');
    final originalPayment = (await db.query('payments')).single;
    final pushed = await CloudSyncService.instance.pushNow();
    expect(pushed['failed'], 0, reason: '$pushed');

    // Only this disposable local fixture is cleared. The real API supplies
    // the unmodified JSON-string payment_info and authoritative charge list.
    await db.transaction((txn) async {
      for (final table in [
        'sync_queue',
        'payments',
        'order_items',
        'order_additional_charges',
        'orders',
        'cashier_shifts',
        'additional_charges'
      ]) {
        await txn.delete(table);
      }
    });
    final recovered = await CloudSyncService.instance.restoreFromCloud();
    expect(recovered['error'], isNull, reason: '$recovered');
    expect(recovered['orders'], 1);
    expect(recovered['shifts'], 1);
    expect((await db.query('cashier_shifts')).single['id'], shift.id);
    final restored = (await repo.getOrderById(order.id))!;
    expect(restored.paidAmount, 25000);
    expect(restored.totalAmount, 110000);
    expect(restored.reservationId, reserved);
    final item = (await repo.getOrderItems(order.id)).single;
    expect(item.id, originalItem.id);
    expect(item.productId, product.id);
    expect(item.menuKind, 'food');
    expect(item.notes, 'Catatan dari POS');
    expect(item.createdAt.toUtc(), originalItem.createdAt.toUtc());
    final payment = (await db.query('payments')).single;
    expect(payment['id'], originalPayment['id']);
    expect(payment['payment_method'], 'reservasi_dp');
    expect(DateTime.parse(payment['created_at'] as String).toUtc(), original);
    final charge = (await repo.getOrderCharges(order.id)).single;
    final restoredMaster = (await db.query('additional_charges')).single;
    expect(restoredMaster['sync_id'], master['sync_id']);
    expect(charge.chargeId, restoredMaster['id']);
    expect(charge.appliedAmount, 10000);
    final again = await CloudSyncService.instance.restoreFromCloud();
    expect(again['error'], isNull);
    expect(again['orders'], 0);
    expect(again['skipped_existing'], 2);
    expect((await db.query('payments')).length, 1);
    expect((await repo.getOrderItems(order.id)).single.id, originalItem.id);
  });
}
