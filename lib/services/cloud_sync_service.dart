import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/database.dart';
import '../repositories/order_repository.dart';
import '../repositories/cashier_repository.dart';
import '../repositories/sync_queue_repository.dart';
import 'device_heartbeat_service.dart';
import 'cloud_restore_writer.dart';
import 'online_order_service.dart';
import 'sync_acknowledgements.dart';
import 'outlet_service.dart';
import 'product_photo_cache.dart';
import 'app_events.dart';

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

  // New photo-capable clients must replay old products once after upgrading.
  static const _lastSyncKey = 'cloud_last_pull_at:photos-v1';
  Future<void>? _masterPull;
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
    await CashierRepository().enqueueUnsyncedCashMovements();

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
      final url = '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/heartbeat';
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
      final url = '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/sync/batch';

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
        // tiap item sukses punya {entity_type, local_id, status:"success"};
        // event audit juga memiliki event_id agar dua aksi pada item yang
        // sama tidak saling mengonfirmasi.
        //
        // Maka: tandai "synced" HANYA untuk satu entri yang dapat dicocokkan
        // tanpa ambigu dengan status=="success". Item gagal/tidak muncul di
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

        final confirmedIds = confirmedSyncQueueIds(rows, results);

        var success = 0;
        var failed = 0;
        for (final r in rows) {
          final id = r['id'] as int;
          final retry = r['retry_count'] as int;
          final maxRetries = r['max_retries'] as int;
          if (confirmedIds.contains(id)) {
            await _queue.markSuccess(id);
            success++;
          } else {
            // status "failed" atau tak dikonfirmasi cloud → tetap di outbox.
            await _queue.markFailed(
                id,
                'Belum dikonfirmasi cloud (results status ≠ success)',
                retry,
                maxRetries);
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
  String _pullCheckpointKey(OutletInfo outlet) =>
      '$_lastSyncKey:${_normalizeBaseUrl(outlet.cloudApiUrl)}:${outlet.cloudOutletId}';

  Future<T> _serializeMasterPull<T>(Future<T> Function() action) async {
    final previous = _masterPull;
    final done = Completer<void>();
    _masterPull = done.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      done.complete();
      if (identical(_masterPull, done.future)) _masterPull = null;
    }
  }

  // Missing or malformed collections are errors, not authoritative empty lists.
  List<Map> _masterRows(dynamic value) {
    if (value is String) value = jsonDecode(value);
    if (value is! List || value.any((row) => row is! Map)) {
      throw const FormatException('Daftar master cloud tidak lengkap');
    }
    return value.cast<Map>();
  }

  String _masterIdentity(Map row) {
    for (final key in ['local_id', 'cloud_id', 'id']) {
      final value = row[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    throw const FormatException('Identitas master cloud tidak tersedia');
  }

  void _validateMaster(Map row, {required bool product}) {
    _masterIdentity(row);
    if (row['name'] is! String || (row['name'] as String).trim().isEmpty) {
      throw const FormatException('Nama master cloud tidak tersedia');
    }
    if (product) {
      final price = row['price'];
      if (price is! num || !price.isFinite || price < 0) {
        throw const FormatException('Harga produk cloud tidak valid');
      }
    }
  }

  Future<void> pullUpdates() async {
    try {
      await _serializeMasterPull(() async {
        final outlet = await _outletService.loadOutlet();
        if (!_isConfigured(outlet)) return;
        final prefs = await SharedPreferences.getInstance();
        final key = _pullCheckpointKey(outlet);
        // A cursor from another outlet, or an old device-clock cursor, must
        // never skip this outlet's catalog. Replay once on migration.
        final since = prefs.getString(key) ?? '1970-01-01T00:00:00.000Z';
        final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
        final resp = await _dio.get(
          '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/updates',
          queryParameters: {'since': since},
          options: Options(headers: _authHeaders(outlet)),
        );
        final root = resp.data;
        final data = root is Map ? root['data'] : null;
        if (root is! Map || root['success'] == false || data is! Map) {
          throw const FormatException('Respons master cloud tidak valid');
        }
        final categories = _masterRows(data['categories']);
        final products = _masterRows(data['products']);
        final deleted = _masterRows(data['deleted']);
        for (final row in categories) {
          _validateMaster(row, product: false);
        }
        for (final row in products) {
          _validateMaster(row, product: true);
        }
        for (final row in deleted) {
          _masterIdentity(row);
          if (!['category', 'product'].contains(row['entity_type'])) {
            throw const FormatException(
                'Jenis penghapusan master tidak dikenal');
          }
        }
        final checkpoint = data['sync_checkpoint'];
        if (checkpoint is! String || DateTime.tryParse(checkpoint) == null) {
          throw const FormatException('Checkpoint cloud tidak valid');
        }
        final db = await _db.database;
        await db.transaction((txn) async {
          for (final row in categories) {
            await _applyCategory(txn, row);
          }
          for (final row in products) {
            await _applyProduct(txn, row, baseUrl);
          }
          for (final row in deleted) {
            await _applyDeletion(txn, row);
          }
        });
        if (categories.isNotEmpty ||
            products.isNotEmpty ||
            deleted.isNotEmpty) {
          notifyDataChanged('catalog_updated');
        }
        _prefetchProductPhotos(db);
        // Saving only after commit makes a crash replay safe. Never substitute
        // a tablet timestamp for the server's cursor.
        await prefs.setString(key, checkpoint);
      });
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data?.toString() ?? '';
      if (status == 403 && body.contains('does not match')) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('outlet_cloud_outlet_id');
        // The pull lock has been released before discovery starts a full pull.
        await testConnection();
      } else {
        debugPrint('pullUpdates error: ${_errMessage(e)}');
      }
    } on FormatException catch (e) {
      debugPrint('pullUpdates: $e');
    }
  }

  /// Fetch and validate the complete catalog before changing local rows.
  /// Interrupted or overlapping pages must not remove menu items or move the
  /// incremental cursor past unseen changes.
  Future<Map<String, int>> fullPullFromCloud() =>
      _serializeMasterPull(() async {
        final outlet = await _outletService.loadOutlet();
        if (!_isConfigured(outlet)) return {'categories': 0, 'products': 0};
        final baseUrl = _normalizeBaseUrl(outlet.cloudApiUrl);
        try {
          final catResp = await _dio.get(
            '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/categories',
            options: Options(headers: _authHeaders(outlet)),
          );
          if (catResp.data is! Map || catResp.data['success'] == false) {
            throw const FormatException('Respons kategori cloud tidak valid');
          }
          final categories = _masterRows(catResp.data['data']);
          final categoryIds = <String>{};
          for (final row in categories) {
            _validateMaster(row, product: false);
            if (!categoryIds.add(_masterIdentity(row))) {
              throw const FormatException('Kategori cloud terduplikasi');
            }
          }
          final products = <Map>[];
          final productIds = <String>{};
          int? total;
          var complete = false;
          for (var page = 1; page <= 500; page++) {
            final response = await _dio.get(
              '$baseUrl/api/v1/outlets/${outlet.cloudOutletId}/products',
              queryParameters: {'page': page, 'limit': 200},
              options: Options(headers: _authHeaders(outlet)),
            );
            final body = response.data;
            if (body is! Map || body['success'] == false) {
              throw const FormatException('Respons produk cloud tidak valid');
            }
            final rows = _masterRows(body['data']);
            final declared = body['total'];
            if (declared != null) {
              if (declared is! int ||
                  declared < 0 ||
                  (total != null && total != declared)) {
                throw const FormatException(
                    'Jumlah produk cloud berubah/tidak valid');
              }
              total = declared;
            }
            for (final row in rows) {
              _validateMaster(row, product: true);
              if (!productIds.add(_masterIdentity(row))) {
                throw const FormatException('Halaman produk cloud berulang');
              }
              products.add(row);
            }
            if (total != null && products.length > total) {
              throw const FormatException(
                  'Jumlah produk melebihi respons cloud');
            }
            if (rows.isEmpty || (total != null && products.length == total)) {
              complete = total == null || products.length == total;
              break;
            }
          }
          if (!complete) {
            throw const FormatException('Daftar produk cloud terpotong');
          }

          final db = await _db.database;
          var deletedCategories = 0, deletedProducts = 0;
          await db.transaction((txn) async {
            for (final row in categories) {
              await _applyCategory(txn, row);
            }
            for (final row in products) {
              await _applyProduct(txn, row, baseUrl);
            }
            // Retain the empty-outlet guard: an accidental empty configuration
            // must not erase the entire local menu.
            if (categories.isNotEmpty || products.isNotEmpty) {
              deletedCategories =
                  await _softDeleteNotInCloud(txn, 'categories', categoryIds);
              deletedProducts =
                  await _softDeleteNotInCloud(txn, 'products', productIds);
            }
          });
          if (categories.isNotEmpty ||
              products.isNotEmpty ||
              deletedCategories > 0 ||
              deletedProducts > 0) {
            notifyDataChanged('catalog_updated');
          }
          _prefetchProductPhotos(db);
          // A full pull spans requests, not one server snapshot. Replaying updates
          // from the beginning catches edits committed while pages were fetched,
          // even when the tablet clock is ahead of the server.
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
              _pullCheckpointKey(outlet), '1970-01-01T00:00:00.000Z');
          return {
            'categories': categories.length,
            'products': products.length,
            'deleted_categories': deletedCategories,
            'deleted_products': deletedProducts
          };
        } on DioException catch (e) {
          debugPrint('fullPullFromCloud: ${_errMessage(e)}');
        } on FormatException catch (e) {
          debugPrint('fullPullFromCloud: $e');
        }
        return {
          'categories': 0,
          'products': 0,
          'deleted_categories': 0,
          'deleted_products': 0,
          'incomplete': 1
        };
      });

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
      if (resp.data is! Map) {
        throw const FormatException('Respons pemulihan tidak valid');
      }
      final root = resp.data as Map;
      if (root['success'] == false ||
          (root.containsKey('data') && root['data'] is! Map)) {
        throw const FormatException('Respons pemulihan tidak valid');
      }
      final data = (root['data'] ?? root) as Map;

      final db = await _db.database;
      var shifts = 0, orders = 0, movements = 0, skipped = 0;

      await db.transaction((txn) async {
        final restore = CloudRestoreWriter(txn);
        final cloudShifts = restore.records(data['open_shifts'], 'shift');
        final cloudOrders = restore.records(data['unpaid_orders'], 'order');
        final cloudMovements = restore.records(data['cash_movements'], 'kas');
        await restore.prepareCharges(data['additional_charges']);
        for (final shift in cloudShifts) {
          if (await restore.shift(shift)) {
            shifts++;
          } else {
            skipped++;
          }
        }
        for (final order in cloudOrders) {
          if (await restore.order(order)) {
            orders++;
          } else {
            skipped++;
          }
        }
        for (final movement in cloudMovements) {
          if (await restore.movement(movement)) {
            movements++;
          } else {
            skipped++;
          }
        }
      });

      debugPrint('restoreFromCloud: $shifts shift, $orders order, '
          '$movements kas');
      return {
        'shifts': shifts,
        'orders': orders,
        'movements': movements,
        if (skipped > 0) 'skipped_existing': skipped,
      };
    } on DioException catch (e) {
      debugPrint('restoreFromCloud error: ${_errMessage(e)}');
      return {
        'shifts': 0,
        'orders': 0,
        'movements': 0,
        'error': _errMessage(e),
      };
    } catch (e) {
      // The SQLite transaction has rolled back every inserted entity.
      return {
        'shifts': 0,
        'orders': 0,
        'movements': 0,
        'error': e is FormatException
            ? e.message
            : 'Data pemulihan bertabrakan dengan data lokal. '
                'Periksa data dan sinkronisasi sebelum mencoba kembali.',
      };
    }
  }

  /// Soft-delete baris aktif di [table] yang id-nya tidak ada di [cloudIds].
  /// Mengembalikan jumlah baris yang dihapus.
  Future<int> _softDeleteNotInCloud(
      dynamic db, String table, Set<String> cloudIds) async {
    final rows =
        await db.query(table, columns: ['id'], where: 'is_deleted = 0');
    final now = DateTime.now().toIso8601String();
    var deleted = 0;
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null || cloudIds.contains(id)) continue;
      await db.update(
        table,
        {
          'is_deleted': 1,
          'updated_at': now,
          if (table == 'products') 'photo_url': ''
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      deleted++;
    }
    return deleted;
  }

  Future<void> _applyCategory(dynamic db, Map cat) async {
    final id = _masterIdentity(cat);
    final name = cat['name'] as String?;
    if (name == null) return;
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

  void _prefetchProductPhotos(dynamic db) {
    final cache = ProductPhotoCache.instance;
    unawaited(() async {
      try {
        // Include old URLs so a later successful cycle retries previously
        // offline photos even when no product changed in that cycle.
        final rows = await db.query('products',
            columns: ['photo_url'],
            where: "is_deleted = 0 AND photo_url != ''");
        await cache
            .prefetch(rows.map<String>((row) => row['photo_url'] as String));
      } catch (_) {
        // Disk/network/plugin errors only leave the image placeholder visible.
      }
    }());
  }

  Future<void> _applyProduct(dynamic db, Map prod, String cloudBase) async {
    final id = _masterIdentity(prod);
    final name = prod['name'] as String?;
    if (name == null) return;
    final price = (prod['price'] as num?)?.toDouble() ?? 0;
    final stock = (prod['stock'] as num?)?.toInt() ?? 0;
    final code = prod['code'] as String?;
    final desc = prod['description'] as String?;
    final hasPhoto = prod.containsKey('photo_url');
    final photoUrl = ProductPhotoCache.resolveUrl(prod['photo_url'], cloudBase);
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
          INSERT INTO products (id, name, code, description, price, stock, category_id, is_deleted, created_at, updated_at, photo_url)
          VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, code=excluded.code, description=excluded.description,
            price=excluded.price, stock=excluded.stock, category_id=excluded.category_id,
            is_deleted=0, updated_at=excluded.updated_at,
            photo_url=CASE WHEN ? = 1 THEN excluded.photo_url ELSE products.photo_url END
          ''',
          [
            id,
            name,
            code,
            desc,
            price,
            stock,
            catId,
            now,
            now,
            photoUrl,
            hasPhoto ? 1 : 0
          ],
        );

    try {
      await upsert(categoryId);
    } catch (_) {
      await upsert(null); // pengaman terakhir bila FK tetap gagal
    }
  }

  Future<void> _applyDeletion(dynamic db, Map del) async {
    final type = del['entity_type'] as String?;
    final id = _masterIdentity(del);
    final table = type == 'category' ? 'categories' : 'products';
    await db.update(
      table,
      {
        'is_deleted': 1,
        'updated_at': DateTime.now().toIso8601String(),
        if (table == 'products') 'photo_url': ''
      },
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
      return {
        'success': false,
        'error': 'Server tidak terjangkau: ${_errMessage(e)}'
      };
    }

    try {
      // Auto-discover outlet via API Key
      final resp = await _dio.get(
        '$baseUrl/api/v1/outlet/me',
        options:
            Options(headers: {'Authorization': 'Bearer ${outlet.cloudApiKey}'}),
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
        if (pulled['incomplete'] == 1) {
          return {
            'success': false,
            'error':
                'Terhubung, tetapi daftar menu belum lengkap. Coba sinkronkan kembali.'
          };
        }

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

      return {
        'success': false,
        'error': 'API Key tidak valid atau outlet tidak ditemukan'
      };
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
