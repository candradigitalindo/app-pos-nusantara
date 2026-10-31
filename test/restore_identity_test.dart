import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late Database db;
  final shiftId = Ulid.generate();
  final orderId = Ulid.generate();
  final movementId = Ulid.generate();
  final productId = Ulid.generate();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-restore-identity-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await AppDatabase.instance.database;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_env': 'development',
      'outlet_cloud_api_url': 'http://127.0.0.1:${server.port}',
      'outlet_cloud_api_key': 'isolated-test-key',
      'outlet_cloud_outlet_id': 'isolated-test-outlet',
    });
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'data': {
          'open_shifts': [
            {'id': 'cloud-shift-id', 'local_id': shiftId, 'opened_by': 'Kasir',
              'opened_at': '2026-09-19T03:00:00Z', 'opening_cash': 50000},
          ],
          'unpaid_orders': [
            {'id': 'cloud-order-id', 'local_id': orderId, 'table_number': 'A1',
              'total_amount': 10000, 'status': 'cooking',
              'created_at': '2026-09-19T04:00:00Z',
              'payment_info': {'paid_amount': 0, 'payment_status': 'unpaid'},
              'items': [{'product_id': productId, 'product_name': 'Menu',
                'qty': 1, 'price': 10000, 'destination': 'kitchen'}]},
          ],
          'cash_movements': [
            {'id': 'cloud-movement-id', 'local_id': movementId, 'shift_id': shiftId,
              'movement_type': 'in', 'amount': 1000, 'counterpart_name': 'Uji',
              'created_at': '2026-09-19T04:00:00Z'},
          ],
        },
      }));
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('restore keeps local IDs when cloud canonical IDs differ', () async {
    final result = await CloudSyncService.instance.restoreFromCloud();
    expect(result, {'shifts': 1, 'orders': 1, 'movements': 1});
    expect((await db.query('cashier_shifts')).single['id'], shiftId);
    expect((await db.query('orders')).single['id'], orderId);
    final movement = (await db.query('cashier_cash_movements')).single;
    expect(movement['id'], movementId);
    expect(movement['shift_id'], shiftId);
    final item = (await db.query('order_items')).single;
    expect(item['order_id'], orderId);
    expect(item['product_id'], productId);
  });
}
