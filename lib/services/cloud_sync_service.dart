import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../database/database.dart';
import '../repositories/order_repository.dart';
import '../repositories/sync_queue_repository.dart';
import '../utils/ulid.dart';
import 'device_heartbeat_service.dart';
import 'online_order_service.dart';
import 'outlet_service.dart';

/// Mengirim outbox (sync_queue) ke cloud-pos via endpoint BatchSync.
/// Meniru pola sync_worker.go di backend Go: push berkala + exponential
/// backoff saat offline. Hanya PUSH (kasir → cloud) untuk fitur laporan shift.
class CloudSyncService {
  static final CloudSyncService instance = CloudSyncService._();
  CloudSyncService._();

  final _queue = SyncQueueRepository();
  final _orderRepo = OrderRepository();
  final _outletService = OutletService();
  final _db = AppDatabase.instance;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  static const _lastSyncKey = 'cloud_last_pull_at';
  static const _lastSyncAtKey = 'cloud_last_sync_at';

  Timer? _timer;
  bool _pushBusy = false; // reentrancy guard khusus pushNow()
  int _consecutiveFails = 0;
  static const _maxBackoffMinutes = 30;

  /// True selama satu siklus sinkron berjalan — baik otomatis (timer) maupun
  /// manual (tombol kasir). UI mendengarkan ini agar tombol ikut berputar saat
  /// auto-sync, sekaligus mencegah tap manual memicu siklus ganda.
  final ValueNotifier<bool> syncing = ValueNotifier(false);

  bool get isSyncing => syncing.value;

  /// Status ringkas untuk indikator UI kasir.
  /// [enabled] sync aktif?, [pending] jumlah item outbox belum terkirim,
  /// [online] siklus terakhir tidak gagal jaringan.
  Future<({bool enabled, int pending, bool online})> status() async {
    final outlet = await _outletService.loadOutlet();
    final stats = await _queue.stats();
    final pending = (stats['pending'] ?? 0) + (stats['failed'] ?? 0);
    return (
      enabled: outlet.syncEnabled,
      pending: pending,
      online: _consecutiveFails == 0,
    );
  }

  /// Waktu siklus sync terakhir selesai (untuk dipantau di UI). Null bila belum pernah.
  Future<DateTime?> lastSyncAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastSyncAtKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> start() async {
    final outlet = await _outletService.loadOutlet();
    if (!outlet.syncEnabled) return;
    _scheduleNext(outlet.syncInterval);
    unawaited(syncCycle()); // sync awal saat startup
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> restart() async {
    stop();
    await start();
  }

  void _scheduleNext(int baseIntervalMinutes) {
    _timer?.cancel();
    final base = baseIntervalMinutes < 1 ? 5 : baseIntervalMinutes;
    // Exponential backoff saat gagal beruntun (cap 30 menit)
    var minutes = base;
    if (_consecutiveFails > 0) {
      minutes = base * (1 << _consecutiveFails);
      if (minutes > _maxBackoffMinutes) minutes = _maxBackoffMinutes;
    }
    _timer = Timer(Duration(minutes: minutes), () async {
      await syncCycle();
      final outlet = await _outletService.loadOutlet();
      if (outlet.syncEnabled) _scheduleNext(outlet.syncInterval);
    });
  }

  /// Satu siklus penuh seperti sync_service.go: push → pull → tax.
  /// Dijaga agar tidak berjalan ganda (auto timer + tap manual) dan mengekspos
  /// [syncing] ke UI untuk animasi tombol sinkron.
  Future<void> syncCycle() async {
    if (syncing.value) return; // siklus lain sedang jalan → jangan dobel
    syncing.value = true;
    try {
      await _runCycle();
    } finally {
      syncing.value = false;
    }
  }

  Future<void> _runCycle() async {
    // Auto-discover outlet ID jika belum ada
    final outlet = await _outletService.loadOutlet();
    if (outlet.cloudOutletId.isEmpty && outlet.cloudApiKey.isNotEmpty) {
      await testConnection();
    }

    // Reset item yang sebelumnya gagal (exhausted retries) agar dicoba ulang.
    // Item yang gagal karena jaringan harus bisa retry di siklus berikutnya.
    await _queue.retryFailed();

    // Backfill order aktif yang belum masuk antrian (mis. dibuat sebelum fitur
    // sync order, atau yang terlewat) agar semua ikut terkirim.
    await _orderRepo.enqueueUnsyncedActiveOrders();

    // Backfill PENYELAMAT: pembayaran LUNAS yang kehilangan entri outbox
    // (mis. app tertutup tepat setelah commit pembayaran, sebelum enqueue).
    // Tanpa ini order tsb selamanya tampil belum lunas di cloud — backfill
    // order aktif di atas sengaja melewati order 'paid'.
    await _orderRepo.enqueueUnsyncedPaidTransactions();

    // Daftar biaya tambahan (pajak, service charge) dikirim ulang tiap siklus.
    // Cloud memakainya untuk menghitung total pesanan online persis seperti
    // kasir; kalau sampai melenceng, tamu membayar nominal QRIS yang berbeda
    // dari tagihannya. Barisnya cuma segelintir dan enqueue menimpa entri
    // pending untuk entity yang sama, jadi ini murah dan menutup celah drift.
    await _orderRepo.enqueueAllAdditionalCharges();

    final pushed = await pushNow();
    // Pull hanya jika push tidak gagal jaringan (hindari spam saat offline)
    if ((pushed['failed'] ?? 0) == 0 || (pushed['sent'] ?? 0) == 0) {
      await pullUpdates();
      await syncTaxFromCloud();
      // Tarik pesanan mandiri tamu (QR dine-in) menjadi order meja. Menelan
      // seluruh kegagalannya sendiri — pesanan online tidak boleh sampai
      // menggagalkan sinkronisasi data kasir.
      await OnlineOrderService.instance.pullPendingOrders();
    }

    // Catat waktu siklus selesai agar bisa dipantau di UI
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncAtKey, DateTime.now().toIso8601String());

    // Heartbeat: snapshot kondisi tablet/printer/koneksi (tidak di-retry).
    await _sendHeartbeat();
  }

