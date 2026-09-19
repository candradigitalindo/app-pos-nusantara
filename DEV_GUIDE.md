# POS Resto Flutter — Panduan Pengembangan Lengkap

> Dokumen referensi untuk pengembangan aplikasi Flutter POS Resto.
> Dibuat berdasarkan analisis mendalam terhadap Go backend (`app-pos`).

---

## Quick Context (untuk AI Assistant)

```
TEKNOLOGI: Flutter + SQLite (offline-first) + Go backend (REST API)
BACKEND: app-pos (Go/Echo) — Flutter BERKOMUNIKASI via REST, bukan langsung ke DB
ARCHITECTURE: Flutter → REST API → Go Backend → SQLite
SYNC: Cloud sync optional (outbox pattern via sync_queue)
PRINTING: TCP socket ke thermal printer (ESC/POS)
REAL-TIME: SSE events dari Go backend
AUTH: JWT token, PIN 4-digit untuk manager actions

DATABASE: 23 tabel SQLite di Go backend (Flutter tidak akses langsung)
  Core: users, customers, tables, categories, products, orders, order_items
  Charges: additional_charges, order_additional_charges
  Payment: payments, transactions, transaction_items
  Printer: printers, print_queue
  Shift: cashier_shifts, cashier_cash_movements
  Sync: sync_queue, sync_logs, outlet_config, entity_versions, registered_devices
  Extras: product_notes, product_addons

ID FORMAT: ULID 26 karakter (text string)
CURRENCY: Rupiah (int/real, tanpa desimal)
ROLES: admin, cashier, manager, waiter, kitchen, bar
ORDER STATUS: cooking → ready → served
PAYMENT STATUS: unpaid → partial → paid
ITEM STATUS: pending → cooking → ready → served
```

---

## Daftar Isi

