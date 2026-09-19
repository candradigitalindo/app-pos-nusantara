// Alur lokal membuka reservasi cloud menjadi order meja, tanpa jaringan:
//
//   - DP tervalidasi tercatat sebagai pembayaran 'reservasi_dp' dan langsung
//     mengurangi sisa tagihan;
//   - membuka reservasi yang sama dua kali TIDAK membuat order/DP ganda;
//   - pelunasan menghasilkan payload transaksi ber-reservation_id dengan baris
//     payments[] 'reservasi_dp' — itulah yang membuat cloud menutup reservasi;
//   - tanpa shift terbuka, reservasi ber-DP ditolak (DP dicatat ke shift).
//
// Memakai AppDatabase & repository yang sebenarnya di atas SQLite ffi.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/services/reservation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late Database db;
late File dbFile;
final _orderRepo = OrderRepository();
final _cashierRepo = CashierRepository();

const _productId = '01JRESVTESTPRODUK000000001';

CloudReservation _reservasi({double paid = 100000, String id = '01JRESVTEST000000000000001'}) =>
    CloudReservation(
      id: id,
      customerName: 'Bu Sari',
      customerPhone: '0812000',
      pax: 4,
      date: '2026-09-19',
      time: '19:00',
      items: const [
        CloudReservationItem(
            productLocalId: _productId, productName: 'Paket Keluarga', qty: 2, price: 100000),
        // Menu yang tidak ada di POS: harus dilewati, bukan menggagalkan.
        CloudReservationItem(
            productLocalId: '01JRESVTESTHILANG0000000001', productName: 'Menu Hilang', qty: 1, price: 5000),
      ],
      total: 205000,
      paidAmount: paid,
      remaining: 205000 - paid,
      status: paid > 0 ? 'confirmed' : 'pending',
      notes: '',
    );

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({'saved_printers': <String>[]});

    dbFile = File(p.join(await getDatabasesPath(), 'pos_resto.db'));
    if (await dbFile.exists()) await dbFile.delete();
    db = await AppDatabase.instance.database;

    final now = DateTime.now().toIso8601String();
    await db.insert('products', {
      'id': _productId,
      'name': 'Paket Keluarga',
      'price': 100000.0,
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

  test('tanpa shift terbuka, reservasi ber-DP ditolak', () async {
    expect(await _cashierRepo.getActiveShift(), isNull);
    await expectLater(
      ReservationService.instance.openAsOrder(
          reservation: _reservasi(), tableNumber: 'R1', cashierName: 'Kasir'),
      throwsA(predicate((e) => e.toString().contains('shift'))),
    );
    expect(await _orderRepo.getOrderByTable('R1'), isNull);
  });

  test('dibuka: order terbentuk, DP tercatat, menu asing dilewati', () async {
    await _cashierRepo.openShift(openedBy: 'Kasir Uji', openingCash: 0);

    final opened = await ReservationService.instance.openAsOrder(
        reservation: _reservasi(), tableNumber: 'R1', cashierName: 'Kasir Uji');
    final order = opened.order;

    expect(order.reservationId, '01JRESVTEST000000000000001');
    expect(order.customerName, 'Bu Sari');
    expect(order.pax, 4);
    expect(order.totalAmount, 200000); // 2 × 100.000; menu hilang dilewati
    expect(order.paidAmount, 100000);
    expect(order.paymentStatus, 'partial');
    expect(opened.skipped, ['1× Menu Hilang']);

    final pays = await db.query('payments', where: 'order_id = ?', whereArgs: [order.id]);
    expect(pays.length, 1);
    expect(pays.single['payment_method'], ReservationService.dpMethod);
    expect(pays.single['amount'], 100000.0);
  });

  test('dibuka lagi: order & DP yang sama, bukan duplikat', () async {
    final again = await ReservationService.instance.openAsOrder(
        reservation: _reservasi(), tableNumber: 'R9', cashierName: 'Kasir Uji');
    final first = await _orderRepo.getOrderByTable('R1');
    expect(again.order.id, first!.id);
    expect(again.order.tableNumber, 'R1', reason: 'meja pilihan kedua diabaikan');
    final pays = await db.query('payments', where: 'order_id = ?', whereArgs: [first.id]);
    expect(pays.length, 1, reason: 'DP tidak boleh dicatat dua kali');
    expect(await _orderRepo.getOrderByTable('R9'), isNull);
  });

  test('pelunasan: payload transaksi membawa reservation_id + baris reservasi_dp', () async {
    final order = (await _orderRepo.getOrderByTable('R1'))!;
    expect(order.remaining, 100000);

    await _orderRepo.processPayment(
        orderId: order.id, paymentMethod: 'cash', paidAmount: 100000, createdBy: 'Kasir Uji');

    final rows = await db.query('sync_queue',
        where: "entity_type = 'transaction'", orderBy: 'id DESC', limit: 1);
    expect(rows, isNotEmpty);
    final payload = jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>;
    expect(payload['order_id'], order.id);
    expect(payload['reservation_id'], '01JRESVTEST000000000000001');
    expect(payload['total_amount'], 200000);

    final payments = (payload['payments'] as List).cast<Map>();
    final byMethod = {for (final p in payments) p['payment_method']: (p['amount'] as num).toDouble()};
    expect(byMethod[ReservationService.dpMethod], 100000,
        reason: 'uang muka harus terlihat cloud sebagai reservasi_dp, bukan tunai');
    expect(byMethod['cash'], 100000);
    expect(payload['payment_method'], 'mixed');

    final paid = await _orderRepo.getOrderById(order.id);
    expect(paid!.isPaid, isTrue);
  });

  test('reservasi tanpa DP: order biasa, tidak ada baris pembayaran', () async {
    final opened = await ReservationService.instance.openAsOrder(
        reservation: _reservasi(paid: 0, id: '01JRESVTEST000000000000002'),
        tableNumber: 'R2',
        cashierName: 'Kasir Uji');
    expect(opened.order.paidAmount, 0);
    expect(opened.order.paymentStatus, 'unpaid');
    expect(await db.query('payments', where: 'order_id = ?', whereArgs: [opened.order.id]), isEmpty);
  });
}
