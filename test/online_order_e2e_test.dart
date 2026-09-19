// End-to-end pesanan online: POS Flutter menarik dari server cloud SUNGGUHAN.
//
// Sengaja TIDAK memakai HTTP palsu. Yang paling rawan di jalur ini adalah
// kecocokan kontrak antar-repo — nama field seperti `paid_amount`,
// `product_local_id`, dan `addons[].id` dibaca POS dari JSON yang dibentuk Go.
// Menjawabnya dengan JSON yang saya tulis sendiri hanya akan menguji ulang
// asumsi saya, bukan kontraknya.
//
// Dilewati kecuali E2E_CLOUD_URL diset, jadi `flutter test` tetap hijau tanpa
// server. Jalankan lewat: tool/run_e2e.sh
//
// Yang dibuktikan di sini:
//   * pesanan yang sudah dibayar tamu menjadi order meja dengan item & harga
//     yang benar, dan tagihannya langsung LUNAS tanpa kasir menagih ulang;
//   * harga add-on dihitung ulang dari master POS, bukan dari kiriman cloud;
//   * tanpa shift terbuka POS tidak menarik apa pun;
//   * pesanan yang sudah dikonfirmasi tidak ditarik dua kali.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/services/online_order_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _env = Platform.environment;
final _cloudUrl = _env['E2E_CLOUD_URL'] ?? '';
final _slug = _env['E2E_SLUG'] ?? '';
final _outletId = _env['E2E_OUTLET_ID'] ?? '';
final _apiKey = _env['E2E_API_KEY'] ?? '';
final _productId = _env['E2E_PRODUCT_ID'] ?? '';
final _addonId = _env['E2E_ADDON_ID'] ?? '';

const _hargaMenu = 25000.0;
const _hargaAddon = 5000.0;

late Database db;
late File dbFile;
final _orderRepo = OrderRepository();
final _cashierRepo = CashierRepository();

