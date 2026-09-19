import 'dart:math';

/// ULID generator - 26 character sortable unique ID
/// Compatible with the Go backend ULIDs.
///
/// Bagian waktu (10 char) menjaga urutan; bagian acak (16 char = 80 bit)
/// memakai RNG kriptografis agar TIDAK pernah bentrok walau banyak ID dibuat
/// dalam mikrodetik yang sama (mis. saat transaksi datang bertubi-tubi).
class Ulid {
  static final Random _rng = Random.secure();

  static String generate() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Encoding characters (Crockford's Base32)
    const encoding = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

    // Encode timestamp (10 chars)
    var ts = timestamp;
    final timeChars = <String>[];
    for (var i = 0; i < 10; i++) {
      timeChars.insert(0, encoding[ts & 0x1f]);
      ts >>= 5;
    }

    // Random part (16 chars × 5 bit = 80 bit entropi nyata)
    final randomChars = <String>[];
    for (var i = 0; i < 16; i++) {
      randomChars.add(encoding[_rng.nextInt(32)]);
    }

    return '${timeChars.join()}${randomChars.join()}';
  }
}
