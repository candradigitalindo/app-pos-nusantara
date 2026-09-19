import 'package:flutter/material.dart';

/// Palet warna terpusat — hijau forest/emerald premium (samakan dgn Cloud POS).
///
/// PRIMARY  = emerald hijau (aksen/tombol/aktif) di atas chrome forest gelap.
/// SECONDARY = honey gold (aksen hangat mewah yang serasi dengan hijau).
///
/// Semua warna aplikasi HARUS mengacu ke sini agar konsisten dan mudah
/// diubah di satu tempat. Jangan menulis `Color(0xFF...)` langsung di screen.
class AppColors {
  AppColors._();

  // ── Brand PRIMARY (emerald — cocokkan dgn dashboard cloud) ─────────────────
  static const Color brand = Color(0xFF2E9E5F); // emerald primer
  static const Color brandDark = Color(0xFF1C6E43);
  static const Color brandLight = Color(0xFF7FC7A0); // sage/mint utk aksen di latar gelap
  static const Color accent = Color(0xFFCFA24E); // SECONDARY: honey gold
  static const Color accentDark = Color(0xFFA97C2E);
  static const Color accentSoft = Color(0xFFFBF3E1);

  /// Gradasi brand utama (dipakai tombol utama, header, logo).
  static const List<Color> brandGradient = [Color(0xFF34A96A), Color(0xFF288E56)];

  /// Gradasi aksen secondary (honey gold) untuk highlight premium.
  static const List<Color> accentGradient = [Color(0xFFDDB262), Color(0xFFC5933F)];

  /// Gradasi latar halus untuk background halaman (nyaris putih, sedikit hijau).
  static const List<Color> canvasGradient = [Color(0xFFF6FAF7), Color(0xFFEDF4EF)];

  // ── Chrome forest (sidebar & login — cocokkan dgn Cloud POS) ───────────────
  static const Color green = brand; // ikon logo di tile putih
  static const Color greenDark = brandDark;

  /// Gradasi sidebar & header chrome — forest hijau gelap premium.
  static const List<Color> sidebarGradient = [
    Color(0xFF1F3B29), // forest atas
    Color(0xFF15301F), // forest tengah
    Color(0xFF0C1911), // forest bawah (nyaris hitam-hijau)
  ];

  /// Gradasi latar login — forest gelap (kartu glass di atasnya).
  static const List<Color> greenGradient = [
    Color(0xFF18331F),
    Color(0xFF102619),
    Color(0xFF0A1610),
  ];

  // ── Surface & background ───────────────────────────────────────────────────
  static const Color canvas = Color(0xFFF4F8F5); // background halaman (hijau samar)
  static const Color surface = Color(0xFFFFFFFF); // kartu / panel
  static const Color surfaceAlt = Color(0xFFF6FAF7); // kartu sekunder
  static const Color surfaceMuted = Color(0xFFF0F4F1);
  static const Color border = Color(0xFFE4EAE6); // garis tepi halus
  static const Color borderStrong = Color(0xFFD4DCD7);

  /// Warna kaca (frosted glass) — dipakai dengan BackdropFilter.
  static const Color glassOnDark = Color(0x1FFFFFFF); // putih 12% di atas gelap

  // ── Teks ───────────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFF11201A); // hampir hitam kehijauan
  static const Color textSecondary = Color(0xFF586661);
  static const Color textTertiary = Color(0xFF93A29B);
  static const Color textOnBrand = Color(0xFFFFFFFF);

  // ── Semantik ────────────────────────────────────────────────────────────────
  static const Color success = Color(0xFF16A34A);
  static const Color successSoft = Color(0xFFECFDF3);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningSoft = Color(0xFFFFF8EB);
  static const Color danger = Color(0xFFEF4444);
  static const Color dangerSoft = Color(0xFFFEF2F2);
  static const Color info = Color(0xFF0EA5E9);
  static const Color infoSoft = Color(0xFFEFF9FF);

  // ── Aksen per-modul ────────────────────────────────────────────────────────
  // Diseragamkan: semua modul memakai PRIMARY hijau emerald agar seluruh
  // halaman konsisten satu brand (SECONDARY gold dipakai untuk highlight/aksi
  // sekunder, bukan sebagai identitas modul). Nama token dipertahankan agar
  // screen tidak perlu diubah.
  static const Color moduleKasir = brand;
  static const Color moduleMeja = brand;
  static const Color moduleDapur = brand;
  static const Color moduleWaiter = brand;
  static const Color moduleProduk = brand;
  static const Color moduleTransaksi = brand;
  static const Color modulePengaturan = brand;

  /// Gradasi lembut dari sebuah warna aksen (untuk ikon berbentuk kapsul).
  static List<Color> gradientOf(Color c) => [
        Color.lerp(c, Colors.white, 0.18)!,
        c,
      ];

  /// Versi transparan sebuah warna (pengganti `.withOpacity` yang deprecated).
  static Color soft(Color c, double alpha) => c.withValues(alpha: alpha);
}
