import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Public product images use a separate, credential-free client. A URL is the
/// cache identity: replacing a photo URL can never return the previous photo.
class ProductPhotoCache {
  static ProductPhotoCache _instance = ProductPhotoCache();
  static ProductPhotoCache get instance => _instance;

  @visibleForTesting
  static void replaceForTesting(ProductPhotoCache cache) => _instance = cache;
  static const maxImageBytes = 10 * 1024 * 1024;

  ProductPhotoCache({
    Future<Directory> Function()? directoryProvider,
    this.maxCacheBytes = 100 * 1024 * 1024,
    this.maxEntries = 256,
    this.requestTimeout = const Duration(seconds: 15),
    this.retryDelay = const Duration(seconds: 30),
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory {
    _dio = Dio(BaseOptions(
      connectTimeout: requestTimeout,
      receiveTimeout: requestTimeout,
      sendTimeout: requestTimeout,
      followRedirects: false,
      headers: const {},
    ));
  }

  final Future<Directory> Function() _directoryProvider;
  final int maxCacheBytes;
  final int maxEntries;
  final Duration requestTimeout;
  final Duration retryDelay;
  late final Dio _dio;
  Future<Directory>? _directory;
  final _inFlight = <String, Future<File?>>{};
  final _failedUntil = <String, DateTime>{};
  final _waiting = Queue<Completer<void>>();
  final _stored = StreamController<String>.broadcast();
  Stream<String> get onStored => _stored.stream;
  var _active = 0;
  Future<void> _writes = Future.value();

  static Future<Directory> _defaultDirectory() async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'product_photos'));

