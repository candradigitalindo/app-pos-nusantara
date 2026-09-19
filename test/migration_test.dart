// Verifikasi migrasi DB v10 → v13 terhadap SQLITE ASLI berisi data.
//
// Migrasi-migrasi ini menyentuh tabel yang sudah dipakai di lapangan:
//
//   v11 — MEMBUANG lalu membuat ulang product_addons (id INTEGER → ULID).
//         Aman HANYA bila tabel itu memang selalu kosong. Kalau ternyata
//         pernah terisi, data hilang tanpa jejak.
//   v12 — menambah kolom sync_id pada additional_charges dan mengisinya untuk
//         baris lama. Kolom `id` TIDAK boleh ikut berubah karena sudah
//         dirujuk order_additional_charges.charge_id di baris pesanan lama.
//   v13 — menambah orders.reservation_id dan MEMBUAT ULANG payments agar
//         metode 'reservasi_dp' diterima CHECK. Baris pembayaran lama wajib
//         selamat utuh — itu jejak uang shift-shift sebelumnya.
//
// Migrasinya dijalankan oleh AppDatabase yang SEBENARNYA — bukan salinan SQL
// di berkas ini — supaya yang teruji adalah kode yang dipakai aplikasi.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pos_resto/database/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late Database db;
late File dbFile;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final path = p.join(await getDatabasesPath(), 'pos_resto.db');
    dbFile = File(path);
    if (await dbFile.exists()) await dbFile.delete();

    await _bangunDatabaseV10(path);

    // Membuka lewat AppDatabase menjalankan _onUpgrade yang asli.
    db = await AppDatabase.instance.database;
  });

  tearDownAll(() async {
    await db.close();
    if (await dbFile.exists()) await dbFile.delete();
  });

  test('versi skema naik ke 13', () async {
    final versi = (await db.rawQuery('PRAGMA user_version')).first.values.first;
    expect(versi, 13);
  });

  group('reservasi (migrasi v13)', () {
    test('orders punya kolom reservation_id', () async {
      final info = await db.rawQuery('PRAGMA table_info(orders)');
      expect(info.map((c) => c['name']), contains('reservation_id'));
    });

    test('pembayaran lama selamat utuh setelah payments dibuat ulang', () async {
      final rows = await db.query('payments', orderBy: 'created_at');
      expect(rows.length, 2);
      expect(rows.first['payment_method'], 'cash');
      expect(rows.first['amount'], 20000.0);
      expect(rows.last['payment_method'], 'qris');
      expect(rows.last['payment_note'], 'Pesan online — dibayar QRIS');
    });

    test("metode 'reservasi_dp' diterima, metode asing tetap ditolak", () async {
      await db.insert('payments', {
        'id': '01JQTESTPAYMENT0000000RES1',
        'order_id': 'ORDERLAMA',
        'amount': 50000.0,
        'payment_method': 'reservasi_dp',
        'created_by': 'kasir',
      });
      await expectLater(
        db.insert('payments', {
          'id': '01JQTESTPAYMENT0000000BAD1',
          'order_id': 'ORDERLAMA',
          'amount': 1000.0,
          'payment_method': 'bitcoin',
          'created_by': 'kasir',
        }),
        throwsA(anything),
      );
    });

    test('indeks payments(order_id) dibuat ulang', () async {
      final idx = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_payments_order_id'");
      expect(idx, isNotEmpty);
    });
  });

  group('additional_charges (migrasi v12)', () {
    test('ketiga baris biaya selamat', () async {
      final rows = await db.query('additional_charges');
      expect(rows.length, 3);
    });

    test('nilai lama tidak bergeser', () async {
      // Kalau tarif berubah diam-diam, seluruh tagihan setelah pembaruan
      // aplikasi jadi salah tanpa ada yang menyadarinya.
      final rows = await db.query('additional_charges',
          where: 'name = ?', whereArgs: ['Pajak Restoran (PB1)']);
      expect(rows.single['value'], 10.0);
      expect(rows.single['id'], 1, reason: 'id dirujuk pesanan lama');
    });

    test('baris nonaktif ikut termigrasi', () async {
      final rows = await db.query('additional_charges',
          where: 'name = ?', whereArgs: ['Biaya Kemasan']);
      expect(rows.single['is_active'], 0);
      expect(rows.single['sync_id'], isA<String>());
    });

    test('sync_id terisi untuk semua baris dan unik', () async {
      // Syarat agar daftar biaya bisa dikirim ke cloud; tanpa ini cloud tidak
      // bisa menghitung nominal QRIS yang sama dengan kasir.
      final rows = await db.query('additional_charges');
      final ids = rows.map((r) => r['sync_id']).toList();
      expect(ids.every((v) => v is String && v.length == 26), isTrue,
          reason: 'sync_id: $ids');
      expect(ids.toSet().length, rows.length);
    });
  });

  group('product_addons (migrasi v11)', () {
    test('id menjadi TEXT dan kolom baru ada', () async {
      final info = await db.rawQuery('PRAGMA table_info(product_addons)');
      final kolom = {
        for (final c in info) c['name'] as String: c['type'] as String
      };
      expect(kolom['id'], 'TEXT', reason: 'ULID, bukan INTEGER lagi');
      expect(kolom.keys, containsAll(['group_name', 'sort_order', 'is_deleted']));
    });

    test('indeks pencarian dibuat', () async {
      final idx = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_addons_product'");
      expect(idx, isNotEmpty);
    });

    test('tabel kosong setelah dibuat ulang', () async {
      // Dasar keputusan v11: tabel lama tidak pernah punya UI pengisinya.
      expect(await db.query('product_addons'), isEmpty);
    });

    test('menerima ULID dan menolak id lain', () async {
      await db.insert('product_addons', {
        'id': '01JQTESTULID00000000000000',
        'product_id': 'PRD1',
        'name': 'Extra keju',
        'price': 5000.0,
      });
      expect((await db.query('product_addons')).length, 1);

      await expectLater(
        db.insert('product_addons',
            {'id': 'pendek', 'product_id': 'PRD1', 'name': 'x', 'price': 0.0}),
        throwsA(anything),
      );
    });
  });

  group('order_additional_charges (pesanan historis)', () {
    test('baris pesanan lama utuh dan nominalnya tidak berubah', () async {
      final rows =
          await db.query('order_additional_charges', orderBy: 'id ASC');
      expect(rows.length, 2);
      expect(rows.first['applied_amount'], 2500.0);
    });

    test('tidak ada rujukan charge_id yang yatim', () async {
      // Inilah alasan kolom id additional_charges TIDAK diganti tipe: baris
      // pesanan historis merujuknya lewat INTEGER. Kalau id-nya berubah,
      // laporan pajak pesanan lama kehilangan induknya.
      final yatim = await db.rawQuery('''
        SELECT COUNT(*) AS n FROM order_additional_charges oc
        WHERE oc.charge_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM additional_charges c WHERE c.id = oc.charge_id)
      ''');
      expect(yatim.first['n'], 0);
    });
  });
}

