# Nusantara POS — Flutter

Aplikasi operasional kasir/restoran untuk tablet Android, dengan station kasir,
waiter dan dapur, printer/laci uang, pembayaran, sinkronisasi cloud, serta
reservasi dan DP. `master` menjadi acuan gabungan aplikasi ini.

Backend pasangannya adalah
[`claoud-pos-nusantara/master`](https://github.com/candradigitalindo/claoud-pos-nusantara/tree/master).
Menu administrasi, stok bahan, pengadaan, dan laporan tetap berada di cloud.

## Asal penggabungan

- `app-pos-nusantara` pada `8c36e15`: reservasi dan DP.
- Subdirektori `app-pos-flutter` dari
  `app-pos-resto/feat/kasir-station-parity` pada `57a5070`: kasir/station,
  laci uang, dapur station, serta pembaruan layar langsung.
- Penggabungan tiga arah memakai `bf1071d` sebagai dasar. Kedua keluarga
  fitur dipertahankan; repo lama tetap menjadi referensi riwayat.

Migrasi SQLite v14 menambah identitas produk pada item pesanan. Data lama
dipertahankan tanpa menebak ID produk. Antrean kejadian void/titipan memakai
identitas tersendiri, pembayaran membawa waktu UTC, dan pembaruan DP mencatat
selisih tervalidasi secara idempoten.

## Pengembangan dan pengujian

Toolchain yang diuji: Flutter **3.41.9**, Dart **3.11.5**. Gunakan lockfile yang
disertakan. Dari checkout aplikasi:

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test --concurrency=1
```

Dua tes E2E memerlukan API dan data sintetis. Runner berikut menyiapkan
PostgreSQL dan API melalui Docker pada jaringan internal baru, tanpa port
host atau database produksi. `cloud-pos` dan aplikasi ini dapat ditempatkan
sebagai direktori saudara; gunakan `POS_CLOUD_DIR` untuk lokasi lain.

```bash
POS_CLOUD_DIR=../cloud-pos tool/run_e2e.sh \
  --artifacts /path/baru/hasil-uji-flutter
```

Runner memeriksa seluruh tes Flutter, termasuk alur pesanan online dan
reservasi terhadap API nyata. Lihat
[panduan integrasi cloud](https://github.com/candradigitalindo/claoud-pos-nusantara/blob/master/docs/pos-master-integration.md)
untuk batas pemeriksaan dan cara menjalankan seluruh pemeriksaan Go/Vue/Flutter.

QRIS dalam pengujian adalah **simulasi**, bukan penerimaan uang. Uji tablet,
printer, laci uang, build APK Android, dan penyedia pembayaran nyata tetap
diperlukan sebelum rilis perangkat. Restore belum menggantikan cadangan lengkap
rincian pembayaran; pembaruan DP ditolak bila riwayat lokal belum lengkap.
