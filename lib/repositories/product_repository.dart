import '../database/database.dart';
import '../models/models.dart';
import '../utils/ulid.dart';
import 'sync_queue_repository.dart';

class ProductRepository {
  final AppDatabase _db = AppDatabase.instance;
  final SyncQueueRepository _sync = SyncQueueRepository();

  // ── Sync payload helpers ────────────────────────────────────────────────────

  Map<String, dynamic> _categoryPayload(Category c) => {
        'local_id': c.id,
        'id': c.id,
        'name': c.name,
        'description': c.description ?? '',
        'print_destination': c.printDestination,
        'version': 1,
      };

  Map<String, dynamic> _productPayload(Product p) => {
        'local_id': p.id,
        'id': p.id,
        'name': p.name,
        'code': p.code ?? '',
        'description': p.description ?? '',
        'price': p.price,
        'stock': p.stock,
        'category_id': p.categoryId ?? '',
        'version': 1,
      };

  // ==================== CATEGORIES ====================

  Future<List<Category>> getCategories() async {
    final results = await _db.query(
      'categories',
      where: 'is_deleted = 0',
      orderBy: 'name ASC',
    );
    return results.map((m) => Category.fromMap(m)).toList();
  }

  Future<Category> createCategory({
    required String name,
    String? description,
    String? printerId,
    String printDestination = 'kitchen',
  }) async {
    final now = DateTime.now();
    final category = Category(
      id: Ulid.generate(),
      name: name,
      description: description,
      printerId: printerId,
      printDestination: printDestination,
      createdAt: now,
      updatedAt: now,
    );
    await _db.insert('categories', category.toMap());
    await _sync.enqueue(
      entityType: 'category',
      entityId: category.id,
      operation: 'create',
      payload: _categoryPayload(category),
    );
    return category;
  }

  Future<void> updateCategory(Category category) async {
    await _db.update(
      'categories',
      category.toMap(),
      where: 'id = ?',
      whereArgs: [category.id],
    );
    await _sync.enqueue(
      entityType: 'category',
      entityId: category.id,
      operation: 'update',
      payload: _categoryPayload(category),
    );
  }

  // ==================== PRODUCTS ====================

  Future<List<Product>> getProducts({String? categoryId}) async {
    String? where;
    List<Object?>? whereArgs;

    if (categoryId != null) {
      where = 'is_deleted = 0 AND category_id = ?';
      whereArgs = [categoryId];
    } else {
      where = 'is_deleted = 0';
    }

    final results = await _db.query(
      'products',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'name ASC',
    );
    return results.map((m) => Product.fromMap(m)).toList();
  }

  Future<List<Product>> searchProducts(String query) async {
    final results = await _db.query(
      'products',
      where: 'is_deleted = 0 AND (name LIKE ? OR code LIKE ?)',
      whereArgs: ['%$query%', '%$query%'],
      orderBy: 'name ASC',
    );
    return results.map((m) => Product.fromMap(m)).toList();
  }

  Future<Product> createProduct({
    required String name,
    String? code,
    String? description,
    required double price,
    int stock = 0,
    String? categoryId,
  }) async {
    final now = DateTime.now();
    final product = Product(
      id: Ulid.generate(),
      name: name,
      code: code,
      description: description,
      price: price,
      stock: stock,
      categoryId: categoryId,
      createdAt: now,
      updatedAt: now,
    );
    await _db.insert('products', product.toMap());
    await _sync.enqueue(
      entityType: 'product',
      entityId: product.id,
      operation: 'create',
      payload: _productPayload(product),
    );
    return product;
  }

  Future<void> updateProduct(Product product) async {
    await _db.update(
      'products',
      product.toMap(),
      where: 'id = ?',
      whereArgs: [product.id],
    );
    await _sync.enqueue(
      entityType: 'product',
      entityId: product.id,
      operation: 'update',
      payload: _productPayload(product),
    );
  }

