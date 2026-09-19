import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../repositories/order_repository.dart';
import '../services/printer_service.dart';

/// State untuk KitchenScreen.
///
/// STASIUN = printer prep (bukan kasir/checker). Item ditampilkan pada stasiun
/// yang mencetak kategorinya — sama persis dengan routing cetak (kategori→printer),
/// sehingga mendukung banyak dapur/bar dengan SATU konfigurasi.
class KitchenState {
  final Map<Order, List<OrderItem>> ordersWithItems;
  final bool isLoading;
  final String? errorMessage;

  /// Daftar stasiun (printer prep). Kosong = belum ada printer → tampilkan semua.
  final List<PrinterDevice> stations;

  /// Alamat printer stasiun yang sedang dipilih.
  final String? selectedStationId;

  const KitchenState({
    this.ordersWithItems = const {},
    this.isLoading = false,
    this.errorMessage,
    this.stations = const [],
    this.selectedStationId,
  });

  PrinterDevice? get selectedStation {
    if (stations.isEmpty) return null;
    return stations.firstWhere(
      (s) => s.address == selectedStationId,
      orElse: () => stations.first,
    );
  }

  /// Apakah item ini termasuk stasiun yang sedang dipilih.
  /// - Tak ada stasiun → tampilkan semua.
  /// - Stasiun punya kategori → cocokkan kategori item.
  /// - Stasiun TANPA kategori → "catch-all": item yang tak diklaim stasiun lain.
  bool inSelectedStation(OrderItem item) {
    final st = selectedStation;
    if (st == null) return true;
    if (st.categoryIds.isEmpty) {
      final claimed = stations.any(
          (s) => s.categoryIds.isNotEmpty && s.printsCategory(item.categoryId));
      return !claimed;
    }
    return st.printsCategory(item.categoryId);
  }

  bool _visible(OrderItem i) => i.itemStatus != 'served' && inSelectedStation(i);

  /// Item per order (meja) untuk stasiun terpilih.
  Map<Order, List<OrderItem>> get filteredOrders {
    final result = <Order, List<OrderItem>>{};
    for (final entry in ordersWithItems.entries) {
      final items = entry.value.where(_visible).toList();
      if (items.isNotEmpty) result[entry.key] = items;
    }
    return result;
  }

  /// Daftar datar semua item (untuk tiket/batch), terurut status lalu waktu.
  List<({OrderItem item, String tableNumber})> get flatItems {
    final result = <({OrderItem item, String tableNumber})>[];
    for (final entry in ordersWithItems.entries) {
      for (final item in entry.value.where(_visible)) {
        result.add((item: item, tableNumber: entry.key.tableNumber));
      }
    }
    result.sort((a, b) {
      const order = ['pending', 'cooking', 'ready'];
      final ai = order.indexOf(a.item.itemStatus);
      final bi = order.indexOf(b.item.itemStatus);
      if (ai != bi) return ai.compareTo(bi);
      return a.item.createdAt.compareTo(b.item.createdAt);
    });
    return result;
  }

  int _count(String status) => ordersWithItems.values
      .expand((items) => items)
      .where((i) => inSelectedStation(i) && i.itemStatus == status)
      .length;

  int get pendingCount => _count('pending');
  int get cookingCount => _count('cooking');
  int get readyCount => _count('ready');

  KitchenState copyWith({
    Map<Order, List<OrderItem>>? ordersWithItems,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
    List<PrinterDevice>? stations,
    String? selectedStationId,
  }) {
    return KitchenState(
      ordersWithItems: ordersWithItems ?? this.ordersWithItems,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      stations: stations ?? this.stations,
      selectedStationId: selectedStationId ?? this.selectedStationId,
    );
  }
}

/// Controller untuk KitchenScreen.
class KitchenController extends ChangeNotifier {
  final OrderRepository _orderRepo;
  final PrinterService _printer;

  KitchenState _state = const KitchenState();
  KitchenState get state => _state;

  KitchenController({OrderRepository? orderRepo, PrinterService? printer})
      : _orderRepo = orderRepo ?? OrderRepository(),
        _printer = printer ?? PrinterService();

  void _setState(KitchenState newState) {
    _state = newState;
    notifyListeners();
  }

  void setStation(String stationId) {
    _setState(_state.copyWith(selectedStationId: stationId));
  }

  Future<void> loadOrders() async {
    _setState(_state.copyWith(isLoading: true, clearError: true));
    try {
      final ordersWithItems = await _orderRepo.getActiveOrdersWithItems();
      // Stasiun = printer prep (bukan kasir & bukan checker).
      final printers = await _printer.getSavedPrinters();
      final stations = printers
          .where((p) =>
              !p.hasRole(PrinterRole.cashier) &&
              !p.hasRole(PrinterRole.checker))
          .toList();

      var sel = _state.selectedStationId;
      if (sel == null || !stations.any((s) => s.address == sel)) {
        sel = stations.isNotEmpty ? stations.first.address : null;
      }

      _setState(_state.copyWith(
        ordersWithItems: ordersWithItems,
        stations: stations,
        selectedStationId: sel,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal memuat pesanan: $e',
      ));
    }
  }

  Future<void> updateItemStatus(String itemId, String newStatus) async {
    try {
      await _orderRepo.updateItemStatus(itemId, newStatus);
      _setState(_state.copyWith(
          ordersWithItems: _applyStatus({itemId}, newStatus)));
    } catch (e) {
      _setState(_state.copyWith(errorMessage: 'Gagal update status: $e'));
      await loadOrders();
    }
  }

  /// Update status BANYAK item sekaligus (mode Batch / Siap Semua).
  Future<void> updateBatchStatus(List<String> itemIds, String newStatus) async {
    if (itemIds.isEmpty) return;
    try {
      for (final id in itemIds) {
        await _orderRepo.updateItemStatus(id, newStatus);
      }
      _setState(_state.copyWith(
          ordersWithItems: _applyStatus(itemIds.toSet(), newStatus)));
    } catch (e) {
      _setState(_state.copyWith(errorMessage: 'Gagal update status: $e'));
      await loadOrders();
    }
  }

  Future<void> markAllReady(String orderId) async {
    final entry = _state.ordersWithItems.entries
        .where((e) => e.key.id == orderId)
        .firstOrNull;
    if (entry == null) return;
    final ids = entry.value
        .where((i) =>
            _state.inSelectedStation(i) &&
            (i.itemStatus == 'pending' || i.itemStatus == 'cooking'))
        .map((i) => i.id)
        .toList();
    await updateBatchStatus(ids, 'ready');
  }

  /// Terapkan status baru ke item-item [ids] secara optimistic (satu notify).
  Map<Order, List<OrderItem>> _applyStatus(Set<String> ids, String newStatus) {
    final updated = <Order, List<OrderItem>>{};
    for (final entry in _state.ordersWithItems.entries) {
      updated[entry.key] = entry.value.map((item) {
        if (ids.contains(item.id)) {
          return OrderItem(
            id: item.id,
            orderId: item.orderId,
            productName: item.productName,
            categoryId: item.categoryId,
            qty: item.qty,
            price: item.price,
            destination: item.destination,
            itemStatus: newStatus,
            notes: item.notes,
            addons: item.addons,
            waiterName: item.waiterName,
            isAdditional: item.isAdditional,
            createdAt: item.createdAt,
            updatedAt: DateTime.now(),
          );
        }
        return item;
      }).toList();
    }
    return updated;
  }
}
