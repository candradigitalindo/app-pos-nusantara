import 'package:shared_preferences/shared_preferences.dart';

import '../database/database.dart';

/// Service untuk membersihkan data transaksi lama (lebih dari retention days).
/// Data lengkap tersimpan di cloud, lokal hanya menyimpan minimal 3 bulan.
class DataRetentionService {
  final AppDatabase _db = AppDatabase.instance;

  /// Jalankan cleanup data lama berdasarkan outlet_config.data_retention_days.
  /// Return jumlah record yang dihapus.
  Future<int> purgeOldData() async {
    final retentionDays = await _getRetentionDays();
    if (retentionDays <= 0) {
      return 0; // 0 = tidak ada retensi (simpan selamanya)
    }

    final cutoffDate = DateTime.now().subtract(Duration(days: retentionDays));
    final cutoffStr = cutoffDate.toIso8601String();

    final db = await _db.database;
    int totalDeleted = 0;

    await db.transaction((txn) async {
      // 1. Cari order IDs yang sudah tua (completed/paid/voided dan di atas
      // retention). PENGAMAN SYNC: jangan hapus order yang datanya (order itu
      // sendiri ATAU transaksinya) masih pending/failed di outbox cloud —
      // menghapusnya berarti kehilangan data uang yang belum sampai cloud.
      final oldOrders = await txn.rawQuery(
        '''
        SELECT id FROM orders
        WHERE created_at < ?
          AND (payment_status = 'paid' OR voided_at IS NOT NULL)
          AND id NOT IN (
            SELECT entity_id FROM sync_queue
            WHERE status IN ('pending', 'failed')
          )
          AND id NOT IN (
            SELECT t.order_id FROM transactions t
            JOIN sync_queue q ON q.entity_id = t.id
            WHERE q.status IN ('pending', 'failed')
          )
        ''',
        [cutoffStr],
      );

      if (oldOrders.isEmpty) return;

      final oldOrderIds = oldOrders.map((o) => o['id'] as String).toList();

      // 2. Hapus transaction_items (via transaction)
      final oldTxns = await txn.query(
        'transactions',
        columns: ['id'],
        where:
            "order_id IN (${List.filled(oldOrderIds.length, '?').join(',')})",
        whereArgs: oldOrderIds,
      );

      if (oldTxns.isNotEmpty) {
        final oldTxnIds = oldTxns.map((t) => t['id'] as String).toList();
        totalDeleted += await txn.delete(
          'transaction_items',
          where:
              "transaction_id IN (${List.filled(oldTxnIds.length, '?').join(',')})",
          whereArgs: oldTxnIds,
        );
      }

      // 3. Hapus transactions
      totalDeleted += await txn.delete(
        'transactions',
        where:
            "order_id IN (${List.filled(oldOrderIds.length, '?').join(',')})",
        whereArgs: oldOrderIds,
      );

      // 4. Hapus payments
      totalDeleted += await txn.delete(
        'payments',
        where:
            "order_id IN (${List.filled(oldOrderIds.length, '?').join(',')})",
        whereArgs: oldOrderIds,
      );

      // 5. Hapus order_additional_charges
      totalDeleted += await txn.delete(
        'order_additional_charges',
        where:
            "order_id IN (${List.filled(oldOrderIds.length, '?').join(',')})",
        whereArgs: oldOrderIds,
      );

      // 6. Hapus order_items (cascade dari orders tapi eksplisit)
      totalDeleted += await txn.delete(
        'order_items',
        where:
            "order_id IN (${List.filled(oldOrderIds.length, '?').join(',')})",
        whereArgs: oldOrderIds,
      );

      // 7. Hapus orders
      totalDeleted += await txn.delete(
        'orders',
        where: "id IN (${List.filled(oldOrderIds.length, '?').join(',')})",
        whereArgs: oldOrderIds,
      );

      // 8. Hapus completed/done print queue lama
      totalDeleted += await txn.delete(
        'print_queue',
        where: "created_at < ? AND status IN ('done', 'failed')",
        whereArgs: [cutoffStr],
      );

      // 9. Hapus sync_queue lama yang sudah SUKSES saja. Entri 'failed'
      // dipertahankan: itu data yang BELUM pernah sampai cloud (retry habis)
      // dan bisa dikirim ulang oleh retryFailed() pada siklus sync.
      totalDeleted += await txn.delete(
        'sync_queue',
        where: "created_at < ? AND status = 'success'",
        whereArgs: [cutoffStr],
      );

      // 10. Hapus entity_versions lama yang sudah synced
      totalDeleted += await txn.delete(
        'entity_versions',
        where: "last_modified_at < ? AND sync_status = 'synced'",
        whereArgs: [cutoffStr],
      );
    });

    return totalDeleted;
  }

  /// Ambil retention days dari outlet_config.
  /// Default 90 hari (3 bulan).
  Future<int> _getRetentionDays() async {
    try {
      final results = await _db.query(
        'outlet_config',
        limit: 1,
      );
      if (results.isEmpty) return 90;
      final config = results.first;
      final days = config['data_retention_days'] as int?;
      // 0 = simpan selamanya (cloud-only mode), tapi untuk POS lokal default 90
      return days != null && days > 0 ? days : 90;
    } catch (_) {
      return 90;
    }
  }

  /// Cek apakah perlu di-purge (bisa dipanggil saat app start).
  /// Hanya purge sekali per hari.
  Future<bool> shouldPurge() async {
    final prefs = await _getPrefs();
    final lastPurge = prefs.getString('last_data_purge');
    if (lastPurge == null) return true;

    final lastDate = DateTime.tryParse(lastPurge);
    if (lastDate == null) return true;

    final now = DateTime.now();
    return now.difference(lastDate).inDays >= 1;
  }

  /// Tandai sudah purge hari ini.
  Future<void> _markPurged() async {
    final prefs = await _getPrefs();
    await prefs.setString('last_data_purge', DateTime.now().toIso8601String());
  }

  /// Jalankan purge jika perlu (dipanggil dari app init).
  Future<int> runIfNeeded() async {
    if (!await shouldPurge()) return 0;
    final deleted = await purgeOldData();
    await _markPurged();
    return deleted;
  }

  // SharedPreferences helper
  Future<SharedPreferences> _getPrefs() async {
    return SharedPreferences.getInstance();
  }
}
