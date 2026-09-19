# Spesifikasi Sinkron "Meja Titipan" (untuk sisi Cloud)

Dokumen ini menjelaskan data **Meja Titipan (parked check)** yang dikirim aplikasi
POS ke cloud, agar sisi cloud (server terpisah) bisa **menampung & menyesuaikan**.

> Ringkas untuk tim cloud — ada **2 perubahan**:
> 1. Entity sinkron **baru**: `order_item_titipan` (audit aksi titip/tarik).
> 2. Field **baru** pada payload `order`: `is_holding` (menandai order Meja Titipan).
>
> Void titipan tetap memakai entity `order_item_void` yang sudah ada (tak berubah).

---

## 0. Konteks singkat

"Meja Titipan" = **parked check**. Saat item dibatalkan dari meja tamu, kasir bisa
memilih **menitipkannya** (bukan void) ke satu order "Titipan" (belum dibayar) —
untuk dijual ke tamu berikutnya. Siklusnya:

```
Titip (park)  : item pindah  Meja tamu → Titipan   [PIN manajer]
Tarik (pull)  : item pindah  Titipan → Meja tamu
Void (waste)  : item titipan dibuang (tak layak)    [PIN manajer]
```

Semua auditable. Nilai titipan **tidak** masuk penjualan (order Titipan belum
dibayar) sampai ditarik ke bill tamu & dibayar.

---

## 1. Transport (sama seperti sync lain)

Semua audit dikirim lewat **BatchSync**:

```
POST {BASE_URL}/api/v1/outlets/{outletId}/sync/batch
Authorization: Bearer {API_KEY}
X-Outlet-ID: {outletId}
X-Outlet-Code: {outletCode}
```

Body:

```jsonc
{
  "outlet_id": "…",
  "outlet_code": "…",
  "sync_timestamp": "2026-07-10T04:00:00.000Z",
  "items": [
    { "entity_type": "order_item_titipan", "operation": "create", "data": { … } },
    { "entity_type": "order",              "operation": "upsert", "data": { … } }
  ]
}
```

Tiap perubahan = satu elemen `items[]` dengan `entity_type`, `operation`, dan `data`.

---

## 2. Entity BARU: `order_item_titipan`

Dikirim **setiap kali item dititip (park) atau ditarik (pull)**. `operation`
selalu `create` (event log, bukan mutasi state).

```jsonc
// items[].entity_type = "order_item_titipan", operation = "create"
"data": {
  "local_id": "01J…",           // id item (order_items.id)
  "action": "park",             // "park" (dititip) | "pull" (ditarik)
  "product_name": "Es Teh",
  "qty": 2,
  "price": 8000,
  "subtotal": 16000,
  "category_id": "01J…",        // boleh null
  "source_table": "5",          // asal   (park: meja tamu; pull: "Titipan")
  "target_table": "Titipan",    // tujuan (park: "Titipan"; pull: meja tamu)
  "by": "Budi (Manager)",       // authorizer PIN (park) / kasir (pull)
  "at": "2026-07-10T04:00:00.000Z"  // UTC
}
```

| Field | Tipe | Arti |
|---|---|---|
| `local_id` | string | ID item (`order_items.id`) yang dititip/ditarik |
| `action` | string | `park` = dititip, `pull` = ditarik |
| `product_name` | string | Nama produk |
| `qty` | integer | Jumlah |
| `price` | number | Harga satuan |
| `subtotal` | number | `qty × price` (nilai item) |
| `category_id` | string \| null | Kategori produk |
| `source_table` | string | Meja asal (untuk `pull` = `"Titipan"`) |
| `target_table` | string | Meja tujuan (untuk `park` = `"Titipan"`) |
| `by` | string | **Siapa** yang melakukan: authorizer manajer (park) / kasir (pull) |
| `at` | string (ISO-8601 UTC) | Waktu aksi |

**Saran penanganan cloud:** simpan sebagai baris log (append-only) di tabel mis.
`order_item_titipan_logs`. Berguna untuk laporan "kebocoran"/pengawasan: berapa
item dititip, oleh siapa, seberapa sering ditarik vs berakhir void.

Contoh DDL:

```sql
CREATE TABLE order_item_titipan_logs (
  id            BIGSERIAL PRIMARY KEY,
  outlet_id     TEXT NOT NULL,
  local_id      TEXT NOT NULL,        -- order_items.id
  action        TEXT NOT NULL,        -- 'park' | 'pull'
  product_name  TEXT,
  qty           INTEGER,
  price         NUMERIC,
  subtotal      NUMERIC,
  category_id   TEXT,
  source_table  TEXT,
  target_table  TEXT,
  performed_by  TEXT,                 -- data.by
  performed_at  TIMESTAMPTZ,          -- data.at
  created_at    TIMESTAMPTZ DEFAULT now()
);
```

---

## 3. Field BARU pada entity `order`: `is_holding`

Payload `order` (entity `order`, operation `upsert`) kini **bisa** memuat:

```jsonc
"data": {
  "local_id": "01J…",
  "table_number": "Titipan",   // order titipan memakai nomor meja "Titipan"
  "status": "served",
  "is_holding": true,          // ← BARU: hanya ADA bila order = Meja Titipan
  "total_amount": 16000,
  "payment_info": { "payment_status": "unpaid", … },
  "items": [ … ],
  …
}
```

| Field | Tipe | Arti |
|---|---|---|
| `is_holding` | boolean | `true` → order ini adalah **Meja Titipan** (parked check), **bukan** pesanan tamu aktif. **Hanya muncul saat true** (absen = order tamu biasa). |

**Saran penanganan cloud (penting):**
- **Kecualikan** order `is_holding = true` dari: daftar meja aktif, dashboard
  penjualan, laporan omzet — karena belum dibayar & bukan tamu nyata.
- Boleh ditampilkan terpisah sebagai "Titipan" bila ingin memantau barang
  menggantung.
- Order ini memakai `table_number = "Titipan"` (string, bukan angka) — jangan
  di-cast ke integer.

Contoh kolom:

```sql
ALTER TABLE orders ADD COLUMN is_holding BOOLEAN NOT NULL DEFAULT false;
```

---

## 4. Void titipan (tidak berubah)

Saat item titipan dibuang (waste, tak layak), aplikasi mengirim entity
**`order_item_void`** yang **sudah ada** — lengkap dengan `voided_by`, `void_reason`,
`voided_at`. Tidak ada perubahan; disebut di sini hanya agar siklusnya lengkap:
titip → tarik **atau** void.

---

## 5. Ringkasan yang perlu disesuaikan di cloud

1. **Terima & simpan** entity `order_item_titipan` (jangan tolak sebagai entity tak
   dikenal) → tabel log audit.
2. **Tambah kolom** `orders.is_holding` (boolean) + **kecualikan** dari laporan
   penjualan/meja aktif.
3. `table_number` order titipan = string `"Titipan"` — perlakukan sebagai teks.

Tanpa penyesuaian ini, data titip/tarik tetap terkirim tapi (a) event
`order_item_titipan` bisa tertolak/terabaikan, dan (b) order Titipan akan tampak
sebagai pesanan tamu biasa yang belum dibayar.
