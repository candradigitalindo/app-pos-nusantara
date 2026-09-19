import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../repositories/cashier_repository.dart';
import '../repositories/order_repository.dart';
import '../repositories/product_repository.dart';
import '../utils/ulid.dart';
import 'outlet_service.dart';

/// Menarik pesanan mandiri tamu (QR dine-in) dari cloud menjadi order meja.
///
/// Ini SATU-SATUNYA data yang mengalir cloud → POS; sinkronisasi lain selalu
/// POS → cloud. Karena itu urutannya dijaga ketat:
///
///   klaim (atomik di server) → buat order lokal → konfirmasi
///
/// Klaim memastikan hanya satu perangkat yang memproses sebuah pesanan.
/// Konfirmasi baru dikirim SETELAH order lokal benar-benar tersimpan, sehingga
/// perangkat yang mati di tengah jalan tidak membuat pesanan hilang — klaimnya
/// kedaluwarsa di server dan pesanan bisa ditarik ulang.
class OnlineOrderService {
  static final OnlineOrderService instance = OnlineOrderService._();
  OnlineOrderService._();

  static const _deviceIdKey = 'online_order_device_id';

  final _outletService = OutletService();
  final _orderRepo = OrderRepository();
  final _productRepo = ProductRepository();
  final _cashierRepo = CashierRepository();
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
  ));

  bool _busy = false;

  /// Id perangkat yang stabil antar-restart — dipakai server untuk mengenali
  /// klaim milik perangkat ini sendiri (klaim ulang boleh, klaim milik orang
  /// lain tidak).
  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      id = Ulid.generate();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  String _normalizeBaseUrl(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Tarik dan proses semua pesanan yang menunggu.
  ///
  /// Aman dipanggil dari siklus sync berkala: dijaga agar tidak berjalan ganda,
  /// dan seluruh kegagalan ditelan (dicatat ke log) supaya tidak pernah
  /// menggagalkan siklus sinkronisasi utama.
  Future<int> pullPendingOrders() async {
    if (_busy) return 0;
    _busy = true;
    try {
      final outlet = await _outletService.loadOutlet();
      if (outlet.cloudApiUrl.isEmpty ||
          outlet.cloudOutletId.isEmpty ||
          outlet.cloudApiKey.isEmpty) {
        return 0;
      }

      // Pesanan online sudah dibayar tamu, jadi pembayarannya harus tercatat
      // di shift kasir. Tanpa shift terbuka, pembayaran akan tertolak dan
      // ordernya jadi tagihan yang salah — lebih baik tunda: pesanan tetap
      // menunggu di cloud dan ditarik saat kasir membuka shift.
      if (await _cashierRepo.getActiveShift() == null) return 0;

      final base = _normalizeBaseUrl(outlet.cloudApiUrl);
      final options = Options(headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${outlet.cloudApiKey}',
        'X-Outlet-ID': outlet.cloudOutletId,
        'X-Outlet-Code': outlet.code,
      });
      final root = '$base/api/v1/outlets/${outlet.cloudOutletId}/online-orders';

      final resp = await _dio.get(root, options: options);
      final data = resp.data is Map ? resp.data['data'] : null;
      if (data is! List || data.isEmpty) return 0;

      final deviceId = await _deviceId();
      var ingested = 0;

      for (final raw in data) {
        if (raw is! Map) continue;
        final order = raw.cast<String, dynamic>();
        final id = order['id'] as String?;
        if (id == null || id.isEmpty) continue;

        // Klaim dulu — kalah klaim (409) berarti perangkat lain sedang
        // memprosesnya, jadi lewati tanpa membuat apa pun.
        try {
          await _dio.post('$root/$id/claim',
              data: {'device_id': deviceId}, options: options);
        } on DioException catch (e) {
          if (e.response?.statusCode != 409) {
            debugPrint('OnlineOrder klaim $id gagal: ${e.message}');
          }
          continue;
        }

        try {
          final localOrderId = await _materialize(order);
          await _dio.post('$root/$id/confirm',
              data: {'local_order_id': localOrderId}, options: options);
          ingested++;
        } catch (e) {
          // Pesanan yang tak bisa diproses (menu sudah dihapus, meja tidak
          // ada) ditolak dengan alasan, supaya tidak ditarik berulang kali
          // sampai klaimnya kedaluwarsa.
          debugPrint('OnlineOrder $id gagal diproses: $e');
          try {
            await _dio.post('$root/$id/reject',
                data: {'reason': e.toString()}, options: options);
          } catch (_) {}
        }
      }
      return ingested;
    } catch (e) {
      debugPrint('OnlineOrderService.pullPendingOrders: $e');
      return 0;
    } finally {
      _busy = false;
    }
  }

  /// Ubah satu pesanan online menjadi order meja lokal.
  ///
  /// Bila meja sudah punya order aktif, itemnya DITAMBAHKAN ke order itu
  /// alih-alih membuat order kedua — tamu yang menambah pesanan dari HP-nya
  /// tetap berada di satu tagihan.
  Future<String> _materialize(Map<String, dynamic> order) async {
    final tableNumber = (order['table_number'] as String? ?? '').trim();
    if (tableNumber.isEmpty) throw Exception('Nomor meja kosong');

    final rawItems = order['items'];
    if (rawItems is! List || rawItems.isEmpty) {
      throw Exception('Pesanan tidak punya item');
    }

    final items = <OrderItemInput>[];
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final m = raw.cast<String, dynamic>();
      final productId = m['product_local_id'] as String? ?? '';
      final qty = (m['qty'] as num?)?.toInt() ?? 0;
      if (productId.isEmpty || qty < 1) continue;

      items.add(OrderItemInput(
        productId: productId,
        qty: qty,
        notes: (m['notes'] as String? ?? '').trim().isEmpty
            ? null
            : m['notes'] as String,
        addons: await _resolveAddons(productId, m['addons']),
      ));
    }
    if (items.isEmpty) throw Exception('Tidak ada item yang bisa diproses');

    final customerName = (order['customer_name'] as String? ?? '').trim();
    final orderer = customerName.isEmpty ? 'Pesan Online' : customerName;

    final existing = await _orderRepo.getOrderByTable(tableNumber);
    String localOrderId;
    if (existing != null && !existing.isPaid && !existing.isVoided) {
      await _orderRepo.addItemToOrder(
        orderId: existing.id,
        items: items,
        waiterName: orderer,
      );
      localOrderId = existing.id;
    } else {
      final created = await _orderRepo.createOrder(
        tableNumber: tableNumber,
        items: items,
        pax: 1,
        customerName: customerName.isEmpty ? null : customerName,
        customerPhone: (order['customer_phone'] as String? ?? '').trim().isEmpty
            ? null
            : order['customer_phone'] as String,
        createdBy: orderer,
        waiterName: orderer,
      );
      localOrderId = created.id;
    }

    await _recordOnlinePayment(localOrderId, order, orderer);
    return localOrderId;
  }

  /// Catat pembayaran QRIS yang SUDAH diterima penyedia ke order lokal.
  ///
  /// Nominal yang dicatat adalah yang benar-benar dibayar tamu, BUKAN total
  /// yang dihitung POS. Kalau konfigurasi biaya sempat berbeda antara cloud dan
  /// POS, selisihnya muncul sebagai sisa tagihan yang terlihat kasir — jauh
  /// lebih baik daripada menandai lunas atas uang yang tidak masuk, atau
  /// menagih ulang tamu yang sudah membayar penuh.
  ///
  /// Memakai splitBillPayment karena method itu sudah menangani pembayaran
  /// sebagian, meng-clamp ke sisa tagihan, dan menutup transaksi begitu lunas.
  Future<void> _recordOnlinePayment(
    String localOrderId,
    Map<String, dynamic> order,
    String orderer,
  ) async {
    final paid = (order['paid_amount'] as num?)?.toDouble() ?? 0;
    if (paid <= 0) return;

    try {
      final sebelum = await _orderRepo.getOrderById(localOrderId);
      await _orderRepo.splitBillPayment(
        orderId: localOrderId,
        amount: paid,
        paymentMethod: 'qris',
        note: 'Pesan online — dibayar QRIS',
        createdBy: orderer,
      );

      // splitBillPayment meng-clamp ke sisa tagihan. Untuk kasir yang menerima
      // tunai itu benar (kembaliannya diberikan langsung), tetapi uang QRIS
      // SUDAH masuk ke penyedia — kelebihannya nyata dan tidak boleh hilang
      // tanpa jejak. Selisih hanya mungkin muncul bila konfigurasi biaya di
      // cloud dan POS sempat berbeda, mis. tarif diubah tepat sebelum siklus
      // sync berikutnya.
      final sisaSebelum =
          (sebelum?.remaining ?? paid).clamp(0.0, double.infinity);
      if (paid > sisaSebelum + 0.01) {
        debugPrint(
          'SELISIH pesanan online $localOrderId: tamu membayar $paid, '
          'tagihan POS hanya $sisaSebelum — kelebihan '
          '${paid - sisaSebelum} TIDAK tercatat di laporan shift. '
          'Periksa apakah tarif biaya di POS dan cloud sudah sama.',
        );
      }
    } catch (e) {
      // Ordernya sudah terbentuk dan tiket dapur sudah tercetak; kegagalan
      // mencatat pembayaran TIDAK boleh membatalkan itu. Kasir akan melihat
      // tagihan ini belum lunas dan bisa menyelesaikannya manual.
      debugPrint('Gagal mencatat pembayaran online $localOrderId: $e');
    }
  }

  /// Cocokkan add-on kiriman cloud dengan master add-on MILIK POS.
  ///
  /// Harga selalu diambil dari master lokal, bukan dari kiriman: harga yang
  /// ditagih tamu harus mengikuti data kasir, bukan angka yang dikirim
  /// perangkat tamu. Add-on yang tidak lagi ada di master dilewati diam-diam
  /// agar satu add-on usang tidak menggagalkan seluruh pesanan.
  Future<List<SelectedAddon>> _resolveAddons(
      String productId, dynamic raw) async {
    if (raw is! List || raw.isEmpty) return const [];

    final master = await _productRepo.getAddons(productId);
    if (master.isEmpty) return const [];
    final byId = {for (final a in master) a.id: a};

    final out = <SelectedAddon>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final id = entry['id'] as String? ?? '';
      final found = byId[id];
      if (found != null) out.add(SelectedAddon.fromAddon(found));
    }
    return out;
  }
}
