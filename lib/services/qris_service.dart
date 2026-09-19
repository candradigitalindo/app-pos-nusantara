import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'outlet_service.dart';

/// Tagihan QRIS yang sedang berjalan.
class QrisCharge {
  final String chargeId;
  final String provider;
  final String qrString;
  final double amount;
  final String status; // pending, paid, expired, failed
  final DateTime? expiresAt;

  const QrisCharge({
    required this.chargeId,
    required this.provider,
    required this.qrString,
    required this.amount,
    required this.status,
    this.expiresAt,
  });

  bool get isPaid => status == 'paid';
  bool get isPending => status == 'pending';

  /// Penyedia tiruan: alur lengkap jalan tanpa akun asli, tetapi kasir harus
  /// diberi tahu bahwa tidak ada uang sungguhan yang berpindah.
  bool get isMock => provider == 'mock';

  factory QrisCharge.fromJson(Map<String, dynamic> m) => QrisCharge(
        chargeId: m['charge_id'] as String? ?? '',
        provider: m['provider'] as String? ?? '',
        qrString: m['qr_string'] as String? ?? '',
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        status: m['status'] as String? ?? 'pending',
        expiresAt: DateTime.tryParse(m['expires_at'] as String? ?? '')?.toLocal(),
      );
}

/// Klien QRIS terintegrasi.
///
/// POS TIDAK pernah mencatat pembayaran dari sini — layanan ini hanya
/// memastikan uang benar-benar sudah masuk. Setelah status `paid`, pemanggil
/// tetap menjalankan `processPayment` seperti pembayaran tunai, sehingga
/// pembayaran QRIS selalu punya pasangan di laporan shift kasir.
class QrisService {
  static final QrisService instance = QrisService._();
  QrisService._();

  final _outletService = OutletService();
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

  Future<({String base, String outletId, Options options})?> _endpoint() async {
    final outlet = await _outletService.loadOutlet();
    if (outlet.cloudApiUrl.isEmpty ||
        outlet.cloudOutletId.isEmpty ||
        outlet.cloudApiKey.isEmpty) {
      return null;
    }
    return (
      base: _normalizeBaseUrl(outlet.cloudApiUrl),
      outletId: outlet.cloudOutletId,
      options: Options(headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${outlet.cloudApiKey}',
        'X-Outlet-ID': outlet.cloudOutletId,
        'X-Outlet-Code': outlet.code,
      }),
    );
  }

  /// Apakah QRIS terintegrasi tersedia untuk outlet ini. Mengembalikan null
  /// bila cloud belum dikonfigurasi atau tidak bisa dihubungi — pemanggil
  /// harus jatuh ke pembayaran QRIS manual, jangan memblokir kasir.
  Future<Map<String, dynamic>?> info() async {
    final ep = await _endpoint();
    if (ep == null) return null;
    try {
      final resp = await _dio.get(
        '${ep.base}/api/v1/outlets/${ep.outletId}/qris/info',
        options: ep.options,
      );
      final data = resp.data is Map ? resp.data['data'] : null;
      return data is Map ? data.cast<String, dynamic>() : null;
    } catch (e) {
      debugPrint('QrisService.info: $e');
      return null;
    }
  }

  /// Terbitkan tagihan. Melempar bila gagal — kasir perlu tahu QR-nya tidak
  /// terbit alih-alih menunggu layar kosong.
  Future<QrisCharge> createCharge({
    required String orderId,
    required double amount,
    String description = '',
  }) async {
    final ep = await _endpoint();
    if (ep == null) {
      throw Exception('Cloud belum dikonfigurasi — QRIS terintegrasi tidak tersedia');
    }
    final resp = await _dio.post(
      '${ep.base}/api/v1/outlets/${ep.outletId}/qris/charges',
      data: {
        'order_local_id': orderId,
        'amount': amount,
        'description': description,
      },
      options: ep.options,
    );
    final data = resp.data is Map ? resp.data['data'] : null;
    if (data is! Map) throw Exception('Jawaban server tidak dikenali');
    return QrisCharge.fromJson(data.cast<String, dynamic>());
  }

  Future<QrisCharge> fetchCharge(String chargeId) async {
    final ep = await _endpoint();
    if (ep == null) throw Exception('Cloud belum dikonfigurasi');
    final resp = await _dio.get(
      '${ep.base}/api/v1/outlets/${ep.outletId}/qris/charges/$chargeId',
      options: ep.options,
    );
    final data = resp.data is Map ? resp.data['data'] : null;
    if (data is! Map) throw Exception('Jawaban server tidak dikenali');
    return QrisCharge.fromJson(data.cast<String, dynamic>());
  }

  /// Pantau tagihan sampai lunas/kedaluwarsa/dibatalkan.
  ///
  /// Kegagalan jaringan sesaat TIDAK menghentikan pemantauan — polling berikut
  /// dicoba lagi, karena tamu mungkin sudah membayar saat koneksi sempat putus.
  /// Pemanggil menghentikan lewat [cancel].
  Stream<QrisCharge> watch(
    String chargeId, {
    Duration interval = const Duration(seconds: 3),
    Duration timeout = const Duration(minutes: 15),
  }) async* {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final charge = await fetchCharge(chargeId);
        yield charge;
        if (!charge.isPending) return;
      } catch (e) {
        debugPrint('QrisService.watch: $e');
      }
      await Future<void>.delayed(interval);
    }
  }

  /// Tandai lunas TANPA penyedia asli. Server hanya menerimanya saat penyedia
  /// aktif adalah mock, jadi ini tidak bisa dipakai melunasi tagihan sungguhan.
  Future<QrisCharge> simulatePaid(String chargeId) async {
    final ep = await _endpoint();
    if (ep == null) throw Exception('Cloud belum dikonfigurasi');
    final resp = await _dio.post(
      '${ep.base}/api/v1/outlets/${ep.outletId}/qris/charges/$chargeId/simulate-paid',
      options: ep.options,
    );
    final data = resp.data is Map ? resp.data['data'] : null;
    if (data is! Map) throw Exception('Jawaban server tidak dikenali');
    return QrisCharge.fromJson(data.cast<String, dynamic>());
  }
}