  static String resolveUrl(dynamic raw, String cloudBase) {
    if (raw is! String || raw.trim().isEmpty) return '';
    var base = cloudBase.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.endsWith('/api/v1')) base = base.substring(0, base.length - 7);
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return '';
    if (uri.hasScheme) return _validUrl(uri.toString()) ?? '';
    // Only Cloud's public upload paths may resolve relative to the API host.
    // Scheme-relative URLs must not silently switch the configured origin.
    if (uri.hasAuthority ||
        !(uri.path.startsWith('/uploads/') ||
            uri.path.startsWith('uploads/'))) {
      return '';
    }
    final origin = Uri.tryParse(base);
    if (origin == null || _validUrl(origin.toString()) == null) return '';
    final resolved =
        origin.resolve('/${uri.toString().replaceFirst(RegExp(r'^/+'), '')}');
    if (!resolved.path.startsWith('/uploads/')) return '';
    return _validUrl(resolved.toString()) ?? '';
  }

  static String? _validUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.removeFragment().toString();
  }

  Future<Directory> _root() =>
      _directory ??= _directoryProvider().then((dir) async {
        await dir.create(recursive: true);
        return dir;
      }).catchError((Object error) {
        _directory = null; // plugin/filesystem errors must be retryable
        throw error;
      });

  Future<File> _file(String url) async => File(
      p.join((await _root()).path, '${sha256.convert(utf8.encode(url))}.img'));

  /// Disk only, for authenticated LAN serving. Never starts a network request.
  Future<File?> cachedFile(String absoluteUrl) async {
    final url = _validUrl(absoluteUrl);
    if (url == null) return null;
    try {
      final file = await _file(url);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > maxImageBytes) {
        await file.delete();
        return null;
      }
      await file.setLastModified(DateTime.now());
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<File?> fileFor(String absoluteUrl) async {
    final url = _validUrl(absoluteUrl);
    if (url == null) return null;
    final cached = await cachedFile(url);
    if (cached != null) return cached;
    if ((_failedUntil[url]?.isAfter(DateTime.now()) ?? false)) return null;
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final pending = _download(url);
    _inFlight[url] = pending;
    try {
      final file = await pending;
      if (file == null) _failedUntil[url] = DateTime.now().add(retryDelay);
      // Bound failed-URL bookkeeping as well as the on-disk cache.
      if (_failedUntil.length > 512) {
        _failedUntil.remove(_failedUntil.keys.first);
      }
      return file;
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<void> prefetch(Iterable<String> absoluteUrls) async {
    // A bad image is deliberately independent of menu synchronization.
    await Future.wait(
        absoluteUrls.where((url) => url.isNotEmpty).toSet().map(fileFor));
  }

  Future<File?> _download(String url) async {
    if (_active >= 3) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    final cancel = CancelToken();
    try {
      final response = await _dio.get<ResponseBody>(url,
          cancelToken: cancel,
          options:
              Options(responseType: ResponseType.stream, headers: const {}));
      final body = response.data;
      if (response.statusCode != 200 || body == null) return null;
      final mime = response.headers
          .value('content-type')
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif']
          .contains(mime)) {
        return null;
      }
      final declared =
          int.tryParse(response.headers.value('content-length') ?? '');
      if (declared != null && declared > maxImageBytes) return null;
      final bytes = BytesBuilder(copy: false);
      final started = DateTime.now();
      await for (final chunk in body.stream.timeout(requestTimeout)) {
        if (bytes.length + chunk.length > maxImageBytes ||
            DateTime.now().difference(started) > requestTimeout) {
          return null;
        }
        bytes.add(chunk);
      }
      return await storeBytes(url, bytes.takeBytes());
    } catch (_) {
      return null;
    } finally {
      cancel.cancel();
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  /// Authenticated LAN clients can supply bytes without adding credentials to
  /// public image URLs. Identical validation and disk bounds apply here.
  Future<File?> storeBytes(String absoluteUrl, Uint8List bytes) async {
    final url = _validUrl(absoluteUrl);
    if (url == null ||
        bytes.isEmpty ||
        bytes.length > maxImageBytes ||
        bytes.length > maxCacheBytes ||
        maxEntries < 1) {
      return null;
    }
    try {
      final previous = _writes;
      final completed = Completer<void>();
      _writes = completed.future;
      await previous;
      File? temporary;
      try {
        // Decode one image at a time even when cloud and LAN warm together.
        if (!await compute(_validImage, bytes)) return null;
        final file = await _file(url);
        temporary =
            File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.part');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        await _trim(file.path);
        _failedUntil.remove(url);
        _stored.add(url);
        return file;
      } finally {
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
        } finally {
          // A disk-cleanup failure must never strand later image requests.
          completed.complete();
        }
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _trim(String newestPath) async {
    final files = <({File file, FileStat stat})>[];
    await for (final entry in (await _root()).list(followLinks: false)) {
      if (entry is! File) continue;
      final stat = await entry.stat();
      if (entry.path.endsWith('.img')) {
        files.add((file: entry, stat: stat));
      } else if (entry.path.endsWith('.part') &&
          DateTime.now().difference(stat.modified) > const Duration(hours: 1)) {
        await entry.delete();
      }
    }
    files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var total = files.fold<int>(0, (sum, file) => sum + file.stat.size);
    var count = files.length;
    for (final entry in files) {
      if (total <= maxCacheBytes && count <= maxEntries) break;
      if (entry.file.path == newestPath) continue;
      await entry.file.delete();
      total -= entry.stat.size;
      count--;
    }
  }
}

bool _validImage(Uint8List bytes) {
  try {
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null ||
        ![
          img.ImageFormat.png,
          img.ImageFormat.jpg,
          img.ImageFormat.webp,
          img.ImageFormat.gif
        ].contains(decoder.format)) {
      return false;
    }
    final info = decoder.startDecode(bytes);
    if (info == null ||
        info.width < 1 ||
        info.height < 1 ||
        info.width > 4096 ||
        info.height > 4096 ||
        info.numFrames > 100 ||
        info.width * info.height * info.numFrames > 16 * 1024 * 1024) {
      return false;
    }
    return decoder.decodeFrame(0) != null;
  } catch (_) {
    return false;
  }
}
