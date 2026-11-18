import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'outlet_service.dart';

/// Pembaruan dalam-aplikasi: cek APK POS terbaru di cloud
/// (`GET /api/v1/app-update/pos`), unduh di latar belakang, cocokkan SHA-256,
/// lalu pasang lewat PackageInstaller Android (channel `pos/app_update`).
/// Kasir cukup menekan "Pasang" (dan "Perbarui" di dialog Android) — tanpa
/// membuka browser atau mencari file APK.

enum AppUpdatePhase {
  idle, // belum pernah memeriksa
  checking,
  upToDate,
  downloading,
  ready, // APK terunduh & terverifikasi, siap dipasang
  installing, // dialog / proses pemasangan Android berjalan
  failed,
}

@immutable
class AppRelease {
  final String name;
  final String url; // absolut
  final int size;
  final String sha256;
  final int versionCode;
  final String label; // mis. "v10.19" (dari nama berkas di cloud)

  const AppRelease({
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
    required this.versionCode,
    required this.label,
  });

  String get displayName => label.isNotEmpty ? label : 'build $versionCode';

  static final _sha256Re = RegExp(r'^[0-9a-f]{64}$');

  /// null bila data rilis tidak lengkap/aneh — lebih baik tidak menawarkan
  /// apa pun daripada memasang berkas yang tak bisa diverifikasi.
  static AppRelease? fromJson(Map json, String baseUrl) {
    final code = json['version_code'];
    final size = json['size'];
    final sha = (json['sha256'] as String? ?? '').toLowerCase();
    var url = json['url'] as String? ?? '';
    if (code is! num || code <= 0 || size is! num || size <= 0) return null;
    if (!_sha256Re.hasMatch(sha) || url.isEmpty) return null;
    if (url.startsWith('/')) url = '$baseUrl$url';
    return AppRelease(
      name: json['name'] as String? ?? '',
      url: url,
      size: size.toInt(),
      sha256: sha,
      versionCode: code.toInt(),
      label: json['label'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'size': size,
        'sha256': sha256,
        'version_code': versionCode,
        'label': label,
      };
}

@immutable
class AppUpdateState {
  final AppUpdatePhase phase;
  final int? currentCode;
  final String currentLabel;
  final AppRelease? release;
  final double? progress; // 0..1 saat mengunduh
  final String? message; // keterangan / galat untuk ditampilkan

  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.currentCode,
    this.currentLabel = '',
    this.release,
    this.progress,
    this.message,
  });

  bool get updateAvailable =>
      release != null &&
      currentCode != null &&
      release!.versionCode > currentCode!;

  String get currentDisplay => currentLabel.isNotEmpty
      ? currentLabel
      : (currentCode == null ? '-' : 'build $currentCode');

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    int? currentCode,
    String? currentLabel,
    AppRelease? release,
    double? progress,
    String? message,
    bool clearMessage = false,
  }) =>
      AppUpdateState(
        phase: phase ?? this.phase,
        currentCode: currentCode ?? this.currentCode,
        currentLabel: currentLabel ?? this.currentLabel,
        release: release ?? this.release,
        progress: progress ?? this.progress,
        message: clearMessage ? null : (message ?? this.message),
      );
}

/// Bagian yang bergantung platform — diganti tiruan di tes.
abstract class AppUpdatePlatform {
  bool get supported;
  Future<int?> currentVersionCode();
  Future<Directory> updatesDirectory();
  Future<bool> canInstall();
  Future<void> openInstallSettings();
  Future<void> install(String apkPath);
  void onInstallStatus(void Function(String status, String? message) handler);
}

class _ChannelPlatform implements AppUpdatePlatform {
  static const _channel = MethodChannel('pos/app_update');

  @override
  bool get supported => !kIsWeb && Platform.isAndroid;

