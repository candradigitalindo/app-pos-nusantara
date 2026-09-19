import 'package:flutter/foundation.dart' hide Category;

import '../models/models.dart';
import '../repositories/order_repository.dart';
import '../repositories/product_repository.dart';
import '../repositories/table_repository.dart';
import '../services/auth_service.dart';
import '../services/local_api_server.dart';
import '../services/printer_service.dart';
import '../services/receipt_builder.dart';

/// State untuk WaiterScreen - mandiri, tidak bergantung ke CashierScreen
class WaiterState {
  // Tables
  final List<RestaurantTable> tables;
  final Map<String, Order?> tableOrders;

  // Products
  final List<Category> categories;
  final List<Product> products;
  final Category? selectedCategory;

  // Cart (for creating new orders)
  final RestaurantTable? selectedTable;
  final Map<String, int> cart;
  final Map<String, String> cartNotes;

  /// Add-on terpilih per produk di keranjang — sama polanya dengan
  /// [cartNotes]; harganya dilipat ke harga item saat order dibuat.
  final Map<String, List<SelectedAddon>> cartAddons;

  /// Jumlah add-on aktif per produk, untuk menandai menu di grid.
  final Map<String, int> addonCounts;
  final Map<String, Product> productCache;
  final int pax; // jumlah tamu untuk order baru
  final String? customerName; // identitas customer (opsional)
  final String? customerPhone; // no HP customer (opsional)

  // Existing order detail
  final Order? currentOrder;
  final List<OrderItem> currentOrderItems;

  // UI state
  final bool isLoading;
  final bool isProcessing;
  final String? errorMessage;
  final String? successMessage;

  // View mode: 'tables' | 'order' | 'detail'
  final String viewMode;

  const WaiterState({
    this.tables = const [],
    this.tableOrders = const {},
    this.categories = const [],
    this.products = const [],
    this.selectedCategory,
    this.selectedTable,
    this.cart = const {},
    this.cartNotes = const {},
    this.cartAddons = const {},
    this.addonCounts = const {},
    this.productCache = const {},
    this.pax = 1,
    this.customerName,
    this.customerPhone,
    this.currentOrder,
    this.currentOrderItems = const [],
    this.isLoading = false,
    this.isProcessing = false,
    this.errorMessage,
    this.successMessage,
    this.viewMode = 'tables',
  });

  int get availableCount => tables.where((t) => t.status == 'available').length;
  int get occupiedCount => tables.where((t) => t.status == 'occupied').length;

  double get cartTotal => cart.entries.fold(0.0, (sum, e) {
        final p = productCache[e.key];
        final addons = SelectedAddon.totalOf(cartAddons[e.key] ?? const []);
        return sum + ((p?.price ?? 0) + addons) * e.value;
      });

  int get cartItemCount => cart.values.fold(0, (sum, qty) => sum + qty);

  WaiterState copyWith({
    List<RestaurantTable>? tables,
    Map<String, Order?>? tableOrders,
    List<Category>? categories,
    List<Product>? products,
    Category? selectedCategory,
    bool clearSelectedCategory = false,
    RestaurantTable? selectedTable,
    bool clearSelectedTable = false,
    Map<String, int>? cart,
    Map<String, String>? cartNotes,
    Map<String, List<SelectedAddon>>? cartAddons,
    Map<String, int>? addonCounts,
    Map<String, Product>? productCache,
    int? pax,
    String? customerName,
    String? customerPhone,
    bool clearCustomer = false,
    Order? currentOrder,
    bool clearCurrentOrder = false,
    List<OrderItem>? currentOrderItems,
    bool? isLoading,
    bool? isProcessing,
    String? errorMessage,
    bool clearError = false,
    String? successMessage,
    bool clearSuccess = false,
    String? viewMode,
  }) {
    return WaiterState(
      tables: tables ?? this.tables,
      tableOrders: tableOrders ?? this.tableOrders,
      categories: categories ?? this.categories,
      products: products ?? this.products,
      selectedCategory: clearSelectedCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      selectedTable:
          clearSelectedTable ? null : (selectedTable ?? this.selectedTable),
      cart: cart ?? this.cart,
      cartNotes: cartNotes ?? this.cartNotes,
      cartAddons: cartAddons ?? this.cartAddons,
      addonCounts: addonCounts ?? this.addonCounts,
      productCache: productCache ?? this.productCache,
      pax: pax ?? this.pax,
      customerName: clearCustomer ? null : (customerName ?? this.customerName),
      customerPhone:
          clearCustomer ? null : (customerPhone ?? this.customerPhone),
      currentOrder:
          clearCurrentOrder ? null : (currentOrder ?? this.currentOrder),
      currentOrderItems: currentOrderItems ?? this.currentOrderItems,
      isLoading: isLoading ?? this.isLoading,
      isProcessing: isProcessing ?? this.isProcessing,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      successMessage:
          clearSuccess ? null : (successMessage ?? this.successMessage),
      viewMode: viewMode ?? this.viewMode,
    );
  }
}

