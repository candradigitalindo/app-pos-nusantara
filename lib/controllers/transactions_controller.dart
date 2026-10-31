import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../repositories/order_repository.dart';
import '../services/auth_service.dart';
import '../services/cash_drawer_service.dart';
import '../services/outlet_service.dart';
import '../services/print_queue_service.dart';
import '../services/printer_service.dart';
import '../services/receipt_builder.dart';

/// State untuk TransactionsScreen
class TransactionsState {
  final List<Order> orders;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final int offset;
  final String filter; // 'all', 'paid', 'unpaid', 'voided'
  final String? errorMessage;

  static const int pageSize = 20;

  const TransactionsState({
    this.orders = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.offset = 0,
    this.filter = 'all',
    this.errorMessage,
  });

  List<Order> get filteredOrders {
    switch (filter) {
      case 'paid':
        return orders.where((o) => o.isPaid).toList();
      case 'unpaid':
        return orders.where((o) => !o.isPaid && !o.isVoided).toList();
      case 'voided':
        return orders.where((o) => o.isVoided).toList();
      default:
        return orders;
    }
  }

  double get totalRevenue => orders
      .where((o) => o.isPaid && !o.isVoided)
      .fold(0.0, (sum, o) => sum + o.totalAmount);

  int get paidCount => orders.where((o) => o.isPaid && !o.isVoided).length;
  int get unpaidCount => orders.where((o) => !o.isPaid && !o.isVoided).length;
  int get voidedCount => orders.where((o) => o.isVoided).length;

