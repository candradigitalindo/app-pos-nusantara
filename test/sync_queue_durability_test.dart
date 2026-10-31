import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/sync_queue_repository.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database db;
  final queue = SyncQueueRepository();
  final cashier = CashierRepository();

  Future<void> enqueueSnapshot(int version) => queue.enqueue(
        entityType: 'order',
        entityId: 'same-order',
        operation: 'update',
        payload: {'local_id': 'same-order', 'version': version},
      );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-outbox-durability-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await AppDatabase.instance.database;
  });

  setUp(() async {
    await db.delete('sync_queue');
    await db.delete('cashier_cash_movements');
    await db.delete('cashier_shifts');
    await db.delete('transactions');
  });

  tearDown(() => db.execute('DROP TRIGGER IF EXISTS reject_outbox_insert'));

  tearDownAll(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('failed replacement preserves the old pending snapshot', () async {
    await enqueueSnapshot(1);
    final original = (await queue.pending()).single;
    await db.execute('''
      CREATE TRIGGER reject_outbox_insert BEFORE INSERT ON sync_queue
      BEGIN SELECT RAISE(ABORT, 'simulated outbox failure'); END
    ''');

    await expectLater(enqueueSnapshot(2), throwsA(isA<DatabaseException>()));

    final pending = (await queue.pending()).single;
    expect(pending['id'], original['id']);
    expect(jsonDecode(pending['payload'] as String)['version'], 1);
  });

  test('concurrent replacements retain exactly one pending snapshot', () async {
    await enqueueSnapshot(1);
    await Future.wait([enqueueSnapshot(2), enqueueSnapshot(3)]);

    final pending = await queue.pending();
    expect(pending, hasLength(1));
    expect(jsonDecode(pending.single['payload'] as String)['version'],
        anyOf(2, 3));
  });

  test('late acknowledgement cannot confirm a newer replacement', () async {
    await enqueueSnapshot(1);
    final sent = (await queue.pending()).single;
    await enqueueSnapshot(2);
    final replacement = (await queue.pending()).single;
    expect(replacement['id'], isNot(sent['id']));

    // This is the exact acknowledgement write used when the earlier HTTP
    // request returns after a local edit has replaced its queued snapshot.
    await queue.markSuccess(sent['id'] as int);
    await queue.markFailed(sent['id'] as int, 'late failure', 0, 3);

    final pending = (await queue.pending()).single;
    expect(pending['id'], replacement['id']);
    expect(pending['retry_count'], 0);
    expect(jsonDecode(pending['payload'] as String)['version'], 2);
    expect((await queue.stats())['success'], 0);
  });

  test('opening a shift rolls back when its outbox cannot be written',
      () async {
    await db.execute('''
      CREATE TRIGGER reject_outbox_insert BEFORE INSERT ON sync_queue
      WHEN NEW.entity_type='cashier_shift'
      BEGIN SELECT RAISE(ABORT, 'simulated shift outbox failure'); END
    ''');
    await expectLater(cashier.openShift(openedBy: 'Kasir', openingCash: 10000),
        throwsA(isA<DatabaseException>()));
    expect(await cashier.getActiveShift(), isNull);
    expect(await db.query('cashier_shifts'), isEmpty);
    expect(await queue.pending(), isEmpty);

    await db.execute('DROP TRIGGER reject_outbox_insert');
    final shift =
        await cashier.openShift(openedBy: 'Kasir', openingCash: 10000);
    final job = (await queue.pending()).single;
    expect(job['entity_id'], shift.id);
    expect(jsonDecode(job['payload'] as String)['status'], 'open');
  });

  test('failed close preserves open shift and its queued snapshot', () async {
    final shift =
        await cashier.openShift(openedBy: 'Kasir', openingCash: 10000);
    final original = (await queue.pending()).single;
    await db.execute('''
      CREATE TRIGGER reject_outbox_insert BEFORE INSERT ON sync_queue
      WHEN NEW.entity_type='cashier_shift'
      BEGIN SELECT RAISE(ABORT, 'simulated shift outbox failure'); END
    ''');
    await expectLater(cashier.closeShift(shiftId: shift.id, closedBy: 'Kasir'),
        throwsA(isA<DatabaseException>()));
    final unchanged = await cashier.getActiveShift();
    expect(unchanged?.id, shift.id);
    expect(unchanged?.closedAt, isNull);
    expect((await queue.pending()).single['id'], original['id']);

    await db.execute('DROP TRIGGER reject_outbox_insert');
    final closed =
        await cashier.closeShift(shiftId: shift.id, closedBy: 'Kasir');
    expect(closed.status, 'closed');
    expect(await cashier.getActiveShift(), isNull);
    final payload =
        jsonDecode((await queue.pending()).single['payload'] as String);
    expect(payload['status'], 'closed');
    expect(payload['opened_at'], shift.openedAt.toUtc().toIso8601String());
    expect(payload['carry_over_cash'], 10000);
  });

  test('failed second handover job rolls back both shifts and both jobs',
      () async {
    final shift = await cashier.openShift(openedBy: 'Lama', openingCash: 10000);
    final original = (await queue.pending()).single;
    // The old shift's update is inserted first; reject only the new shift's
    // create so this exercises rollback after a successful earlier enqueue.
    await db.execute('''
      CREATE TRIGGER reject_outbox_insert BEFORE INSERT ON sync_queue
      WHEN NEW.entity_type='cashier_shift' AND NEW.operation='create'
      BEGIN SELECT RAISE(ABORT, 'simulated second handover job failure'); END
    ''');
    await expectLater(
        cashier.handoverShift(
            currentShiftId: shift.id, handoverToUserId: 'Baru'),
        throwsA(isA<DatabaseException>()));
    expect(await db.query('cashier_shifts'), hasLength(1));
    final unchanged = await cashier.getActiveShift();
    expect(unchanged?.id, shift.id);
    expect(unchanged?.handoverTo, isNull);
    expect((await queue.pending()).single['id'], original['id']);

    await db.execute('DROP TRIGGER reject_outbox_insert');
    final replacement = await cashier.handoverShift(
        currentShiftId: shift.id, handoverToUserId: 'Baru');
    expect(replacement.previousShiftId, shift.id);
    expect(replacement.openingCash, 10000);
    expect((await cashier.getActiveShift())?.id, replacement.id);
    final jobs = await queue.pending();
    expect(jobs, hasLength(2));
    final payloads = jobs.map((j) => jsonDecode(j['payload'] as String) as Map);
    expect(payloads.singleWhere((p) => p['local_id'] == shift.id)['status'],
        'closed');
    expect(
        payloads.singleWhere((p) => p['local_id'] == replacement.id)['status'],
        'open');
  });

  test('reconciliation follows latest job instead of historical success',
      () async {
    final id = Ulid.generate();
    await db.insert('transactions', {
      'id': id,
      'total_amount': 15000,
      'payment_method': 'cash',
      'status': 'completed',
      'transaction_date': DateTime.now().toIso8601String(),
    });
    Future<void> enqueue() => queue.enqueue(
        entityType: 'transaction',
        entityId: id,
        operation: 'update',
        payload: {'local_id': id});
    await enqueue();
    await queue.markSuccess((await queue.pending()).single['id'] as int);
    expect((await queue.reconciliation())['synced_count'], 1);

    await enqueue();
    final newest = (await queue.pending()).single['id'] as int;
    final pending = await queue.reconciliation();
    expect(pending['synced_count'], 0);
    expect(pending['pending_count'], 1);
    expect(pending['at_risk_amount'], 15000);

    await queue.markFailed(newest, 'unconfirmed', 2, 3);
    final failed = await queue.reconciliation();
    expect(failed['synced_count'], 0);
    expect(failed['failed_count'], 1);
    await queue.markSuccess(newest);
    expect((await queue.reconciliation())['synced_count'], 1);
  });

  test('cash movement is rolled back when its outbox insert fails', () async {
    final shift = await cashier.openShift(openedBy: 'Kasir', openingCash: 0);
    await db.delete('sync_queue');
    await db.execute('''
      CREATE TRIGGER reject_outbox_insert BEFORE INSERT ON sync_queue
      WHEN NEW.entity_type='cashier_cash_movement'
      BEGIN SELECT RAISE(ABORT, 'simulated outbox failure'); END
    ''');

    await expectLater(
        cashier.addCashMovement(
          shiftId: shift.id,
          movementType: 'out',
          amount: 12000,
          counterpartName: 'Kurir',
        ),
        throwsA(isA<DatabaseException>()));
    expect(await db.query('cashier_cash_movements'), isEmpty);
    expect(await queue.pending(), isEmpty);

    await db.execute('DROP TRIGGER reject_outbox_insert');
    final movement = await cashier.addCashMovement(
      shiftId: shift.id,
      movementType: 'out',
      amount: 12000,
      counterpartName: 'Kurir',
    );
    expect(await db.query('cashier_cash_movements'), hasLength(1));
    final job = (await queue.pending()).single;
    final payload = jsonDecode(job['payload'] as String) as Map;
    expect(job['entity_id'], movement.id);
    expect(payload['amount'], 12000);
    expect(payload['shift_id'], shift.id);
    expect(payload['created_at'], movement.createdAt.toUtc().toIso8601String());
  });

  test('legacy movement backfill preserves identity and runs only once',
      () async {
    final shift = await cashier.openShift(openedBy: 'Kasir', openingCash: 0);
    final movement = await cashier.addCashMovement(
      shiftId: shift.id,
      movementType: 'in',
      amount: 5000,
      counterpartName: 'Tambahan modal',
    );
    // Simulate the pre-fix state: business row committed, outbox absent.
    await db.delete('sync_queue');
    expect(await cashier.enqueueUnsyncedCashMovements(), 1);
    expect(await cashier.enqueueUnsyncedCashMovements(), 0);

    final job = (await queue.pending()).single;
    final payload = jsonDecode(job['payload'] as String) as Map;
    expect(job['entity_id'], movement.id);
    expect(payload['created_at'], movement.createdAt.toUtc().toIso8601String());
    await queue.markSuccess(job['id'] as int);
    expect(await cashier.enqueueUnsyncedCashMovements(), 0);
    expect(await db.query('cashier_cash_movements'), hasLength(1));
  });
}
