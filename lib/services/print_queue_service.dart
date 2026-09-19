import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../utils/ulid.dart';
import 'printer_service.dart';

/// Antrian cetak dapur/bar yang durable + retry, meniru pola print_worker
/// di backend Go (app-pos). Job ditulis ke tabel `kitchen_print_jobs`, lalu
/// worker memprosesnya satu per satu (serial) agar koneksi Bluetooth (SPP
/// single-session) tidak tabrakan saat transaksi datang bertubi-tubi.
///
/// Struk kasir TIDAK lewat sini — tetap cetak langsung.
class PrintQueueService {
  static final PrintQueueService instance = PrintQueueService._();
  PrintQueueService._();

  final _db = AppDatabase.instance;
  final _printer = PrinterService();

  Timer? _timer;
  bool _draining = false;

  static const _pollInterval = Duration(milliseconds: 1500);
  static const _maxRetries = 5;
  static const _staleLockSeconds = 120;
  static const _batchLimit = 20;
  // Backoff antar-retry: 5s, 10s, 20s, 40s (dulu 3 retry beruntun dalam ~5
  // detik → printer yang sekejap reboot langsung 'failed' permanen).
  static const _retryBaseDelay = Duration(seconds: 5);
  // Auto-recover: job 'failed' yang masih muda di-requeue otomatis berkala
  // (dulu hanya lewat tombol manual "Cetak Ulang").
  static const _autoRecoverWindow = Duration(minutes: 30);
  static const _autoRecoverEvery = Duration(minutes: 5);