/// Controller untuk WaiterScreen - mandiri dengan kemampuan order lengkap
class WaiterController extends ChangeNotifier {
  final OrderRepository _orderRepo;
  final ProductRepository _productRepo;
  final TableRepository _tableRepo;
  final AuthService _authService;

  WaiterState _state = const WaiterState();
  WaiterState get state => _state;

  WaiterController({
    OrderRepository? orderRepo,
    ProductRepository? productRepo,
    TableRepository? tableRepo,
    AuthService? authService,
  })  : _orderRepo = orderRepo ?? OrderRepository(),
        _productRepo = productRepo ?? ProductRepository(),
        _tableRepo = tableRepo ?? TableRepository(),
        _authService = authService ?? AuthService();

  void _setState(WaiterState newState) {
    _state = newState;
    notifyListeners();
  }

  // ── Load Tables ──────────────────────────────────────────────────────────

  Future<void> loadTables() async {
    _setState(_state.copyWith(isLoading: true, clearError: true));
    try {
      // 2 query saja (bukan N+1): daftar meja + semua order aktif sekaligus.
      final results = await Future.wait([
        _tableRepo.getTables(),
        _orderRepo.getActiveOrdersByTable(),
      ]);
      final tables = results[0] as List<RestaurantTable>;
      final activeByTable = results[1] as Map<String, Order>;

      final tableOrders = <String, Order?>{};
      for (final t in tables) {
        tableOrders[t.tableNumber] = activeByTable[t.tableNumber];
      }

      _setState(_state.copyWith(
        tables: tables,
        tableOrders: tableOrders,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal memuat meja: $e',
      ));
    }
  }

  // ── Select Table & Enter Order Mode ──────────────────────────────────────

  Future<void> selectTableForOrder(RestaurantTable table) async {
    _setState(_state.copyWith(
      selectedTable: table,
      viewMode: 'order',
      cart: {},
      pax: 1, // reset jumlah tamu untuk order baru
      clearCustomer: true, // reset identitas customer
      clearCurrentOrder: true,
      currentOrderItems: [],
      isLoading: true,
      clearError: true,
    ));

    try {
      // Load categories + products in parallel
      final results = await Future.wait([
        _productRepo.getCategories(),
        _productRepo.getProducts(),
        _productRepo.addonCountByProduct(),
      ]);
      final categories = results[0] as List<Category>;
      final products = results[1] as List<Product>;
      final addonCounts = results[2] as Map<String, int>;

      final productCache = <String, Product>{};
      for (final p in products) {
        productCache[p.id] = p;
      }

      _setState(_state.copyWith(
        categories: categories,
        products: products,
        // Default "Semua" saat pertama buka (bukan kategori pertama).
        clearSelectedCategory: true,
        productCache: productCache,
        addonCounts: addonCounts,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal memuat menu: $e',
      ));
    }
  }

  // ── View Existing Order Detail ───────────────────────────────────────────