void main() {
  if (_cloudUrl.isEmpty) {
    test('e2e pesanan online', () {}, skip: 'setel E2E_CLOUD_URL — lihat tool/run_e2e.sh');
    return;
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // Prefs harus dipasang SEBELUM layanan apa pun membacanya.
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_api_url': _cloudUrl,
      'outlet_cloud_api_key': _apiKey,
      'outlet_cloud_outlet_id': _outletId,
      'outlet_code': 'UJI',
      'outlet_name': 'Outlet Uji',
      // Tanpa printer tersimpan, antrian cetak dapur berhenti lebih awal —
      // menjauhkan tes dari plugin perangkat keras.
      'saved_printers': <String>[],
    });

    dbFile = File(p.join(await getDatabasesPath(), 'pos_resto.db'));
    if (await dbFile.exists()) await dbFile.delete();
    db = await AppDatabase.instance.database;

    // Master lokal HARUS memakai id yang sama dengan cloud — itulah yang
    // menjadi jembatan product_local_id pada payload pesanan.
    final now = DateTime.now().toIso8601String();
    await db.insert('products', {
      'id': _productId,
      'name': 'Nasi Goreng',
      'price': _hargaMenu,
      'stock': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
    });
    // Biaya tambahan HARUS ada di POS juga. Di produksi POS-lah sumber
    // kebenarannya dan cloud hanya mencerminkannya lewat sync; kalau di sini
    // hanya cloud yang punya, totalnya beda dan itu bukan cerminan produksi.
    await db.insert('additional_charges', {
      'sync_id': '01E2ETESTCHARGE00000000001',
      'name': 'Pajak Restoran (PB1)',
      'charge_type': 'percentage',
      'value': 10.0,
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });

    if (_addonId.isNotEmpty) {
      await db.insert('product_addons', {
        'id': _addonId,
        'product_id': _productId,
        'name': 'Extra keju',
        'price': _hargaAddon,
        'created_at': now,
        'updated_at': now,
      });
    }
  });

  tearDownAll(() async {
    await db.close();
    if (await dbFile.exists()) await dbFile.delete();
  });

  test('tanpa shift terbuka, POS tidak menarik apa pun', () async {
    await _buatPesananLunas(tableNumber: 'T-NOSHIFT');

    // Pembayaran butuh shift untuk dicatat; menariknya sekarang akan
    // menghasilkan order meja tanpa pembayaran — tagihan yang salah.
    expect(await _cashierRepo.getActiveShift(), isNull);
    expect(await OnlineOrderService.instance.pullPendingOrders(), 0);
    expect(await _orderRepo.getOrderByTable('T-NOSHIFT'), isNull);
  });

  test('pesanan lunas menjadi order meja yang sudah lunas', () async {
    await _cashierRepo.openShift(openedBy: 'Kasir Uji', openingCash: 100000);

    final pesanan = await _buatPesananLunas(tableNumber: 'A5', qty: 2);
    final ditarik = await OnlineOrderService.instance.pullPendingOrders();
    expect(ditarik, greaterThanOrEqualTo(1));

    final order = await _orderTerakhirDiMeja('A5');
    expect(order, isNotNull, reason: 'order meja tidak terbentuk');

    final items = await _orderRepo.getOrderItems(order!.id);
    expect(items.length, 1);
    expect(items.first.qty, 2);
    expect(items.first.price, _hargaMenu, reason: 'harga menu dari master POS');

    // Total = subtotal + PB1 10% = 50.000 + 5.000 = 55.000, dan itulah yang
    // ditagihkan cloud lewat QRIS.
    expect(order.totalAmount, closeTo(pesanan.total, 0.01),
        reason: 'total POS harus sama dengan yang dibayar tamu');

    // Inti fiturnya: tamu sudah membayar, jadi kasir TIDAK boleh menagih lagi.
    expect(order.paidAmount, closeTo(pesanan.total, 0.01));
    expect(order.isPaid, isTrue, reason: 'order harus lunas, bukan menyisakan tagihan');

    // Cloud harus tahu pesanannya sudah diproses.
    expect(await _statusCloud(pesanan.id), 'confirmed');
  });

  test('pesanan yang sudah dikonfirmasi tidak ditarik dua kali', () async {
    // Siklus sync berjalan berulang; menarik ulang berarti tamu mendapat
    // pesanan kedua yang tidak pernah ia pesan.
    final sebelum = await _jumlahOrderDiMeja('A5');
    expect(await OnlineOrderService.instance.pullPendingOrders(), 0);
    expect(await _jumlahOrderDiMeja('A5'), sebelum);
  });

  test('harga add-on diambil dari master POS, bukan kiriman cloud', () async {
    if (_addonId.isEmpty) {
      markTestSkipped('E2E_ADDON_ID tidak diset');
      return;
    }

    final pesanan = await _buatPesananLunas(
      tableNumber: 'B7',
      qty: 1,
      addonId: _addonId,
    );
    expect(await OnlineOrderService.instance.pullPendingOrders(),
        greaterThanOrEqualTo(1));

    final order = await _orderTerakhirDiMeja('B7');
    expect(order, isNotNull);
    final items = await _orderRepo.getOrderItems(order!.id);

    // Harga add-on DILIPAT ke harga satuan item.
    expect(items.first.price, _hargaMenu + _hargaAddon);
    expect(items.first.addonLabel, 'Extra keju');
    expect(order.paidAmount, closeTo(pesanan.total, 0.01));
  });

  // ── Selisih konfigurasi biaya antara cloud dan POS ────────────────────
  //
  // Cloud menagih memakai daftar biaya yang TERAKHIR dikirim POS. Bila tarif
  // diubah tepat sebelum siklus sync berikutnya, ada jendela sempit di mana
  // keduanya berbeda. Dua tes berikut memotret apa yang SEBENARNYA terjadi di
  // jendela itu — bukan apa yang seharusnya — supaya perilakunya diketahui,
  // bukan ditemukan saat menutup kasir.

  test('tamu kurang bayar (POS menagih lebih) menyisakan tagihan', () async {
    final pesanan = await _buatPesananLunas(tableNumber: 'D1', qty: 2);

    // POS menaikkan pajak SETELAH tamu membayar.
    await _setTarifPajakPos(20);
    addTearDown(() => _setTarifPajakPos(10));

    expect(await OnlineOrderService.instance.pullPendingOrders(),
        greaterThanOrEqualTo(1));

    final order = (await _orderTerakhirDiMeja('D1'))!;
    expect(order.totalAmount, closeTo(60000, 0.01)); // 50.000 + 20%
    expect(order.paidAmount, closeTo(pesanan.total, 0.01)); // yang benar dibayar
    expect(order.isPaid, isFalse);
    expect(order.remaining, closeTo(5000, 0.01),
        reason: 'sisanya harus terlihat kasir, bukan ditutup diam-diam');
  });

  test('tamu lebih bayar (POS menagih kurang) — kelebihan TIDAK tercatat',
      () async {
    final pesanan = await _buatPesananLunas(tableNumber: 'D2', qty: 2);

    // POS menurunkan pajak setelah tamu membayar 55.000.
    await _setTarifPajakPos(0);
    addTearDown(() => _setTarifPajakPos(10));

    expect(await OnlineOrderService.instance.pullPendingOrders(),
        greaterThanOrEqualTo(1));

    final order = (await _orderTerakhirDiMeja('D2'))!;
    expect(order.totalAmount, closeTo(50000, 0.01));
    expect(order.isPaid, isTrue);

    // INI KETERBATASAN YANG DIKETAHUI, bukan perilaku yang diinginkan:
    // splitBillPayment meng-clamp ke sisa tagihan, jadi 5.000 yang sudah
    // masuk ke penyedia tidak muncul di laporan shift. OnlineOrderService
    // mencatatnya ke log agar bisa ditelusuri. Bila suatu saat ditangani
    // sungguhan, tes ini yang harus diubah lebih dulu.
    expect(order.paidAmount, closeTo(50000, 0.01),
        reason: 'kelebihan bayar ter-clamp — lihat log SELISIH');
    expect(order.paidAmount, lessThan(pesanan.total));
  });

  test('tagihan meja yang berjalan menerima pesanan online sebagai tambahan',
      () async {
    // Tamu sudah punya tagihan berjalan yang dibuat pramusaji, lalu menambah
    // pesanan sendiri dari HP. Harus menjadi SATU tagihan dengan pembayaran
    // online dikreditkan — bukan order kedua di meja yang sama, dan bukan
    // pula tagihan yang ditandai lunas atas uang yang belum semuanya masuk.
    final berjalan = await _orderRepo.createOrder(
      tableNumber: 'C9',
      items: [OrderItemInput(productId: _productId, qty: 4)], // 100.000
      createdBy: 'Pramusaji',
    );
    final totalSebelum = (await _orderRepo.getOrderById(berjalan.id))!.totalAmount;

    final pesanan = await _buatPesananLunas(tableNumber: 'C9', qty: 2);
    expect(await OnlineOrderService.instance.pullPendingOrders(),
        greaterThanOrEqualTo(1));

    expect(await _jumlahOrderDiMeja('C9'), 1,
        reason: 'order kedua terbentuk di meja yang sama');

    final sesudah = (await _orderRepo.getOrderById(berjalan.id))!;
    expect(sesudah.totalAmount, greaterThan(totalSebelum));
    // Yang dibayar online dikreditkan; sisanya tetap ditagih kasir.
    expect(sesudah.paidAmount, closeTo(pesanan.total, 0.01));
    expect(sesudah.isPaid, isFalse, reason: 'sisa tagihan harus tetap terlihat');
    expect(sesudah.remaining, greaterThan(0));
  });
}

