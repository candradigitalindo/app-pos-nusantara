import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late Database db;
  HttpServer? server;
  late String productId, categoryId, cursorKey;
  late SharedPreferences prefs;
  late Future<Object> Function(HttpRequest) respond;
  final sync = CloudSyncService.instance;
  const before = '2026-10-30T01:00:00Z';
  const checkpoint = '2026-10-31T01:00:00Z';
  const epoch = '1970-01-01T00:00:00.000Z';

  Map<String, dynamic> product(String id) => {
        'local_id': id,
        'name': 'Menu $id',
        'price': 12000,
        'stock': 3,
        'category_id': categoryId,
        'category_name': 'Menu',
      };

  Map<String, dynamic> updates(List<Map<String, dynamic>> rows) => {
        'success': true,
        'data': {
          'categories': [],
          'products': rows,
          'deleted': [],
          'sync_checkpoint': checkpoint,
        },
      };

  Future<void> pull(String mode, List<Map<String, dynamic>> rows) async {
    respond = (request) async {
      if (mode == 'incremental') return updates(rows);
      if (request.uri.path.endsWith('/categories')) {
        return {
          'success': true,
          'data': [
            {'local_id': categoryId, 'name': 'Menu'}
          ],
        };
      }
      return {'success': true, 'data': rows, 'total': rows.length};
    };
    if (mode == 'incremental') {
      await sync.pullUpdates();
    } else {
      expect((await sync.fullPullFromCloud())['products'], rows.length);
    }
  }

  Future<Map<String, Object?>> storedProduct() async =>
      (await db.query('products', where: 'id = ?', whereArgs: [productId]))
          .single;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-menu-kind-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await AppDatabase.instance.database;
    await db.delete('products');
    await db.delete('categories');
    productId = Ulid.generate();
    categoryId = Ulid.generate();
    await db.insert('categories', {'id': categoryId, 'name': 'Menu'});
    await db.insert('products', {
      'id': productId,
      'name': 'Nama lama',
      'price': 10000,
      'stock': 1,
      'category_id': categoryId,
      'menu_kind': 'food',
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server!.port}';
    cursorKey = 'cloud_last_pull_at:menu-kinds-v1:$base:outlet-test';
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_env': 'development',
      'outlet_cloud_api_url': base,
      'outlet_cloud_api_key': 'synthetic-key',
      'outlet_cloud_outlet_id': 'outlet-test',
      cursorKey: before,
      'cloud_last_pull_at:photos-v1:$base:outlet-test': '2099-01-01T00:00:00Z',
    });
    prefs = await SharedPreferences.getInstance();
    respond = (_) async => throw StateError('Unexpected request');
    server!.listen((request) async {
      try {
        final response = await respond(request);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
      } catch (error) {
        request.response.statusCode = 500;
        request.response.write('$error');
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

  for (final mode in ['full', 'incremental']) {
    test('$mode pull stores every Cloud kind and defaults new legacy products',
        () async {
      final rows = <Map<String, dynamic>>[
        for (final kind in ['food', 'beverage', 'activity', 'other'])
          {...product(Ulid.generate()), 'menu_kind': kind},
        product(Ulid.generate()),
      ];
      await pull(mode, rows);
      for (var index = 0; index < rows.length; index++) {
        final stored = (await db.query('products',
                where: 'id = ?', whereArgs: [rows[index]['local_id']]))
            .single;
        expect(stored['menu_kind'], rows[index]['menu_kind'] ?? '');
        expect(
            Product.fromMap(stored).menuKind, rows[index]['menu_kind'] ?? '');
        expect(stored['price'], 12000);
        expect(stored['stock'], 3);
      }
    });

    test('$mode pull preserves missing kind and clears explicit null or empty',
        () async {
      await pull(mode, [product(productId)]);
      expect((await storedProduct())['menu_kind'], 'food');
      for (final cleared in <Object?>['', null]) {
        await db.update('products', {'menu_kind': 'activity'},
            where: 'id = ?', whereArgs: [productId]);
        await pull(mode, [
          {...product(productId), 'menu_kind': cleared},
        ]);
        expect((await storedProduct())['menu_kind'], '');
      }
    });

    test('$mode pull normalizes unknown and malformed kinds', () async {
      for (final invalid in <Object>[
        'dessert',
        'FOOD',
        ' food ',
        7,
        {'id': 1}
      ]) {
        await db.update('products', {'menu_kind': 'food'},
            where: 'id = ?', whereArgs: [productId]);
        await pull(mode, [
          {...product(productId), 'menu_kind': invalid},
        ]);
        expect((await storedProduct())['menu_kind'], '');
      }
    });
  }

  test('upgrade replays old catalog once instead of reusing photo-only cursor',
      () async {
    await prefs.remove(cursorKey);
    final seen = <String?>[];
    respond = (request) async {
      seen.add(request.uri.queryParameters['since']);
      return updates([
        {...product(productId), 'menu_kind': 'activity'},
      ]);
    };
    await sync.pullUpdates();
    await sync.pullUpdates();
    expect(seen, [epoch, checkpoint]);
    expect((await storedProduct())['menu_kind'], 'activity');
    expect(prefs.getString(cursorKey), checkpoint);
  });

  test('stale local edit cannot overwrite a changed or cleared Cloud kind',
      () async {
    final stale = Product.fromMap(await storedProduct());
    final repository = ProductRepository();
    for (final latest in ['beverage', '']) {
      await pull('incremental', [
        {...product(productId), 'menu_kind': latest},
      ]);
      await repository.updateProduct(stale);
      expect((await storedProduct())['menu_kind'], latest);
      final queued = (await db.query('sync_queue',
              where: "entity_type = 'product' AND entity_id = ?",
              whereArgs: [productId]))
          .single;
      final payload = jsonDecode(queued['payload'] as String) as Map;
      expect(payload.containsKey('menu_kind'), isFalse);
    }
  });

  test('photo copy and model serialization preserve kinds and legacy null',
      () async {
    final product = Product.fromMap(await storedProduct());
    final changed = product.withPhotoUrl('https://cloud.test/new.png');
    expect(changed.menuKind, 'food');
    expect(Product.fromMap(changed.toMap()).menuKind, 'food');
    expect(
        Product.fromMap({...product.toMap(), 'menu_kind': null}).menuKind, '');
    final now = DateTime(2026, 10, 31, 10);
    for (final kind in <String?>[
      null,
      '',
      'food',
      'beverage',
      'activity',
      'other'
    ]) {
      final item = OrderItem(
        id: Ulid.generate(),
        orderId: Ulid.generate(),
        productId: product.id,
        productName: product.name,
        menuKind: kind,
        qty: 2,
        price: product.price,
        createdAt: now,
        updatedAt: now,
      );
      expect(item.toMap()['menu_kind'], kind);
      expect(OrderItem.fromMap(item.toMap()).menuKind, kind);
      final legacy = item.toMap()..remove('menu_kind');
      expect(OrderItem.fromMap(legacy).menuKind, isNull);
    }
  });
}