  TransactionsState copyWith({
    List<Order>? orders,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    int? offset,
    String? filter,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TransactionsState(
      orders: orders ?? this.orders,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      offset: offset ?? this.offset,
      filter: filter ?? this.filter,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Controller untuk TransactionsScreen
class TransactionsController extends ChangeNotifier {
  final OrderRepository _orderRepo;

  TransactionsState _state = const TransactionsState();
  TransactionsState get state => _state;

  TransactionsController({OrderRepository? orderRepo})
      : _orderRepo = orderRepo ?? OrderRepository();

  void _setState(TransactionsState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<void> loadOrders({bool reset = false}) async {
    if (reset) {
      _setState(_state.copyWith(
        isLoading: true,
        orders: [],
        offset: 0,
        hasMore: true,
        clearError: true,
      ));
    }

    try {
      final newOrders = await _orderRepo.listOrders(
        limit: TransactionsState.pageSize,
        offset: _state.offset,
      );
      final updatedOrders = [..._state.orders, ...newOrders];
      _setState(_state.copyWith(
        orders: updatedOrders,
        offset: _state.offset + newOrders.length,
        hasMore: newOrders.length == TransactionsState.pageSize,
        isLoading: false,
        isLoadingMore: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        isLoadingMore: false,
        errorMessage: 'Gagal memuat transaksi: $e',
      ));
    }
  }

  Future<void> loadMore() async {
    if (_state.isLoadingMore || !_state.hasMore) return;
    _setState(_state.copyWith(isLoadingMore: true));
    await loadOrders();
  }

  void setFilter(String filter) {
    _setState(_state.copyWith(filter: filter));
  }

  void clearError() {
    _setState(_state.copyWith(clearError: true));
  }

  // ── Aksi ber-otoritas PIN (void & bayar dari layar Transaksi) ─────────────

  final _authService = AuthService();
  final _outletService = OutletService();

  /// Nama pihak yang mengotorisasi dari [pin], atau null bila tidak berwenang.
  /// Sama dengan kasir: PIN void bersama ATAU PIN user admin/manager/svp.
  /// Verifikasi PIN otorisasi (Admin/Manager/SVP atau PIN void outlet) tanpa
  /// menjalankan aksi apa pun — dipakai layar untuk menggerbangi aksi kasir
  /// (Split Bill / Gabung Bayar) yang dijalankan dari daftar transaksi.
  Future<String?> authorize(String pin) => _authorizer(pin);

  Future<String?> _authorizer(String pin) async {
    final stored = await _outletService.getVoidPin();
    if (pin == stored) {
      final user = await _authService.currentUserFromSession();
      return (user?.fullName.isNotEmpty ?? false)
          ? user!.fullName
          : (user?.username ?? 'Kasir');
    }
    try {
      final user = await _authService.loginByPin(pin);
      if (AuthService.voidAuthorizedRoles.contains(user.role)) {
        return user.fullName.isNotEmpty ? user.fullName : user.username;
      }
    } catch (_) {}
    return null;
  }

  /// VOID transaksi lunas. Mengembalikan 'ok' | 'invalid_pin' | 'error'.
  Future<String> voidOrder({
    required String orderId,
    required String pin,
    String reason = '',
  }) async {
    final authorizer = await _authorizer(pin);
    if (authorizer == null) return 'invalid_pin';
    try {
      await _orderRepo.voidPaidOrder(
        orderId: orderId,
        voidedBy: authorizer,
        reason: reason.isEmpty ? 'Dibatalkan kasir' : reason,
      );
      await loadOrders(reset: true);
      return 'ok';
    } catch (e) {
      _setState(_state.copyWith(
        errorMessage: 'Gagal void: '
            '${e.toString().replaceFirst('Exception: ', '')}',
      ));
      return 'error';
    }
  }

  /// BAYAR order belum lunas (seperti kasir: metode + jumlah + kembalian),
  /// digerbang PIN. Mengembalikan hasil {change, ...} atau null bila gagal
  /// (errorMessage terisi); 'invalid_pin' via return null + flag khusus tidak
  /// dipakai — cek dilakukan di awal dan dikembalikan sebagai string di UI.
  Future<Map<String, dynamic>?> payOrder({
    required String orderId,
    required String paymentMethod,
    required double paidAmount,
    required String pin,
  }) async {
    final authorizer = await _authorizer(pin);
    if (authorizer == null) {
      _setState(_state.copyWith(errorMessage: 'PIN salah / tidak berwenang'));
      return null;
    }
    try {
      // Snapshot untuk struk sebelum status berubah.
      final order = await _orderRepo.getOrderById(orderId);
      if (order == null) throw Exception('Order tidak ditemukan');
      final items = await _orderRepo.getOrderItems(orderId);

      final result = await _orderRepo.processPayment(
        orderId: orderId,
        paymentMethod: paymentMethod,
        paidAmount: paidAmount,
        createdBy: authorizer,
      );

      final charges = await _orderRepo.getOrderCharges(orderId);
      await _printReceipt(order, items, charges, result, authorizer);
      // Laci kasir: buka otomatis setelah lunas (ikut Pengaturan Printer).
      unawaited(CashDrawerService.instance
          .openAfterPayment(paymentMethod: paymentMethod));
      await loadOrders(reset: true);
      return result;
    } catch (e) {
      _setState(_state.copyWith(
        errorMessage: 'Gagal bayar: '
            '${e.toString().replaceFirst('Exception: ', '')}',
      ));
      return null;
    }
  }

  /// Cetak struk pembayaran lewat ANTRIAN cetak (durable, bisa cetak ulang) —
  /// pola sama dengan kasir.
  Future<void> _printReceipt(
    Order order,
    List<OrderItem> items,
    List<OrderAdditionalCharge> charges,
    Map<String, dynamic> result,
    String cashierName,
  ) async {
    try {
      final o = await _outletService.loadOutlet();
      final data = ReceiptData.fromPaymentResult(
        result: result,
        order: order,
        orderItems: items,
        charges: charges,
        cashierName: cashierName,
        outletName: o.name.isNotEmpty ? o.name : 'POS Resto',
        outletAddress: o.address,
        outletPhone: o.phone,
      );
      final ps = PrinterService();
      final saved = await ps.getSavedPrinters();
      if (saved.isEmpty) return;
      final cps = saved.where((p) => p.hasRole(PrinterRole.cashier)).toList();
      final printer = cps.isNotEmpty
          ? cps.first
          : saved.firstWhere((p) => !p.hasRole(PrinterRole.checker),
              orElse: () => saved.first);
      final builder = ReceiptBuilder(paperWidth: printer.paperCols);
      final label = 'Struk Bayar Meja ${order.tableNumber}';
      await PrintQueueService.instance.enqueueForPrinter(printer,
          bytes: builder.buildReceipt(data), label: label);
      // Rangkap: salinan ke-2..N ditandai "COPY".
      for (var c = 2; c <= printer.copies; c++) {
        await PrintQueueService.instance.enqueueForPrinter(printer,
            bytes: builder.buildReceipt(data, isCopy: true),
            label: '$label (Copy)');
      }
    } catch (e) {
      debugPrint('Cetak struk (transaksi) error: $e');
    }
  }
}
