# Spec: Endpoint Rekonsiliasi Transaksi (App POS ⇄ Cloud)

Tujuan: **mendeteksi dini transaksi yang ada di tablet tetapi TIDAK ada di
cloud** (silent loss), per shift/outlet. Melengkapi perbaikan penandaan sync
whitelist (App hanya menandai `synced` bila `data.results[].status=="success"`).

Diagnostik lokal (layar *Status Sinkronisasi*) hanya tahu apa yang **App**
tandai. Untuk memastikan data benar-benar ADA di cloud, App perlu bertanya ke
cloud lalu membandingkan. Dokumen ini mendefinisikan endpoint yang dibutuhkan.

Konvensi umum:
- Base URL & auth = SAMA dengan BatchSync: header `Authorization: Bearer <cloudApiKey>`,
  `X-Outlet-ID`, `X-Outlet-Code`, `Content-Type: application/json`.
- `local_id` transaksi = ULID 26 karakter (identitas kanonik lintas App↔Cloud).
- Semua waktu ISO-8601 UTC (`...Z`). App mengirim rentang dalam UTC.
- Uang: angka (rupiah, tanpa desimal) — samakan dengan payload BatchSync.

---

## 1) Ringkasan per shift/tanggal — `POST /api/v1/outlets/{outlet_id}/reconcile/summary`

Murah (bandwidth kecil): App kirim daftar shift + total lokalnya, cloud balas
total versinya. Dipakai untuk **menandai shift yang selisih** tanpa mengirim
seluruh ID.

### Request
```json
{
  "outlet_id": "outlet-abc",
  "outlet_code": "OUT001",
  "shifts": [
    { "shift_id": "01J...ULID", "opened_at": "2026-07-11T01:00:00Z",
      "closed_at": "2026-07-11T09:00:00Z",
      "local_count": 143, "local_total": 8231000 }
  ]
}
```
Jika `shift_id` tak dipakai, boleh pakai rentang tanggal:
`{ "ranges": [ { "date_from": "...Z", "date_to": "...Z", "local_count": N, "local_total": T } ] }`

### Response (selalu HTTP 200)
```json
{
  "success": true,
  "data": {
    "shifts": [
      {
        "shift_id": "01J...ULID",
        "cloud_count": 141,
        "cloud_total": 8100000,
        "count_diff": 2,          // local_count - cloud_count
        "total_diff": 131000,     // local_total - cloud_total
        "in_sync": false          // true bila count_diff==0 && total_diff==0
      }
    ]
  }
}
```
> Catatan: hitung transaksi cloud dengan aturan yang SAMA dengan
> `sales_total` App: hanya transaksi **tidak dibatalkan** (`cancelled_at IS NULL`),
> dalam jendela `[opened_at, closed_at)`.

---

## 2) Detail ID hilang — `POST /api/v1/outlets/{outlet_id}/reconcile/detail`

Untuk shift/rentang yang `in_sync:false`, App mengirim daftar `local_id` yang
ADA di tablet; cloud mengembalikan mana yang **tidak ditemukan** (hilang) dan
mana yang **beda nilai**. Dibatasi (mis. ≤ 1000 id per request) → App paginasi.

### Request
```json
{
  "outlet_id": "outlet-abc",
  "outlet_code": "OUT001",
  "transactions": [
    { "local_id": "01J...ULID", "total_amount": 57000 },
    { "local_id": "01J...ULID2", "total_amount": 12000 }
  ]
}
```

### Response (selalu HTTP 200)
```json
{
  "success": true,
  "data": {
    "missing": [ "01J...ULID" ],           // ada di App, TIDAK ada di cloud → HILANG
    "amount_mismatch": [                     // ada, tapi nilai beda
      { "local_id": "01J...ULID2", "cloud_amount": 10000, "local_amount": 12000 }
    ],
    "matched_count": 998                     // cocok sempurna
  }
}
```

---

## Cara App memakainya (alur rekonsiliasi)

1. Untuk tiap shift dalam N hari terakhir, App hitung `local_count/local_total`
   (query yang sama dengan laporan shift, exclude voided) → kirim ke **/summary**.
2. Shift dengan `in_sync:false` ditandai di layar *Status Sinkronisasi*
   ("Shift X: selisih Rp131.000 / 2 transaksi").
3. Untuk shift bermasalah, App ambil `local_id` transaksinya (batch ≤1000) →
   kirim ke **/detail** → dapat daftar `missing`.
4. `missing` = transaksi yang **hilang di cloud** → App bisa:
   - Menampilkannya (nilai + waktu + kasir) untuk audit, dan/atau
   - **Re-enqueue** ke outbox agar dikirim ulang (payload masih ada di lokal
     selama < retensi 90 hari). Ini memperbaiki transaksi lama yang telanjur
     ditandai "sukses palsu" sebelum perbaikan whitelist.

## Persyaratan konsistensi (penting untuk tim cloud)
- Aturan hitung cloud **HARUS identik** dengan App: exclude `cancelled_at IS NOT NULL`,
  jendela waktu `[opened_at, closed_at)`, dan pakai `local_id` (ULID) sebagai kunci.
- Kedua endpoint **read-only** & idempoten; boleh sering dipanggil (mis. saat buka
  layar Status Sync atau saat tutup shift).
- Batasi ukuran (`transactions` ≤ 1000/detail; `shifts` ≤ 200/summary) dan balas
  400 bila melebihi, agar App paginasi.

## Retensi
App menyimpan payload transaksi selama **90 hari** (retensi lokal). Rekonsiliasi
& re-enqueue hanya bisa untuk transaksi dalam jendela itu — di luar itu, payload
lokal sudah dipurge, jadi rekonsiliasi cukup melaporkan selisih (tanpa perbaikan
otomatis).
