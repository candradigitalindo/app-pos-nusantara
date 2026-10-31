import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/models/models.dart' as models;
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database db;

  Future<String> shift(DateTime start,
      {DateTime? end, double opening = 10000}) async {
    final id = Ulid.generate();
    await db.insert(
        'cashier_shifts',
        models.CashierShift(
          id: id,
          openedBy: 'Kasir uji',
          openedAt: start,
          closedAt: end,
          openingCash: opening,
          status: end == null ? 'open' : 'closed',
          createdAt: start,
          updatedAt: end ?? start,
        ).toMap());
    return id;
  }

  Future<String> order(double total, DateTime completed,
      {DateTime? voided, bool complimentary = false}) async {
    final id = Ulid.generate();
    await db.insert('orders', {
      'id': id,
      'table_number': id,
      'total_amount': total,
      'paid_amount': total,
      'payment_status': 'paid',
      'voided_at': voided?.toIso8601String(),
      'complimented_at': complimentary ? completed.toIso8601String() : null,
      'created_at': completed.toIso8601String(),
      'updated_at': completed.toIso8601String(),
    });
    await db.insert('transactions', {
      'id': Ulid.generate(),
      'order_id': id,
      'total_amount': total,
      'payment_method': 'cash',
      'status': voided == null ? 'completed' : 'cancelled',
      'transaction_date': completed.toIso8601String(),
    });
    if (complimentary) {
      await db.insert('order_additional_charges', {
        'order_id': id,
        'name': 'Kompliment',
        'charge_type': 'fixed',
        'value': 10000,
        'applied_amount': -10000,
      });
    }
    return id;
  }

  Future<void> payment(
      String orderId, double amount, DateTime at, String method) async {
    await db.insert('payments', {
      'id': Ulid.generate(),
      'order_id': orderId,
      'payment_method': method,
      'amount': amount,
      'created_by': 'Kasir uji',
      'created_at': at.toIso8601String(),
    });
  }

  Future<void> sale(double amount, DateTime at) async {
    final id = await order(amount, at);
    await payment(id, amount, at, 'cash');
  }

  Future<void> movement(
      String shiftId, String type, double amount, DateTime at) async {
    await db.insert('cashier_cash_movements', {
      'id': Ulid.generate(),
      'shift_id': shiftId,
      'movement_type': type,
      'amount': amount,
      'counterpart_name': 'Mutasi uji',
      'created_at': at.toIso8601String(),
    });
  }

  Future<Map<String, dynamic>> queuedReport(String id) async {
    final rows = await db.query('sync_queue',
        where: "entity_type='cashier_shift' AND entity_id=?", whereArgs: [id]);
    final payload = jsonDecode(rows.single['payload'] as String) as Map;
    return Map<String, dynamic>.from(payload['report'] as Map);
  }

  List<Map<String, dynamic>> days(Map<String, dynamic> report) =>
      (report['by_day'] as List).cast<Map<String, dynamic>>();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-daily-shift-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await AppDatabase.instance.database;
  });
  tearDown(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test(
      'overnight open shift separates daily sales and keeps complete close ledger',
      () async {
    final now = DateTime(2026, 10, 31, 18);
    final repo = CashierRepository(now: () => now);
    final id = await shift(DateTime(2026, 10, 30, 8).toUtc());
    await sale(100000, DateTime(2026, 10, 30, 12));
    await sale(50000, DateTime(2026, 10, 31, 12));

    final report = await repo.getShiftReport(id);
    expect(report['period_start'], DateTime(2026, 10, 30, 8).toIso8601String());
    expect(report['period_end'], now.toIso8601String());
    expect(report['crosses_day'], isTrue);
    expect(report['sales_total'], 150000);
    expect(report['sales_count'], 2);
    expect(report['expected_cash'], 160000);
    expect(
        days(report).map((row) => row['date']), ['2026-10-30', '2026-10-31']);
    expect(days(report).map((row) => row['sales_total']), [100000, 50000]);
    expect(
        days(report).every((row) => !row.containsKey('opening_cash')), isTrue);

    final closed = await repo.closeShift(shiftId: id, closedBy: 'Kasir');
    expect(closed.closingCash, 150000);
    expect(closed.carryOverCash, 160000);
    expect(await queuedReport(id), report);
    await sale(900000, DateTime(2026, 11, 1, 12));
    expect(await repo.getShiftReport(id), report,
        reason: 'Reprinting a closed shift must not absorb the next day');
    expect((await repo.getShiftTotals(id))['cash'], 150000);
  });

  test(
      'midnight handover assigns boundary payments to exactly one day and shift',
      () async {
    var now = DateTime(2026, 10, 31);
    final repo = CashierRepository(now: () => now);
    final id = await shift(DateTime(2026, 10, 30, 8));
    await sale(100000, DateTime(2026, 10, 30, 23, 59, 59, 999));
    await sale(50000, DateTime(2026, 10, 31));
    final next = await repo.handoverShift(
        currentShiftId: id, handoverToUserId: 'Kasir berikutnya');
    final previous = await repo.getShiftReport(id);
    expect(previous['crosses_day'], isFalse);
    expect(days(previous).map((row) => row['date']), ['2026-10-30']);
    expect(previous['sales_total'], 100000);
    expect(next.openingCash, 110000);
    expect(next.previousShiftId, id);
    now = DateTime(2026, 10, 31, 1);
    final current = await repo.getShiftReport(next.id);
    expect(current['sales_total'], 50000);
    expect(current['expected_cash'], 160000);
    expect(days(current).map((row) => row['date']), ['2026-10-31']);
    expect(days(current).single['sales_count'], 1);
  });

  test(
      'daily payments transactions and cash movements reconcile including free orders',
      () async {
    final repo = CashierRepository();
    final id =
        await shift(DateTime(2026, 10, 30, 8), end: DateTime(2026, 10, 31, 18));
    final split = await order(50000, DateTime(2026, 10, 31, 12));
    await payment(split, 20000, DateTime(2026, 10, 30, 12), 'cash');
    await payment(split, 30000, DateTime(2026, 10, 31, 12), 'qris');
    await order(0, DateTime(2026, 10, 31, 14), complimentary: true);
    final voided = await order(90000, DateTime(2026, 10, 30, 16),
        voided: DateTime(2026, 10, 31, 15));
    await payment(voided, 90000, DateTime(2026, 10, 30, 16), 'cash');
    await movement(id, 'in', 5000, DateTime(2026, 10, 30, 9));
    await movement(id, 'out', 2000, DateTime(2026, 10, 31, 10));
    final report = await repo.getShiftReport(id);
    final daily = days(report);
    expect(daily.map((row) => row['sales_count']), [0, 2]);
    expect(daily.map((row) => row['sales_total']), [20000, 30000]);
    expect(report['sales_count'], 2);
    expect(report['sales_total'], 50000);
    expect(daily[0]['by_method']['cash'], {'count': 1, 'total': 20000.0});
    expect(daily[1]['by_method']['qris'], {'count': 1, 'total': 30000.0});
    expect(daily[0]['cash_in_total'], 5000);
    expect(daily[1]['cash_out_total'], 2000);
    expect(report['expected_cash'], 33000);
    expect(report['compliment_count'], 1);
    expect(report['compliment_total'], 10000);
    expect(report['out_of_period_movement_count'], 0);
  });

  test(
      'legacy out-of-period movements remain in ledger and are visibly flagged',
      () async {
    final repo = CashierRepository();
    final id =
        await shift(DateTime(2026, 10, 30, 8), end: DateTime(2026, 10, 30, 18));
    await movement(id, 'out', 2000, DateTime(2026, 10, 30, 7));
    await movement(id, 'in', 7000, DateTime(2026, 10, 31, 10));
    final report = await repo.getShiftReport(id);
    expect(report['crosses_day'], isFalse);
    expect(report['cash_in_total'], 7000);
    expect(report['cash_out_total'], 2000);
    expect(report['expected_cash'], 15000);
    expect(report['out_of_period_movement_count'], 2);
    expect(days(report).map((row) => row['outside_shift']), [true, true]);
    await expectLater(
        repo.addCashMovement(
            shiftId: id,
            movementType: 'in',
            amount: 1000,
            counterpartName: 'Klien lama'),
        throwsException);
    expect(await db.query('cashier_cash_movements'), hasLength(2));
    expect(await db.query('sync_queue'), isEmpty);
  });

  for (final handover in [false, true]) {
    test(
        '${handover ? 'handover' : 'close'} pins totals and outbox to one closing instant',
        () async {
      final cutoff = DateTime(2026, 10, 31, 18);
      var calls = 0;
      final repo = CashierRepository(
          now: () => cutoff.add(Duration(milliseconds: calls++)));
      final id = await shift(DateTime(2026, 10, 31, 8));
      await sale(10000, cutoff.subtract(const Duration(milliseconds: 1)));
      await sale(100000, cutoff);
      if (handover) {
        final next = await repo.handoverShift(
            currentShiftId: id, handoverToUserId: 'Kasir berikutnya');
        expect(next.openingCash, 20000);
      } else {
        final closed = await repo.closeShift(shiftId: id, closedBy: 'Kasir');
        expect(closed.closingCash, 10000);
        expect(closed.carryOverCash, 20000);
        expect(calls, 1);
      }
      final saved =
          (await db.query('cashier_shifts', where: 'id=?', whereArgs: [id]))
              .single;
      expect(saved['closing_cash'], 10000);
      final report = await queuedReport(id);
      expect(report['period_end'], cutoff.toIso8601String());
      expect(report['sales_total'], 10000);
      expect(days(report).single['sales_total'], 10000);
      expect(await repo.getShiftReport(id), report);
    });
  }

  test('stale shift IDs cannot close handover or mutate another active shift',
      () async {
    final repo = CashierRepository(now: () => DateTime(2026, 10, 31, 18));
    // Simulate legacy overlapping open rows without silently rewriting them.
    final stale = await shift(DateTime(2026, 10, 30, 8));
    final active = await shift(DateTime(2026, 10, 31, 8));
    await expectLater(
        repo.closeShift(shiftId: stale, closedBy: 'Kasir'), throwsException);
    await expectLater(
        repo.handoverShift(currentShiftId: stale, handoverToUserId: 'Kasir'),
        throwsException);
    await expectLater(
        repo.addCashMovement(
            shiftId: stale,
            movementType: 'in',
            amount: 1000,
            counterpartName: 'Kasir'),
        throwsException);
    expect((await repo.getActiveShift())?.id, active);
    expect(await db.query('cashier_cash_movements'), isEmpty);
    expect(await db.query('sync_queue'), isEmpty);
    expect(
        (await db.query('cashier_shifts'))
            .every((row) => row['status'] == 'open'),
        isTrue);
  });

  test('long inactive gaps do not produce thousands of empty daily rows',
      () async {
    final repo = CashierRepository(now: () => DateTime(2026, 10, 31, 18));
    final id = await shift(DateTime(2000, 1, 1, 8));
    await sale(15000, DateTime(2020, 6, 15, 12));
    final report = await repo.getShiftReport(id);
    expect(report['crosses_day'], isTrue);
    expect(days(report).map((row) => row['date']),
        ['2000-01-01', '2020-06-15', '2026-10-31']);
    expect(report['sales_total'], 15000);
    expect(report['expected_cash'], 25000);
  });

  test('missing shift reports fail instead of presenting a zero ledger',
      () async {
    final repo = CashierRepository();
    await expectLater(repo.getShiftReport('missing'), throwsException);
    await expectLater(repo.getShiftTotals('missing'), throwsException);
  });
}
