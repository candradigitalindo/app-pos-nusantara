// Simulasi beban: membuktikan ketahanan jalur pembayaran saat transaksi padat.
//
// Menguji 3 hal terhadap SQLite ASLI (sqflite ffi):
//   1. ULID — tidak bentrok walau ratusan ribu ID dibuat secepat mungkin.
//   2. Race pembayaran ganda — cara LAMA (cek lalu tulis di luar txn) dobel,
//      cara BARU (klaim atomik di dalam txn, seperti di processPayment) tidak.
//   3. Beban padat — N order, tiap order dibayar 2x bersamaan → tepat N transaksi.
//
// Jalankan: dart run tool/payment_stress_sim.dart
import 'dart:io';

import 'package:pos_resto/utils/ulid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late Database db;

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('pos_sim');
  db = await databaseFactory.openDatabase('${dir.path}/sim.db');
  await _schema();

  print('=== SIMULASI BEBAN TRANSAKSI PADAT ===\n');
  await _ulidTest();
  await _racePaymentTest();
  await _loadTest(orders: 300, concurrentPaysEach: 3);

  await db.close();
  await dir.delete(recursive: true);
}

Future<void> _schema() async {
  await db.execute('''
    CREATE TABLE orders(
      id TEXT PRIMARY KEY, total_amount REAL, paid_amount REAL DEFAULT 0,
      payment_status TEXT DEFAULT 'unpaid')''');
  await db.execute('''
    CREATE TABLE payments(id TEXT PRIMARY KEY, order_id TEXT, amount REAL)''');
  await db.execute('''
    CREATE TABLE transactions(id TEXT PRIMARY KEY, order_id TEXT, total REAL)''');
}

// ── 1. ULID anti-bentrok ─────────────────────────────────────────────────────
Future<void> _ulidTest() async {
  const n = 200000;
  final set = <String>{};
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    set.add(Ulid.generate());
  }
  sw.stop();
  final dup = n - set.length;
  print('[1] ULID: $n dibuat dalam ${sw.elapsedMilliseconds}ms — '
      'bentrok: $dup  => ${dup == 0 ? "LULUS ✅" : "GAGAL ❌"}\n');
}

// ── 2. Race pembayaran ganda ─────────────────────────────────────────────────

/// Cara LAMA: cek isPaid di luar txn, lalu tulis. Rawan dobel.
Future<bool> payOld(String orderId) async {
  final rows = await db.query('orders',
      columns: ['payment_status', 'total_amount'],
      where: 'id=?', whereArgs: [orderId], limit: 1);
  if (rows.first['payment_status'] == 'paid') return false; // cek di luar txn
  await db.transaction((txn) async {
    await txn.insert('payments',
        {'id': Ulid.generate(), 'order_id': orderId, 'amount': rows.first['total_amount']});
    await txn.insert('transactions',
        {'id': Ulid.generate(), 'order_id': orderId, 'total': rows.first['total_amount']});
    await txn.update('orders', {'payment_status': 'paid'}, where: 'id=?', whereArgs: [orderId]);
  });
  return true;
}

/// Cara BARU: klaim atomik DI DALAM txn (sama seperti processPayment terbaru).
Future<bool> payNew(String orderId) async {
  var ok = false;
  await db.transaction((txn) async {
    final claimed = await txn.rawUpdate(
      "UPDATE orders SET payment_status='paid' WHERE id=? AND payment_status!='paid'",
      [orderId]);
    if (claimed == 0) return; // sudah dibayar proses lain → batalkan
    final r = await txn.query('orders', columns: ['total_amount'],
        where: 'id=?', whereArgs: [orderId], limit: 1);
    final total = r.first['total_amount'];
    await txn.insert('payments',
        {'id': Ulid.generate(), 'order_id': orderId, 'amount': total});
    await txn.insert('transactions',
        {'id': Ulid.generate(), 'order_id': orderId, 'total': total});
    ok = true;
  });
  return ok;
}

Future<int> _txCount(String orderId) async {
  final r = await db.rawQuery(
      'SELECT COUNT(*) c FROM transactions WHERE order_id=?', [orderId]);
  return r.first['c'] as int;
}

Future<void> _racePaymentTest() async {
  // LAMA — 2 pembayaran bersamaan pada order yang sama
  final oldId = Ulid.generate();
  await db.insert('orders', {'id': oldId, 'total_amount': 50000});
  await Future.wait([payOld(oldId), payOld(oldId)]); // race
  final oldTx = await _txCount(oldId);

  // BARU — skenario sama
  final newId = Ulid.generate();
  await db.insert('orders', {'id': newId, 'total_amount': 50000});
  await Future.wait([payNew(newId), payNew(newId)]); // race
  final newTx = await _txCount(newId);

  print('[2] Race bayar ganda (2 bersamaan, 1 order):');
  print('    Cara LAMA  -> transaksi tercatat: $oldTx '
      '${oldTx > 1 ? "(DOBEL, ini bug-nya) ⚠️" : ""}');
  print('    Cara BARU  -> transaksi tercatat: $newTx '
      '=> ${newTx == 1 ? "LULUS ✅ (tidak dobel)" : "GAGAL ❌"}\n');
}

// ── 3. Beban padat ───────────────────────────────────────────────────────────
Future<void> _loadTest({required int orders, required int concurrentPaysEach}) async {
  // Baseline sebelum beban (mengabaikan transaksi dari test sebelumnya).
  final baseTx = (await db.rawQuery('SELECT COUNT(*) c FROM transactions'))
      .first['c'] as int;
  final basePaid = (await db.rawQuery(
          "SELECT COUNT(*) c FROM orders WHERE payment_status='paid'"))
      .first['c'] as int;

  final ids = <String>[];
  for (var i = 0; i < orders; i++) {
    final id = Ulid.generate();
    ids.add(id);
    await db.insert('orders', {'id': id, 'total_amount': 25000});
  }

  final sw = Stopwatch()..start();
  // Setiap order ditembak beberapa pembayaran SEKALIGUS (simulasi padat + double-tap)
  final futures = <Future>[];
  for (final id in ids) {
    for (var k = 0; k < concurrentPaysEach; k++) {
      futures.add(payNew(id));
    }
  }
  await Future.wait(futures);
  sw.stop();

  final loadTx = ((await db.rawQuery('SELECT COUNT(*) c FROM transactions'))
          .first['c'] as int) -
      baseTx;
  final loadPaid = ((await db.rawQuery(
              "SELECT COUNT(*) c FROM orders WHERE payment_status='paid'"))
          .first['c'] as int) -
      basePaid;

  final ok = loadTx == orders && loadPaid == orders;
  print('[3] Beban padat: $orders order, masing-masing '
      '$concurrentPaysEach pembayaran bersamaan '
      '(${orders * concurrentPaysEach} request) dalam ${sw.elapsedMilliseconds}ms');
  print('    Order lunas      : $loadPaid / $orders');
  print('    Transaksi tercatat: $loadTx (harusnya $orders)');
  print('    => ${ok ? "LULUS ✅ (tidak ada dobel/hilang)" : "GAGAL ❌"}');
}