  Future<void> deleteProduct(String id) async {
    await _db.update(
      'products',
      {'is_deleted': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _sync.enqueue(
      entityType: 'product',
      entityId: id,
      operation: 'delete',
      payload: {'local_id': id, 'id': id},
    );
  }

  // ==================== PRODUCT ADDONS ====================

  Map<String, dynamic> _addonPayload(ProductAddon a) => {
        'local_id': a.id,
        'id': a.id,
        'product_local_id': a.productId,
        'group_name': a.groupName,
        'name': a.name,
        'price': a.price,
        'sort_order': a.sortOrder,
        'is_active': a.isActive,
        'version': 1,
      };

  /// Add-on aktif milik satu produk, siap ditawarkan di dialog pemilih.
  Future<List<ProductAddon>> getAddons(String productId) async {
    final results = await _db.query(
      'product_addons',
      where: 'product_id = ? AND is_deleted = 0 AND is_active = 1',
      whereArgs: [productId],
      orderBy: 'sort_order ASC, name ASC',
    );
    return results.map((m) => ProductAddon.fromMap(m)).toList();
  }

  /// Semua add-on produk TERMASUK yang dinonaktifkan — untuk layar pengelolaan.
  Future<List<ProductAddon>> getAllAddons(String productId) async {
    final results = await _db.query(
      'product_addons',
      where: 'product_id = ? AND is_deleted = 0',
      whereArgs: [productId],
      orderBy: 'sort_order ASC, name ASC',
    );
    return results.map((m) => ProductAddon.fromMap(m)).toList();
  }

  /// Jumlah add-on aktif per produk, dipakai layar kasir/waiter untuk menandai
  /// menu mana yang perlu membuka dialog pemilih saat ditekan. Satu query untuk
  /// seluruh menu — menghindari N query saat grid menu digambar.
  Future<Map<String, int>> addonCountByProduct() async {
    final rows = await _db.rawQuery('''
      SELECT product_id, COUNT(*) AS n FROM product_addons
      WHERE is_deleted = 0 AND is_active = 1
      GROUP BY product_id
    ''');
    return {
      for (final r in rows)
        r['product_id'] as String: (r['n'] as num).toInt(),
    };
  }

  Future<ProductAddon> createAddon({
    required String productId,
    required String name,
    double price = 0,
    String groupName = '',
    int sortOrder = 0,
  }) async {
    final now = DateTime.now();
    final addon = ProductAddon(
      id: Ulid.generate(),
      productId: productId,
      groupName: groupName,
      name: name,
      price: price,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await _db.insert('product_addons', addon.toMap());
    await _sync.enqueue(
      entityType: 'product_addon',
      entityId: addon.id,
      operation: 'create',
      payload: _addonPayload(addon),
    );
    return addon;
  }

  Future<void> updateAddon(ProductAddon addon) async {
    await _db.update(
      'product_addons',
      addon.toMap(),
      where: 'id = ?',
      whereArgs: [addon.id],
    );
    await _sync.enqueue(
      entityType: 'product_addon',
      entityId: addon.id,
      operation: 'update',
      payload: _addonPayload(addon),
    );
  }

  /// Hapus lunak: baris pesanan lama menyimpan salinan nama & harga add-on,
  /// jadi struk historis tetap utuh walau master-nya dibuang.
  Future<void> deleteAddon(String id) async {
    await _db.update(
      'product_addons',
      {'is_deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    await _sync.enqueue(
      entityType: 'product_addon',
      entityId: id,
      operation: 'delete',
      payload: {'local_id': id, 'id': id},
    );
  }

  // ==================== SEED DATA ====================

  Future<void> seedSampleData() async {
    // Check if already seeded
    final existing = await getProducts();
    if (existing.isNotEmpty) return;

    // Create categories — minuman default ke bar agar routing langsung benar
    final makanan = await createCategory(name: 'Makanan');
    final minuman =
        await createCategory(name: 'Minuman', printDestination: 'bar');
    final snack = await createCategory(name: 'Snack');

    // Create products
    final products = [
      ('Nasi Goreng Spesial', 'MNS-001', 25000.0, makanan.id),
      ('Nasi Goreng Ayam', 'MNS-002', 22000.0, makanan.id),
      ('Mie Goreng', 'MNS-003', 20000.0, makanan.id),
      ('Ayam Goreng', 'MNS-004', 18000.0, makanan.id),
      ('Soto Ayam', 'MNS-005', 20000.0, makanan.id),
      ('Nasi Padang', 'MNS-006', 25000.0, makanan.id),
      ('Es Teh Manis', 'MNM-001', 5000.0, minuman.id),
      ('Es Jeruk', 'MNM-002', 8000.0, minuman.id),
      ('Kopi Susu', 'MNM-003', 12000.0, minuman.id),
      ('Teh Hangat', 'MNM-004', 5000.0, minuman.id),
      ('Air Mineral', 'MNM-005', 4000.0, minuman.id),
      ('Jus Alpukat', 'MNM-006', 15000.0, minuman.id),
      ('Kentang Goreng', 'SNK-001', 15000.0, snack.id),
      ('Pisang Goreng', 'SNK-002', 10000.0, snack.id),
      ('Tahu Crispy', 'SNK-003', 8000.0, snack.id),
    ];

    for (final (name, code, price, catId) in products) {
      await createProduct(
        name: name,
        code: code,
        price: price,
        categoryId: catId,
      );
    }
  }
}