  Future<void> viewOrderDetail(RestaurantTable table) async {
    final order = _state.tableOrders[table.tableNumber];
    if (order == null) return;

    _setState(_state.copyWith(
      selectedTable: table,
      currentOrder: order,
      viewMode: 'detail',
      isLoading: true,
      clearError: true,
    ));

    try {
      final items = await _orderRepo.getOrderItems(order.id);
      _setState(_state.copyWith(
        currentOrderItems: items,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal memuat detail order: $e',
      ));
    }
  }

  // ── Pindah / Gabung Meja ─────────────────────────────────────────────────

  /// Pindahkan order yang sedang dilihat (mode detail) ke meja kosong lain.
  Future<bool> moveOrderToTable(String newTableNumber) async {
    final order = _state.currentOrder;
    if (order == null) return false;
    if (_state.isProcessing) return false;
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _orderRepo.moveOrderToTable(
          orderId: order.id, newTableNumber: newTableNumber);
      _setState(_state.copyWith(isProcessing: false));
      await loadTables();
      await _reopenDetail(newTableNumber);
      return true;
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage:
            'Gagal pindah meja: ${e.toString().replaceFirst('Exception: ', '')}',
      ));
      return false;
    }
  }

  /// Daftar order meja lain yang bisa digabung ke order saat ini.
  Future<List<Order>> getMergeableOrders() {
    final order = _state.currentOrder;
    if (order == null) return Future.value([]);
    return _orderRepo.getMergeableOrders(order.tableNumber);
  }

  /// Gabungkan order meja lain ke order yang sedang dilihat.
  Future<bool> mergeTable(String sourceOrderId) async {
    final order = _state.currentOrder;
    if (order == null) return false;
    if (_state.isProcessing) return false;
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _orderRepo.mergeOrders(
          targetOrderId: order.id, sourceOrderId: sourceOrderId);
      _setState(_state.copyWith(isProcessing: false));
      await loadTables(); // meja source kini available
      await _reopenDetail(order.tableNumber);
      return true;
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage:
            'Gagal gabung meja: ${e.toString().replaceFirst('Exception: ', '')}',
      ));
      return false;
    }
  }

  /// Muat ulang tampilan detail untuk [tableNumber] (setelah pindah/gabung).
  Future<void> _reopenDetail(String tableNumber) async {
    RestaurantTable? table;
    for (final t in _state.tables) {
      if (t.tableNumber == tableNumber) {
        table = t;
        break;
      }
    }
    final order = _state.tableOrders[tableNumber];
    if (table == null || order == null) {
      _setState(_state.copyWith(viewMode: 'tables', clearCurrentOrder: true));
      return;
    }
    final items = await _orderRepo.getOrderItems(order.id);
    _setState(_state.copyWith(
      selectedTable: table,
      currentOrder: order,
      currentOrderItems: items,
      viewMode: 'detail',
    ));
  }

  // ── Category & Product Filtering ─────────────────────────────────────────

  Future<void> selectCategory(Category? cat) async {
    _setState(_state.copyWith(
      selectedCategory: cat,
      clearSelectedCategory: cat == null,
    ));
    try {
      final products = await _productRepo.getProducts(categoryId: cat?.id);
      final productCache = Map<String, Product>.from(_state.productCache);
      for (final p in products) {
        productCache[p.id] = p;
      }
      _setState(_state.copyWith(
        products: products,
        productCache: productCache,
      ));
    } catch (e) {
      _setState(_state.copyWith(errorMessage: 'Gagal memuat produk: $e'));
    }
  }

  /// Cari menu di semua kategori. Bila query kosong, kembali ke daftar
  /// produk kategori yang sedang dipilih.
  Future<void> searchProducts(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      await selectCategory(_state.selectedCategory);
      return;
    }
    try {
      final products = await _productRepo.searchProducts(q);
      final productCache = Map<String, Product>.from(_state.productCache);
      for (final p in products) {
        productCache[p.id] = p;
      }
      _setState(_state.copyWith(
        products: products,
        productCache: productCache,
      ));
    } catch (e) {
      _setState(_state.copyWith(errorMessage: 'Gagal mencari produk: $e'));
    }
  }

  // ── Cart Management ──────────────────────────────────────────────────────

  /// Tambah satu unit. [addons] hanya dipakai saat produk PERTAMA kali masuk
  /// keranjang; unit berikutnya mengikuti racikan yang sudah dipilih.
  void addToCart(Product product, {List<SelectedAddon>? addons}) {
    final updated = Map<String, int>.from(_state.cart);
    final isNewLine = !updated.containsKey(product.id);
    updated[product.id] = (updated[product.id] ?? 0) + 1;
    final cache = Map<String, Product>.from(_state.productCache);
    cache[product.id] = product;

    Map<String, List<SelectedAddon>>? picks;
    if (isNewLine && addons != null && addons.isNotEmpty) {
      picks = Map<String, List<SelectedAddon>>.from(_state.cartAddons);
      picks[product.id] = addons;
    }

    _setState(_state.copyWith(
      cart: updated,
      productCache: cache,
      cartAddons: picks,
    ));
  }

  void removeFromCart(String productId) {
    final updated = Map<String, int>.from(_state.cart);
    if ((updated[productId] ?? 0) <= 1) {
      updated.remove(productId);
      final notes = Map<String, String>.from(_state.cartNotes)
        ..remove(productId);
      final picks = Map<String, List<SelectedAddon>>.from(_state.cartAddons)
        ..remove(productId);
      _setState(_state.copyWith(
        cart: updated,
        cartNotes: notes,
        cartAddons: picks,
      ));
    } else {
      updated[productId] = updated[productId]! - 1;
      _setState(_state.copyWith(cart: updated));
    }
  }

  void updateCartAddons(String productId, List<SelectedAddon> addons) {
    final picks = Map<String, List<SelectedAddon>>.from(_state.cartAddons);
    if (addons.isEmpty) {
      picks.remove(productId);
    } else {
      picks[productId] = addons;
    }
    _setState(_state.copyWith(cartAddons: picks));
  }

  Future<List<ProductAddon>> addonsFor(String productId) =>
      _productRepo.getAddons(productId);

  void updateCartNote(String productId, String note) {
    final notes = Map<String, String>.from(_state.cartNotes);
    if (note.isEmpty) {
      notes.remove(productId);
    } else {
      notes[productId] = note;
    }
    _setState(_state.copyWith(cartNotes: notes));
  }

  // ── Create Order ─────────────────────────────────────────────────────────

  /// Atur jumlah tamu (pax) untuk order baru (1..99).
  void setPax(int p) {
    _setState(_state.copyWith(pax: p.clamp(1, 99)));
  }

  /// Atur identitas customer (opsional) untuk order baru.
  void setCustomer({String? name, String? phone}) {
    _setState(_state.copyWith(
      customerName: name,
      customerPhone: phone,
      clearCustomer: name == null && phone == null,
    ));
  }

  Future<bool> createOrder({String? customerName, int? pax}) async {
    if (_state.selectedTable == null) {
      _setState(_state.copyWith(errorMessage: 'Pilih meja terlebih dahulu'));
      return false;
    }
    if (_state.cart.isEmpty) {
      _setState(_state.copyWith(errorMessage: 'Tambahkan item ke pesanan'));
      return false;
    }

    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      final items = _state.cart.entries
          .map((e) => OrderItemInput(
                productId: e.key,
                qty: e.value,
                notes: _state.cartNotes[e.key],
                addons: _state.cartAddons[e.key] ?? const [],
              ))
          .toList();

      // Pemesan = akun yang sedang login di perangkat ini; fallback 'Waiter'.
      final user = await _authService.currentUserFromSession();
      final orderedBy = (user?.fullName.isNotEmpty ?? false)
          ? user!.fullName
          : (user?.username ?? 'Waiter');

      final order = await _orderRepo.createOrder(
        tableNumber: _state.selectedTable!.tableNumber,
        items: items,
        customerName: customerName ?? _state.customerName,
        customerPhone: _state.customerPhone,
        pax: pax ?? _state.pax,
        createdBy: orderedBy,
        waiterName: orderedBy, // catat pemesan di tiap item
      );

      // Broadcast ke waiter stations yang terhubung
      LocalApiServer.instance.broadcast('order_created', order.toMap());

      // Cetak tiket dapur/bar ditangani oleh OrderRepository (print queue).

      // Refresh tables
      await loadTables();

      _setState(_state.copyWith(
        isProcessing: false,
        successMessage:
            'Order berhasil dibuat untuk Meja ${_state.selectedTable!.tableNumber}',
        viewMode: 'tables',
        cart: {},
        cartNotes: {},
        cartAddons: {},
        clearSelectedTable: true,
        clearCurrentOrder: true,
        clearCustomer: true,
        currentOrderItems: [],
      ));
      return true;
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal membuat order: $e',
      ));
      return false;
    }
  }

  // ── Print Bill ───────────────────────────────────────────────────────────

  Future<void> printBill(String orderId) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      final order = await _orderRepo.getOrderById(orderId);
      if (order == null) throw Exception('Order tidak ditemukan');

      final items = await _orderRepo.getOrderItems(orderId);
      final charges = await _orderRepo.getOrderCharges(orderId);

      final printerService = PrinterService();
      final savedPrinters = await printerService.getSavedPrinters();
      if (savedPrinters.isEmpty) {
        throw Exception('Tidak ada printer tersimpan');
      }

      final subtotal = items.fold(0.0, (sum, i) => sum + i.subtotal);
      final chargesTotal = charges.fold(0.0, (sum, c) => sum + c.appliedAmount);

      final receiptData = ReceiptData(
        orderId: order.id,
        receiptNumber: 'BILL-${order.id.substring(0, 8).toUpperCase()}',
        tableNumber: order.tableNumber,
        customerName: order.customerName,
        pax: order.pax,
        items: items
            .map((i) => ReceiptItem(
                  name: i.productName,
                  quantity: i.qty,
                  price: i.price,
                  total: i.subtotal,
                  notes: i.notes.isNotEmpty ? i.notes : null,
                  ordererName: i.waiterName,
                ))
            .toList(),
        subtotal: subtotal,
        charges: charges
            .map((c) => ReceiptCharge(name: c.name, amount: c.appliedAmount))
            .toList(),
        chargesTotal: chargesTotal,
        total: order.totalAmount,
        dateTime: DateTime.now(),
        isBill: true,
      );

      // Bill → printer kasir; fallback ke printer non-dapur/bar, lalu pertama.
      final cashierPrinters =
          savedPrinters.where((p) => p.hasRole(PrinterRole.cashier)).toList();
      final printer = cashierPrinters.isNotEmpty
          ? cashierPrinters.first
          : savedPrinters.firstWhere(
              (p) =>
                  !p.hasRole(PrinterRole.kitchen) &&
                  !p.hasRole(PrinterRole.bar),
              orElse: () => savedPrinters.first,
            );

      final builder = ReceiptBuilder(paperWidth: printer.paperCols);

      Future<void> send(List<int> bytes) async {
        if (printer.type == PrinterType.bluetooth) {
          await printerService.sendBluetooth(printer.address, bytes);
        } else {
          await printerService.sendLan(printer.address, bytes);
        }
      }

      await send(builder.buildReceipt(receiptData));
      // Rangkap: salinan ke-2..N bertanda "COPY" (printer.copies dari Pengaturan).
      for (var c = 2; c <= printer.copies; c++) {
        await send(builder.buildReceipt(receiptData, isCopy: true));
      }

      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Bill berhasil dicetak',
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal cetak bill: $e',
      ));
    }
  }

  // ── Navigation ───────────────────────────────────────────────────────────

  void goBackToTables() {
    _setState(_state.copyWith(
      viewMode: 'tables',
      cart: {},
      clearSelectedTable: true,
      clearSelectedCategory: true,
      clearCurrentOrder: true,
      currentOrderItems: [],
    ));
    loadTables();
  }

  void clearMessages() {
    _setState(_state.copyWith(clearError: true, clearSuccess: true));
  }
}
