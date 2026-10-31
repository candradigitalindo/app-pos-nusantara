import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pos_resto/services/product_photo_cache.dart';
import 'package:pos_resto/widgets/menu_avatar.dart';
import 'package:pos_resto/widgets/product_photo.dart';

// Cache decoding and disk writes are covered by product_photo_cache_test and
// the LAN tests. Keep this fixture inside the widget test's simulated clock:
// the contract here is that a stored-file event refreshes only its URL's tile.
class _ControllablePhotoCache extends ProductPhotoCache {
  final _events = StreamController<String>.broadcast();
  final _files = <String, File>{};

  @override
  Stream<String> get onStored => _events.stream;

  @override
  Future<File?> fileFor(String absoluteUrl) async => _files[absoluteUrl];

  @override
  Future<File?> cachedFile(String absoluteUrl) async => _files[absoluteUrl];

  void makeAvailable(String url, File file) {
    _files[url] = file;
    _events.add(url);
  }

  bool get hasListeners => _events.hasListener;
  Future<void> close() => _events.close();
}

void main() {
  late Directory directory;
  late File photo;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('product-photo-widget-');
    photo = await File('${directory.path}/photo.png')
        .writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
  });
  tearDownAll(() => directory.delete(recursive: true));

  Widget host(Widget child) => MaterialApp(
      home: Scaffold(
          body: Center(
              child: SizedBox(
                  width: 120, height: 90, child: Align(child: child)))));

  testWidgets('blank and unavailable photos retain the menu avatar',
      (tester) async {
    var requests = 0;
    Future<File?> loader(String _) async {
      requests++;
      return null;
    }

    await tester.pumpWidget(host(
        ProductPhoto(name: 'Nasi Goreng', photoUrl: '', loadFile: loader)));
    await tester.pump();
    expect(requests, 0);
    expect(find.byType(MenuAvatar), findsOneWidget);
    expect(find.text('NG'), findsOneWidget);

    await tester.pumpWidget(host(ProductPhoto(
        name: 'Nasi Goreng',
        photoUrl: 'https://images.test/missing.png',
        loadFile: loader)));
    await tester.pump();
    expect(requests, 1);
    expect(find.byType(MenuAvatar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('URL replacement clears an already displayed old image',
      (tester) async {
    final replacement = Completer<File?>();
    Future<File?> loader(String url) =>
        url.endsWith('old.png') ? Future.value(photo) : replacement.future;
    await tester.pumpWidget(host(ProductPhoto.fill(
        name: 'Menu',
        photoUrl: 'https://images.test/old.png',
        loadFile: loader)));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
    final decoded =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(decoded.width, lessThanOrEqualTo(768));
    expect(decoded.height, lessThanOrEqualTo(768));
    expect(decoded.policy, ResizeImagePolicy.fit);

    await tester.pumpWidget(host(ProductPhoto.fill(
        name: 'Menu',
        photoUrl: 'https://images.test/new.png',
        loadFile: loader)));
    expect(find.byType(Image), findsNothing);
    expect(find.byType(MenuAvatar), findsOneWidget);
    replacement.complete(photo);
    await tester.pump();
    expect(find.byKey(const ValueKey('https://images.test/new.png')),
        findsWidgets);

    await tester.pumpWidget(
        host(ProductPhoto.fill(name: 'Menu', photoUrl: '', loadFile: loader)));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byType(MenuAvatar), findsOneWidget);
  });

  testWidgets('late completion of an old URL never replaces the current photo',
      (tester) async {
    final old = Completer<File?>(), current = Completer<File?>();
    Future<File?> loader(String url) =>
        url.endsWith('old.png') ? old.future : current.future;
    await tester.pumpWidget(host(ProductPhoto(
        name: 'Menu',
        photoUrl: 'https://images.test/old.png',
        loadFile: loader)));
    await tester.pumpWidget(host(ProductPhoto(
        name: 'Menu',
        photoUrl: 'https://images.test/current.png',
        loadFile: loader)));
    old.complete(photo);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    current.complete(null);
    await tester.pump();
    expect(find.byType(MenuAvatar), findsOneWidget);
  });

  testWidgets('fixed and fill variants respect the available bounds',
      (tester) async {
    await tester.pumpWidget(
        host(const ProductPhoto(name: 'Menu', photoUrl: '', size: 44)));
    expect(tester.getSize(find.byType(ProductPhoto)), const Size(44, 44));
    await tester
        .pumpWidget(host(const ProductPhoto.fill(name: 'Menu', photoUrl: '')));
    expect(tester.getSize(find.byType(ProductPhoto)), const Size(120, 90));
    expect(tester.takeException(), isNull);
  });

  testWidgets('matching background cache arrival replaces offline fallback',
      (tester) async {
    final originalCache = ProductPhotoCache.instance;
    final cache = _ControllablePhotoCache();
    ProductPhotoCache.replaceForTesting(cache);
    addTearDown(() => ProductPhotoCache.replaceForTesting(originalCache));
    addTearDown(cache.close);
    const url = 'https://images.test/background.png';
    await tester
        .pumpWidget(host(const ProductPhoto.fill(name: 'Menu', photoUrl: url)));
    await tester.pump();
    expect(find.byType(MenuAvatar), findsOneWidget);
    expect(cache.hasListeners, isTrue);

    cache.makeAvailable('https://images.test/unrelated.png', photo);
    await tester.pump();
    expect(find.byType(Image), findsNothing);

    cache.makeAvailable(url, photo);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(
        host(const ProductPhoto.fill(name: 'Menu', photoUrl: '$url?new')));
    await tester.pump();
    cache.makeAvailable(url, photo);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byType(MenuAvatar), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(cache.hasListeners, isFalse);
  });
}
