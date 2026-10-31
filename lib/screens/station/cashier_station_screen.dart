import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/station_controller.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/cash_drawer_service.dart';
import '../../services/printer_service.dart';
import '../../services/receipt_builder.dart';
import '../../services/station_api_client.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/pax_input_dialog.dart';
import '../../widgets/pin_auth_dialog.dart';
import '../../widgets/ui/ui.dart';
import '../cashier/cashier_widgets.dart';

/// Kasir Station: terminal kasir di perangkat NON-utama (klien tipis).
///
/// TAMPILANNYA SENGAJA SAMA PERSIS dengan kasir perangkat utama
/// (`screens/cashier/cashier_screen.dart`) — header hijau bertombol, tab
/// kategori, grid menu, dan panel pesanan di kanan — supaya kasir yang biasa
/// memakai perangkat utama tidak perlu belajar ulang. Komponen tampilannya
/// dipakai bersama lewat `screens/cashier/cashier_widgets.dart`.
///
/// Bedanya hanya sumber data (semua operasi dijalankan di DB Main POS lewat
/// [StationApiClient], struk dicetak lokal) dan fungsi laci uang/administrasi
/// yang memang hanya boleh di perangkat utama: buka/tutup & ganti shift, kas,
/// void transaksi lunas, histori void, cetak ulang, split bill, gabung bayar.
/// Tombolnya tetap ditampilkan pada posisi yang sama tapi non-aktif, jadi tata
/// letaknya identik dan kasir langsung tahu di mana fungsi itu berada.
class CashierStationScreen extends StatefulWidget {
  final Map<String, dynamic> user; // {id, full_name, username, role}
  final VoidCallback onLogout;
  const CashierStationScreen(
      {super.key, required this.user, required this.onLogout});

  @override
  State<CashierStationScreen> createState() => _CashierStationScreenState();
}

class _CashierStationScreenState extends State<CashierStationScreen> {
  final _api = StationApiClient.instance;
  final _c = StationController();

  static const _accent = AppColors.moduleKasir;

  bool _loading = true;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _shift;

  /// Meja terpilih (map dari Main POS) & order aktifnya (order+items+charges).
  Map<String, dynamic>? _table;
  Map<String, dynamic>? _full;

  int _pax = 1;
  String? _customerName;
  bool _showMoreActions = false;

  late final DateTime _loginAt = DateTime.now();

  // Auto-logout saat idle (mencegah station menggantung atas nama kasir).
  static const _idleSeconds = 180;
  Timer? _idleTimer;

  // Ukuran tombol header — mengecil di HP, sama seperti kasir utama.
  double _hbW = kCashierHeaderBtnW;
  double _hbH = kCashierHeaderBtnH;

  String get _cashierName =>
      (widget.user['full_name'] as String?)?.isNotEmpty == true
          ? widget.user['full_name'] as String
          : (widget.user['username'] as String? ?? 'Kasir');

