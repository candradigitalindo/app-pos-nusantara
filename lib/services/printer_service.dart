import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Data Models ─────────────────────────────────────────────────────────────

enum PrinterType { bluetooth, lan }

/// Peran KHUSUS printer (di luar kategori menu). Routing tiket dapur/bar kini
/// ditentukan oleh KATEGORI menu yang dipilih per printer (lihat
/// [PrinterDevice.categoryIds]), bukan oleh peran.
/// - checker : salinan SELURUH pesanan (untuk pengecek/ekspeditor)
/// - cashier : struk pembayaran (cetak langsung)
class PrinterRole {
  static const String checker = 'checker';
  static const String cashier = 'cashier';
  static const String none = 'none';

  // Kompat data lama (printer pernah ber-role kitchen/bar).
  static const String kitchen = 'kitchen';
  static const String bar = 'bar';

  /// Peran khusus yang bisa dipilih untuk satu printer (selain kategori).
  static const List<String> selectable = [checker, cashier];

  static const Map<String, String> labels = {
    checker: 'Checker',
    cashier: 'Kasir',
    kitchen: 'Dapur',
    bar: 'Bar',
  };
}

class PrinterDevice {
  final String name;
  final String address; // BT MAC or IP:port
  final PrinterType type;
  final Set<String> roles; // peran khusus: checker / cashier
  final Set<String> categoryIds; // kategori menu yang dicetak printer ini
  final int paperCols; // lebar kertas dalam kolom: 32 (58mm) / 48 (80mm)
  final int copies; // rangkap cetak struk: 1 = sekali, 2 = + salinan "COPY"

  const PrinterDevice({
    required this.name,
    required this.address,
    required this.type,
    this.roles = const {},
    this.categoryIds = const {},
    this.paperCols = 48,
    this.copies = 1,
  });

  bool hasRole(String role) => roles.contains(role);
  bool printsCategory(String? categoryId) =>
      categoryId != null && categoryIds.contains(categoryId);

  /// Lebar kertas dalam mm (untuk label UI).
  int get paperMm => paperCols >= 48 ? 80 : 58;

  /// Label peran khusus (mis. "Checker, Kasir"). '-' bila tak ada.
  String get rolesLabel {
    if (roles.isEmpty) return '-';
    return PrinterRole.selectable
        .where(roles.contains)
        .map((r) => PrinterRole.labels[r] ?? r)
        .join(', ');
  }

  PrinterDevice copyWith(
          {Set<String>? roles,
          Set<String>? categoryIds,
          int? paperCols,
          int? copies}) =>
      PrinterDevice(
        name: name,
        address: address,
        type: type,
        roles: roles ?? this.roles,
        categoryIds: categoryIds ?? this.categoryIds,
        paperCols: paperCols ?? this.paperCols,
        copies: copies ?? this.copies,
      );

  /// Aktif/nonaktifkan satu peran khusus, kembalikan instance baru.
  PrinterDevice toggleRole(String role) {
    final next = Set<String>.from(roles);
    if (!next.remove(role)) next.add(role);
    return copyWith(roles: next);
  }

  /// Aktif/nonaktifkan satu kategori, kembalikan instance baru.
  PrinterDevice toggleCategory(String categoryId) {
    final next = Set<String>.from(categoryIds);
    if (!next.remove(categoryId)) next.add(categoryId);
    return copyWith(categoryIds: next);
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'address': address,
        'type': type.name,
        'roles': roles.toList(),
        'category_ids': categoryIds.toList(),
        'paper_cols': paperCols,
        'copies': copies,
      };

  factory PrinterDevice.fromMap(Map<String, dynamic> m) => PrinterDevice(
        name: m['name'] as String,
        address: m['address'] as String,
        type: PrinterType.values.firstWhere(
          (t) => t.name == m['type'],
          orElse: () => PrinterType.lan,
        ),
        roles: _parseSet(m['roles'] ?? m['role']),
        categoryIds: _parseSet(m['category_ids']),
        paperCols: (m['paper_cols'] as num?)?.toInt() ?? 48,
        copies: (m['copies'] as num?)?.toInt() ?? 1,
      );

  /// Toleran: terima List, String "a,b", atau tunggal — buang 'none'/kosong.
  static Set<String> _parseSet(dynamic raw) {
    Iterable<String> parts;
    if (raw is List) {
      parts = raw.map((e) => e.toString());
    } else if (raw is String) {
      parts = raw.split(',');
    } else {
      parts = const [];
    }
    return parts
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != PrinterRole.none)
        .toSet();
  }

  @override
  String toString() =>
      '$name ($address) [${type.name}/$rolesLabel/cat:${categoryIds.length}]';
}

