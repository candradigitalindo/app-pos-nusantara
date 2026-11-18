// Bayar Pengadaan dari Kas Kasir Outlet — sisi tablet.
// SENGAJA tanpa TestWidgetsFlutterBinding (binding tes membuat HttpClient
// membalas 400 tanpa menghubungi server tiruan).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/services/procurement_payout_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Cloud tiruan dengan aturan status yang sama dengan server: klaim terkunci
/// per id kas keluar, selesai idempoten, lepas hanya bila kas belum tercatat.
class _FakeCloud {
  final payouts = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  bool failComplete = false;

  Map<String, dynamic> add(String id, {double amount = 150000, String status = 'pending', String movement = ''}) {
    final p = {
      'id': id,
      'purchase_request_id': 'PR$id',
      'request_number': 'PR-2026-$id',
      'request_type': 'jasa',
      'items_summary': 'Servis mesin kopi',
      'vendor_name': 'CV Teknik',
      'outlet_name': 'Outlet Uji',
      'amount': amount,
      'recipient_name': 'Pak Teknisi',
      'notes': 'Bayar saat selesai',
      'status': status,
      'assigned_by': 'Keuangan',
      'assigned_at': '2026-11-18T10:00:00Z',
      'movement_local_id': movement,
      'cashier_name': '',
      'authorized_by': '',
    };
    payouts[id] = p;
    return p;
  }

  Object handle(String method, String path, Map body) {
    calls.add('$method $path');
    final parts = path.split('/procurement-payouts');
    final rest = parts.length > 1 ? parts[1] : '';
    if (method == 'GET' && rest.isEmpty) {
      return {'success': true, 'data': payouts.values.toList()};
    }
    final seg = rest.split('/').where((s) => s.isNotEmpty).toList();
    final p = payouts[seg[0]];
    if (p == null) return _err(400, 'tugas penyerahan kas tidak ditemukan');
    final movement = body['movement_local_id'] as String? ?? '';
    switch (seg[1]) {
      case 'claim':
        if (p['status'] == 'pending') {
          p['status'] = 'claimed';
          p['movement_local_id'] = movement;
          p['cashier_name'] = body['cashier_name'];
          p['authorized_by'] = body['authorized_by'];
        } else if (p['movement_local_id'] != movement) {
          return _err(409, 'tugas ini sudah diproses perangkat lain');
        }
        break;
      case 'complete':
        if (failComplete) return _err(500, 'gangguan sementara');
        if (p['movement_local_id'] != movement) return _err(409, 'kas keluar ini bukan milik tugas tersebut');
        p['status'] = 'paid';
        p['paid_at'] = '2026-11-18T11:00:00Z';
        break;
      case 'release':
        if (p['status'] == 'claimed' && p['movement_local_id'] == movement) {
          p['status'] = 'pending';
          p['movement_local_id'] = '';
        }
        break;
      case 'return':
        p['status'] = 'returned';
        p['resolution_reason'] = body['reason'];
        break;
    }
    return {'success': true, 'data': p};
  }

  static _Err _err(int code, String msg) => _Err(code, msg);
}

class _Err {
  final int code;
  final String msg;
  _Err(this.code, this.msg);
}

