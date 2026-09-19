import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../repositories/order_repository.dart';
import '../repositories/table_repository.dart';

/// State untuk TablesScreen
class TablesState {
  final List<RestaurantTable> tables;
  final Map<String, Order?> tableOrders; // tableNumber -> active order
  final bool isLoading;
  final bool isProcessing;
  final String? errorMessage;
  final String? successMessage;

  const TablesState({
    this.tables = const [],
    this.tableOrders = const {},
    this.isLoading = false,
    this.isProcessing = false,
    this.errorMessage,
    this.successMessage,
  });

  int get availableCount => tables.where((t) => t.status == 'available').length;
  int get occupiedCount => tables.where((t) => t.status == 'occupied').length;
  int get reservedCount => tables.where((t) => t.status == 'reserved').length;

  TablesState copyWith({
    List<RestaurantTable>? tables,
    Map<String, Order?>? tableOrders,
    bool? isLoading,
    bool? isProcessing,
    String? errorMessage,
    bool clearError = false,
    String? successMessage,
    bool clearSuccess = false,
  }) {
    return TablesState(
      tables: tables ?? this.tables,
      tableOrders: tableOrders ?? this.tableOrders,
      isLoading: isLoading ?? this.isLoading,
      isProcessing: isProcessing ?? this.isProcessing,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      successMessage:
          clearSuccess ? null : (successMessage ?? this.successMessage),
    );
  }
}

/// Controller untuk TablesScreen
class TablesController extends ChangeNotifier {
  final TableRepository _tableRepo;
  final OrderRepository _orderRepo;

  TablesState _state = const TablesState();
  TablesState get state => _state;

  TablesController({
    TableRepository? tableRepo,
    OrderRepository? orderRepo,
  })  : _tableRepo = tableRepo ?? TableRepository(),
        _orderRepo = orderRepo ?? OrderRepository();

  void _setState(TablesState newState) {
    _state = newState;
    notifyListeners();
  }

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

  Future<void> addTable({
    required String tableNumber,
    int capacity = 4,
  }) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _tableRepo.createTable(
        tableNumber: tableNumber,
        capacity: capacity,
      );
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Meja $tableNumber berhasil ditambahkan',
      ));
      await loadTables();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal menambah meja: $e',
      ));
    }
  }

  Future<void> editTable({
    required String tableId,
    required String tableNumber,
    int? capacity,
  }) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      // Cegah nomor meja bentrok dengan meja lain.
      final dup = _state.tables.any(
          (t) => t.id != tableId && t.tableNumber == tableNumber.trim());
      if (dup) throw Exception('Nomor meja sudah dipakai');
      await _tableRepo.updateTable(
        tableId: tableId,
        tableNumber: tableNumber.trim(),
        capacity: capacity,
      );
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Meja diperbarui',
      ));
      await loadTables();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage:
            'Gagal mengubah meja: ${e.toString().replaceFirst('Exception: ', '')}',
      ));
    }
  }

  Future<void> updateTableStatus(String tableNumber, String status) async {
    try {
      await _tableRepo.updateTableStatus(tableNumber, status);
      // Optimistic update
      final updatedTables = _state.tables.map((t) {
        if (t.tableNumber == tableNumber) {
          return RestaurantTable(
            id: t.id,
            tableNumber: t.tableNumber,
            capacity: t.capacity,
            status: status,
            createdAt: t.createdAt,
            updatedAt: DateTime.now(),
          );
        }
        return t;
      }).toList();
      _setState(_state.copyWith(tables: updatedTables));
    } catch (e) {
      _setState(_state.copyWith(errorMessage: 'Gagal update status meja: $e'));
      await loadTables();
    }
  }

  Future<void> deleteTable(String tableId) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _tableRepo.deleteTable(tableId);
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: 'Meja berhasil dihapus',
      ));
      await loadTables();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal hapus meja: $e',
      ));
    }
  }

  Future<void> seedTables({int count = 10}) async {
    _setState(_state.copyWith(isProcessing: true, clearError: true));
    try {
      await _tableRepo.seedTables(count: count);
      _setState(_state.copyWith(
        isProcessing: false,
        successMessage: '$count meja berhasil dibuat',
      ));
      await loadTables();
    } catch (e) {
      _setState(_state.copyWith(
        isProcessing: false,
        errorMessage: 'Gagal seed meja: $e',
      ));
    }
  }

  void clearMessages() {
    _setState(_state.copyWith(clearError: true, clearSuccess: true));
  }
}