  @override
  Future<int?> currentVersionCode() async =>
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber);

  @override
  Future<Directory> updatesDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}updates');
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<bool> canInstall() async =>
      (await _channel.invokeMethod<bool>('canInstall')) ?? false;

  @override
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  @override
  Future<void> install(String apkPath) =>
      _channel.invokeMethod<void>('install', {'path': apkPath});

  @override
  void onInstallStatus(void Function(String status, String? message) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'installStatus') return;
      final args = call.arguments is Map ? call.arguments as Map : const {};
      handler(args['status'] as String? ?? 'failure', args['message'] as String?);
    });
  }
}

class _UpdateException implements Exception {
  final String message;
  const _UpdateException(this.message);
  @override
  String toString() => message;
}

class AppUpdateService {
  AppUpdateService._(this._platform,
      {Dio? dio, Future<String> Function()? baseUrl})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            )),
        _baseUrl = baseUrl ?? _defaultBaseUrl;

  static final AppUpdateService instance =
      AppUpdateService._(_ChannelPlatform());

  @visibleForTesting
  factory AppUpdateService.forTest({
    required AppUpdatePlatform platform,
    required Future<String> Function() baseUrl,
    Dio? dio,
  }) =>
      AppUpdateService._(platform, dio: dio, baseUrl: baseUrl);

  static const checkInterval = Duration(minutes: 30);

  final AppUpdatePlatform _platform;
  final Dio _dio;
  final Future<String> Function() _baseUrl;
  final ValueNotifier<AppUpdateState> state =
      ValueNotifier(const AppUpdateState());

  Timer? _timer;
  Future<AppUpdateState>? _running;
  // Unduhan terverifikasi yang siap dipasang (berkas + rilisnya).
  File? _readyFile;
  AppRelease? _readyRelease;

  bool get supported => _platform.supported;

  static Future<String> _defaultBaseUrl() async {
    final outlet = await OutletService().loadOutlet();
    var url = outlet.cloudApiUrl.trim();
    if (url.isEmpty) url = OutletService.productionCloudApiUrl;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/api/v1')) url = url.substring(0, url.length - 7);
    return url;
  }

  /// Mulai: bersihkan berkas pembaruan yang sudah terpasang, pulihkan unduhan
  /// siap-pasang (tetap bisa dipasang walau sedang offline), lalu periksa
  /// berkala. Hanya di Android; aman dipanggil berulang.
  Future<void> start() async {
    if (!_platform.supported) return;
    _platform.onInstallStatus(_onInstallStatus);
    try {
      await _restoreDownloaded();
    } catch (e) {
      debugPrint('AppUpdate restore: $e');
    }
    unawaited(check());
    _timer ??= Timer.periodic(checkInterval, (_) => unawaited(check()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Periksa versi terbaru dan, bila lebih baru, unduh di latar belakang.
  /// Panggilan bersamaan berbagi satu pemeriksaan.
  Future<AppUpdateState> check({bool userInitiated = false}) =>
      _running ??= _check(userInitiated).whenComplete(() => _running = null);

  Future<AppUpdateState> _check(bool userInitiated) async {
    final before = state.value;
    if (before.phase == AppUpdatePhase.downloading ||
        before.phase == AppUpdatePhase.installing) {
      return before;
    }
    try {
      final current = await _platform.currentVersionCode();
      // Pemeriksaan otomatis tidak boleh menutupi "siap dipasang".
      if (userInitiated || before.phase != AppUpdatePhase.ready) {
        state.value = before.copyWith(
            phase: AppUpdatePhase.checking,
            currentCode: current,
            clearMessage: true);
      }
      final base = await _baseUrl();
      final resp = await _dio.get(
        '$base/api/v1/app-update/pos',
        queryParameters: {if (current != null) 'current': current},
      );
      final root = resp.data;
      final data = root is Map ? root['data'] : null;
      if (data is! Map) {
        throw const _UpdateException('Respons server pembaruan tidak valid.');
      }
      final latest = data['latest'];
      final release = latest is Map ? AppRelease.fromJson(latest, base) : null;
      final currentLabel = data['current_label'] as String? ?? '';
      if (release == null ||
          current == null ||
          release.versionCode <= current) {
        // Tidak pernah menawarkan versi yang sama/lebih lama (no downgrade).
        await _deleteDownloads();
        state.value = AppUpdateState(
          phase: AppUpdatePhase.upToDate,
          currentCode: current,
          currentLabel: currentLabel,
        );
        return state.value;
      }
      final ready = _readyRelease;
      if (_readyFile != null &&
          ready != null &&
          ready.versionCode == release.versionCode &&
          ready.sha256 == release.sha256) {
        // Sudah terunduh & terverifikasi — tak perlu hash ulang 60+ MB.
        state.value = AppUpdateState(
          phase: AppUpdatePhase.ready,
          currentCode: current,
          currentLabel: currentLabel,
          release: ready,
          progress: 1,
        );
        return state.value;
      }
      state.value = AppUpdateState(
        phase: AppUpdatePhase.downloading,
        currentCode: current,
        currentLabel: currentLabel,
        release: release,
        progress: 0,
      );
      await _download(release);
      return state.value;
    } catch (e) {
      debugPrint('AppUpdate check: $e');
      final s = state.value;
      final ready = _readyRelease;
      if (_readyFile != null && ready != null) {
        // Unduhan terverifikasi tetap bisa dipasang walau pemeriksaan gagal.
        state.value = AppUpdateState(
          phase: AppUpdatePhase.ready,
          currentCode: s.currentCode,
          currentLabel: s.currentLabel,
          release: ready,
          progress: 1,
          message: userInitiated
              ? '${_describe(e)} Pembaruan yang sudah diunduh tetap bisa dipasang.'
              : null,
        );
      } else {
        state.value = s.copyWith(
            phase: AppUpdatePhase.failed, message: _describe(e));
      }
      return state.value;
    }
  }

  Future<void> _download(AppRelease r) async {
    final dir = await _platform.updatesDirectory();
    final file = File(_join(dir.path, 'pos-${r.versionCode}.apk'));
    if (await _verified(file, r)) {
      await _markReady(r, file);
      return;
    }
    final part = File('${file.path}.part');
    if (await part.exists()) await part.delete();
    var lastPercent = -1;
    await _dio.download(
      r.url,
      part.path,
      deleteOnError: true,
      options: Options(receiveTimeout: const Duration(minutes: 2)),
      onReceiveProgress: (received, total) {
        final expected = total > 0 ? total : r.size;
        if (expected <= 0) return;
        final percent = (received * 100 ~/ expected).clamp(0, 100);
        if (percent == lastPercent) return; // hemat rebuild UI
        lastPercent = percent;
        state.value = state.value.copyWith(progress: percent / 100);
      },
    );
    if (!await _verified(part, r)) {
      if (await part.exists()) await part.delete();
      throw const _UpdateException(
          'Berkas unduhan tidak utuh (checksum berbeda). Dicoba lagi nanti.');
    }
    if (await file.exists()) await file.delete();
    await part.rename(file.path);
    await _markReady(r, file);
  }

  Future<void> _markReady(AppRelease r, File file) async {
    await _deleteDownloads(keep: file);
    await File('${file.path}.json').writeAsString(jsonEncode(r.toJson()));
    _readyFile = file;
    _readyRelease = r;
    state.value = state.value.copyWith(
        phase: AppUpdatePhase.ready,
        release: r,
        progress: 1,
        clearMessage: true);
  }

  /// Saat aplikasi dibuka: hapus berkas versi yang sudah terpasang, dan bila
  /// ada unduhan terverifikasi untuk versi yang lebih baru, langsung siap.
  Future<void> _restoreDownloaded() async {
    final current = await _platform.currentVersionCode();
    final dir = await _platform.updatesDirectory();
    AppRelease? pending;
    File? pendingFile;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.apk.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        final release = json is Map
            ? AppRelease.fromJson(json, '')
            : null;
        final apk = File(entity.path.substring(0, entity.path.length - 5));
        if (release != null &&
            current != null &&
            release.versionCode > current &&
            await _verified(apk, release)) {
          pending = release;
          pendingFile = apk;
        }
      } catch (_) {}
    }
    if (pending == null || pendingFile == null) {
      await _deleteDownloads();
      state.value = state.value.copyWith(currentCode: current);
      return;
    }
    await _deleteDownloads(keep: pendingFile);
    _readyFile = pendingFile;
    _readyRelease = pending;
    state.value = AppUpdateState(
      phase: AppUpdatePhase.ready,
      currentCode: current,
      release: pending,
      progress: 1,
    );
  }

  /// Mulai pemasangan. null = installer Android berjalan (aplikasi akan
  /// tertutup sebentar); selain itu pesan untuk ditampilkan ke kasir.
  Future<String?> install() async {
    final s = state.value;
    final file = _readyFile;
    final release = _readyRelease;
    if (s.phase != AppUpdatePhase.ready || file == null || release == null) {
      return 'Pembaruan belum siap dipasang.';
    }
    if (!_platform.supported) {
      return 'Pemasangan otomatis hanya tersedia di Android.';
    }
    // Berkas bisa rusak/terhapus sejak diunduh — jangan pasang tanpa bukti.
    if (!await _verified(file, release)) {
      await _deleteDownloads();
      state.value = s.copyWith(
          phase: AppUpdatePhase.failed,
          message: 'Berkas pembaruan rusak. Tekan Periksa untuk mengunduh ulang.');
      return state.value.message;
    }
    if (!await _platform.canInstall()) {
      await _platform.openInstallSettings();
      return 'Izinkan "Instal aplikasi tak dikenal" untuk POS, lalu kembali '
          'dan tekan Pasang lagi.';
    }
    state.value = s.copyWith(phase: AppUpdatePhase.installing, clearMessage: true);
    try {
      await _platform.install(file.path);
      return null;
    } on PlatformException catch (e) {
      state.value = s.copyWith(
          phase: AppUpdatePhase.ready,
          message: 'Gagal memulai pemasangan: ${e.message ?? e.code}');
      return state.value.message;
    }
  }

  void _onInstallStatus(String status, String? message) {
    final s = state.value;
    switch (status) {
      case 'pending_user_action': // dialog "Perbarui" Android sedang tampil
      case 'success': // sistem akan mengganti proses aplikasi
        return;
      default:
        state.value = s.copyWith(
          phase: _readyFile != null ? AppUpdatePhase.ready : AppUpdatePhase.failed,
          message: (message == null || message.isEmpty)
              ? 'Pemasangan dibatalkan.'
              : 'Pemasangan tidak selesai: $message',
        );
    }
  }

  @visibleForTesting
  void debugInstallStatus(String status, [String? message]) =>
      _onInstallStatus(status, message);

  Future<bool> _verified(File file, AppRelease r) async {
    if (!await file.exists()) return false;
    if (await file.length() != r.size) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == r.sha256;
  }

  Future<void> _deleteDownloads({File? keep}) async {
    final dir = await _platform.updatesDirectory();
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (keep != null &&
          (entity.path == keep.path || entity.path == '${keep.path}.json')) {
        continue;
      }
      try {
        await entity.delete();
      } catch (_) {}
    }
    if (keep == null) {
      _readyFile = null;
      _readyRelease = null;
    }
  }

  static String _join(String dir, String name) =>
      '$dir${Platform.pathSeparator}$name';

  static String _describe(Object e) {
    if (e is _UpdateException) return e.message;
    if (e is DioException) {
      final code = e.response?.statusCode;
      return code != null
          ? 'Server pembaruan membalas $code. Dicoba lagi nanti.'
          : 'Tidak bisa menghubungi server pembaruan. Dicoba lagi nanti.';
    }
    if (e is FileSystemException) {
      return 'Penyimpanan tablet bermasalah: ${e.osError?.message ?? e.message}';
    }
    return e.toString();
  }
}
