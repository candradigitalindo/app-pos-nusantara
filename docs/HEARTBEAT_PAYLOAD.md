# Spesifikasi Payload Heartbeat (untuk sisi Cloud)

Dokumen ini menjelaskan payload **heartbeat** yang dikirim aplikasi POS (Flutter)
ke server cloud, khususnya **field baru CPU & RAM** yang perlu ditampung/disimpan
di sisi cloud.

> Ringkas untuk tim cloud: tambahkan penampung untuk field di bagian
> [**Field baru — CPU & RAM**](#field-baru--cpu--ram). Field lama tetap sama.
> Semua field CPU/RAM berada di dalam objek `device`.

---

## 1. Endpoint

```
POST {BASE_URL}/api/v1/outlets/{outletId}/heartbeat
```

Header:

| Header | Nilai |
|---|---|
| `Content-Type` | `application/json` |
| `Authorization` | `Bearer {API_KEY}` |
| `X-Outlet-ID` | `{outletId}` |
| `X-Outlet-Code` | `{outletCode}` |

Frekuensi: dikirim tiap siklus sinkron (mengikuti interval sync outlet, default
tiap beberapa menit). Kegagalan heartbeat **tidak** memengaruhi sinkron data —
murni telemetri, tidak di-retry.

---

## 2. Struktur payload lengkap

```jsonc
{
  "device": {
    "app_version": "1.2.0+3",
    "battery": 87,                 // 0..100 (persen)
    "battery_state": "charging",   // charging | full | discharging | unknown

    // ↓ Android saja (via native channel)
    "model": "Samsung SM-T500",
    "os": "Android 13 (SDK 33)",
    "storage_total_mb": 63488,
    "storage_free_mb": 24170,

    // ↓ FIELD BARU — kondisi RAM (Android, selalu ada)
    "ram_total_mb": 3840,
    "ram_free_mb": 1180,
    "ram_used_percent": 69,
    "ram_low": false,

    // ↓ FIELD BARU — kondisi CPU (Android)
    "cpu_cores": 8,
    "cpu_used_percent": 23.5,       // best-effort, bisa TIDAK ADA
    "cpu_load_1m": 1.42,            // best-effort, bisa TIDAK ADA
    "cpu_load_5m": 1.10,           // best-effort, bisa TIDAK ADA
    "cpu_load_15m": 0.98           // best-effort, bisa TIDAK ADA
  },

  "printers": [
    {
      "name": "Kasir 80mm",
      "address": "192.168.1.50:9100",
      "ip": "192.168.1.50",       // hanya untuk LAN
      "type": "lan",              // lan | bluetooth
      "roles": "Kasir",
      "connected": true,
      "online": true              // alias kompatibilitas dari `connected`
    }
  ],

  "network": {
    "online": true,
    "pending_sync": 0,
    "last_sync_at": "2026-07-05T00:24:11.000Z"   // opsional
  },

  "reported_at": "2026-07-05T00:24:12.345Z"
}
```

---

## 3. Field baru — CPU & RAM

Semua di dalam objek **`device`**.

### RAM (selalu terkirim di Android)

| Field | Tipe | Satuan / Rentang | Arti |
|---|---|---|---|
| `ram_total_mb` | integer | MB | Total RAM fisik perangkat |
| `ram_free_mb` | integer | MB | RAM yang masih tersedia |
| `ram_used_percent` | integer | 0–100 | Persentase RAM terpakai = `(total-free)/total×100` |
| `ram_low` | boolean | — | `true` bila sistem dalam kondisi memori kritis (Android `lowMemory`) |

### CPU

| Field | Tipe | Satuan / Rentang | Arti | Selalu ada? |
|---|---|---|---|---|
| `cpu_cores` | integer | — | Jumlah core CPU (logis) | Ya (Android) |
| `cpu_used_percent` | number (desimal) | 0–100 | %CPU rata-rata selama ±300ms sampling di heartbeat itu | Ya (Android)¹ |
| `cpu_source` | string | `system` \| `app` | Sumber angka CPU: `system` = seluruh perangkat (`/proc/stat`); `app` = proses POS saja (fallback bila `/proc/stat` diblok SELinux) | Menyertai `cpu_used_percent` |
| `cpu_load_1m` | number (desimal) | ≥ 0 | Load average 1 menit | **Best-effort** |
| `cpu_load_5m` | number (desimal) | ≥ 0 | Load average 5 menit | **Best-effort** |
| `cpu_load_15m` | number (desimal) | ≥ 0 | Load average 15 menit | **Best-effort** |

> ¹ `cpu_used_percent` dihitung dari **dua sampling berjarak ±300ms dalam satu
> heartbeat** (bukan selisih antar-heartbeat), jadi **selalu ada tiap heartbeat**
> — termasuk heartbeat pertama. Utamakan `/proc/stat` (CPU sistem, `cpu_source=system`);
> bila diblok SELinux (Android 8+), fallback ke `/proc/self/stat` (CPU proses
> app, `cpu_source=app`) yang selalu terbaca. Perhatikan: saat `cpu_source=app`,
> angka mencerminkan beban aplikasi POS saja, bukan seluruh perangkat.
>
> **Best-effort** = bisa **tidak muncul** di payload:
> - `cpu_load_*`: pada Android 8+ `/proc/loadavg` kadang diblok SELinux → field
>   dilewati, tetapi `cpu_cores`, `cpu_used_percent`, & RAM **tetap** terkirim.
>
> Sisi cloud **wajib memperlakukan field CPU sebagai nullable/opsional**
> (jangan asumsikan selalu ada).

---

## 4. Catatan platform

- Field `ram_*`, `cpu_*`, `storage_*`, `model`, `os` berasal dari native channel
  dan **hanya terkirim di Android** (perangkat POS produksi).
- Di **iOS / desktop**, field tersebut tidak dikirim (payload tetap valid; hanya
  `app_version`, `battery`, `printers`, `network`, `reported_at` yang ada).
- `battery` & `battery_state` lintas-platform (Android + iOS).

Konsekuensi untuk cloud: **semua field di `device` selain `app_version` harus
diperlakukan opsional.**

---

## 5. Saran penyimpanan di cloud (opsional)

Bila ingin menyimpan sebagai kolom (bukan blob JSON), contoh penambahan kolom
pada tabel snapshot heartbeat perangkat:

```sql
ALTER TABLE device_heartbeats ADD COLUMN ram_total_mb     INTEGER NULL;
ALTER TABLE device_heartbeats ADD COLUMN ram_free_mb      INTEGER NULL;
ALTER TABLE device_heartbeats ADD COLUMN ram_used_percent INTEGER NULL;
ALTER TABLE device_heartbeats ADD COLUMN ram_low          BOOLEAN NULL;
ALTER TABLE device_heartbeats ADD COLUMN cpu_cores        INTEGER NULL;
ALTER TABLE device_heartbeats ADD COLUMN cpu_used_percent REAL    NULL;  -- 0..100
ALTER TABLE device_heartbeats ADD COLUMN cpu_load_1m      REAL    NULL;
ALTER TABLE device_heartbeats ADD COLUMN cpu_load_5m      REAL    NULL;
ALTER TABLE device_heartbeats ADD COLUMN cpu_load_15m     REAL    NULL;
```

Contoh struct Go (parsing longgar, semua pointer agar nullable):

```go
type HeartbeatDevice struct {
    AppVersion   string   `json:"app_version"`
    Battery      *int     `json:"battery"`
    BatteryState *string  `json:"battery_state"`

    Model         *string `json:"model"`
    OS            *string `json:"os"`
    StorageTotalMB *int   `json:"storage_total_mb"`
    StorageFreeMB  *int   `json:"storage_free_mb"`

    // Baru — RAM
    RamTotalMB     *int   `json:"ram_total_mb"`
    RamFreeMB      *int   `json:"ram_free_mb"`
    RamUsedPercent *int   `json:"ram_used_percent"`
    RamLow         *bool  `json:"ram_low"`

    // Baru — CPU (best-effort → pointer)
    CPUCores       *int     `json:"cpu_cores"`
    CPUUsedPercent *float64 `json:"cpu_used_percent"`
    CPULoad1m      *float64 `json:"cpu_load_1m"`
    CPULoad5m      *float64 `json:"cpu_load_5m"`
    CPULoad15m     *float64 `json:"cpu_load_15m"`
}
```

Ambang saran untuk indikator/alert di dashboard:

| Indikator | Kuning | Merah |
|---|---|---|
| `ram_used_percent` | ≥ 80% | ≥ 90% atau `ram_low = true` |
| `cpu_used_percent` | ≥ 75% | ≥ 90% |
| `storage_free_mb` | ≤ 2048 (2 GB) | ≤ 512 (0.5 GB) |
| `battery` | ≤ 20% | ≤ 10% (dan `battery_state ≠ charging`) |
