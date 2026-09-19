# Reservasi & Uang Muka — sisi App POS

Pasangan dari modul Reservasi di cloud (`docs/reservasi.md` di repo cloud-pos).
Cloud memegang reservasi, validasi DP, dan laporan keuangannya; POS hanya
**membuka** reservasi menjadi order meja pada hari kunjungan dan **menutupnya**
lewat transaksi pelunasan.

## Alur di kasir

```
Kasir → tombol "Reservasi" (header) → daftar reservasi hari ini dari cloud
      → pilih reservasi → pilih meja kosong
      → order dibuat (menu dari reservasi) + DP tervalidasi tercatat
      → tamu bayar sisanya seperti biasa (tunai/QRIS/…)
      → transaksi tersinkron dengan reservation_id → cloud menutup reservasi
```

Reservasi **tidak** dimaterialisasi otomatis tiap siklus sync (berbeda dari
pesanan online): ia berjadwal, belum bermeja, dan biasanya baru dibayar
sebagian, jadi kasir yang memutuskan kapan dan di meja mana.

## Kontrak dengan cloud

| Arah | Endpoint | Keterangan |
|---|---|---|
| POS → cloud | `GET /api/v1/outlets/:id/reservations?date=YYYY-MM-DD` | Reservasi hari itu berstatus pending/confirmed; item membawa `product_local_id` |
| POS → cloud | payload transaksi (`/sync/batch`, entity `transaction`) | Field opsional `reservation_id`; DP dikirim sebagai baris `payments[]` bermetode `reservasi_dp` |
| POS → cloud | `POST /api/v1/outlets/:id/reservations/:rid/settle` | Cadangan bila penutupan otomatis gagal (belum dipakai UI) |

Auth memakai API key outlet, sama seperti sync lain.

## Uang muka di POS

- Metode pembayaran `reservasi_dp` ditambahkan ke `CHECK` tabel `payments`
  (migrasi v13). Ia dicatat oleh sistem saat reservasi dibuka, **bukan** pilihan
  kasir di dialog bayar.
- Nominalnya = `paid_amount` dari cloud (uang muka yang sudah divalidasi admin),
  dicatat lewat `splitBillPayment` sehingga sisa tagihan langsung berkurang.
- Uang DP tidak ada di laci: laporan shift menampilkannya sebagai baris
  "DP Reservasi" terpisah dari tunai. Di cloud, baris ini dikecualikan dari
  penerimaan kas hari kunjungan karena uangnya sudah masuk saat DP.
- Butuh shift terbuka (sama seperti pesanan online), karena pembayaran selalu
  tercatat ke shift.

## Idempotensi & kegagalan

- Membuka reservasi yang sudah punya order aktif mengembalikan order itu, dan
  melengkapi DP-nya bila sebelumnya gagal tercatat — tidak pernah membuat order
  kedua atau DP ganda.
- Menu reservasi yang tidak dikenal POS (produk terhapus / belum tersinkron)
  dilewati dan disebutkan di notifikasi agar kasir menambahkannya manual.
  Bila tidak ada satu pun yang dikenal, pembukaan ditolak.
- Cloud menolak menutup reservasi yang masih punya bukti pembayaran menunggu
  validasi; transaksinya sendiri tetap sah dan tersimpan.

## Menjalankan tes

Tes berbasis SQLite memakai satu berkas `pos_resto.db` yang sama, jadi jalankan
berurutan agar tidak saling menimpa:

```
flutter test --concurrency=1 test/migration_test.dart test/reservation_open_test.dart
```

Tanpa Flutter di mesin: image `ghcr.io/cirruslabs/flutter:stable` + paket
`libsqlite3-0` sudah cukup untuk `flutter analyze` dan tes di atas.

## Berkas

- `lib/services/reservation_service.dart` — model + tarik daftar + buka order.
- `lib/widgets/reservation_picker_dialog.dart` — daftar reservasi hari ini.
- `lib/screens/cashier/cashier_screen.dart` — tombol Reservasi + pemilihan meja.
- `lib/database/database.dart` — migrasi v13 (`orders.reservation_id`, CHECK `payments`).
- `test/reservation_open_test.dart` — alur lokal (DP tercatat, idempoten, payload).
- `test/reservation_e2e_test.dart` — melawan cloud sungguhan (`E2E_*`).
