// Real admin upload -> Go API -> CloudSyncService -> SQLite -> disk cache.
// Run only against the dedicated outlet in the disposable integration runner.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_resto/database/database.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/services/cloud_sync_service.dart';
import 'package:pos_resto/services/product_photo_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final env = Platform.environment;
  final url = env['E2E_CLOUD_URL'] ?? '';
  final outlet = env['E2E_PHOTO_OUTLET_ID'] ?? '';
  final key = env['E2E_PHOTO_API_KEY'] ?? '';
  final productId = env['E2E_PHOTO_PRODUCT_ID'] ?? '';
  final username = env['E2E_PHOTO_ADMIN_USER'] ?? '';
  final password = env['E2E_PHOTO_ADMIN_PASSWORD'] ?? '';
  if ([url, outlet, key, productId, username, password]
      .any((value) => value.isEmpty)) {
    test('e2e photo upload replacement deletion and offline cache', () {},
        skip: 'set E2E_CLOUD_URL and E2E_PHOTO_* with disposable fixtures');
    return;
  }
  late Directory directory, photoDirectory;
  late ProductPhotoCache cache;
  late Options admin;
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
  ));
  final sync = CloudSyncService.instance;
  final repo = ProductRepository();
  final endpoint = '$url/api/v1/admin/products/$productId/photo';

  Uint8List png(int red, int green) {
    final pixels = img.Image(width: 2, height: 2);
    img.fill(pixels, color: img.ColorRgb8(red, green, 30));
    return Uint8List.fromList(img.encodePng(pixels));
  }

  Future<String> upload(Uint8List bytes) async {
    final result = await dio.post(endpoint,
        options: admin,
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: 'menu.png'),
        }));
    expect(result.data['success'], true);
    final relative = result.data['data']['photo_url'] as String;
    expect(relative, startsWith('/uploads/products/$productId-'));
    return Uri.parse(url).resolve(relative).toString();
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('pos-photo-real-api-');
    await databaseFactory.setDatabasesPath(directory.path);
    photoDirectory = Directory('${directory.path}/photos');
    cache = ProductPhotoCache(directoryProvider: () async => photoDirectory);
    ProductPhotoCache.replaceForTesting(cache);
    SharedPreferences.setMockInitialValues({
      'outlet_cloud_env': 'development',
      // Also exercise URL normalization for configurations containing /api/v1.
      'outlet_cloud_api_url': '$url/api/v1',
      'outlet_cloud_api_key': key,
      'outlet_cloud_outlet_id': outlet,
      'outlet_code': 'E2EPHOTO',
    });
    final login = await dio.post('$url/api/v1/admin/login', data: {
      'username': username,
      'password': password,
    });
    expect(login.data['success'], true);
    admin = Options(headers: {
      'Authorization': 'Bearer ${login.data['data']['token']}',
    });
  });

  tearDownAll(() async {
    dio.close(force: true);
    ProductPhotoCache.replaceForTesting(ProductPhotoCache());
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  test('real photo lifecycle reaches Flutter and survives offline restart',
      () async {
    final firstBytes = png(220, 40);
    final firstUrl = await upload(firstBytes);
    final pulled = await sync.fullPullFromCloud();
    expect(pulled['incomplete'], isNull, reason: '$pulled');
    expect(pulled['products'], 1);
    var product = (await repo.getProducts()).single;
    expect(product.id, productId);
    expect(product.photoUrl, firstUrl);
    final firstFile = await cache.fileFor(product.photoUrl);
    expect(firstFile, isNotNull);
    expect(await firstFile!.readAsBytes(), firstBytes);

    // POS edits must not take ownership of the Cloud-managed photo.
    await repo.updateProduct(product);
    final pushed = await sync.pushNow();
    expect(pushed['failed'], 0, reason: '$pushed');
    await sync.pullUpdates();
    expect((await repo.getProducts()).single.photoUrl, firstUrl);

    final secondBytes = png(20, 200);
    final secondUrl = await upload(secondBytes);
    expect(secondUrl, isNot(firstUrl));
    await sync.pullUpdates();
    product = (await repo.getProducts()).single;
    expect(product.photoUrl, secondUrl);
    final secondFile = await cache.fileFor(product.photoUrl);
    expect(secondFile, isNotNull);
    expect(await secondFile!.readAsBytes(), secondBytes);
    expect(secondFile.path, isNot(firstFile.path));
    final removed =
        await dio.get(firstUrl, options: Options(validateStatus: (_) => true));
    expect(removed.statusCode, 404);

    // New cache instance models application restart. No HTTP client can be
    // created in this scope: the bytes must come from persistent disk storage.
    await HttpOverrides.runZoned(() async {
      final offlineCache =
          ProductPhotoCache(directoryProvider: () async => photoDirectory);
      final offlineFile = await offlineCache.fileFor(secondUrl);
      expect(offlineFile, isNotNull);
      expect(await offlineFile!.readAsBytes(), secondBytes);
    }, createHttpClient: (_) => throw const SocketException('offline fixture'));

    final deleted = await dio.delete(endpoint, options: admin);
    expect(deleted.data['success'], true);
    await sync.pullUpdates();
    expect((await repo.getProducts()).single.photoUrl, isEmpty);
    final deletedImage =
        await dio.get(secondUrl, options: Options(validateStatus: (_) => true));
    expect(deletedImage.statusCode, 404);
    expect((await sync.fullPullFromCloud())['incomplete'], isNull);
    expect((await repo.getProducts()).single.photoUrl, isEmpty);
    expect(await cache.fileFor(''), isNull);

    final invalid = await dio.post(endpoint,
        options: Options(headers: admin.headers, validateStatus: (_) => true),
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes('not an image'.codeUnits,
              filename: 'pretend.png'),
        }));
    expect(invalid.statusCode, 400);
    await sync.pullUpdates();
    expect((await repo.getProducts()).single.photoUrl, isEmpty);
  });
}
