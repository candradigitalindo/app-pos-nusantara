import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_resto/services/product_photo_cache.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late ProductPhotoCache cache;
  late Future<void> Function(HttpRequest) respond;
  late String base;
  late Uint8List png;
  var requests = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pos-photo-cache-');
    png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
    cache = ProductPhotoCache(
        directoryProvider: () async => directory,
        retryDelay: Duration.zero,
        requestTimeout: const Duration(seconds: 1));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    requests = 0;
    respond = (request) async {
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png);
    };
    server.listen((request) async {
      requests++;
      try {
        await respond(request);
        await request.response.close();
      } catch (_) {
        // Tests deliberately disconnect interrupted/oversized transfers.
      }
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
      'same URL downloads once without credentials and survives cache restart offline',
      () async {
    final url = '$base/uploads/photo.png';
    final files =
        await Future.wait(List.generate(8, (_) => cache.fileFor(url)));
    expect(requests, 1);
    expect(files.every((file) => file != null), isTrue);
    expect(files.map((file) => file!.path).toSet().length, 1);
    expect(await files.first!.readAsBytes(), png);
    await server.close(force: true);
    final restarted = ProductPhotoCache(
        directoryProvider: () async => directory,
        requestTimeout: const Duration(milliseconds: 50));
    expect((await restarted.fileFor(url))!.path, files.first!.path);
    expect(await restarted.fileFor('$base/uploads/replacement.png'), isNull,
        reason: 'a changed URL must never fall back to the old photo');
  });

  test('HTML, SVG and truncated images never become cached photos', () async {
    for (final payload in [
      ('text/html', Uint8List.fromList('<html>login</html>'.codeUnits)),
      (
        'image/svg+xml',
        Uint8List.fromList('<svg onload="alert(1)"/>'.codeUnits)
      ),
      ('image/png', Uint8List.fromList([137, 80, 78, 71])),
    ]) {
      respond = (request) async {
        request.response.headers.set('content-type', payload.$1);
        request.response.add(payload.$2);
      };
      expect(await cache.fileFor('$base/uploads/${payload.$1.hashCode}.png'),
          isNull);
    }
    expect(await directory.list().toList(), isEmpty);
  });

  test('failed transfer is retryable and successful store emits its exact URL',
      () async {
    final url = '$base/uploads/retry.png';
    respond = (request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png.sublist(0, png.length ~/ 2));
    };
    expect(await cache.fileFor(url), isNull);
    expect(await cache.cachedFile(url), isNull);
    respond = (request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png);
    };
    final notified = cache.onStored.first;
    final stored = await cache.fileFor(url);
    expect(stored, isNotNull);
    expect(await notified, url);
    expect(requests, 2);
    expect(
        (await directory.list().toList())
            .every((file) => file.path.endsWith('.img')),
        isTrue);
  });

  test('file size limit applies to LAN bytes and streamed response', () async {
    expect(
        await cache.storeBytes('$base/uploads/too-big.png',
            Uint8List(ProductPhotoCache.maxImageBytes + 1)),
        isNull);
    respond = (request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      // Chunked response cannot evade the actual-byte limit.
      final chunk = Uint8List(1024 * 1024);
      for (var i = 0; i < 11; i++) {
        request.response.add(chunk);
        await request.response.flush();
      }
    };
    expect(await cache.fileFor('$base/uploads/stream-too-big.png'), isNull);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
      'bounded persistent cache evicts oldest files and retains latest valid photo',
      () async {
    cache = ProductPhotoCache(
        directoryProvider: () async => directory,
        maxEntries: 2,
        maxCacheBytes: png.length * 2);
    final first = await cache.storeBytes('$base/a', png);
    await first!.setLastModified(DateTime(2000));
    final second = await cache.storeBytes('$base/b', png);
    await second!.setLastModified(DateTime(2001));
    final third = await cache.storeBytes('$base/c', png);
    expect(third, isNotNull);
    expect(await cache.cachedFile('$base/a'), isNull);
    expect(await cache.cachedFile('$base/b'), isNotNull);
    expect(await cache.cachedFile('$base/c'), isNotNull);
    final files = await directory
        .list()
        .where((file) => file is File)
        .cast<File>()
        .toList();
    expect(files.length, 2);
    var total = 0;
    for (final file in files) {
      total += await file.length();
    }
    expect(total, lessThanOrEqualTo(png.length * 2));
  });

  test('timeouts and invalid URL schemes leave no partial cache file',
      () async {
    cache = ProductPhotoCache(
        directoryProvider: () async => directory,
        requestTimeout: const Duration(milliseconds: 20));
    respond = (request) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(png);
    };
    expect(await cache.fileFor('$base/uploads/slow.png'), isNull);
    for (final url in [
      '',
      'file:///etc/passwd',
      'data:image/png;base64,abc',
      'http://user:secret@example.com/photo.png'
    ]) {
      expect(await cache.fileFor(url), isNull);
    }
    expect(await directory.list().toList(), isEmpty);
  });

  test('relative upload URL uses configured origin stripped of api/v1', () {
    expect(ProductPhotoCache.resolveUrl('/uploads/a.png', '$base/api/v1/'),
        '$base/uploads/a.png');
    expect(ProductPhotoCache.resolveUrl('uploads/a.png', '$base/api/v1'),
        '$base/uploads/a.png');
    expect(ProductPhotoCache.resolveUrl('https://cdn.example/a.png', base),
        'https://cdn.example/a.png');
    expect(ProductPhotoCache.resolveUrl('//other.example/a.png', base), '');
    expect(ProductPhotoCache.resolveUrl('uploads/../secret', base), '');
    expect(ProductPhotoCache.resolveUrl('javascript:alert(1)', base), '');
  });
}
