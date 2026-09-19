import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'services/device_role_service.dart';
import 'services/logo_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Muat logo struk dari penyimpanan lokal ke cache (untuk cetak offline).
  await LogoService.instance.init();

  // Server API 7070 + print queue + cloud sync HANYA untuk Main POS.
  // Mode Station (atau peran belum dipilih) tidak membuka port apa pun.
  final role = await DeviceRoleService.instance.getRole();
  if (role == DeviceRole.mainPos) {
    await DeviceRoleService.instance.startMainPosServices();
  }

  // Hide system UI (status bar + navigation bar) — immersive sticky mode
  // System UI will temporarily appear on edge swipe, then auto-hide again
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // JANGAN mengunci orientasi di sini. Orientasi diatur native:
  // - Android: manifest `screenOrientation="fullSensor"` → rotasi bebas ke
  //   semua sisi, MENGABAIKAN kunci auto-rotate perangkat (penting: tablet POS
  //   sering terkunci landscape). Memanggil setPreferredOrientations dengan
  //   kombinasi portrait+landscape justru dipetakan Flutter ke UNSPECIFIED
  //   yang kembali tunduk pada kunci perangkat → tetap landscape.
  // - iOS: Info.plist mendaftarkan portrait + landscape.
  // Layout menyesuaikan otomatis via helper responsif (context.isPhone dll).

  runApp(const PosRestoApp());
}
