// Status tombol Sinkron kasir harus jujur: "offline"/merah HANYA bila cloud
// memang tak terjangkau. Kasus lapangan (Nov 2026):
//  - Gadis Desa: 5 item ditolak cloud (data tak cocok) membuat 100% siklus
//    tampil "Offline", backoff naik ke 30 menit, dan pull katalog tak pernah
//    jalan — padahal transaksi lain masuk cloud.
//  - Semesta/H&C: cloud menyimpan batch dalam <0,3 dtk tetapi balasannya
//    hilang di jalan → tablet bilang gagal padahal data sudah tersimpan.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/sync_queue_repository.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/services/sync_feedback.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Keputusan cloud tiruan untuk satu item batch: null = sukses, selain itu
/// teks alasan penolakan; [_omit] = item tidak dijawab sama sekali.
typedef _Decide = String? Function(String entityType, Map data);
const _omit = '__omit__';

void main() {
  // SENGAJA tanpa TestWidgetsFlutterBinding: binding tes membuat setiap
  // HttpClient membalas 400 tanpa benar-benar mengirim ke server tiruan.
  late Directory directory;
  late Database db;
  HttpServer? server;
  late int port;
  final sync = CloudSyncService.instance;
  final queue = SyncQueueRepository();

  // Perilaku cloud tiruan, diatur per tes.
  late _Decide decide;
  var dropRepliesRemaining = 0; // simpan batch lalu putus tanpa membalas
  final batches = <List<Map>>[]; // setiap batch yang DITERIMA cloud
  final paths = <String>[];

  Future<void> enqueue(String type, String id) => queue.enqueue(
        entityType: type,
        entityId: id,
        operation: 'create',
        payload: {'local_id': id, 'n': 1},
      );

  Future<Map<String, Object?>> job(String type, String id) async =>
      (await db.query('sync_queue',
              where: 'entity_type = ? AND entity_id = ?',
              whereArgs: [type, id],
              orderBy: 'id DESC'))
          .first;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-sync-status-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await AppDatabase.instance.database;
    // Biaya tambahan dikirim ulang tiap siklus; kosongkan agar batch hanya
    // berisi item tes ini.
    await db.delete('additional_charges');
    CloudSyncService.resendDelayForTest = Duration.zero;

    decide = (_, __) => null;
    dropRepliesRemaining = 0;
    batches.clear();
    paths.clear();

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server!.port;
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_env': 'development',
      'outlet_cloud_api_url': 'http://127.0.0.1:$port',
      'outlet_cloud_api_key': 'synthetic-key',
      'outlet_cloud_outlet_id': 'outlet-test',
      'outlet_code': 'UJI',
      'outlet_sync_enabled': true,
      'saved_printers': <String>[],
      // Lewati tarikan foto produk (bukan bagian tes ini).
      'cloud_last_pull_at:photos-v1:http://127.0.0.1:$port:outlet-test':
          '2099-01-01T00:00:00Z',
    });
    server!.listen((request) async {
      final path = request.uri.path;
      paths.add('${request.method} $path');
      Object? body;
      if (path.endsWith('/sync/batch')) {
        final raw = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final items = (raw['items'] as List).cast<Map>();
        batches.add(items);
        if (dropRepliesRemaining > 0) {
          dropRepliesRemaining--;
          // Batch sudah "tersimpan", tapi balasannya tak pernah sampai.
          final socket = await request.response.detachSocket();
          socket.destroy();
          return;
        }
        final results = <Map>[];
        for (final item in items) {
          final data = item['data'] as Map;
          final verdict = decide(item['entity_type'] as String, data);
          if (verdict == _omit) continue;
          results.add({
            'entity_type': item['entity_type'],
            'local_id': data['local_id'] ?? data['id'] ?? '',
            if (data['event_id'] != null) 'event_id': data['event_id'],
            'status': verdict == null ? 'success' : 'failed',
            if (verdict != null) 'error': verdict,
          });
        }
        body = {
          'success': true,
          'data': {'processed': items.length, 'results': results},
        };
      } else if (path.endsWith('/updates')) {
        body = {
          'success': true,
          'data': {
            'categories': [],
            'products': [],
            'deleted': [],
            'sync_checkpoint': '2026-11-18T00:00:00Z',
          },
        };
      } else if (path.endsWith('/online-orders')) {
        body = {'success': true, 'data': []};
      } else {
        body = {'success': true, 'data': null}; // info, heartbeat, dll.
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server?.close(force: true);
    server = null;
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('item ditolak cloud tidak membuat tablet offline & pull tetap jalan',
      () async {
    await enqueue('transaction', 'TRX-1');
    await enqueue('order', 'ORD-RUSAK');
    decide = (type, data) => data['local_id'] == 'ORD-RUSAK'
        ? 'waste pembatalan: produk "HWP3-A" harus cocok; ditemukan 0'
        : null;

    await sync.syncCycle();

    final s = await sync.status();
    expect(s.online, isTrue, reason: 'cloud terjangkau → bukan offline');
    expect(s.pending, 0);
    expect(s.rejected, 1);
    expect(paths, contains('GET /api/v1/outlets/outlet-test/updates'),
        reason: 'item ditolak tidak boleh menghentikan pull katalog');
    expect((await job('transaction', 'TRX-1'))['status'], 'success');
    final rejected = await job('order', 'ORD-RUSAK');
    expect(rejected['status'], 'failed');
    expect(rejected['error_kind'], SyncQueueRepository.errorKindRejected);
    expect(rejected['error_message'], contains('ditemukan 0'));

    final feedback = describeManualSync(s);
    expect(feedback.tone, SyncTone.warning);
    expect(feedback.message, contains('1 data ditolak cloud'));
    expect(feedback.message, isNot(contains('tidak terjangkau')));
  });

  test('item ditolak dikirim ulang tiap siklus & pulih begitu cloud menerima',
      () async {
    await enqueue('order', 'ORD-RUSAK');
    decide = (_, __) => 'produk tidak cocok';
    await sync.syncCycle();
    expect((await sync.status()).rejected, 1);

    decide = (_, __) => null; // data cloud sudah dibetulkan
    await sync.syncCycle();
    final s = await sync.status();
    expect(s.rejected, 0);
    expect(s.pending, 0);
    expect(s.online, isTrue);
    expect(batches.length, 2, reason: 'satu kirim per siklus, tidak dobel');
    expect((await job('order', 'ORD-RUSAK'))['status'], 'success');
    expect(describeManualSync(s).tone, SyncTone.success);
  });

  test('balasan hilang setelah cloud menyimpan → kirim ulang sekali, tersinkron',
      () async {
    await enqueue('transaction', 'TRX-HILANG');
    dropRepliesRemaining = 1;

    await sync.syncCycle();

    final s = await sync.status();
    expect(batches.length, 2, reason: 'batch dikirim ulang tepat satu kali');
    expect(batches.first.single['data']['local_id'], 'TRX-HILANG');
    expect(batches.last.single['data']['local_id'], 'TRX-HILANG');
    expect(s.online, isTrue);
    expect(s.pending, 0);
    expect((await job('transaction', 'TRX-HILANG'))['status'], 'success');
    expect(describeManualSync(s).message, 'Tersinkron ke cloud.');
  });

  test('cloud benar-benar tak terjangkau → offline, data tetap antre', () async {
    await enqueue('transaction', 'TRX-OFFLINE');
    await server!.close(force: true); // port ditutup → koneksi ditolak
    server = null;

    await sync.syncCycle();

    final s = await sync.status();
    expect(s.online, isFalse);
    expect(s.pending, 1);
    expect(s.rejected, 0);
    final row = await job('transaction', 'TRX-OFFLINE');
    expect(row['status'], 'pending');
    expect(row['error_kind'], SyncQueueRepository.errorKindNetwork);
    final feedback = describeManualSync(s);
    expect(feedback.tone, SyncTone.error);
    expect(feedback.message, contains('Cloud tidak terjangkau'));
    expect(feedback.message, contains('1 data aman di tablet'));
  });

  test('item tanpa konfirmasi tetap antre tanpa menandai offline', () async {
    await enqueue('transaction', 'TRX-OK');
    await enqueue('transaction', 'TRX-TANPA-JAWABAN');
    decide = (_, data) => data['local_id'] == 'TRX-TANPA-JAWABAN' ? _omit : null;

    await sync.syncCycle();

    final s = await sync.status();
    expect(s.online, isTrue);
    expect(s.pending, 1);
    expect(s.rejected, 0);
    expect(batches.length, 1,
        reason: 'item tak terkonfirmasi tidak dikirim berulang dalam siklus');
    final row = await job('transaction', 'TRX-TANPA-JAWABAN');
    expect(row['error_kind'], SyncQueueRepository.errorKindUnconfirmed);
    expect(describeManualSync(s).tone, SyncTone.warning);
  });

  test('backlog lebih dari satu batch terkuras dalam satu siklus', () async {
    for (var i = 0; i < 230; i++) {
      await enqueue('transaction', 'TRX-${i.toString().padLeft(3, '0')}');
    }

    await sync.syncCycle();

    final s = await sync.status();
    expect(batches.map((b) => b.length).toList(), [200, 30]);
    expect(s.pending, 0);
    expect(describeManualSync(s).tone, SyncTone.success);
  });
}
