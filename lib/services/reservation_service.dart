import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../models/models.dart';
import '../repositories/cashier_repository.dart';
import '../repositories/order_repository.dart';
import 'outlet_service.dart';

/// Reservasi dari cloud → order meja di POS.
///
/// Berbeda dengan pesanan online (otomatis, bermeja, sudah lunas), reservasi
/// berjadwal, belum bermeja, dan biasanya baru dibayar sebagian. Karena itu
/// reservasi TIDAK dimaterialisasi otomatis tiap siklus sync: kasir melihat
/// daftarnya, memilih meja, lalu membukanya menjadi order.
///
/// Uang muka yang sudah divalidasi admin di cloud dicatat sebagai baris
/// pembayaran bermetode [ReservationService.dpMethod] — uangnya sudah masuk
/// rekening saat DP, bukan ke laci kasir. Transaksi pelunasan membawa
/// `reservation_id`, dan cloud menutup reservasinya begitu transaksi tersinkron.
class CloudReservationItem {
  final String productLocalId;
  final String productName;
  final int qty;
  final double price;

  const CloudReservationItem({
    required this.productLocalId,
    required this.productName,
    required this.qty,
    required this.price,
  });

  factory CloudReservationItem.fromJson(Map<String, dynamic> m) =>
      CloudReservationItem(
        productLocalId: (m['product_local_id'] as String? ?? '').trim(),
        productName: (m['product_name'] as String? ?? '').trim(),
        qty: (m['qty'] as num?)?.toInt() ?? 0,
        price: (m['price'] as num?)?.toDouble() ?? 0,
      );
}

class CloudReservation {
  final String id;
  final String customerName;
  final String customerPhone;
  final int pax;
  final String date; // YYYY-MM-DD
  final String time; // HH:MM
  final List<CloudReservationItem> items;
  final double total;
  final double paidAmount; // uang muka TERVALIDASI di cloud
  final double remaining;
  final String status; // pending | confirmed
  final String notes;

  const CloudReservation({
    required this.id,
    required this.customerName,
    required this.customerPhone,
    required this.pax,
    required this.date,
    required this.time,
    required this.items,
    required this.total,
    required this.paidAmount,
    required this.remaining,
    required this.status,
    required this.notes,
  });

  bool get isConfirmed => status == 'confirmed';

  factory CloudReservation.fromJson(Map<String, dynamic> m) {
    final rawItems = m['items'];
    return CloudReservation(
      id: m['id'] as String? ?? '',
      customerName: (m['customer_name'] as String? ?? '').trim(),
      customerPhone: (m['customer_phone'] as String? ?? '').trim(),
      pax: (m['pax'] as num?)?.toInt() ?? 1,
      date: m['reservation_date'] as String? ?? '',
      time: m['reservation_time'] as String? ?? '',
      items: rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((e) => CloudReservationItem.fromJson(e.cast<String, dynamic>()))
              .toList()
          : const [],
      total: (m['total'] as num?)?.toDouble() ?? 0,
      paidAmount: (m['paid_amount'] as num?)?.toDouble() ?? 0,
      remaining: (m['remaining'] as num?)?.toDouble() ?? 0,
      status: m['status'] as String? ?? 'pending',
      notes: (m['notes'] as String? ?? '').trim(),
    );
  }
}

/// Hasil membuka reservasi: order-nya, dan menu yang dilewati karena tidak
/// dikenal POS (agar kasir bisa menambahkannya manual).
typedef OpenedReservation = ({Order order, List<String> skipped});

class ReservationService {
  static final ReservationService instance = ReservationService._();
  ReservationService._();

  /// Metode pembayaran untuk uang muka reservasi. Sama dengan konstanta di
  /// cloud (`services.ReservationDpMethod`): laporan kas di cloud mengecualikan
  /// baris ini dari penerimaan hari kunjungan karena uangnya sudah masuk saat DP.
  static const dpMethod = 'reservasi_dp';

