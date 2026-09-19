#!/usr/bin/env bash
#
# redeploy.sh — Build APK terbaru + pasang ke tablet yang tersambung USB.
# Tujuan: memastikan KODE & FUNGSI di tablet selalu = hasil build terbaru.
#
# Pakai:  ./redeploy.sh
# Syarat: tablet tersambung USB + "USB debugging" aktif.
#
set -e
cd "$(dirname "$0")"

# 1. Pastikan ada device tersambung
DEV=$(adb devices | grep -w "device" | grep -v "List of" | head -1 | awk '{print $1}')
if [ -z "$DEV" ]; then
  echo "✗ Tidak ada tablet tersambung. Colok USB & aktifkan USB debugging, lalu ulangi."
  exit 1
fi
echo "▶ Device: $DEV"

# 2. Build release (split-per-abi, ringan). versionCode otomatis naik (timestamp).
echo "▶ Build release terbaru..."
flutter build apk --release --split-per-abi

# 3. Pilih APK sesuai arsitektur tablet
ABI=$(adb -s "$DEV" shell getprop ro.product.cpu.abi | tr -d '\r')
case "$ABI" in
  arm64-v8a)   APK=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk ;;
  armeabi-v7a) APK=build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk ;;
  x86_64)      APK=build/app/outputs/flutter-apk/app-x86_64-release.apk ;;
  *)           APK=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk ;;
esac
echo "▶ Arsitektur tablet: $ABI → pasang $APK"

# 4. Pasang menimpa (-r): data transaksi & pengaturan TETAP utuh, kode diganti baru.
if adb -s "$DEV" install -r "$APK"; then
  echo "✓ Update sukses. Buka app → Pengaturan → Versi Aplikasi untuk verifikasi."
else
  echo ""
  echo "✗ Gagal pasang menimpa. Penyebab umum: TANDA TANGAN (signature) APK lama"
  echo "  berbeda dengan yang baru (mis. build lama dari komputer/keystore lain)."
  echo "  Solusi (sekali saja): backup DB lalu uninstall + install bersih:"
  echo "    adb -s $DEV shell run-as com.candradigital.pos_resto \\"
  echo "      cat databases/pos_resto.db > backup_pos_resto.db   # backup"
  echo "    adb -s $DEV uninstall com.candradigital.pos_resto"
  echo "    adb -s $DEV install \"$APK\""
  exit 1
fi
