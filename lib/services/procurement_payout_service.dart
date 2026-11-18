import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../repositories/cashier_repository.dart';
import '../utils/ulid.dart';
import 'outlet_service.dart';

/// "Bayar Pengadaan" dari Kas Kasir Outlet.
///
/// Bagian Keuangan memilih sumber dana Kas Kasir Outlet di cloud → tugas
/// muncul di tablet ini. Data diambil LANGSUNG dari cloud (bukan dari sinkron
/// berkala) dan memprosesnya WAJIB online: tugas diklaim di cloud dulu, baru
/// kas keluar dicatat di shift, lalu dikonfirmasi. Tablet offline tidak bisa
/// memproses tugas ini sama sekali.

@immutable
class CashPayout {
  final String id;
  final String purchaseRequestId;
  final String requestNumber;
  final String requestType;
  final String itemsSummary;
  final String vendorName;
  final String outletName;
  final double amount;
  final String recipientName;
  final String notes;
  final String status; // pending | claimed | paid | returned | cancelled
  final String assignedBy;
  final DateTime? assignedAt;
  final String movementLocalId;
  final String cashierName;
  final String authorizedBy;
  final DateTime? claimedAt;
  final DateTime? paidAt;
  final String resolvedBy;
  final String resolutionReason;

  const CashPayout({
    required this.id,
    required this.purchaseRequestId,
    required this.requestNumber,
    this.requestType = '',
    this.itemsSummary = '',
    this.vendorName = '',
    this.outletName = '',
    required this.amount,
    required this.recipientName,
    this.notes = '',
    required this.status,
    this.assignedBy = '',
    this.assignedAt,
    this.movementLocalId = '',
    this.cashierName = '',
    this.authorizedBy = '',
    this.claimedAt,
    this.paidAt,
    this.resolvedBy = '',
    this.resolutionReason = '',
  });

  bool get isPending => status == 'pending';
  bool get isClaimed => status == 'claimed';
  bool get isPaid => status == 'paid';
  bool get isOpen => isPending || isClaimed;

  static DateTime? _time(Object? v) =>
      v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

