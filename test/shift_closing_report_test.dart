// Laporan TUTUP KASIR harus memuat SEMUA menu yang terjual dari buka sampai
// tutup kasir — lewat alur kasir yang sebenarnya, bukan data sintetis — dan
// cetak ulangnya identik dengan cetakan pertama & payload cloud, walau data
// tablet berubah sesudah shift ditutup.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/controllers/cashier_controller.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/services/auth_service.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoSessionAuth extends AuthService {
  @override
  Future<User?> currentUserFromSession() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Database db;
  final orders = OrderRepository();
  final cashier = CashierRepository();
  late Map<String, Product> menu;

  Future<Product> product(String name, double price, String kind) async {
    final p = await ProductRepository().createProduct(name: name, price: price);
    await db.update('products', {'menu_kind': kind},
        where: 'id = ?', whereArgs: [p.id]);
    return p;
  }

  OrderItemInput line(String name, int qty) =>
      OrderItemInput(productId: menu[name]!.id, qty: qty);

  Future<Order> order(String table, List<OrderItemInput> items) =>
      orders.createOrder(tableNumber: table, items: items);

  Future<void> payInFull(Order o) async {
    final fresh = (await orders.getOrderById(o.id))!;
    await orders.processPayment(
        orderId: o.id, paymentMethod: 'cash', paidAmount: fresh.totalAmount);
  }

  Future<String> itemId(String orderId, String name) async =>
      (await orders.getOrderItems(orderId))
          .firstWhere((i) => i.productName == name)
          .id;

  /// {nama menu: qty} dari laporan.
  Map<String, int> soldQuantities(Map<String, dynamic> report) {
    final out = <String, int>{};
    for (final group in (report['menu_items_by_kind'] as List).cast<Map>()) {
      for (final item in (group['items'] as List).cast<Map>()) {
        final name = item['product_name'] as String;
        out[name] = (out[name] ?? 0) + (item['quantity'] as num).toInt();
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> cloudShiftReport(String shiftId) async {
    final rows = await db.query('sync_queue',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['cashier_shift', shiftId],
        orderBy: 'id DESC');
    final payload = jsonDecode(rows.first['payload'] as String) as Map;
    return (payload['report'] as Map).cast<String, dynamic>();
  }

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-closing-report-');
    await databaseFactory.setDatabasesPath(directory.path);
    SharedPreferences.setMockInitialValues({'saved_printers': <String>[]});
    db = await AppDatabase.instance.database;
    await db.delete('additional_charges'); // total = subtotal, mudah dihitung
    menu = {
      'Nasi Goreng': await product('Nasi Goreng', 25000, 'food'),
      'Ayam Bakar': await product('Ayam Bakar', 30000, 'food'),
      'Es Teh': await product('Es Teh', 8000, 'beverage'),
      'Kopi Susu': await product('Kopi Susu', 18000, 'beverage'),
    };
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  /// Satu shift lengkap lewat semua alur kasir. Mengembalikan id shift
  /// tertutup, id order lunas yang bisa di-void sesudahnya, dan jumlah menu
  /// yang SEHARUSNYA terjual.
  Future<({String shiftId, String paidOrderId, Map<String, int> expected})>
      runFullShift() async {
    // Pesanan dibuat SEBELUM kasir dibuka, dibayar sesudahnya → ikut shift ini.
    final early = await order('L', [line('Nasi Goreng', 1)]);

    final shift =
        await cashier.openShift(openedBy: 'Kasir Uji', openingCash: 100000);

    // A — bayar penuh.
    final a = await order('A', [line('Nasi Goreng', 2), line('Es Teh', 1)]);
    await payInFull(a);

    // B — split bill dua kali sampai lunas.
    final b = await order('B', [line('Ayam Bakar', 1)]);
    await orders.splitBillPayment(
        orderId: b.id, amount: 10000, paymentMethod: 'qris');
    await orders.splitBillPayment(
        orderId: b.id, amount: 20000, paymentMethod: 'cash');

    // C — kompliment (gratis, tanpa baris payments).
    final c = await order('C', [line('Kopi Susu', 3)]);
    await orders.complimentOrder(orderId: c.id, complimentBy: 'Manager');

    // D ← E — gabung meja, lalu bayar.
    final d = await order('D', [line('Nasi Goreng', 1)]);
    final e = await order('E', [line('Es Teh', 2)]);
    await orders.mergeOrders(targetOrderId: d.id, sourceOrderId: e.id);
    await payInFull(d);

    // F → G — pindah sebagian item ke meja lain, keduanya dibayar.
    final f = await order('F', [line('Ayam Bakar', 2)]);
    final g = await order('G', [line('Kopi Susu', 1)]);
    await orders.transferItemQty(
        itemId: await itemId(f.id, 'Ayam Bakar'), qty: 1, targetOrderId: g.id);
    await payInFull(f);
    await payInFull(g);

    // H → Titipan → I — item dititipkan lalu ditarik ke tagihan lain.
    final h = await order('H', [line('Kopi Susu', 1), line('Es Teh', 1)]);
    await orders.parkItem(itemId: await itemId(h.id, 'Es Teh'));
    final i = await order('I', [line('Nasi Goreng', 1)]);
    final held = (await db.rawQuery('''
      SELECT oi.id FROM order_items oi JOIN orders o ON o.id = oi.order_id
      WHERE o.is_holding = 1 AND oi.product_name = 'Es Teh'
    ''')).single['id'] as String;
    await orders.pullHeldItem(itemId: held, targetOrderId: i.id);
    await payInFull(h);
    await payInFull(i);

    // J — void sebagian sebelum bayar: hanya sisa yang terjual.
    final j = await order('J', [line('Nasi Goreng', 4)]);
    await orders.voidOrderItem(
        itemId: await itemId(j.id, 'Nasi Goreng'), qty: 1, voidedBy: 'Manager');
    await payInFull(j);

    // K — lunas lalu di-void: BUKAN penjualan.
    final k = await order('K', [line('Ayam Bakar', 1)]);
    await payInFull(k);
    await orders.voidPaidOrder(
        orderId: k.id, voidedBy: 'Manager', reason: 'Salah input');

    await payInFull(early);

    final closed =
        await cashier.closeShift(shiftId: shift.id, closedBy: 'Kasir Uji');
    return (
      shiftId: closed.id,
      paidOrderId: a.id,
      expected: {
        'Nasi Goreng': 2 + 1 + 1 + 3 + 1, // A, D, I, J (4−1), L
        'Ayam Bakar': 1 + 2, // B, F (1 dipindah ke G tetap terjual)
        'Es Teh': 1 + 2 + 1, // A, E→D, titipan→I
        'Kopi Susu': 3 + 1 + 1, // C kompliment, G, H
      },
    );
  }

  test('menu terjual lengkap dari buka sampai tutup kasir, tanpa dobel',
      () async {
    final run = await runFullShift();
    final closing = await cashier.getClosingReport(run.shiftId);

    expect(closing.frozen, isTrue);
    expect(soldQuantities(closing.report), run.expected);
    expect(closing.report['menu_quantity'],
        run.expected.values.reduce((a, b) => a + b));
    // 10 transaksi selesai (A,B,C,D,F,G,H,I,J,L): kompliment ikut, order
    // gabungan E tidak berdiri sendiri, transaksi K yang di-void tidak.
    expect(closing.report['sales_count'], 10);
    // Cetakan == payload cloud (laporan yang sama persis).
    expect(jsonEncode(await cloudShiftReport(run.shiftId)),
        jsonEncode(closing.report));
  });

  test('cetak ulang tetap identik walau data berubah sesudah tutup kasir',
      () async {
    final run = await runFullShift();
    final original = (await cashier.getClosingReport(run.shiftId)).report;

    // Shift berikutnya mem-void transaksi dari shift yang sudah ditutup,
    // lalu retensi data menghapus detail pesanan lama.
    await cashier.openShift(openedBy: 'Kasir Besok', openingCash: 0);
    await orders.voidPaidOrder(
        orderId: run.paidOrderId, voidedBy: 'Manager', reason: 'Komplain');
    final recomputed = await cashier.getShiftReport(run.shiftId);
    expect(soldQuantities(recomputed), isNot(run.expected),
        reason: 'hitung ulang memang berubah — karena itu laporan dibekukan');
    await db.delete('order_items');

    final reprint = await cashier.getClosingReport(run.shiftId);
    expect(reprint.frozen, isTrue);
    expect(jsonEncode(reprint.report), jsonEncode(original));
    expect(soldQuantities(reprint.report), run.expected);
  });

  test('ganti shift juga membekukan laporan shift yang diserahkan', () async {
    final shift = await cashier.openShift(openedBy: 'Kasir Pagi', openingCash: 0);
    final o = await order('X', [line('Es Teh', 2)]);
    await payInFull(o);
    final next = await cashier.handoverShift(
        currentShiftId: shift.id,
        handoverToUserId: 'Kasir Sore',
        countedCash: 16000);

    final closing = await cashier.getClosingReport(shift.id);
    expect(closing.frozen, isTrue);
    expect(soldQuantities(closing.report), {'Es Teh': 2});
    expect(jsonEncode(await cloudShiftReport(shift.id)),
        jsonEncode(closing.report));
    // Shift baru masih terbuka → belum bisa dicetak sebagai tutup kasir.
    await expectLater(cashier.getClosingReport(next.id), throwsException);
  });

  test('shift lama tanpa snapshot dihitung ulang dan ditandai', () async {
    final id = Ulid.generate();
    final opened = DateTime.now().subtract(const Duration(hours: 3));
    await db.insert('cashier_shifts', {
      'id': id,
      'opened_by': 'Kasir Lama',
      'opened_at': opened.toIso8601String(),
      'closed_at': DateTime.now().toIso8601String(),
      'status': 'closed',
    });

    final closing = await cashier.getClosingReport(id);
    expect(closing.frozen, isFalse);
    expect(closing.report['shift_id'], id);

    final listed = await cashier.getRecentClosedShifts();
    expect(listed.single.shift.id, id);
    expect(listed.single.frozen, isFalse);
    expect(listed.single.salesTotal, isNull);
  });

  test('daftar cetak ulang: terbaru dulu, membawa ringkasan snapshot',
      () async {
    final run = await runFullShift();
    final later = await cashier.openShift(openedBy: 'Kasir 2', openingCash: 0);
    await cashier.closeShift(shiftId: later.id, closedBy: 'Kasir 2');

    final listed = await cashier.getRecentClosedShifts();
    expect(listed.map((s) => s.shift.id), [later.id, run.shiftId]);
    expect(listed.last.frozen, isTrue);
    expect(listed.last.salesCount, 10);
    expect(listed.first.salesCount, 0);
  });

  test('controller mencetak ulang laporan yang sama, bertanda CETAK ULANG',
      () async {
    final printer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(printer.close);
    final received = <List<int>>[];
    printer.listen((socket) {
      final bytes = <int>[];
      socket.listen(bytes.addAll, onDone: () => received.add(bytes));
    });
    SharedPreferences.setMockInitialValues({
      'saved_printers': [
        'Printer Kasir|127.0.0.1:${printer.port}|lan|cashier||48|1'
      ],
    });
    final run = await runFullShift();
    final controller = CashierController(authService: _NoSessionAuth());
    addTearDown(controller.dispose);

    expect(await controller.reprintShiftReport(run.shiftId), isNull);

    Future<Map<String, Object?>> job() async => (await db.query(
            'kitchen_print_jobs',
            where: 'label = ?',
            whereArgs: ['TUTUP KASIR (cetak ulang)']))
        .single;
    for (var n = 0;
        n < 100 && ((await job())['status'] != 'done' || received.isEmpty);
        n++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect((await job())['status'], 'done');
    final text = latin1.decode(received.expand((b) => b).toList());
    expect(text, contains('TUTUP KASIR'));
    expect(text, contains('*** CETAK ULANG ***'));
    expect(text, contains('Dicetak:'));
    expect(text, isNot(contains('Dihitung ulang')));
    expect(text, matches(RegExp(r'Nasi Goreng +8')));
    expect(text, matches(RegExp(r'Kopi Susu +5')));
    expect(text, matches(RegExp(r'TOTAL QTY MENU +20')));

    expect(await controller.reprintShiftReport('tidak-ada'),
        'Shift tidak ditemukan.');
  });

  test('cetak ulang tanpa printer memberi pesan yang jelas', () async {
    final run = await runFullShift();
    final controller = CashierController(authService: _NoSessionAuth());
    addTearDown(controller.dispose);
    expect(await controller.reprintShiftReport(run.shiftId),
        contains('Belum ada printer tersimpan'));
  });
}
