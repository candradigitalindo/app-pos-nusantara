import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Bayangan lembut berlapis — memberi kedalaman premium tanpa terlihat berat.
class AppShadows {
  AppShadows._();

  /// Bayangan kartu standar (istirahat).
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0F1B1F3B),
      blurRadius: 18,
      offset: Offset(0, 8),
      spreadRadius: -4,
    ),
    BoxShadow(
      color: Color(0x0A1B1F3B),
      blurRadius: 4,
      offset: Offset(0, 2),
    ),
  ];

  /// Bayangan saat elemen terangkat (hover / ditekan).
  static const List<BoxShadow> raised = [
    BoxShadow(
      color: Color(0x1A1B1F3B),
      blurRadius: 28,
      offset: Offset(0, 14),
      spreadRadius: -6,
    ),
    BoxShadow(
      color: Color(0x0F1B1F3B),
      blurRadius: 8,
      offset: Offset(0, 3),
    ),
  ];

  /// Bayangan berwarna (glow) dari warna aksen — untuk tombol/ikon utama.
  static List<BoxShadow> glow(Color color, {double strength = 0.35}) => [
        BoxShadow(
          color: AppColors.soft(color, strength),
          blurRadius: 20,
          offset: const Offset(0, 8),
          spreadRadius: -4,
        ),
      ];

  /// Bayangan untuk modal / sheet yang mengambang.
  static const List<BoxShadow> modal = [
    BoxShadow(
      color: Color(0x24151935),
      blurRadius: 48,
      offset: Offset(0, 24),
      spreadRadius: -12,
    ),
  ];
}
