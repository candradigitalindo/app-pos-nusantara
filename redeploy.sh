#!/usr/bin/env bash
#
# redeploy.sh — Build APK terbaru + pasang ke tablet yang tersambung USB.
# Tujuan: memastikan KODE & FUNGSI di tablet selalu = hasil build terbaru.
#
# Pakai:  ./redeploy.sh                 build + pasang ke tablet USB
#         ./redeploy.sh --build-only    build saja (tanpa tablet)
# Syarat: tablet tersambung USB + "USB debugging" aktif (kecuali --build-only).
#
set -e
cd "$(dirname "$0")"

BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    -b|--build-only|--no-install) BUILD_ONLY=1 ;;
    -h|--help)
      sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "✗ Opsi tidak dikenal: $arg (lihat ./redeploy.sh --help)"
      exit 2 ;;
  esac
done

# 1. Pastikan ada device tersambung (dilewati saat --build-only)
if [ "$BUILD_ONLY" = 0 ]; then
  DEV=$(adb devices | grep -w "device" | grep -v "List of" | head -1 | awk '{print $1}')
  if [ -z "$DEV" ]; then
    echo "✗ Tidak ada tablet tersambung. Colok USB & aktifkan USB debugging, lalu ulangi."
    echo "  Mau APK-nya saja tanpa tablet? Jalankan: ./redeploy.sh --build-only"
    exit 1
  fi
  echo "▶ Device: $DEV"
fi

# 2. Build release (split-per-abi, ringan). versionCode otomatis naik (timestamp).
echo "▶ Build release terbaru..."
flutter build apk --release --split-per-abi

# 2b. Tunjukkan identitas build (versionCode timestamp → unik tiap build).
#     Angka ini yang muncul di app → Pengaturan → Versi Aplikasi, jadi bisa
#     dipakai memastikan tablet benar-benar memakai APK yang baru dibuat.
META=build/app/outputs/apk/release/output-metadata.json
if [ -f "$META" ]; then
  echo "▶ Identitas build (unik per build):"
  python3 - "$META" <<'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
for e in meta.get("elements", []):
    abi = "".join(f.get("value", "") for f in e.get("filters", [])) or "universal"
    print(f'   {abi:<12} v{e.get("versionName")} (build {e.get("versionCode")})  {e.get("outputFile")}')
PYEOF
fi

# 3. Berhenti di sini bila hanya build (tanpa tablet).
if [ "$BUILD_ONLY" = 1 ]; then
  echo ""
  echo "✓ Build selesai. APK ada di build/app/outputs/flutter-apk/:"
  ls -lh build/app/outputs/flutter-apk/*-release.apk | awk '{print "   " $9 "  (" $5 ")"}'
  echo ""
  echo "  Pasang nanti saat tablet tersambung:"
  echo "    ./redeploy.sh                                   # build ulang + pasang"
  echo "    adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
  exit 0
fi

# 4. Pilih APK sesuai arsitektur tablet
ABI=$(adb -s "$DEV" shell getprop ro.product.cpu.abi | tr -d '\r')
case "$ABI" in
  arm64-v8a)   APK=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk ;;
  armeabi-v7a) APK=build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk ;;
  x86_64)      APK=build/app/outputs/flutter-apk/app-x86_64-release.apk ;;
  *)           APK=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk ;;
esac
echo "▶ Arsitektur tablet: $ABI → pasang $APK"

# 5. Pasang menimpa (-r): data transaksi & pengaturan TETAP utuh, kode diganti baru.
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
