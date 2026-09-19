import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../database/database.dart';
import '../repositories/cashier_repository.dart';
import '../repositories/order_repository.dart';
import '../repositories/product_repository.dart';
import '../repositories/table_repository.dart';
import '../utils/ulid.dart';

/// HTTP + WebSocket server yang berjalan di Main POS.
/// Waiter station terhubung ke server ini via WiFi lokal cafe.
class LocalApiServer {
  static final LocalApiServer instance = LocalApiServer._();
  LocalApiServer._();

  static const int defaultPort = 7070;

  HttpServer? _httpServer;
  final Set<WebSocketChannel> _wsClients = {};

  final _orderRepo = OrderRepository();
  final _productRepo = ProductRepository();
  final _tableRepo = TableRepository();
  final _cashierRepo = CashierRepository();

  bool get isRunning => _httpServer != null;
  int? _port;
  int? get port => _port;

  // ── Start / Stop ──────────────────────────────────────────────────────────

  Future<void> start({int port = defaultPort}) async {
    if (_httpServer != null) return;

    final router = Router()
      ..get('/api/ping', _getPing)
      ..post('/api/auth', _auth)
      ..get('/api/tables', _getTables)
      ..get('/api/categories', _getCategories)
      ..get('/api/products', _getProducts)
      ..get('/api/orders/active', _getActiveOrders)
      ..get('/api/orders/<id>', _getOrder)
      ..post('/api/orders', _createOrder)
      ..post('/api/orders/<id>/items', _addItems)
      // Operasi item terkirim dari station: void / titip / pindah (per-unit)
      ..post('/api/order-items/<itemId>/void', _voidItem)
      ..post('/api/order-items/<itemId>/park', _parkItem)
      ..post('/api/order-items/<itemId>/move', _moveItem)
      // ── Kasir station (klien tipis): operasi kasir di DB perangkat utama ──
      ..get('/api/orders/<id>/full', _getOrderFull)
      ..post('/api/orders/<id>/pay', _payOrder)
      ..post('/api/orders/<id>/split-pay', _splitPayOrder)
      ..post('/api/orders/<id>/discount', _discountOrder)
      ..post('/api/orders/<id>/compliment', _complimentOrder)
      ..post('/api/orders/<id>/move-table', _moveOrderTable)
      ..get('/api/orders/<id>/mergeable', _getMergeableOrders)
      ..post('/api/orders/<id>/merge', _mergeOrders)
      ..get('/api/held-items', _getHeldItems)
      ..post('/api/held-items/<itemId>/pull', _pullHeldItem)
      ..get('/api/shift/active', _getActiveShift)
      ..post('/api/shift/open', _openShift)
      ..post('/api/shift/close', _closeShift)
      ..get('/api/cashier/session-summary', _cashierSessionSummary)
      ..get('/ws', webSocketHandler(_onWsConnect));

    final handler = const Pipeline()
        .addMiddleware(_corsMiddleware())
        .addMiddleware(_sessionMiddleware())
        .addHandler(router.call);

    _httpServer = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      port,
    );
    _port = port;
  }

  Future<void> stop() async {
    for (final client in List.of(_wsClients)) {
      await client.sink.close();
    }
    _wsClients.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
    _port = null;
  }

  // ── WebSocket ─────────────────────────────────────────────────────────────

  void _onWsConnect(WebSocketChannel ws) {
    _wsClients.add(ws);
    ws.stream.listen(
      (_) {},
      onDone: () => _wsClients.remove(ws),
      onError: (_) => _wsClients.remove(ws),
      cancelOnError: true,
    );
  }

  /// Broadcast event ke semua waiter station yang terhubung.
  /// Dipanggil dari controller setelah mutasi data.
  void broadcast(String event, Map<String, dynamic> data) {
    if (_wsClients.isEmpty) return;
    final msg = jsonEncode({
      'event': event,
      'data': data,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    for (final client in List.of(_wsClients)) {
      try {
        client.sink.add(msg);
      } catch (_) {
        _wsClients.remove(client);
      }
    }
  }

  // ── GET /api/ping ─────────────────────────────────────────────────────────
  // Dipakai waiter station untuk konfirmasi bahwa server ini adalah Main POS.

  Future<Response> _getPing(Request req) async {
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query('outlet_config', limit: 1);
      final outlet = rows.isNotEmpty ? rows.first : <String, dynamic>{};
      return _ok({
        'app': 'pos-resto',
        'version': '1.0.0',
        'port': _port,
        'outlet_name': outlet['outlet_name'] ?? 'POS Resto',
        'outlet_code': outlet['outlet_code'] ?? '',
        'connected_stations': _wsClients.length,
      });
    } catch (e) {
      return _ok({
        'app': 'pos-resto',
        'version': '1.0.0',
        'port': _port,
      });
    }
  }

  // ── POST /api/auth ────────────────────────────────────────────────────────
  // Verifikasi PIN waiter (mode station). Kembalikan nama untuk atribusi order.

  Future<Response> _auth(Request req) async {
    // Rate-limit per-IP: PIN hanya 4 digit — tanpa throttle, seluruh ruang
    // 10.000 PIN bisa di-brute-force dari LAN dalam hitungan menit.
    final ip = _clientIp(req);
    if (_isLockedOut(ip)) {
      return Response(
        429,
        body: jsonEncode({
          'success': false,
          'error': 'Terlalu banyak percobaan PIN — coba lagi 5 menit lagi',
        }),
        headers: _jsonHeader,
      );
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final pin = (body['pin'] as String?)?.trim();
    if (pin == null || pin.isEmpty) return _badRequest('pin wajib diisi');

    try {
      final db = await AppDatabase.instance.database;
      final users = await db.query('users', where: 'is_active = 1');
      final pinHash = sha256.convert(utf8.encode(pin)).toString();

      for (final u in users) {
        // Hanya hash asli — jalur backdoor 'dummyhash'/1234 DIHAPUS
        // (akun seed dimigrasi ke hash sungguhan di DB v10).
        if ((u['password_hash'] as String? ?? '') == pinHash) {
          _authFails.remove(ip);
          // Terbitkan token sesi: wajib disertakan station pada semua
          // request berikutnya (header X-Station-Token).
          final token = _issueSessionToken();
          return _ok({
            'id': u['id'],
            'full_name': u['full_name'],
            'username': u['username'],
            'role': u['role'],
            'token': token,
          });
        }
      }
      _recordAuthFail(ip);
      return Response(
        401,
        body: jsonEncode({'success': false, 'error': 'PIN salah'}),
        headers: _jsonHeader,
      );
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── Sesi & rate-limit ────────────────────────────────────────────────────

  /// Token sesi station yang masih berlaku (token → kedaluwarsa, sliding).
  final Map<String, DateTime> _sessions = {};
  static const _sessionTtl = Duration(hours: 12);

  /// Riwayat gagal PIN per-IP untuk lockout brute-force.
  final Map<String, List<DateTime>> _authFails = {};
  static const _maxAuthFails = 5;
  static const _authFailWindow = Duration(minutes: 10);
  static const _lockoutFor = Duration(minutes: 5);

  String _clientIp(Request req) {
    final info = req.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return 'unknown';
  }

  bool _isLockedOut(String ip) {
    final fails = _authFails[ip];
    if (fails == null) return false;
    final now = DateTime.now();
    fails.removeWhere((t) => now.difference(t) > _authFailWindow);
    if (fails.length < _maxAuthFails) return false;
    return now.difference(fails.last) < _lockoutFor;
  }

  void _recordAuthFail(String ip) {
    (_authFails[ip] ??= []).add(DateTime.now());
  }

  String _issueSessionToken() {
    // 2× ULID ≈ 160 bit acak — cukup untuk token sesi LAN.
    final token = '${Ulid.generate()}${Ulid.generate()}';
    _sessions[token] = DateTime.now().add(_sessionTtl);
    // Housekeeping: buang token kedaluwarsa.
    _sessions.removeWhere((_, exp) => DateTime.now().isAfter(exp));
    return token;
  }

  /// Middleware: semua route (selain ping/auth/ws & preflight) wajib membawa
  /// token sesi yang valid. Tanpa ini, siapa pun di WiFi bisa memanggil
  /// endpoint pembayaran/void/diskon/shift.
  Middleware _sessionMiddleware() => (inner) => (req) {
        if (req.method == 'OPTIONS') return inner(req);
        final path = req.url.path; // tanpa leading slash
        if (path == 'api/ping' || path == 'api/auth' || path == 'ws') {
          return inner(req);
        }
        final token = req.headers['x-station-token'];
        final exp = token == null ? null : _sessions[token];
        if (exp == null || DateTime.now().isAfter(exp)) {
          return Response(
            401,
            body: jsonEncode({
              'success': false,
              'error': 'Sesi tidak valid — login ulang di station',
            }),
            headers: _jsonHeader,
          );
        }
        _sessions[token!] = DateTime.now().add(_sessionTtl); // sliding TTL
        return inner(req);
      };

  // ── GET /api/tables ───────────────────────────────────────────────────────

  Future<Response> _getTables(Request req) async {
    try {
      // 2 query (bukan N+1): daftar meja + semua order aktif sekaligus.
      final tables = await _tableRepo.getTables();
      final activeByTable = await _orderRepo.getActiveOrdersByTable();
      final rows = tables
          .map((t) => <String, dynamic>{
                ...t.toMap(),
                'active_order': activeByTable[t.tableNumber]?.toMap(),
              })
          .toList();
      return _ok(rows);
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── GET /api/categories ───────────────────────────────────────────────────

  Future<Response> _getCategories(Request req) async {
    try {
      final cats = await _productRepo.getCategories();
      return _ok(cats.map((c) => c.toMap()).toList());
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── GET /api/products?category_id=... ─────────────────────────────────────

  Future<Response> _getProducts(Request req) async {
    try {
      final categoryId = req.url.queryParameters['category_id'];
      final products = await _productRepo.getProducts(categoryId: categoryId);
      return _ok(products.map((p) => p.toMap()).toList());
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── GET /api/orders/active ────────────────────────────────────────────────

  Future<Response> _getActiveOrders(Request req) async {
    try {
      final map = await _orderRepo.getActiveOrdersWithItems();
      final result = map.entries
          .map((e) => <String, dynamic>{
                ...e.key.toMap(),
                'items': e.value.map((i) => i.toMap()).toList(),
              })
          .toList();
      return _ok(result);
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── GET /api/orders/:id ───────────────────────────────────────────────────

  Future<Response> _getOrder(Request req, String id) async {
    try {
      final order = await _orderRepo.getOrderById(id);
      if (order == null) return _notFound('Order tidak ditemukan');
      final items = await _orderRepo.getOrderItems(id);
      return _ok(<String, dynamic>{
        ...order.toMap(),
        'items': items.map((i) => i.toMap()).toList(),
      });
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── POST /api/orders ──────────────────────────────────────────────────────

  Future<Response> _createOrder(Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }

    final tableNumber = body['table_number'] as String?;
    if (tableNumber == null || tableNumber.trim().isEmpty) {
      return _badRequest('table_number wajib diisi');
    }

    final List<OrderItemInput> items;
    try {
      items = _parseItems(body['items']);
    } on FormatException catch (e) {
      return _badRequest(e.message);
    }

    try {
      final order = await _orderRepo.createOrder(
        tableNumber: tableNumber,
        customerName: body['customer_name'] as String?,
        pax: _asInt(body['pax']) ?? 1,
        items: items,
        waiterName: body['waiter_name'] as String?,
        createdBy: body['created_by'] as String?,
      );

      broadcast('order_created', order.toMap());
      return _ok(order.toMap(), status: 201);
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── POST /api/orders/:id/items ────────────────────────────────────────────

  Future<Response> _addItems(Request req, String id) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }

    final List<OrderItemInput> items;
    try {
      items = _parseItems(body['items']);
    } on FormatException catch (e) {
      return _badRequest(e.message);
    }

    try {
      await _orderRepo.addItemToOrder(
        orderId: id,
        items: items,
        waiterName: body['waiter_name'] as String? ?? '',
      );

      final order = await _orderRepo.getOrderById(id);
      if (order != null) broadcast('order_items_added', order.toMap());
      return _ok({'success': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── POST /api/order-items/<itemId>/void {qty?, voided_by, reason} ──────────
  // Void item terkirim (per-unit). Otorisasi manajer diverifikasi di station
  // via /api/auth sebelum memanggil ini.
  Future<Response> _voidItem(Request req, String itemId) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    try {
      await _orderRepo.voidOrderItem(
        itemId: itemId,
        voidedBy: body['voided_by'] as String? ?? '',
        reason: body['reason'] as String? ?? 'Void (station)',
        qty: _asInt(body['qty']),
      );
      broadcast('order_items_added', {'item_id': itemId});
      return _ok({'success': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── POST /api/order-items/<itemId>/park {qty?, by} ────────────────────────
  // Titipkan item ke Meja Titipan (per-unit).
  Future<Response> _parkItem(Request req, String itemId) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    try {
      await _orderRepo.parkItem(
        itemId: itemId,
        qty: _asInt(body['qty']),
        movedBy: body['by'] as String? ?? '',
      );
      broadcast('order_items_added', {'item_id': itemId});
      return _ok({'success': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── POST /api/order-items/<itemId>/move {qty?, target_order_id, by} ────────
  // Pindahkan item ke order aktif meja lain (per-unit).
  Future<Response> _moveItem(Request req, String itemId) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final targetOrderId = (body['target_order_id'] as String?)?.trim();
    if (targetOrderId == null || targetOrderId.isEmpty) {
      return _badRequest('target_order_id wajib diisi');
    }
    try {
      await _orderRepo.transferItemQty(
        itemId: itemId,
        qty: _asInt(body['qty']),
        targetOrderId: targetOrderId,
        movedBy: body['by'] as String? ?? '',
      );
      broadcast('order_items_added', {'item_id': itemId});
      return _ok({'success': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  // ── Input parsing (aman, kembalikan 400 bukan 500) ────────────────────────

  /// Mengubah `items` JSON menjadi List<OrderItemInput>.
  /// Melempar [FormatException] dengan pesan jelas bila tidak valid.
  List<OrderItemInput> _parseItems(dynamic raw) {
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('items tidak boleh kosong');
    }
    final result = <OrderItemInput>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw const FormatException('Format item tidak valid');
      }
      final productId = entry['product_id'];
      if (productId is! String || productId.isEmpty) {
        throw const FormatException('product_id wajib diisi pada setiap item');
      }
      final qty = _asInt(entry['qty']);
      if (qty == null || qty <= 0) {
        throw FormatException('qty tidak valid untuk produk $productId');
      }
      result.add(OrderItemInput(
        productId: productId,
        qty: qty,
        notes: entry['notes'] as String?,
      ));
    }
    return result;
  }

  /// Terima int maupun num/string numerik (JSON kadang kirim 2.0).
  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  // ── Kasir station handlers ────────────────────────────────────────────────

  /// GET /api/orders/<id>/full — order + items + charges (untuk tagihan).
  Future<Response> _getOrderFull(Request req, String id) async {
    try {
      final order = await _orderRepo.getOrderById(id);
      if (order == null) return _notFound('Order tidak ditemukan');
      final items = await _orderRepo.getOrderItems(id);
      final charges = await _orderRepo.getOrderCharges(id);
      return _ok({
        'order': order.toMap(),
        'items': items.map((i) => i.toMap()).toList(),
        'charges': charges.map((c) => c.toMap()).toList(),
      });
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/orders/<id>/pay {payment_method, paid_amount, created_by}
  Future<Response> _payOrder(Request req, String id) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final method = body['payment_method'] as String?;
    final paid = _asDouble(body['paid_amount']);
    if (method == null || method.isEmpty) {
      return _badRequest('payment_method wajib');
    }
    if (paid == null) return _badRequest('paid_amount wajib');
    try {
      final r = await _orderRepo.processPayment(
        orderId: id,
        paymentMethod: method,
        paidAmount: paid,
        createdBy: body['created_by'] as String?,
      );
      broadcast('order_paid', {'order_id': id});
      // Hanya field JSON-safe (result berisi objek Transaction/Payment).
      return _ok({
        'order_id': r['order_id'],
        'total_amount': r['total_amount'],
        'remaining': r['remaining'],
        'paid_amount': r['paid_amount'],
        'change': r['change'],
        'payment_status': r['payment_status'],
      });
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/orders/<id>/split-pay {amount, payment_method, note, created_by}
  Future<Response> _splitPayOrder(Request req, String id) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final method = body['payment_method'] as String?;
    final amount = _asDouble(body['amount']);
    if (method == null || method.isEmpty) {
      return _badRequest('payment_method wajib');
    }
    if (amount == null || amount <= 0) return _badRequest('amount wajib > 0');
    try {
      final r = await _orderRepo.splitBillPayment(
        orderId: id,
        amount: amount,
        paymentMethod: method,
        note: body['note'] as String?,
        createdBy: body['created_by'] as String?,
      );
      broadcast('order_paid', {'order_id': id});
      return _ok({
        'order_id': r['order_id'],
        'amount_paid': r['amount_paid'],
        'remaining': r['remaining'],
        'payment_status': r['payment_status'],
      });
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// GET /api/shift/active — shift aktif (atau null).
  Future<Response> _getActiveShift(Request req) async {
    try {
      final shift = await _cashierRepo.getActiveShift();
      return _ok({'shift': shift?.toMap()});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/shift/open {opened_by, opening_cash}
  Future<Response> _openShift(Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final openedBy = body['opened_by'] as String?;
    final cash = _asDouble(body['opening_cash']) ?? 0;
    if (openedBy == null || openedBy.isEmpty) {
      return _badRequest('opened_by wajib');
    }
    try {
      final shift =
          await _cashierRepo.openShift(openedBy: openedBy, openingCash: cash);
      return _ok({'shift': shift.toMap()});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/shift/close {shift_id, closed_by}
  Future<Response> _closeShift(Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final shiftId = body['shift_id'] as String?;
    final closedBy = body['closed_by'] as String?;
    if (shiftId == null || closedBy == null) {
      return _badRequest('shift_id & closed_by wajib');
    }
    try {
      final shift =
          await _cashierRepo.closeShift(shiftId: shiftId, closedBy: closedBy);
      return _ok({'shift': shift.toMap()});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/orders/<id>/discount {charge_type, value, note}
  Future<Response> _discountOrder(Request req, String id) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final type = body['charge_type'] as String?;
    final value = _asDouble(body['value']);
    if (type == null || value == null) {
      return _badRequest('charge_type & value wajib');
    }
    try {
      await _orderRepo.applyDiscount(
        orderId: id,
        chargeType: type,
        value: value,
        note: (body['note'] as String?) ?? '',
      );
      broadcast('order_updated', {'order_id': id});
      return _ok({'ok': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/orders/<id>/compliment {compliment_by, reason, created_by}
  /// Gratiskan seluruh order (paritas tombol Kompliment kasir utama).
  Future<Response> _complimentOrder(Request req, String id) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final by = body['compliment_by'] as String?;
    if (by == null || by.isEmpty) return _badRequest('compliment_by wajib');
    try {
      await _orderRepo.complimentOrder(
        orderId: id,
        complimentBy: by,
        reason: (body['reason'] as String?) ?? '',
        createdBy: body['created_by'] as String?,
      );
      // Order kini paid (total 0) & meja bebas — event sama dengan pembayaran.
      broadcast('order_paid', {'order_id': id});
      return _ok({'ok': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/orders/<id>/move-table {table_number}
  Future<Response> _moveOrderTable(Request req, String id) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final table = body['table_number'] as String?;
    if (table == null || table.isEmpty) return _badRequest('table_number wajib');
    try {
      await _orderRepo.moveOrderToTable(orderId: id, newTableNumber: table);
      broadcast('order_updated', {'order_id': id});
      return _ok({'ok': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// GET /api/orders/<id>/mergeable — order aktif meja LAIN yang bisa digabung
  /// ke order <id> (aturan sama dengan kasir/waiter utama).
  Future<Response> _getMergeableOrders(Request req, String id) async {
    try {
      final order = await _orderRepo.getOrderById(id);
      if (order == null) return _notFound('Order tidak ditemukan');
      final list = await _orderRepo.getMergeableOrders(order.tableNumber);
      return _ok(list.map((o) => o.toMap()).toList());
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/orders/<id>/merge {source_order_id} — gabung order meja lain
  /// ke order <id>.
  Future<Response> _mergeOrders(Request req, String id) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final source = body['source_order_id'] as String?;
    if (source == null || source.isEmpty) {
      return _badRequest('source_order_id wajib');
    }
    try {
      await _orderRepo.mergeOrders(targetOrderId: id, sourceOrderId: source);
      broadcast('order_updated', {'order_id': id});
      return _ok({'ok': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// GET /api/held-items — item yang sedang di Meja Titipan.
  Future<Response> _getHeldItems(Request req) async {
    try {
      final items = await _orderRepo.getHeldItems();
      return _ok(items.map((i) => i.toMap()).toList());
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// POST /api/held-items/<itemId>/pull {qty, target_order_id, by} — tarik
  /// item titipan ke order tamu.
  Future<Response> _pullHeldItem(Request req, String itemId) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return _badRequest('Body JSON tidak valid');
    }
    final target = body['target_order_id'] as String?;
    if (target == null || target.isEmpty) {
      return _badRequest('target_order_id wajib');
    }
    try {
      await _orderRepo.pullHeldItem(
        itemId: itemId,
        qty: (body['qty'] as num?)?.toInt(),
        targetOrderId: target,
        movedBy: (body['by'] as String?) ?? 'Station',
      );
      broadcast('order_items_added', {'order_id': target});
      return _ok({'ok': true});
    } catch (e) {
      return _serverError('$e');
    }
  }

  /// GET /api/cashier/session-summary?cashier=Nama&since=ISO — rekap kerja
  /// kasir (per metode + total) sejak login, tanpa menutup shift laci kas.
  Future<Response> _cashierSessionSummary(Request req) async {
    final cashier = req.url.queryParameters['cashier'];
    final since = req.url.queryParameters['since'];
    if (cashier == null || cashier.isEmpty || since == null || since.isEmpty) {
      return _badRequest('cashier & since wajib');
    }
    try {
      final summary =
          await _cashierRepo.getCashierSessionSummary(cashier, since);
      return _ok(summary);
    } catch (e) {
      return _serverError('$e');
    }
  }


  // ── Response helpers ──────────────────────────────────────────────────────

  static const _jsonHeader = {
    'content-type': 'application/json; charset=utf-8',
  };

  Response _ok(dynamic data, {int status = 200}) => Response(
        status,
        body: jsonEncode({'success': true, 'data': data}),
        headers: _jsonHeader,
      );

  Response _serverError(String msg) => Response(
        500,
        body: jsonEncode({'success': false, 'error': msg}),
        headers: _jsonHeader,
      );

  Response _badRequest(String msg) => Response(
        400,
        body: jsonEncode({'success': false, 'error': msg}),
        headers: _jsonHeader,
      );

  Response _notFound(String msg) => Response(
        404,
        body: jsonEncode({'success': false, 'error': msg}),
        headers: _jsonHeader,
      );

  Middleware _corsMiddleware() => (Handler inner) => (Request req) async {
        if (req.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final res = await inner(req);
        return res.change(headers: _corsHeaders);
      };

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}
