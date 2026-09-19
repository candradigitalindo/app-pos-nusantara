/// Perhitungan biaya tambahan (pajak/PB1, service charge) di atas subtotal.
///
/// SENGAJA dipisah sebagai fungsi murni karena rumus yang sama harus hidup di
/// DUA tempat:
///
///   * di sini — dipakai OrderRepository untuk menghitung tagihan kasir;
///   * di cloud — `CalculateOrderTotal` pada `services/additional_charge.go`,
///     untuk menentukan nominal QRIS dinamis pesanan online.
///
/// Kalau keduanya melenceng, tamu membayar angka yang berbeda dari tagihan
/// yang dihitung kasir — dan selisihnya tidak akan terlihat sampai ada yang
/// mencocokkan setoran. Karena itu keduanya diuji dengan tabel kasus yang sama
/// (`test/charge_math_test.dart` dan `services/charge_math_test.go`); mengubah
/// salah satunya tanpa yang lain akan membuat tabel itu gagal.
class ChargeMath {
  const ChargeMath._();

  /// Basis pengenaan biaya = subtotal SETELAH diskon manual (DPP sesuai
  /// PB1/PPN F&B), tidak pernah negatif.
  ///
  /// Diskon 100% menghasilkan basis 0, sehingga pajak atas tagihan yang
  /// digratiskan juga 0 — bukan pajak atas harga sebelum diskon.
  static double base(double subtotal, double discount) {
    final net = subtotal - discount;
    return net > 0 ? net : 0;
  }

  /// Nominal satu biaya terhadap [base].
  ///
  /// Persentase dihitung dari basis (BUKAN berantai dari hasil biaya
  /// sebelumnya), biaya tetap ditambahkan apa adanya. Basis 0 menghasilkan 0
  /// untuk keduanya: tagihan yang digratiskan tidak boleh menyisakan biaya
  /// tetap yang tetap harus dibayar tamu.
  static double applied(String chargeType, double value, double base) {
    if (base <= 0) return 0;
    return chargeType == 'percentage' ? base * value / 100 : value;
  }
}