/// Order terakhir di sebuah meja, APA PUN statusnya.
///
/// `getOrderByTable` sengaja hanya mengembalikan order yang belum lunas —
/// meja yang tagihannya selesai dianggap bebas. Pesanan online masuk dalam
/// keadaan sudah lunas, jadi pemeriksaan hasilnya tidak bisa lewat sana.
Future<Order?> _orderTerakhirDiMeja(String table) async {
  final rows = await db.query('orders',
      where: 'table_number = ?',
      whereArgs: [table],
      orderBy: 'created_at DESC',
      limit: 1);
  return rows.isEmpty ? null : Order.fromMap(rows.first);
}

/// Mengubah tarif pajak di POS saja — mensimulasikan jendela di mana
/// konfigurasi POS dan cloud belum sinkron.
Future<void> _setTarifPajakPos(double persen) async {
  await db.update('additional_charges', {'value': persen},
      where: 'name = ?', whereArgs: ['Pajak Restoran (PB1)']);
}

Future<int> _jumlahOrderDiMeja(String table) async {
  final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM orders WHERE table_number = ?', [table]);
  return (rows.first['n'] as int?) ?? 0;
}

// ── Penggerak sisi cloud ──────────────────────────────────────────────────

/// Dio, bukan paket http, supaya tes tidak menambah dependensi baru.
final _dio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 10),
  receiveTimeout: const Duration(seconds: 10),
));

class _Pesanan {
  final String id;
  final double total;
  const _Pesanan(this.id, this.total);
}

/// Membuat pesanan lewat endpoint publik lalu melunasinya (penyedia mock),
/// persis seperti yang dilakukan halaman tamu.
Future<_Pesanan> _buatPesananLunas({
  required String tableNumber,
  int qty = 1,
  String addonId = '',
}) async {
  final body = {
    'table_number': tableNumber,
    'customer_name': 'Tamu Uji',
    'items': [
      {
        'product_local_id': _productId,
        'qty': qty,
        if (addonId.isNotEmpty) 'addons': [{'id': addonId}],
      }
    ],
  };

  final buat = await _dio.post(
    '$_cloudUrl/api/v1/public/outlets/$_slug/orders',
    data: body,
  );
  final data = (buat.data as Map)['data'] as Map;
  final id = data['id'] as String;
  final total = (data['total_amount'] as num).toDouble();

  await _dio.post(
      '$_cloudUrl/api/v1/public/outlets/$_slug/orders/$id/simulate-paid');

  return _Pesanan(id, total);
}

Future<String> _statusCloud(String orderId) async {
  final r = await _dio
      .get('$_cloudUrl/api/v1/public/outlets/$_slug/orders/$orderId');
  return ((r.data as Map)['data'] as Map)['status'] as String;
}