1. [Arsitektur Sistem](#1-arsitektur-sistem)
2. [Database Schema Lengkap](#2-database-schema-lengkap)
3. [Alur Transaksi End-to-End](#3-alur-transaksi-end-to-end)
4. [Sistem Antrian Printer](#4-sistem-antrian-printer)
5. [Cloud Sync](#5-cloud-sync)
6. [API Contracts (Backend → Flutter)](#6-api-contracts-backend--flutter)
7. [Struktur Flutter Project](#7-struktur-flutter-project)
8. [Implementasi per Layer](#8-implementasi-per-layer)
9. [Real-time Events (SSE)](#9-real-time-events-sse)
10. [Shift Kasir & Cash Movements](#10-shift-kasir--cash-movements)
11. [Checklist Implementasi](#11-checklist-implementasi)
12. [Additional Charges & Pajak Restoran (Cloud-Synced)](#12-additional-charges--pajak-restoran-cloud-synced)

---

## 1. Arsitektur Sistem

```
┌─────────────────────────────────────────────────────┐
│                  FLUTTER APP (Tablet)                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐ │
│  │  Kasir   │ │  Waiter  │ │  Dapur   │ │Setting │ │
│  │  Screen  │ │  Screen  │ │  Screen  │ │ Screen │ │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └───┬────┘ │
│       │             │             │            │      │
│  ┌────▼─────────────▼─────────────▼────────────▼──┐  │
│  │           REPOSITORY LAYER (SQLite)             │  │
│  └────┬─────────────┬─────────────┬───────────────┘  │
│       │             │             │                   │
│  ┌────▼────┐  ┌─────▼─────┐  ┌───▼──────┐          │
│  │Database │  │  Print     │  │  Sync    │          │
│  │(SQLite) │  │  Worker    │  │  Worker  │          │
│  └─────────┘  └─────┬─────┘  └────┬─────┘          │
│                     │             │                   │
└─────────────────────┼─────────────┼───────────────────┘
                      │             │
          ┌───────────▼──┐    ┌─────▼──────────┐
          │  THERMAL      │    │  CLOUD API     │
          │  PRINTER      │    │  (REST)        │
          │  (TCP/ESC-POS)│    │                │
          └──────────────┘    └────────────────┘
```

### Prinsip Utama
- **Offline-first**: Semua data tersimpan di SQLite lokal
- **Fire-and-forget printing**: Print job masuk antrian, diproses background
- **Eventual consistency**: Sync ke cloud secara periodik (bisa diatur interval)
- **Single-device**: Satu tablet = satu instance (tidak pernah concurrent write)

---

## 2. Database Schema Lengkap

### 2.1 Users
```sql
CREATE TABLE users (
    id TEXT PRIMARY KEY,           -- ULID 26 chars
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,    -- bcrypt hash
    full_name TEXT NOT NULL,
    role TEXT NOT NULL,             -- 'admin', 'waiter', 'kitchen', 'bar', 'cashier', 'manager'
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.2 Categories
```sql
CREATE TABLE categories (
    id TEXT PRIMARY KEY CHECK (length(id) = 26),  -- ULID
    name TEXT NOT NULL UNIQUE,
    description TEXT,                             -- Deskripsi kategori (optional)
    printer_id TEXT,                              -- FK ke printers, auto-assign by category
    is_deleted INTEGER NOT NULL DEFAULT 0,        -- Soft delete
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (printer_id) REFERENCES printers(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_categories_printer_id ON categories(printer_id);
```

> **Catatan:** Cloud sync tracking (version, sync_status) ditangani oleh tabel terpisah `entity_versions` (lihat 2.20).

### 2.3 Products
```sql
CREATE TABLE products (
    id TEXT PRIMARY KEY CHECK (length(id) = 26),  -- ULID
    name TEXT NOT NULL,
    code TEXT UNIQUE,                             -- Kode produk (barcode/sku)
    description TEXT,
    price REAL NOT NULL,
    stock INTEGER NOT NULL DEFAULT 0,
    category_id TEXT,                             -- FK ke categories
    is_deleted INTEGER NOT NULL DEFAULT 0,        -- Soft delete
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_products_category_id ON products(category_id);
CREATE INDEX IF NOT EXISTS idx_products_name ON products(name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_code ON products(code);
```

> **Catatan:** Cloud sync tracking (version, sync_status) ditangani oleh tabel terpisah `entity_versions` (lihat 2.20).

### 2.4 Tables (Restoran)
```sql
CREATE TABLE tables (
    id TEXT PRIMARY KEY,
    table_number TEXT NOT NULL UNIQUE,
    capacity INTEGER NOT NULL DEFAULT 4,
    status TEXT NOT NULL DEFAULT 'available',  -- 'available', 'occupied', 'reserved'
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.5 Customers
```sql
CREATE TABLE customers (
    id TEXT PRIMARY KEY CHECK (length(id) = 26),  -- ULID
    name TEXT NOT NULL,
    phone TEXT NOT NULL UNIQUE,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone);
```

### 2.6 Orders
```sql
CREATE TABLE orders (
    id TEXT PRIMARY KEY,
    table_number TEXT NOT NULL,
    customer_name TEXT,
    customer_phone TEXT,
    customer_id TEXT,                             -- FK ke customers
    pax INTEGER NOT NULL DEFAULT 1 CHECK (pax > 0),
    basket_size INTEGER NOT NULL DEFAULT 0 CHECK (basket_size >= 0),
    total_amount REAL NOT NULL,
    paid_amount REAL NOT NULL DEFAULT 0,
    order_status TEXT NOT NULL DEFAULT 'cooking'
        CHECK (order_status IN ('cooking', 'ready', 'served')),
    created_by TEXT,                              -- FK ke users.id
    payment_status TEXT NOT NULL DEFAULT 'unpaid'
        CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
    merged_from TEXT,                             -- ID order sumber merge
    is_merged INTEGER NOT NULL DEFAULT 0,
    voided_at DATETIME,
    voided_by TEXT,
    void_reason TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at);
CREATE INDEX IF NOT EXISTS idx_orders_table_number ON orders(table_number);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(order_status, payment_status);
```

> **Catatan:** `waiter_name` ada di `order_items`, BUKAN di tabel orders.

### 2.7 Order Items
```sql
CREATE TABLE order_items (
    id TEXT PRIMARY KEY,
    order_id TEXT NOT NULL,
    product_name TEXT NOT NULL,     -- Denormalized dari product
    qty INTEGER NOT NULL CHECK (qty > 0),
    price REAL NOT NULL,
    destination TEXT NOT NULL DEFAULT 'kitchen', -- 'kitchen' atau 'bar'
    item_status TEXT NOT NULL DEFAULT 'pending', -- 'pending','cooking','ready','served'
    notes TEXT NOT NULL DEFAULT '',              -- Catatan item (e.g. "pedas")
    addons TEXT NOT NULL DEFAULT '',             -- Addon items (comma-separated atau JSON)
    waiter_name TEXT NOT NULL DEFAULT '',        -- Nama waiter yang ambil order
    is_additional INTEGER NOT NULL DEFAULT 0,    -- Item tambahan (bukan order baru)
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL,
    FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_order_items_status ON order_items(item_status);
```

### 2.8 Order Additional Charges (Diskon/Pajak)
```sql
CREATE TABLE order_additional_charges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id TEXT NOT NULL,
    charge_id INTEGER,             -- FK ke additional_charges (nullable = diskon manual)
    name TEXT NOT NULL,             -- Nama charge (e.g. "Pajak Restoran", "Diskon 10%")
    charge_type TEXT NOT NULL,     -- 'percentage' atau 'fixed'
    value REAL NOT NULL,           -- Nilai (10 = 10% atau 50000 = Rp50.000)
    applied_amount REAL NOT NULL,  -- Jumlah aktual yang dikenakan
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.9 Additional Charges (Master)
```sql
CREATE TABLE additional_charges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    outlet_id TEXT,
    name TEXT NOT NULL,
    charge_type TEXT NOT NULL,      -- 'percentage' atau 'fixed'
    value REAL NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.10 Payments
```sql
CREATE TABLE payments (
    id TEXT PRIMARY KEY,
    order_id TEXT NOT NULL,
    amount REAL NOT NULL,
    payment_method TEXT NOT NULL,   -- 'cash', 'card', 'qris', 'transfer'
    payment_note TEXT,
    created_by TEXT NOT NULL,
    created_at DATETIME NOT NULL
);
```

### 2.11 Transactions
```sql
CREATE TABLE transactions (
    id TEXT PRIMARY KEY,
    order_id TEXT NOT NULL DEFAULT '',
    total_amount REAL NOT NULL,
    payment_method TEXT NOT NULL,
    status TEXT NOT NULL,           -- 'completed', 'cancelled'
    transaction_date DATETIME NOT NULL,
    created_by TEXT,
    cancelled_at DATETIME,
    cancelled_by TEXT,
    cancel_reason TEXT,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.12 Transaction Items
```sql
CREATE TABLE transaction_items (
    id TEXT PRIMARY KEY,
    transaction_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    price REAL NOT NULL
);
```

### 2.13 Printers
```sql
CREATE TABLE printers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    ip_address TEXT NOT NULL,
    port INTEGER NOT NULL DEFAULT 9100,
    printer_type TEXT NOT NULL,     -- 'kitchen', 'bar', 'cashier', 'checker', 'struk'
    paper_size TEXT NOT NULL DEFAULT '80mm', -- '58mm' atau '80mm'
    -- Optional Settings
    connection_timeout INTEGER DEFAULT 3,
    write_timeout INTEGER DEFAULT 5,
    retry_attempts INTEGER DEFAULT 2,
    print_density INTEGER DEFAULT 50,
    print_speed TEXT DEFAULT 'normal',
    cut_mode TEXT DEFAULT 'partial',
    enable_beep INTEGER DEFAULT 1,
    auto_cut INTEGER DEFAULT 1,
    charset TEXT DEFAULT 'latin',
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.14 Print Queue (Antrian Cetak)
```sql
CREATE TABLE print_queue (
    id TEXT PRIMARY KEY,
    printer_id TEXT NOT NULL,
    data TEXT NOT NULL,             -- JSON PrintJobData
    status TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'done', 'failed'
    retry_count INTEGER NOT NULL DEFAULT 0,
    error_message TEXT,
    locked_at DATETIME,             -- Lock untuk claim job
    locked_by TEXT,                 -- Worker ID yang memproses
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.15 Cashier Shifts
```sql
CREATE TABLE cashier_shifts (
    id TEXT PRIMARY KEY,
    opened_by TEXT NOT NULL,
    opened_at DATETIME NOT NULL,
    opening_cash REAL NOT NULL DEFAULT 0,
    closed_at DATETIME,
    closed_by TEXT,
    closing_cash REAL,
    closing_card REAL,
    closing_qris REAL,
    closing_transfer REAL,
    carry_over_cash REAL,
    previous_shift_id TEXT,
    handover_to TEXT,
    status TEXT NOT NULL DEFAULT 'open', -- 'open', 'closed'
    notes TEXT,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.16 Cashier Cash Movements
```sql
CREATE TABLE cashier_cash_movements (
    id TEXT PRIMARY KEY,
    shift_id TEXT NOT NULL,
    movement_type TEXT NOT NULL,    -- 'in' atau 'out'
    amount REAL NOT NULL,
    counterpart_name TEXT NOT NULL, -- Nama pemberi/penerima
    note TEXT NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL
);
```

### 2.17 Sync Queue
```sql
CREATE TABLE sync_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL,      -- 'order', 'transaction', 'product', 'category'
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL,        -- 'create', 'update', 'delete'
    payload TEXT NOT NULL,          -- JSON data entity
    status TEXT NOT NULL DEFAULT 'pending', -- 'pending','processing','success','failed','bundled'
    retry_count INTEGER NOT NULL DEFAULT 0,
    max_retries INTEGER NOT NULL DEFAULT 3,
    error_message TEXT,
    created_at DATETIME NOT NULL,
    processed_at DATETIME,
    synced_at DATETIME
);
```

### 2.18 Sync Logs
```sql
CREATE TABLE sync_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sync_type TEXT NOT NULL,        -- 'push', 'pull'
    entity_type TEXT,
    entity_count INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL,           -- 'success','partial','failed','skipped'
    error_message TEXT,
    started_at DATETIME NOT NULL,
    completed_at DATETIME,
    duration_ms INTEGER,
    details TEXT                    -- JSON
);
```

### 2.19 Outlet Config
```sql
CREATE TABLE outlet_config (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    outlet_id TEXT,
    outlet_name TEXT,
    outlet_code TEXT,
    outlet_address TEXT,
    outlet_phone TEXT,
    receipt_footer TEXT,
    social_media TEXT,
    target_spend_per_pax INTEGER DEFAULT 0,
    cloud_api_url TEXT,
    cloud_api_key TEXT,
    is_active INTEGER DEFAULT 1,
    sync_enabled INTEGER DEFAULT 0,
    sync_interval_minutes INTEGER DEFAULT 5,
    data_retention_days INTEGER NOT NULL DEFAULT 0,  -- 0 = tidak ada retensi
    last_sync_at DATETIME,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

### 2.20 Entity Versions (Conflict Resolution)
```sql
CREATE TABLE entity_versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL,      -- 'product', 'category', 'order', dll.
    entity_id TEXT NOT NULL,
    version INTEGER DEFAULT 1,      -- Local version counter
    cloud_version INTEGER DEFAULT 0,-- Version terakhir dari cloud
    last_modified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_synced_at TIMESTAMP,
    sync_status TEXT DEFAULT 'pending', -- 'pending','synced','conflict'
    UNIQUE(entity_type, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_entity_versions_sync ON entity_versions(sync_status);
```

### 2.21 Registered Devices (LAN)
```sql
CREATE TABLE registered_devices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL UNIQUE,
    device_name TEXT NOT NULL,
    device_type TEXT NOT NULL DEFAULT 'tablet', -- 'tablet', 'phone', 'desktop'
    ip_address TEXT NOT NULL,
    user_agent TEXT DEFAULT '',
    is_active INTEGER DEFAULT 1,
    last_seen_at DATETIME,
    registered_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    registered_by TEXT
);
```

### 2.22 Product Notes (Special Request Suggestions)
```sql
CREATE TABLE product_notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id TEXT NOT NULL,        -- FK ke products
    note TEXT NOT NULL,              -- Isi catatan (e.g. "Pedas", "Tanpa MSG")
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
);
```

> **Catatan:** Product notes adalah saran catatan yang bisa dipilih saat order (bukan catatan actual order, itu ada di `order_items.notes`).

### 2.23 Product Addons (Additional Items with Prices)
```sql
CREATE TABLE product_addons (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id TEXT NOT NULL,        -- FK ke products
    name TEXT NOT NULL,              -- Nama addon (e.g. "Extra Keju", "Telur Mata")
    price REAL NOT NULL DEFAULT 0,   -- Harga tambahan
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
);
```

---

## 3. Alur Transaksi End-to-End

### 3.1 Buat Order Baru (Kasir/Waiter)

```
User tap "Buat Order"
    │
    ▼
[1] Pilih Meja → Set Pax → Pilih Produk
    │
    ▼
[2] POST /api/orders
    Body: {
        table_number: "A1",
        customer_name: "John",      // optional
        customer_phone: "081234",   // optional, auto-register jika baru
        pax: 4,
        items: [
            { product_id: "01HXYZ", qty: 2, notes: "pedas" },
            { product_id: "01HABC", qty: 1 }
        ],
        waiter_name: "Budi"         // optional
    }
    │
    ▼
[3] Backend memproses:
    a. Buat record orders (status=cooking, payment_status=unpaid)
    b. Buat record order_items (dari product_id → lookup product name & price)
    c. Setiap item di-assign destination: 'kitchen' atau 'bar'
       (berdasarkan category → printer assignment)
    d. Update table status → 'occupied'
    e. **Enqueue print jobs**:
       - Kitchen/bar printer: cetak order items (hanya item miliknya)
       - Checker printer: cetak semua items (verifikasi)
    f. Enqueue sync_queue untuk order (push ke cloud nanti)
    g. Emit SSE event "order_created"
    │
    ▼
[4] Response: { order_id: "01J..." }
```

### 3.2 Tambah Item ke Order yang Sudah Ada

```
[1] POST /api/orders/{id}/items
    Body: {
        items: [{ product_id: "01H...", qty: 1 }],
        waiter_name: "Budi"
    }
    │
    ▼
[2] Backend:
    a. Validasi order masih aktif (belum paid/voided)
    b. Tambah order_items baru (is_additional = 1)
    c. Recalculate order total_amount
    d. Enqueue print jobs untuk item baru ke kitchen/bar/checker
    e. Enqueue sync (operation: "upsert")
    f. Emit SSE "order_items_updated"
```

### 3.3 Update Status Item (Dapur/Bar)

```
[1] PATCH /api/orders/items/{item_id}/status
    Body: { status: "cooking" }  // pending → cooking → ready → served
    │
    ▼
[2] Backend:
    a. Update item_status
    b. Check apakah semua item sudah "served" → update order_status = "ready"
    c. Enqueue sync
    d. Emit SSE "item_status_updated"
```

### 3.4 Proses Pembayaran (Full Payment)

```
[1] POST /api/orders/{id}/payment
    Body: {
        payment_method: "cash",     // cash, card, qris, transfer
        paid_amount: 150000         // harus >= remaining
    }
    │
    ▼
[2] Backend memproses SECARA BERURUTAN:
    a. ✅ Validasi shift kasir aktif (harus ada open shift)
    b. ✅ Ambil detail order, hitung remaining = total_amount - paid_amount
    c. ✅ Validasi paid_amount >= remaining
    d. ✅ Hitung change = paid_amount - remaining
    e. ✅ Update order: payment_status = "paid", paid_amount = total
    f. ✅ Update order_status = "served"
    g. ✅ Update table status → "available" (termasuk merged tables)
    h. ✅ Buat record transactions (status=completed)
    i. ✅ Enqueue struk receipt ke printer cashier/struk
    j. ✅ Enqueue sync untuk order + transaction
    k. ✅ Emit SSE "payment_completed" + "table_status_updated"
    │
    ▼
[3] Response:
    {
        order_id, total_amount, remaining, original_total,
        paid_amount, payment_status, payments[]
    }
```

### 3.5 Split Bill Payment

```
[1] POST /api/orders/{id}/split-payment
    Body: {
        amount: 50000,
        payment_method: "cash",
        note: "Bagian 1 dari 3",
        items: [                    // Optional: split by items
            { item_id: "01H...", qty: 1 }
        ]
    }
    │
    ▼
[2] Backend:
    a. Buat record payments (partial payment)
    b. Update order paid_amount (akumulasi)
    c. Jika paid_amount >= total_amount:
       - payment_status = "paid"
       - Proses seperti full payment
    d. Jika belum lunas: payment_status = "partial"
    e. Enqueue split receipt ke printer
    f. Enqueue sync
    │
    ▼
[3] Bisa panggil berkali-kali sampai lunas
```

### 3.6 Void Order

```
[1] POST /api/orders/{id}/void
    Body: {
        manager_pin: "1234",     // PIN 4 digit manager
        reason: "Salah pesan"
    }
    │
    ▼
[2] Backend:
    a. Validasi PIN manager (bcrypt compare)
    b. Validasi order belum paid/voided
    c. Set voided_at, voided_by, void_reason
    d. Update table status → "available"
    e. Enqueue sync
    f. Emit SSE "order_voided" + "table_status_updated"
```

### 3.7 Compliment Order

```
[1] POST /api/orders/{id}/compliment
    │
    ▼
[2] Backend:
    a. Set total_amount = 0 (diskon 100%)
    b. ProcessPayment (payment_status = paid)
    c. UpdateOrderStatus = served
    d. Update table → available
    e. Buat transaction (amount=0, method=compliment)
    f. Enqueue compliment receipt ke printer
    g. Enqueue sync
    h. Emit SSE events
```

### 3.8 Merge Tables

```
[1] POST /api/orders/merge
    Body: {
        source_order_ids: ["order_id_1", "order_id_2"],
        target_table_number: "A5"
    }
    │
    ▼
[2] Backend:
    a. Gabungkan semua items ke target order
    b. Recalculate total_amount
    c. Set merged_from, is_merged
    d. Void source orders
    e. Update table statuses
    f. Enqueue kitchen/bar receipts untuk items pindah
    g. Enqueue sync
    h. Emit SSE events
```

### 3.9 Move Order to Different Table

```
[1] POST /api/orders/{id}/move
    Body: {
        new_table_number: "B3",
        waiter_name: "Budi"
    }
    │
    ▼
[2] Backend:
    a. Update order table_number
    b. Update old table → available, new table → occupied
    c. Enqueue move-table notice ke kitchen/bar/checker printers
    d. Enqueue sync
    e. Emit SSE events
```

### 3.10 Apply Discount

```
[1] POST /api/orders/{id}/discount
    Body: {
        charge_type: "percentage",   // atau "fixed"
        value: 10                    // 10% atau nominal fixed
    }
    │
    ▼
[2] Backend:
    a. Hitung applied_amount
    b. Buat order_additional_charges record
    c. Recalculate order total_amount
    d. Enqueue sync
    e. Emit SSE "order_items_updated"
```

---

## 4. Sistem Antrian Printer

### 4.1 Arsitektur

```
Order Created / Payment / etc
        │
        ▼
   Enqueue Print Jobs (INSERT INTO print_queue)
        │
        │  ┌───────────────────────────────────┐
        │  │       PRINT WORKER (background)    │
        │  │   Poll setiap 2 detik              │
        │  │   1. Release stale locks (>5min)   │
        │  │   2. Claim pending jobs            │
        │  │   3. Process: parse JSON → format  │
        │  │   4. Send via TCP socket           │
        │  │   5. Mark done / retry on failure  │
        │  └───────────────────────────────────┘
        │
        ▼
   Thermal Printer (ESC/POS via TCP)
```

### 4.2 Tipe Printer & Fungsinya

| Tipe | Fungsi | Format Cetak |
|------|--------|-------------|
| `kitchen` | Cetak order item makanan | Kitchen order (nama produk + qty, tanpa harga) |
| `bar` | Cetak order item minuman | Kitchen order (sama seperti kitchen) |
| `checker` | Verifikasi order lengkap | Checker order (semua item, tanpa harga, tanda additional) |
| `cashier` | Struk pembayaran | Receipt lengkap (items + harga + pajak + total) |
| `struk` | Struk pembayaran (utama) | Receipt lengkap (prioritas lebih tinggi dari cashier) |

### 4.3 PrintJobData (JSON di print_queue.data)

```dart
class PrintJobData {
  String orderId;
  String? retryOf;
  String receiptNumber;           // "TRX-{orderID}" atau "COMP-{orderID}"
  String tableNumber;
  String? oldTableNumber;         // Untuk move table
  String customerName;
  String waiterName;
  String cashierName;
  List<ReceiptItem> items;
  int subtotal;                   // Dalam Rupiah (integer)
  int additionalChargesTotal;
  List<ReceiptCharge> additionalCharges;
  int tax;
  int total;
  String paymentMethod;           // cash, card, qris, transfer, compliment
  int paidAmount;
  int changeAmount;
  DateTime dateTime;
  
  // Flags untuk tipe cetakan
  bool isBill;                    // Cetak bill (belum bayar)
  bool isSplitPayment;            // Cetak split receipt
  bool isHandover;                // Cetak serah terima shift
  bool isCloseShift;              // Cetak tutup shift
  bool isCashInReceipt;           // Cetak kas masuk
  bool isCashOutReceipt;          // Cetak kas keluar
  bool isMoveTable;               // Cetak pindah meja
  
  // Handover/Close Shift data
  String handoverFrom;
  String handoverTo;
  double openingCash;
  double closingCash;
  double closingCard;
  double closingQris;
  double closingTransfer;
  int voidedCount;
  double voidedTotal;
  int cancelledCount;
  double cancelledTotal;
  List<CashMovementData> cashIns;
  List<CashMovementData> cashOuts;
  
  int pax;
}

class ReceiptItem {
  String name;
  int quantity;
  int price;
  int total;
}

class ReceiptCharge {
  String name;
  int amount;
}

class CashMovementData {
  String name;
  int amount;
}
```

### 4.4 Alur Enqueue Print Jobs

#### Saat Buat Order Baru:
```
Untuk setiap printer aktif:
  - kitchen printer → cetak items dengan destination='kitchen'
  - bar printer → cetak items dengan destination='bar'
  - checker printer → cetak semua items
```

#### Saat Pembayaran:
```
  - cashier/struk printer → cetak receipt lengkap
    (items + harga + additional charges + total + payment method + change)
```

#### Saat Cetak Bill (request dari kasir):
```
  - cashier/struk printer → cetak bill
    (items + harga + total, TANPA payment info)
```

#### Saat Split Payment:
```
  - cashier/struk printer → cetak split receipt
    (items yang dibayar + amount + remaining)
```

### 4.5 Koneksi TCP ke Printer

```dart
// Implementasi di Flutter (menggunakan dart:io)
import 'dart:io';
import 'dart:typed_data';

Future<void> sendToPrinter(String ipAddress, int port, Uint8List data) async {
  final socket = await Socket.connect(
    ipAddress, 
    port,
    timeout: Duration(seconds: 3),
  );
  
  try {
    socket.add(data);
    await socket.flush();
  } finally {
    await socket.close();
  }
}
```

### 4.6 ESC/POS Commands (Referensi)

```dart
// Perintah dasar ESC/POS
class EscPosCommands {
  static const int ESC = 0x1B;
  static const int GS = 0x1D;
  
  // Initialize printer
  static List<int> init() => [ESC, 0x40];
  
  // Feed line
  static List<int> feedLine(int lines) => 
    List.filled(lines, 0x0A);
  
  // Bold on/off
  static List<int> boldOn() => [ESC, 0x45, 0x01];
  static List<int> boldOff() => [ESC, 0x45, 0x00];
  
  // Center align
  static List<int> centerAlign() => [ESC, 0x61, 0x01];
  // Left align
  static List<int> leftAlign() => [ESC, 0x61, 0x00];
  // Right align
  static List<int> rightAlign() => [ESC, 0x61, 0x02];
  
  // Font size
  static List<int> fontSizeLarge() => [GS, 0x21, 0x11]; // double height + width
  static List<int> fontSizeNormal() => [GS, 0x21, 0x00];
  
  // Cut paper
  static List<int> cutFull() => [GS, 0x56, 0x01];   // Full cut
  static List<int> cutPartial() => [GS, 0x56, 0x00]; // Partial cut
  
  // Character code table (UTF-8 support)
  static List<int> setCharset(int code) => [ESC, 0x52, code];
}
```

### 4.7 Format Receipt per Tipe

#### Receipt / Struk (cashier/struk printer):
```
╔══════════════════════════════╗
║      NAMA OUTLET             ║
║      Alamat Outlet           ║
║      Telp: xxx               ║
╠══════════════════════════════╣
║ No: TRX-01HXYZ...            ║
║ Meja: A1     Pax: 4          ║
║ Kasir: Siti                  ║
║ Waiter: Budi                 ║
║ Tgl: 28/05/2026 10:30       ║
╠══════════════════════════════╣
║ Nasi Goreng     2x 25.000   ║
║   Pedas                      ║
║ Es Teh Manis    1x  8.000   ║
║ Sate Ayam       3x 45.000   ║
╠══════════════════════════════╣
║ Subtotal          103.000   ║
║ Pajak 10%          10.300   ║
║ Diskon 5%          -5.150   ║
╠══════════════════════════════╣
║ TOTAL             108.150   ║
║ Tunai             150.000   ║
║ Kembali            41.850   ║
╠══════════════════════════════╣
║       Terima Kasih!          ║
║     Footer Text Here        ║
╚══════════════════════════════╝
```

#### Kitchen Order (kitchen/bar printer):
```
╔══════════════════════════════╗
║    DAPUR / BAR               ║
║ Printer: Kitchen-1           ║
╠══════════════════════════════╣
║ No: TRX-01HXYZ...            ║
║ Meja: A1                     ║
║ Waiter: Budi                 ║
║ Tgl: 28/05/2026 10:30       ║
╠══════════════════════════════╣
║ 2x  Nasi Goreng              ║
║     - Pedas                  ║
║ 1x  Es Teh Manis             ║
╠══════════════════════════════╣
║           --- CUT ---         ║
╚══════════════════════════════╝
```

#### Checker Order:
```
Sama seperti kitchen, tapi:
- Semua items (kitchen + bar)
- Tanda "TAMBAHAN" jika ada order sebelumnya untuk meja yang sama
- Tanpa harga
```

#### Bill (belum bayar):
```
Sama seperti receipt, tapi:
- TANPA payment info (paid_amount, change)
- Ada kata "BILL" / "BUKTI PESANAN"
```

### 4.8 Retry Logic

```dart
// Print Worker retry mechanism
class PrintWorker {
  static const maxRetries = 3;
  static const pollInterval = Duration(seconds: 2);
  static const staleLockTimeout = Duration(minutes: 5);
  
  void processJob(PrintJob job) {
    if (job.retryCount >= maxRetries) {
      markFailed(job.id, "Max retries exceeded");
      return;
    }
    
    try {
      sendToPrinter(job.printerIP, job.printerPort, job.receiptData);
      markDone(job.id);
    } catch (e) {
      incrementRetry(job.id, e.toString());
      // Job tetap pending, akan di-pickup lagi di cycle berikutnya
    }
  }
}
```

---

## 5. Cloud Sync

### 5.1 Arsitektur Sync

```
┌─────────────────────────────────────────────┐
│              SYNC WORKER                     │
│  (Background, interval: 5 menit default)     │
│                                              │
│  1. Reload cloud config dari DB              │
│  2. PUSH: pending sync_queue → cloud         │
│  3. PULL: updates dari cloud → local DB      │
│  4. Update last_sync_at                      │
│  5. Cleanup old entries (>24 jam)            │
└─────────────────────────────────────────────┘
```

### 5.2 Sync Queue (Outbox Pattern)

Setiap operasi yang perlu di-sync dimasukkan ke `sync_queue`:

```dart
// Entity types yang di-sync
enum SyncEntityType {
  order,
  transaction,
  transactionItem, // di-bundle ke parent transaction
  product,
  category,
}

// Operations
enum SyncOperation {
  create,
  update, // disebut "upsert" di backend
  delete,
}
```

### 5.3 Alur Push ke Cloud

```
1. Ambil pending items (max 100 per batch)
   - Skip items dengan retry_count >= 3 (exponential backoff)
   - Skip transaction_item (di-bundle ke parent transaction)
   
2. Untuk setiap item:
   a. Mark as "processing"
   b. Parse payload JSON
   c. ENRICH payload:
      - order → tambahkan items dari order_items
      - transaction → tambahkan transaction_items + cash_amount + tax_amount
   
3. Kirim batch ke cloud:
   POST /api/v1/outlets/{outlet_id}/sync/batch
   Headers:
     Authorization: Bearer {api_key}
     X-Outlet-ID: {outlet_id}
     X-Outlet-Code: {outlet_code}
   Body: {
     outlet_id, outlet_code, sync_timestamp,
     items: [{ entity_type, operation, data }]
   }
   
4. Process response:
   - Untuk setiap result:
     - success → mark sync_queue success, update entity version
     - failed → mark sync_queue failed (increment retry_count)
   
5. Cleanup:
   - Hapus sync_queue entries success/bundled yang > 24 jam
```

### 5.4 Alur Pull dari Cloud

```
1. Ambil last_sync_at dari outlet_config
2. GET /api/v1/outlets/{outlet_id}/updates?since={last_sync_at}
3. Process updates:
   - products → upsert ke local products
   - categories → upsert ke local categories
   - deleted → soft-delete (is_deleted=1) di local
4. Juga sync tax settings dari outlet info
5. Update last_sync_at
```

### 5.5 Full Pull dari Cloud

```
Digunakan saat:
- Pertama kali setup
- Ganti API key / outlet
- Manual trigger

1. Fetch semua categories → upsert local
   - Hapus local categories yang tidak ada di cloud
2. Fetch semua products → upsert local
   - Hapus local products yang tidak ada di cloud
3. Fetch outlet info → sync tax charge
4. Update last_sync_at
```

### 5.6 Cloud API Endpoints

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/v1/ping` | Health check |
| POST | `/api/v1/outlets/{id}/sync/batch` | Push batch sync |
| POST | `/api/v1/outlets/{id}/orders` | Push single order |
| POST | `/api/v1/outlets/{id}/transactions` | Push single transaction |
| POST | `/api/v1/outlets/{id}/products` | Push single product |
| GET | `/api/v1/outlets/{id}/updates?since={ts}` | Pull updates |
| GET | `/api/v1/outlets/{id}/products?page={n}&limit={l}` | Get all products |
| GET | `/api/v1/outlets/{id}/categories` | Get all categories |
| GET | `/api/v1/outlets/{id}/info` | Get outlet info + tax settings |

### 5.7 Exponential Backoff

```dart
// Sync Worker backoff saat offline
int consecutiveFails = 0;
int maxBackoffMinutes = 30;

Duration getNextInterval(Duration baseInterval) {
  if (consecutiveFails <= 0) return baseInterval;
  
  // interval * 2^fails
  Duration backoff = baseInterval * (1 << consecutiveFails);
  Duration maxBackoff = Duration(minutes: maxBackoffMinutes);
  
  if (backoff > maxBackoff) backoff = maxBackoff;
  return backoff;
}
// Contoh: base 5 menit
// Fail 1x → 10 menit
// Fail 2x → 20 menit
// Fail 3x → 30 menit (capped)
// Sukses → reset ke 5 menit
```

### 5.8 Sync Payload Examples

#### Order Sync Payload
```json
{
  "entity_type": "order",
  "operation": "create",
  "data": {
    "local_id": "01HXYZ...",
    "table_number": "A1",
    "customer_name": "John",
    "pax": 4,
    "total_amount": 103000,
    "status": "cooking",
    "items": [
      {
        "product_name": "Nasi Goreng",
        "category": "Makanan",
        "qty": 2,
        "price": 25000,
        "subtotal": 50000,
        "destination": "kitchen",
        "status": "pending"
      }
    ],
    "payment_info": {
      "paid_amount": 0,
      "payment_status": "unpaid"
    },
    "version": 1716867000,
    "created_at": "2026-05-28T10:30:00Z",
    "updated_at": "2026-05-28T10:30:00Z"
  }
}
```

#### Transaction Sync Payload
```json
{
  "entity_type": "transaction",
  "operation": "create",
  "data": {
    "id": "01HABC...",
    "local_id": "01HABC...",
    "order_id": "01HXYZ...",
    "total_amount": 103000,
    "payment_method": "cash",
    "cashier_name": "Siti",
    "cash_amount": 150000,
    "change_amount": 47000,
    "tax_amount": 10300,
    "items": [
      {
        "id": "01HITEM1...",
        "product_id": "01HPROD1...",
        "product_name": "Nasi Goreng",
        "quantity": 2,
        "price": 25000,
        "subtotal": 50000
      }
    ],
    "created_at": "2026-05-28T10:35:00Z"
  }
}
```

---

## 6. API Contracts (Backend → Flutter)

> Flutter berkomunikasi dengan Go backend via REST API.
> Semua response mengikuti format standar.

### 6.1 Response Format

```dart
// Semua API response
{
  "success": true/false,
  "message": "Deskripsi",
  "data": { ... }            // Payload, bisa null
}
```

### 6.2 Authentication

```
POST /api/auth/login
Body: { username: "admin", pin: "1234" }
Response: { success: true, data: { user, token } }

GET /api/auth/me
Headers: Authorization: Bearer {token}
Response: { success: true, data: { user } }
```

### 6.3 Orders API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| POST | `/api/orders` | Buat order baru |
| GET | `/api/orders?page=1&pageSize=20` | List orders (paginated) |
| GET | `/api/orders/{id}` | Detail order + items |
| GET | `/api/orders/table/{table_id}` | Order aktif by meja |
| POST | `/api/orders/{id}/items` | Tambah item ke order |
| POST | `/api/orders/table/{table_id}/items` | Tambah item by meja |
| PATCH | `/api/orders/items/{id}/status` | Update status item |
| PATCH | `/api/orders/items/{id}/qty` | Update qty item |
| POST | `/api/orders/{id}/payment` | Proses pembayaran |
| POST | `/api/orders/{id}/split-payment` | Split bill payment |
| POST | `/api/orders/{id}/discount` | Apply diskon |
| POST | `/api/orders/{id}/compliment` | Compliment order |
| POST | `/api/orders/{id}/void` | Void order |
| POST | `/api/orders/{id}/move` | Pindah meja |
| POST | `/api/orders/merge` | Merge orders |
| GET | `/api/orders/{id}/payments` | Riwayat pembayaran |

### 6.4 Products API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/products?page=1&pageSize=20` | List products |
| GET | `/api/products/{id}` | Detail product |
| POST | `/api/products` | Buat product |
| PUT | `/api/products/{id}` | Update product |
| DELETE | `/api/products/{id}` | Soft-delete product |

### 6.5 Categories API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/categories` | List categories |
| POST | `/api/categories` | Buat category |
| PUT | `/api/categories/{id}` | Update category |
| DELETE | `/api/categories/{id}` | Soft-delete category |

### 6.6 Tables API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/tables` | List tables |
| POST | `/api/tables` | Buat table |
| PUT | `/api/tables/{id}` | Update table |
| DELETE | `/api/tables/{id}` | Hapus table |

### 6.7 Transactions API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/transactions?page=1&pageSize=20` | List transactions |
| GET | `/api/transactions/{id}` | Detail + items |
| GET | `/api/transactions/range?start=&end=` | By date range |
| POST | `/api/transactions/{id}/cancel` | Cancel transaction |

### 6.8 Printers API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/printers` | List printers |
| POST | `/api/printers` | Buat printer |
| PUT | `/api/printers/{id}` | Update printer |
| DELETE | `/api/printers/{id}` | Hapus printer |
| PATCH | `/api/printers/{id}/toggle` | Toggle active |

### 6.9 Print Queue API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/print/queue?status=pending` | Status antrian |
| POST | `/api/print/order` | Cetak order manual |
| POST | `/api/print/reprint/{id}` | Cetak ulang |
| POST | `/api/print/bill/{id}` | Cetak bill |
| POST | `/api/print/queue/{id}/retry` | Retry job gagal |

### 6.10 Sync API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/sync/status` | Status sync |
| POST | `/api/sync/trigger` | Manual trigger |
| GET | `/api/sync/logs?limit=20` | Sync logs |
| GET | `/api/sync/failed` | Failed items |
| POST | `/api/sync/retry/{id}` | Retry item |
| POST | `/api/sync/full-pull` | Full pull dari cloud |

### 6.11 Config API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/config` | Get outlet config |
| PUT | `/api/config` | Update config |
| GET | `/api/config/outlet-info` | Info outlet |

### 6.12 Customers API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| GET | `/api/customers` | List customers |
| POST | `/api/customers` | Buat customer |
| GET | `/api/customers/{id}` | Detail |
| GET | `/api/customers/{id}/orders` | Order history |

### 6.13 Shifts API

| Method | Endpoint | Deskripsi |
|--------|----------|-----------|
| POST | `/api/shifts/open` | Buka shift baru |
| POST | `/api/shifts/close` | Tutup shift |
| GET | `/api/shifts/current` | Shift aktif |
| GET | `/api/shifts/{id}/summary` | Ringkasan shift |
| POST | `/api/shifts/{id}/cash-in` | Kas masuk |
| POST | `/api/shifts/{id}/cash-out` | Kas keluar |
| POST | `/api/shifts/{id}/handover` | Serah terima |

---

## 7. Struktur Flutter Project

```
lib/
├── main.dart                          # Entry point
├── app.dart                           # MaterialApp + Auth wrapper
│
├── config/
│   └── app_config.dart                # Constants, roles, status values
│
├── database/
│   └── database.dart                  # SQLite helper + schema migration
│
├── models/
│   └── models.dart                    # Semua data classes
│
├── repositories/
│   ├── auth_repository.dart
│   ├── order_repository.dart
│   ├── product_repository.dart
│   ├── category_repository.dart
│   ├── table_repository.dart
│   ├── transaction_repository.dart
│   ├── printer_repository.dart
│   ├── print_queue_repository.dart
│   ├── sync_repository.dart
│   ├── shift_repository.dart
│   ├── customer_repository.dart
│   └── config_repository.dart
│
├── services/
│   ├── api_service.dart               # HTTP client (Dio) ke backend
│   ├── auth_service.dart              # Login + session
│   ├── print_service.dart             # TCP socket + ESC/POS
│   ├── sync_service.dart              # Cloud sync logic
│   └── websocket_service.dart         # SSE/WS untuk real-time
│
├── workers/
│   ├── print_worker.dart              # Background print processor
│   └── sync_worker.dart               # Background sync processor
│
├── providers/                         # Riverpod providers
│   ├── auth_provider.dart
│   ├── order_provider.dart
│   ├── product_provider.dart
│   ├── table_provider.dart
│   ├── printer_provider.dart
│   └── sync_provider.dart
│
├── screens/
│   ├── login/
│   │   └── login_screen.dart
│   ├── dashboard/
│   │   └── dashboard_screen.dart
│   ├── cashier/
│   │   └── cashier_screen.dart        # POS kasir (create order, payment)
│   ├── tables/
│   │   └── table_management_screen.dart
│   ├── kitchen/
│   │   └── kitchen_screen.dart        # Dapur view (update item status)
│   ├── waiter/
│   │   └── waiter_screen.dart         # Waiter view (ambil pesanan)
│   ├── products/
│   │   └── product_screen.dart        # CRUD produk
│   ├── transactions/
│   │   └── transaction_screen.dart    # Riwayat transaksi
│   ├── settings/
│   │   └── settings_screen.dart       # Printer, config, user management
│   └── shift/
│       └── shift_screen.dart          # Open/close shift
│
├── widgets/
│   ├── order_card.dart
│   ├── product_grid.dart
│   ├── payment_dialog.dart
│   ├── receipt_preview.dart
│   └── ...
│
└── utils/
    ├── ulid.dart
    ├── currency.dart
    ├── date.dart
    └── escpos.dart                    # ESC/POS command builder
```

---

## 8. Implementasi per Layer

### 8.1 Database Layer

```dart
// database/database.dart
class AppDatabase {
  static Database? _instance;
  
  static Future<Database> get instance async {
    _instance ??= await openDatabase(
      join(await getDatabasesPath(), 'pos_resto.db'),
      version: 1,
      onCreate: (db, version) async {
        // Execute semua CREATE TABLE dari schema
        await db.execute('PRAGMA foreign_keys = ON');
        await db.execute(createUsersTable);
        await db.execute(createCategoriesTable);
        // ... dst untuk semua tabel
        // Insert default admin user
        await db.execute(insertDefaultAdmin);
      },
    );
    return _instance!;
  }
}
```

### 8.2 Repository Pattern

```dart
// repositories/order_repository.dart
abstract class OrderRepository {
  Future<String> createOrder(OrderInput input);
  Future<Order?> getOrderByTable(String tableNumber);
  Future<Order?> getOrderById(String id);
  Future<List<OrderItem>> getOrderItems(String orderId);
  Future<void> addItemToOrder(String orderId, List<OrderItemInput> items, String waiterName);
  Future<void> updateItemStatus(String itemId, String status);
  Future<void> updateItemQty(String itemId, int qty);
  Future<void> processPayment(String orderId);
  Future<void> updateOrderStatus(String orderId, String status);
  Future<void> applyDiscount(String orderId, String chargeType, double value);
  Future<void> applyCompliment(String orderId);
  Future<void> voidOrder(String orderId, String voidedBy, String reason);
  Future<List<Order>> listOrders({int limit = 20, int offset = 0});
  Future<int> countOrders();
  Future<void> splitBillPayment(SplitBillInput input);
  Future<String> mergeTables(List<String> sourceOrderIds, String targetTable);
  Future<void> moveOrderToTable(String orderId, String newTable, String waiterName);
  Future<List<Payment>> getOrderPayments(String orderId);
  Future<List<VoidedOrderHistory>> listVoidedOrders({int limit, int offset});
}
```

### 8.3 Print Worker

```dart
// workers/print_worker.dart
class PrintWorker {
  final Database _db;
  Timer? _timer;
  
  void start() {
    _timer = Timer.periodic(Duration(seconds: 2), (_) => _processPendingJobs());
  }
  
  void stop() => _timer?.cancel();
  
  Future<void> _processPendingJobs() async {
    // 1. Release stale locks
    await _releaseStaleLocks();
    
    // 2. Get pending jobs
    final jobs = await _getPendingJobs(limit: 10);
    
    // 3. Process each job
    for (final job in jobs) {
      final claimed = await _claimJob(job.id);
      if (!claimed) continue;
      await _processJob(job);
    }
  }
  
  Future<void> _processJob(PrintQueueJob job) async {
    if (job.retryCount >= 3) {
      await _markFailed(job.id, 'Max retries exceeded');
      return;
    }
    
    // Get printer info
    final printer = await _getPrinter(job.printerId);
    if (printer == null || !printer.isActive) {
      await _markFailed(job.id, 'Printer not available');
      return;
    }
    
    // Parse data & format receipt
    final data = PrintJobData.fromJson(jsonDecode(job.data));
    final escPosData = _formatReceipt(data, printer);
    
    // Send to printer
    try {
      await _sendToPrinter(printer.ipAddress, printer.port, escPosData);
      await _markDone(job.id);
    } catch (e) {
      await _incrementRetry(job.id, e.toString());
    }
  }
}
```

### 8.4 Sync Worker

```dart
// workers/sync_worker.dart
class SyncWorker {
  final SyncService _syncService;
  Timer? _timer;
  int _consecutiveFails = 0;
  static const _maxBackoffMinutes = 30;
  
  void start({int intervalMinutes = 5}) {
    _performSync(); // Initial sync
    _scheduleNextSync(Duration(minutes: intervalMinutes));
  }
  
  void _scheduleNextSync(Duration baseInterval) {
    final interval = _getNextInterval(baseInterval);
    _timer = Timer(interval, () {
      _performSync();
      _scheduleNextSync(baseInterval);
    });
  }
  
  Duration _getNextInterval(Duration base) {
    if (_consecutiveFails <= 0) return base;
    var backoff = base * (1 << _consecutiveFails);
    final max = Duration(minutes: _maxBackoffMinutes);
    return backoff > max ? max : backoff;
  }
  
  Future<void> _performSync() async {
    try {
      // Push
      await _syncService.pushPendingData();
      // Pull
      await _syncService.pullUpdates();
      _consecutiveFails = 0;
    } catch (e) {
      _consecutiveFails++;
    }
  }
}
```

---

## 9. Real-time Events (SSE)

Backend mengirim Server-Sent Events untuk update real-time:

| Event | Payload | Deskripsi |
|-------|---------|-----------|
| `order_created` | `{ order_id, table_number }` | Order baru dibuat |
| `order_items_updated` | `{ order_id }` | Item di-order diubah |
| `item_status_updated` | `{ item_id, status }` | Status item berubah |
| `payment_completed` | `{ order_id, table_numbers[] }` | Pembayaran selesai |
| `order_voided` | `{ order_id, table_numbers[] }` | Order di-void |
| `table_status_updated` | `{ table_numbers[] }` | Status meja berubah |

```dart
// services/websocket_service.dart
// Flutter mendengarkan SSE events dari backend
// Jika mode offline (tanpa backend), gunakan local DB saja

class RealtimeService {
  final _eventController = StreamController<RealtimeEvent>.broadcast();
  Stream<RealtimeEvent> get events => _eventController.stream;
  
  void connect(String baseUrl) {
    // SSE connection ke backend
    // Parse events dan emit ke stream
  }
  
  void dispose() {
    _eventController.close();
  }
}
```

---

## 10. Shift Kasir & Cash Movements

### 10.1 Alur Shift

```
HARI OPERASIONAL
═════════════════

1. KASIR BUKA SHIFT
   POST /api/shifts/open
   Body: { opening_cash: 500000 }
   → cashier_shifts (status='open')

2. OPERASIONAL NORMAL
   - Buat order, proses pembayaran
   - Semua pembayaran BUTUH open shift
   - Cash in/out selama shift

3. KASIR TUTUP SHIFT
   POST /api/shifts/close
   Body: {
     closing_cash: 750000,
     closing_card: 300000,
     closing_qris: 150000,
     closing_transfer: 0
   }
   → cashier_shifts (status='closed')
   → Cetak close shift receipt

4. SERAH TERIMA (opsional)
   POST /api/shifts/{id}/handover
   Body: { handover_to: "user_id_next_cashier" }
   → Cetak handover receipt
```

### 10.2 Cash Movements

```
KAS MASUK:
  POST /api/shifts/{id}/cash-in
  Body: { amount: 100000, counterpart_name: "Modal Tambahan", note: "Dari owner" }
  → cashier_cash_movements (type='in')
  → Cetak kas masuk receipt

KAS KELUAR:
  POST /api/shifts/{id}/cash-out
  Body: { amount: 50000, counterpart_name: "Budi", note: "Beli es batu" }
  → cashier_cash_movements (type='out')
  → Cetak kas keluar receipt
```

### 10.3 Close Shift Receipt Data

```dart
class CloseShiftReceipt {
  String receiptNumber;
  String cashierName;
  double openingCash;
  double closingCash;
  double closingCard;
  double closingQris;
  double closingTransfer;
  int voidedCount;
  double voidedTotal;
  int cancelledCount;
  double cancelledTotal;
  List<CashMovementData> cashIns;
  List<CashMovementData> cashOuts;
  DateTime dateTime;
}
```

---

## 11. Checklist Implementasi

### Phase 1: Core Foundation
- [ ] Database layer (semua tabel)
- [ ] Models lengkap
- [ ] Auth service (login + session)
- [ ] Config/constants

### Phase 2: POS Screens
- [ ] Dashboard/Home screen
- [ ] Kasir screen (create order, add items)
- [ ] Payment dialog (full, split, compliment)
- [ ] Table management screen
- [ ] Kitchen screen (update item status)
- [ ] Waiter screen (ambil pesanan)

### Phase 3: Printer System
- [ ] TCP socket connection
- [ ] ESC/POS command builder
- [ ] Receipt formatter (semua tipe)
- [ ] Print worker (background queue processor)
- [ ] Printer management (CRUD + settings)
- [ ] Print queue status UI

### Phase 4: Transactions & Reports
- [ ] Transaction history (list, filter by date)
- [ ] Void order flow (manager PIN)
- [ ] Discount/compliment flow
- [ ] Merge tables / move table
- [ ] Analytics dashboard

### Phase 5: Shift Management
- [ ] Open/close shift
- [ ] Cash in/out
- [ ] Handover between cashiers
- [ ] Shift summary receipt

### Phase 6: Cloud Sync
- [ ] Cloud API client
- [ ] Sync queue (outbox pattern)
- [ ] Push pending data
- [ ] Pull updates from cloud
- [ ] Full pull
- [ ] Exponential backoff
- [ ] Sync status UI
- [ ] Manual trigger / retry

### Phase 7: Polish
- [ ] Offline mode indicator
- [ ] Error handling & retry UI
- [ ] Search & filter
- [ ] Pagination (lazy loading)
- [ ] Receipt preview
- [ ] App icon & splash screen
- [ ] Performance optimization

---

## 12. Additional Charges & Pajak Restoran (Cloud-Synced)

### 12.1 Konsep

Additional charges adalah biaya tambahan yang **otomatis dikenakan** ke setiap order. Yang paling umum adalah **Pajak Restoran (PB1) 10%** yang pengaturannya datang dari cloud.

```
CLOUD (Dashboard Admin)
    │
    │  Outlet Settings:
    │  - tax_enabled: true
    │  - tax_rate: 10.0
    │  - tax_name: "Pajak Restoran (PB1)"
    │
    ▼  syncTaxFromCloud()
LOCAL APP (Go Backend / Flutter)
    │
    │  additional_charges table:
    │  - name: "Pajak Restoran (PB1)"
    │  - charge_type: "percentage"
    │  - value: 10.0
    │  - is_active: 1
    │
    ▼  recalculateOrderTotals()
SETIAP ORDER
    │
    │  order_additional_charges:
    │  - charge_id: (FK ke additional_charges)
    │  - applied_amount: subtotal × 10%
    │
    ▼
TOTAL ORDER = subtotal + charges - diskon
```

### 12.2 Alur Sinkronisasi Pajak dari Cloud

#### Saat FullPullFromCloud:
```
1. Fetch outlet info dari cloud
   GET /api/v1/outlets/{outlet_id}/info
   Response: {
     tax_enabled: true,
     tax_rate: 10.0,
     tax_name: "Pajak Restoran (PB1)"
   }

2. syncTaxFromCloud(taxEnabled, taxRate, taxName):
   a. Cari existing tax charge di local additional_charges:
      - Cari yang charge_type="percentage" DAN
        (name == taxName ATAU name dimulai dengan "pajak")
   
   b. Jika DITEMUKAN → UPDATE:
      - name = taxName
      - value = taxRate
      - is_active = taxEnabled
   
   c. Jika BELUM ADA → CREATE:
      - name = taxName (default: "Pajak Restoran (PB1)")
      - charge_type = "percentage"
      - value = taxRate
      - is_active = taxEnabled
   
   d. Refresh semua open order totals:
      - Untuk setiap order yang belum dibayar:
        - Hapus order_additional_charges lama (charge_id IS NOT NULL)
        - Re-read active additional_charges
        - Recalculate dan insert ulang
        - Update order total_amount
```

#### Best Practice: Kapan Sync Tax?
```
✅ FullPullFromCloud (saat setup, ganti API key, manual trigger)
✅ PullUpdates periodic (setiap 5 menit, jika outlet info berubah)
✅ Saat app pertama kali dijalankan (initial sync)
❌ JANGAN sync saat ada order sedang diproses (bisa race condition)
```

### 12.3 Perhitungan Charges saat Buat/Update Order

```
ALUR recalculateOrderTotals(orderID):

1. Hitung subtotal dari order_items
   subtotal = Σ(price × qty) untuk semua items

2. Hapus auto-charges lama (charge_id IS NOT NULL)
   DELETE FROM order_additional_charges
   WHERE order_id = ? AND charge_id IS NOT NULL

3. Baca active charges dari master
   SELECT * FROM additional_charges WHERE is_active = 1

4. Untuk setiap active charge:
   - Jika charge_type = "percentage":
     applied = subtotal × value / 100
   - Jika charge_type = "fixed":
     applied = value (langsung)
   - INSERT INTO order_additional_charges
   
5. Pertahankan manual charges (charge_id IS NULL = diskon manual)
   - Recalculate berdasarkan subtotal terbaru
   - Update applied_amount jika berubah

6. Total = subtotal + auto_charges + manual_charges
   (total tidak boleh < 0)
```

**Contoh Perhitungan:**
```
Subtotal items:       Rp 100.000
Pajak PB1 10%:        Rp  10.000  (auto, dari additional_charges)
Service Charge 5%:    Rp   5.000  (auto, dari additional_charges)
Diskon 10%:          (Rp  10.000) (manual, dari HandleApplyDiscount)
──────────────────────────────────
TOTAL:                Rp 105.000
```

### 12.4 Implementasi di Flutter

#### Model AdditionalCharge (Master)
```dart
class AdditionalCharge {
  final int? id;
  final String? outletId;
  final String name;
  final String chargeType; // 'percentage' atau 'fixed'
  final double value;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
}
```

#### Model OrderAdditionalCharge (per Order)
```dart
class OrderAdditionalCharge {
  final int? id;
  final String orderId;
  final int? chargeId;          // NULL = diskon manual
  final String name;
  final String chargeType;
  final double value;
  final double appliedAmount;   // Jumlah aktual
  final DateTime createdAt;
  final DateTime updatedAt;
  
  bool get isAuto => chargeId != null;   // Auto-charge dari master
  bool get isManual => chargeId == null; // Diskon manual
}
```

#### Sync Tax Function
```dart
// services/sync_service.dart
Future<void> syncTaxFromCloud(OutletInfo outletInfo) async {
  final taxName = outletInfo.taxName.isNotEmpty 
      ? outletInfo.taxName 
      : 'Pajak Restoran (PB1)';
  
  final charges = await chargeRepo.listAll();
  
  // Cari existing tax charge
  AdditionalCharge? existingTax;
  for (final ch in charges) {
    if (ch.chargeType == 'percentage' && 
        (ch.name == taxName || ch.name.toLowerCase().startsWith('pajak'))) {
      existingTax = ch;
      break;
    }
  }
  
  if (existingTax != null) {
    // Update existing
    existingTax.name = taxName;
    existingTax.value = outletInfo.taxRate;
    existingTax.isActive = outletInfo.taxEnabled;
    await chargeRepo.update(existingTax);
  } else {
    // Create new
    await chargeRepo.create(AdditionalCharge(
      name: taxName,
      chargeType: 'percentage',
      value: outletInfo.taxRate,
      isActive: outletInfo.taxEnabled,
    ));
  }
  
  // Refresh open orders
  await refreshOpenOrderTotals();
}
```

#### Recalculate Order Totals (Flutter)
```dart
// repositories/order_repository.dart
Future<void> recalculateOrderTotals(String orderId, Transaction tx) async {
  // 1. Subtotal dari items
  final items = await getItems(tx, orderId);
  final subtotal = items.fold(0.0, (sum, item) => sum + item.price * item.qty);
  
  // 2. Hapus auto-charges lama
  await tx.delete('order_additional_charges',
    where: 'order_id = ? AND charge_id IS NOT NULL',
    whereArgs: [orderId]);
  
  // 3. Baca active charges
  final activeCharges = await getActiveCharges(tx);
  
  // 4. Apply auto-charges
  double chargesTotal = 0;
  for (final charge in activeCharges) {
    double applied = 0;
    if (subtotal > 0) {
      if (charge.chargeType == 'percentage') {
        applied = subtotal * charge.value / 100;
      } else {
        applied = charge.value;
      }
    }
    if (applied == 0) continue;
    
    await tx.insert('order_additional_charges', {
      'order_id': orderId,
      'charge_id': charge.id,
      'name': charge.name,
      'charge_type': charge.chargeType,
      'value': charge.value,
      'applied_amount': applied,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    chargesTotal += applied;
  }
  
  // 5. Recalculate manual charges (diskon)
  final manualCharges = await getManualCharges(tx, orderId);
  double manualTotal = 0;
  for (final mc in manualCharges) {
    double computedAbs = 0;
    if (mc.chargeType == 'percentage') {
      computedAbs = subtotal * mc.value / 100;
    } else {
      computedAbs = mc.value;
    }
    final sign = mc.appliedAmount < 0 ? -1.0 : 1.0;
    final applied = sign * computedAbs;
    // Update applied_amount
    await tx.update('order_additional_charges',
      {'applied_amount': applied, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?', whereArgs: [mc.id]);
    manualTotal += applied;
  }
  
  // 6. Update order total
  double totalAmount = subtotal + chargesTotal + manualTotal;
  if (totalAmount < 0) totalAmount = 0;
  
  await tx.update('orders', {
    'total_amount': totalAmount,
    'basket_size': items.length,
    'updated_at': DateTime.now().toIso8601String(),
  }, where: 'id = ?', whereArgs: [orderId]);
}
```

### 12.5 Cloud API Contract (Outlet Info)

```
GET /api/v1/outlets/{outlet_id}/info
Headers:
  Authorization: Bearer {api_key}

Response:
{
  "success": true,
  "data": {
    "id": "outlet-uuid",
    "code": "OUTLET-001",
    "name": "Restoran Sederhana",
    "address": "Jl. Sudirman No. 123",
    "is_active": true,
    "tax_enabled": true,
    "tax_rate": 10.0,
    "tax_name": "Pajak Restoran (PB1)"
  }
}
```

### 12.6 Diagram Alur Lengkap: Tax → Order → Receipt

```
┌─────────────────────────────────────────────────────────┐
│                    CLOUD DASHBOARD                       │
│  Admin set: tax_enabled=true, tax_rate=10%, tax_name=... │
└────────────────────────┬────────────────────────────────┘
                         │
                    Full Pull / Periodic Pull
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│              LOCAL APP (Backend / Flutter)               │
│                                                          │
│  syncTaxFromCloud()                                      │
│    → UPSERT additional_charges                           │
│    → RefreshOpenOrderTotals()                            │
│                                                          │
│  additional_charges:                                     │
│  ┌────┬──────────────────────┬────────┬───────┬───────┐ │
│  │ id │ name                 │ type   │ value │ active│ │
│  ├────┼──────────────────────┼────────┼───────┼───────┤ │
│  │ 1  │ Pajak Restoran (PB1) │ pct    │ 10.0  │ 1     │ │
│  │ 2  │ Service Charge       │ pct    │ 5.0   │ 0     │ │
│  └────┴──────────────────────┴────────┴───────┴───────┘ │
│                                                          │
│  SAAT ORDER DIBUAT/DIUBAH:                               │
│                                                          │
│  order_items:                                            │
│    Nasi Goreng  2x 25.000 = 50.000                      │
│    Es Teh      1x  8.000 =  8.000                       │
│                          ─────────                        │
│                    subtotal = 58.000                      │
│                                                          │
│  recalculateOrderTotals():                               │
│    auto-charges (dari additional_charges WHERE active):  │
│      Pajak PB1 10% = 5.800                              │
│                                                          │
│    order_additional_charges:                             │
│    ┌──────────────────┬───────┬──────────┬─────────┐    │
│    │ name             │ type  │ value    │ applied │    │
│    ├──────────────────┼───────┼──────────┼─────────┤    │
│    │ Pajak Restoran   │ pct   │ 10.0     │ 5.800   │    │
│    └──────────────────┴───────┴──────────┴─────────┘    │
│                                                          │
│    total_amount = 58.000 + 5.800 = 63.800               │
│                                                          │
│  RECEIPT:                                                │
│    Nasi Goreng    2x 25.000                              │
│    Es Teh         1x  8.000                              │
│    ────────────────────────                               │
│    Subtotal         58.000                               │
│    Pajak PB1 10%     5.800                               │
│    ────────────────────────                               │
│    TOTAL             63.800                              │
│    Tunai            70.000                               │
│    Kembali           6.200                               │
└─────────────────────────────────────────────────────────┘
```

### 12.7 Best Practice Checklist: Tax & Charges

#### Di Go Backend (app-pos):
- [x] `syncTaxFromCloud()` — upsert tax charge dari cloud
- [x] `RefreshOpenOrderTotals()` — recalculate open orders setelah tax berubah
- [x] `recalculateOrderTotals()` — charges auto-applied saat create/update order
- [x] Diskon manual (`charge_id IS NULL`) dipisah dari auto-charges
- [x] Tax amount dihitung dari `order_additional_charges` + join `additional_charges`
- [x] Enrichment sync payload dengan `tax_amount`

#### Di Flutter (app-pos-flutter):
- [ ] Simpan `OutletInfo` (termasuk tax settings) di SQLite `outlet_config`
- [ ] `syncTaxFromCloud()` — replica logic dari Go backend
- [ ] `recalculateOrderTotals()` — replica calculation logic
- [ ] UI Settings: tampilkan toggle & field pajak (read-only jika dari cloud)
- [ ] UI Kasir: tampilkan pajak di ringkasan order sebelum payment
- [ ] Receipt: cetak baris pajak secara terpisah (bukan digabung total)
- [ ] Tax dihitung dari subtotal SEBELUM diskon (sesuai implementasi backend)
- [ ] Saat offline: gunakan tax settings lokal (terakhir disync)

---

## Appendix A: Status Values Reference

### Order Status
| Value | Deskripsi |
|-------|-----------|
| `cooking` | Order baru, item sedang disiapkan |
| `ready` | Semua item sudah ready/served |
| `served` | Order sudah disajikan/dibayar |

### Payment Status
| Value | Deskripsi |
|-------|-----------|
| `unpaid` | Belum dibayar |
| `partial` | Dibayar sebagian (split bill) |
| `paid` | Lunas |

### Item Status
| Value | Deskripsi |
|-------|-----------|
| `pending` | Menunggu diproses |
| `cooking` | Sedang dimasak/dibuat |
| `ready` | Siap disajikan |
| `served` | Sudah disajikan |

### Table Status
| Value | Deskripsi |
|-------|-----------|
| `available` | Meja kosong |
| `occupied` | Meja terisi |
| `reserved` | Meja di-reservasi |

### User Roles
| Value | Deskripsi |
|-------|-----------|
| `admin` | Full access |
| `cashier` | Kasir (payment, shift) |
| `manager` | Void, discount, reports |
| `waiter` | Ambil pesanan |
| `kitchen` | Update item status |
| `bar` | Update item status (bar) |

### Payment Methods
| Value | Deskripsi |
|-------|-----------|
| `cash` | Tunai |
| `card` | Kartu debit/kredit |
| `qris` | QRIS |
| `transfer` | Transfer bank |

### Printer Types
| Value | Deskripsi |
|-------|-----------|
| `kitchen` | Printer dapur |
| `bar` | Printer bar |
| `cashier` | Printer kasir |
| `checker` | Printer checker |
| `struk` | Printer struk utama |

---

## Appendix B: Error Handling

### Validasi Backend (wajib diikuti Flutter)

```
Buat Order:
  ✗ table_number kosong → 400 "table_number wajib diisi"
  ✗ pax <= 0 → 400 "pax harus lebih dari 0"
  ✗ items kosong → 400 "items tidak boleh kosong"
  ✗ product_id kosong → 400 "product_id wajib diisi"
  ✗ qty <= 0 → 400 "qty harus lebih dari 0"

Pembayaran:
  ✗ shift belum dibuka → 400 "Shift kasir belum dibuka"
  ✗ sudah lunas → 400 "Tagihan sudah lunas"
  ✗ paid_amount < remaining → 400 "Jumlah bayar kurang"

Void:
  ✗ PIN bukan 4 digit → 400 "PIN harus tepat 4 digit"
  ✗ PIN salah → 401 "PIN manager salah"
  ✗ order sudah paid → 400 "Order sudah dibayar"
  ✗ order sudah voided → 400 "Order sudah di-void"

Diskon:
  ✗ charge_type invalid → 400 "charge_type harus percentage atau fixed"
  ✗ value <= 0 → 400 "Nilai diskon harus lebih dari 0"
  ✗ percentage > 100 → 400 "Tidak boleh lebih dari 100"

Update Item Qty:
  ✗ item sudah diproses kitchen → 400 "Item sudah diproses"
  ✗ order sudah dibayar → 400 "Order sudah dibayar"
  ✗ qty tidak valid → 400 "qty tidak valid"
```

---

*Dokumen ini dibuat berdasarkan analisis source code Go backend (`app-pos`).*
*Terakhir diupdate: 28 Mei 2026*