  Map<String, dynamic>? get _order =>
      (_full?['order'] as Map?)?.cast<String, dynamic>();
  String? get _orderId => _order?['id'] as String?;
  List<Map<String, dynamic>> get _orderItems =>
      ((_full?['items'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
  List<Map<String, dynamic>> get _orderCharges =>
      ((_full?['charges'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
  double get _orderTotal => (_order?['total_amount'] as num?)?.toDouble() ?? 0;
  double get _orderSubtotal =>
      (_order?['subtotal'] as num?)?.toDouble() ??
      _orderItems.fold<double>(
          0,
          (a, m) =>
              a +
              ((m['qty'] as num?)?.toInt() ?? 0) *
                  ((m['price'] as num?)?.toDouble() ?? 0));
  double get _paidAmount => (_order?['paid_amount'] as num?)?.toDouble() ?? 0;
  double get _remaining =>
      (_orderTotal - _paidAmount).clamp(0, double.infinity).toDouble();
  String get _tableNumber =>
      (_order?['table_number'] as String?) ??
      (_table?['table_number'] as String?) ??
      '';

  @override
  void initState() {
    super.initState();
    _c.addListener(_onControllerChange);
    _boot();
    _resetIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _c.removeListener(_onControllerChange);
    _c.dispose(); // ikut melepas WebSocket
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    await _c.init(); // meja + kategori + WebSocket
    if (!mounted) return;
    await _c.loadProducts();
    if (!mounted) return;
    // Ambil alih callback socket: selain daftar meja, tagihan yang sedang
    // dibuka & status shift ikut disegarkan saat Main POS berubah.
    _connectSocket();
    await _loadShift();
    if (mounted) setState(() => _loading = false);
  }

  void _connectSocket() {
    _api.connectWebSocket((event, _) {
      if (event == 'order_created' ||
          event == 'order_items_added' ||
          event == 'order_paid' ||
          event == 'order_updated') {
        _c.loadTables();
        _refreshOrder();
      }
    });
  }

  Future<void> _loadShift() async {
    try {
      final s = await _api.getActiveShift();
      if (!mounted) return;
      setState(() {
        _shift = s;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat data dari Main POS');
    }
  }

  Future<void> _reloadAll() async {
    await Future.wait([_c.loadTables(), _loadShift()]);
    await _c.loadProducts();
    await _refreshOrder();
  }

  /// Muat ulang order yang sedang dibuka (bila ada).
  Future<void> _refreshOrder() async {
    final id = _orderId;
    if (id == null) return;
    try {
      final full = await _api.getOrderFull(id);
      if (!mounted) return;
      final order = full['order'];
      // Order lunas / hilang → bersihkan layar seperti kasir utama.
      if (order is! Map || order['payment_status'] == 'paid') {
        setState(() {
          _full = null;
          _table = null;
        });
        return;
      }
      setState(() => _full = full);
    } catch (_) {/* diamkan: tampilan lama tetap dipakai */}
  }

  void _resetIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: _idleSeconds), () {
      if (mounted) _finishWork(auto: true);
    });
  }

  void _snack(String m, {bool isError = false}) {
    if (mounted) showAppSnack(context, m, isError: isError);
  }

  /// Pesan seragam untuk fungsi yang memang hanya ada di perangkat utama.
  void _mainOnly(String label) =>
      _snack('$label hanya tersedia di perangkat utama', isError: true);

  String _msg(Object e) =>
      e.toString().replaceFirst('Exception: ', '').replaceFirst('Exception:', '');

  // ══════════════════════════════════════════════════════════════════════════
  // Meja & order
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _showTableSelector() async {
    final tables = _c.tables;
    final number = await showDialog<String>(
      context: context,
      builder: (_) => CashierTablePickerDialog(
        tables: tables
            .map((t) => CashierPickerTable(
                  number: t['table_number'] as String? ?? '',
                  available: t['active_order'] == null,
                ))
            .toList(),
        selectedNumber: _tableNumber.isEmpty ? null : _tableNumber,
      ),
    );
    if (number == null || !mounted) return;
    final table = tables.firstWhere(
      (t) => t['table_number'] == number,
      orElse: () => <String, dynamic>{'table_number': number},
    );
    final active = table['active_order'];
    if (active is Map && active['id'] != null) {
      await _openOrder(active['id'] as String, table);
      return;
    }
    // Pesanan baru → input pax (wajib) + identitas customer (opsional).
    final res = await showPaxDialog(context);
    if (res == null || !mounted) return;
    setState(() {
      _table = table;
      _full = null;
      _pax = res.pax;
      _customerName = res.customerName;
      _clearCart();
    });
  }

  Future<void> _openOrder(String orderId, Map<String, dynamic> table) async {
    setState(() => _busy = true);
    try {
      final full = await _api.getOrderFull(orderId);
      if (!mounted) return;
      setState(() {
        _full = full['order'] == null ? null : full;
        _table = table;
        _pax = (full['order']?['pax'] as num?)?.toInt() ?? 1;
        _clearCart();
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal memuat tagihan: ${_msg(e)}', isError: true);
    }
  }

  void _clearCart() {
    _c.cart.clear();
    _c.cartNotes.clear();
  }

  List<Map<String, dynamic>> _cartPayload() => _c.cart.entries
      .map((e) => {
            'product_id': e.key,
            'qty': e.value,
            if (_c.cartNotes[e.key] != null) 'notes': _c.cartNotes[e.key],
          })
      .toList();

  /// BUAT ORDER (belum ada order) / TAMBAH (order sudah ada).
  Future<void> _submitCart() async {
    if (_c.cart.isEmpty) return;
    if (_tableNumber.isEmpty) {
      _snack('Pilih meja dulu', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final id = _orderId;
      if (id == null) {
        final created = await _api.createOrder(
          tableNumber: _tableNumber,
          items: _cartPayload(),
          customerName: _customerName,
          pax: _pax,
          waiterName: _cashierName,
        );
        final newId = created['id'] as String?;
        _clearCart();
        await _c.loadTables();
        if (newId != null) {
          final full = await _api.getOrderFull(newId);
          if (!mounted) return;
          setState(() => _full = full);
        }
        if (!mounted) return;
        setState(() => _busy = false);
        _snack('Order meja $_tableNumber dibuat');
      } else {
        await _api.addItems(
          orderId: id,
          items: _cartPayload(),
          waiterName: _cashierName,
        );
        _clearCart();
        await _refreshOrder();
        await _c.loadTables();
        if (!mounted) return;
        setState(() => _busy = false);
        _snack('Item ditambahkan ke meja $_tableNumber');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal menyimpan pesanan: ${_msg(e)}', isError: true);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Pembayaran
  // ══════════════════════════════════════════════════════════════════════════

  void _showPaymentDialog() {
    if (_orderId == null) return;
    final remaining = _remaining;
    final controller = TextEditingController(
      text: CurrencyHelper.formatInput(remaining.round()),
    );
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: CashierPaymentSheet(
          total: remaining,
          controller: controller,
          onPay: (method, amount) async {
            Navigator.pop(ctx);
            await _processPayment(method, amount);
          },
        ),
      ),
    );
  }

  Future<void> _processPayment(String method, double amount) async {
    final id = _orderId;
    if (id == null || amount <= 0) return;
    final full = _full!;
    final hasPartial = _paidAmount > 0;
    final total = _orderTotal;
    setState(() => _busy = true);
    try {
      // Tanpa pembayaran sebagian sebelumnya & nominal cukup → bayar penuh
      // (mendukung kembalian tunai). Selain itu → split-pay (gabung metode).
      if (!hasPartial && amount >= _remaining) {
        final r = await _api.payOrder(
          orderId: id,
          paymentMethod: method,
          paidAmount: amount,
          createdBy: _cashierName,
        );
        await _finishPaid(full, r, method);
        return;
      }
      final r = await _api.splitPayOrder(
        orderId: id,
        amount: amount,
        paymentMethod: method,
        createdBy: _cashierName,
      );
      final remaining = (r['remaining'] as num?)?.toDouble() ?? 0;
      final status = r['payment_status'] as String?;
      if (status == 'paid' || remaining <= 0) {
        await _finishPaid(full, {'paid_amount': total, 'change': 0}, method);
        return;
      }
      await _refreshOrder();
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(
          'Dibayar ${CurrencyHelper.format(amount)} — sisa ${CurrencyHelper.format(remaining)}');
    } catch (e) {
      if (!mounted) return;
      // Pemulihan 'Tagihan sudah lunas': hampir selalu berarti percobaan
      // SEBELUMNYA sebenarnya berhasil tapi responsnya hilang (timeout/
      // jaringan). Verifikasi ke Main POS; bila memang lunas, selesaikan
      // normal (struk tercetak) — jangan buat kasir mengira bayar gagal.
      if (_msg(e).contains('sudah lunas')) {
        try {
          final fresh = await _api.getOrderFull(id);
          final order = fresh['order'];
          if (order is Map && order['payment_status'] == 'paid') {
            await _finishPaid(full, {'paid_amount': total, 'change': 0}, method);
            return;
          }
        } catch (_) {}
        if (!mounted) return;
      }
      setState(() => _busy = false);
      _snack('Gagal bayar: ${_msg(e)}', isError: true);
    }
  }

  Future<void> _finishPaid(Map<String, dynamic> full,
      Map<String, dynamic> result, String method) async {
    await _printReceipt(full, result, method);
    // Laci kasir station dibuka di PERANGKAT INI (laci menempel pada printer
    // struk station), bukan di Main POS yang mencatat pembayarannya.
    unawaited(CashDrawerService.instance.openAfterPayment(paymentMethod: method));
    _clearCart();
    if (!mounted) return;
    setState(() {
      _full = null;
      _table = null;
      _busy = false;
    });
    await _c.loadTables();
    _snack('Pembayaran lunas — struk dicetak');
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Aksi sekunder (paritas panel order kasir utama)
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _showDiscountDialog() async {
    final id = _orderId;
    if (id == null) return;
    final res = await showAppModal<_DiscountInput>(
      context,
      title: 'Diskon',
      icon: Icons.percent_rounded,
      accent: _accent,
      scrollable: false,
      maxWidth: 440,
      builder: (_) => const _DiscountForm(),
    );
    if (res == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.applyDiscount(
        orderId: id,
        chargeType: res.type,
        value: res.value,
        note: res.note,
      );
      await _refreshOrder();
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Diskon diterapkan');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal diskon: ${_msg(e)}', isError: true);
    }
  }

  /// Kompliment: gratiskan seluruh tagihan — WAJIB PIN Manager/SVP/Admin
  /// (sama dengan kasir utama). Nama pemberi = pemilik PIN, bukan teks bebas,
  /// agar jejak kompliment akuntabel.
  Future<void> _showComplimentDialog() async {
    final id = _orderId;
    if (id == null) return;
    final auth = await showPinAuthDialog(
      context,
      title: 'Kompliment',
      actionLabel: 'Kompliment — Gratiskan',
      actionColor: _accent,
      icon: Icons.card_giftcard_rounded,
      details: {
        'Meja': _tableNumber,
        'Total': CurrencyHelper.format(_orderTotal),
      },
      reasonHint: 'Contoh: tamu owner, kompensasi',
    );
    if (auth == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final user = await _api.authPin(auth.pin);
      final role = (user?['role'] as String?) ?? '';
      if (user == null || !AuthService.voidAuthorizedRoles.contains(role)) {
        if (!mounted) return;
        setState(() => _busy = false);
        _snack(
            user == null
                ? 'PIN salah'
                : 'Tidak berwenang (butuh Manager/SVP/Admin)',
            isError: true);
        return;
      }
      final by = (user['full_name'] as String?)?.isNotEmpty == true
          ? user['full_name'] as String
          : (user['username'] as String? ?? 'Manager');
      await _api.complimentOrder(
        orderId: id,
        complimentBy: by,
        reason: auth.reason,
        createdBy: _cashierName,
      );
      _clearCart();
      if (!mounted) return;
      setState(() {
        _full = null;
        _table = null;
        _busy = false;
      });
      await _c.loadTables();
      _snack('Order dikompliment (oleh $by)');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal kompliment: ${_msg(e)}', isError: true);
    }
  }

  /// Tarik item dari Meja Titipan ke order ini.
  Future<void> _showHeldItemsPicker() async {
    final id = _orderId;
    if (id == null) return;
    List<Map<String, dynamic>> held;
    try {
      held = await _api.getHeldItems();
    } catch (e) {
      _snack('Gagal memuat titipan: ${_msg(e)}', isError: true);
      return;
    }
    if (!mounted) return;
    if (held.isEmpty) {
      _snack('Tidak ada item di Meja Titipan', isError: true);
      return;
    }
    final picked = await showAppModal<Map<String, dynamic>>(
      context,
      title: 'Tarik dari Titipan',
      icon: Icons.inventory_2_outlined,
      accent: _accent,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: held
            .map((i) => ListTile(
                  leading: const Icon(Icons.lunch_dining_rounded),
                  title: Text('${i['qty']}x ${i['product_name']}'),
                  subtitle: Text(CurrencyHelper.format(
                      (i['price'] as num?)?.toDouble() ?? 0)),
                  onTap: () => Navigator.pop(ctx, i),
                ))
            .toList(),
      ),
    );
    if (picked == null || !mounted) return;
    final maxQty = (picked['qty'] as num?)?.toInt() ?? 1;
    final qty = maxQty <= 1 ? 1 : await _askQty(maxQty);
    if (qty == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.pullHeldItem(
        picked['id'] as String,
        qty: qty,
        targetOrderId: id,
        by: _cashierName,
      );
      await _refreshOrder();
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Item titipan ditarik ke tagihan ini');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal tarik titipan: ${_msg(e)}', isError: true);
    }
  }

  /// Pilih jumlah unit (1..max) — untuk tarik titipan / void sebagian.
  Future<int?> _askQty(int max, {String title = 'Berapa unit?'}) {
    return showAppModal<int>(
      context,
      title: title,
      icon: Icons.onetwothree_rounded,
      accent: _accent,
      builder: (ctx) => Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (var n = 1; n <= max; n++)
            ActionChip(
              label: Text('$n'),
              onPressed: () => Navigator.pop(ctx, n),
            ),
        ],
      ),
    );
  }

  Future<void> _showMovePicker() async {
    final id = _orderId;
    if (id == null) return;
    final empty = _c.tables.where((t) => t['active_order'] == null).toList();
    if (empty.isEmpty) {
      _snack('Tidak ada meja kosong', isError: true);
      return;
    }
    final target = await showAppModal<String>(
      context,
      title: 'Pindah ke Meja',
      icon: Icons.swap_horiz_rounded,
      accent: _accent,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: empty
            .map((t) => ListTile(
                  leading: const Icon(Icons.table_restaurant_rounded),
                  title: Text('Meja ${t['table_number']}'),
                  onTap: () => Navigator.pop(ctx, t['table_number'] as String),
                ))
            .toList(),
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.moveOrderTable(orderId: id, tableNumber: target);
      await _c.loadTables();
      await _refreshOrder();
      if (!mounted) return;
      setState(() {
        _table = _c.tables.firstWhere(
          (t) => t['table_number'] == target,
          orElse: () => <String, dynamic>{'table_number': target},
        );
        _busy = false;
      });
      _snack('Order dipindah ke meja $target');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal pindah meja: ${_msg(e)}', isError: true);
    }
  }

  Future<void> _showMergePicker() async {
    final id = _orderId;
    if (id == null) return;
    List<Map<String, dynamic>> orders;
    try {
      orders = await _api.getMergeableOrders(id);
    } catch (e) {
      _snack('Gagal memuat meja: ${_msg(e)}', isError: true);
      return;
    }
    if (!mounted) return;
    if (orders.isEmpty) {
      _snack('Tidak ada meja lain untuk digabung', isError: true);
      return;
    }
    final source = await showAppModal<String>(
      context,
      title: 'Gabung ke Meja $_tableNumber',
      icon: Icons.call_merge_rounded,
      accent: _accent,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: orders
            .map((o) => ListTile(
                  leading: const Icon(Icons.table_restaurant_rounded),
                  title: Text('Meja ${o['table_number']}'),
                  subtitle: Text(CurrencyHelper.format(
                      (o['total_amount'] as num?)?.toDouble() ?? 0)),
                  onTap: () => Navigator.pop(ctx, o['id'] as String),
                ))
            .toList(),
      ),
    );
    if (source == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.mergeOrders(targetOrderId: id, sourceOrderId: source);
      await _c.loadTables();
      await _refreshOrder();
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Meja digabung ke tagihan ini');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal gabung meja: ${_msg(e)}', isError: true);
    }
  }

  /// Hapus (void) satu item terkirim — wajib PIN Manager/SVP/Admin.
  Future<void> _showItemVoidDialog(Map<String, dynamic> item) async {
    final maxQty = (item['qty'] as num?)?.toInt() ?? 1;
    final n = maxQty <= 1 ? 1 : await _askQty(maxQty, title: 'Void berapa unit?');
    if (n == null || !mounted) return;
    final price = (item['price'] as num?)?.toDouble() ?? 0;
    final auth = await showPinAuthDialog(
      context,
      title: 'Hapus Item',
      actionLabel: 'Hapus Item',
      icon: Icons.delete_outline,
      details: {
        'Item': '${n}x ${item['product_name']}',
        'Harga': CurrencyHelper.format(price * n),
      },
      reasonHint: 'Contoh: salah input, pelanggan batal',
    );
    if (auth == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final user = await _api.authPin(auth.pin);
      final role = (user?['role'] as String?) ?? '';
      if (user == null || !AuthService.voidAuthorizedRoles.contains(role)) {
        if (!mounted) return;
        setState(() => _busy = false);
        _snack('PIN salah / tidak berwenang', isError: true);
        return;
      }
      final by = (user['full_name'] as String?)?.isNotEmpty == true
          ? user['full_name'] as String
          : (user['username'] as String? ?? 'Manager');
      await _api.voidItem(item['id'] as String,
          qty: n, voidedBy: by, reason: auth.reason);
      await _refreshOrder();
      await _c.loadTables();
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Item dihapus');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal hapus item: ${_msg(e)}', isError: true);
    }
  }

  Future<void> _showNoteDialog(String productId, String? current) async {
    final ctrl = TextEditingController(text: current ?? '');
    final res = await showAppModal<String>(
      context,
      title: 'Catatan Item',
      icon: Icons.note_add_rounded,
      accent: _accent,
      scrollable: false,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Catatan (mis. tanpa sambal)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Simpan',
            accent: _accent,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
      ),
    );
    if (res == null || !mounted) return;
    _c.setNote(productId, res);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Cetak
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _printReceipt(Map<String, dynamic> full,
      Map<String, dynamic> result, String method) async {
    try {
      final order =
          Order.fromMap((full['order'] as Map).cast<String, dynamic>());
      final items = (full['items'] as List)
          .map((m) => OrderItem.fromMap((m as Map).cast<String, dynamic>()))
          .toList();
      final charges = (full['charges'] as List)
          .map((m) =>
              OrderAdditionalCharge.fromMap((m as Map).cast<String, dynamic>()))
          .toList();
      final data = ReceiptData.fromPaymentResult(
        result: {...result, 'payment_method': method},
        order: order,
        orderItems: items,
        charges: charges,
        cashierName: _cashierName,
      );
      await _sendToCashierPrinter(
          (cols, isCopy) =>
              ReceiptBuilder(paperWidth: cols).buildReceipt(data, isCopy: isCopy),
          honorCopies: true);
    } catch (e) {
      debugPrint('Cetak struk station error: $e');
    }
  }

  /// Cetak TAGIHAN (belum bayar) ke printer lokal station.
  Future<void> _printBill() async {
    final full = _full;
    if (full == null) return;
    try {
      final order =
          Order.fromMap((full['order'] as Map).cast<String, dynamic>());
      final items = (full['items'] as List)
          .map((m) => OrderItem.fromMap((m as Map).cast<String, dynamic>()))
          .toList();
      final charges = (full['charges'] as List)
          .map((m) =>
              OrderAdditionalCharge.fromMap((m as Map).cast<String, dynamic>()))
          .toList();
      final subtotal = items.fold<double>(0, (s, i) => s + i.subtotal);
      final data = ReceiptData(
        orderId: order.id,
        receiptNumber: 'BILL-${order.id.substring(0, 8).toUpperCase()}',
        tableNumber: order.tableNumber,
        customerName: order.customerName,
        cashierName: _cashierName,
        pax: order.pax,
        items: items
            .map((i) => ReceiptItem(
                  name: i.productName,
                  quantity: i.qty,
                  price: i.price,
                  total: i.subtotal,
                  notes: i.notes.isNotEmpty ? i.notes : null,
                  ordererName: i.waiterName,
                ))
            .toList(),
        subtotal: subtotal,
        charges: charges
            .map((c) => ReceiptCharge(name: c.name, amount: c.appliedAmount))
            .toList(),
        chargesTotal: charges.fold<double>(0, (s, c) => s + c.appliedAmount),
        total: order.totalAmount,
        dateTime: DateTime.now(),
        isBill: true,
      );
      await _sendToCashierPrinter((cols, isCopy) =>
          ReceiptBuilder(paperWidth: cols).buildReceipt(data, isCopy: isCopy));
      _snack('Tagihan dicetak');
    } catch (e) {
      _snack('Gagal cetak tagihan: ${_msg(e)}', isError: true);
    }
  }

  /// Kirim bytes ke printer ber-role kasir (fallback non-checker, lalu pertama).
  Future<void> _sendToCashierPrinter(
      List<int> Function(int cols, bool isCopy) build,
      {bool honorCopies = false}) async {
    final ps = PrinterService();
    final saved = await ps.getSavedPrinters();
    if (saved.isEmpty) return;
    final cps = saved.where((p) => p.hasRole(PrinterRole.cashier)).toList();
    final printer = cps.isNotEmpty
        ? cps.first
        : saved.firstWhere((p) => !p.hasRole(PrinterRole.checker),
            orElse: () => saved.first);

    Future<void> send(List<int> bytes) async {
      if (printer.type == PrinterType.bluetooth) {
        await ps.sendBluetooth(printer.address, bytes);
      } else {
        await ps.sendLan(printer.address, bytes);
      }
    }

    await send(build(printer.paperCols, false));
    if (honorCopies) {
      for (var c = 2; c <= printer.copies; c++) {
        await send(build(printer.paperCols, true));
      }
    }
  }

  // ── Ganti shift (serah terima laci ke kasir berikutnya) ───────────────────

  /// Ganti shift dari station: kasir berikutnya memasukkan PIN-nya, saldo laci
  /// diserahkan, lalu Main POS menutup shift berjalan dan membuka shift baru
  /// atas nama kasir tersebut. Ringkasan kerja kasir lama dicetak, lalu station
  /// kembali ke layar login supaya kasir baru masuk dengan PIN-nya sendiri.
  Future<void> _showSwapShiftDialog() async {
    final shift = _shift;
    final shiftId = shift?['id'] as String?;
    if (shiftId == null) {
      _snack('Shift belum dibuka di perangkat utama', isError: true);
      return;
    }
    final pinCtrl = TextEditingController();
    final cashCtrl = TextEditingController();
    final noteCtrl = TextEditingController();

    final ok = await showAppModal<bool>(
      context,
      title: 'Ganti Shift',
      subtitle: 'Serah terima laci ke kasir berikutnya',
      icon: Icons.people_alt_outlined,
      accent: _accent,
      maxWidth: 460,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Shift dibuka oleh ${shift?['opened_by'] ?? '-'}. Setelah diganti, '
            'shift baru dibuka atas nama kasir yang PIN-nya dimasukkan di '
            'bawah dan station kembali ke layar login.',
            style: AppType.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: pinCtrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'PIN kasir berikutnya',
              prefixIcon: Icon(Icons.lock_outline, size: 20),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: cashCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [RupiahInputFormatter()],
            decoration: const InputDecoration(
              labelText: 'Uang tunai di laci (opsional)',
              helperText: 'Kosongkan untuk memakai hitungan sistem',
              prefixText: 'Rp ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: noteCtrl,
            decoration: const InputDecoration(
              labelText: 'Catatan (opsional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton.neutral('Batal',
                    onPressed: () => Navigator.pop(ctx, false)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Ganti Shift',
                  icon: Icons.people_alt_outlined,
                  accent: _accent,
                  onPressed: () {
                    if (pinCtrl.text.trim().isEmpty) return;
                    Navigator.pop(ctx, true);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // PIN kasir berikutnya diverifikasi ke Main POS; hanya peran yang boleh
      // memegang kasir yang bisa menerima serah terima.
      final user = await _api.authPin(pinCtrl.text.trim());
      final role = (user?['role'] as String?)?.toLowerCase() ?? '';
      const cashierRoles = {'cashier', 'admin', 'manager', 'svp'};
      if (user == null || !cashierRoles.contains(role)) {
        if (!mounted) return;
        setState(() => _busy = false);
        _snack(
            user == null
                ? 'PIN salah'
                : 'Peran $role tidak bisa memegang kasir',
            isError: true);
        return;
      }
      final nextName = (user['full_name'] as String?)?.isNotEmpty == true
          ? user['full_name'] as String
          : (user['username'] as String? ?? 'Kasir');
      final cash = cashCtrl.text.trim().isEmpty
          ? null
          : CurrencyHelper.parseInput(cashCtrl.text);

      await _api.swapShift(
        shiftId: shiftId,
        handoverTo: nextName,
        countedCash: cash,
        notes: noteCtrl.text.trim(),
      );

      // Cetak ringkasan kerja kasir yang menyerahkan, lalu keluar ke login.
      try {
        final summary = await _api.getCashierSessionSummary(
            _cashierName, _loginAt.toIso8601String());
        await _printSession(summary);
      } catch (e) {
        debugPrint('Ringkasan sesi (ganti shift) error: $e');
      }
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Shift diserahkan ke $nextName');
      widget.onLogout();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Gagal ganti shift: ${_msg(e)}', isError: true);
    }
  }

  // ── Selesai kerja (logout + ringkasan sesi kasir) ──────────────────────────
  Future<void> _finishWork({bool auto = false}) async {
    _idleTimer?.cancel();
    if (!auto) {
      final ok = await showAppConfirm(
        context,
        title: 'Selesai Kerja?',
        message:
            'Cetak ringkasan kerja Anda lalu keluar ke layar login. Shift laci kas tidak ditutup (di perangkat utama).',
        confirmText: 'Selesai',
        icon: Icons.logout_rounded,
      );
      if (!ok) {
        _resetIdle();
        return;
      }
    }
    try {
      final summary = await _api.getCashierSessionSummary(
          _cashierName, _loginAt.toIso8601String());
      await _printSession(summary);
    } catch (e) {
      debugPrint('Ringkasan sesi error: $e');
    }
    widget.onLogout();
  }

  Future<void> _printSession(Map<String, dynamic> summary) async {
    try {
      await _sendToCashierPrinter((cols, _) =>
          ReceiptBuilder(paperWidth: cols).buildCashierSession(
            outletName: 'POS Resto',
            cashierName: _cashierName,
            loginAt: _loginAt,
            endAt: DateTime.now(),
            summary: summary,
          ));
    } catch (e) {
      debugPrint('Cetak ringkasan sesi error: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Tampilan — tata letak identik dengan kasir perangkat utama
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppColors.canvas,
        body: AppLoader(label: 'Memuat kasir...'),
      );
    }
    // Gate: shift laci kas hanya dibuka di perangkat utama.
    if (_shift == null) return _buildShiftGate();

    return Listener(
      onPointerDown: (_) => _resetIdle(),
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        body: Column(
          children: [
            _buildHeader(),
            if (_error != null) _errorBanner(_error!),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isPhone = constraints.maxWidth < 600;
                  if (isPhone) return _buildPhoneLayout();
                  final cartWidth =
                      (constraints.maxWidth * 0.30).clamp(300.0, 440.0);
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            _buildCategoryTabs(),
                            Expanded(child: _buildProductGrid()),
                          ],
                        ),
                      ),
                      _buildCartPanel(width: cartWidth),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      width: double.infinity,
      color: AppColors.dangerSoft,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 18, color: AppColors.danger),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(message,
                style: AppType.bodySm.copyWith(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  // ── Header (susunan tombol sama persis dengan kasir utama) ────────────────

  Widget _buildHeader() {
    final phone = context.isPhone;
    _hbW = phone ? 62.0 : kCashierHeaderBtnW;
    _hbH = phone ? 54.0 : kCashierHeaderBtnH;
    final backSize = phone ? 46.0 : 60.0;
    final edgeGap = phone ? 6.0 : 10.0;
    final headerH = phone ? 66.0 : 76.0;
    final padX = phone ? 10.0 : 16.0;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.gradientOf(_accent),
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        boxShadow: AppShadows.glow(_accent, strength: 0.28),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: headerH,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: padX),
            child: Row(
              children: [
                // Di perangkat utama tombol ini kembali ke dashboard; di
                // station tidak ada dashboard, jadi ia mengakhiri sesi kasir.
                Material(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _finishWork(),
                    child: Container(
                      width: backSize,
                      height: backSize,
                      alignment: Alignment.center,
                      child: const Icon(Icons.arrow_back,
                          color: Colors.white, size: 24),
                    ),
                  ),
                ),
                SizedBox(width: edgeGap),

                // SATU bingkai berisi semua tombol aksi — susunannya sama
                // persis dengan kasir perangkat utama.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      // Sama seperti kasir utama: bingkai memenuhi lebar bila
                      // muat, dan baru bisa digulir saat layar sempit.
                      const count = 4; // meja, shift, laci, muat ulang
                      const dividers = count - 1;
                      final natural = _hbW * count + dividers;
                      final fits = c.maxWidth >= natural;
                      final w = fits ? (c.maxWidth - dividers) / count : _hbW;
                      final frame = cashierHeaderGroup(_headerActions(w));
                      if (fits) return frame;
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: frame,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Isi bingkai header. Station hanya menampilkan tombol yang BENAR-BENAR
  /// berfungsi di sini — fungsi khusus perangkat utama (sinkron cloud, kas,
  /// riwayat kas, void transaksi, histori void, cetak ulang, tutup kasir)
  /// tidak ditampilkan sama sekali supaya tidak membingungkan kasir.
  /// Buka laci kasir station MANUAL (paritas dengan kasir utama).
  Future<void> _openCashDrawer() async {
    try {
      await CashDrawerService.instance.open();
      _snack('Laci kasir dibuka');
    } catch (e) {
      _snack('Gagal buka laci: ${_msg(e)}', isError: true);
    }
  }

  List<Widget> _headerActions(double w) => [
        _headerBtn(
          icon: Icons.table_restaurant_outlined,
          label: _tableNumber.isNotEmpty ? 'Meja $_tableNumber' : 'Pilih Meja',
          onTap: _showTableSelector,
          width: w,
        ),
        cashierGroupDivider(),
        _headerBtn(
          icon: Icons.people_alt_outlined,
          label: 'Ganti Shift',
          onTap: _showSwapShiftDialog,
          width: w,
        ),
        cashierGroupDivider(),
        _headerBtn(
          icon: Icons.point_of_sale_outlined,
          label: 'Buka Laci',
          onTap: _openCashDrawer,
          width: w,
        ),
        cashierGroupDivider(),
        CashierHeaderButton(
          icon: Icons.refresh,
          label: 'Muat Ulang',
          onTap: _reloadAll,
          background: Colors.white,
          iconColor: _accent,
          width: w,
          height: _hbH,
        ),
      ];

  Widget _headerBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    bool enabled = true,
    double? width,
  }) =>
      CashierHeaderButton(
        icon: icon,
        label: label,
        onTap: onTap,
        iconColor: iconColor,
        width: width ?? _hbW,
        height: _hbH,
        enabled: enabled,
      );

  // ── Menu ──────────────────────────────────────────────────────────────────

  Widget _buildCategoryTabs() {
    return Container(
      height: 54,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          CashierCategoryChip(
              label: 'Semua',
              selected: _c.selectedCategory == null,
              onTap: () => _c.selectCategory(null)),
          ..._c.categories.map((cat) => CashierCategoryChip(
                label: cat.name,
                selected: _c.selectedCategory?.id == cat.id,
                onTap: () => _c.selectCategory(cat),
              )),
        ],
      ),
    );
  }

  Widget _buildProductGrid() {
    if (_c.isLoading && _c.products.isEmpty) {
      return const AppLoader(label: 'Memuat menu...');
    }
    if (_c.products.isEmpty) {
      return const EmptyState(
        icon: Icons.restaurant_menu_rounded,
        title: 'Tidak ada produk',
        message: 'Belum ada produk pada kategori ini.',
        accent: _accent,
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final maxExtent = context.isPhone
            ? (w / 2)
            : w >= 1100
                ? 200.0
                : w >= 850
                    ? 185.0
                    : w >= 600
                        ? 170.0
                        : 150.0;
        final pad = w >= 850 ? 18.0 : 12.0;
        final gap = w >= 850 ? 14.0 : 10.0;
        return GridView.builder(
          padding: EdgeInsets.all(pad),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: 0.85,
          ),
          itemCount: _c.products.length,
          itemBuilder: (context, index) {
            final product = _c.products[index];
            return CashierProductTile(
              product: product,
              inCart: _c.cart[product.id] ?? 0,
              onTap: () => _c.addToCart(product),
            );
          },
        );
      },
    );
  }

  // ── Panel pesanan ─────────────────────────────────────────────────────────

  Widget _buildCartPanel({double width = 320}) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
        boxShadow: [
          BoxShadow(
            color: Color(0x0F1B1F3B),
            blurRadius: 18,
            offset: Offset(-6, 0),
            spreadRadius: -4,
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
            ),
            child: Row(
              children: [
                const Icon(Icons.receipt_long_outlined,
                    color: _accent, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Pesanan',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                if (_c.cartItemCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.soft(_accent, 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_c.cartItemCount} item',
                      style: const TextStyle(
                        color: _accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _buildPaxRow(),
          Expanded(child: _buildCartItems()),
          _buildCartBottom(),
        ],
      ),
    );
  }

  /// Baris jumlah tamu (pax). Editable saat membuat order baru; saat order
  /// sudah ada, tampilkan pax order tersebut (read-only).
  Widget _buildPaxRow() {
    final hasOrder = _order != null;
    final value = hasOrder ? ((_order!['pax'] as num?)?.toInt() ?? 1) : _pax;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: Row(
        children: [
          const Icon(Icons.people_outline,
              size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          const Text('Jumlah Tamu',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const Spacer(),
          if (hasOrder)
            Text('$value pax',
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.bold))
          else
            Row(
              children: [
                _paxBtn(Icons.remove,
                    () => setState(() => _pax = _pax > 1 ? _pax - 1 : 1)),
                Container(
                  width: 40,
                  alignment: Alignment.center,
                  child: Text('$value',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                _paxBtn(Icons.add, () => setState(() => _pax++)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _paxBtn(IconData icon, VoidCallback onTap) {
    return Material(
      color: AppColors.surfaceMuted,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 18, color: _accent),
        ),
      ),
    );
  }

  Widget _buildCartItems() {
    if (_c.cart.isEmpty && _orderItems.isEmpty) {
      return const EmptyState(
        icon: Icons.shopping_cart_outlined,
        title: 'Belum ada item',
        message: 'Pilih menu untuk mulai pesanan',
        accent: _accent,
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      children: _buildCartItemWidgets(),
    );
  }

  List<Widget> _buildCartItemWidgets() {
    return [
      ..._c.cart.entries.map((entry) {
        final product = _c.productCache[entry.key];
        if (product == null) return const SizedBox.shrink();
        return CashierCartItemTile(
          name: product.name,
          qty: entry.value,
          price: product.price,
          notes: _c.cartNotes[entry.key],
          onAdd: () => _c.addToCart(product),
          onRemove: () => _c.removeFromCart(product.id),
          onEditNote: () => _showNoteDialog(entry.key, _c.cartNotes[entry.key]),
        );
      }),
      if (_orderItems.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('Dipesan',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary,
                  fontSize: 12)),
        ),
        ..._orderItems.map((item) {
          final notes = item['notes'] as String?;
          return CashierCartItemTile(
            name: item['product_name'] as String? ?? '',
            qty: (item['qty'] as num?)?.toInt() ?? 0,
            price: (item['price'] as num?)?.toDouble() ?? 0,
            status: item['item_status'] as String?,
            notes: (notes == null || notes.isEmpty) ? null : notes,
            onDelete: () => _showItemVoidDialog(item),
          );
        }),
      ],
    ];
  }

  Widget _buildCartBottom() {
    final hasOrder = _order != null;
    final displayTotal = hasOrder ? _orderTotal : _c.cartTotal;
    final charges = hasOrder ? _orderCharges : const <Map<String, dynamic>>[];

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasOrder && charges.isNotEmpty) ...[
              _billRow('Subtotal', _orderSubtotal),
              const SizedBox(height: 4),
              ...charges.map((c) {
                final applied =
                    (c['applied_amount'] as num?)?.toDouble() ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _billRow(
                    c['name'] as String? ?? '',
                    applied,
                    signed: true,
                    color: applied < 0 ? AppColors.danger : null,
                  ),
                );
              }),
              const Divider(height: 14, color: AppColors.border),
            ],
            if (hasOrder && _paidAmount > 0) ...[
              _billRow('Sudah dibayar', _paidAmount),
              const SizedBox(height: 4),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total', style: AppType.title),
                Text(
                  CurrencyHelper.format(displayTotal),
                  style: AppType.amount.copyWith(color: _accent),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (hasOrder && _c.cart.isNotEmpty) ...[
              CashierActionButton(
                  label: 'TAMBAH', isLoading: _busy, onTap: _submitCart),
              const SizedBox(height: 8),
              CashierActionButton(
                  label: 'BAYAR', isLoading: _busy, onTap: _showPaymentDialog),
              const SizedBox(height: 8),
              _buildCollapsibleActions(_busy),
            ] else if (hasOrder) ...[
              CashierActionButton(
                  label: 'BAYAR', isLoading: _busy, onTap: _showPaymentDialog),
              const SizedBox(height: 8),
              _buildCollapsibleActions(_busy),
            ] else if (_c.cart.isNotEmpty)
              CashierActionButton(
                  label: 'BUAT ORDER', isLoading: _busy, onTap: _submitCart),
          ],
        ),
      ),
    );
  }

  Widget _billRow(String label, double amount,
      {bool signed = false, Color? color}) {
    final prefix =
        signed && amount < 0 ? '- ' : (signed && amount > 0 ? '+ ' : '');
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
        ),
        const SizedBox(width: 8),
        Text('$prefix${CurrencyHelper.format(amount.abs())}',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color ?? AppColors.textSecondary)),
      ],
    );
  }

  Widget _buildCollapsibleActions(bool isLoading) {
    return Column(
      children: [
        Material(
          color: AppColors.soft(AppColors.accent, 0.10),
          borderRadius: AppRadius.rMd,
          child: InkWell(
            borderRadius: AppRadius.rMd,
            onTap: () => setState(() => _showMoreActions = !_showMoreActions),
            child: Container(
              height: 44,
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                      _showMoreActions
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: AppColors.accentDark),
                  const SizedBox(width: 6),
                  Text(_showMoreActions ? 'Sembunyikan aksi' : 'Aksi Lainnya',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accentDark)),
                ],
              ),
            ),
          ),
        ),
        if (_showMoreActions) ...[
          const SizedBox(height: 8),
          _buildSecondaryActions(isLoading),
        ],
      ],
    );
  }

  /// Aksi sekunder — urutan & posisi sama dengan kasir utama. Split Bill dan
  /// Gabung Bayar dihitung di perangkat utama, jadi di station tampil non-aktif
  /// (bayar bertahap tetap bisa lewat tombol BAYAR: isi nominal sebagian).
  Widget _buildSecondaryActions(bool isLoading) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: CashierSecondaryButton(
                icon: Icons.local_offer_outlined,
                label: 'Diskon',
                onTap: isLoading ? null : _showDiscountDialog,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CashierSecondaryButton(
                icon: Icons.card_giftcard,
                label: 'Kompliment',
                onTap: isLoading ? null : _showComplimentDialog,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: CashierSecondaryButton(
                icon: Icons.call_split,
                label: 'Split Bill',
                onTap: isLoading ? null : () => _mainOnly('Split bill'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CashierSecondaryButton(
                icon: Icons.payments_outlined,
                label: 'Gabung Bayar',
                onTap: isLoading ? null : () => _mainOnly('Gabung bayar'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: CashierSecondaryButton(
                icon: Icons.swap_horiz,
                label: 'Pindah Meja',
                onTap: isLoading ? null : _showMovePicker,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CashierSecondaryButton(
                icon: Icons.merge_type,
                label: 'Gabung Meja',
                onTap: isLoading ? null : _showMergePicker,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: CashierSecondaryButton(
            icon: Icons.inventory_2_outlined,
            label: 'Tarik dari Titipan',
            onTap: isLoading ? null : _showHeldItemsPicker,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: CashierSecondaryButton(
            icon: Icons.receipt_long_outlined,
            label: 'Cetak Tagihan',
            onTap: isLoading ? null : _printBill,
          ),
        ),
      ],
    );
  }

  // ── Layout ponsel (sama seperti kasir utama) ──────────────────────────────

  Widget _buildPhoneLayout() {
    return Column(
      children: [
        _buildCategoryTabs(),
        Expanded(child: _buildProductGrid()),
        _buildPhoneCartBar(),
      ],
    );
  }

  Widget _buildPhoneCartBar() {
    final hasItems = _c.cart.isNotEmpty || _orderItems.isNotEmpty;
    if (!hasItems) return const SizedBox.shrink();
    final hasOrder = _order != null;
    final displayTotal = hasOrder ? _orderTotal : _c.cartTotal;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: const Border(top: BorderSide(color: AppColors.border)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _showPhoneCartSheet,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${_c.cartItemCount} item',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textTertiary)),
                      Text(
                        CurrencyHelper.format(displayTotal),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: _accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (hasOrder && _c.cart.isNotEmpty) ...[
              _buildBarButton('TAMBAH', _busy, _submitCart),
              const SizedBox(width: 8),
              _buildBarButton('BAYAR', _busy, _showPaymentDialog),
            ] else if (hasOrder)
              _buildBarButton('BAYAR', _busy, _showPaymentDialog)
            else if (_c.cart.isNotEmpty)
              _buildBarButton('BUAT ORDER', _busy, _submitCart),
          ],
        ),
      ),
    );
  }

  Widget _buildBarButton(String label, bool isLoading, VoidCallback onTap) {
    return SizedBox(
      width: 120,
      child: AppButton(
        label: label,
        loading: isLoading,
        onPressed: onTap,
        accent: _accent,
        size: AppButtonSize.medium,
      ),
    );
  }

  void _showPhoneCartSheet() {
    showAppModal(
      context,
      title: 'Pesanan',
      icon: Icons.receipt_long_rounded,
      accent: _accent,
      builder: (_) => StatefulBuilder(
        builder: (_, __) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildCartItemWidgets(),
        ),
      ),
    );
  }

  // ── Gate: shift belum dibuka di perangkat utama ───────────────────────────

  Widget _buildShiftGate() {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: AppBackground(
        child: Column(
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: AppColors.gradientOf(_accent),
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                boxShadow: AppShadows.glow(_accent, strength: 0.28),
              ),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 66,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Row(
                      children: [
                        AppIconButton(
                          icon: Icons.arrow_back_ios_new_rounded,
                          onPressed: () => _finishWork(),
                          color: Colors.white,
                          filled: true,
                          size: 44,
                          tooltip: 'Selesai',
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppColors.soft(Colors.white, 0.2),
                            borderRadius: AppRadius.rSm,
                          ),
                          child: const Icon(Icons.point_of_sale_outlined,
                              color: Colors.white, size: 24),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('Kasir Station',
                                  style:
                                      AppType.h3.copyWith(color: Colors.white)),
                              Text('Menunggu shift dibuka',
                                  style: AppType.caption.copyWith(
                                      color: AppColors.soft(Colors.white, 0.85))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AppCard(
                      padding: const EdgeInsets.all(AppSpacing.xxl),
                      radius: AppRadius.rXxl,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: AppColors.gradientOf(_accent),
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: AppRadius.rXl,
                              boxShadow: AppShadows.glow(_accent),
                            ),
                            child: const Icon(Icons.lock_clock_rounded,
                                color: Colors.white, size: 40),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          Text('Shift Belum Dibuka', style: AppType.h1),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Laci kas dibuka di perangkat utama. Setelah kasir '
                            'utama membuka shift, tekan Muat Ulang.',
                            textAlign: TextAlign.center,
                            style: AppType.body
                                .copyWith(color: AppColors.textTertiary),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          AppButton(
                            label: 'Muat Ulang',
                            icon: Icons.refresh_rounded,
                            accent: _accent,
                            onPressed: _reloadAll,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          AppButton.neutral(
                            'Selesai',
                            icon: Icons.logout_rounded,
                            onPressed: () => _finishWork(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiscountInput {
  final String type; // percentage | fixed
  final double value;
  final String note;
  const _DiscountInput(this.type, this.value, this.note);
}

/// Form diskon (di dalam modal terpusat). Pop dengan [_DiscountInput] saat
/// diterapkan, atau null saat batal.
class _DiscountForm extends StatefulWidget {
  const _DiscountForm();
  @override
  State<_DiscountForm> createState() => _DiscountFormState();
}

class _DiscountFormState extends State<_DiscountForm> {
  String _type = 'percentage';
  final _valueCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  @override
  void dispose() {
    _valueCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPercent = _type == 'percentage';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'percentage', label: Text('Persen %')),
            ButtonSegment(value: 'fixed', label: Text('Nominal Rp')),
          ],
          selected: {_type},
          onSelectionChanged: (s) => setState(() => _type = s.first),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _valueCtrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: isPercent ? 'Persentase' : 'Nominal',
            prefixText: isPercent ? '' : 'Rp ',
            suffixText: isPercent ? '%' : '',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _noteCtrl,
          decoration: const InputDecoration(
            labelText: 'Catatan (mis. member)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: AppButton.neutral(
                'Batal',
                onPressed: () => Navigator.pop(context),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: AppButton(
                label: 'Terapkan',
                accent: AppColors.moduleKasir,
                onPressed: () {
                  final v =
                      double.tryParse(_valueCtrl.text.replaceAll('.', '')) ?? 0;
                  if (v <= 0) return;
                  Navigator.pop(
                      context, _DiscountInput(_type, v, _noteCtrl.text.trim()));
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
