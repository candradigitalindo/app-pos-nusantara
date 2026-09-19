import 'package:flutter/material.dart';

/// Kelas ukuran layar (mengikuti pola Material 3 / Apple size classes).
enum SizeClass {
  /// Ponsel / jendela sempit (< 600).
  compact,

  /// Ponsel besar landscape / tablet kecil (600–899).
  medium,

  /// Tablet (900–1199).
  expanded,

  /// Tablet besar / desktop (>= 1200).
  large,
}

/// Ambang batas breakpoint global.
class Breakpoints {
  Breakpoints._();
  static const double medium = 600;
  static const double expanded = 900;
  static const double large = 1200;
}

/// Extension responsif pada [BuildContext].
///
/// Dipakai di seluruh screen agar tata letak, ukuran, dan padding menyesuaikan
/// otomatis di SEMUA ukuran layar — dari ponsel sampai tablet besar.
extension ResponsiveContext on BuildContext {
  Size get _size => MediaQuery.sizeOf(this);
  double get w => _size.width;
  double get h => _size.height;
  double get shortestSide => _size.shortestSide;

  SizeClass get sizeClass {
    final width = w;
    if (width < Breakpoints.medium) return SizeClass.compact;
    if (width < Breakpoints.expanded) return SizeClass.medium;
    if (width < Breakpoints.large) return SizeClass.expanded;
    return SizeClass.large;
  }

  bool get isCompact => sizeClass == SizeClass.compact;
  bool get isMedium => sizeClass == SizeClass.medium;
  bool get isExpanded => sizeClass == SizeClass.expanded;
  bool get isLarge => sizeClass == SizeClass.large;

  /// True untuk ponsel (dipakai memilih layout ponsel vs tablet).
  bool get isPhone => w < Breakpoints.medium;
  bool get isTablet => w >= Breakpoints.medium;

  /// Pilih nilai berdasarkan kelas ukuran. `medium`/`expanded`/`large`
  /// akan jatuh ke tingkat di bawahnya bila tidak diberikan.
  T responsive<T>({
    required T compact,
    T? medium,
    T? expanded,
    T? large,
  }) {
    switch (sizeClass) {
      case SizeClass.compact:
        return compact;
      case SizeClass.medium:
        return medium ?? compact;
      case SizeClass.expanded:
        return expanded ?? medium ?? compact;
      case SizeClass.large:
        return large ?? expanded ?? medium ?? compact;
    }
  }

  /// Skala fluid: perbesar/perkecil [value] secara proporsional terhadap lebar
  /// layar (basis 900px), dengan batas [min]/[max] agar tak ekstrem.
  double rs(double value, {double base = 900, double min = 0.85, double max = 1.2}) {
    final factor = (w / base).clamp(min, max);
    return value * factor;
  }

  /// Padding horizontal halaman yang menyesuaikan ukuran layar.
  double get pagePadX => responsive(compact: 16.0, medium: 20.0, expanded: 28.0, large: 36.0);

  /// Padding vertikal halaman.
  double get pagePadY => responsive(compact: 16.0, medium: 18.0, expanded: 24.0, large: 28.0);

  EdgeInsets get pagePadding => EdgeInsets.symmetric(horizontal: pagePadX, vertical: pagePadY);

  /// Lebar sidebar sesuai layar (mengecil di layar kecil, sembunyi via drawer
  /// bila terlalu sempit — ditangani di shell).
  double get sidebarWidth => responsive(compact: 0.0, medium: 76.0, expanded: 236.0, large: 260.0);

  /// Apakah sidebar sebaiknya jadi rail (ikon saja) alih-alih penuh.
  bool get sidebarIsRail => isMedium;

  /// Jumlah kolom grid yang pas untuk lebar kartu minimum [minTileWidth].
  int gridColumns({double minTileWidth = 220, double gap = 12, double? maxWidth}) {
    final available = (maxWidth ?? w) - pagePadX * 2;
    final cols = ((available + gap) / (minTileWidth + gap)).floor();
    return cols.clamp(1, 8);
  }

  /// Lebar dialog terpusat yang nyaman (dibatasi agar tak melebar berlebihan).
  double dialogWidth({double max = 480}) =>
      (w * responsive(compact: 0.92, medium: 0.7, expanded: 0.55, large: 0.45))
          .clamp(280.0, max);
}
