// Rumus biaya tambahan sisi POS.
//
// Tabel kasus di berkas ini KEMBARAN PERSIS dari `services/charge_math_test.go`
// di cloud-nusantara. Keduanya harus menghasilkan angka yang sama, karena POS
// memakainya untuk menagih di kasir sementara cloud memakainya untuk menentukan
// nominal QRIS dinamis pesanan online. Kalau salah satu diubah tanpa yang lain,
// salah satu tabel akan gagal — itulah gunanya duplikasi yang disengaja ini.
//
// Bila menambah kasus di sini, TAMBAHKAN JUGA di berkas Go-nya.

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/utils/charge_math.dart';

/// Satu biaya pada tabel kasus.
class _Charge {
  final String type; // 'percentage' | 'fixed'
  final double value;
  const _Charge(this.type, this.value);
}

class _Case {
  final String name;
  final double subtotal;
  final double discount;
  final List<_Charge> charges;
  final double expectedTotal;

  const _Case(this.name, this.subtotal, this.discount, this.charges,
      this.expectedTotal);
}

/// TABEL BERSAMA — harus identik dengan sharedCases di charge_math_test.go.
const _sharedCases = <_Case>[
  _Case('tanpa biaya', 100000, 0, [], 100000),

  _Case('pajak persentase saja (PB1 10%)', 100000, 0,
      [_Charge('percentage', 10)], 110000),

  _Case('biaya tetap saja', 100000, 0, [_Charge('fixed', 5000)], 105000),

  // Dua persentase dihitung dari SUBTOTAL, bukan berantai. Kalau berantai,
  // hasilnya 115500 — angka itulah yang ditolak kasus ini.
  _Case('pajak 10% + service 5% tidak berantai', 100000, 0,
      [_Charge('percentage', 10), _Charge('percentage', 5)], 115000),

  _Case('campuran persentase dan tetap', 100000, 0,
      [_Charge('percentage', 10), _Charge('percentage', 5), _Charge('fixed', 2000)],
      117000),

  // Basis pengenaan = subtotal setelah diskon (DPP PB1/PPN).
  _Case('diskon menurunkan basis pajak', 200000, 50000,
      [_Charge('percentage', 10)], 165000),

  // Diskon 100% → basis 0 → tidak ada pajak DAN tidak ada biaya tetap.
  // Tagihan yang digratiskan tidak boleh menyisakan apa pun untuk dibayar.
  _Case('diskon penuh menihilkan seluruh biaya', 200000, 200000,
      [_Charge('percentage', 10), _Charge('fixed', 5000)], 0),

  _Case('subtotal nol', 0, 0, [_Charge('percentage', 10), _Charge('fixed', 5000)], 0),

  // Diskon melebihi subtotal tidak boleh menghasilkan basis negatif.
  _Case('diskon melebihi subtotal', 50000, 80000,
      [_Charge('percentage', 10)], 0),

  // Pecahan: memastikan tidak ada pembulatan diam-diam di salah satu sisi.
  _Case('nominal berpecahan', 33333, 0, [_Charge('percentage', 10)], 36666.3),
];

double _total(_Case c) {
  final base = ChargeMath.base(c.subtotal, c.discount);
  var total = base;
  for (final ch in c.charges) {
    total += ChargeMath.applied(ch.type, ch.value, base);
  }
  return total;
}

void main() {
  group('ChargeMath — tabel bersama dengan cloud', () {
    for (final c in _sharedCases) {
      test(c.name, () {
        expect(_total(c), closeTo(c.expectedTotal, 0.0001),
            reason: 'Bila kasus ini berubah, ubah juga charge_math_test.go');
      });
    }
  });

  group('ChargeMath — sifat yang harus dijaga', () {
    test('urutan biaya tidak memengaruhi total', () {
      // POS membaca biaya tanpa ORDER BY (urut rowid), cloud mengurutkan per
      // nama. Itu aman HANYA selama biaya tidak berantai. Kalau suatu saat
      // rumusnya dibuat berantai, kasus ini gagal dan memaksa kedua sisi
      // disepakati ulang alih-alih diam-diam berbeda.
      const subtotal = 137500.0;
      const charges = [
        _Charge('percentage', 11),
        _Charge('fixed', 3000),
        _Charge('percentage', 6),
      ];
      final maju = _total(const _Case('', subtotal, 0, charges, 0));
      final mundur =
          _total(_Case('', subtotal, 0, charges.reversed.toList(), 0));
      expect(maju, closeTo(mundur, 0.0001));
    });

    test('basis tidak pernah negatif', () {
      expect(ChargeMath.base(1000, 999999), 0);
      expect(ChargeMath.base(0, 0), 0);
    });

    test('biaya tetap ikut nihil saat basis nol', () {
      // Bukan detail sepele: kalau biaya tetap tetap dikenakan, tagihan yang
      // sudah digratiskan manajer masih menyisakan angka yang harus dibayar.
      expect(ChargeMath.applied('fixed', 5000, 0), 0);
      expect(ChargeMath.applied('percentage', 10, 0), 0);
    });

    test('jenis biaya tak dikenal diperlakukan sebagai nominal tetap', () {
      // Cerminan perilaku cloud: apa pun yang bukan 'percentage' ditambahkan
      // apa adanya. Diuji supaya perbedaan penanganan tidak lolos diam-diam.
      expect(ChargeMath.applied('fixed', 2500, 100000), 2500);
      expect(ChargeMath.applied('entah-apa', 2500, 100000), 2500);
    });
  });
}
