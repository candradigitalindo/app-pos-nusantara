import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'printer_service.dart';

/// Pengaturan laci kasir (cash drawer). Laci dibuka lewat printer struk:
/// hampir semua laci POS tersambung ke port RJ11 "DK" di printer thermal dan
/// terpicu oleh perintah ESC/POS `ESC p m t1 t2` yang dikirim ke printer.
class CashDrawerSettings {
  /// Buka laci OTOMATIS setelah pembayaran lunas.
  final bool enabled;

  /// Hanya buka untuk pembayaran TUNAI (kartu/QRIS/transfer tidak membuka laci).
  final bool cashOnly;

  /// Pin konektor drawer di printer: 2 (paling umum) atau 5.
  final int pin;

  /// Lama pulsa ON dalam milidetik (laci "keras" butuh pulsa lebih panjang).
  final int pulseMs;

  /// Alamat printer yang lacinya dicolok. Kosong = ikut printer kasir
  /// (printer ber-peran Kasir, sama seperti tujuan struk).
  final String printerAddress;

  const CashDrawerSettings({
    this.enabled = true,
    this.cashOnly = true,
    this.pin = 2,
    this.pulseMs = 100,
    this.printerAddress = '',
  });

  /// Pilihan lama pulsa yang ditawarkan di Pengaturan.
  static const List<int> pulseChoices = [50, 100, 200, 300];

  CashDrawerSettings copyWith({
    bool? enabled,
    bool? cashOnly,
    int? pin,
    int? pulseMs,
    String? printerAddress,
  }) =>
      CashDrawerSettings(
        enabled: enabled ?? this.enabled,
        cashOnly: cashOnly ?? this.cashOnly,
        pin: pin ?? this.pin,
        pulseMs: pulseMs ?? this.pulseMs,
        printerAddress: printerAddress ?? this.printerAddress,
      );
}

/// Integrasi laci kasir.
///
/// Alur: pembayaran lunas → [openAfterPayment] → byte kick ESC/POS dikirim ke
/// printer kasir → printer memicu solenoid laci.
///
/// Pengiriman TIDAK lewat antrian cetak (PrintQueueService) dengan sengaja:
/// job antrian punya retry sampai puluhan menit, dan laci yang membuka sendiri
/// jauh setelah transaksi justru berbahaya. Bila gagal, kasir memakai tombol
/// "Buka Laci" manual. Serialisasi koneksi tetap aman karena kirimnya lewat
/// [PrinterService] yang sudah mengunci per-koneksi (BT global, LAN per-alamat).
class CashDrawerService {
  static final CashDrawerService instance = CashDrawerService._();
  CashDrawerService._();

  static const _kEnabled = 'cash_drawer_enabled';
  static const _kCashOnly = 'cash_drawer_cash_only';
  static const _kPin = 'cash_drawer_pin';
  static const _kPulseMs = 'cash_drawer_pulse_ms';
  static const _kPrinter = 'cash_drawer_printer';

  final _printerService = PrinterService();
  CashDrawerSettings? _cache;

  // ── Pengaturan ────────────────────────────────────────────────────────────

  Future<CashDrawerSettings> settings() async {
    final cached = _cache;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    const d = CashDrawerSettings();
    return _cache = CashDrawerSettings(
      enabled: prefs.getBool(_kEnabled) ?? d.enabled,
      cashOnly: prefs.getBool(_kCashOnly) ?? d.cashOnly,
      pin: prefs.getInt(_kPin) == 5 ? 5 : 2,
      pulseMs: prefs.getInt(_kPulseMs) ?? d.pulseMs,
      printerAddress: prefs.getString(_kPrinter) ?? d.printerAddress,
    );
  }

  Future<void> save(CashDrawerSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, s.enabled);
    await prefs.setBool(_kCashOnly, s.cashOnly);
    await prefs.setInt(_kPin, s.pin == 5 ? 5 : 2);
    await prefs.setInt(_kPulseMs, s.pulseMs);
    await prefs.setString(_kPrinter, s.printerAddress);
    _cache = s;
  }

  // ── Byte ESC/POS ──────────────────────────────────────────────────────────

  /// `ESC p m t1 t2` — buka laci.
  /// m  : 0 = pin 2, 1 = pin 5.
  /// t1 : lama pulsa ON, t2 : jeda OFF. Satuan 2 ms, maksimum 255 (510 ms).
  static List<int> kickBytes({int pin = 2, int pulseMs = 100}) {
    final on = (pulseMs ~/ 2).clamp(1, 255);
    final off = (on * 2).clamp(1, 255);
    return [0x1B, 0x70, pin == 5 ? 0x01 : 0x00, on, off];
  }

  // ── Pemilihan printer ─────────────────────────────────────────────────────

  /// Printer yang lacinya dibuka: sesuai pengaturan, kalau tidak ada pakai
  /// printer kasir (aturan sama dengan tujuan struk), lalu printer non-checker,
  /// lalu printer pertama. Null = belum ada printer tersimpan.
  Future<PrinterDevice?> resolvePrinter([CashDrawerSettings? preset]) async {
    final s = preset ?? await settings();
    final saved = await _printerService.getSavedPrinters();
    if (saved.isEmpty) return null;

    if (s.printerAddress.isNotEmpty) {
      for (final p in saved) {
        if (p.address == s.printerAddress) return p;
      }
      // Printer pilihan sudah dihapus → jatuh ke aturan otomatis.
    }
    final cashiers =
        saved.where((p) => p.hasRole(PrinterRole.cashier)).toList();
    if (cashiers.isNotEmpty) return cashiers.first;
    return saved.firstWhere((p) => !p.hasRole(PrinterRole.checker),
        orElse: () => saved.first);
  }

  // ── Buka laci ─────────────────────────────────────────────────────────────

  /// Kirim perintah buka ke [printer] (atau printer hasil [resolvePrinter]).
  /// Melempar Exception bila printer tak ada / tak bisa dihubungi — dipakai
  /// tombol manual & tes supaya kasir dapat pesan kegagalan yang jelas.
  Future<void> open({PrinterDevice? printer, int? pin, int? pulseMs}) async {
    final s = await settings();
    final target = printer ?? await resolvePrinter(s);
    if (target == null) {
      throw Exception(
          'Belum ada printer tersimpan — laci kasir dibuka lewat printer struk.');
    }
    final bytes = kickBytes(pin: pin ?? s.pin, pulseMs: pulseMs ?? s.pulseMs);
    if (target.type == PrinterType.bluetooth) {
      await _printerService.sendBluetooth(target.address, bytes);
    } else {
      await _printerService.sendLan(target.address, bytes);
    }
    debugPrint('Laci kasir: perintah buka terkirim ke ${target.name}');
  }

  /// Buka laci setelah pembayaran LUNAS. Menghormati pengaturan (aktif/tunai
  /// saja) dan tidak pernah melempar — kegagalan laci tidak boleh menggagalkan
  /// alur pembayaran yang sudah tercatat. Mengembalikan true bila terkirim.
  Future<bool> openAfterPayment({required String paymentMethod}) async {
    try {
      final s = await settings();
      if (!s.enabled) return false;
      if (s.cashOnly && paymentMethod.toLowerCase() != 'cash') return false;
      await open();
      return true;
    } catch (e) {
      debugPrint('Laci kasir gagal dibuka: $e');
      return false;
    }
  }
}
