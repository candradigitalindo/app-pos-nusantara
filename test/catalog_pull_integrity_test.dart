import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/services/product_photo_cache.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/services/app_events.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  HttpServer? server;
  late Database db;
  late ProductPhotoCache photoCache;
  Future<void> Function(HttpRequest)? photoRespond;
  var photoRequests = 0;
  late SharedPreferences prefs;
  late String cursorKey;
  late String categoryId, oldId, firstId, secondId;
  late Future<Object> Function(HttpRequest) respond;
  const before = '2026-09-01T00:00:00Z';
  const checkpoint = '2026-10-31T01:00:00Z';
  const epoch = '1970-01-01T00:00:00.000Z';
  final sync = CloudSyncService.instance;

  Map<String, Object> product(String id, {int price = 10000}) => {
        'local_id': id,
        'name': 'Menu $id',
        'price': price,
        'category_id': categoryId,
        'category_name': 'Minuman'
      };
  Map<String, Object> categories() => {
        'success': true,
        'data': [
          {'local_id': categoryId, 'name': 'Minuman'}
        ]
      };
  Map<String, Object> updates(List<Map> products) => {
        'success': true,
        'data': {
          'categories': [],
          'products': products,
          'deleted': [],
          'sync_checkpoint': checkpoint
        }
      };
  Future<void> expectUnchanged() async {
    expect(await db.query('products', columns: ['id', 'is_deleted']), [
      {'id': oldId, 'is_deleted': 0}
    ]);
    expect((await db.query('categories')).single['name'], 'Minuman');
    expect(prefs.getString(cursorKey), before);
  }

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-catalog-pull-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await AppDatabase.instance.database;
    await db.delete('products');
    await db.delete('categories');
    categoryId = Ulid.generate();
    oldId = Ulid.generate();
    firstId = Ulid.generate();
    secondId = Ulid.generate();
    await db.insert('categories', {'id': categoryId, 'name': 'Minuman'});
    await db.insert('products', {
      'id': oldId,
      'name': 'Menu lama',
      'stock': 0,
      'price': 5000,
      'category_id': categoryId
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://127.0.0.1:${server!.port}';
    cursorKey = 'cloud_last_pull_at:photos-v1:$url:outlet-test';
    photoCache = ProductPhotoCache(
        directoryProvider: () async => Directory('${directory.path}/photos'),
        retryDelay: Duration.zero,
        requestTimeout: const Duration(milliseconds: 500));
    ProductPhotoCache.replaceForTesting(photoCache);
    photoRequests = 0;
    photoRespond = null;
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_env': 'development',
      'outlet_cloud_api_url': url,
      'outlet_cloud_api_key': 'synthetic-key',
      'outlet_cloud_outlet_id': 'outlet-test',
      cursorKey: before,
      'cloud_last_pull_at': '2099-01-01T00:00:00Z',
    });
    prefs = await SharedPreferences.getInstance();
    respond = (_) async => throw StateError('Unexpected request');
    server!.listen((request) async {
      try {
        if (request.uri.path.startsWith('/uploads/')) {
          photoRequests++;
          expect(request.headers.value('authorization'), isNull);
          if (photoRespond != null) {
            await photoRespond!(request);
          } else {
            request.response.statusCode = 404;
          }
          await request.response.close();
          return;
        }
        final body = await respond(request);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
      } catch (e) {
        request.response.statusCode = 500;
        request.response.write('$e');
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await server?.close(force: true);
    server = null;
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('malformed categories cannot erase a local catalog', () async {
    respond = (_) async => {'success': true, 'data': null};
    expect((await sync.fullPullFromCloud())['incomplete'], 1);
    await expectUnchanged();
  });

  for (final mode in ['repeat', 'truncated', 'overlap', 'network']) {
    test('$mode product pages leave catalog and cursor unchanged', () async {
      respond = (r) async {
        if (r.uri.path.endsWith('/categories')) return categories();
        final page = r.uri.queryParameters['page'];
        if (page == '1') {
          return {
            'success': true,
            'data': [product(firstId)],
            'total': 3
          };
        }
        if (mode == 'network') throw const SocketException('offline');
        return {
          'success': true,
          'data': mode == 'truncated'
              ? []
              : [product(firstId), if (mode == 'overlap') product(secondId)],
          'total': 3
        };
      };
      expect((await sync.fullPullFromCloud())['incomplete'], 1);
      await expectUnchanged();
    });
  }

  test('server page caps and empty local IDs preserve selected identities',
      () async {
    final canonicalId = Ulid.generate();
    await db.insert('products',
        {'id': canonicalId, 'name': 'Alias lama', 'price': 1, 'stock': 0});
    respond = (r) async {
      if (r.uri.path.endsWith('/categories')) return categories();
      final row = r.uri.queryParameters['page'] == '1'
          ? {...product(firstId), 'id': canonicalId}
          : {...product(secondId), 'local_id': '', 'cloud_id': secondId};
      return {
        'success': true,
        'data': [row],
        'total': 2
      };
    };
    final result = await sync.fullPullFromCloud();
    expect(result['products'], 2);
    expect(result['deleted_products'], 2);
    final active = await db.query('products', where: 'is_deleted=0');
    expect(active.map((r) => r['id']).toSet(), {firstId, secondId});
    expect(prefs.getString(cursorKey), epoch);
  });

  test('no-total repeated pages are incomplete too', () async {
    respond = (r) async => r.uri.path.endsWith('/categories')
        ? categories()
        : {
            'data': [product(firstId)]
          };
    expect((await sync.fullPullFromCloud())['incomplete'], 1);
    await expectUnchanged();
  });

  test('malformed incremental collection cannot advance server cursor',
      () async {
    respond = (_) async => {
          'success': true,
          'data': {
            'categories': [],
            'products': [product(firstId)],
            'deleted': null,
            'sync_checkpoint': checkpoint,
          }
        };
    await sync.pullUpdates();
    await expectUnchanged();
  });

  test('SQL failure rolls back all incremental changes and cursor', () async {
    respond = (_) async => updates([product(firstId), product('too-short')]);
    await expectLater(sync.pullUpdates(), throwsException);
    await expectUnchanged();
  });

  test('full pull replays edits during paging using the server cursor',
      () async {
    String? since;
    respond = (r) async {
      if (r.uri.path.endsWith('/categories')) return categories();
      if (r.uri.path.endsWith('/updates')) {
        since = r.uri.queryParameters['since'];
        return updates([product(firstId, price: 12000)]);
      }
      return {
        'data': [product(firstId)],
        'total': 1
      };
    };
    await sync.fullPullFromCloud();
    await sync.pullUpdates();
    expect(since, epoch);
    expect(prefs.getString(cursorKey), checkpoint);
    expect(
        (await db.query('products', where: 'id=?', whereArgs: [firstId]))
            .single['price'],
        12000);
  });

  test('another outlet never inherits old or device-clock checkpoints',
      () async {
    await prefs.setString('outlet_cloud_outlet_id', 'another-outlet');
    String? since;
    respond = (r) async {
      since = r.uri.queryParameters['since'];
      return updates([]);
    };
    await sync.pullUpdates();
    expect(since, epoch);
    expect(prefs.getString(cursorKey), before);
  });

  test('full and incremental pulls cannot overwrite each other out of order',
      () async {
    final pageStarted = Completer<void>();
    final releasePage = Completer<void>();
    var incrementalStarted = false;
    respond = (r) async {
      if (r.uri.path.endsWith('/categories')) return categories();
      if (r.uri.path.endsWith('/updates')) {
        incrementalStarted = true;
        return updates([product(firstId, price: 13000)]);
      }
      pageStarted.complete();
      await releasePage.future;
      return {
        'data': [product(firstId)],
        'total': 1
      };
    };
    final full = sync.fullPullFromCloud();
    await pageStarted.future;
    final incremental = sync.pullUpdates();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(incrementalStarted, isFalse);
    releasePage.complete();
    await full;
    await incremental;
    expect(
        (await db.query('products', where: 'id=?', whereArgs: [firstId]))
            .single['price'],
        13000);
    expect(prefs.getString(cursorKey), checkpoint);
  });

  test(
      'photo-capable upgrade replays old products despite prior scoped future cursor',
      () async {
    final base = 'http://127.0.0.1:${server!.port}';
    await prefs.remove(cursorKey);
    await prefs.setString(
        'cloud_last_pull_at:$base:outlet-test', '2099-01-01T00:00:00Z');
    await prefs.setString('outlet_cloud_api_url', '$base/api/v1');
    final png =
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    photoRespond = (request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png);
    };
    respond = (request) async {
      expect(request.uri.queryParameters['since'], epoch);
      return updates([
        {...product(oldId), 'photo_url': '/uploads/old-photo.png'}
      ]);
    };
    await sync.pullUpdates();
    final productRow =
        (await db.query('products', where: 'id=?', whereArgs: [oldId])).single;
    expect(productRow['photo_url'], '$base/uploads/old-photo.png');
    expect(
        await photoCache.fileFor(productRow['photo_url'] as String), isNotNull);
    expect(prefs.getString(cursorKey), checkpoint);
    expect(photoRequests, 1);
  });

  test(
      'absent photo preserves both pulls, explicit empty clears, deletion clears display',
      () async {
    final base = 'http://127.0.0.1:${server!.port}';
    final url = '$base/uploads/original.png';
    final png =
        Uint8List.fromList(img.encodePng(img.Image(width: 1, height: 1)));
    await photoCache.storeBytes(url, png);
    await db.update('products', {'photo_url': url},
        where: 'id=?', whereArgs: [oldId]);
    respond = (_) async => updates([product(oldId)]);
    await sync.pullUpdates();
    expect((await db.query('products')).single['photo_url'], url);
    respond = (request) async => request.uri.path.endsWith('/categories')
        ? categories()
        : {
            'success': true,
            'data': [product(oldId)],
            'total': 1
          };
    expect((await sync.fullPullFromCloud())['products'], 1);
    expect((await db.query('products')).single['photo_url'], url);
    respond = (_) async => updates([
          {...product(oldId), 'photo_url': ''}
        ]);
    await sync.pullUpdates();
    expect((await db.query('products')).single['photo_url'], '');
    await db.update('products', {'photo_url': url},
        where: 'id=?', whereArgs: [oldId]);
    respond = (_) async {
      final body = updates([]);
      (body['data'] as Map)['deleted'] = [
        {'local_id': oldId, 'entity_type': 'product'}
      ];
      return body;
    };
    await sync.pullUpdates();
    final deleted = (await db.query('products')).single;
    expect(deleted['photo_url'], '');
    expect(Product.fromMap(deleted).photoUrl, '');
  });

  test('broken photo leaves menu committed and retries on a later empty update',
      () async {
    final base = 'http://127.0.0.1:${server!.port}';
    final url = '$base/uploads/retry.png';
    respond = (_) async => updates([
          {...product(oldId, price: 17000), 'photo_url': url}
        ]);
    await sync.pullUpdates();
    expect((await db.query('products')).single['price'], 17000);
    expect(await photoCache.fileFor(url), isNull);
    final png =
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    final notified = photoCache.onStored.firstWhere((stored) => stored == url);
    photoRespond = (request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png);
    };
    respond = (_) async => updates([]);
    await sync.pullUpdates();
    expect(await notified.timeout(const Duration(seconds: 5)), url);
    expect(await photoCache.cachedFile(url), isNotNull);
    expect(prefs.getString(cursorKey), checkpoint);
  });

  test('invalid catalog never starts image prefetch or changes existing photo',
      () async {
    const oldUrl = 'https://example.invalid/old.png';
    await db.update('products', {'photo_url': oldUrl},
        where: 'id=?', whereArgs: [oldId]);
    respond = (_) async => updates([
          {
            ...product(oldId),
            'price': -1,
            'photo_url': 'http://127.0.0.1:${server!.port}/uploads/never.png',
          }
        ]);
    await sync.pullUpdates();
    expect(photoRequests, 0);
    expect((await db.query('products')).single['photo_url'], oldUrl);
    expect(prefs.getString(cursorKey), before);
  });

  test(
      'catalog event follows committed updates and is absent on failure or empty replay',
      () async {
    final events = <String>[];
    final committedPrices = <num>[];
    final sub = AppEvents.instance.stream.listen((event) async {
      events.add(event);
      if (event == 'catalog_updated') {
        committedPrices.add(
            (await db.query('products', where: 'id=?', whereArgs: [oldId]))
                .single['price'] as num);
      }
    });
    try {
      respond = (_) async => updates([
            {...product(oldId), 'price': -1}
          ]);
      await sync.pullUpdates();
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      respond = (_) async => updates([product(oldId, price: 19000)]);
      await sync.pullUpdates();
      // The DB query in the stream callback is queued before this one.
      await db.query('products');
      expect(events, ['catalog_updated']);
      expect(committedPrices, [19000]);
      respond = (_) async => updates([]);
      await sync.pullUpdates();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['catalog_updated']);
    } finally {
      await sub.cancel();
    }
  });

  test(
      'saving an old product edit cannot restore a replaced or deleted Cloud photo',
      () async {
    final base = 'http://127.0.0.1:${server!.port}';
    final originalUrl = '$base/uploads/original.png';
    final replacementUrl = '$base/uploads/replacement.png';
    await db.update('products', {'photo_url': originalUrl},
        where: 'id=?', whereArgs: [oldId]);
    final oldProduct = Product.fromMap((await db.query('products')).single);
    final repository = ProductRepository();
    for (final currentUrl in [replacementUrl, '']) {
      respond = (_) async => updates([
            {...product(oldId), 'photo_url': currentUrl}
          ]);
      await sync.pullUpdates();
      await repository.updateProduct(oldProduct);
      expect((await db.query('products')).single['photo_url'], currentUrl);
      final queued = (await db.query('sync_queue',
              where: "entity_type = 'product' AND entity_id = ?",
              whereArgs: [oldId]))
          .single;
      final payload = jsonDecode(queued['payload'] as String) as Map;
      expect(payload.containsKey('photo_url'), isFalse);
    }
  });
}
