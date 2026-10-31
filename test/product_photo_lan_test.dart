import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_resto/controllers/station_controller.dart';
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/services/local_api_server.dart';
import 'package:pos_resto/services/product_photo_cache.dart';
import 'package:pos_resto/services/station_api_client.dart';
import 'package:pos_resto/utils/ulid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late Database db;
  late ProductPhotoCache cache;
  late Dio client;
  late String base, productId, photoUrl, token;
  final bytes =
      Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('product-photo-lan-');
    await databaseFactory.setDatabasesPath('${directory.path}/db');
    SharedPreferences.setMockInitialValues({});
    cache = ProductPhotoCache(
        directoryProvider: () async => Directory('${directory.path}/cache'));
    ProductPhotoCache.replaceForTesting(cache);
    db = await AppDatabase.instance.database;
    productId = Ulid.generate();
    photoUrl = 'https://offline.invalid/uploads/$productId.png';
    await db.insert('products', {
      'id': productId,
      'name': 'Foto LAN',
      'price': 12000,
      'stock': 5,
      'photo_url': photoUrl,
      'is_deleted': 0,
    });
    await db.insert('users', {
      'id': Ulid.generate(),
      'username': 'photo-lan-test',
      'password_hash': sha256.convert(utf8.encode('4817')).toString(),
      'full_name': 'Waiter Uji',
      'role': 'waiter',
      'is_active': 1,
    });
    await LocalApiServer.instance.start(port: 0);
    base = 'http://127.0.0.1:${LocalApiServer.instance.port}';
    client = Dio(BaseOptions(baseUrl: base, validateStatus: (_) => true));
    final auth = await client.post('/api/auth', data: {'pin': '4817'});
    expect(auth.statusCode, 200);
    token = auth.data['data']['token'] as String;
  });

  tearDown(() async {
    StationApiClient.instance.clearToken();
    await StationApiClient.instance.clear();
    client.close(force: true);
    await LocalApiServer.instance.stop();
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('main cached photo remains available on authenticated LAN without cloud',
      () async {
    expect(await cache.storeBytes(photoUrl, bytes), isNotNull);
    final rows = await client.get('/api/products',
        options: Options(headers: {'X-Station-Token': token}));
    final product = (rows.data['data'] as List).single as Map;
    expect(product['photo_url'], photoUrl);
    final path = product['photo_cache_path'] as String;
    expect((await client.get(path)).statusCode, 401);
    final downloaded = await client.get<List<int>>(path,
        options: Options(
            headers: {'X-Station-Token': token},
            responseType: ResponseType.bytes));
    expect(downloaded.statusCode, 200);
    expect(downloaded.headers.value('content-type'), 'image/png');
    expect(downloaded.data, bytes);
    expect(
        (await client.get('/api/products/..%2F..%2Fsecrets/photo?v=x',
                options: Options(headers: {'X-Station-Token': token})))
            .statusCode,
        404);

    await db.update('products', {'photo_url': '$photoUrl?v=new'},
        where: 'id = ?', whereArgs: [productId]);
    expect(
        (await client.get(path,
                options: Options(headers: {'X-Station-Token': token})))
            .statusCode,
        404);
    await db.update('products', {'photo_url': photoUrl, 'is_deleted': 1},
        where: 'id = ?', whereArgs: [productId]);
    expect(
        (await client.get(path,
                options: Options(headers: {'X-Station-Token': token})))
            .statusCode,
        404);
  });

  test('uncached products keep cloud URL and station menu remains usable',
      () async {
    final rows = await client.get('/api/products',
        options: Options(headers: {'X-Station-Token': token}));
    expect((rows.data['data'] as List).single['photo_cache_path'], isNull);
    StationApiClient.instance.setBaseUrl(base);
    expect(await StationApiClient.instance.authPin('4817'), isNotNull);
    final products = await StationApiClient.instance.getProducts();
    expect(products.single.photoUrl, photoUrl);
    expect(await cache.cachedFile(photoUrl), isNull);
  });

  test('station refresh changes photos without repricing or clearing cart',
      () async {
    StationApiClient.instance.setBaseUrl(base);
    expect(await StationApiClient.instance.authPin('4817'), isNotNull);
    final controller = StationController();
    addTearDown(controller.dispose);
    await controller.loadProducts();
    controller.addToCart(controller.products.single);
    final order = <String, dynamic>{'id': 'open-order', 'total': 12000};
    controller.currentOrder = order;

    await db.update(
        'products', {'photo_url': '$photoUrl?replacement', 'price': 99000},
        where: 'id = ?', whereArgs: [productId]);
    await controller.refreshProductPhotos();
    expect(controller.products.single.photoUrl, '$photoUrl?replacement');
    expect(
        controller.productCache[productId]!.photoUrl, '$photoUrl?replacement');
    expect(controller.products.single.price, 12000);
    expect(controller.cart, {productId: 1});
    expect(controller.cartTotal, 12000);
    expect(controller.currentOrder, same(order));

    await db.update('products', {'is_deleted': 1},
        where: 'id = ?', whereArgs: [productId]);
    await controller.refreshProductPhotos();
    expect(controller.products.single.photoUrl, '');
    expect(controller.productCache[productId]!.photoUrl, '');
    expect(controller.cartTotal, 12000);
    expect(controller.cart, {productId: 1});
    expect(controller.currentOrder, same(order));
  });

  test('station caches LAN bytes under cloud URL using its session header',
      () async {
    final fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var photoRequests = 0;
    final photoStarted = Completer<void>();
    final releasePhoto = Completer<void>();
    final stored = cache.onStored.firstWhere((url) => url == photoUrl);
    final version = sha256.convert(utf8.encode(photoUrl)).toString();
    fake.listen((request) async {
      if (request.uri.path == '/api/auth') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': {'token': 'isolated-station-token'}
        }));
      } else if (request.uri.path == '/api/products') {
        final row =
            Map<String, dynamic>.from((await db.query('products')).single);
        row['photo_cache_path'] = '/api/products/$productId/photo?v=$version';
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': [row]
        }));
      } else if (request.uri.path == '/api/products/$productId/photo' &&
          request.headers.value('X-Station-Token') ==
              'isolated-station-token') {
        photoRequests++;
        if (!photoStarted.isCompleted) photoStarted.complete();
        await releasePhoto.future;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(bytes);
      } else {
        request.response.statusCode = 401;
      }
      await request.response.close();
    });
    try {
      StationApiClient.instance.setBaseUrl('http://127.0.0.1:${fake.port}');
      await StationApiClient.instance.authPin('4817');
      final products = await StationApiClient.instance
          .getProducts()
          .timeout(const Duration(seconds: 1));
      expect(products.single.photoUrl, photoUrl);
      await photoStarted.future.timeout(const Duration(seconds: 2));
      expect(await cache.cachedFile(photoUrl), isNull);
      // Repeated menu loads return promptly and do not launch a second fetch
      // while the same image is still pending on the main register.
      await StationApiClient.instance
          .getProducts()
          .timeout(const Duration(seconds: 1));
      expect(photoRequests, 1);
      releasePhoto.complete();
      await stored.timeout(const Duration(seconds: 2));
      expect(await (await cache.cachedFile(photoUrl))!.readAsBytes(), bytes);
      await StationApiClient.instance.getProducts();
      expect(photoRequests, 1);
    } finally {
      if (!releasePhoto.isCompleted) releasePhoto.complete();
      await fake.close(force: true);
    }
  });
}
