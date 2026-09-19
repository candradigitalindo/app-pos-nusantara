import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/printer_service.dart';
import '../../services/receipt_builder.dart';
import '../../services/station_api_client.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/ui/ui.dart';

/// Kasir Station: terminal kasir di perangkat NON-utama (klien tipis). Operasi
/// transaksi (bayar, diskon) dijalankan di DB Main POS lewat StationApiClient;
/// struk dicetak lokal. Buka/tutup shift (laci kas) HANYA di perangkat utama —
/// station hanya menampilkan status shift & memproses bayar di bawahnya.
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

  static const _accent = AppColors.moduleKasir;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _tables = [];
  Map<String, dynamic>? _shift;
  late final DateTime _loginAt = DateTime.now();

  // Auto-logout saat idle (mencegah station menggantung atas nama kasir).
  static const _idleSeconds = 180;
  Timer? _idleTimer;

  String get _cashierName =>
      (widget.user['full_name'] as String?)?.isNotEmpty == true
          ? widget.user['full_name'] as String
          : (widget.user['username'] as String? ?? 'Kasir');

  @override
  void initState() {
    super.initState();
    _load();
    _resetIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  void _resetIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: _idleSeconds), () {
      if (mounted) _finishWork(auto: true);
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _api.getTables(),
        _api.getActiveShift(),
      ]);
      if (!mounted) return;
      setState(() {
        _tables = (results[0] as List).cast<Map<String, dynamic>>();
        _shift = results[1] as Map<String, dynamic>?;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Gagal memuat data dari Main POS';
        _loading = false;
      });
    }
  }

  // ── Cetak struk pembayaran lokal ───────────────────────────────────────────
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

  /// Kirim bytes ke printer ber-role kasir (fallback non-checker, lalu pertama).
  /// [build] menerima (cols, isCopy). Bila [honorCopies] true, salinan ke-2..N
  /// (sesuai printer.copies) dikirim dengan isCopy=true → bertanda "COPY".
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

  // ── Bayar ────────────────────────────────────────────────────────────────
  Future<void> _openBill(Map<String, dynamic> order) async {
    final orderId = order['id'] as String;
    final full = await _api.getOrderFull(orderId);
    if (!mounted || full['order'] == null) return;
    await showAppModal(
      context,
      title: 'Tagihan · Meja ${order['table_number']}',
      icon: Icons.receipt_long_rounded,
      accent: _accent,
      builder: (_) => _BillSheet(
        full: full,
        cashierName: _cashierName,
        api: _api,
        onPaid: (latestFull, result, method) async {
          await _printReceipt(latestFull, result, method);
          if (mounted) Navigator.pop(context);
          await _load();
          _snack('Pembayaran lunas — struk dicetak');
        },
        onChanged: _load,
        onCloseAndReload: (msg) async {
          if (mounted) Navigator.pop(context);
          await _load();
          _snack(msg);
        },
        onPrintBill: _printBillLocal,
      ),
    );
    _resetIdle();
  }

  /// Cetak TAGIHAN (belum bayar) ke printer lokal station — paritas tombol
  /// "Cetak Tagihan" di kasir utama.
  Future<void> _printBillLocal(Map<String, dynamic> full) async {
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
      if (mounted) {
        showAppSnack(context, 'Gagal cetak tagihan: $e', isError: true);
      }
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    showAppSnack(context, m);
  }

  @override
  Widget build(BuildContext context) {
    final hasShift = _shift != null;
    final activeOrders = _tables
        .where((t) => t['active_order'] != null)
        .map((t) => (t['active_order'] as Map).cast<String, dynamic>())
        .where((o) => (o['payment_status'] as String?) != 'paid')
        .toList();

    return Listener(
      onPointerDown: (_) => _resetIdle(),
      child: Scaffold(
        appBar: AppPageHeader(
          title: 'Kasir Station',
          subtitle: _cashierName,
          icon: Icons.point_of_sale_rounded,
          accent: _accent,
          showBack: false,
          actions: [
            AppIconButton(
              icon: Icons.refresh_rounded,
              onPressed: _load,
              tooltip: 'Muat ulang',
            ),
            const SizedBox(width: AppSpacing.xxs),
            AppButton(
              label: 'Selesai',
              icon: Icons.logout_rounded,
              variant: AppButtonVariant.neutral,
              size: AppButtonSize.small,
              expanded: false,
              onPressed: () => _finishWork(),
            ),
          ],
        ),
        body: AppBackground(
          child: _loading
              ? const AppLoader(label: 'Memuat data...')
              : Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(context.pagePadX,
                          AppSpacing.md, context.pagePadX, 0),
                      child: _shiftBanner(hasShift),
                    ),
                    if (_error != null)
                      Padding(
                        padding: EdgeInsets.fromLTRB(context.pagePadX,
                            AppSpacing.sm, context.pagePadX, 0),
                        child: _errorBanner(_error!),
                      ),
                    Expanded(child: _ordersList(activeOrders, hasShift)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _shiftBanner(bool hasShift) {
    final color = hasShift ? AppColors.success : AppColors.warning;
    return AppCard(
      accent: color,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Row(
        children: [
          IconBadge(
            icon: hasShift ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
            color: color,
            size: 40,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              hasShift
                  ? 'Shift dibuka oleh ${_shift!['opened_by']}'
                  : 'Shift belum dibuka di perangkat utama',
              style: AppType.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          StatusPill(
            label: hasShift ? 'Aktif' : 'Tutup',
            color: color,
            icon: hasShift ? Icons.check_circle_outline_rounded : null,
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: AppRadius.rSm,
        border: Border.all(color: AppColors.soft(AppColors.danger, 0.28)),
      ),
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

  Widget _ordersList(List<Map<String, dynamic>> activeOrders, bool hasShift) {
    if (activeOrders.isEmpty) {
      return const EmptyState(
        icon: Icons.receipt_long_rounded,
        title: 'Belum ada tagihan aktif',
        message: 'Tagihan meja yang belum lunas akan tampil di sini.',
        accent: _accent,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
            context.pagePadX, AppSpacing.md, context.pagePadX, AppSpacing.lg),
        itemCount: activeOrders.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (_, i) {
          final o = activeOrders[i];
          final partial = (o['payment_status'] as String?) == 'partial';
          final color = partial ? AppColors.warning : _accent;
          return AppCard(
            onTap: hasShift
                ? () => _openBill(o)
                : () => _snack('Shift belum dibuka di perangkat utama'),
            accent: color,
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: AppColors.gradientOf(color)),
                    borderRadius: AppRadius.rSm,
                    boxShadow: AppShadows.glow(color, strength: 0.28),
                  ),
                  child: Text('${o['table_number']}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 18)),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Meja ${o['table_number']} · ${o['basket_size'] ?? 0} item',
                        style: AppType.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      partial
                          ? const StatusPill(
                              label: 'Sebagian terbayar',
                              color: AppColors.warning,
                              icon: Icons.timelapse_rounded,
                            )
                          : Text('${o['pax'] ?? 1} pax',
                              style: AppType.caption
                                  .copyWith(color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  CurrencyHelper.format(
                      (o['total_amount'] as num?)?.toDouble() ?? 0),
                  style: AppType.amount.copyWith(color: color),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Konten tagihan + pembayaran (penuh / campur metode) + diskon + aksi order
/// lain (kompliment, titipan, cetak tagihan, pindah/gabung meja) — paritas
/// dengan panel order kasir utama.
class _BillSheet extends StatefulWidget {
  final Map<String, dynamic> full;
  final String cashierName;
  final StationApiClient api;
  final Future<void> Function(Map<String, dynamic> latestFull,
      Map<String, dynamic> result, String method) onPaid;

  /// Data order berubah tapi sheet tetap terbuka (gabung meja, tarik titipan).
  final Future<void> Function() onChanged;

  /// Order selesai/berpindah — tutup sheet, muat ulang daftar, tampilkan pesan.
  final Future<void> Function(String message) onCloseAndReload;

  /// Cetak tagihan (belum bayar) ke printer lokal station.
  final Future<void> Function(Map<String, dynamic> full) onPrintBill;

  const _BillSheet(
      {required this.full,
      required this.cashierName,
      required this.api,
      required this.onPaid,
      required this.onChanged,
      required this.onCloseAndReload,
      required this.onPrintBill});

  @override
  State<_BillSheet> createState() => _BillSheetState();
}

class _BillSheetState extends State<_BillSheet> {
  static const _accent = AppColors.moduleKasir;
  static const _methods = {
    'cash': 'Tunai',
    'qris': 'QRIS',
    'card': 'Kartu',
    'transfer': 'Transfer',
  };
  String _method = 'cash';
  bool _busy = false;
  bool _hasPartial = false;
  late Map<String, dynamic> _full = widget.full;
  late double _remaining;
  final _amountCtrl = TextEditingController();
  final List<String> _log = [];

  Map<String, dynamic> get _order =>
      (_full['order'] as Map).cast<String, dynamic>();
  String get _orderId => _order['id'] as String;
  double get _total => (_order['total_amount'] as num?)?.toDouble() ?? 0;
  double get _paid => (_order['paid_amount'] as num?)?.toDouble() ?? 0;

  @override
  void initState() {
    super.initState();
    _recompute();
    if (_paid > 0) _hasPartial = true;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  void _recompute() {
    _remaining = (_total - _paid).clamp(0, double.infinity).toDouble();
    _amountCtrl.text = CurrencyHelper.formatInput(_remaining.round());
  }

  Future<void> _refreshFull() async {
    final fresh = await widget.api.getOrderFull(_orderId);
    if (!mounted || fresh['order'] == null) return;
    setState(() {
      _full = fresh;
      _recompute();
    });
  }

  Future<void> _discount() async {
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
      await widget.api.applyDiscount(
        orderId: _orderId,
        chargeType: res.type,
        value: res.value,
        note: res.note,
      );
      await _refreshFull();
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _err('Gagal diskon: ${_msg(e)}');
    }
  }

  // ── Aksi order lain (paritas panel order kasir utama) ──────────────────────

  /// Kompliment: gratiskan seluruh tagihan — WAJIB PIN Manager/SVP/Admin
  /// (samakan dengan kasir utama). Nama pemberi = pemilik PIN, bukan teks
  /// bebas, agar jejak kompliment akuntabel.
  Future<void> _compliment() async {
    final pinCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();
    final ok = await showAppModal<bool>(
      context,
      title: 'Kompliment',
      icon: Icons.card_giftcard_rounded,
      accent: _accent,
      scrollable: false,
      maxWidth: 440,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Gratiskan seluruh tagihan ${CurrencyHelper.format(_total)}?',
            style: AppType.body,
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: pinCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'PIN Manager/SVP (wajib)',
              prefixIcon: Icon(Icons.lock_outline, size: 20),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: reasonCtrl,
            decoration: const InputDecoration(
              labelText: 'Alasan (opsional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Kompliment — Gratiskan',
            icon: Icons.card_giftcard_rounded,
            accent: _accent,
            onPressed: () {
              if (pinCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      // Verifikasi PIN ke Main POS + cek role berwenang (pola sama dengan
      // void/titip item di waiter station).
      final user = await widget.api.authPin(pinCtrl.text.trim());
      final role = (user?['role'] as String?) ?? '';
      if (user == null || !AuthService.voidAuthorizedRoles.contains(role)) {
        if (!mounted) return;
        setState(() => _busy = false);
        _err(user == null
            ? 'PIN salah'
            : 'Tidak berwenang (butuh Manager/SVP/Admin)');
        return;
      }
      final by = (user['full_name'] as String?)?.isNotEmpty == true
          ? user['full_name'] as String
          : (user['username'] as String? ?? 'Manager');
      await widget.api.complimentOrder(
        orderId: _orderId,
        complimentBy: by,
        reason: reasonCtrl.text.trim(),
        createdBy: widget.cashierName,
      );
      await widget.onCloseAndReload('Order dikompliment (oleh $by)');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _err('Gagal kompliment: ${_msg(e)}');
    }
  }

  /// Tarik item dari Meja Titipan ke order ini.
  Future<void> _pullHeld() async {
    List<Map<String, dynamic>> held;
    try {
      held = await widget.api.getHeldItems();
    } catch (e) {
      _err('Gagal memuat titipan: ${_msg(e)}');
      return;
    }
    if (!mounted) return;
    if (held.isEmpty) {
      _err('Tidak ada item di Meja Titipan');
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
      await widget.api.pullHeldItem(
        picked['id'] as String,
        qty: qty,
        targetOrderId: _orderId,
        by: widget.cashierName,
      );
      await _refreshFull();
      await widget.onChanged();
      if (!mounted) return;
      setState(() => _busy = false);
      showAppSnack(context, 'Item titipan ditarik ke tagihan ini');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _err('Gagal tarik titipan: ${_msg(e)}');
    }
  }

  /// Pilih jumlah unit (1..max) — untuk tarik titipan sebagian.
  Future<int?> _askQty(int max) {
    return showAppModal<int>(
      context,
      title: 'Berapa unit?',
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

  /// Pindahkan order ini ke meja kosong lain.
  Future<void> _moveTable() async {
    List<Map<String, dynamic>> tables;
    try {
      tables = await widget.api.getTables();
    } catch (e) {
      _err('Gagal memuat meja: ${_msg(e)}');
      return;
    }
    if (!mounted) return;
    final empty = tables.where((t) => t['active_order'] == null).toList();
    if (empty.isEmpty) {
      _err('Tidak ada meja kosong');
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
                  onTap: () =>
                      Navigator.pop(ctx, t['table_number'] as String),
                ))
            .toList(),
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api
          .moveOrderTable(orderId: _orderId, tableNumber: target);
      await widget.onCloseAndReload('Order dipindah ke meja $target');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _err('Gagal pindah meja: ${_msg(e)}');
    }
  }

  /// Gabung order meja lain ke tagihan ini.
  Future<void> _mergeTable() async {
    List<Map<String, dynamic>> orders;
    try {
      orders = await widget.api.getMergeableOrders(_orderId);
    } catch (e) {
      _err('Gagal memuat meja: ${_msg(e)}');
      return;
    }
    if (!mounted) return;
    if (orders.isEmpty) {
      _err('Tidak ada meja lain untuk digabung');
      return;
    }
    final source = await showAppModal<String>(
      context,
      title: 'Gabung dari Meja',
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
      await widget.api
          .mergeOrders(targetOrderId: _orderId, sourceOrderId: source);
      await _refreshFull();
      await widget.onChanged();
      if (!mounted) return;
      setState(() => _busy = false);
      showAppSnack(context, 'Meja digabung ke tagihan ini');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _err('Gagal gabung meja: ${_msg(e)}');
    }
  }

  Future<void> _pay() async {
    final amount = CurrencyHelper.parseInput(_amountCtrl.text);
    if (amount <= 0) return;
    setState(() => _busy = true);
    try {
      // Tanpa partial sebelumnya & nominal cukup → bayar penuh (dukung kembalian
      // tunai). Selain itu → split-pay (mendukung gabung metode bertahap).
      if (!_hasPartial && amount >= _remaining) {
        final r = await widget.api.payOrder(
          orderId: _orderId,
          paymentMethod: _method,
          paidAmount: amount,
          createdBy: widget.cashierName,
        );
        await widget.onPaid(_full, r, _method);
        return;
      }
      final r = await widget.api.splitPayOrder(
        orderId: _orderId,
        amount: amount,
        paymentMethod: _method,
        createdBy: widget.cashierName,
      );
      final remaining = (r['remaining'] as num?)?.toDouble() ?? 0;
      final status = r['payment_status'] as String?;
      if (status == 'paid' || remaining <= 0) {
        await widget.onPaid(_full, {'paid_amount': _total, 'change': 0}, _method);
        return;
      }
      if (!mounted) return;
      setState(() {
        _hasPartial = true;
        _log.add('${_methods[_method]}: ${CurrencyHelper.format(amount)}');
        _remaining = remaining;
        _amountCtrl.text = CurrencyHelper.formatInput(remaining.round());
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Pemulihan 'Tagihan sudah lunas': hampir selalu berarti percobaan
      // SEBELUMNYA sebenarnya berhasil tapi responsnya hilang (timeout/
      // jaringan). Verifikasi ke Main POS; bila memang lunas, selesaikan
      // normal (struk tercetak) — jangan tampilkan error yang membuat kasir
      // mengira pembayaran gagal.
      if (_msg(e).contains('sudah lunas')) {
        try {
          final full = await widget.api.getOrderFull(_orderId);
          final order = full['order'];
          if (order is Map && order['payment_status'] == 'paid') {
            await widget.onPaid(
                _full, {'paid_amount': _total, 'change': 0}, _method);
            return;
          }
        } catch (_) {}
        if (!mounted) return;
      }
      setState(() => _busy = false);
      _err('Gagal bayar: ${_msg(e)}');
    }
  }

  void _err(String m) => showAppSnack(context, m, isError: true);
  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          color: AppColors.surfaceAlt,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            children: [
              _row('Total', _total, bold: true),
              const SizedBox(height: AppSpacing.xs),
              _row('Sisa', _remaining, color: AppColors.danger, bold: true),
              if (_log.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                const Divider(height: AppSpacing.md),
                ..._log.map((l) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_rounded,
                              size: 14, color: AppColors.success),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Text(l,
                                style: AppType.caption
                                    .copyWith(color: AppColors.textTertiary)),
                          ),
                        ],
                      ),
                    )),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const SectionHeader('Metode Pembayaran'),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: _methods.entries.map((e) {
            final selected = _method == e.key;
            return GestureDetector(
              onTap: () => setState(() => _method = e.key),
              child: AnimatedContainer(
                duration: AppMotion.fast,
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                decoration: BoxDecoration(
                  // SECONDARY gold untuk metode terpilih (aksentuasi sekunder).
                  color: selected ? AppColors.accentSoft : AppColors.surfaceMuted,
                  borderRadius: AppRadius.rPill,
                  border: Border.all(
                      color: selected ? AppColors.accent : AppColors.border),
                ),
                child: Text(
                  e.value,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color:
                        selected ? AppColors.accentDark : AppColors.textSecondary,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _amountCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [RupiahInputFormatter()],
          style: AppType.title,
          decoration: const InputDecoration(
            labelText: 'Jumlah bayar',
            prefixText: 'Rp ',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // Aksi order lain — paritas panel order kasir utama. Aksi khusus
        // perangkat utama (shift, void transaksi lunas, kas laci) sengaja
        // tidak ada di station.
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _miniAction(Icons.card_giftcard_rounded, 'Kompliment',
                _busy ? null : _compliment),
            _miniAction(Icons.inventory_2_outlined, 'Titipan',
                _busy ? null : _pullHeld),
            _miniAction(Icons.receipt_long_outlined, 'Tagihan',
                _busy ? null : () => widget.onPrintBill(_full)),
            _miniAction(Icons.swap_horiz_rounded, 'Pindah',
                _busy ? null : _moveTable),
            _miniAction(Icons.call_merge_rounded, 'Gabung',
                _busy ? null : _mergeTable),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: 'Diskon',
                icon: Icons.percent_rounded,
                variant: AppButtonVariant.tonal,
                accent: AppColors.accent, // SECONDARY gold — aksi sekunder
                onPressed: _busy ? null : _discount,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: 2,
              child: AppButton(
                label: 'Bayar',
                icon: Icons.payments_rounded,
                accent: _accent,
                loading: _busy,
                onPressed: _busy ? null : _pay,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Tombol aksi kecil (chip) untuk baris aksi order.
  Widget _miniAction(IconData icon, String label, VoidCallback? onTap) {
    return ActionChip(
      avatar: Icon(icon, size: 18, color: AppColors.textSecondary),
      label: Text(label),
      onPressed: onTap,
    );
  }

  Widget _row(String label, double value, {Color? color, bool bold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppType.body),
        Text(CurrencyHelper.format(value),
            style: (bold ? AppType.amount : AppType.title)
                .copyWith(color: color ?? AppColors.textPrimary)),
      ],
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
