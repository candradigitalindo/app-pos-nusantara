#!/usr/bin/env bash
# End-to-end pesanan online: server cloud SUNGGUHAN + POS Flutter.
#
# Menyiapkan Postgres, menjalankan server Go, menyemai satu outlet uji,
# lalu menjalankan test/online_order_e2e_test.dart terhadapnya. Seluruh
# jejaknya dibersihkan saat selesai — termasuk bila skrip dihentikan.
#
# Prasyarat: Postgres terpasang (mis. brew install postgresql@16) dan Go.
# Jalankan dari app-pos-flutter/:  tool/run_e2e.sh

set -euo pipefail

PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@16/bin}"
PGDATA="${PGDATA:-/opt/homebrew/var/postgresql@16}"
DB_NAME="${DB_NAME:-cloud_pos_e2e}"
PORT="${PORT:-4010}"
POS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLOUD_DIR="$(cd "$POS_DIR/../cloud-nusantara" && pwd)"
export PATH="$PGBIN:$PATH"

SERVER_PID=""
PG_DIMULAI=0
SERVER_BIN="/tmp/cloud_e2e_server"

bersihkan() {
  echo ""
  echo "── Membersihkan ──"
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  # Jaring pengaman: apa pun yang masih menahan port harus mati, kalau tidak
  # uji berikutnya bicara ke server basi tanpa sadar.
  lsof -ti ":$PORT" 2>/dev/null | xargs -r kill 2>/dev/null || true
  rm -f "$SERVER_BIN"
  sleep 1
  dropdb --if-exists "$DB_NAME" 2>/dev/null || true
  # Postgres hanya dimatikan bila SKRIP INI yang menyalakannya.
  if [ "$PG_DIMULAI" = "1" ]; then
    pg_ctl -D "$PGDATA" stop >/dev/null 2>&1 || true
  fi
}
trap bersihkan EXIT INT TERM

if lsof -ti ":$PORT" >/dev/null 2>&1; then
  echo "Port $PORT masih dipakai proses lain — hentikan dulu:"
  lsof -i ":$PORT" | tail -n +2
  exit 1
fi

echo "── Postgres ──"
if pg_isready -q 2>/dev/null; then
  echo "sudah jalan"
else
  pg_ctl -D "$PGDATA" -l /tmp/pg_e2e.log start >/dev/null
  PG_DIMULAI=1
  sleep 2
  echo "dinyalakan"
fi

dropdb --if-exists "$DB_NAME" 2>/dev/null || true
createdb "$DB_NAME"
echo "database $DB_NAME dibuat"

echo ""
echo "── Server cloud ──"
cd "$CLOUD_DIR"
# Dikompilasi dulu, BUKAN `go run`: go run menjalankan binernya sebagai proses
# anak, jadi membunuh go run meninggalkan server hidup menahan port sambil
# memegang database lama — dan uji berikutnya diam-diam bicara ke server basi.
go build -o "$SERVER_BIN" . || { echo "gagal build server"; exit 1; }
DB_NAME="$DB_NAME" DB_USER="${DB_USER:-postgres}" DB_PASSWORD="${DB_PASSWORD:-postgres}" \
  DB_HOST=localhost DB_PORT=5432 DB_SSLMODE=disable PORT="$PORT" \
  PAYMENT_GATEWAY_PROVIDER=mock QRIS_WEBHOOK_SECRET=uji-e2e \
  "$SERVER_BIN" > /tmp/cloud_e2e.log 2>&1 &
SERVER_PID=$!

for i in $(seq 1 40); do
  if curl -fsS "http://localhost:$PORT/api/v1/ping" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "server mati saat start:"; tail -25 /tmp/cloud_e2e.log; exit 1
  fi
  sleep 1
done
curl -fsS "http://localhost:$PORT/api/v1/ping" >/dev/null || {
  echo "server tidak merespons:"; tail -25 /tmp/cloud_e2e.log; exit 1; }
echo "siap di :$PORT"

echo ""
echo "── Menyemai outlet uji ──"
OUTLET_ID="01E2ETESTOUTLET00000000001"
PRODUCT_ID="01E2ETESTPRODUK00000000001"
ADDON_ID="01E2ETESTADDON00000000001A"
SLUG="e2e-uji"
API_KEY="e2e-api-key"

psql -q -d "$DB_NAME" <<SQL
INSERT INTO outlets (id, name, code, slug, api_key, is_active, created_at, updated_at)
VALUES ('$OUTLET_ID', 'Outlet E2E', 'E2E', '$SLUG', '$API_KEY', true,
        now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC');

-- Shift terbuka: tanpa ini pesanan online ditolak.
INSERT INTO cloud_cashier_shifts (id, local_id, outlet_id, opened_by, opened_at, opening_cash, status)
VALUES ('01E2ETESTSHIFT00000000001A', '01E2ETESTSHIFT00000000001A', '$OUTLET_ID',
        'Kasir E2E', now() AT TIME ZONE 'UTC', 0, 'open');

INSERT INTO cloud_products (id, local_id, outlet_id, name, price, updated_at)
VALUES ('$PRODUCT_ID', '$PRODUCT_ID', '$OUTLET_ID', 'Nasi Goreng', 25000,
        now() AT TIME ZONE 'UTC');

INSERT INTO cloud_product_addons (id, local_id, outlet_id, product_local_id, name, price, is_active)
VALUES ('$ADDON_ID', '$ADDON_ID', '$OUTLET_ID', '$PRODUCT_ID', 'Extra keju', 5000, true);

-- Pajak PB1 10% — harga akhir yang ditagihkan lewat QRIS ikut ini.
INSERT INTO cloud_additional_charges (id, local_id, outlet_id, name, charge_type, value, is_active)
VALUES ('01E2ETESTCHARGE00000000001', '01E2ETESTCHARGE00000000001', '$OUTLET_ID',
        'Pajak Restoran (PB1)', 'percentage', 10, true);
SQL
echo "outlet $SLUG siap (menu 25.000 + add-on 5.000, PB1 10%)"

echo ""
echo "── Menjalankan tes POS terhadap server ──"
cd "$POS_DIR"
E2E_CLOUD_URL="http://localhost:$PORT" \
E2E_SLUG="$SLUG" \
E2E_OUTLET_ID="$OUTLET_ID" \
E2E_API_KEY="$API_KEY" \
E2E_PRODUCT_ID="$PRODUCT_ID" \
E2E_ADDON_ID="$ADDON_ID" \
  flutter test test/online_order_e2e_test.dart
