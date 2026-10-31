import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_sync_service.dart';
import 'local_api_server.dart';
import 'print_queue_service.dart';

/// Peran perangkat. Menentukan apakah device jadi server (Main POS) atau
/// hanya client (Station/tablet pelayan).
enum DeviceRole { mainPos, station }

class DeviceRoleService {
  static final DeviceRoleService instance = DeviceRoleService._();
  DeviceRoleService._();

  static const _key = 'device_role';

  DeviceRole? _cached;

  /// Peran terakhir yang dibaca/di-set — versi SINKRON untuk pemeriksaan cepat
  /// di widget yang tak bisa menunggu Future (mis. guard idle di app shell).
  /// Terisi saat RootGate memuat peran di awal aplikasi.
  DeviceRole? get cachedRole => _cached;

  /// Null = belum dipilih (tampilkan pemilih peran).
  Future<DeviceRole?> getRole() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == 'main_pos') return _cached = DeviceRole.mainPos;
    if (raw == 'station') return _cached = DeviceRole.station;
    return _cached = null;
  }

  Future<void> setRole(DeviceRole role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      role == DeviceRole.mainPos ? 'main_pos' : 'station',
    );
    _cached = role;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    _cached = null;
  }

  // ── Service startup (hanya untuk Main POS) ───────────────────────────────────

  bool _mainPosStarted = false;
  Timer? _startRetryTimer;

  /// Nyalakan server API 7070 + print queue + cloud sync. Idempoten.
  /// Tidak dipanggil di mode station (hemat resource, tak buka port).
  /// Flag sukses HANYA diset setelah semua service benar-benar jalan — bila
  /// gagal (mis. port 7070 masih dipakai), dicoba ulang otomatis tiap 10 detik
  /// agar station tidak kehilangan server secara diam-diam.
  Future<void> startMainPosServices() async {
    if (_mainPosStarted) return;
    try {
      await LocalApiServer.instance.start();
      PrintQueueService.instance.start();
      await CloudSyncService.instance.start();
      _mainPosStarted = true;
      _startRetryTimer?.cancel();
      _startRetryTimer = null;
    } catch (e) {
      debugPrint('startMainPosServices gagal (coba lagi 10 dtk): $e');
      _startRetryTimer?.cancel();
      _startRetryTimer =
          Timer(const Duration(seconds: 10), startMainPosServices);
    }
  }
}
