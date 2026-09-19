import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Tipografi terpusat — skala & bobot ala SF Pro (iOS).
///
/// Sengaja memakai font sistem (Roboto/SF) agar POS tetap andal saat OFFLINE
/// tanpa unduh font runtime. Untuk mengganti ke font khusus (mis. Plus Jakarta
/// Sans yang di-bundle), cukup ubah [_family] di SATU tempat ini.
class AppType {
  AppType._();

  /// Ganti nilai ini bila ingin memakai font khusus yang sudah di-bundle.
  static const String? _family = null;

  static const double _tight = -0.5;
  static const double _snug = -0.2;

  static TextStyle _base(
    double size,
    FontWeight weight, {
    Color color = AppColors.textPrimary,
    double? letterSpacing,
    double height = 1.2,
  }) =>
      TextStyle(
        fontFamily: _family,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  // ── Display / judul besar ──────────────────────────────────────────────────
  static TextStyle display = _base(34, FontWeight.w800, letterSpacing: _tight, height: 1.1);
  static TextStyle h1 = _base(26, FontWeight.w800, letterSpacing: _tight, height: 1.15);
  static TextStyle h2 = _base(22, FontWeight.w700, letterSpacing: _snug, height: 1.2);
  static TextStyle h3 = _base(18, FontWeight.w700, letterSpacing: _snug);
  static TextStyle title = _base(16, FontWeight.w700, letterSpacing: _snug);

  // ── Body ─────────────────────────────────────────────────────────────────────
  static TextStyle bodyLg = _base(16, FontWeight.w500, height: 1.4);
  static TextStyle body = _base(14, FontWeight.w500, height: 1.4);
  static TextStyle bodySm = _base(13, FontWeight.w500, height: 1.35, color: AppColors.textSecondary);

  // ── Label / caption ──────────────────────────────────────────────────────────
  static TextStyle label = _base(13, FontWeight.w600, letterSpacing: 0.1);
  static TextStyle caption = _base(12, FontWeight.w500, color: AppColors.textSecondary);
  static TextStyle overline = _base(11, FontWeight.w700, letterSpacing: 1.0, color: AppColors.textTertiary);

  // ── Angka (nominal uang) — butuh bobot ekstra tebal & rapat ────────────────
  static TextStyle amount = _base(20, FontWeight.w800, letterSpacing: _tight);
  static TextStyle amountLg = _base(28, FontWeight.w800, letterSpacing: _tight);

  /// Tekan/geser warna sebuah style dengan cepat.
  static TextStyle on(TextStyle s, Color color) => s.copyWith(color: color);
}
