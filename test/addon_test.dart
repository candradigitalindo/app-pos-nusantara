// Add-on/modifier: pelipatan harga dan pembekuan rincian di baris pesanan.
//
// Yang dijaga di sini adalah keputusan desainnya: harga add-on DILIPAT ke harga
// satuan item, dan rinciannya disimpan sebagai JSON di kolom `addons`. Karena
// itulah subtotal, pajak, split bill, dan seluruh laporan bekerja tanpa tahu
// soal add-on sama sekali. Kalau pelipatan ini rusak, kerusakannya menyebar ke
// semua angka rupiah di sistem sekaligus tanpa satu pun error muncul.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/models/models.dart';

ProductAddon _addon(String id, String name, double price) => ProductAddon(
      id: id,
      productId: 'PRODUK1',
      name: name,
      price: price,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

OrderItem _item({required int qty, required double price, String addons = ''}) =>
    OrderItem(
      id: 'ITEM1',
      orderId: 'ORDER1',
      productName: 'Nasi Goreng',
      qty: qty,
      price: price,
      addons: addons,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  group('SelectedAddon — penjumlahan harga', () {
    test('daftar kosong bernilai nol', () {
      expect(SelectedAddon.totalOf(const []), 0);
    });

    test('menjumlahkan seluruh add-on terpilih', () {
      final picked = [
        SelectedAddon.fromAddon(_addon('A', 'Extra keju', 5000)),
        SelectedAddon.fromAddon(_addon('B', 'Telur', 4000)),
      ];
      expect(SelectedAddon.totalOf(picked), 9000);
    });

    test('add-on gratis tidak menambah harga', () {
      final picked = [SelectedAddon.fromAddon(_addon('C', 'Level pedas', 0))];
      expect(SelectedAddon.totalOf(picked), 0);
    });

    test('label menggabungkan nama sesuai urutan pilih', () {
      final picked = [
        SelectedAddon.fromAddon(_addon('A', 'Extra keju', 5000)),
        SelectedAddon.fromAddon(_addon('B', 'Telur', 4000)),
      ];
      expect(SelectedAddon.labelOf(picked), 'Extra keju, Telur');
    });
  });

  group('Harga satuan terlipat', () {
    test('subtotal item memakai harga yang sudah termasuk add-on', () {
      // Inilah alasan seluruh perhitungan lain tidak perlu tahu soal add-on:
      // begitu tersimpan, baris ini tampak seperti item biasa seharga 34.000.
      const hargaMenu = 25000.0;
      final addons = [
        SelectedAddon.fromAddon(_addon('A', 'Extra keju', 5000)),
        SelectedAddon.fromAddon(_addon('B', 'Telur', 4000)),
      ];
      final hargaSatuan = hargaMenu + SelectedAddon.totalOf(addons);

      final item = _item(qty: 3, price: hargaSatuan);

      expect(hargaSatuan, 34000);
      expect(item.subtotal, 102000); // add-on ikut terkali qty, bukan sekali
    });
  });

  group('Pembekuan rincian di baris pesanan', () {
    test('JSON terbaca kembali utuh', () {
      final picked = [
        SelectedAddon.fromAddon(_addon('A', 'Extra keju', 5000)),
        SelectedAddon.fromAddon(_addon('B', 'Telur', 4000)),
      ];
      final encoded = jsonEncode(picked.map((a) => a.toJson()).toList());
      final item = _item(qty: 1, price: 34000, addons: encoded);

      final decoded = item.selectedAddons;
      expect(decoded.length, 2);
      expect(decoded[0].name, 'Extra keju');
      expect(decoded[0].price, 5000);
      expect(item.addonLabel, 'Extra keju, Telur');
    });

    test('harga yang dibekukan tidak ikut berubah saat master diedit', () {
      // Master add-on naik harga setelah struk dicetak. Baris pesanan lama
      // harus tetap menunjukkan angka saat transaksi terjadi.
      final saatItu = SelectedAddon.fromAddon(_addon('A', 'Extra keju', 5000));
      final encoded = jsonEncode([saatItu.toJson()]);
      final item = _item(qty: 1, price: 30000, addons: encoded);

      // ignore: unused_local_variable
      final masterBaru = _addon('A', 'Extra keju', 8000); // harga dinaikkan

      expect(item.selectedAddons.single.price, 5000);
      expect(item.price, 30000);
    });
  });

  group('Baris lama tetap terbaca', () {
    test('kolom kosong menghasilkan daftar kosong', () {
      final item = _item(qty: 1, price: 25000);
      expect(item.selectedAddons, isEmpty);
      expect(item.addonLabel, '');
    });

    test('teks bebas pra-JSON dikembalikan apa adanya', () {
      // Sebelum fitur ini, `addons` berisi teks bebas. Struk lama tidak boleh
      // kehilangan keterangannya hanya karena formatnya berubah.
      final item = _item(qty: 1, price: 25000, addons: 'tanpa sambal');
      expect(item.selectedAddons, isEmpty);
      expect(item.addonLabel, 'tanpa sambal');
    });

    test('JSON rusak tidak membuat baris gagal dibaca', () {
      // Lebih baik kehilangan rincian add-on daripada satu baris rusak
      // membuat seluruh struk atau tiket dapur gagal tercetak.
      final item = _item(qty: 1, price: 25000, addons: '[{"name":');
      expect(item.selectedAddons, isEmpty);
    });

    test('JSON bukan daftar diabaikan', () {
      final item = _item(qty: 1, price: 25000, addons: '{"name":"x"}');
      expect(item.selectedAddons, isEmpty);
      expect(item.addonLabel, '{"name":"x"}'); // bukan JSON list → teks bebas
    });
  });
}