  factory CashPayout.fromJson(Map json) => CashPayout(
        id: (json['id'] as String? ?? '').trim(),
        purchaseRequestId: (json['purchase_request_id'] as String? ?? '').trim(),
        requestNumber: json['request_number'] as String? ?? '',
        requestType: json['request_type'] as String? ?? '',
        itemsSummary: json['items_summary'] as String? ?? '',
        vendorName: json['vendor_name'] as String? ?? '',
        outletName: json['outlet_name'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        recipientName: json['recipient_name'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        status: json['status'] as String? ?? '',
        assignedBy: json['assigned_by'] as String? ?? '',
        assignedAt: _time(json['assigned_at']),
        movementLocalId: json['movement_local_id'] as String? ?? '',
        cashierName: json['cashier_name'] as String? ?? '',
        authorizedBy: json['authorized_by'] as String? ?? '',
        claimedAt: _time(json['claimed_at']),
        paidAt: _time(json['paid_at']),
        resolvedBy: json['resolved_by'] as String? ?? '',
        resolutionReason: json['resolution_reason'] as String? ?? '',
      );
}

class PayoutException implements Exception {
  final String message;
  final bool offline;
  const PayoutException(this.message, {this.offline = false});
  @override
  String toString() => message;
}

@immutable
class PayoutHandOverResult {
  final CashPayout payout;
  final CashMovement movement;
  final bool confirmedOnline;
  final String? warning;
  const PayoutHandOverResult({
    required this.payout,
    required this.movement,
    required this.confirmedOnline,
    this.warning,
  });
}

class ProcurementPayoutService {
  ProcurementPayoutService({
    Dio? dio,
    OutletService? outlets,
    CashierRepository? cashier,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            )),
        _outlets = outlets ?? OutletService(),
        _cashier = cashier ?? CashierRepository();

  static final ProcurementPayoutService instance = ProcurementPayoutService();

  static const offlineMessage =
      'Tablet tidak terhubung ke cloud. Bayar Pengadaan hanya bisa diproses saat online.';
  static const pollInterval = Duration(seconds: 30);

  final Dio _dio;
  final OutletService _outlets;
  final CashierRepository _cashier;

  /// Jumlah tugas terbuka (menunggu / diklaim) — lencana tombol di kasir.
  final ValueNotifier<int> openCount = ValueNotifier(0);
  Timer? _poll;
  int _watchers = 0;

  Future<({String base, Options options, String outletId})> _endpoint() async {
    final o = await _outlets.loadOutlet();
    if (o.cloudApiUrl.isEmpty || o.cloudApiKey.isEmpty || o.cloudOutletId.isEmpty) {
      throw const PayoutException(
          'Cloud belum dikonfigurasi di Pengaturan → Cloud.');
    }
    var base = o.cloudApiUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/api/v1')) base = base.substring(0, base.length - 7);
    return (
      base: '$base/api/v1/outlets/${o.cloudOutletId}/procurement-payouts',
      outletId: o.cloudOutletId,
      options: Options(headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${o.cloudApiKey}',
        'X-Outlet-ID': o.cloudOutletId,
        'X-Outlet-Code': o.code,
      }),
    );
  }

  static PayoutException _error(Object e) {
    if (e is PayoutException) return e;
    if (e is DioException) {
      final data = e.response?.data;
      if (e.response != null) {
        final msg = data is Map ? data['error']?.toString() : null;
        return PayoutException(
            (msg == null || msg.isEmpty) ? 'Cloud menolak permintaan (${e.response?.statusCode}).' : msg);
      }
      return const PayoutException(offlineMessage, offline: true);
    }
    return PayoutException(e.toString());
  }

  /// Daftar tugas outlet ini, diambil langsung dari cloud.
  Future<List<CashPayout>> fetch() async {
    try {
      final ep = await _endpoint();
      final resp = await _dio.get(ep.base, options: ep.options);
      final data = resp.data is Map ? resp.data['data'] : null;
      if (data is! List) throw const PayoutException('Respons cloud tidak valid.');
      final list = data.whereType<Map>().map(CashPayout.fromJson).toList();
      openCount.value = list.where((p) => p.isOpen).length;
      return list;
    } catch (e) {
      throw _error(e);
    }
  }

  Future<CashPayout> _post(String id, String action, Map<String, dynamic> body) async {
    try {
      final ep = await _endpoint();
      final resp = await _dio.post('${ep.base}/$id/$action', data: body, options: ep.options);
      final data = resp.data is Map ? resp.data['data'] : null;
      if (data is! Map) throw const PayoutException('Respons cloud tidak valid.');
      return CashPayout.fromJson(data);
    } catch (e) {
      throw _error(e);
    }
  }

  static String movementNote(CashPayout p) {
    final parts = <String>['Bayar pengadaan ${p.requestNumber}'];
    if (p.vendorName.isNotEmpty) parts.add(p.vendorName);
    if (p.itemsSummary.isNotEmpty) parts.add(p.itemsSummary);
    return parts.join(' · ');
  }

  /// Serahkan kas: klaim di cloud (online) → catat kas keluar di shift →
  /// konfirmasi. Klaim & pencatatan idempoten untuk [p] yang sama, jadi
  /// mengulang setelah gangguan tidak menggandakan uang keluar.
  Future<PayoutHandOverResult> handOver(
    CashPayout p, {
    required String cashierName,
    required String authorizedBy,
  }) async {
    final movementId = (p.isClaimed && p.movementLocalId.isNotEmpty)
        ? p.movementLocalId
        : Ulid.generate();
    final claimed = await _post(p.id, 'claim', {
      'movement_local_id': movementId,
      'cashier_name': cashierName,
      'authorized_by': authorizedBy,
    });
    CashMovement movement;
    try {
      movement = await _cashier.recordProcurementPayout(
        movementId: movementId,
        payoutId: claimed.id,
        amount: claimed.amount,
        recipient: claimed.recipientName,
        note: movementNote(claimed),
      );
    } catch (e) {
      // Uang belum keluar dari laci → kembalikan tugas ke "menunggu".
      try {
        await _post(p.id, 'release', {'movement_local_id': movementId});
      } catch (_) {}
      throw PayoutException(
          'Kas keluar gagal dicatat: ${e.toString().replaceFirst('Exception: ', '')}');
    }
    try {
      final done = await _post(p.id, 'complete', {'movement_local_id': movementId});
      unawaited(_refreshQuietly());
      return PayoutHandOverResult(payout: done, movement: movement, confirmedOnline: true);
    } on PayoutException catch (e) {
      // Kas keluar sudah tercatat & akan tersinkron; cloud menuntaskan tugas
      // saat kas keluar itu sampai. Jangan serahkan kas dua kali.
      return PayoutHandOverResult(
        payout: claimed,
        movement: movement,
        confirmedOnline: false,
        warning: 'Kas keluar tercatat di shift. Konfirmasi cloud menyusul saat '
            'sinkron (${e.message}).',
      );
    }
  }

  /// Tugas diklaim tetapi kas keluarnya sudah tercatat di tablet ini:
  /// cukup kirim konfirmasi ulang.
  Future<CashPayout> confirm(CashPayout p) async {
    final done = await _post(p.id, 'complete', {'movement_local_id': p.movementLocalId});
    unawaited(_refreshQuietly());
    return done;
  }

  /// Lepas klaim yang kas keluarnya TIDAK pernah tercatat (uang belum keluar).
  Future<CashPayout> release(CashPayout p) async {
    final local = await _cashier.getCashMovement(p.movementLocalId);
    if (local != null) {
      throw const PayoutException(
          'Kas keluar penyerahan ini sudah tercatat di tablet — selesaikan, jangan dibatalkan.');
    }
    final out = await _post(p.id, 'release', {'movement_local_id': p.movementLocalId});
    unawaited(_refreshQuietly());
    return out;
  }

  /// Kembalikan ke Keuangan (mis. harga berbeda, kas laci tidak cukup).
  Future<CashPayout> returnToFinance(CashPayout p,
      {required String reason, required String cashierName}) async {
    final out = await _post(p.id, 'return', {'reason': reason, 'cashier_name': cashierName});
    unawaited(_refreshQuietly());
    return out;
  }

  Future<void> _refreshQuietly() async {
    try {
      await fetch();
    } catch (_) {}
  }

  /// Pantau jumlah tugas selama layar kasir terbuka (bukan lewat sinkron).
  void startWatching() {
    _watchers++;
    if (_watchers > 1) return;
    unawaited(_refreshQuietly());
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_refreshQuietly()));
  }

  void stopWatching() {
    if (_watchers > 0) _watchers--;
    if (_watchers > 0) return;
    _poll?.cancel();
    _poll = null;
  }
}
