// End-to-end reservasi: POS Flutter melawan server cloud SUNGGUHAN.
//
//   pelanggan membuat reservasi (endpoint publik, tanpa DP tervalidasi)
//     → POS menarik daftar reservasi hari ini
//     → kasir membukanya ke meja, tamu bayar tunai
//     → transaksi tersinkron dengan reservation_id
//     → cloud menutup reservasi (status 'done').
//
// Butuh env: E2E_CLOUD_URL, E2E_SLUG, E2E_OUTLET_ID, E2E_API_KEY,
// E2E_PRODUCT_ID (id produk cloud = id produk lokal). Tanpa itu di-skip.
// Skenario DP tervalidasi butuh login admin di cloud, jadi diuji lokal di
// test/reservation_open_test.dart, bukan di sini.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/services/reservation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _env = Platform.environment;
final _cloudUrl = _env['E2E_CLOUD_URL'] ?? '';
final _slug = _env['E2E_SLUG'] ?? '';
final _outletId = _env['E2E_OUTLET_ID'] ?? '';
final _apiKey = _env['E2E_API_KEY'] ?? '';
final _productId = _env['E2E_PRODUCT_ID'] ?? '';

final _dio = Dio();
final _orderRepo = OrderRepository();
final _cashierRepo = CashierRepository();

late Database db;
late File dbFile;

void main() {
  if (_cloudUrl.isEmpty || _slug.isEmpty || _outletId.isEmpty || _apiKey.isEmpty || _productId.isEmpty) {
    test('e2e reservasi', () {}, skip: 'setel E2E_CLOUD_URL, E2E_SLUG, E2E_OUTLET_ID, E2E_API_KEY, E2E_PRODUCT_ID');
    return;
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_api_url': _cloudUrl,
      'outlet_cloud_api_key': _apiKey,
      'outlet_cloud_outlet_id': _outletId,
      'outlet_code': 'UJI',
      'outlet_name': 'Outlet Uji',
      'saved_printers': <String>[],
    });
    dbFile = File(p.join(await getDatabasesPath(), 'pos_resto.db'));
    if (await dbFile.exists()) await dbFile.delete();
    db = await AppDatabase.instance.database;

    final now = DateTime.now().toIso8601String();
    await db.insert('products', {
      'id': _productId,
      'name': 'Nasi Goreng',
      'price': 25000.0,
      'stock': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
    });
  });

  tearDownAll(() async {
    await db.close();
    if (await dbFile.exists()) await dbFile.delete();
  });

  test('reservasi publik → dibuka di POS → lunas → ditutup cloud', () async {
    // Pelanggan memesan untuk HARI INI supaya masuk daftar POS.
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final buat = await _dio.post('$_cloudUrl/api/v1/public/outlets/$_slug/reservations', data: {
      'customer_name': 'Tamu E2E',
      'customer_phone': '0812e2e',
      'pax': 2,
      'reservation_date': today,
      'reservation_time': '19:00',
      'items': [
        {'product_id': _productId, 'qty': 2}
      ],
    });
    final resvId = (buat.data['data'] as Map)['id'] as String;

    await _cashierRepo.openShift(openedBy: 'Kasir E2E', openingCash: 0);

    final list = await ReservationService.instance.fetchToday(date: today);
    final mine = list.where((r) => r.id == resvId).toList();
    expect(mine, hasLength(1), reason: 'reservasi hari ini harus tampil di POS');
    expect(mine.single.items.single.productLocalId, _productId,
        reason: 'cloud harus mengirim product_local_id');

    final opened = await ReservationService.instance.openAsOrder(
        reservation: mine.single, tableNumber: 'E2E-1', cashierName: 'Kasir E2E');
    expect(opened.skipped, isEmpty);
    expect(opened.order.reservationId, resvId);

    await _orderRepo.processPayment(
        orderId: opened.order.id,
        paymentMethod: 'cash',
        paidAmount: opened.order.remaining,
        createdBy: 'Kasir E2E');

    final pushed = await CloudSyncService.instance.pushNow();
    expect(pushed['failed'], 0, reason: 'sync transaksi: $pushed');

    final status = await _dio.get('$_cloudUrl/api/v1/public/outlets/$_slug/reservations/$resvId');
    expect((status.data['data'] as Map)['status'], 'done',
        reason: 'transaksi ber-reservation_id harus menutup reservasi di cloud');
  });
}
