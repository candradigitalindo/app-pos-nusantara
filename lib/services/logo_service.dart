import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Mengelola logo struk (pembayaran & tagihan).
///
/// Prinsip: logo diproses jadi bitmap 1-bit dan disimpan LOKAL di perangkat,
/// lalu di-cache di memori. Pencetakan membaca dari cache lokal ini sehingga
/// TETAP JALAN tanpa internet (tidak bergantung cloud saat operasional).
///
/// Aturan ukuran:
/// - Lebar cetak mengikuti kertas: 58mm = 384 dot, 80mm = 576 dot.
/// - Gambar disesuaikan otomatis agar pas lebar kertas & dipusatkan.
/// - Tinggi dibatasi maksimal ~200 dot (±25mm) agar tidak boros kertas.
/// - Dianjurkan gambar hitam-putih kontras tinggi (akan dicetak monokrom).
class LogoService {
  LogoService._();
  static final LogoService instance = LogoService._();

  static const int dotsWidth58 = 384;
  static const int dotsWidth80 = 576;
  static const int _maxStoreWidth = 576; // simpan cukup untuk 80mm
  static const int _maxPrintHeight = 200; // batas tinggi cetak (dot)
  static const int _threshold = 150; // 0..255 — di bawah ini dianggap hitam

  static const String _fileName = 'receipt_logo.png';

  img.Image? _cached; // sumber logo (sudah di-downscale) untuk raster
  Uint8List? _previewBytes; // PNG untuk pratinjau di UI

  bool get hasLogo => _cached != null;
  Uint8List? get previewBytes => _previewBytes;

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Muat logo tersimpan ke cache memori. Panggil sekali saat start app.
  Future<void> init() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        _previewBytes = bytes;
        _cached = img.decodeImage(bytes);
      }
    } catch (_) {
      // abaikan — logo opsional
    }
  }

  /// Simpan logo dari byte gambar (mis. hasil image_picker).
  /// Mengembalikan pesan error, atau null bila berhasil.
  Future<String?> saveFromBytes(Uint8List sourceBytes) async {
    try {
      final decoded = img.decodeImage(sourceBytes);
      if (decoded == null) return 'Format gambar tidak didukung.';
      var im = decoded;
      if (im.width > _maxStoreWidth) {
        im = img.copyResize(im, width: _maxStoreWidth);
      }
      final png = img.encodePng(im);
      final file = await _file();
      await file.writeAsBytes(png, flush: true);
      _cached = im;
      _previewBytes = Uint8List.fromList(png);
      return null;
    } catch (e) {
      return 'Gagal memproses gambar: $e';
    }
  }

  Future<void> remove() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _cached = null;
    _previewBytes = null;
  }

  /// Hasilkan perintah ESC/POS raster (GS v 0) untuk logo pada lebar [dotWidth]
  /// (384 utk 58mm, 576 utk 80mm). Null bila belum ada logo.
  ///
  /// Sinkron & tanpa jaringan — dipanggil saat membangun struk.
  List<int>? escposRaster(int dotWidth) {
    final src = _cached;
    if (src == null) return null;

    var im = src;
    // Jangan upscale melebihi sumber; kecilkan agar pas lebar kertas.
    if (im.width > dotWidth) {
      im = img.copyResize(im, width: dotWidth);
    }
    if (im.height > _maxPrintHeight) {
      im = img.copyResize(im, height: _maxPrintHeight);
    }

    final w = im.width;
    final h = im.height;
    if (w <= 0 || h <= 0) return null;

    final bytesPerRow = (w + 7) >> 3;
    final data = Uint8List(bytesPerRow * h);

    for (int y = 0; y < h; y++) {
      final rowOff = y * bytesPerRow;
      for (int x = 0; x < w; x++) {
        final p = im.getPixel(x, y);
        final maxv = p.maxChannelValue;
        if (maxv <= 0) continue;
        final alpha = p.a / maxv; // 0..1 (transparan = putih)
        final lum = img.getLuminance(p) / maxv * 255.0; // 0..255
        final isBlack = alpha > 0.5 && lum < _threshold;
        if (isBlack) {
          data[rowOff + (x >> 3)] |= (0x80 >> (x & 7));
        }
      }
    }

    final xL = bytesPerRow & 0xff;
    final xH = (bytesPerRow >> 8) & 0xff;
    final yL = h & 0xff;
    final yH = (h >> 8) & 0xff;

    return <int>[
      0x1D, 0x76, 0x30, 0x00, // GS v 0 (raster bit image, mode normal)
      xL, xH, yL, yH,
      ...data,
      0x0A, // umpan satu baris setelah logo
    ];
  }
}
