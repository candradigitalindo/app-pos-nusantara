// Simulasi verifikasi laporan shift PASCA-perbaikan getShiftReport.
//
// Membuktikan dengan SQLite ASLI (sqflite ffi) bahwa query laporan shift yang
// BARU (sales_count dari tabel transactions, diskon berbasis transactions,
// kompliment exclude voided) menghasilkan angka benar, dan bahwa angka
// sales_count SAMA dengan "sudut pandang cloud" (jumlah baris transactions
// non-cancelled dalam jendela shift) — jaminan rekonsiliasi baru.
//
// Semua SQL laporan disalin VERBATIM dari
// lib/repositories/cashier_repository.dart (getShiftReport, pasca-perbaikan).
// Skema tabel disalin VERBATIM dari lib/database/database.dart.
//
// Jalankan: dart run tool/shift_report_verify_sim.dart
import 'dart:io';

import 'package:pos_resto/utils/ulid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late Database db;

int _failures = 0;

void check(String label, Object? actual, Object? expected) {
  final ok = actual == expected;
  if (!ok) _failures++;
  print('  ${ok ? "LULUS ✅" : "GAGAL ❌"}  $label — '
      'aktual: $actual, ekspektasi: $expected');
}

void observe(String label, Object? value) {
  print('  PENGAMATAN 👁  $label — $value');
}

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('pos_shift_report_sim');
  db = await databaseFactory.openDatabase('${dir.path}/sim.db');
  await _schema();
  await _seed();

  print('=== SIMULASI VERIFIKASI LAPORAN SHIFT (getShiftReport BARU) ===\n');
  await _verifyS2();
  await _verifyS3();
  await _observeS1();

  await db.close();
  await dir.delete(recursive: true);

  if (_failures > 0) {
    print('\nTOTAL: $_failures assert GAGAL ❌');
    exit(1);
  }
  print('\nTOTAL: semua assert LULUS ✅');
}

