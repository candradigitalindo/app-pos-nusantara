import 'package:flutter/material.dart';

/// Avatar placeholder untuk menu yang tidak punya foto: menampilkan huruf
/// pertama nama menu di atas warna yang konsisten dari nama tersebut.
class MenuAvatar extends StatelessWidget {
  final String name;

  /// Ukuran tetap (persegi). Jika null, avatar mengisi penuh ruang induknya.
  final double? size;
  final double radius;

  const MenuAvatar({
    super.key,
    required this.name,
    this.size = 44,
    this.radius = 10,
  });

  /// Avatar yang mengisi penuh ruang yang tersedia (untuk kartu besar).
  const MenuAvatar.fill({
    super.key,
    required this.name,
    this.radius = 16,
  }) : size = null;

  // Palet warna lembut; dipilih deterministik dari nama agar konsisten.
  // [latar terang, latar kedua (gradasi), warna teks].
  static const _palette = [
    [Color(0xFFD1FAE5), Color(0xFFBBF7E4), Color(0xFF0D9488)], // teal
    [Color(0xFFDBEAFE), Color(0xFFC7DBFF), Color(0xFF3B82F6)], // biru
    [Color(0xFFFEF3C7), Color(0xFFFDE9B0), Color(0xFFD97706)], // amber
    [Color(0xFFFCE7F3), Color(0xFFFBD5EA), Color(0xFFDB2777)], // pink
    [Color(0xFFEDE9FE), Color(0xFFDDD6FE), Color(0xFF7C3AED)], // ungu
    [Color(0xFFFFE4E6), Color(0xFFFECDD3), Color(0xFFE11D48)], // merah
    [Color(0xFFE0F2FE), Color(0xFFCAE9FD), Color(0xFF0EA5E9)], // langit
    [Color(0xFFFFEDD5), Color(0xFFFED7AA), Color(0xFFEA580C)], // oranye
  ];

  /// Inisial dari nama menu: huruf pertama tiap kata (maks 2 kata).
  /// "Nasi Goreng" -> "NG", "Ayam" -> "A".
  String get _initials {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.characters.first.toUpperCase();
    return (words[0].characters.first + words[1].characters.first)
        .toUpperCase();
  }

  List<Color> get _colors {
    final key = name.trim().isEmpty ? '?' : name.trim();
    final idx = key.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length;
    return _palette[idx];
  }

  BoxDecoration _decoration(List<Color> c) => BoxDecoration(
        gradient: LinearGradient(
          colors: [c[0], c[1]],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(radius),
      );

  @override
  Widget build(BuildContext context) {
    final c = _colors;
    final initials = _initials;
    final fg = c[2];
    final factor = initials.length > 1 ? 0.34 : 0.42;

    // Ukuran tetap
    if (size != null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: _decoration(c),
        child: Text(
          initials,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w800,
            fontSize: size! * factor,
          ),
        ),
      );
    }

    // Mengisi penuh ruang induk; font menyesuaikan sisi terpendek.
    return LayoutBuilder(
      builder: (context, constraints) {
        final dim = constraints.biggest.shortestSide.isFinite
            ? constraints.biggest.shortestSide
            : 64.0;
        return Container(
          width: double.infinity,
          height: double.infinity,
          alignment: Alignment.center,
          decoration: _decoration(c),
          child: Text(
            initials,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: dim * factor,
            ),
          ),
        );
      },
    );
  }
}