  final _outletService = OutletService();
  final _orderRepo = OrderRepository();
  final _cashierRepo = CashierRepository();
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 12),
  ));

  String _normalizeBaseUrl(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Reservasi hari ini (menurut zona waktu aplikasi di cloud) yang masih
  /// hidup: menunggu DP atau sudah dikonfirmasi. [date] = YYYY-MM-DD untuk
  /// hari lain.
  Future<List<CloudReservation>> fetchToday({String? date}) async {
    final outlet = await _outletService.loadOutlet();
    if (outlet.cloudApiUrl.isEmpty ||
        outlet.cloudOutletId.isEmpty ||
        outlet.cloudApiKey.isEmpty) {
      throw Exception('Cloud belum dikonfigurasi di Pengaturan');
    }
    final base = _normalizeBaseUrl(outlet.cloudApiUrl);
    final resp = await _dio.get(
      '$base/api/v1/outlets/${outlet.cloudOutletId}/reservations',
      queryParameters: {if (date != null && date.isNotEmpty) 'date': date},
      options: Options(headers: {
        'Authorization': 'Bearer ${outlet.cloudApiKey}',
        'X-Outlet-ID': outlet.cloudOutletId,
        'X-Outlet-Code': outlet.code,
      }),
    );
    final data = resp.data is Map ? resp.data['data'] : null;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((m) => CloudReservation.fromJson(m.cast<String, dynamic>()))
        .where((r) => r.id.isNotEmpty)
        .toList();
  }

  /// Buka reservasi menjadi order di [tableNumber].
  ///
  /// Idempoten: reservasi yang sudah punya order aktif mengembalikan order itu
  /// (dan melengkapi DP-nya bila sebelumnya gagal tercatat), bukan membuat
  /// order kedua. Menu dipetakan lewat product_local_id; yang tidak dikenal
  /// POS dilewati dan dilaporkan di [OpenedReservation.skipped].
  Future<OpenedReservation> openAsOrder({
    required CloudReservation reservation,
    required String tableNumber,
    required String cashierName,
  }) async {
    final existing = await _orderRepo.getOpenOrderByReservation(reservation.id);
    if (existing != null) {
      await _ensureDpRecorded(existing, reservation, cashierName);
      final fresh = await _orderRepo.getOrderById(existing.id) ?? existing;
      return (order: fresh, skipped: const <String>[]);
    }

    // Uang muka dicatat ke shift kasir (sama seperti pesanan online). Tanpa
    // shift, DP tidak bisa dicatat dan ordernya menjadi tagihan penuh — salah.
    if (reservation.paidAmount > 0 &&
        await _cashierRepo.getActiveShift() == null) {
      throw Exception(
          'Buka shift kasir dulu — uang muka reservasi dicatat ke shift');
    }

    final items = <OrderItemInput>[];
    final skipped = <String>[];
    for (final it in reservation.items) {
      if (it.qty < 1) continue;
      final pid = await _resolveProductId(it);
      if (pid == null) {
        skipped.add('${it.qty}× ${it.productName}');
        continue;
      }
      items.add(OrderItemInput(productId: pid, qty: it.qty));
    }
    if (items.isEmpty) {
      throw Exception(
          'Tidak ada menu reservasi yang dikenal POS (${skipped.join(', ')}). '
          'Periksa sinkronisasi produk, atau buat ordernya manual.');
    }

    final order = await _orderRepo.createOrder(
      tableNumber: tableNumber,
      items: items,
      pax: reservation.pax < 1 ? 1 : reservation.pax,
      customerName:
          reservation.customerName.isEmpty ? null : reservation.customerName,
      customerPhone:
          reservation.customerPhone.isEmpty ? null : reservation.customerPhone,
      createdBy: cashierName,
      waiterName: cashierName,
      reservationId: reservation.id,
    );
    if (skipped.isNotEmpty) {
      debugPrint(
          'Reservasi ${reservation.id}: menu tak dikenal POS dilewati: ${skipped.join(', ')}');
    }

    await _ensureDpRecorded(order, reservation, cashierName);
    final fresh = await _orderRepo.getOrderById(order.id) ?? order;
    return (order: fresh, skipped: skipped);
  }

  /// Catat uang muka tervalidasi sebagai pembayaran sebagian, sekali saja.
  Future<void> _ensureDpRecorded(
      Order order, CloudReservation reservation, String cashierName) async {
    if (reservation.paidAmount <= 0 || order.isPaid) return;
    final db = await AppDatabase.instance.database;
    final already = await db.query(
      'payments',
      columns: ['id'],
      where: 'order_id = ? AND payment_method = ?',
      whereArgs: [order.id, dpMethod],
      limit: 1,
    );
    if (already.isNotEmpty) return;
    // splitBillPayment meng-clamp ke sisa tagihan: bila menu di POS lebih
    // murah dari yang dicatat cloud, kelebihan DP tidak hilang di cloud
    // (kewajiban uang muka tetap tercatat di sana sampai direkonsiliasi).
    await _orderRepo.splitBillPayment(
      orderId: order.id,
      amount: reservation.paidAmount,
      paymentMethod: dpMethod,
      note: 'DP reservasi ${reservation.customerName}'.trim(),
      createdBy: cashierName,
    );
  }

  /// product_local_id → produk POS; bila kosong (reservasi lama), cocokkan
  /// nama persis sebagai cadangan. Null = tidak dikenal.
  Future<String?> _resolveProductId(CloudReservationItem it) async {
    final db = await AppDatabase.instance.database;
    if (it.productLocalId.isNotEmpty) {
      final r = await db.query('products',
          columns: ['id'],
          where: 'id = ? AND is_deleted = 0',
          whereArgs: [it.productLocalId],
          limit: 1);
      if (r.isNotEmpty) return r.first['id'] as String;
    }
    if (it.productName.isNotEmpty) {
      final r = await db.query('products',
          columns: ['id'],
          where: 'lower(name) = lower(?) AND is_deleted = 0',
          whereArgs: [it.productName],
          limit: 1);
      if (r.isNotEmpty) return r.first['id'] as String;
    }
    return null;
  }
}