void main() {
  late Directory directory;
  late Database db;
  late HttpServer server;
  late _FakeCloud cloud;
  late ProcurementPayoutService service;
  final cashier = CashierRepository();

  Future<void> startServer() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final body = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw) as Map;
      final out = cloud.handle(request.method, request.uri.path, body);
      request.response.headers.contentType = ContentType.json;
      if (out is _Err) {
        request.response.statusCode = out.code;
        request.response.write(jsonEncode({'success': false, 'error': out.msg}));
      } else {
        request.response.write(jsonEncode(out));
      }
      await request.response.close();
    });
  }

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-payout-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await AppDatabase.instance.database;
    cloud = _FakeCloud();
    await startServer();
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_env': 'development',
      'outlet_cloud_api_url': 'http://127.0.0.1:${server.port}',
      'outlet_cloud_api_key': 'kunci-uji',
      'outlet_cloud_outlet_id': 'outlet-uji',
      'outlet_code': 'UJI',
      'saved_printers': <String>[],
    });
    service = ProcurementPayoutService();
  });

  tearDown(() async {
    await server.close(force: true);
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  Future<void> openShift() => cashier.openShift(openedBy: 'Kasir Uji', openingCash: 500000);

  Future<List<Map<String, Object?>>> payoutMovements() =>
      db.query('cashier_cash_movements', where: 'cash_payout_id IS NOT NULL');

  test('daftar diambil langsung dari cloud & jumlah tugas terbuka dihitung', () async {
    cloud.add('A');
    cloud.add('B', status: 'claimed', movement: 'MV-B-0001');
    cloud.add('C', status: 'paid');
    final list = await service.fetch();
    expect(list.map((p) => p.id), ['A', 'B', 'C']);
    expect(list.first.amount, 150000);
    expect(list.first.recipientName, 'Pak Teknisi');
    expect(service.openCount.value, 2);
    expect(cloud.calls.single, 'GET /api/v1/outlets/outlet-uji/procurement-payouts');
  });

  test('serahkan kas: klaim → kas keluar shift (bertaut tugas) → lunas', () async {
    await openShift();
    final p = CashPayout.fromJson(cloud.add('A'));

    final result = await service.handOver(p, cashierName: 'Kasir Uji', authorizedBy: 'Manajer');

    expect(result.confirmedOnline, isTrue);
    expect(result.payout.status, 'paid');
    expect(cloud.payouts['A']!['authorized_by'], 'Manajer');
    final rows = await payoutMovements();
    expect(rows.single['movement_type'], 'out');
    expect(rows.single['amount'], 150000);
    expect(rows.single['counterpart_name'], 'Pak Teknisi');
    expect(rows.single['cash_payout_id'], 'A');
    expect(rows.single['id'], cloud.payouts['A']!['movement_local_id']);
    expect(rows.single['note'], contains('PR-2026-A'));
    // Outbox membawa id tugas → cloud menautkan & tidak membukukan dua kali.
    final queued = await db.query('sync_queue',
        where: 'entity_type = ? AND entity_id = ?', whereArgs: ['cashier_cash_movement', rows.single['id']]);
    expect(jsonDecode(queued.single['payload'] as String)['cash_payout_id'], 'A');
    // Kas di laci ikut berkurang.
    expect(await cashier.expectedDrawerCashNow(), 350000);
  });

  test('tablet offline: tidak ada klaim, tidak ada kas keluar', () async {
    await openShift();
    final p = CashPayout.fromJson(cloud.add('A'));
    await server.close(force: true);

    await expectLater(
      service.handOver(p, cashierName: 'Kasir', authorizedBy: 'Manajer'),
      throwsA(isA<PayoutException>()
          .having((e) => e.offline, 'offline', isTrue)
          .having((e) => e.message, 'message', contains('hanya bisa diproses saat online'))),
    );
    expect(await payoutMovements(), isEmpty);
  });

  test('tugas sudah diproses perangkat lain: ditolak tanpa uang keluar', () async {
    await openShift();
    cloud.add('A', status: 'claimed', movement: 'MV-LAIN-0001');
    final stale = CashPayout.fromJson({...cloud.payouts['A']!, 'status': 'pending', 'movement_local_id': ''});

    await expectLater(service.handOver(stale, cashierName: 'Kasir', authorizedBy: 'Manajer'),
        throwsA(isA<PayoutException>().having((e) => e.message, 'message', contains('perangkat lain'))));
    expect(await payoutMovements(), isEmpty);
  });

  test('shift belum dibuka: klaim dilepas lagi, tugas kembali menunggu', () async {
    final p = CashPayout.fromJson(cloud.add('A'));

    await expectLater(service.handOver(p, cashierName: 'Kasir', authorizedBy: 'Manajer'),
        throwsA(isA<PayoutException>().having((e) => e.message, 'message', contains('Buka kasir'))));
    expect(cloud.payouts['A']!['status'], 'pending');
    expect(cloud.calls.where((c) => c.endsWith('/release')), hasLength(1));
    expect(await payoutMovements(), isEmpty);
  });

  test('konfirmasi cloud gagal setelah kas diserahkan: tercatat, tidak diulang', () async {
    await openShift();
    final p = CashPayout.fromJson(cloud.add('A'));
    cloud.failComplete = true;

    final result = await service.handOver(p, cashierName: 'Kasir', authorizedBy: 'Manajer');
    expect(result.confirmedOnline, isFalse);
    expect(result.warning, contains('menyusul saat sinkron'));
    expect(await payoutMovements(), hasLength(1));

    // Lanjutan (mis. dari dialog) memakai id kas keluar yang sama: tidak dobel.
    cloud.failComplete = false;
    final claimed = CashPayout.fromJson(cloud.payouts['A']!);
    expect(claimed.isClaimed, isTrue);
    final again = await service.handOver(claimed, cashierName: 'Kasir', authorizedBy: 'Manajer');
    expect(again.confirmedOnline, isTrue);
    expect(await payoutMovements(), hasLength(1));
    expect(await cashier.expectedDrawerCashNow(), 350000);
  });

  test('batalkan klaim ditolak bila kas keluar sudah tercatat', () async {
    await openShift();
    final p = CashPayout.fromJson(cloud.add('A'));
    cloud.failComplete = true;
    await service.handOver(p, cashierName: 'Kasir', authorizedBy: 'Manajer');

    final claimed = CashPayout.fromJson(cloud.payouts['A']!);
    await expectLater(service.release(claimed),
        throwsA(isA<PayoutException>().having((e) => e.message, 'message', contains('sudah tercatat'))));
    expect(cloud.payouts['A']!['status'], 'claimed');
  });

  test('kembalikan ke Keuangan membawa alasan kasir', () async {
    final p = CashPayout.fromJson(cloud.add('A'));
    final out = await service.returnToFinance(p, reason: 'Harga di toko berbeda', cashierName: 'Kasir');
    expect(out.status, 'returned');
    expect(cloud.payouts['A']!['resolution_reason'], 'Harga di toko berbeda');
  });
}
