import 'package:sqflite/sqflite.dart';

import '../database/database.dart';
import '../models/models.dart';
import '../utils/ulid.dart';
import 'order_repository.dart';
import 'sync_queue_repository.dart';

class CashierRepository {
  CashierRepository({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final AppDatabase _db = AppDatabase.instance;
  final SyncQueueRepository _sync = SyncQueueRepository();
  final DateTime Function() _now;

  /// Timestamp payload cloud: SELALU UTC + 'Z' (zona eksplisit). DB lokal tetap
  /// waktu lokal.
  String _isoUtc(DateTime dt) => dt.toUtc().toIso8601String();

  // ==================== SHIFT MANAGEMENT ====================

  Future<CashierShift?> getActiveShift({DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    final results = await db.query(
      'cashier_shifts',
      where: "status = 'open'",
      orderBy: 'opened_at DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    return CashierShift.fromMap(results.first);
  }

  Future<CashierShift> openShift({
    required String openedBy,
    required double openingCash,
  }) async {
    final db = await _db.database;
    return db.transaction((txn) async {
      final activeShift = await getActiveShift(executor: txn);
      if (activeShift != null) {
        throw Exception('Shift sudah dibuka oleh ${activeShift.openedBy}');
      }

      final now = _now();
      final shift = CashierShift(
        id: Ulid.generate(),
        openedBy: openedBy,
        openedAt: now,
        openingCash: openingCash,
        status: 'open',
        createdAt: now,
        updatedAt: now,
      );

      await txn.insert('cashier_shifts', shift.toMap());
      await _enqueueShift(shift, 'create', executor: txn);
      return shift;
    });
  }

  /// Meja yang tagihannya BELUM lunas (termasuk "sebagian terbayar"), DITAMBAH
  /// Meja Titipan bila masih ada item tertitip di sana. Order yang sudah
  /// di-void tidak dihitung.
  ///
  /// Dipakai sebagai syarat tutup kasir: laci tidak boleh ditutup selama masih
  /// ada tagihan berjalan atau item menggantung di titipan, supaya laporan
  /// shift & setoran kas tidak menyisakan pekerjaan.
  Future<List<String>> unpaidTables({DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    final rows = await db.query(
      'orders',
      columns: ['table_number'],
      where:
          "payment_status != 'paid' AND voided_at IS NULL AND is_holding = 0",
      orderBy: 'created_at ASC',
    );
    final tables = <String>[];
    for (final r in rows) {
      final t = (r['table_number'] as String?) ?? '';
      if (t.isNotEmpty && !tables.contains(t)) tables.add(t);
    }

    // Meja Titipan: hanya menghalangi bila BENAR-BENAR masih ada isinya —
    // order titipan yang sudah kosong (semua item ditarik kembali) diabaikan.
    final holding = await db.query(
      'orders',
      columns: ['id'],
      where:
          "is_holding = 1 AND payment_status != 'paid' AND voided_at IS NULL",
      limit: 1,
    );
    if (holding.isNotEmpty) {
      final items = await db.query(
        'order_items',
        columns: ['id'],
        where: 'order_id = ?',
        whereArgs: [holding.first['id']],
        limit: 1,
      );
      if (items.isNotEmpty) tables.add(OrderRepository.holdingTableLabel);
    }
    return tables;
  }

  /// Ringkasan meja untuk pesan error (maksimal 3 nomor, sisanya diringkas).
  static String describeUnpaidTables(List<String> tables) {
    if (tables.length <= 3) {
      return tables.map((t) => 'Meja $t').join(', ');
    }
    final head = tables.take(3).map((t) => 'Meja $t').join(', ');
    return '$head, +${tables.length - 3} lainnya';
  }

  /// Kalimat alasan kenapa kasir belum boleh ditutup. Tagihan meja dan item
  /// tertitip disebut terpisah supaya kasir tahu persis apa yang harus
  /// diselesaikan.
  static String unpaidBlockMessage(List<String> tables) {
    final holding =
        tables.where((t) => t == OrderRepository.holdingTableLabel).isNotEmpty;
    final bills =
        tables.where((t) => t != OrderRepository.holdingTableLabel).toList();
    final parts = <String>[];
    if (bills.isNotEmpty) {
      parts.add('${bills.length} tagihan belum dibayar '
          '(${describeUnpaidTables(bills)})');
    }
    if (holding) parts.add('item yang masih tertitip di Meja Titipan');
    return 'Masih ada ${parts.join(' dan ')}.';
  }

  Future<CashierShift> closeShift({
    required String shiftId,
    required String closedBy,
    double? closingCash,
    double? closingCard,
    double? closingQris,
    double? closingTransfer,
    String? notes,
  }) async {
    final db = await _db.database;
    return db.transaction((txn) async {
      final now = _now();

      // Calculate totals from payments during this shift
      final shift = await _requireOpenShift(shiftId, executor: txn);

      // Syarat tutup kasir: semua tagihan harus selesai dibayar dulu. Dicek di
      // sini (bukan hanya di layar) supaya berlaku untuk SEMUA jalur — kasir
      // utama maupun endpoint station.
      final unpaid = await unpaidTables(executor: txn);
      if (unpaid.isNotEmpty) {
        throw Exception('${unpaidBlockMessage(unpaid)} '
            'Selesaikan dulu sebelum tutup kasir.');
      }

      final totals =
          await _calculateShiftTotals(shiftId, executor: txn, cutoff: now);

      // Kas laci = hitung fisik (closingCash) bila diberikan; selain itu pakai
      // ekspektasi teoritis modal awal + tunai + kas masuk − kas keluar.
      // Formula lama `(closingCash ?? 0) + cash` men-double-count penjualan
      // tunai bila closingCash sudah termasuk penjualan.
      final carryOverCash = closingCash ??
          await _expectedDrawerCash(shift, totals, executor: txn);

      await txn.update(
        'cashier_shifts',
        {
          'closed_at': now.toIso8601String(),
          'closed_by': closedBy,
          'closing_cash': closingCash ?? totals['cash'],
          'closing_card': closingCard ?? totals['card'],
          'closing_qris': closingQris ?? totals['qris'],
          'closing_transfer': closingTransfer ?? totals['transfer'],
          'carry_over_cash': carryOverCash,
          'status': 'closed',
          'notes': notes,
          'updated_at': now.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [shiftId],
      );

      final closed = (await _getShiftById(shiftId, executor: txn))!;
      await _enqueueShift(closed, 'update', executor: txn);
      return closed;
    });
  }

  // ==================== HANDOVER (TUKAR SHIFT) ====================

  /// Tutup shift kasir saat ini lalu buka shift baru untuk kasir berikutnya.
  /// Saldo kas akhir dibawa (carry over) sebagai modal awal shift baru.
  /// Mengembalikan shift baru yang terbuka.
  Future<CashierShift> handoverShift({
    required String currentShiftId,
    required String handoverToUserId,
    double? countedCash,
    String? notes,
  }) async {
    final db = await _db.database;
    return db.transaction((txn) async {
      final now = _now();

      final current = await _requireOpenShift(currentShiftId, executor: txn);

      final totals = await _calculateShiftTotals(currentShiftId,
          executor: txn, cutoff: now);
      // Saldo kas fisik yang diserahterimakan ke kasir berikutnya
      // (hitung fisik bila ada; selain itu modal + tunai + kas masuk − keluar).
      final carryOverCash = countedCash ??
          await _expectedDrawerCash(current, totals, executor: txn);

      // 1. Tutup shift lama, tandai handover_to
      await txn.update(
        'cashier_shifts',
        {
          'closed_at': now.toIso8601String(),
          'closed_by': current.openedBy,
          'closing_cash': totals['cash'],
          'closing_card': totals['card'],
          'closing_qris': totals['qris'],
          'closing_transfer': totals['transfer'],
          'carry_over_cash': carryOverCash,
          'handover_to': handoverToUserId,
          'status': 'closed',
          'notes': notes,
          'updated_at': now.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [currentShiftId],
      );

      // 2. Buka shift baru dengan modal = carry over, link ke shift sebelumnya
      final newShift = CashierShift(
        id: Ulid.generate(),
        openedBy: handoverToUserId,
        openedAt: now,
        openingCash: carryOverCash,
        previousShiftId: currentShiftId,
        status: 'open',
        createdAt: now,
        updatedAt: now,
      );
      await txn.insert('cashier_shifts', newShift.toMap());

      // 3. Outbox: kirim shift lama (closed) & shift baru (open) ke cloud
      final closedOld = (await _getShiftById(currentShiftId, executor: txn))!;
      await _enqueueShift(closedOld, 'update', executor: txn);
      await _enqueueShift(newShift, 'create', executor: txn);

      return newShift;
    });
  }

  // ==================== CASH MOVEMENTS ====================

  Future<CashMovement> addCashMovement({
    required String shiftId,
    required String movementType,
    required double amount,
    required String counterpartName,
    String note = '',
  }) async {
    final db = await _db.database;
    return db.transaction((txn) async {
      await _requireOpenShift(shiftId, executor: txn);
      final movement = CashMovement(
        id: Ulid.generate(),
        shiftId: shiftId,
        movementType: movementType,
        amount: amount,
        counterpartName: counterpartName,
        note: note,
        createdAt: _now(),
      );
      await txn.insert('cashier_cash_movements', movement.toMap());
      await _enqueueCashMovement(movement, executor: txn);
      return movement;
    });
  }

  Future<void> _enqueueCashMovement(CashMovement movement,
      {DatabaseExecutor? executor}) {
    return _sync.enqueue(
      entityType: 'cashier_cash_movement',
      entityId: movement.id,
      operation: 'create',
      payload: {
        'local_id': movement.id,
        'shift_id': movement.shiftId,
        'movement_type':
            movement.movementType, // 'in' (penerimaan) | 'out' (pengeluaran)
        'amount': movement.amount,
        'counterpart_name': movement.counterpartName,
        'note': movement.note,
        'created_at': _isoUtc(movement.createdAt),
      },
      executor: executor,
    );
  }

  /// Recover movements written by older versions before their outbox insert.
  /// The original ID and timestamp make a replay safe if cloud already has it.
  Future<int> enqueueUnsyncedCashMovements() async {
    final db = await _db.database;
    return db.transaction((txn) async {
      final rows = await txn.rawQuery('''
        SELECT m.* FROM cashier_cash_movements m
        WHERE NOT EXISTS (
          SELECT 1 FROM sync_queue q
          WHERE q.entity_type='cashier_cash_movement' AND q.entity_id=m.id
        )
        ORDER BY m.created_at, m.id
      ''');
      for (final row in rows) {
        await _enqueueCashMovement(CashMovement.fromMap(row), executor: txn);
      }
      return rows.length;
    });
  }

  Future<List<CashMovement>> getShiftMovements(String shiftId) async {
    final results = await _db.query(
      'cashier_cash_movements',
      where: 'shift_id = ?',
      whereArgs: [shiftId],
      orderBy: 'created_at DESC',
    );
    return results.map((m) => CashMovement.fromMap(m)).toList();
  }

  // ==================== HELPERS ====================

  Future<CashierShift?> _getShiftById(String id,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    final results = await db.query(
      'cashier_shifts',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (results.isEmpty) return null;
    return CashierShift.fromMap(results.first);
  }

  Future<CashierShift> _requireOpenShift(String id,
      {required DatabaseExecutor executor}) async {
    final shift = await _getShiftById(id, executor: executor);
    if (shift == null) throw Exception('Shift tidak ditemukan');
    if (!shift.isOpen) throw Exception('Shift sudah ditutup');
    if ((await getActiveShift(executor: executor))?.id != id) {
      throw Exception(
          'Shift kasir telah berubah. Muat ulang sebelum melanjutkan.');
    }
    return shift;
  }

  Future<Map<String, double>> getShiftTotals(String shiftId) =>
      _calculateShiftTotals(shiftId);

  static String _dateKey(DateTime value) {
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static Map<String, Map<String, num>> _emptyMethods() => {
        for (final method in ['cash', 'card', 'qris', 'transfer'])
          method: {'count': 0, 'total': 0},
      };

  static Map<String, dynamic> _emptyDay(String date) => {
        'date': date,
        'sales_count': 0,
        'sales_total': 0.0,
        'by_method': _emptyMethods(),
        'cash_in_count': 0,
        'cash_in_total': 0.0,
        'cash_out_count': 0,
        'cash_out_total': 0.0,
        'outside_shift': false,
      };

  /// Laporan shift lengkap untuk struk & sync cloud:
  /// per metode bayar (jumlah transaksi + total), kas masuk/keluar, ekspektasi kas.
  Future<Map<String, dynamic>> getShiftReport(String shiftId,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    final shift = await _getShiftById(shiftId, executor: db);
    if (shift == null) throw Exception('Shift tidak ditemukan');

    // Jendela shift [opened_at, closed_at). Tanpa batas atas, cetak ulang
    // laporan shift LAMA ikut menghitung pembayaran shift berikutnya.
    // .toLocal() menormalkan shift hasil restore cloud (tersimpan UTC+Z).
    final periodStart = shift.openedAt.toLocal();
    final periodEnd = (shift.closedAt ?? _now()).toLocal();
    final since = periodStart.toIso8601String();
    final until = periodEnd.toIso8601String();

    // A shift can stay open overnight. Keep its complete ledger and show a
    // separate calendar-day breakdown instead of silently dropping earlier
    // sales. At midnight, the exclusive end belongs to the preceding day.
    // Restored/forgotten shifts can be very old. Include the endpoints and
    // every date with activity, without allocating years of empty rows.
    final lastDay = periodEnd.isAfter(periodStart)
        ? periodEnd.subtract(const Duration(microseconds: 1))
        : periodStart;
    final daily = <String, Map<String, dynamic>>{
      _dateKey(periodStart): _emptyDay(_dateKey(periodStart)),
      _dateKey(lastDay): _emptyDay(_dateKey(lastDay)),
    };
    Map<String, dynamic> dayFor(String date) =>
        daily.putIfAbsent(date, () => _emptyDay(date));
    final crossesDay = _dateKey(periodStart) != _dateKey(lastDay);

    // Breakdown per metode: count + total
    final payRows = await db.rawQuery(
      '''
      SELECT substr(p.created_at, 1, 10) AS day, p.payment_method,
             COUNT(*) AS cnt, SUM(p.amount) AS total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE p.created_at >= ? AND p.created_at < ? AND o.voided_at IS NULL
      GROUP BY substr(p.created_at, 1, 10), p.payment_method
    ''',
      [since, until],
    );

    final methods = _emptyMethods();
    var salesTotal = 0.0;
    for (final r in payRows) {
      final m = r['payment_method'] as String;
      final cnt = (r['cnt'] as num).toInt();
      final total = (r['total'] as num).toDouble();
      final aggregate = methods.putIfAbsent(m, () => {'count': 0, 'total': 0});
      aggregate['count'] = aggregate['count']! + cnt;
      aggregate['total'] = aggregate['total']! + total;
      salesTotal += total;
      final day = dayFor(r['day'] as String);
      final dayMethods = day['by_method'] as Map<String, Map<String, num>>;
      dayMethods[m] = {'count': cnt, 'total': total};
      day['sales_total'] = (day['sales_total'] as num) + total;
    }

    // Jumlah TRANSAKSI = jumlah order yang selesai dalam jendela shift, dari
    // tabel transactions (TEPAT 1 baris per order lunas/kompliment/diskon
    // 100%) — BUKAN jumlah baris payments, yang bisa >1 per order pada split
    // bill/gabung bayar (menggelembungkan hitungan) dan 0 pada order diskon
    // 100%/kompliment (tabel payments meng-CHECK amount > 0, jadi order
    // semacam itu tak pernah punya baris payments sama sekali).
    final salesCountRows = await db.rawQuery(
      '''
      SELECT substr(t.transaction_date, 1, 10) AS day, COUNT(*) AS cnt
      FROM transactions t
      JOIN orders o ON o.id = t.order_id
      WHERE t.transaction_date >= ? AND t.transaction_date < ? AND o.voided_at IS NULL
      GROUP BY substr(t.transaction_date, 1, 10)
    ''',
      [since, until],
    );
    var salesCount = 0;
    for (final row in salesCountRows) {
      final count = (row['cnt'] as num).toInt();
      salesCount += count;
      dayFor(row['day'] as String)['sales_count'] = count;
    }

    // Kas masuk / keluar selama shift
    final moveRows = await db.rawQuery(
      '''
      SELECT movement_type, amount, created_at
      FROM cashier_cash_movements
      WHERE shift_id = ?
    ''',
      [shiftId],
    );
    var cashInCount = 0, cashOutCount = 0;
    var cashInTotal = 0.0, cashOutTotal = 0.0;
    var outOfPeriodMovementCount = 0;
    for (final r in moveRows) {
      final t = r['movement_type'] as String;
      final total = (r['amount'] as num).toDouble();
      final at = DateTime.parse(r['created_at'] as String).toLocal();
      final day = dayFor(_dateKey(at));
      // Older versions allowed stale clients to add a movement after close.
      // Preserve those assigned amounts and make their time anomaly visible.
      if (at.isBefore(periodStart) || !at.isBefore(periodEnd)) {
        day['outside_shift'] = true;
        outOfPeriodMovementCount++;
      }
      if (t == 'in') {
        cashInCount++;
        cashInTotal += total;
        day['cash_in_count'] = (day['cash_in_count'] as int) + 1;
        day['cash_in_total'] = (day['cash_in_total'] as num) + total;
      } else if (t == 'out') {
        cashOutCount++;
        cashOutTotal += total;
        day['cash_out_count'] = (day['cash_out_count'] as int) + 1;
        day['cash_out_total'] = (day['cash_out_total'] as num) + total;
      }
    }

    final cashSales = methods['cash']!['total']!.toDouble();
    // Ekspektasi kas laci = modal awal + penjualan tunai + kas masuk - kas keluar
    final expectedCash =
        shift.openingCash + cashSales + cashInTotal - cashOutTotal;

    // Rincian per kasir (termasuk kasir station) sejak shift dibuka.
    final cashierRows = await db.rawQuery(
      '''
      SELECT p.created_by, COUNT(*) AS cnt, SUM(p.amount) AS total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE p.created_at >= ? AND p.created_at < ? AND p.created_by != '' AND o.voided_at IS NULL
      GROUP BY p.created_by
      ORDER BY total DESC
    ''',
      [since, until],
    );
    final byCashier = cashierRows
        .map((r) => {
              'cashier': r['created_by'],
              'count': (r['cnt'] as num).toInt(),
              'total': (r['total'] as num).toDouble(),
            })
        .toList();

    // ── Metrik pengawasan: diskon, kompliment, void selama shift ────────────

    // Diskon: charge 'Diskon' pada order yang SELESAI (ada baris transactions,
    // termasuk diskon 100%/kompliment tanpa baris payments) di shift ini & tidak
    // di-void. Basis transactions (bukan payments) juga mencegah order yang
    // dibayar parsial lintas shift terhitung dobel — transactions dicatat TEPAT
    // sekali, saat order benar-benar lunas. Di-agregat per order dulu agar
    // split-payment tidak menggandakan.
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

    // Kompliment: order digratiskan di shift ini (nilai = subtotal digratiskan).
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

    // Void: transaksi dibatalkan di shift ini (nilai = total tagihan yang di-void).
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

    // Titipan: item yang SEDANG di Meja Titipan (snapshot saat tutup — kontrol).
    // Bukan jendela waktu; menunjukkan barang menggantung yang belum terjual.
    final heldRows = await db.rawQuery('''
      SELECT COUNT(*) AS cnt, COALESCE(SUM(oi.qty * oi.price), 0) AS total
      FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE o.is_holding = 1 AND o.payment_status != 'paid' AND o.voided_at IS NULL
    ''');
    final heldCount = (heldRows.first['cnt'] as num?)?.toInt() ?? 0;
    final heldTotal = (heldRows.first['total'] as num?)?.toDouble() ?? 0;

    return {
      'shift_id': shiftId,
      'period_start': since,
      'period_end': until,
      'crosses_day': crossesDay,
      'by_day': [for (final date in daily.keys.toList()..sort()) daily[date]!],
      'out_of_period_movement_count': outOfPeriodMovementCount,
      'opening_cash': shift.openingCash,
      'sales_count': salesCount,
      'sales_total': salesTotal,
      'by_method': methods, // {cash:{count,total}, qris:{...}, ...}
      'by_cashier': byCashier, // [{cashier, count, total}, ...]
      'cash_in_count': cashInCount,
      'cash_in_total': cashInTotal,
      'cash_out_count': cashOutCount,
      'cash_out_total': cashOutTotal,
      'expected_cash': expectedCash,
      // Metrik pengawasan (tidak memengaruhi kas — hanya kontrol)
      'discount_count': discountCount,
      'discount_total': discountTotal,
      'compliment_count': complimentCount,
      'compliment_total': complimentTotal,
      'void_count': voidCount,
      'void_total': voidTotal,
      'held_count': heldCount, // item di Meja Titipan (belum terjual)
      'held_total': heldTotal,
    };
  }

  /// Tulis shift ke outbox cloud dengan breakdown lengkap (jumlah transaksi
  /// per metode + kas masuk/keluar). Field terstruktur (closing_*) tetap
  /// dikirim agar cloud bisa simpan; `report` membawa rincian count.
  Future<void> _enqueueShift(CashierShift shift, String operation,
      {DatabaseExecutor? executor}) async {
    final report = await getShiftReport(shift.id, executor: executor);
    await _sync.enqueue(
      entityType: 'cashier_shift',
      entityId: shift.id,
      operation: operation,
      payload: {
        'local_id': shift.id,
        'opened_by': shift.openedBy,
        'opened_at': _isoUtc(shift.openedAt),
        'opening_cash': shift.openingCash,
        'closed_at': shift.closedAt != null ? _isoUtc(shift.closedAt!) : '',
        'closed_by': shift.closedBy ?? '',
        'closing_cash': shift.closingCash ?? 0,
        'closing_card': shift.closingCard ?? 0,
        'closing_qris': shift.closingQris ?? 0,
        'closing_transfer': shift.closingTransfer ?? 0,
        'carry_over_cash': shift.carryOverCash ?? 0,
        'previous_shift_id': shift.previousShiftId ?? '',
        'handover_to': shift.handoverTo ?? '',
        'status': shift.status,
        'notes': shift.notes ?? '',
        // Rincian lengkap (jumlah transaksi per metode + kas masuk/keluar)
        'report': report,
      },
      executor: executor,
    );
  }

  /// Ringkasan kerja seorang kasir sejak [sinceIso] (jendela login station):
  /// jumlah pembayaran & total per metode, dari tabel payments (created_by).
  /// Tidak menutup shift laci kas — hanya rekap kontribusi kasir tsb.
  Future<Map<String, dynamic>> getCashierSessionSummary(
      String cashierName, String sinceIso) async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      '''
      SELECT p.payment_method, COUNT(*) AS cnt, SUM(p.amount) AS total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE p.created_by = ? AND p.created_at >= ? AND o.voided_at IS NULL
      GROUP BY p.payment_method
    ''',
      [cashierName, sinceIso],
    );
    final methods = <String, Map<String, num>>{
      'cash': {'count': 0, 'total': 0},
      'card': {'count': 0, 'total': 0},
      'qris': {'count': 0, 'total': 0},
      'transfer': {'count': 0, 'total': 0},
    };
    var count = 0;
    var total = 0.0;
    for (final r in rows) {
      final m = r['payment_method'] as String;
      final c = (r['cnt'] as num).toInt();
      final t = (r['total'] as num).toDouble();
      methods[m] = {'count': c, 'total': t};
      count += c;
      total += t;
    }
    return {
      'cashier': cashierName,
      'since': sinceIso,
      'count': count,
      'total': total,
      'by_method': methods,
    };
  }

  // ==================== USERS ====================

  Future<List<User>> getCashierUsers() async {
    final results = await _db.query(
      'users',
      where: "is_active = 1",
      orderBy: 'full_name ASC',
    );
    return results.map((m) => User.fromMap(m)).toList();
  }

  /// Ekspektasi kas fisik laci sebuah shift:
  /// modal awal + penjualan tunai + kas masuk − kas keluar.
  /// Selaras dengan `expected_cash` di getShiftReport.
  Future<double> _expectedDrawerCash(
      CashierShift shift, Map<String, double> totals,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    final rows = await db.rawQuery(
      '''
      SELECT movement_type, COALESCE(SUM(amount), 0) AS total
      FROM cashier_cash_movements
      WHERE shift_id = ?
      GROUP BY movement_type
    ''',
      [shift.id],
    );
    double cashIn = 0, cashOut = 0;
    for (final r in rows) {
      final total = (r['total'] as num).toDouble();
      if (r['movement_type'] == 'in') cashIn = total;
      if (r['movement_type'] == 'out') cashOut = total;
    }
    return shift.openingCash + (totals['cash'] ?? 0) + cashIn - cashOut;
  }

  Future<Map<String, double>> _calculateShiftTotals(String shiftId,
      {DatabaseExecutor? executor, DateTime? cutoff}) async {
    final db = executor ?? await _db.database;
    // Get shift to know when it was opened
    final shift = await _getShiftById(shiftId, executor: db);
    if (shift == null) throw Exception('Shift tidak ditemukan');
    // Jendela [opened_at, closed_at) — tanpa batas atas, menghitung ulang
    // total shift LAMA akan menyerap pembayaran shift berikutnya.
    final results = await db.rawQuery(
      '''
      SELECT p.payment_method, SUM(p.amount) as total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE p.created_at >= ? AND p.created_at < ? AND o.voided_at IS NULL
      GROUP BY p.payment_method
    ''',
      [
        shift.openedAt.toLocal().toIso8601String(),
        (shift.closedAt ?? cutoff ?? _now()).toLocal().toIso8601String(),
      ],
    );

    final totals = <String, double>{};
    for (final row in results) {
      totals[row['payment_method'] as String] =
          (row['total'] as num).toDouble();
    }

    // Ensure all methods exist
    totals.putIfAbsent('cash', () => 0);
    totals.putIfAbsent('card', () => 0);
    totals.putIfAbsent('qris', () => 0);
    totals.putIfAbsent('transfer', () => 0);

    return totals;
  }
}
