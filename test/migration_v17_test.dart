// Migrasi v16 → v17 pada database lapangan yang SUDAH punya sync_queue dan
// cashier_shifts berisi data: kolom baru ditambahkan tanpa menyentuh baris
// lama (outbox yang belum terkirim & riwayat shift adalah jejak uang).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pos_resto/database/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-migration-v17-');
    await databaseFactory.setDatabasesPath(directory.path);
    final path = p.join(await getDatabasesPath(), 'pos_resto.db');

    final old = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(version: 16));
    await old.execute('''
      CREATE TABLE cashier_shifts (
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
    await old.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        payload TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'success', 'failed', 'bundled')),
        retry_count INTEGER NOT NULL DEFAULT 0,
        max_retries INTEGER NOT NULL DEFAULT 3,
        error_message TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        processed_at DATETIME,
        synced_at DATETIME
      )
    ''');
    await old.insert('cashier_shifts', {
      'id': 'SHIFTLAMA',
      'opened_by': 'Kasir Lama',
      'opened_at': '2026-11-17T09:00:00.000',
      'opening_cash': 200000,
      'closed_at': '2026-11-17T21:00:00.000',
      'closing_cash': 750000,
      'status': 'closed',
    });
    await old.insert('sync_queue', {
      'entity_type': 'transaction',
      'entity_id': 'TRXLAMA',
      'operation': 'create',
      'payload': '{"local_id":"TRXLAMA"}',
      'status': 'failed',
      'retry_count': 3,
      'error_message': 'Belum dikonfirmasi cloud',
    });
    await old.close();

    db = await AppDatabase.instance.database; // menjalankan _onUpgrade asli
  });

  tearDownAll(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('versi naik (≥17) dan kolom baru tersedia', () async {
    expect((await db.rawQuery('PRAGMA user_version')).first.values.first, 18);
    final queueColumns = (await db.rawQuery('PRAGMA table_info(sync_queue)'))
        .map((c) => c['name']);
    final shiftColumns =
        (await db.rawQuery('PRAGMA table_info(cashier_shifts)'))
            .map((c) => c['name']);
    expect(queueColumns, contains('error_kind'));
    expect(shiftColumns, contains('closing_report'));
  });

  test('baris outbox & shift lama selamat utuh', () async {
    final job = (await db.query('sync_queue')).single;
    expect(job['entity_id'], 'TRXLAMA');
    expect(job['status'], 'failed');
    expect(job['retry_count'], 3);
    expect(job['error_message'], 'Belum dikonfirmasi cloud');
    expect(job['error_kind'], isNull);

    final shift = (await db.query('cashier_shifts')).single;
    expect(shift['id'], 'SHIFTLAMA');
    expect(shift['closing_cash'], 750000);
    expect(shift['status'], 'closed');
    // Shift lama belum punya snapshot → cetak ulang menghitung ulang.
    expect(shift['closing_report'], isNull);
  });
}
