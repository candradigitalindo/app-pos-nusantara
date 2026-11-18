import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/services/app_update_service.dart';
import 'package:pos_resto/widgets/app_update_banner.dart';

class _IdlePlatform implements AppUpdatePlatform {
  @override
  bool get supported => true;
  @override
  Future<int?> currentVersionCode() async => 100;
  @override
  Future<Directory> updatesDirectory() async => Directory.systemTemp;
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> openInstallSettings() async {}
  @override
  Future<void> install(String apkPath) async {}
  @override
  void onInstallStatus(void Function(String, String?) handler) {}
}

const _release = AppRelease(
  name: 'app-universal-release-v10.19.apk',
  url: 'http://127.0.0.1/uploads/apps/app-universal-release-v10.19.apk',
  size: 1,
  sha256: '0000000000000000000000000000000000000000000000000000000000000000',
  versionCode: 200,
  label: 'v10.19',
);

void main() {
  late AppUpdateService service;

  setUp(() {
    service = AppUpdateService.forTest(
        platform: _IdlePlatform(), baseUrl: () async => 'http://127.0.0.1:1');
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));
  }

  testWidgets('banner tersembunyi bila tidak ada versi baru', (tester) async {
    service.state.value = const AppUpdateState(
        phase: AppUpdatePhase.upToDate, currentCode: 200, currentLabel: 'v10.19');
    await pump(tester, AppUpdateBanner(service: service));
    expect(find.byKey(const Key('app-update-banner')), findsNothing);
  });

  testWidgets('banner menampilkan progres unduhan lalu tombol Pasang',
      (tester) async {
    service.state.value = const AppUpdateState(
        phase: AppUpdatePhase.downloading,
        currentCode: 100,
        release: _release,
        progress: 0.45);
    await pump(tester, AppUpdateBanner(service: service));
    expect(find.text('Mengunduh versi baru v10.19'), findsOneWidget);
    expect(find.textContaining('45%'), findsOneWidget);
    expect(find.byKey(const Key('app-update-install')), findsNothing);

    service.state.value = service.state.value
        .copyWith(phase: AppUpdatePhase.ready, progress: 1);
    await tester.pump();
    expect(find.text('Versi baru v10.19 siap dipasang'), findsOneWidget);

    // Pasang selalu didahului konfirmasi; "Nanti" tidak memasang apa pun.
    await tester.tap(find.byKey(const Key('app-update-install')));
    await tester.pumpAndSettle();
    expect(find.text('Pasang v10.19?'), findsOneWidget);
    expect(find.textContaining('tetap tersimpan'), findsOneWidget);
    await tester.tap(find.text('Nanti'));
    await tester.pumpAndSettle();
    expect(find.text('Pasang v10.19?'), findsNothing);
    expect(service.state.value.phase, AppUpdatePhase.ready);
  });

  testWidgets('gagal mengunduh menampilkan alasan & Coba lagi', (tester) async {
    service.state.value = const AppUpdateState(
        phase: AppUpdatePhase.failed,
        currentCode: 100,
        release: _release,
        message: 'Tidak bisa menghubungi server pembaruan. Dicoba lagi nanti.');
    await pump(tester, AppUpdateBanner(service: service));
    expect(find.text('Pembaruan v10.19 belum bisa diunduh'), findsOneWidget);
    expect(find.textContaining('Tidak bisa menghubungi'), findsOneWidget);
    expect(find.byKey(const Key('app-update-retry')), findsOneWidget);
  });

  testWidgets('kartu Pengaturan: versi terpasang, status, dan aksi', (tester) async {
    service.state.value = const AppUpdateState(
        phase: AppUpdatePhase.upToDate, currentCode: 100, currentLabel: 'v10.18');
    await pump(tester, AppUpdateCard(service: service));
    expect(find.text('Terpasang: v10.18'), findsOneWidget);
    expect(find.text('Sudah versi terbaru'), findsOneWidget);
    expect(find.byKey(const Key('app-update-check')), findsOneWidget);

    service.state.value = service.state.value
        .copyWith(phase: AppUpdatePhase.ready, release: _release, progress: 1);
    await tester.pump();
    expect(find.text('v10.19 siap dipasang'), findsOneWidget);
    expect(find.byKey(const Key('app-update-card-install')), findsOneWidget);
  });
}