  bool get isRunning => _timer != null;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_pollInterval, (_) => _drain());
    unawaited(_drain()); // proses langsung tanpa menunggu tick pertama
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  // ── Enqueue ─────────────────────────────────────────────────────────────────

  /// Buat satu job cetak untuk [printer] tertentu. Dipakai routing per-printer
  /// (printer memilih kategori menu yang dicetaknya).
  Future<void> enqueueForPrinter(
    PrinterDevice printer, {
    required List<int> bytes,
    String label = '',
  }) async {
    final db = await _db.database;
    final now = DateTime.now().toIso8601String();
    await db.insert('kitchen_print_jobs', {
      'id': Ulid.generate(),
      'printer_address': printer.address,
      'printer_type': printer.type.name,
      'role': printer.rolesLabel,
      'payload': Uint8List.fromList(bytes),
      'label': label,
      'status': 'pending',
      'retry_count': 0,
      'created_at': now,
      'updated_at': now,
    });
    unawaited(_drain()); // segera proses
  }

  // ── Worker ──────────────────────────────────────────────────────────────────

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      final db = await _db.database;
      final nowIso = DateTime.now().toIso8601String();

      // Reset lock basi (kalau worker mati di tengah proses)
      final staleBefore = DateTime.now()
          .subtract(const Duration(seconds: _staleLockSeconds))
          .toIso8601String();
      await db.rawUpdate(
        '''
        UPDATE kitchen_print_jobs
        SET locked_at = NULL, updated_at = ?
        WHERE status = 'pending' AND locked_at IS NOT NULL AND locked_at <= ?
        ''',
        [nowIso, staleBefore],
      );

      // Auto-recover: requeue job 'failed' yang masih muda (created dalam
      // _autoRecoverWindow) dan sudah "diam" >= _autoRecoverEvery sejak
      // percobaan terakhir. Bounded: setelah window lewat, tetap failed
      // (butuh tombol manual) — tak ada loop abadi untuk printer yang mati.
      final recoverCreatedAfter =
          DateTime.now().subtract(_autoRecoverWindow).toIso8601String();
      final recoverIdleBefore =
          DateTime.now().subtract(_autoRecoverEvery).toIso8601String();
      await db.rawUpdate(
        '''
        UPDATE kitchen_print_jobs
        SET status = 'pending', retry_count = 0, locked_at = NULL, updated_at = ?
        WHERE status = 'failed' AND created_at >= ? AND updated_at <= ?
        ''',
        [nowIso, recoverCreatedAfter, recoverIdleBefore],
      );

      final jobs = await db.query(
        'kitchen_print_jobs',
        where: "status = 'pending' AND locked_at IS NULL",
        orderBy: 'created_at ASC',
        limit: _batchLimit,
      );
      if (jobs.isEmpty) return;

      // Serial: satu job selesai dulu sebelum job berikutnya (aman untuk BT).
      final now = DateTime.now();
      for (final job in jobs) {
        final id = job['id'] as String;

        // Backoff: job retry ke-N menunggu 5s·2^(N-1) sejak percobaan
        // terakhir sebelum dicoba lagi (jangan 3x beruntun dalam satu drain).
        final retryCount = job['retry_count'] as int? ?? 0;
        if (retryCount > 0) {
          final last =
              DateTime.tryParse(job['updated_at'] as String? ?? '') ?? now;
          final wait = _retryBaseDelay * (1 << (retryCount - 1));
          if (now.isBefore(last.add(wait))) continue; // belum waktunya
        }
        final claimed = await db.rawUpdate(
          '''
          UPDATE kitchen_print_jobs
          SET locked_at = ?, updated_at = ?
          WHERE id = ? AND status = 'pending' AND locked_at IS NULL
          ''',
          [
            DateTime.now().toIso8601String(),
            DateTime.now().toIso8601String(),
            id,
          ],
        );
        if (claimed == 0) continue; // sudah diklaim proses lain
        await _processJob(job);
      }
    } catch (e) {
      debugPrint('PrintQueue drain error: $e');
    } finally {
      _draining = false;
    }
  }

  Future<void> _processJob(Map<String, dynamic> job) async {
    final id = job['id'] as String;
    final address = job['printer_address'] as String;
    final typeName = job['printer_type'] as String;
    final retryCount = job['retry_count'] as int;

    final raw = job['payload'];
    final bytes = raw is Uint8List
        ? raw
        : Uint8List.fromList(List<int>.from(raw as List));

    try {
      if (typeName == PrinterType.bluetooth.name) {
        await _printer.sendBluetooth(address, bytes);
      } else {
        await _printer.sendLan(address, bytes);
      }
      await _markDone(id);
    } catch (e) {
      if (retryCount + 1 >= _maxRetries) {
        await _markFailed(id, '$e');
      } else {
        await _incrementRetry(id, '$e');
      }
    }
  }

  // ── State transitions ────────────────────────────────────────────────────────

  Future<void> _markDone(String id) async {
    final db = await _db.database;
    await db.update(
      'kitchen_print_jobs',
      {
        'status': 'done',
        'locked_at': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> _markFailed(String id, String err) async {
    final db = await _db.database;
    await db.update(
      'kitchen_print_jobs',
      {
        'status': 'failed',
        'error_message': err,
        'locked_at': null,
        'retry_count': _maxRetries,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> _incrementRetry(String id, String err) async {
    final db = await _db.database;
    await db.rawUpdate(
      '''
      UPDATE kitchen_print_jobs
      SET retry_count = retry_count + 1,
          error_message = ?,
          locked_at = NULL,
          updated_at = ?
      WHERE id = ?
      ''',
      [err, DateTime.now().toIso8601String(), id],
    );
  }

  // ── Monitoring (untuk UI/diagnostik) ─────────────────────────────────────────

  Future<Map<String, int>> stats() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      "SELECT status, COUNT(*) AS c FROM kitchen_print_jobs GROUP BY status",
    );
    final out = {'pending': 0, 'done': 0, 'failed': 0};
    for (final r in rows) {
      out[r['status'] as String] = r['c'] as int;
    }
    return out;
  }

  /// Daftar job terbaru untuk layar monitoring (tanpa kolom payload yang besar).
  Future<List<Map<String, dynamic>>> recentJobs({int limit = 50}) async {
    final db = await _db.database;
    return db.query(
      'kitchen_print_jobs',
      columns: [
        'id',
        'role',
        'printer_type',
        'printer_address',
        'label',
        'status',
        'retry_count',
        'error_message',
        'created_at',
        'updated_at',
      ],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// Hapus job yang sudah selesai lebih dari [olderThan] (housekeeping).
  Future<int> clearDone() async {
    final db = await _db.database;
    return db.delete('kitchen_print_jobs', where: "status = 'done'");
  }

  /// Coba ulang semua job yang gagal (dipanggil dari tombol "Cetak Ulang").
  Future<void> retryFailed() async {
    final db = await _db.database;
    await db.update(
      'kitchen_print_jobs',
      {
        'status': 'pending',
        'retry_count': 0,
        'error_message': null,
        'locked_at': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: "status = 'failed'",
    );
    unawaited(_drain());
  }

  /// Cetak ulang SATU job (mis. tiket bar/dapur tertentu) — termasuk yang sudah
  /// 'done'. Job dikembalikan ke antrian lalu dikirim ulang ke printer ASLINYA
  /// (printer_address tersimpan → routing kategori bar/dapur tetap benar).
  Future<void> reprint(String id) async {
    final db = await _db.database;
    await db.update(
      'kitchen_print_jobs',
      {
        'status': 'pending',
        'retry_count': 0,
        'error_message': null,
        'locked_at': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    unawaited(_drain());
  }
}