// ── Skema — salinan VERBATIM dari lib/database/database.dart ────────────────
Future<void> _schema() async {
  // SUMBER: lib/database/database.dart baris 274-299 (orders, verbatim)
  await db.execute('''
      CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY,
        table_number TEXT NOT NULL,
        customer_name TEXT,
        customer_phone TEXT,
        customer_id TEXT,
        pax INTEGER NOT NULL DEFAULT 1 CHECK (pax > 0),
        basket_size INTEGER NOT NULL DEFAULT 0 CHECK (basket_size >= 0),
        total_amount REAL NOT NULL,
        paid_amount REAL NOT NULL DEFAULT 0,
        order_status TEXT NOT NULL DEFAULT 'cooking' CHECK (order_status IN ('cooking', 'ready', 'served')),
        created_by TEXT,
        payment_status TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
        merged_from TEXT,
        is_merged INTEGER NOT NULL DEFAULT 0,
        is_holding INTEGER NOT NULL DEFAULT 0,
        voided_at DATETIME,
        voided_by TEXT,
        void_reason TEXT,
        compliment_by TEXT,
        compliment_reason TEXT,
        complimented_at DATETIME,
        discount_note TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

  // SUMBER: lib/database/database.dart baris 313-330 (order_items, verbatim)
  await db.execute('''
      CREATE TABLE IF NOT EXISTS order_items (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        order_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        category_id TEXT,
        qty INTEGER NOT NULL CHECK (qty > 0),
        price REAL NOT NULL CHECK (price >= 0),
        destination TEXT NOT NULL CHECK (destination IN ('kitchen', 'bar')),
        item_status TEXT NOT NULL DEFAULT 'pending' CHECK (item_status IN ('pending', 'cooking', 'ready', 'served')),
        notes TEXT NOT NULL DEFAULT '',
        addons TEXT NOT NULL DEFAULT '',
        waiter_name TEXT NOT NULL DEFAULT '',
        is_additional INTEGER NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
      )
    ''');

  // SUMBER: lib/database/database.dart baris 354-365 (order_additional_charges)
  await db.execute('''
      CREATE TABLE IF NOT EXISTS order_additional_charges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id TEXT NOT NULL,
        charge_id INTEGER,
        name TEXT NOT NULL,
        charge_type TEXT NOT NULL,
        value REAL NOT NULL,
        applied_amount REAL NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

  // SUMBER: lib/database/database.dart baris 369-383 (transactions, verbatim)
  await db.execute('''
      CREATE TABLE IF NOT EXISTS transactions (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        order_id TEXT NOT NULL DEFAULT '',
        total_amount REAL NOT NULL,
        payment_method TEXT NOT NULL,
        status TEXT NOT NULL,
        transaction_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_by TEXT,
        cancelled_at DATETIME,
        cancelled_by TEXT,
        cancel_reason TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

  // SUMBER: lib/database/database.dart baris 402-412 (payments, verbatim —
  // CHECK amount > 0 dan payment_method DIPERTAHANKAN: inilah alasan order
  // diskon 100%/kompliment tidak pernah punya baris payments)
  await db.execute('''
      CREATE TABLE IF NOT EXISTS payments (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        order_id TEXT NOT NULL,
        amount REAL NOT NULL CHECK (amount > 0),
        payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'card', 'qris', 'transfer')),
        payment_note TEXT,
        created_by TEXT NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
      )
    ''');

  // SUMBER: lib/database/database.dart baris 435-454 (cashier_shifts, verbatim)
  await db.execute('''
      CREATE TABLE IF NOT EXISTS cashier_shifts (
        id TEXT PRIMARY KEY,
        opened_by TEXT NOT NULL,
        opened_at DATETIME NOT NULL,
        opening_cash REAL NOT NULL DEFAULT 0,
        closed_at DATETIME,
        closed_by TEXT,
        closing_cash REAL,
        closing_card REAL,
        closing_qris REAL,
        closing_transfer REAL,
        carry_over_cash REAL,
        previous_shift_id TEXT,
        handover_to TEXT,
        status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
        notes TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

  // SUMBER: lib/database/database.dart baris 458-467 (cashier_cash_movements)
  await db.execute('''
      CREATE TABLE IF NOT EXISTS cashier_cash_movements (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        movement_type TEXT NOT NULL CHECK (movement_type IN ('in', 'out')),
        amount REAL NOT NULL,
        counterpart_name TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
}

// ── Data skenario ───────────────────────────────────────────────────────────
// Semua tanggal 2026-07-25 waktu LOKAL (format sama seperti yang ditulis app:
// DateTime lokal .toIso8601String(), tanpa 'Z').
String ts(int h, [int m = 0]) =>
    '2026-07-25T${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:00.000';

const kasir = 'Kasir A';

Future<String> _order({
  required String table,
  required double total,
  double paid = 0,
  String payStatus = 'paid',
  String? voidedAt,
  String? complimentedAt,
  required String createdAt,
}) async {
  final id = Ulid.generate();
  await db.insert('orders', {
    'id': id,
    'table_number': table,
    'total_amount': total,
    'paid_amount': paid,
    'payment_status': payStatus,
    'voided_at': voidedAt,
    'complimented_at': complimentedAt,
    'created_at': createdAt,
    'updated_at': createdAt,
  });
  return id;
}

Future<void> _payment(String orderId, double amount, String method, String at) =>
    db.insert('payments', {
      'id': Ulid.generate(),
      'order_id': orderId,
      'amount': amount,
      'payment_method': method,
      'created_by': kasir,
      'created_at': at,
    }).then((_) {});

Future<void> _transaction(String orderId, double total, String method,
        String at,
        {String status = 'completed', String? cancelledAt}) =>
    db.insert('transactions', {
      'id': Ulid.generate(),
      'order_id': orderId,
      'total_amount': total,
      'payment_method': method,
      'status': status,
      'transaction_date': at,
      'created_by': kasir,
      'cancelled_at': cancelledAt,
    }).then((_) {});

Future<void> _charge(String orderId, String name, double applied) =>
    db.insert('order_additional_charges', {
      'order_id': orderId,
      'charge_id': null, // diskon/kompliment manual: charge_id NULL
      'name': name,
      'charge_type': 'fixed',
      'value': applied,
      'applied_amount': applied,
    }).then((_) {});

Future<void> _seed() async {
  // Shift: S1 [00:00, 10:00) closed, S2 [10:00, 22:00) closed,
  // S3 [22:00, sekarang) masih open.
  await db.insert('cashier_shifts', {
    'id': 'S1',
    'opened_by': kasir,
    'opened_at': ts(0),
    'opening_cash': 200000.0,
    'closed_at': ts(10),
    'status': 'closed',
  });
  await db.insert('cashier_shifts', {
    'id': 'S2',
    'opened_by': kasir,
    'opened_at': ts(10),
    'opening_cash': 500000.0,
    'closed_at': ts(22),
    'status': 'closed',
  });
  await db.insert('cashier_shifts', {
    'id': 'S3',
    'opened_by': kasir,
    'opened_at': ts(22),
    'opening_cash': 0.0,
    'status': 'open',
  });

  // a. Order A: bayar penuh cash 100k jam 11:00 → 1 payment, 1 transaction.
  final a = await _order(table: 'A', total: 100000, paid: 100000, createdAt: ts(10, 30));
  await _payment(a, 100000, 'cash', ts(11));
  await _transaction(a, 100000, 'cash', ts(11));

  // b. Order B: split bill cash 60k + qris 40k jam 12:00 → 2 payments,
  //    1 transaction (total 100k).
  final b = await _order(table: 'B', total: 100000, paid: 100000, createdAt: ts(11, 30));
  await _payment(b, 60000, 'cash', ts(12));
  await _payment(b, 40000, 'qris', ts(12));
  await _transaction(b, 100000, 'split', ts(12));

  // c. Order C: diskon 100% (charge 'Diskon' -80k), total 0, dibayar 13:00
  //    → 0 payments (CHECK amount>0 melarang baris 0), 1 transaction total 0.
  final c = await _order(table: 'C', total: 0, paid: 0, createdAt: ts(12, 30));
  await _charge(c, 'Diskon', -80000);
  await _transaction(c, 0, 'cash', ts(13));

  // d. Order D: kompliment jam 14:00 → 0 payments, 1 transaction
  //    (payment_method 'compliment', total 0), charge 'Kompliment' -50k.
  final d = await _order(
      table: 'D', total: 0, paid: 0, complimentedAt: ts(14), createdAt: ts(13, 30));
  await _charge(d, 'Kompliment', -50000);
  await _transaction(d, 0, 'compliment', ts(14));

  // e. Order E: dibayar cash 70k jam 15:00 LALU di-void jam 16:00
  //    (voided_at 16:00, transaction status cancelled) → keluar dari sales &
  //    by_method, masuk void_count.
  final e = await _order(
      table: 'E', total: 70000, paid: 70000, voidedAt: ts(16), createdAt: ts(14, 30));
  await _payment(e, 70000, 'cash', ts(15));
  await _transaction(e, 70000, 'cash', ts(15),
      status: 'cancelled', cancelledAt: ts(16));

  // f. Order F: dibayar cash 90k jam 09:00 (shift S1), di-void jam 17:00
  //    (shift S2) + cash movement 'out' 90k di S2 (meniru perbaikan
  //    voidPaidOrder: refund tunai lintas shift → kas keluar di shift aktif).
  final f = await _order(
      table: 'F', total: 90000, paid: 90000, voidedAt: ts(17), createdAt: ts(8, 30));
  await _payment(f, 90000, 'cash', ts(9));
  await _transaction(f, 90000, 'cash', ts(9),
      status: 'cancelled', cancelledAt: ts(17));
  await db.insert('cashier_cash_movements', {
    'id': Ulid.generate(),
    'shift_id': 'S2',
    'movement_type': 'out',
    'amount': 90000.0,
    'counterpart_name': kasir,
    'note': 'Refund void order F (dibayar di shift sebelumnya)',
    'created_at': ts(17, 5),
  });

  // Kas masuk 10k di S2 (menguji cabang 'in' agregasi movement).
  await db.insert('cashier_cash_movements', {
    'id': Ulid.generate(),
    'shift_id': 'S2',
    'movement_type': 'in',
    'amount': 10000.0,
    'counterpart_name': kasir,
    'note': 'Setoran tambahan',
    'created_at': ts(18),
  });

  // g. Order G: partial cash 50k jam 21:00 di S2, dilunasi cash 30k jam 23:00
  //    SETELAH S2 closed (di S3) dengan diskon 20k → transaction tercatat
  //    23:00 (saat lunas). Diskon TIDAK boleh muncul di S2, muncul SEKALI di S3.
  final g = await _order(table: 'G', total: 80000, paid: 80000, createdAt: ts(20, 30));
  await _payment(g, 50000, 'cash', ts(21)); // partial di S2
  await _payment(g, 30000, 'cash', ts(23)); // pelunasan di S3
  await _charge(g, 'Diskon', -20000);
  await _transaction(g, 80000, 'cash', ts(23)); // TEPAT 1 baris, saat lunas
}

// ── Replika getShiftReport — SQL disalin VERBATIM dari
//    lib/repositories/cashier_repository.dart (pasca-perbaikan) ─────────────
Future<Map<String, dynamic>> shiftReport(String shiftId) async {
  final shiftRows =
      await db.query('cashier_shifts', where: 'id = ?', whereArgs: [shiftId]);
  final shift = shiftRows.first;

  // SUMBER: cashier_repository.dart baris 239-241 — jendela [opened_at,
  // closed_at), .toLocal() menormalkan, closed_at NULL → sekarang.
  final since =
      DateTime.parse(shift['opened_at'] as String).toLocal().toIso8601String();
  final until = (shift['closed_at'] != null
          ? DateTime.parse(shift['closed_at'] as String)
          : DateTime.now())
      .toLocal()
      .toIso8601String();

  // SUMBER: cashier_repository.dart baris 244-253 (by_method, verbatim)
  final payRows = await db.rawQuery(
    '''
      SELECT p.payment_method, COUNT(*) AS cnt, SUM(p.amount) AS total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE p.created_at >= ? AND p.created_at < ? AND o.voided_at IS NULL
      GROUP BY p.payment_method
    ''',
    [since, until],
  );
  final methods = <String, Map<String, num>>{
    'cash': {'count': 0, 'total': 0},
    'card': {'count': 0, 'total': 0},
    'qris': {'count': 0, 'total': 0},
    'transfer': {'count': 0, 'total': 0},
  };
  var salesTotal = 0.0;
  for (final r in payRows) {
    final m = r['payment_method'] as String;
    final cnt = (r['cnt'] as num).toInt();
    final total = (r['total'] as num).toDouble();
    methods[m] = {'count': cnt, 'total': total};
    salesTotal += total;
  }

  // SUMBER: cashier_repository.dart baris 276-285 (sales_count BARU dari
  // transactions, verbatim)
  final salesCountRows = await db.rawQuery(
    '''
      SELECT COUNT(*) AS cnt
      FROM transactions t
      JOIN orders o ON o.id = t.order_id
      WHERE t.transaction_date >= ? AND t.transaction_date < ? AND o.voided_at IS NULL
    ''',
    [since, until],
  );
  final salesCount = (salesCountRows.first['cnt'] as num?)?.toInt() ?? 0;

  // SUMBER: cashier_repository.dart baris 288-296 (kas masuk/keluar, verbatim)
  final moveRows = await db.rawQuery(
    '''
      SELECT movement_type, COUNT(*) AS cnt, SUM(amount) AS total
      FROM cashier_cash_movements
      WHERE shift_id = ?
      GROUP BY movement_type
    ''',
    [shiftId],
  );
  var cashInCount = 0, cashOutCount = 0;
  var cashInTotal = 0.0, cashOutTotal = 0.0;
  for (final r in moveRows) {
    final t = r['movement_type'] as String;
    final cnt = (r['cnt'] as num).toInt();
    final total = (r['total'] as num).toDouble();
    if (t == 'in') {
      cashInCount = cnt;
      cashInTotal = total;
    } else if (t == 'out') {
      cashOutCount = cnt;
      cashOutTotal = total;
    }
  }

  final cashSales = methods['cash']!['total']!.toDouble();
  // SUMBER: cashier_repository.dart baris 314-315 (rumus expected_cash,
  // verbatim): modal awal + penjualan tunai + kas masuk - kas keluar
  final expectedCash =
      (shift['opening_cash'] as num).toDouble() + cashSales + cashInTotal - cashOutTotal;

  // SUMBER: cashier_repository.dart baris 345-358 (diskon BARU berbasis
  // transactions, verbatim)
  final discRows = await db.rawQuery(
    '''
      SELECT COUNT(*) AS cnt, COALESCE(SUM(t.disc), 0) AS total FROM (
        SELECT c.order_id, SUM(-c.applied_amount) AS disc
        FROM order_additional_charges c
        WHERE c.name = 'Diskon'
          AND c.order_id IN (SELECT tr.order_id FROM transactions tr
                             WHERE tr.transaction_date >= ? AND tr.transaction_date < ?)
          AND c.order_id NOT IN (SELECT id FROM orders WHERE voided_at IS NOT NULL)
        GROUP BY c.order_id
      ) t
    ''',
    [since, until],
  );
  final discountCount = (discRows.first['cnt'] as num?)?.toInt() ?? 0;
  final discountTotal = (discRows.first['total'] as num?)?.toDouble() ?? 0;

  // SUMBER: cashier_repository.dart baris 363-373 (kompliment, verbatim)
  final compRows = await db.rawQuery(
    '''
      SELECT COUNT(*) AS cnt, COALESCE(SUM(-c.applied_amount), 0) AS total
      FROM order_additional_charges c
      JOIN orders o ON o.id = c.order_id
      WHERE c.name = 'Kompliment'
        AND o.complimented_at >= ? AND o.complimented_at < ?
        AND o.voided_at IS NULL
    ''',
    [since, until],
  );
  final complimentCount = (compRows.first['cnt'] as num?)?.toInt() ?? 0;
  final complimentTotal = (compRows.first['total'] as num?)?.toDouble() ?? 0;

  // SUMBER: cashier_repository.dart baris 378-385 (void, verbatim)
  final voidRows = await db.rawQuery(
    '''
      SELECT COUNT(*) AS cnt, COALESCE(SUM(total_amount), 0) AS total
      FROM orders
      WHERE voided_at >= ? AND voided_at < ?
    ''',
    [since, until],
  );
  final voidCount = (voidRows.first['cnt'] as num?)?.toInt() ?? 0;
  final voidTotal = (voidRows.first['total'] as num?)?.toDouble() ?? 0;

  return {
    'since': since,
    'until': until,
    'sales_count': salesCount,
    'sales_total': salesTotal,
    'by_method': methods,
    'cash_in_count': cashInCount,
    'cash_in_total': cashInTotal,
    'cash_out_count': cashOutCount,
    'cash_out_total': cashOutTotal,
    'expected_cash': expectedCash,
    'discount_count': discountCount,
    'discount_total': discountTotal,
    'compliment_count': complimentCount,
    'compliment_total': complimentTotal,
    'void_count': voidCount,
    'void_total': voidTotal,
  };
}

/// "Sudut pandang cloud": jumlah baris transactions NON-cancelled yang
/// transaction_date-nya jatuh dalam jendela shift — inilah yang dilihat
/// backend saat rekonsiliasi (baris transactions tersinkron).
Future<int> cloudView(String since, String until) async {
  final r = await db.rawQuery(
    '''
      SELECT COUNT(*) AS cnt FROM transactions
      WHERE status != 'cancelled'
        AND transaction_date >= ? AND transaction_date < ?
    ''',
    [since, until],
  );
  return (r.first['cnt'] as num).toInt();
}

// ── Verifikasi S2 [10:00, 22:00) ────────────────────────────────────────────
Future<void> _verifyS2() async {
  final rep = await shiftReport('S2');
  print('[S2] Laporan shift utama 10:00-22:00');

  // EKSPEKTASI sales_count = 4, alasannya:
  //   A (tx 11:00) ✓, B (tx 12:00, split = TETAP 1 transaksi) ✓,
  //   C (tx 13:00, diskon 100% tanpa payments) ✓, D (tx 14:00, kompliment) ✓,
  //   E (tx 15:00) TIDAK — order voided_at 16:00 → tereksklusi JOIN orders,
  //   F (tx 09:00) TIDAK — di luar jendela (dan voided),
  //   G (tx 23:00) TIDAK — lunas setelah S2 tutup, milik S3.
  check('sales_count == 4 (A,B,C,D; E void, F&G di luar jendela)',
      rep['sales_count'], 4);

  final by = rep['by_method'] as Map<String, Map<String, num>>;
  // by_method dari baris payments dalam jendela (order non-void):
  //   cash: A 100k (11:00) + B 60k (12:00) + G partial 50k (21:00) = 3 baris,
  //         210k. Uang partial G BENAR masuk laci S2 saat 21:00 walau
  //         transaksinya baru tercatat lunas di S3.
  //   qris: B 40k = 1 baris. E (cash 70k) tereksklusi karena order voided;
  //   F (09:00) di luar jendela.
  check('by_method cash count == 3 (A, B-cash, G-partial)',
      by['cash']!['count']!.toInt(), 3);
  check('by_method cash total == 210000', by['cash']!['total']!.toDouble(),
      210000.0);
  check('by_method qris count == 1 (B-qris)', by['qris']!['count']!.toInt(), 1);
  check('by_method qris total == 40000', by['qris']!['total']!.toDouble(),
      40000.0);
  check('by_method card count == 0', by['card']!['count']!.toInt(), 0);
  check('by_method transfer count == 0', by['transfer']!['count']!.toInt(), 0);

  // sales_total = jumlah semua baris payments valid = 210k + 40k.
  check('sales_total == 250000', rep['sales_total'], 250000.0);

  // Diskon: hanya C (charge 'Diskon' -80k, transaksi 13:00 dalam jendela).
  // Diskon G (-20k) TIDAK boleh ikut — transaksinya 23:00 (S3).
  check('discount_count == 1 (hanya C; diskon G milik S3)',
      rep['discount_count'], 1);
  check('discount_total == 80000', rep['discount_total'], 80000.0);

  // Kompliment: hanya D (complimented_at 14:00, tidak voided).
  check('compliment_count == 1 (D)', rep['compliment_count'], 1);
  check('compliment_total == 50000', rep['compliment_total'], 50000.0);

  // Void: E (voided 16:00, 70k) + F (voided 17:00, 90k) — keduanya voided_at
  // dalam jendela S2 walau F dibayar di S1.
  check('void_count == 2 (E & F)', rep['void_count'], 2);
  check('void_total == 160000 (70k + 90k)', rep['void_total'], 160000.0);

  // Kas masuk/keluar
  check('cash_in: 1 x 10000', '${rep['cash_in_count']}/${rep['cash_in_total']}',
      '1/10000.0');
  check('cash_out: 1 x 90000 (refund void F)',
      '${rep['cash_out_count']}/${rep['cash_out_total']}', '1/90000.0');

  // expected_cash = modal 500k + tunai (A 100k + B 60k + G-partial 50k = 210k)
  //                 + kas masuk 10k - kas keluar 90k (refund F) = 630k.
  // CATATAN: partial G 50k WAJIB ikut — uang itu fisik masuk laci jam 21:00.
  check('expected_cash == 630000 (500k + 210k + 10k - 90k)',
      rep['expected_cash'], 630000.0);

  // Rekonsiliasi: sudut pandang cloud (baris transactions non-cancelled
  // dalam jendela S2) harus SAMA dengan sales_count laporan.
  final cloud = await cloudView(rep['since'] as String, rep['until'] as String);
  check('cloud view (tx non-cancelled di jendela) == sales_count',
      cloud, rep['sales_count']);
  print('');
}

// ── Verifikasi S3 [22:00, sekarang) ─────────────────────────────────────────
Future<void> _verifyS3() async {
  final rep = await shiftReport('S3');
  print('[S3] Shift berikutnya 22:00-sekarang (masih open)');

  // G lunas 23:00 → 1 transaksi milik S3.
  check('sales_count == 1 (G lunas 23:00)', rep['sales_count'], 1);

  // Diskon G muncul TEPAT SEKALI, di S3 (bukan di S2, tidak dobel).
  check('discount_count == 1 (diskon G tercatat sekali, di S3)',
      rep['discount_count'], 1);
  check('discount_total == 20000', rep['discount_total'], 20000.0);

  final by = rep['by_method'] as Map<String, Map<String, num>>;
  check('by_method cash == pelunasan G 30000 saja',
      '${by['cash']!['count']}/${by['cash']!['total']}', '1/30000.0');

  final cloud = await cloudView(rep['since'] as String, rep['until'] as String);
  check('cloud view == sales_count', cloud, rep['sales_count']);
  print('');
}

// ── Pengamatan S1 [00:00, 10:00) — recompute pasca void lintas shift ────────
Future<void> _observeS1() async {
  final rep = await shiftReport('S1');
  print('[S1] Recompute shift lama (F di-void belakangan di S2) — pengamatan,'
      ' bukan assert:');
  observe(
      'sales_count S1 kini ${rep['sales_count']} (semula 1: order F) — '
      'void lintas shift MENGUBAH laporan historis S1 bila dihitung ulang',
      null);
  observe(
      'by_method cash S1 kini ${(rep['by_method'] as Map)['cash']} — '
      'pembayaran F 90k ikut hilang dari recompute',
      null);
  final cloud = await cloudView(rep['since'] as String, rep['until'] as String);
  observe(
      'cloud view S1 = $cloud — konsisten dengan recompute lokal '
      '(keduanya turun bersama; struk S1 yang SUDAH tercetak/tersinkron '
      'saat tutup shift tetap memuat angka lama)',
      null);
}
