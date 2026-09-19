import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../repositories/cashier_repository.dart';
import '../repositories/product_repository.dart';
import '../repositories/table_repository.dart';
import '../services/cloud_sync_service.dart';
import '../services/outlet_service.dart';

class SettingsState {
  final OutletInfo outletInfo;
  final bool isLoading;
  final bool isSaving;
  final String? errorMessage;
  final String? successMessage;

  const SettingsState({
    this.outletInfo = const OutletInfo(),
    this.isLoading = false,
    this.isSaving = false,
    this.errorMessage,
    this.successMessage,
  });

  SettingsState copyWith({
    OutletInfo? outletInfo,
    bool? isLoading,
    bool? isSaving,
    String? errorMessage,
    bool clearError = false,
    String? successMessage,
    bool clearSuccess = false,
  }) {
    return SettingsState(
      outletInfo: outletInfo ?? this.outletInfo,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      successMessage:
          clearSuccess ? null : (successMessage ?? this.successMessage),
    );
  }
}

class SettingsController extends ChangeNotifier {
  final OutletService _outletService;
  final CashierRepository _cashierRepo;
  final ProductRepository _productRepo;
  final TableRepository _tableRepo;
  final AppDatabase _db;

  SettingsState _state = const SettingsState();
  SettingsState get state => _state;

  SettingsController({
    OutletService? outletService,
    CashierRepository? cashierRepo,
    ProductRepository? productRepo,
    TableRepository? tableRepo,
    AppDatabase? db,
  })  : _outletService = outletService ?? OutletService(),
        _cashierRepo = cashierRepo ?? CashierRepository(),
        _productRepo = productRepo ?? ProductRepository(),
        _tableRepo = tableRepo ?? TableRepository(),
        _db = db ?? AppDatabase.instance;

  void _setState(SettingsState s) {
    _state = s;
    notifyListeners();
  }

  // ── Load ─────────────────────────────────────────────────────────────────

  Future<void> loadSettings() async {
    _setState(_state.copyWith(isLoading: true, clearError: true));
    try {
      final info = await _outletService.loadOutlet();
      _setState(_state.copyWith(outletInfo: info, isLoading: false));
    } catch (e) {
      _setState(_state.copyWith(
        isLoading: false,
        errorMessage: 'Gagal memuat pengaturan: $e',
      ));
    }
  }

  // ── Save Outlet ───────────────────────────────────────────────────────────

  Future<void> saveOutlet(OutletInfo info) async {
    _setState(_state.copyWith(isSaving: true, clearError: true));
    try {
      await _outletService.saveOutlet(info);
      _setState(_state.copyWith(
        outletInfo: info,
        isSaving: false,
        successMessage: 'Pengaturan outlet berhasil disimpan',
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isSaving: false,
        errorMessage: 'Gagal menyimpan outlet: $e',
      ));
    }
  }

  // ── Save Cloud ────────────────────────────────────────────────────────────

  Future<void> saveCloud({
    required String cloudApiUrl,
    required String cloudApiKey,
    String? cloudOutletId,
    required bool syncEnabled,
    required int syncInterval,
  }) async {
    _setState(_state.copyWith(isSaving: true, clearError: true));
    try {
      await _outletService.saveCloudSettings(
        cloudApiUrl: cloudApiUrl,
        cloudApiKey: cloudApiKey,
        cloudOutletId: cloudOutletId,
        syncEnabled: syncEnabled,
        syncInterval: syncInterval,
      );
      _setState(_state.copyWith(
        outletInfo: _state.outletInfo.copyWith(
          cloudApiUrl: cloudApiUrl,
          cloudApiKey: cloudApiKey,
          cloudOutletId: cloudOutletId,
          syncEnabled: syncEnabled,
          syncInterval: syncInterval,
        ),
        isSaving: false,
        successMessage: 'Pengaturan cloud berhasil disimpan',
      ));

      // Terapkan perubahan ke worker sync (start/stop/interval)
      await CloudSyncService.instance.restart();
    } catch (e) {
      _setState(_state.copyWith(
        isSaving: false,
        errorMessage: 'Gagal menyimpan cloud: $e',
      ));
    }
  }

  // ── Save Retention ────────────────────────────────────────────────────────

  Future<void> saveRetention(int days) async {
    _setState(_state.copyWith(isSaving: true, clearError: true));
    try {
      await _outletService.saveRetentionDays(days);
      _setState(_state.copyWith(
        outletInfo: _state.outletInfo.copyWith(retentionDays: days),
        isSaving: false,
        successMessage: 'Retensi data berhasil disimpan',
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isSaving: false,
        errorMessage: 'Gagal menyimpan retensi: $e',
      ));
    }
  }

  // ── Shift ─────────────────────────────────────────────────────────────────

  Future<void> openShift({required double openingCash}) async {
    _setState(_state.copyWith(isSaving: true, clearError: true));
    try {
      await _cashierRepo.openShift(
        openedBy: 'Kasir',
        openingCash: openingCash,
      );
      _setState(_state.copyWith(
        isSaving: false,
        successMessage: 'Shift berhasil dibuka',
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isSaving: false,
        errorMessage: 'Gagal membuka shift: $e',
      ));
    }
  }

  Future<void> closeShift() async {
    _setState(_state.copyWith(isSaving: true, clearError: true));
    try {
      final shift = await _cashierRepo.getActiveShift();
      if (shift == null) throw Exception('Tidak ada shift aktif');
      await _cashierRepo.closeShift(shiftId: shift.id, closedBy: 'Kasir');
      _setState(_state.copyWith(
        isSaving: false,
        successMessage: 'Shift berhasil ditutup',
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isSaving: false,
        errorMessage: 'Gagal menutup shift: $e',
      ));
    }
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> seedData() async {
    _setState(_state.copyWith(isSaving: true, clearError: true));
    try {
      await _productRepo.seedSampleData();
      await _tableRepo.seedTables(count: 10);
      _setState(_state.copyWith(
        isSaving: false,
        successMessage: 'Data contoh berhasil ditambahkan',
      ));
    } catch (e) {
      _setState(_state.copyWith(
        isSaving: false,
        errorMessage: 'Gagal seed data: $e',
      ));
    }
  }

  Future<bool> resetDatabase() async {
    _setState(_state.copyWith(isSaving: true, clearError: true));
    try {
      final db = await _db.database;
      await db.transaction((txn) async {
        // Biaya tambahan per order (tidak punya cascade) — hapus eksplisit
        await txn.delete('order_additional_charges');
        // Order → cascade ke order_items & payments
        await txn.delete('orders');
        // Transaksi → cascade ke transaction_items
        await txn.delete('transactions');
        // Antrian sync agar data yang dihapus tidak terkirim ke cloud
        await txn.delete('sync_queue');
        // Antrian & job cetak
        await txn.delete('print_queue');
        await txn.delete('kitchen_print_jobs');
        // Shift kasir & pergerakan kas
        await txn.delete('cashier_cash_movements');
        await txn.delete('cashier_shifts');
        // Bebaskan semua meja yang masih terisi
        await txn.update('tables', {
          'status': 'available',
          'updated_at': DateTime.now().toIso8601String(),
        });
      });
      _setState(_state.copyWith(
        isSaving: false,
        successMessage: 'Database berhasil direset',
      ));
      return true;
    } catch (e) {
      _setState(_state.copyWith(
        isSaving: false,
        errorMessage: 'Gagal reset database: $e',
      ));
      return false;
    }
  }

  // ── Messages ──────────────────────────────────────────────────────────────

  void clearMessages() {
    _setState(_state.copyWith(clearError: true, clearSuccess: true));
  }
}