/// Membangun database berbentuk v10 — skema SEBELUM kedua migrasi — lalu
/// mengisinya dengan data yang mewakili outlet yang sudah berjalan.
Future<void> _bangunDatabaseV10(String path) async {
  final old = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(version: 10),
  );

  await old.execute('''
    CREATE TABLE products (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      price REAL NOT NULL DEFAULT 0,
      is_deleted INTEGER NOT NULL DEFAULT 0
    )
  ''');

  // Bentuk LAMA product_addons: id INTEGER AUTOINCREMENT.
  await old.execute('''
    CREATE TABLE product_addons (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      product_id TEXT NOT NULL,
      name TEXT NOT NULL,
      price REAL NOT NULL DEFAULT 0,
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
    )
  ''');

  // Bentuk LAMA additional_charges: tanpa sync_id.
  await old.execute('''
    CREATE TABLE additional_charges (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      outlet_id TEXT,
      name TEXT NOT NULL,
      charge_type TEXT NOT NULL CHECK (charge_type IN ('percentage', 'fixed')),
      value REAL NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  ''');

  await old.execute('''
    CREATE TABLE order_additional_charges (
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

  // Bentuk LAMA orders & payments (v10): tanpa reservation_id, CHECK metode
  // tanpa 'reservasi_dp'. Kedua tabel ini disentuh migrasi v13.
  await old.execute('''
    CREATE TABLE orders (
      id TEXT PRIMARY KEY,
      table_number TEXT NOT NULL,
      total_amount REAL NOT NULL,
      paid_amount REAL NOT NULL DEFAULT 0,
      payment_status TEXT NOT NULL DEFAULT 'unpaid',
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  ''');
  await old.execute('''
    CREATE TABLE payments (
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
  await old.execute(
      'CREATE INDEX IF NOT EXISTS idx_payments_order_id ON payments(order_id)');
  await old.insert('orders', {
    'id': 'ORDERLAMA',
    'table_number': 'A1',
    'total_amount': 45000.0,
    'paid_amount': 45000.0,
    'payment_status': 'paid',
  });
  await old.insert('payments', {
    'id': '01JQTESTPAYMENT0000000CASH',
    'order_id': 'ORDERLAMA',
    'amount': 20000.0,
    'payment_method': 'cash',
    'created_by': 'kasir',
    'created_at': '2026-08-01T10:00:00.000',
  });
  await old.insert('payments', {
    'id': '01JQTESTPAYMENT0000000QRIS',
    'order_id': 'ORDERLAMA',
    'amount': 25000.0,
    'payment_method': 'qris',
    'payment_note': 'Pesan online — dibayar QRIS',
    'created_by': 'kasir',
    'created_at': '2026-08-01T10:05:00.000',
  });

  await old.insert('products',
      {'id': 'PRD1', 'name': 'Nasi Goreng', 'price': 25000});

  // Outlet yang sudah berjalan: pajak + service charge + biaya tetap nonaktif.
  await old.insert('additional_charges', {
    'name': 'Pajak Restoran (PB1)', 'charge_type': 'percentage',
    'value': 10.0, 'is_active': 1,
  });
  await old.insert('additional_charges', {
    'name': 'Service Charge', 'charge_type': 'percentage',
    'value': 5.0, 'is_active': 1,
  });
  await old.insert('additional_charges', {
    'name': 'Biaya Kemasan', 'charge_type': 'fixed',
    'value': 2000.0, 'is_active': 0,
  });

  // Pesanan historis yang merujuk biaya di atas lewat charge_id INTEGER.
  await old.insert('order_additional_charges', {
    'order_id': 'ORDERLAMA', 'charge_id': 1, 'name': 'Pajak Restoran (PB1)',
    'charge_type': 'percentage', 'value': 10.0, 'applied_amount': 2500.0,
  });
  await old.insert('order_additional_charges', {
    'order_id': 'ORDERLAMA', 'charge_id': 2, 'name': 'Service Charge',
    'charge_type': 'percentage', 'value': 5.0, 'applied_amount': 1250.0,
  });

  await old.close();
}