// ─── PrinterService ───────────────────────────────────────────────────────────

class PrinterService {
  static const _prefKey = 'saved_printers';
  static const _defaultLanPort = 9100;

  // ── Bluetooth ──────────────────────────────────────────────────────────────

  /// Request Bluetooth permissions (Android only; iOS handled via Info.plist).
  Future<bool> requestBluetoothPermissions() async {
    if (Platform.isIOS) return true;

    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    return statuses.values.every(
      (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
    );
  }

  /// Return paired BT devices (Android) or BLE-discovered devices (iOS).
  Future<List<PrinterDevice>> scanBluetooth() async {
    final granted = await requestBluetoothPermissions();
    if (!granted) throw Exception('Izin Bluetooth ditolak');

    final devices = await PrintBluetoothThermal.pairedBluetooths;
    return devices
        .map((d) => PrinterDevice(
              name: d.name.isNotEmpty ? d.name : d.macAdress,
              address: d.macAdress,
              type: PrinterType.bluetooth,
            ))
        .toList();
  }

  // ── LAN Discovery ──────────────────────────────────────────────────────────

  /// Scan local /24 subnet for open port 9100 (ESC/POS default).
  Future<List<PrinterDevice>> scanLan({
    int port = _defaultLanPort,
    Duration timeout = const Duration(milliseconds: 400),
    void Function(int current, int total)? onProgress,
  }) async {
    // network_info_plus lebih andal di iOS (menghindari VPN/interface ganda)
    String? localIp = await NetworkInfo().getWifiIP();

    // Fallback ke dart:io jika network_info_plus tidak berhasil
    if (localIp == null || localIp.isEmpty) {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            localIp = addr.address;
            break;
          }
        }
        if (localIp != null) break;
      }
    }

    if (localIp == null) throw Exception('Tidak dapat mendeteksi IP lokal. Pastikan WiFi aktif.');

    final parts = localIp.split('.');
    final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';

    final found = <PrinterDevice>[];
    const total = 254;
    var done = 0;

    const batchSize = 32;
    for (var start = 1; start <= total; start += batchSize) {
      final end = (start + batchSize - 1).clamp(1, total);
      final futures = <Future<void>>[];

      for (var i = start; i <= end; i++) {
        final ip = '$subnet.$i';
        futures.add(_checkPort(ip, port, timeout).then((open) {
          if (open) {
            found.add(PrinterDevice(
              name: 'Printer LAN ($ip)',
              address: '$ip:$port',
              type: PrinterType.lan,
            ));
          }
          done++;
          onProgress?.call(done, total);
        }));
      }
      await Future.wait(futures);
    }

    return found;
  }

  Future<bool> _checkPort(String ip, int port, Duration timeout) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Cek apakah satu printer LAN bisa dijangkau (untuk entri manual via IP).
  /// Timeout lebih longgar dari saat scan massal agar printer lambat tetap lolos.
  Future<bool> pingLan(String ip, int port,
          {Duration timeout = const Duration(seconds: 3)}) =>
      _checkPort(ip, port, timeout);

  /// Ping LAN yang DISERIALISASI dengan job cetak ke printer yang sama (lewat
  /// kunci per-alamat). Mencegah ping heartbeat bertabrakan dengan perintah
  /// cetak (printer thermal umumnya hanya menerima 1 koneksi di port 9100).
  /// Bila printer sedang mencetak, ping menunggu sampai selesai (lalu cepat).
  Future<bool> pingLanSafe(String addressWithPort,
      {Duration timeout = const Duration(seconds: 1)}) {
    final parts = addressWithPort.split(':');
    final ip = parts.first;
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 9100 : 9100;
    return _withLanLock(addressWithPort, () => _checkPort(ip, port, timeout));
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  Future<List<PrinterDevice>> getSavedPrinters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefKey) ?? [];
    return raw
        .map((s) {
          final parts = s.split('|');
          if (parts.length < 3) return null;
          return PrinterDevice(
            name: parts[0],
            address: parts[1],
            type: PrinterType.values.firstWhere(
              (t) => t.name == parts[2],
              orElse: () => PrinterType.lan,
            ),
            // parts[3]=peran; parts[4]=id kategori; parts[5]=lebar kolom kertas;
            // parts[6]=rangkap cetak (copies).
            roles: parts.length >= 4
                ? PrinterDevice._parseSet(parts[3])
                : const {},
            categoryIds: parts.length >= 5
                ? PrinterDevice._parseSet(parts[4])
                : const {},
            paperCols: parts.length >= 6
                ? (int.tryParse(parts[5]) ?? 48)
                : 48,
            copies: parts.length >= 7 ? (int.tryParse(parts[6]) ?? 1) : 1,
          );
        })
        .whereType<PrinterDevice>()
        .toList();
  }

  Future<void> savePrinter(PrinterDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getSavedPrinters();
    final idx = existing.indexWhere((d) => d.address == device.address);
    if (idx >= 0) {
      existing[idx] = device; // ganti DI TEMPAT — jaga urutan agar tile tak geser
    } else {
      existing.add(device);
    }
    await prefs.setStringList(_prefKey, existing.map(_serialize).toList());
  }

  Future<void> removePrinter(String address) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getSavedPrinters();
    final updated = existing.where((d) => d.address != address).toList();
    await prefs.setStringList(_prefKey, updated.map(_serialize).toList());
  }

  String _serialize(PrinterDevice d) =>
      '${d.name}|${d.address}|${d.type.name}|${d.roles.join(',')}|${d.categoryIds.join(',')}|${d.paperCols}|${d.copies}';

  // ── Test Print ─────────────────────────────────────────────────────────────

  Future<void> testPrint(PrinterDevice device) async {
    final data = _buildTestPage(device);
    if (device.type == PrinterType.bluetooth) {
      await _sendBluetooth(device.address, data);
    } else {
      await _sendLan(device.address, data);
    }
  }

  // ── ESC/POS builder helpers ──────────────────────────────────────────────────
  static const int _esc = 0x1B;
  static const int _gs = 0x1D;
  static const int _lf = 0x0A;

  // Latin-1 agar karakter seperti titik ribuan & strip aman di printer ESC/POS.
  List<int> _t(String s) => latin1.encode(s);
  List<int> _line(String s) => [..._t(s), _lf];
  List<int> _align(int n) => [_esc, 0x61, n]; // 0=kiri,1=tengah,2=kanan
  List<int> _bold(bool on) => [_esc, 0x45, on ? 1 : 0];
  // GS ! n — ukuran karakter: nibble tinggi = lebar, nibble rendah = tinggi.
  List<int> _size(int w, int h) => [_gs, 0x21, (w << 4) | h];
  List<int> _sep(int cols, [String ch = '-']) => _line(ch * cols);

  /// Baris dua kolom (kiri rata kiri, kanan rata kanan) dalam lebar [cols].
  List<int> _row(int cols, String left, String right) {
    var l = left;
    final space = cols - l.length - right.length;
    if (space < 1) {
      final maxLeft = cols - right.length - 1;
      l = maxLeft > 0 ? l.substring(0, maxLeft) : '';
      return _line('$l $right');
    }
    return _line(l + ' ' * space + right);
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  List<int> _buildTestPage(PrinterDevice device) {
    final now = DateTime.now();
    final tgl =
        '${_two(now.day)}/${_two(now.month)}/${now.year} ${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final tipe = device.type == PrinterType.bluetooth ? 'Bluetooth' : 'LAN';
    final roleLabel = device.rolesLabel;
    final c = device.paperCols; // lebar kolom (32/48)

    // Penanda lebar kolom dinamis: "1234567890..." sepanjang kertas.
    final ruler =
        List.generate(c, (i) => ((i + 1) % 10).toString()).join();

    return [
      _esc, 0x40, // init

      // ── Header besar ──
      ..._align(1),
      ..._size(1, 1), // dobel lebar & tinggi
      ..._bold(true),
      ..._line('POS RESTO'),
      ..._bold(false),
      ..._size(0, 0),
      ..._line('Sistem Kasir Restoran'),
      _lf,
      ..._size(0, 1), // dobel tinggi
      ..._line('TEST PRINT'),
      ..._size(0, 0),
      ..._line('Printer Berhasil Terhubung'),
      _lf,

      // ── Info printer ──
      ..._align(0),
      ..._sep(c, '='),
      ..._row(c, 'Nama', device.name),
      ..._row(c, 'Alamat', device.address),
      ..._row(c, 'Tipe', tipe),
      ..._row(c, 'Kertas', '${device.paperMm}mm ($c kolom)'),
      ..._row(c, 'Peran', roleLabel),
      ..._row(c, 'Waktu', tgl),
      ..._sep(c, '='),

      // ── Uji perataan ──
      ..._align(1),
      ..._line('Uji Perataan & Ukuran'),
      ..._align(0),
      ..._sep(c),
      ..._row(c, 'Kiri', 'Kanan'),
      ..._row(c, '1x Nasi Goreng', '25.000'),
      ..._row(c, '2x Es Teh Manis', '8.000'),
      ..._row(c, '1x Ayam Bakar', '28.000'),
      ..._sep(c),
      ..._bold(true),
      ..._row(c, 'TOTAL', '61.000'),
      ..._bold(false),
      _lf,

      // ── Uji gaya teks ──
      ..._align(1),
      ..._bold(true),
      ..._line('Teks Tebal'),
      ..._bold(false),
      ..._line('Teks Normal'),
      ..._size(1, 1),
      ..._line('Teks Besar'),
      ..._size(0, 0),
      ..._line('Teks Kecil ABCdef 0123456789'),
      _lf,

      // ── Uji lebar kertas (penanda kolom penuh) ──
      ..._align(0),
      ..._line(ruler),
      _lf,

      ..._align(1),
      ..._line('*** SELESAI ***'),
      ..._line('Jika struk ini rapi & penuh ke kanan,'),
      ..._line('lebar kertas sudah benar.'),

      // ── Feed & potong ──
      _lf, _lf, _lf,
      _gs, 0x56, 0x41, 0x03, // partial cut
    ];
  }

  // ── Serialisasi cetak (anti tabrakan saat banyak transaksi) ──────────────────
  //
  // Plugin print_bluetooth_thermal hanya punya SATU koneksi aktif untuk seluruh
  // aplikasi. Karena struk kasir (cetak langsung), antrian dapur/bar, dan bill
  // waiter sama-sama bisa memicu cetak Bluetooth bersamaan, semua operasi BT
  // HARUS antre global agar connect/write/disconnect tidak saling merusak.
  // Lock dibuat `static` supaya dibagi lintas instance PrinterService.
  static Future<void> _btChain = Future.value();

  // LAN: cukup serialisasi per-alamat (printer sama) agar byte tidak berbaur;
  // printer berbeda tetap boleh paralel.
  static final Map<String, Future<void>> _lanChains = {};

  static Future<T> _withBtLock<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final prev = _btChain;
    _btChain = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }

  static Future<T> _withLanLock<T>(
      String address, Future<T> Function() action) {
    final completer = Completer<void>();
    final prev = _lanChains[address] ?? Future.value();
    _lanChains[address] = completer.future;
    return prev.then((_) => action()).whenComplete(() {
      completer.complete();
      // Bersihkan map bila tidak ada yang antre setelah kita.
      if (identical(_lanChains[address], completer.future)) {
        _lanChains.remove(address);
      }
    });
  }

  // ── Internal send ──────────────────────────────────────────────────────────

  Future<void> _sendBluetooth(String address, List<int> data) {
    return _withBtLock(() async {
      try {
        final connected = await PrintBluetoothThermal.connect(
          macPrinterAddress: address,
        ).timeout(const Duration(seconds: 8), onTimeout: () => false);
        if (!connected) throw Exception('Gagal terhubung ke printer Bluetooth');

        final sent = await PrintBluetoothThermal.writeBytes(
          Uint8List.fromList(data),
        ).timeout(const Duration(seconds: 12), onTimeout: () => false);
        if (!sent) throw Exception('Gagal mengirim data ke printer');
      } finally {
        // Selalu putuskan koneksi agar tidak menahan sesi BT job berikutnya.
        try {
          await PrintBluetoothThermal.disconnect
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
    });
  }

  Future<void> _sendLan(String addressWithPort, List<int> data) {
    return _withLanLock(addressWithPort, () async {
      final parts = addressWithPort.split(':');
      final ip = parts[0];
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 9100 : 9100;

      debugPrint('LAN print → $ip:$port (${data.length} bytes)');
      Socket? socket;
      try {
        socket = await Socket.connect(ip, port,
            timeout: const Duration(seconds: 5));
        socket.add(data);
        await socket.flush().timeout(const Duration(seconds: 8));
        // Beri jeda agar printer sempat menarik seluruh buffer sebelum ditutup.
        await Future.delayed(const Duration(milliseconds: 150));
        debugPrint('LAN print → OK ($ip:$port)');
      } catch (e) {
        debugPrint('LAN print → GAGAL ($ip:$port): $e');
        rethrow;
      } finally {
        try {
          await socket?.close();
        } catch (_) {}
        socket?.destroy();
      }
    });
  }

  // ── Public send methods ────────────────────────────────────────────────────

  Future<void> sendBluetooth(String address, List<int> data) =>
      _sendBluetooth(address, data);

  Future<void> sendLan(String addressWithPort, List<int> data) =>
      _sendLan(addressWithPort, data);
}
