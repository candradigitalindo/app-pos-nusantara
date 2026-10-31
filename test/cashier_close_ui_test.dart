import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/controllers/cashier_controller.dart';
import 'package:pos_resto/models/models.dart' as m;
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/repositories/table_repository.dart';
import 'package:pos_resto/screens/cashier/cashier_screen.dart';
import 'package:pos_resto/screens/cashier/shift_period_summary.dart';
import 'package:pos_resto/services/auth_service.dart';
import 'package:pos_resto/services/receipt_builder.dart';
import 'package:pos_resto/utils/currency.dart';
import 'package:pos_resto/widgets/ui/ui.dart';
import 'package:sqflite/sqflite.dart';

final _start = DateTime(2026, 10, 30, 20);
final _end = DateTime(2026, 10, 31, 10);
m.CashierShift _shift(String id) => m.CashierShift(
    id: id,
    openedBy: 'Kasir Uji',
    openedAt: _start,
    openingCash: 100,
    createdAt: _start,
    updatedAt: _start);

Map<String, dynamic> _report() => {
      'period_start': _start.toIso8601String(),
      'period_end': _end.toIso8601String(),
      'crosses_day': true,
      'opening_cash': 100.0,
      'expected_cash': 430.0,
      'sales_count': 3,
      'sales_total': 300.0,
      'cash_in_total': 50.0,
      'cash_out_total': 20.0,
      'by_method': {
        'cash': {'count': 3, 'total': 300.0}
      },
      'by_day': [
        {
          'date': '2026-10-30',
          'sales_count': 1,
          'sales_total': 100.0,
          'cash_in_total': 50.0,
          'cash_out_total': 0.0
        },
        {
          'date': '2026-10-31',
          'sales_count': 2,
          'sales_total': 200.0,
          'cash_in_total': 0.0,
          'cash_out_total': 20.0
        },
      ],
    };

class _Products extends ProductRepository {
  @override
  Future<List<m.Product>> getProducts({String? categoryId}) async => [];
  @override
  Future<List<m.Category>> getCategories() async => [];
  @override
  Future<Map<String, int>> addonCountByProduct() async => {};
}

class _Tables extends TableRepository {
  @override
  Future<List<m.RestaurantTable>> getTables() async => [];
}

class _Auth extends AuthService {
  @override
  Future<m.User?> currentUserFromSession() async => null;
}

class _Cashier extends CashierRepository {
  m.CashierShift? active = _shift('reviewed');
  final readIds = <String>[];
  final closeIds = <String>[];
  bool failClose = false;
  bool committed = false;
  @override
  Future<m.CashierShift?> getActiveShift({DatabaseExecutor? executor}) async =>
      active;
  @override
  Future<Map<String, double>> getShiftTotals(String shiftId) async {
    readIds.add(shiftId);
    return {'cash': 300};
  }

  @override
  Future<List<m.CashMovement>> getShiftMovements(String shiftId) async {
    readIds.add(shiftId);
    return [];
  }

  @override
  Future<Map<String, dynamic>> getShiftReport(String shiftId,
      {DatabaseExecutor? executor}) async {
    readIds.add(shiftId);
    if (committed) throw Exception('Laporan printer sementara tidak tersedia');
    return _report();
  }

  @override
  Future<m.CashierShift> closeShift(
      {required String shiftId,
      required String closedBy,
      double? closingCash,
      double? closingCard,
      double? closingQris,
      double? closingTransfer,
      String? notes}) async {
    closeIds.add(shiftId);
    if (failClose) throw Exception('Gagal menulis penutupan');
    final closed = m.CashierShift.fromMap({
      ...active!.toMap(),
      'closed_at': _end.toIso8601String(),
      'status': 'closed'
    });
    committed = true;
    active = null;
    return closed;
  }
}

