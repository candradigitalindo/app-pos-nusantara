import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../models/models.dart';
import '../repositories/cashier_repository.dart';
import '../repositories/order_repository.dart';
import '../services/auth_service.dart';
import '../services/data_retention_service.dart';

/// State untuk DashboardScreen
class DashboardState {
  final User? currentUser;
  final CashierShift? activeShift;
  final int totalActiveOrders;
  final int totalTables;
  final int occupiedTables;
  final double todayRevenue;
  final bool isLoading;
  final String? errorMessage;

  const DashboardState({
    this.currentUser,
    this.activeShift,
    this.totalActiveOrders = 0,
    this.totalTables = 0,
    this.occupiedTables = 0,
    this.todayRevenue = 0,
    this.isLoading = false,
    this.errorMessage,
  });

  bool get hasActiveShift => activeShift != null;

  DashboardState copyWith({
    User? currentUser,
    CashierShift? activeShift,
    bool clearShift = false,
    int? totalActiveOrders,
    int? totalTables,
    int? occupiedTables,
    double? todayRevenue,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
  }) {
    return DashboardState(
      currentUser: currentUser ?? this.currentUser,
      activeShift: clearShift ? null : (activeShift ?? this.activeShift),
      totalActiveOrders: totalActiveOrders ?? this.totalActiveOrders,
      totalTables: totalTables ?? this.totalTables,
      occupiedTables: occupiedTables ?? this.occupiedTables,
      todayRevenue: todayRevenue ?? this.todayRevenue,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Controller untuk DashboardScreen
class DashboardController extends ChangeNotifier {
  final AuthService _authService;
  final CashierRepository _cashierRepo;
  final OrderRepository _orderRepo;
  final DataRetentionService _retentionService;
  final AppDatabase _db;

  DashboardState _state = const DashboardState();
  DashboardState get state => _state;

  DashboardController({
    AuthService? authService,
    CashierRepository? cashierRepo,
    OrderRepository? orderRepo,
    DataRetentionService? retentionService,
    AppDatabase? db,
  })  : _authService = authService ?? AuthService(),
        _cashierRepo = cashierRepo ?? CashierRepository(),
        _orderRepo = orderRepo ?? OrderRepository(),
        _retentionService = retentionService ?? DataRetentionService(),
        _db = db ?? AppDatabase.instance;

  void _setState(DashboardState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<void> initialize() async {
    _setState(_state.copyWith(isLoading: true, clearError: true));
    try {
      // Run data retention cleanup in background
      _retentionService.runIfNeeded().then((deleted) {
        if (deleted > 0) {
          debugPrint('Data retention: $deleted records purged');
        }
      });

      final user = _authService.currentUser;
      final results = await Future.wait([
        _cashierRepo.getActiveShift(),
        _orderRepo.countOrders(),
        _getTableStats(),
        _getTodayRevenue(),
      ]);

      final shift = results[0] as CashierShift?;
      final totalOrders = results[1] as int;
      final tableStats = results[2] as Map<String, int>;
      final revenue = results[3] as double;

      _setState(_state.copyWith(
        currentUser: user,
        activeShift: shift,
        totalActiveOrders: totalOrders,
        totalTables: tableStats['total'] ?? 0,
        occupiedTables: tableStats['occupied'] ?? 0,
        todayRevenue: revenue,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal memuat dashboard: $e',
      ));
    }
  }

  Future<void> refresh() => initialize();

  Future<void> openShift({
    required String openedBy,
    required double openingCash,
  }) async {
    _setState(_state.copyWith(isLoading: true, clearError: true));
    try {
      final shift = await _cashierRepo.openShift(
        openedBy: openedBy,
        openingCash: openingCash,
      );
      _setState(_state.copyWith(
        activeShift: shift,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal buka shift: $e',
      ));
    }
  }

  Future<void> closeShift({
    required String closedBy,
    double? closingCash,
    String? notes,
  }) async {
    if (_state.activeShift == null) return;
    _setState(_state.copyWith(isLoading: true, clearError: true));
    try {
      await _cashierRepo.closeShift(
        shiftId: _state.activeShift!.id,
        closedBy: closedBy,
        closingCash: closingCash,
        notes: notes,
      );
      _setState(_state.copyWith(
        clearShift: true,
        isLoading: false,
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal tutup shift: $e',
      ));
    }
  }

  Future<void> logout() async {
    await _authService.logout();
  }

  void clearError() {
    _setState(_state.copyWith(clearError: true));
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  Future<Map<String, int>> _getTableStats() async {
    final results = await _db.query('tables');
    final total = results.length;
    final occupied = results.where((t) => t['status'] == 'occupied').length;
    return {'total': total, 'occupied': occupied};
  }

  Future<double> _getTodayRevenue() async {
    final today = DateTime.now();
    final startOfDay =
        DateTime(today.year, today.month, today.day).toIso8601String();
    final results = await _db.rawQuery(
      '''
      SELECT COALESCE(SUM(p.amount), 0) as total
      FROM payments p
      JOIN orders o ON o.id = p.order_id
      WHERE p.created_at >= ? AND o.voided_at IS NULL
      ''',
      [startOfDay],
    );
    return (results.first['total'] as num?)?.toDouble() ?? 0;
  }
}