  /// Kirim telemetri perangkat ke cloud (snapshot terkini). Kegagalan tidak
  /// memengaruhi sync data — hanya pemantauan.
  Future<void> _sendHeartbeat() async {
    try {
      final outlet = await _outletService.loadOutlet();
      if (!_isConfigured(outlet)) return;
      final stats = await _queue.stats();
      final pending = (stats['pending'] ?? 0) + (stats['failed'] ?? 0);
      final payload = await DeviceHeartbeatService.instance.build(
        online: _consecutiveFails == 0,
        pendingSync: pending,
        lastSyncAt: await lastSyncAt(),
      );
      final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
      final url =
          '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/heartbeat';
      await _dio.post(
        url,
        data: payload,
        options: Options(headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${outlet.cloudApiKey}',
          'X-Outlet-ID': outlet.cloudOutletId,
          'X-Outlet-Code': outlet.code,
        }),
      );
    } catch (e) {
      debugPrint('CloudSync heartbeat error: $e');
    }
  }

  // ── Push ──────────────────────────────────────────────────────────────────

  /// Kirim semua item pending. Aman dipanggil manual (tombol "Sync Sekarang").
  /// Mengembalikan ringkasan {sent, success, failed}.
  Future<Map<String, int>> pushNow() async {
    if (_pushBusy) return {'sent': 0, 'success': 0, 'failed': 0};
    _pushBusy = true;
    try {
      final outlet = await _outletService.loadOutlet();
      if (!_isConfigured(outlet)) {
        return {'sent': 0, 'success': 0, 'failed': 0, 'unconfigured': 1};
      }

      final rows = await _queue.pending(limit: 200);
      if (rows.isEmpty) {
        _consecutiveFails = 0;
        return {'sent': 0, 'success': 0, 'failed': 0};
      }

      final items = rows.map((r) {
        Map<String, dynamic> data;
        try {
          data = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        } catch (_) {
          data = {};
        }
        return {
          'entity_type': r['entity_type'],
          'operation': r['operation'],
          'data': data,
        };
      }).toList();

      final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
      final url =
          '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/sync/batch';

      final body = {
        'outlet_id': outlet.cloudOutletId,
        'outlet_code': outlet.code,
        'sync_timestamp': DateTime.now().toUtc().toIso8601String(),
        'items': items,
      };

      try {
        final resp = await _dio.post(
          url,
          data: body,
          options: Options(headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${outlet.cloudApiKey}',
            'X-Outlet-ID': outlet.cloudOutletId,
            'X-Outlet-Code': outlet.code,
          }),
        );

        // PENANDAAN BERBASIS KONFIRMASI PER-ITEM (whitelist).
        //
        // Kontrak cloud: `success:true` di level atas HARDCODED — cloud selalu
        // balas 200 + success:true asalkan request valid, MESKI ada item yang
        // gagal tersimpan. Keandalan sebenarnya ada di `data.results[]`:
        // tiap item sukses punya {local_id, status:"success"}.
        //
        // Maka: tandai "synced" HANYA untuk local_id yang cloud konfirmasi
        // status=="success". Item ber-status "failed" ATAU yang TIDAK muncul di
        // results[] harus TETAP di outbox & di-retry (jangan pernah andalkan
        // success:true level atas → kalau tidak, transaksi gagal tersimpan di
        // cloud akan ditandai terkirim di tablet dan HILANG permanen).
        final root = resp.data;
        final dataPart = root is Map ? root['data'] : null;
        final results = dataPart is Map ? dataPart['results'] : null;

        // Tanpa results[] yang valid, respons TIDAK bisa dipercaya (success:true
        // level atas bukan sinyal). Perlakukan seluruh batch sebagai gagal →
        // tetap pending untuk dicoba lagi.
        if (results is! List) {
          _consecutiveFails++;
          for (final r in rows) {
            await _queue.markFailed(
              r['id'] as int,
              'Respons cloud tanpa data.results[] — tak bisa konfirmasi per-item',
              r['retry_count'] as int,
              r['max_retries'] as int,
            );
          }
          return {'sent': rows.length, 'success': 0, 'failed': rows.length};
        }

        final syncedIds = <String>{};
        for (final it in results) {
          if (it is Map && it['status'] == 'success') {
            final lid = it['local_id'];
            if (lid is String) syncedIds.add(lid);
          }
        }

        var success = 0;
        var failed = 0;
        for (final r in rows) {
          final id = r['id'] as int;
          final entityId = r['entity_id'] as String;
          final retry = r['retry_count'] as int;
          final maxRetries = r['max_retries'] as int;
          if (syncedIds.contains(entityId)) {
            await _queue.markSuccess(id);
            success++;
          } else {
            // status "failed" atau tak dikonfirmasi cloud → tetap di outbox.
            await _queue.markFailed(
                id, 'Belum dikonfirmasi cloud (results status ≠ success)',
                retry, maxRetries);
            failed++;
          }
        }
        _consecutiveFails = failed > 0 ? _consecutiveFails + 1 : 0;
        return {'sent': rows.length, 'success': success, 'failed': failed};
      } on DioException catch (e) {
        // Gagal jaringan → biarkan tetap pending, naikkan backoff
        _consecutiveFails++;
        for (final r in rows) {
          await _queue.markFailed(
            r['id'] as int,
            _errMessage(e),
            r['retry_count'] as int,
            r['max_retries'] as int,
          );
        }
        return {'sent': rows.length, 'success': 0, 'failed': rows.length};
      }
    } catch (e) {
      debugPrint('CloudSync pushNow error: $e');
      return {'sent': 0, 'success': 0, 'failed': 0};
    } finally {
      _pushBusy = false;
    }
  }

  // ── Pull (master data dari cloud) ───────────────────────────────────────────

  /// Tarik perubahan produk & kategori dari cloud sejak sync terakhir.
  /// Cloud = sumber kebenaran master data (cloud_wins).
  Future<void> pullUpdates() async {
    final outlet = await _outletService.loadOutlet();
    if (!_isConfigured(outlet) || outlet.cloudOutletId.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final since = prefs.getString(_lastSyncKey) ??
        DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 30))
            .toIso8601String();

    final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
    final url = '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/updates';

    try {
      final resp = await _dio.get(
        url,
        queryParameters: {'since': since},
        options: Options(headers: _authHeaders(outlet)),
      );

      final data = resp.data is Map ? resp.data['data'] : null;
      if (data is! Map) return;

      final categories = _asList(data['categories']);
      final products = _asList(data['products']);
      final deleted = _asList(data['deleted']);

      final db = await _db.database;
      // Kategori dulu (produk punya FK ke kategori)
      for (final c in categories) {
        if (c is Map) await _applyCategory(db, c);
      }
      for (final p in products) {
        if (p is Map) await _applyProduct(db, p);
      }
      for (final d in deleted) {
        if (d is Map) await _applyDeletion(db, d);
      }

      final checkpoint = data['sync_checkpoint'] as String?;
      await prefs.setString(
        _lastSyncKey,
        checkpoint ?? DateTime.now().toUtc().toIso8601String(),
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data?.toString() ?? '';
      if (status == 403 && body.contains('does not match')) {
        // Outlet ID tidak cocok dengan API Key → hapus dan discover ulang
        final prefs2 = await SharedPreferences.getInstance();
        await prefs2.remove('outlet_cloud_outlet_id');
        await testConnection();
      } else {
        debugPrint('pullUpdates error: ${_errMessage(e)}');
      }
    }
  }

  /// Tarik SEMUA kategori & produk dari cloud (bukan incremental).
  /// Dipakai saat pertama kali terhubung agar seluruh master data masuk,
  /// termasuk yang dibuat sebelum jendela `since` pada pullUpdates.
  /// Mengembalikan jumlah {categories, products} yang diproses.
  Future<Map<String, int>> fullPullFromCloud() async {
    final outlet = await _outletService.loadOutlet();
    if (!_isConfigured(outlet) || outlet.cloudOutletId.isEmpty) {
      return {'categories': 0, 'products': 0};
    }

    final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
    final db = await _db.database;
    var catCount = 0;
    var prodCount = 0;
    final cloudCatIds = <String>{};
    final cloudProdIds = <String>{};
    var fetchOk = false;
    int? cloudTotal; // total produk menurut cloud (bila dikirim)

    try {
      // 1. Semua kategori (kategori dulu karena produk punya FK)
      final catResp = await _dio.get(
        '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/categories',
        options: Options(headers: _authHeaders(outlet)),
      );
      final cats = catResp.data is Map ? catResp.data['data'] : null;
      if (cats is List) {
        for (final c in cats) {
          if (c is Map) {
            _collectCloudIds(c, cloudCatIds);
            await _applyCategory(db, c);
            catCount++;
          }
        }
      }

      // 2. Semua produk (paginasi). PENTING: server bisa membatasi ukuran
      // halaman (mis. cap 100 walau diminta 200). Jangan berhenti hanya karena
      // halaman "kurang penuh" — dulu itu membuat produk ke-101+ tak terambil
      // lalu ikut ter-soft-delete di langkah replace. Andalkan total bila ada;
      // selain itu teruskan sampai halaman kosong.
      var page = 1;
      const limit = 200;
      String? prevFirstId;
      while (true) {
        final prodResp = await _dio.get(
          '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/products',
          queryParameters: {'page': page, 'limit': limit},
          options: Options(headers: _authHeaders(outlet)),
        );
        final body = prodResp.data is Map ? prodResp.data : null;
        final prods = body?['data'];
        if (prods is! List || prods.isEmpty) break;

        // Pengaman: server mengabaikan parameter page (mengirim halaman sama
        // terus) → berhenti agar tidak loop tanpa akhir.
        final first = prods.first;
        final firstId = first is Map
            ? '${first['local_id'] ?? first['cloud_id'] ?? first['id']}'
            : null;
        if (firstId != null && firstId == prevFirstId) break;
        prevFirstId = firstId;

        for (final p in prods) {
          if (p is Map) {
            _collectCloudIds(p, cloudProdIds);
            await _applyProduct(db, p);
            prodCount++;
          }
        }

        cloudTotal = (body?['total'] as num?)?.toInt() ?? cloudTotal;
        if (cloudTotal != null && prodCount >= cloudTotal) break;
        if (page >= 500) break; // pengaman loop (500 hal × 200 = 100rb produk)
        page++;
      }

      fetchOk = true;

      // 3. Update checkpoint agar pull incremental berikutnya tidak ambil ulang semua
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lastSyncKey,
        DateTime.now().toUtc().toIso8601String(),
      );
    } on DioException catch (e) {
      debugPrint('fullPullFromCloud error: ${_errMessage(e)}');
    }

    // 4. Replace: soft-delete data lokal yang TIDAK ada di cloud (cloud = sumber kebenaran).
    // Pengaman:
    //  - Hanya bila fetch sukses (jangan hapus saat jaringan gagal).
    //  - Hanya bila cloud benar-benar mengirim data. Bila cloud balas 0 produk &
    //    0 kategori (kemungkinan salah konfigurasi/outlet kosong), JANGAN wipe
    //    seluruh menu lokal — lebih aman membiarkan data lokal apa adanya.
    //  - Produk: hanya bila daftar dari cloud LENGKAP (prodCount >= total).
    //    Daftar terpotong (server cap/paging aneh) pernah membuat produk
    //    ke-101+ ikut ter-soft-delete di sini.
    final prodListComplete = cloudTotal == null || prodCount >= cloudTotal;
    var delCat = 0;
    var delProd = 0;
    if (fetchOk && (catCount > 0 || prodCount > 0)) {
      delCat = await _softDeleteNotInCloud(db, 'categories', cloudCatIds);
      if (prodListComplete) {
        delProd = await _softDeleteNotInCloud(db, 'products', cloudProdIds);
      } else {
        debugPrint('fullPullFromCloud: daftar produk cloud tidak lengkap '
            '($prodCount/$cloudTotal) — lewati soft-delete produk lokal.');
      }
    }

    debugPrint('fullPullFromCloud: $catCount kategori, $prodCount produk '
        '(hapus lokal: $delCat kategori, $delProd produk)');
    return {
      'categories': catCount,
      'products': prodCount,
      'deleted_categories': delCat,
      'deleted_products': delProd,
    };
  }

  /// Kumpulkan id & local_id dari payload cloud ke dalam set.
  void _collectCloudIds(Map item, Set<String> out) {
    for (final key in ['id', 'local_id', 'cloud_id']) {
      final v = item[key];
      if (v is String && v.isNotEmpty) out.add(v);
    }
  }

  // ── Restore (setelah reset DB / fresh install) ───────────────────────────────

  /// Tarik kembali data operasional yang masih "hidup" dari cloud:
  /// shift terbuka, order belum dibayar, dan pergerakan kas. Dipakai saat
  /// database lokal baru direset agar kasir bisa melanjutkan operasional.
  ///
  /// Endpoint: GET /api/v1/outlets/{outletId}/restore
  /// Respons (data): { open_shifts:[], unpaid_orders:[], cash_movements:[], summary:{} }
  Future<Map<String, dynamic>> restoreFromCloud() async {
    final outlet = await _outletService.loadOutlet();
    if (!_isConfigured(outlet) || outlet.cloudOutletId.isEmpty) {
      return {'shifts': 0, 'orders': 0, 'movements': 0, 'unconfigured': true};
    }

    final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
    final url = '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/restore';

    try {
      final resp = await _dio.get(
        url,
        options: Options(headers: _authHeaders(outlet)),
      );
      final root = resp.data is Map ? resp.data as Map : const {};
      final data = (root['data'] is Map ? root['data'] : root) as Map;

      final db = await _db.database;
      var shifts = 0, orders = 0, movements = 0;

      await db.transaction((txn) async {
        // 1. Shift terbuka
        for (final s in _asList(data['open_shifts'])) {
          if (s is Map) {
            await _restoreShift(txn, s);
            shifts++;
          }
        }
        // 2. Order belum dibayar (+ item)
        for (final o in _asList(data['unpaid_orders'])) {
          if (o is Map) {
            await _restoreUnpaidOrder(txn, o);
            orders++;
          }
        }
        // 3. Pergerakan kas
        for (final m in _asList(data['cash_movements'])) {
          if (m is Map) {
            await _restoreCashMovement(txn, m);
            movements++;
          }
        }
      });

      debugPrint('restoreFromCloud: $shifts shift, $orders order, '
          '$movements kas');
      return {'shifts': shifts, 'orders': orders, 'movements': movements};
    } on DioException catch (e) {
      debugPrint('restoreFromCloud error: ${_errMessage(e)}');
      return {
        'shifts': 0,
        'orders': 0,
        'movements': 0,
        'error': _errMessage(e),
      };
    }
  }

  /// Konversi timestamp cloud (UTC, akhiran Z) ke ISO waktu LOKAL tanpa zona —
  /// konsisten dengan seluruh timestamp lokal (created_at pembayaran dll).
  /// Tanpa ini, batas shift/laporan bergeser sebesar offset zona (mis. +7 WIB)
  /// karena perbandingan string mencampur dua zona.
  String _toLocalIso(String raw, String fallback) {
    final t = DateTime.tryParse(raw);
    if (t == null) return fallback;
    return t.toLocal().toIso8601String();
  }

  Future<void> _restoreShift(dynamic txn, Map s) async {
    final id = _pick(s, ['id', 'local_id']);
    if (id.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    await txn.insert(
      'cashier_shifts',
      {
        'id': id,
        'opened_by': _pick(s, ['opened_by', 'opened_by_name'], 'Kasir'),
        'opened_at': _toLocalIso(_pick(s, ['opened_at'], now), now),
        'opening_cash': _numOf(s, ['opening_cash']),
        'status': 'open',
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _restoreUnpaidOrder(dynamic txn, Map o) async {
    final id = _pick(o, ['id', 'local_id']);
    if (id.isEmpty) return;
    final items = _asList(o['items']);
    final pay = o['payment_info'] is Map ? o['payment_info'] as Map : const {};
    final now = DateTime.now().toIso8601String();

    await txn.insert(
      'orders',
      {
        'id': id,
        'table_number': _pick(o, ['table_number'], '-'),
        'customer_name': _pickOrNull(o, ['customer_name']),
        'pax': _intOf(o, ['pax'], 1).clamp(1, 99999),
        'basket_size': items.length,
        'total_amount': _numOf(o, ['total_amount']),
        'paid_amount': _numOf(pay, ['paid_amount']),
        'order_status':
            _oneOf(_pick(o, ['order_status', 'status']), const ['cooking', 'ready', 'served'], 'cooking'),
        'payment_status': _oneOf(_pick(pay, ['payment_status']),
            const ['unpaid', 'partial', 'paid'], 'unpaid'),
        'created_at': _toLocalIso(_pick(o, ['created_at'], now), now),
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await txn.delete('order_items', where: 'order_id = ?', whereArgs: [id]);
    for (final it in items) {
      if (it is! Map) continue;
      await txn.insert('order_items', {
        'id': Ulid.generate(),
        'order_id': id,
        'product_name': _pick(it, ['product_name', 'name'], '-'),
        'qty': _intOf(it, ['qty', 'quantity'], 1).clamp(1, 99999),
        'price': _numOf(it, ['price']),
        'destination':
            _oneOf(_pick(it, ['destination']), const ['kitchen', 'bar'], 'kitchen'),
        'item_status': _oneOf(_pick(it, ['status', 'item_status']),
            const ['pending', 'cooking', 'ready', 'served'], 'pending'),
        'notes': _pick(it, ['notes']),
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  Future<void> _restoreCashMovement(dynamic txn, Map m) async {
    final id = _pick(m, ['id', 'local_id']);
    if (id.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    await txn.insert(
      'cashier_cash_movements',
      {
        'id': id,
        'shift_id': _pick(m, ['shift_id']),
        'movement_type':
            _oneOf(_pick(m, ['movement_type', 'type']), const ['in', 'out'], 'in'),
        'amount': _numOf(m, ['amount']),
        'counterpart_name':
            _pick(m, ['counterpart_name', 'name'], '-'),
        'note': _pick(m, ['note']),
        'created_at': _toLocalIso(_pick(m, ['created_at'], now), now),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Helper parsing toleran (cloud bisa pakai beberapa nama field).
  String _pick(Map m, List<String> keys, [String fallback = '']) {
    for (final k in keys) {
      final v = m[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return fallback;
  }

  String? _pickOrNull(Map m, List<String> keys) {
    final v = _pick(m, keys);
    return v.isEmpty ? null : v;
  }

  double _numOf(Map m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is num) return v.toDouble();
      if (v is String) {
        final p = double.tryParse(v);
        if (p != null) return p;
      }
    }
    return 0;
  }

  int _intOf(Map m, List<String> keys, int fallback) {
    for (final k in keys) {
      final v = m[k];
      if (v is num) return v.toInt();
      if (v is String) {
        final p = int.tryParse(v);
        if (p != null) return p;
      }
    }
    return fallback;
  }

  String _oneOf(String value, List<String> allowed, String fallback) =>
      allowed.contains(value) ? value : fallback;

  /// Ambil List dengan aman. Bila cloud mengirim JSON-string (mis. "[...]"),
  /// coba decode; selain itu kembalikan list kosong.
  List _asList(dynamic v) {
    if (v is List) return v;
    if (v is String && v.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(v);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    return const [];
  }

  /// Soft-delete baris aktif di [table] yang id-nya tidak ada di [cloudIds].
  /// Mengembalikan jumlah baris yang dihapus.
  Future<int> _softDeleteNotInCloud(
      dynamic db, String table, Set<String> cloudIds) async {
    final rows = await db.query(table,
        columns: ['id'], where: 'is_deleted = 0');
    final now = DateTime.now().toIso8601String();
    var deleted = 0;
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null || cloudIds.contains(id)) continue;
      await db.update(
        table,
        {'is_deleted': 1, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      deleted++;
    }
    return deleted;
  }

  Future<void> _applyCategory(dynamic db, Map cat) async {
    final id = (cat['local_id'] ?? cat['cloud_id'] ?? cat['id']) as String?;
    final name = cat['name'] as String?;
    if (id == null || name == null) return;
    final now = DateTime.now().toIso8601String();
    // Buang kategori lokal dengan nama sama tapi id beda (mis. data seed) agar
    // tidak melanggar UNIQUE(name). FK products.category_id ON DELETE SET NULL.
    await db.delete('categories',
        where: 'name = ? AND id != ?', whereArgs: [name, id]);
    await db.rawInsert(
      '''
      INSERT INTO categories (id, name, is_deleted, created_at, updated_at)
      VALUES (?, ?, 0, ?, ?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name, is_deleted=0, updated_at=excluded.updated_at
      ''',
      [id, name, now, now],
    );
  }

  Future<void> _applyProduct(dynamic db, Map prod) async {
    final id = (prod['local_id'] ?? prod['cloud_id'] ?? prod['id']) as String?;
    final name = prod['name'] as String?;
    if (id == null || name == null) return;
    final price = (prod['price'] as num?)?.toDouble() ?? 0;
    final stock = (prod['stock'] as num?)?.toInt() ?? 0;
    final code = prod['code'] as String?;
    final desc = prod['description'] as String?;
    var categoryId = prod['category_id'] as String?;
    if (categoryId != null && categoryId.isEmpty) categoryId = null;
    final categoryName = prod['category_name'] as String?;
    final now = DateTime.now().toIso8601String();

    // Pastikan kategori ada agar FK terpenuhi & produk tidak jadi "tanpa
    // kategori". Jika kategori belum ada tapi cloud kirim nama, buat dari nama.
    if (categoryId != null) {
      final existing = await db.query('categories',
          columns: ['id'], where: 'id = ?', whereArgs: [categoryId], limit: 1);
      if (existing.isEmpty) {
        if (categoryName != null && categoryName.isNotEmpty) {
          // Buang kategori bernama sama dengan id beda agar tidak melanggar UNIQUE(name)
          await db.delete('categories',
              where: 'name = ? AND id != ?',
              whereArgs: [categoryName, categoryId]);
          await db.rawInsert(
            '''
            INSERT INTO categories (id, name, is_deleted, created_at, updated_at)
            VALUES (?, ?, 0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, is_deleted=0
            ''',
            [categoryId, categoryName, now, now],
          );
        } else {
          categoryId = null; // tidak ada nama → simpan tanpa kategori
        }
      }
    }

    // Kosongkan code milik produk lain (id beda) yang bentrok agar tidak
    // melanggar UNIQUE(code) saat insert produk dari cloud.
    if (code != null && code.isNotEmpty) {
      await db.update('products', {'code': null},
          where: 'code = ? AND id != ?', whereArgs: [code, id]);
    }

    Future<void> upsert(String? catId) => db.rawInsert(
          '''
          INSERT INTO products (id, name, code, description, price, stock, category_id, is_deleted, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, code=excluded.code, description=excluded.description,
            price=excluded.price, stock=excluded.stock, category_id=excluded.category_id,
            is_deleted=0, updated_at=excluded.updated_at
          ''',
          [id, name, code, desc, price, stock, catId, now, now],
        );

    try {
      await upsert(categoryId);
    } catch (_) {
      await upsert(null); // pengaman terakhir bila FK tetap gagal
    }
  }

  Future<void> _applyDeletion(dynamic db, Map del) async {
    final type = del['entity_type'] as String?;
    final id = (del['local_id'] ?? del['cloud_id']) as String?;
    if (id == null) return;
    final table = type == 'category' ? 'categories' : 'products';
    await db.update(
      table,
      {'is_deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── Pajak dari cloud ────────────────────────────────────────────────────────

  /// Tarik pengaturan pajak outlet dari cloud, lalu buat/update charge pajak
  /// lokal (additional_charges). Mirror syncTaxFromCloud di app-pos Go.
  Future<void> syncTaxFromCloud() async {
    final outlet = await _outletService.loadOutlet();
    if (!_isConfigured(outlet) || outlet.cloudOutletId.isEmpty) return;

    final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
    final url = '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/info';

    try {
      final resp = await _dio.get(
        url,
        options: Options(headers: _authHeaders(outlet)),
      );
      final data = resp.data is Map ? resp.data['data'] : null;
      if (data is! Map) return;

      final taxEnabled = data['tax_enabled'] == true;
      final taxRate = (data['tax_rate'] as num?)?.toDouble() ?? 0;
      var taxName = data['tax_name'] as String?;
      if (taxName == null || taxName.isEmpty) taxName = 'Pajak Restoran (PB1)';

      final db = await _db.database;
      final now = DateTime.now().toIso8601String();

      // Cari charge pajak yang sudah ada (percentage & nama diawali "pajak")
      final existing = await db.query(
        'additional_charges',
        where:
            "charge_type = 'percentage' AND (name = ? OR LOWER(name) LIKE 'pajak%')",
        whereArgs: [taxName],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        await db.update(
          'additional_charges',
          {
            'name': taxName,
            'value': taxRate,
            'is_active': taxEnabled ? 1 : 0,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
      } else {
        await db.insert('additional_charges', {
          'name': taxName,
          'charge_type': 'percentage',
          'value': taxRate,
          'is_active': taxEnabled ? 1 : 0,
          'created_at': now,
          'updated_at': now,
        });
      }
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data?.toString() ?? '';
      if (status == 403 && body.contains('does not match')) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('outlet_cloud_outlet_id');
        await testConnection();
      } else {
        debugPrint('syncTaxFromCloud error: ${_errMessage(e)}');
      }
    }
  }

  // ── Test Connection ──────────────────────────────────────────────────────────

  /// Ping cloud dan auto-discover outlet info menggunakan API Key.
  /// Menyimpan outlet ID secara otomatis jika berhasil.
  Future<Map<String, dynamic>> testConnection() async {
    final outlet = await _outletService.loadOutlet();
    if (outlet.cloudApiKey.isEmpty) {
      return {'success': false, 'error': 'API Key belum diisi'};
    }

    final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);

    try {
      // Ping dulu untuk cek konektivitas
      await _dio.get(
        '$baseUrl/api/v1/ping',
        options: Options(
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
    } on DioException catch (e) {
      return {'success': false, 'error': 'Server tidak terjangkau: ${_errMessage(e)}'};
    }

    try {
      // Auto-discover outlet via API Key
      final resp = await _dio.get(
        '$baseUrl/api/v1/outlet/me',
        options: Options(headers: {'Authorization': 'Bearer ${outlet.cloudApiKey}'}),
      );

      final respData = resp.data is Map ? resp.data : null;
      final data = respData?['data'];

      if (data is Map && (data['id'] ?? '').toString().isNotEmpty) {
        final outletId = data['id'].toString();
        final outletName = data['name']?.toString() ?? '';
        final outletCode = data['code']?.toString() ?? '';
        final outletAddress = data['address']?.toString() ?? '';
        // Nomor HP outlet — dukung beberapa nama field yang mungkin dipakai cloud.
        final outletPhone = (data['phone'] ??
                data['phone_number'] ??
                data['hp'] ??
                data['telp'])
            ?.toString() ??
            '';

        // Simpan outlet ID ke shared preferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('outlet_cloud_outlet_id', outletId);

        // Isi profil outlet dari cloud (nama/kode/alamat/telepon) — cloud = sumber kebenaran
        await _outletService.saveOutlet(outlet.copyWith(
          name: outletName.isNotEmpty ? outletName : outlet.name,
          code: outletCode.isNotEmpty ? outletCode : outlet.code,
          address: outletAddress.isNotEmpty ? outletAddress : outlet.address,
          phone: outletPhone.isNotEmpty ? outletPhone : outlet.phone,
        ));

        // Tarik semua master data (produk & kategori) dari cloud
        final pulled = await fullPullFromCloud();

        return {
          'success': true,
          'outlet_id': outletId,
          'outlet_name': outletName,
          'outlet_code': outletCode,
          'outlet_address': outletAddress,
          'categories': pulled['categories'] ?? 0,
          'products': pulled['products'] ?? 0,
        };
      }

      return {'success': false, 'error': 'API Key tidak valid atau outlet tidak ditemukan'};
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        return {'success': false, 'error': 'API Key tidak valid'};
      }
      return {'success': false, 'error': _errMessage(e)};
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Map<String, String> _authHeaders(OutletInfo o) => {
        'Authorization': 'Bearer ${o.cloudApiKey}',
        'X-Outlet-ID': o.cloudOutletId,
        'X-Outlet-Code': o.code,
      };

  bool _isConfigured(OutletInfo o) =>
      o.cloudApiUrl.isNotEmpty &&
      o.cloudApiKey.isNotEmpty &&
      o.cloudOutletId.isNotEmpty;

  String _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/api/v1')) {
      url = url.substring(0, url.length - '/api/v1'.length);
    }
    return url;
  }

  String _errMessage(DioException e) {
    if (e.response != null) {
      return 'HTTP ${e.response?.statusCode}: ${e.response?.data}';
    }
    return e.message ?? 'Network error';
  }
}