void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    required Future<Map<String, dynamic>> Function() report,
    required Future<String?> Function() close,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => CloseShiftDialog(
                                activeShift: _shift('reviewed'),
                                getShiftReport: report,
                                getShiftMovements: () async => [],
                                onClose: close,
                              )),
                      child: const Text('Open test'),
                    )))));
    await tester.tap(find.text('Open test'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'closing dialog separates calendar days even when shift is shorter than 24 hours',
      (tester) async {
    await openDialog(tester,
        report: () async => _report(), close: () async => null);
    expect(find.textContaining('30/10/2026 20:00 – 31/10/2026 10:00'),
        findsOneWidget);
    expect(find.textContaining('Shift melintasi tanggal.'), findsOneWidget);
    expect(find.text('2026-10-30'), findsOneWidget);
    expect(find.text('2026-10-31'), findsOneWidget);
    expect(find.text(CurrencyHelper.format(200)), findsOneWidget);
    expect(find.text('Total Penjualan Shift'), findsOneWidget);
    expect(find.text(CurrencyHelper.format(430)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed report load disables closing until successful retry',
      (tester) async {
    var fail = true, calls = 0;
    await openDialog(tester, report: () async {
      if (fail) throw Exception('Pembacaan gagal');
      return _report();
    }, close: () async {
      calls++;
      return null;
    });
    final button = find.byWidgetPredicate(
        (widget) => widget is AppButton && widget.label == 'TUTUP KASIR');
    expect(tester.widget<AppButton>(button).onPressed, isNull);
    expect(find.byKey(const Key('shift-load-error')), findsOneWidget);
    expect(calls, 0);
    fail = false;
    await tester.tap(find.text('Muat Ulang Ringkasan'));
    await tester.pumpAndSettle();
    expect(tester.widget<AppButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(CloseShiftDialog), findsNothing);
  });

  testWidgets(
      'failed close stays visible and successful retry waits for commit',
      (tester) async {
    var calls = 0;
    final commit = Completer<String?>();
    await openDialog(tester,
        report: () async => _report(),
        close: () async {
          calls++;
          if (calls == 1) return 'Gagal menulis penutupan';
          return commit.future;
        });
    final button = find.byWidgetPredicate(
        (widget) => widget is AppButton && widget.label == 'TUTUP KASIR');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(CloseShiftDialog), findsOneWidget);
    expect(find.text('Gagal menulis penutupan'), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(find.byType(CloseShiftDialog), findsOneWidget);
    expect(tester.widget<AppButton>(button).onPressed, isNull);
    expect(tester.widget<AppButton>(button).loading, isTrue);
    commit.complete(null);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(CloseShiftDialog), findsNothing);
  });

  testWidgets(
      'same-day report and historical out-of-window cash are labelled accurately',
      (tester) async {
    final report = _report()
      ..['crosses_day'] = false
      ..['period_end'] = DateTime(2026, 10, 30, 23).toIso8601String();
    report['out_of_period_movement_count'] = 1;
    (report['by_day'] as List).last['outside_shift'] = true;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320,
                child: ShiftPeriodSummary(
                    shift: _shift('reviewed'), report: report)))));
    expect(find.textContaining('Shift melintasi tanggal.'), findsNothing);
    expect(
        find.text('Ada mutasi kas di luar rentang shift; periksa rincian kas.'),
        findsOneWidget);
    expect(find.text('Memuat mutasi di luar rentang shift'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
      'controller pins report reads and refuses to close or hand over a replacement shift',
      () async {
    final repo = _Cashier();
    final controller = CashierController(
        cashierRepo: repo,
        productRepo: _Products(),
        tableRepo: _Tables(),
        authService: _Auth());
    addTearDown(controller.dispose);
    await controller.loadData();
    repo.active = _shift('replacement');
    await controller.refreshExternal();
    await controller.getShiftReport(shiftId: 'reviewed');
    await controller.getShiftTotals(shiftId: 'reviewed');
    await controller.getShiftMovements(shiftId: 'reviewed');
    expect(repo.readIds, ['reviewed', 'reviewed', 'reviewed']);
    expect(await controller.closeShift(shiftId: 'reviewed'),
        contains('Shift sudah berubah'));
    expect(
        await controller.swapShift(
            shiftId: 'reviewed', handoverTo: 'Next', newOpeningCash: 430),
        contains('Shift sudah berubah'));
    expect(repo.closeIds, isEmpty);
    expect(controller.state.activeShift!.id, 'replacement');
  });

  test(
      'controller preserves failed close then treats committed close as success despite printer report failure',
      () async {
    final repo = _Cashier()..failClose = true;
    final controller = CashierController(
        cashierRepo: repo,
        productRepo: _Products(),
        tableRepo: _Tables(),
        authService: _Auth());
    addTearDown(controller.dispose);
    await controller.loadData();
    expect(await controller.closeShift(shiftId: 'reviewed'),
        contains('Gagal menulis penutupan'));
    expect(controller.state.activeShift!.id, 'reviewed');
    expect(controller.state.isProcessing, isFalse);
    repo.failClose = false;
    expect(await controller.closeShift(shiftId: 'reviewed'), isNull);
    expect(repo.committed, isTrue);
    expect(controller.state.activeShift, isNull);
    expect(controller.state.errorMessage, isNull);
    expect(repo.closeIds, ['reviewed', 'reviewed']);
  });

  test(
      'close and handover receipts include daily dates while retaining full shift ledger',
      () {
    for (final title in ['TUTUP KASIR', 'GANTI SHIFT']) {
      final bytes = const ReceiptBuilder(paperWidth: 48).buildShiftReport(
          title: title,
          outletName: 'Outlet Uji',
          shift: _shift('reviewed'),
          report: _report(),
          closedAt: _end);
      final text = utf8.decode(bytes, allowMalformed: true);
      expect(text, contains('30/10/2026 20:00'));
      expect(text, contains('31/10/2026 10:00'));
      expect(text, contains('SHIFT MELINTASI TANGGAL'));
      expect(text, contains('PENJUALAN PER HARI'));
      expect(text, matches(RegExp(r'2026-10-30 \(1\) +100')));
      expect(text, matches(RegExp(r'2026-10-31 \(2\) +200')));
      expect(text, matches(RegExp(r'Penjualan Shift +300')));
      expect(text, matches(RegExp(r'KAS SEHARUSNYA +430')));
      expect(text, isNot(contains('Periksa mutasi di luar rentang shift.')));
    }
  });
}
