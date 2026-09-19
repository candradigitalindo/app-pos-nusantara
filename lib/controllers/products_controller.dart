import 'package:flutter/foundation.dart' hide Category;

import '../models/models.dart';
import '../repositories/product_repository.dart';
import '../services/outlet_service.dart';

/// State untuk ProductsScreen
class ProductsState {
  final List<Category> categories;
  final List<Product> products;
  final Category? selectedCategory;
  final bool isLoading;
  final bool isProcessing;
  final String? errorMessage;
  final String? successMessage;
  final String searchQuery;

  /// True bila sync cloud aktif → produk & kategori dikelola dari cloud
  /// sehingga tidak boleh diedit lokal (akan tertimpa saat sync).
  final bool syncEnabled;

  const ProductsState({
    this.categories = const [],
    this.products = const [],
    this.selectedCategory,
    this.isLoading = false,
    this.isProcessing = false,
    this.errorMessage,
    this.successMessage,
    this.searchQuery = '',
    this.syncEnabled = false,
  });

  List<Product> get filteredProducts {
    if (searchQuery.isEmpty) return products;
    final q = searchQuery.toLowerCase();
    return products
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            (p.code?.toLowerCase().contains(q) ?? false))
        .toList();
  }

  ProductsState copyWith({
    List<Category>? categories,
    List<Product>? products,
    Category? selectedCategory,
    bool clearSelectedCategory = false,
    bool? isLoading,
    bool? isProcessing,
    String? errorMessage,
    bool clearError = false,
    String? successMessage,
    bool clearSuccess = false,
    String? searchQuery,
    bool? syncEnabled,
  }) {
    return ProductsState(
      categories: categories ?? this.categories,
      products: products ?? this.products,
      selectedCategory: clearSelectedCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      isLoading: isLoading ?? this.isLoading,
      isProcessing: isProcessing ?? this.isProcessing,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      successMessage:
          clearSuccess ? null : (successMessage ?? this.successMessage),
      searchQuery: searchQuery ?? this.searchQuery,
      syncEnabled: syncEnabled ?? this.syncEnabled,
    );
  }
}

/// Controller untuk ProductsScreen
class ProductsController extends ChangeNotifier {
  final ProductRepository _productRepo;
  final OutletService _outletService;

  ProductsState _state = const ProductsState();
  ProductsState get state => _state;

  ProductsController({
    ProductRepository? productRepo,
    OutletService? outletService,
  })  : _productRepo = productRepo ?? ProductRepository(),
        _outletService = outletService ?? OutletService();

  void _setState(ProductsState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<void> loadData() async {
    _setState(_state.copyWith(isLoading: true, clearError: true));
    try {
      final results = await Future.wait([
        _productRepo.getCategories(),
        _productRepo.getProducts(categoryId: _state.selectedCategory?.id),
        _outletService.loadOutlet(),
      ]);
      final categories = results[0] as List<Category>;
      final products = results[1] as List<Product>;
      final outlet = results[2] as OutletInfo;

      _setState(_state.copyWith(
        categories: categories,
        products: products,
        syncEnabled: outlet.syncEnabled,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal memuat data: $e',
      ));
    }
  }

  Future<void> selectCategory(Category? cat) async {
    _setState(_state.copyWith(
      selectedCategory: cat,
      clearSelectedCategory: cat == null,
      searchQuery: '',
    ));
    try {
      final products = await _productRepo.getProducts(categoryId: cat?.id);
      _setState(_state.copyWith(products: products));
    } catch (e) {
      _setState(_state.copyWith(errorMessage: 'Gagal memuat produk: $e'));
    }
  }

  void setSearchQuery(String query) {
    _setState(_state.copyWith(searchQuery: query));
  }

  Future<void> createProduct({
    required String name,
    String? code,
    String? description,
    required double price,
    int stock = 0,
    String? categoryId,
  }) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _productRepo.createProduct(
        name: name,
        code: code,
        description: description,
        price: price,
        stock: stock,
        categoryId: categoryId,
      );
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Produk "$name" berhasil ditambahkan',
      ));
      await loadData();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal menambah produk: $e',
      ));
    }
  }

  Future<void> updateProduct(Product product) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _productRepo.updateProduct(product);
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Produk berhasil diperbarui',
      ));
      await loadData();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal update produk: $e',
      ));
    }
  }

  Future<void> deleteProduct(String productId) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _productRepo.deleteProduct(productId);
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Produk berhasil dihapus',
      ));
      await loadData();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal hapus produk: $e',
      ));
    }
  }

  Future<void> createCategory({
    required String name,
    String? description,
    String printDestination = 'kitchen',
  }) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _productRepo.createCategory(
        name: name,
        description: description,
        printDestination: printDestination,
      );
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Kategori "$name" berhasil ditambahkan',
      ));
      await loadData();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal menambah kategori: $e',
      ));
    }
  }

  /// Ubah kategori (mis. nama / tujuan cetak dapur↔bar).
  Future<void> updateCategory(
    Category category, {
    String? name,
    String? printDestination,
  }) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      final updated = Category(
        id: category.id,
        name: name ?? category.name,
        description: category.description,
        printerId: category.printerId,
        printDestination: printDestination ?? category.printDestination,
        isDeleted: category.isDeleted,
        createdAt: category.createdAt,
        updatedAt: DateTime.now(),
      );
      await _productRepo.updateCategory(updated);
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Kategori "${updated.name}" diperbarui',
      ));
      await loadData();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal memperbarui kategori: $e',
      ));
    }
  }

  Future<void> seedSampleData() async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _productRepo.seedSampleData();
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Data contoh berhasil ditambahkan',
      ));
      await loadData();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal seed data: $e',
      ));
    }
  }

  void clearMessages() {
    _setState(_state.copyWith(clearError: true, clearSuccess: true));
  }
}
