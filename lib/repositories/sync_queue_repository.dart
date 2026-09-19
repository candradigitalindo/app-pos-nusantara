import 'dart:convert';

import '../database/database.dart';

/// Outbox untuk sinkronisasi ke cloud-pos. Setiap mutasi penting (shift,
/// cash movement, transaksi) ditulis ke tabel `sync_queue` agar terkirim
/// andal walau sedang offline (at-least-once + retry).
class SyncQueueRepository {
  final AppDatabase _db = AppDatabase.instance;

  /// Masukkan satu entity ke outbox.
  /// [entityType] mengikuti kontrak cloud BatchSync: 'cashier_shift',
  /// 'cashier_cash_movement', 'transaction', 'product', 'category', dst.
  Future<void> enqueue({
    required String entityType,
    required String entityId,
    required String operation, // 'create' | 'update' | 'delete'
    required Map<String, dynamic> payload,
  }) async {
    final db = await _db.database;
    // Hapus pending & failed lama untuk entity yang sama sebelum insert baru.
    // Ini memungkinkan re-enqueue setelah retry exhausted (status='failed').
    await db.delete(
      'sync_queue',
      where: "entity_type = ? AND entity_id = ? AND status IN ('pending', 'failed')",
      whereArgs: [entityType, entityId],
    );
    await db.insert('sync_queue', {
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'payload': jsonEncode(payload),
      'status': 'pending',
      'retry_count': 0,
      'max_retries': 3,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Ambil batch pending tertua (FIFO) untuk dikirim.
  Future<List<Map<String, dynamic>>> pending({int limit = 100}) async {
    final db = await _db.database;
    return db.query(
      'sync_queue',
      where: "status = 'pending'",
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<void> markSuccess(int id) async {
    final db = await _db.database;
    await db.update(
      'sync_queue',
      {
        'status': 'success',
        'processed_at': DateTime.now().toIso8601String(),
        'synced_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(int id, String error, int retryCount, int maxRetries) async {
    final db = await _db.database;
    final exhausted = retryCount + 1 >= maxRetries;
    await db.update(
      'sync_queue',
      {
        'status': exhausted ? 'failed' : 'pending',
        'retry_count': retryCount + 1,
        'error_message': error,
        'processed_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, int>> stats() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS c FROM sync_queue GROUP BY status',
    );
    final out = {'pending': 0, 'success': 0, 'failed': 0};
    for (final r in rows) {
      out[r['status'] as String] = r['c'] as int;
    }
    return out;
  }

  /// Rekonsiliasi lokal: bandingkan transaksi (uang) vs status sinkronisasinya.
  /// READ-ONLY — tidak mengubah apa pun. Tujuannya mendeteksi dini transaksi
  /// yang BELUM terkonfirmasi terkirim ke cloud (pending/gagal/tanpa entri).
  ///
  /// Status per transaksi diturunkan dari sync_queue (entity_type='transaction'):
  ///  - synced  : ada baris status='success'
  ///  - pending : ada baris status='pending' (belum sukses)
  ///  - failed  : ada baris status='failed'
  ///  - missing : tak ada baris sama sekali (dalam jendela retensi = mencurigakan;
  ///              di luar jendela biasanya karena riwayat sukses sudah dipurge —
  ///              maka jendela dibatasi [days] hari agar tak salah tuduh).
  ///
  /// Catatan: "synced" hanya berarti App menandainya sukses secara LOKAL; untuk
  /// memastikan benar-benar tersimpan di cloud diperlukan rekonsiliasi cloud.
  Future<Map<String, dynamic>> reconciliation({int days = 30}) async {
    final db = await _db.database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String();
    final rows = await db.rawQuery(
      '''
      SELECT sync_state, COUNT(*) AS c, COALESCE(SUM(total_amount), 0) AS amt
      FROM (
        SELECT t.total_amount,
          CASE
            WHEN EXISTS (SELECT 1 FROM sync_queue q
                         WHERE q.entity_type='transaction' AND q.entity_id=t.id
                           AND q.status='success') THEN 'synced'
            WHEN EXISTS (SELECT 1 FROM sync_queue q
                         WHERE q.entity_type='transaction' AND q.entity_id=t.id
                           AND q.status='pending') THEN 'pending'
            WHEN EXISTS (SELECT 1 FROM sync_queue q
                         WHERE q.entity_type='transaction' AND q.entity_id=t.id
                           AND q.status='failed') THEN 'failed'
            ELSE 'missing'
          END AS sync_state
        FROM transactions t
        WHERE t.cancelled_at IS NULL AND t.transaction_date >= ?
      )
      GROUP BY sync_state
      ''',
      [cutoff],
    );

    final out = {
      'window_days': days,
      'synced_count': 0, 'synced_amount': 0.0,
      'pending_count': 0, 'pending_amount': 0.0,
      'failed_count': 0, 'failed_amount': 0.0,
      'missing_count': 0, 'missing_amount': 0.0,
    };
    for (final r in rows) {
      final s = r['sync_state'] as String;
      out['${s}_count'] = (r['c'] as num).toInt();
      out['${s}_amount'] = (r['amt'] as num).toDouble();
    }
    // Belum pasti terkirim = pending + gagal + tanpa entri.
    out['at_risk_count'] = (out['pending_count'] as int) +
        (out['failed_count'] as int) +
        (out['missing_count'] as int);
    out['at_risk_amount'] = (out['pending_amount'] as double) +
        (out['failed_amount'] as double) +
        (out['missing_amount'] as double);
    out['total_count'] =
        (out['synced_count'] as int) + (out['at_risk_count'] as int);
    out['total_amount'] =
        (out['synced_amount'] as double) + (out['at_risk_amount'] as double);
    return out;
  }

  /// Job terbaru untuk layar monitor (tanpa payload besar).
  Future<List<Map<String, dynamic>>> recentJobs({int limit = 50}) async {
    final db = await _db.database;
    return db.query(
      'sync_queue',
      columns: [
        'id',
        'entity_type',
        'entity_id',
        'operation',
        'status',
        'retry_count',
        'error_message',
        'created_at',
      ],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// Bersihkan riwayat yang sudah sukses.
  Future<int> clearSuccess() async {
    final db = await _db.database;
    return db.delete('sync_queue', where: "status = 'success'");
  }

  /// Reset semua job gagal agar dicoba lagi.
  Future<void> retryFailed() async {
    final db = await _db.database;
    await db.update(
      'sync_queue',
      {'status': 'pending', 'retry_count': 0, 'error_message': null},
      where: "status = 'failed'",
    );
  }
}
