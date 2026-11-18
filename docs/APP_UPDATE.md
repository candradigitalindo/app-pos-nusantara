# Pembaruan Dalam-Aplikasi (POS)

Mulai v10.19 tablet memperbarui aplikasinya sendiri dari halaman **App POS**
di cloud — kasir tidak perlu membuka browser atau mencari file APK.

## Alur

1. Saat aplikasi dibuka dan tiap 30 menit, `AppUpdateService` memanggil
   `GET {cloud}/api/v1/app-update/pos?current=<versionCode terpasang>`.
   Cloud = URL di Pengaturan → Cloud; perangkat station tanpa URL memakai
   `https://pos.nbp.co.id`.
2. Bila `latest.version_code` > versi terpasang, APK diunduh di latar
   belakang ke `<app support>/updates/pos-<code>.apk`, lalu **ukuran dan
   SHA-256 wajib cocok** dengan jawaban cloud. Tidak cocok → dibuang.
3. Banner "Versi baru … siap dipasang" muncul di Beranda, layar Buka Kasir,
   dan Pengaturan → Aplikasi. Kasir menekan **Pasang** → konfirmasi →
   `PackageInstaller` Android (channel `pos/app_update`).
4. Android menampilkan dialog **Perbarui** (atau memasang tanpa ketukan di
   Android 12+ bila syarat sistem terpenuhi). Aplikasi tertutup sebentar,
   lalu dibuka lagi dari layar utama. Data, pesanan, dan pengaturan tetap.

Tidak pernah menurunkan versi: cloud menawarkan APK paket
`com.candradigital.pos_resto` dengan **versionCode tertinggi**, dan aplikasi
hanya memasang bila lebih tinggi dari yang terpasang. Unduhan terverifikasi
tetap bisa dipasang walau tablet sedang offline; berkasnya dihapus otomatis
setelah versi tersebut terpasang.

## Kontrak cloud

```json
GET /api/v1/app-update/pos?current=93421153   (publik, tanpa auth, no-store)
{
  "success": true,
  "data": {
    "latest": {
      "name": "app-universal-release-v10.19.apk",
      "url": "/uploads/apps/app-universal-release-v10.19.apk",
      "size": 64200000,
      "sha256": "…64 hex…",
      "version_code": 95300000,
      "version_name": "1.2.0",
      "label": "v10.19",
      "package": "com.candradigital.pos_resto",
      "uploaded_at": "2026-11-18T…Z"
    },
    "current_label": "v10.18",
    "update_available": true
  }
}
```

`version_code`/`package` dibaca cloud langsung dari `AndroidManifest.xml` di
APK yang diunggah (tanpa aapt). `label` berasal dari nama berkas (`-v10.19`).

## Izin Android

- `REQUEST_INSTALL_PACKAGES` — sekali per tablet, kasir mengizinkan
  "Instal aplikasi tak dikenal" untuk POS (aplikasi membuka layar izinnya).
- `UPDATE_PACKAGES_WITHOUT_USER_ACTION` — Android 12+ boleh memasang
  pembaruan diri sendiri tanpa ketukan bila syarat sistem terpenuhi; bila
  tidak, Android tetap meminta konfirmasi. Perilaku bisa berbeda per merek
  (Xiaomi/HyperOS biasanya menambah pemindaian keamanan).
- APK harus ditandatangani kunci yang sama (`android/app/pos-signing.jks`);
  Android menolak pembaruan bertanda tangan lain.

## Uji di tablet sebelum mengandalkannya

1. Pasang v10.19 manual (terakhir kalinya).
2. Unggah build lebih baru (mis. v10.20) ke App POS.
3. Di tablet: Pengaturan → Aplikasi → **Periksa pembaruan** → tunggu unduhan →
   **Pasang**. Catat apakah muncul dialog Perbarui atau langsung terpasang.
4. Buka lagi POS, pastikan versi di kartu Pembaruan Aplikasi berubah dan
   data (pesanan aktif, printer, pengaturan) utuh. Ulangi per merek tablet.
