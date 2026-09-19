import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'printer_service.dart';

/// Mengumpulkan telemetri perangkat untuk dikirim ke cloud (heartbeat):
/// kondisi tablet (baterai, penyimpanan, CPU, RAM, model, OS, versi app),
/// status tiap printer (online/offline), dan ringkasan konektivitas.
class DeviceHeartbeatService {
  DeviceHeartbeatService._();
  static final DeviceHeartbeatService instance = DeviceHeartbeatService._();

  static const _channel = MethodChannel('pos/device');
  final _printer = PrinterService();

  /// Channel native `pos/device` hanya diimplementasikan di Android. Di platform
  /// lain (iOS/desktop) panggilannya melempar MissingPluginException — sekali
  /// terdeteksi tak tersedia, hentikan agar tidak membanjiri log.
  static bool _nativeAvailable = true;

  /// Bangun payload heartbeat. [online]/[pendingSync]/[lastSyncAt] berasal dari
  /// CloudSyncService (status konektivitas terakhir).
  Future<Map<String, dynamic>> build({
    required bool online,
    required int pendingSync,
    DateTime? lastSyncAt,
  }) async {
    final device = await _deviceInfo();
    final printers = await _printerStatus();
    return {
      'device': device,
      'printers': printers,
      'network': {
        'online': online,
        'pending_sync': pendingSync,
        if (lastSyncAt != null)
          'last_sync_at': lastSyncAt.toUtc().toIso8601String(),
      },
      'reported_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _deviceInfo() async {
    final out = <String, dynamic>{};
    try {
      final pkg = await PackageInfo.fromPlatform();
      out['app_version'] = '${pkg.version}+${pkg.buildNumber}';
    } catch (_) {}
    try {
      final battery = Battery();
      out['battery'] = await battery.batteryLevel; // 0..100
      out['battery_state'] = (await battery.batteryState).name; // charging/full/...
    } catch (_) {}
    // Info model/OS/penyimpanan via MethodChannel native — Android saja.
    // Di iOS/desktop channel tak ada; lewati diam-diam agar log tak dibanjiri.
    if (_nativeAvailable && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final d = await _channel.invokeMethod('deviceInfo');
        if (d is Map) {
          out['model'] = '${d['manufacturer']} ${d['model']}';
          out['os'] =
              'Android ${d['android_release']} (SDK ${d['sdk_int']})';
        }
      } on MissingPluginException {
        _nativeAvailable = false;
      } catch (e) {
        debugPrint('Heartbeat deviceInfo error: $e');
      }
      try {
        final s = await _channel.invokeMethod('storage');
        if (s is Map) {
          final total = (s['total'] as num?)?.toInt() ?? 0;
          final free = (s['free'] as num?)?.toInt() ?? 0;
          const mb = 1024 * 1024;
          out['storage_total_mb'] = (total / mb).round();
          out['storage_free_mb'] = (free / mb).round();
        }
      } on MissingPluginException {
        _nativeAvailable = false;
      } catch (e) {
        debugPrint('Heartbeat storage error: $e');
      }
      // Kondisi CPU & RAM. RAM selalu ada; %CPU/load average best-effort
      // (bisa null bila /proc/stat diblok SELinux) → cukup dilewati.
      try {
        // Timeout: bila native macet (mis. I/O /proc lambat), jangan biarkan
        // heartbeat menggantung — batalkan setelah 5 dtk & lewati CPU/RAM.
        final r = await _channel
            .invokeMethod('resources')
            .timeout(const Duration(seconds: 5));
        if (r is Map) {
          const mb = 1024 * 1024;
          final ramTotal = (r['ram_total'] as num?)?.toInt();
          final ramAvail = (r['ram_avail'] as num?)?.toInt();
          if (ramTotal != null) out['ram_total_mb'] = (ramTotal / mb).round();
          if (ramAvail != null) out['ram_free_mb'] = (ramAvail / mb).round();
          if (ramTotal != null && ramAvail != null && ramTotal > 0) {
            out['ram_used_percent'] =
                (((ramTotal - ramAvail) / ramTotal) * 100).round();
          }
          if (r['ram_low'] is bool) out['ram_low'] = r['ram_low'];
          final cores = (r['cpu_cores'] as num?)?.toInt();
          if (cores != null) out['cpu_cores'] = cores;
          final cpuPct = (r['cpu_used_percent'] as num?)?.toDouble();
          if (cpuPct != null) out['cpu_used_percent'] = cpuPct;
          final cpuSrc = r['cpu_source'] as String?; // 'system' | 'app'
          if (cpuSrc != null) out['cpu_source'] = cpuSrc;
          final l1 = (r['load_1m'] as num?)?.toDouble();
          final l5 = (r['load_5m'] as num?)?.toDouble();
          final l15 = (r['load_15m'] as num?)?.toDouble();
          if (l1 != null) out['cpu_load_1m'] = l1;
          if (l5 != null) out['cpu_load_5m'] = l5;
          if (l15 != null) out['cpu_load_15m'] = l15;
          debugPrint('Heartbeat resources: cpu=${out['cpu_used_percent']}% '
              '(${out['cpu_source']}) cores=${out['cpu_cores']} '
              'ram=${out['ram_used_percent']}%');
        }
      } on MissingPluginException {
        _nativeAvailable = false;
      } catch (e) {
        debugPrint('Heartbeat resources error: $e');
      }
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _printerStatus() async {
    final saved = await _printer.getSavedPrinters();
    if (saved.isEmpty) return const [];

    // Daftar BT yang ter-pairing (best-effort, tanpa connect agar tak ganggu cetak).
    Set<String> pairedBt = {};
    if (saved.any((p) => p.type == PrinterType.bluetooth)) {
      try {
        final paired = await PrintBluetoothThermal.pairedBluetooths;
        pairedBt = paired.map((b) => b.macAdress).toSet();
      } catch (_) {}
    }

    // Ping semua printer PARALEL → total maksimal ~1 detik apa pun jumlahnya
    // (Socket.connect async, non-blocking; tidak membekukan UI).
    return Future.wait(saved.map((p) async {
      bool online = false;
      String? ip;
      if (p.type == PrinterType.lan) {
        ip = p.address.split(':').first; // IP lokal printer
        try {
          // Ping DISERIALISASI dengan job cetak (tak ganggu perintah order).
          online = await _printer.pingLanSafe(p.address,
              timeout: const Duration(seconds: 1));
        } catch (_) {}
      } else {
        // BT: status "paired" (tak bisa pastikan menyala tanpa connect).
        online = pairedBt.contains(p.address);
      }
      return {
        'name': p.name,
        'address': p.address, // BT MAC atau IP:port
        if (ip != null) 'ip': ip, // IP lokal (LAN)
        'type': p.type.name,
        'roles': p.rolesLabel,
        'connected': online, // terhubung/terjangkau (LAN) atau paired (BT)
        'online': online, // alias kompatibilitas
      };
    }));
  }
}
