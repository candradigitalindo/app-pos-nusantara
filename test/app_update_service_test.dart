// Pembaruan dalam-aplikasi: cek → unduh → verifikasi SHA-256 → pasang.
// SENGAJA tanpa TestWidgetsFlutterBinding: binding tes membuat setiap
// HttpClient membalas 400 tanpa benar-benar menghubungi server tiruan.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/services/app_update_service.dart';

class _FakePlatform implements AppUpdatePlatform {
  _FakePlatform(this.dir, this.version);

  final Directory dir;
  int? version;
  bool allowed = true;
  int settingsOpened = 0;
  final installs = <String>[];
  PlatformException? installError;
  void Function(String, String?)? statusHandler;

  @override
  bool get supported => true;
  @override
  Future<int?> currentVersionCode() async => version;
  @override
  Future<Directory> updatesDirectory() async {
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> openInstallSettings() async => settingsOpened++;
  @override
  Future<void> install(String apkPath) async {
    if (installError != null) throw installError!;
    installs.add(apkPath);
  }

  @override
  void onInstallStatus(void Function(String, String?) handler) =>
      statusHandler = handler;
}

void main() {
  late Directory root;
  late Directory updates;
  late HttpServer server;
  late String base;
  late _FakePlatform platform;
  late AppUpdateService service;

  // Perilaku cloud tiruan.
  late List<int> apk;
  int latestCode = 200;
  String? shaOverride;
  var downloads = 0;

  Map<String, dynamic> latestJson() => {
        'name': 'app-universal-release-v10.19.apk',
        'url': '/uploads/apps/app-universal-release-v10.19.apk',
        'size': apk.length,
        'sha256': shaOverride ?? sha256.convert(apk).toString(),
        'version_code': latestCode,
        'version_name': '1.2.0',
        'label': 'v10.19',
      };

  Future<void> startServer() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/api/v1/app-update/pos') {
        final current = int.tryParse(request.uri.queryParameters['current'] ?? '');
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': true,
          'data': {
            'latest': latestJson(),
            'current_label': current == 100 ? 'v10.18' : '',
            'update_available': latestCode > (current ?? 0),
          },
        }));
      } else if (path == '/uploads/apps/app-universal-release-v10.19.apk') {
        downloads++;
        request.response.headers.contentLength = apk.length;
        request.response.add(apk);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  }

  List<String> files() =>
      updates.existsSync() ? updates.listSync().map((e) => e.uri.pathSegments.last).toList() : [];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pos-app-update-');
    updates = Directory('${root.path}/updates');
    apk = List<int>.generate(300 * 1024, (i) => (i * 31 + 7) & 0xff);
    latestCode = 200;
    shaOverride = null;
    downloads = 0;
    await startServer();
    platform = _FakePlatform(updates, 100);
    service = AppUpdateService.forTest(platform: platform, baseUrl: () async => base);
  });

  tearDown(() async {
    service.stop();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test('versi baru diunduh, diverifikasi, lalu siap dipasang', () async {
    final s = await service.check();

    expect(s.phase, AppUpdatePhase.ready);
    expect(s.release!.displayName, 'v10.19');
    expect(s.currentLabel, 'v10.18');
    expect(s.progress, 1);
    expect(s.updateAvailable, isTrue);
    expect(downloads, 1);
    final saved = File('${updates.path}/pos-200.apk');
    expect(await saved.readAsBytes(), apk);
    expect(files(), unorderedEquals(['pos-200.apk', 'pos-200.apk.json']));

    // Pemeriksaan berkala berikutnya tidak mengunduh ulang 60+ MB.
    final again = await service.check();
    expect(again.phase, AppUpdatePhase.ready);
    expect(downloads, 1);
  });

  test('sudah versi terbaru: tidak menawarkan apa pun & sisa unduhan dibersihkan',
      () async {
    await updates.create(recursive: true);
    await File('${updates.path}/pos-150.apk').writeAsBytes([1, 2, 3]);
    platform.version = 200;

    final s = await service.check();

    expect(s.phase, AppUpdatePhase.upToDate);
    expect(s.release, isNull);
    expect(downloads, 0);
    expect(files(), isEmpty);
  });

  test('tidak pernah menurunkan versi', () async {
    latestCode = 90;
    final s = await service.check();
    expect(s.phase, AppUpdatePhase.upToDate);
    expect(downloads, 0);
  });

  test('checksum tidak cocok: gagal & berkas setengah jadi dibuang', () async {
    shaOverride = 'a' * 64;
    final s = await service.check();

    expect(s.phase, AppUpdatePhase.failed);
    expect(s.message, contains('checksum'));
    expect(files().where((f) => f.endsWith('.apk') || f.endsWith('.part')), isEmpty);
    expect(await service.install(), 'Pembaruan belum siap dipasang.');
  });

  test('server tak terjangkau: pesan jelas, dicoba lagi nanti', () async {
    await server.close(force: true);
    final s = await service.check();
    expect(s.phase, AppUpdatePhase.failed);
    expect(s.message, contains('Tidak bisa menghubungi server pembaruan'));
  });

  test('pasang: izin "aplikasi tak dikenal" belum ada → buka pengaturan', () async {
    await service.check();
    platform.allowed = false;

    final message = await service.install();

    expect(message, contains('Instal aplikasi tak dikenal'));
    expect(platform.settingsOpened, 1);
    expect(platform.installs, isEmpty);
    expect(service.state.value.phase, AppUpdatePhase.ready);
  });

  test('pasang: installer dipanggil; dibatalkan di dialog → kembali siap', () async {
    await service.check();

    expect(await service.install(), isNull);
    expect(platform.installs, ['${updates.path}/pos-200.apk']);
    expect(service.state.value.phase, AppUpdatePhase.installing);

    service.debugInstallStatus('pending_user_action');
    expect(service.state.value.phase, AppUpdatePhase.installing);
    service.debugInstallStatus('failure', 'INSTALL_FAILED_ABORTED: User rejected');
    expect(service.state.value.phase, AppUpdatePhase.ready);
    expect(service.state.value.message, contains('tidak selesai'));
  });

  test('pasang: berkas rusak sejak diunduh → ditolak, tidak dipasang', () async {
    await service.check();
    await File('${updates.path}/pos-200.apk').writeAsBytes(List.filled(apk.length, 0));

    final message = await service.install();

    expect(message, contains('rusak'));
    expect(platform.installs, isEmpty);
    expect(service.state.value.phase, AppUpdatePhase.failed);
  });

  test('pasang: kegagalan memulai installer dilaporkan, tetap bisa dicoba lagi',
      () async {
    await service.check();
    platform.installError = PlatformException(code: 'INSTALL_FAILED', message: 'Sesi gagal');

    expect(await service.install(), contains('Sesi gagal'));
    expect(service.state.value.phase, AppUpdatePhase.ready);
  });

  test('aplikasi dibuka ulang saat offline: unduhan terverifikasi tetap ditawarkan',
      () async {
    await service.check();
    service.stop();
    await server.close(force: true);

    final reopened = AppUpdateService.forTest(platform: platform, baseUrl: () async => base);
    addTearDown(reopened.stop);
    await reopened.start();
    final s = await reopened.check();

    expect(s.phase, AppUpdatePhase.ready);
    expect(s.release!.versionCode, 200);
    expect(await reopened.install(), isNull);
    expect(platform.installs.single, endsWith('pos-200.apk'));
  });

  test('setelah versi baru terpasang, berkas pembaruannya dihapus', () async {
    await service.check();
    service.stop();
    platform.version = 200; // pembaruan sudah terpasang
    latestCode = 200;

    final reopened = AppUpdateService.forTest(platform: platform, baseUrl: () async => base);
    addTearDown(reopened.stop);
    await reopened.start();
    final s = await reopened.check();

    expect(s.phase, AppUpdatePhase.upToDate);
    expect(files(), isEmpty);
  });
}
