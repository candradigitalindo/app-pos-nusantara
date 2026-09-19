import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../utils/ulid.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._();
  static Database? _database;
  static Future<Database>? _opening;

  AppDatabase._();

  /// Mengembalikan koneksi DB tunggal. Memakai cache Future agar `_initDb`
  /// (yang menjalankan migrasi) tidak pernah dijalankan ganda walau beberapa
  /// pemanggil meminta `database` bersamaan saat startup.
  Future<Database> get database {
    final db = _database;
    if (db != null) return Future.value(db);
    return _opening ??= _initDb().then((opened) {
      _database = opened;
      _opening = null;
      return opened;
    }, onError: (Object e) {
      _opening = null; // izinkan percobaan ulang bila gagal buka
      throw e;
    });
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'pos_resto.db');

    return openDatabase(
      path,
      version: 12,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(_kitchenPrintJobsSql);
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_kpj_status ON kitchen_print_jobs(status, created_at)',
      );
    }
    if (oldVersion < 3) {
      // Catat siapa yang memberi kompliment & alasannya
      await db.execute('ALTER TABLE orders ADD COLUMN compliment_by TEXT');
      await db.execute('ALTER TABLE orders ADD COLUMN compliment_reason TEXT');
      await db.execute('ALTER TABLE orders ADD COLUMN complimented_at DATETIME');
    }
    if (oldVersion < 4) {
      // Catatan/label diskon bill (mis. "member"), dikirim ke cloud
      await db.execute('ALTER TABLE orders ADD COLUMN discount_note TEXT');
    }
    if (oldVersion < 5) {
      // Tujuan cetak per kategori (kitchen/bar) — penanda routing langsung,
      // menggantikan rantai categories.printer_id → printers (yang tak terisi).
      await db.execute(
        "ALTER TABLE categories ADD COLUMN print_destination TEXT NOT NULL DEFAULT 'kitchen'",
      );
    }
    if (oldVersion < 6) {
      // Kategori asal item — dipakai routing cetak per-printer (printer memilih
      // kategori mana yang dicetaknya).
      await db.execute('ALTER TABLE order_items ADD COLUMN category_id TEXT');
    }
    if (oldVersion < 7) {
      // Tambah peran 'svp' ke CHECK constraint kolom role. CHECK tak bisa
      // di-ALTER → recreate tabel users (data lama dipertahankan).
      await db.execute('''
        CREATE TABLE users_new (
          id TEXT PRIMARY KEY CHECK (length(id) = 26),
          username TEXT NOT NULL UNIQUE,
          password_hash TEXT NOT NULL,
          full_name TEXT NOT NULL,
          role TEXT NOT NULL CHECK (role IN ('admin', 'waiter', 'kitchen', 'bar', 'cashier', 'manager', 'svp')),
          is_active INTEGER NOT NULL DEFAULT 1,
          created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
      ''');
      await db.execute('INSERT INTO users_new SELECT * FROM users');
      await db.execute('DROP TABLE users');
      await db.execute('ALTER TABLE users_new RENAME TO users');
    }
    if (oldVersion < 8) {
      // Default retensi data lokal = 90 hari (3 bulan). Config lama yang masih
      // 0 dinaikkan ke 90 agar konsisten (data lengkap tetap di cloud).
      await db.execute(
        'UPDATE outlet_config SET data_retention_days = 90 '
        'WHERE data_retention_days <= 0',
      );
    }
    if (oldVersion < 9) {
      // Penanda order "Meja Titipan" (parked check) — item yang dititip, bukan
      // pesanan tamu aktif. Dikecualikan dari view meja/dapur/waiter.
      await db.execute(
        'ALTER TABLE orders ADD COLUMN is_holding INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 10) {
      // KEAMANAN: tutup backdoor 'dummyhash' (menerima PIN 1234 tanpa hash).
      // Akun seed dimigrasi ke hash SHA-256 asli dari '1234' — PIN default
      // tetap 1234 tapi lewat jalur verifikasi normal & bisa diganti di
      // Manajemen User. SANGAT disarankan langsung mengganti PIN default.
      await db.execute(
        "UPDATE users SET password_hash = "
        "'03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4' "
        "WHERE password_hash LIKE '%dummyhash%'",
      );
    }
    if (oldVersion < 11) {
      // Add-on/modifier menu (mis. "Extra keju +5.000"). Tabel lama memakai
      // INTEGER AUTOINCREMENT — tak bisa disinkron ke cloud yang mengidentifikasi
      // entitas via local_id ULID. Tabel lama SELALU kosong (belum pernah ada
      // UI pengisinya), jadi aman dibuang & dibuat ulang alih-alih dimigrasi.
      await db.execute('DROP TABLE IF EXISTS product_addons');
      await db.execute(_productAddonsSql);
      await db.execute(_productAddonsIndexSql);
    }
    if (oldVersion < 12) {
      // Pengenal stabil untuk disinkron ke cloud. Kolom `id` bertipe INTEGER
      // AUTOINCREMENT dan sudah dirujuk order_additional_charges.charge_id di
      // baris pesanan historis, jadi TIDAK boleh diganti tipe — cukup tambah
      // kolom pendamping dan isi untuk baris yang sudah ada.
      //
      // Cloud butuh daftar biaya ini untuk menghitung total pesanan online
      // dengan cara yang sama persis dengan kasir; tanpa itu nominal QRIS
      // yang dibayar tamu bisa berbeda dari tagihan yang dihitung POS.
      await db.execute('ALTER TABLE additional_charges ADD COLUMN sync_id TEXT');
      final rows = await db.query('additional_charges', columns: ['id']);
      for (final r in rows) {
        await db.update(
          'additional_charges',
          {'sync_id': Ulid.generate()},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }
    }
  }

  // Add-on/modifier per produk. Harga add-on DILIPAT ke harga item saat
  // pesanan dibuat (lihat OrderRepository), sehingga subtotal, pajak, dan
  // seluruh laporan bekerja tanpa perubahan; rincian pilihannya disimpan
  // sebagai JSON di order_items.addons untuk struk & tiket dapur.
  static const String _productAddonsSql = '''
    CREATE TABLE IF NOT EXISTS product_addons (
      id TEXT PRIMARY KEY CHECK (length(id) = 26),
      product_id TEXT NOT NULL,
      group_name TEXT NOT NULL DEFAULT '',
      name TEXT NOT NULL,
      price REAL NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_active INTEGER NOT NULL DEFAULT 1,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
    )
  ''';

  static const String _productAddonsIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_addons_product '
      'ON product_addons(product_id, is_deleted, sort_order)';

  // Antrian cetak dapur/bar (durable + retry). Struk kasir TIDAK lewat sini.
  static const String _kitchenPrintJobsSql = '''
    CREATE TABLE IF NOT EXISTS kitchen_print_jobs (
      id TEXT PRIMARY KEY,
      printer_address TEXT NOT NULL,
      printer_type TEXT NOT NULL,
      role TEXT NOT NULL,
      payload BLOB NOT NULL,
      label TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed')),
      retry_count INTEGER NOT NULL DEFAULT 0,
      error_message TEXT,
      locked_at DATETIME,
      created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  ''';

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    // Users
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        full_name TEXT NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('admin', 'waiter', 'kitchen', 'bar', 'cashier', 'manager', 'svp')),
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Customers
    await db.execute('''
      CREATE TABLE IF NOT EXISTS customers (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        name TEXT NOT NULL,
        phone TEXT NOT NULL UNIQUE,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_customers_phone ON customers(phone)',
    );

    // Tables
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tables (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        table_number TEXT NOT NULL UNIQUE,
        capacity INTEGER NOT NULL DEFAULT 4 CHECK (capacity > 0),
        status TEXT NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'occupied', 'reserved')),
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tables_status ON tables(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tables_number ON tables(table_number)',
    );

    // Printers
    await db.execute('''
      CREATE TABLE IF NOT EXISTS printers (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        name TEXT NOT NULL,
        ip_address TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 9100,
        printer_type TEXT NOT NULL CHECK (printer_type IN ('kitchen', 'bar', 'cashier', 'checker', 'struk')),
        paper_size TEXT NOT NULL DEFAULT '80mm' CHECK (paper_size IN ('58mm', '80mm')),
        connection_timeout INTEGER DEFAULT 3,
        write_timeout INTEGER DEFAULT 5,
        retry_attempts INTEGER DEFAULT 2,
        print_density INTEGER DEFAULT 50 CHECK (print_density >= 0 AND print_density <= 100),
        print_speed TEXT DEFAULT 'normal' CHECK (print_speed IN ('slow', 'normal', 'fast')),
        cut_mode TEXT DEFAULT 'partial' CHECK (cut_mode IN ('full', 'partial', 'none')),
        enable_beep INTEGER DEFAULT 1,
        auto_cut INTEGER DEFAULT 1,
        charset TEXT DEFAULT 'latin',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Categories
    await db.execute('''
      CREATE TABLE IF NOT EXISTS categories (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        name TEXT NOT NULL UNIQUE,
        description TEXT,
        printer_id TEXT,
        print_destination TEXT NOT NULL DEFAULT 'kitchen' CHECK (print_destination IN ('kitchen', 'bar')),
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (printer_id) REFERENCES printers(id) ON DELETE SET NULL
      )
    ''');

    // Products
    await db.execute('''
      CREATE TABLE IF NOT EXISTS products (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        name TEXT NOT NULL,
        code TEXT UNIQUE,
        description TEXT,
        price REAL NOT NULL,
        stock INTEGER NOT NULL,
        category_id TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_category_id ON products(category_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_name ON products(name)',
    );

    // Product Notes
    await db.execute('''
      CREATE TABLE IF NOT EXISTS product_notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id TEXT NOT NULL,
        note TEXT NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
      )
    ''');

    // Product Addons
    await db.execute(_productAddonsSql);
    await db.execute(_productAddonsIndexSql);

    // Orders
    await db.execute('''
      CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY,
        table_number TEXT NOT NULL,
        customer_name TEXT,
        customer_phone TEXT,
        customer_id TEXT,
        pax INTEGER NOT NULL DEFAULT 1 CHECK (pax > 0),
        basket_size INTEGER NOT NULL DEFAULT 0 CHECK (basket_size >= 0),
        total_amount REAL NOT NULL,
        paid_amount REAL NOT NULL DEFAULT 0,
        order_status TEXT NOT NULL DEFAULT 'cooking' CHECK (order_status IN ('cooking', 'ready', 'served')),
        created_by TEXT,
        payment_status TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
        merged_from TEXT,
        is_merged INTEGER NOT NULL DEFAULT 0,
        is_holding INTEGER NOT NULL DEFAULT 0,
        voided_at DATETIME,
        voided_by TEXT,
        void_reason TEXT,
        compliment_by TEXT,
        compliment_reason TEXT,
        complimented_at DATETIME,
        discount_note TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_orders_created_at ON orders(created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_orders_table_number ON orders(table_number)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(order_status, payment_status)',
    );

    // Order Items
    await db.execute('''
      CREATE TABLE IF NOT EXISTS order_items (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        order_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        category_id TEXT,
        qty INTEGER NOT NULL CHECK (qty > 0),
        price REAL NOT NULL CHECK (price >= 0),
        destination TEXT NOT NULL CHECK (destination IN ('kitchen', 'bar')),
        item_status TEXT NOT NULL DEFAULT 'pending' CHECK (item_status IN ('pending', 'cooking', 'ready', 'served')),
        notes TEXT NOT NULL DEFAULT '',
        addons TEXT NOT NULL DEFAULT '',
        waiter_name TEXT NOT NULL DEFAULT '',
        is_additional INTEGER NOT NULL DEFAULT 0,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON order_items(order_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_order_items_status ON order_items(item_status)',
    );

    // Additional Charges (Master)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS additional_charges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_id TEXT,
        outlet_id TEXT,
        name TEXT NOT NULL,
        charge_type TEXT NOT NULL CHECK (charge_type IN ('percentage', 'fixed')),
        value REAL NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Order Additional Charges
    await db.execute('''
      CREATE TABLE IF NOT EXISTS order_additional_charges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id TEXT NOT NULL,
        charge_id INTEGER,
        name TEXT NOT NULL,
        charge_type TEXT NOT NULL,
        value REAL NOT NULL,
        applied_amount REAL NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Transactions
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transactions (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        order_id TEXT NOT NULL DEFAULT '',
        total_amount REAL NOT NULL,
        payment_method TEXT NOT NULL,
        status TEXT NOT NULL,
        transaction_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        created_by TEXT,
        cancelled_at DATETIME,
        cancelled_by TEXT,
        cancel_reason TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transactions_date ON transactions(transaction_date)',
    );

    // Transaction Items
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transaction_items (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        transaction_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        price REAL NOT NULL,
        FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE
      )
    ''');

    // Payments
    await db.execute('''
      CREATE TABLE IF NOT EXISTS payments (
        id TEXT PRIMARY KEY CHECK (length(id) = 26),
        order_id TEXT NOT NULL,
        amount REAL NOT NULL CHECK (amount > 0),
        payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'card', 'qris', 'transfer')),
        payment_note TEXT,
        created_by TEXT NOT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_payments_order_id ON payments(order_id)',
    );

    // Print Queue
    await db.execute('''
      CREATE TABLE IF NOT EXISTS print_queue (
        id TEXT PRIMARY KEY,
        printer_id TEXT NOT NULL,
        data TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed')),
        retry_count INTEGER NOT NULL DEFAULT 0,
        error_message TEXT,
        locked_at DATETIME,
        locked_by TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Cashier Shifts
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cashier_shifts (
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
        status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
        notes TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Cashier Cash Movements
    await db.execute('''
      CREATE TABLE IF NOT EXISTS cashier_cash_movements (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        movement_type TEXT NOT NULL CHECK (movement_type IN ('in', 'out')),
        amount REAL NOT NULL,
        counterpart_name TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Sync Queue
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        payload TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'success', 'failed', 'bundled')),
        retry_count INTEGER NOT NULL DEFAULT 0,
        max_retries INTEGER NOT NULL DEFAULT 3,
        error_message TEXT,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        processed_at DATETIME,
        synced_at DATETIME
      )
    ''');

    // Sync Logs
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_type TEXT NOT NULL,
        entity_type TEXT,
        entity_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        error_message TEXT,
        started_at DATETIME NOT NULL,
        completed_at DATETIME,
        duration_ms INTEGER,
        details TEXT
      )
    ''');

    // Outlet Config
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outlet_config (
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
        data_retention_days INTEGER NOT NULL DEFAULT 90,
        last_sync_at DATETIME,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    ''');

    // Entity Versions
    await db.execute('''
      CREATE TABLE IF NOT EXISTS entity_versions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        version INTEGER DEFAULT 1,
        cloud_version INTEGER DEFAULT 0,
        last_modified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_synced_at TIMESTAMP,
        sync_status TEXT DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced', 'conflict')),
        UNIQUE(entity_type, entity_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_entity_versions_sync ON entity_versions(sync_status)',
    );

    // Registered Devices
    await db.execute('''
      CREATE TABLE IF NOT EXISTS registered_devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL UNIQUE,
        device_name TEXT NOT NULL,
        device_type TEXT NOT NULL DEFAULT 'tablet',
        ip_address TEXT NOT NULL,
        user_agent TEXT DEFAULT '',
        is_active INTEGER DEFAULT 1,
        last_seen_at DATETIME,
        registered_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        registered_by TEXT
      )
    ''');

    // Kitchen/Bar Print Jobs (durable queue + retry)
    await db.execute(_kitchenPrintJobsSql);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_kpj_status ON kitchen_print_jobs(status, created_at)',
    );

    // Seed default manager user (PIN: 1234 — hash SHA-256 asli, GANTI segera
    // lewat Manajemen User; tidak ada lagi jalur backdoor dummyhash).
    await db.execute('''
      INSERT OR IGNORE INTO users (id, username, password_hash, full_name, role)
      VALUES ('01HZ0000000000000000000000', 'admin', '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4', 'Manager', 'manager')
    ''');

    // Seed default outlet config (data_retention_days = 90 = 3 bulan)
    await db.execute('''
      INSERT OR IGNORE INTO outlet_config (id, outlet_name, outlet_code, is_active, data_retention_days)
      VALUES (1, 'POS Resto', 'OUTLET-001', 1, 90)
    ''');
  }

  // Generic query helpers
  Future<List<Map<String, dynamic>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    return db.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  Future<Map<String, dynamic>> insert(
    String table,
    Map<String, dynamic> values,
  ) async {
    final db = await database;
    final id = await db.insert(table, values);
    return {'id': id, ...values};
  }

  Future<int> update(
    String table,
    Map<String, dynamic> values, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final db = await database;
    return db.update(table, values, where: where, whereArgs: whereArgs);
  }

  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final db = await database;
    return db.delete(table, where: where, whereArgs: whereArgs);
  }

  Future<List<Map<String, dynamic>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final db = await database;
    return db.rawQuery(sql, arguments);
  }

  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    final db = await database;
    return db.rawInsert(sql, arguments);
  }

  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    final db = await database;
    return db.rawUpdate(sql, arguments);
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
