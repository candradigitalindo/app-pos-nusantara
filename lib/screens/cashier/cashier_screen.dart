import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/cashier_controller.dart';
import '../../models/models.dart';
import '../../repositories/cashier_repository.dart';
import '../../repositories/order_repository.dart';
import '../../services/app_events.dart';
import '../../services/cash_drawer_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/qris_service.dart';
import '../../services/reservation_service.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/addon_picker_dialog.dart';
import '../../widgets/pax_input_dialog.dart';
import '../../widgets/pin_auth_dialog.dart';
import '../../widgets/qris_payment_dialog.dart';
import '../../widgets/reservation_picker_dialog.dart';
import '../../widgets/ui/ui.dart';
import 'cashier_order_actions.dart';
import 'cashier_widgets.dart';
import 'shift_period_summary.dart';

class CashierScreen extends StatefulWidget {
  final String? initialTableNumber;
  const CashierScreen({super.key, this.initialTableNumber});

  @override
  State<CashierScreen> createState() => _CashierScreenState();
}

class _CashierScreenState extends State<CashierScreen>
    with AppEventsRefresh<CashierScreen>, CashierOrderActions<CashierScreen> {
  @override
  CashierController get actionsController => _controller;

  late final CashierController _controller;
  late final TextEditingController _openShiftCtrl;

  // Status sinkronisasi (indikator offline / menunggu sync) di header.
  // ValueNotifier agar update 8-detik HANYA me-rebuild pil, bukan seluruh layar
  // (penting untuk tablet spek rendah).
  final ValueNotifier<({bool enabled, int pending, bool online})?> _sync =
      ValueNotifier(null);
  Timer? _syncTimer;

  // Aksi sekunder keranjang (Diskon/Split/Pindah/dll) disembunyikan default agar
  // tak menutup daftar item di layar kecil; dibuka via toggle "Aksi Lainnya".

  @override
  void initState() {
    super.initState();
    _openShiftCtrl = TextEditingController();
    _controller = CashierController();
    _controller.addListener(_onStateChanged);
    _controller.loadData().then((_) {
      if (widget.initialTableNumber != null) {
        _controller.initTable(widget.initialTableNumber!);
      }
    });
    _refreshSync();
    _syncTimer = Timer.periodic(
        const Duration(seconds: 8), (_) => _refreshSync());
    // Perbarui status segera setelah siklus sync (otomatis maupun manual)
    // selesai, tanpa menunggu poll 8-detik berikutnya.
    CloudSyncService.instance.syncing.addListener(_onSyncingChanged);
    // Order/meja bisa berubah dari perangkat lain (station) atau layar lain
    // (waiter/dapur) — segarkan tanpa mengganggu keranjang yang sedang disusun.
    listenDataChanges();
  }

  @override
  void onDataChanged() => _controller.refreshExternal();

  @override
  void onCatalogChanged() => _controller.refreshProductPhotos();

  void _onSyncingChanged() {
    if (!CloudSyncService.instance.isSyncing) _refreshSync();
  }

  Future<void> _refreshSync() async {
    final s = await CloudSyncService.instance.status();
    if (mounted) {
      _sync.value = s; // hanya pil yang rebuild (ValueListenableBuilder)
    }
  }

  @override
  void deactivate() {
    _controller.removeListener(_onStateChanged);
    super.deactivate();
  }

  @override
  void dispose() {
    cancelDataChanges();
    _syncTimer?.cancel();
    CloudSyncService.instance.syncing.removeListener(_onSyncingChanged);
    _sync.dispose();
    _openShiftCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final state = _controller.state;

    final errorMsg = state.errorMessage;
    final paymentResult = state.lastPaymentResult;

    if (errorMsg != null) _controller.clearError();
    if (paymentResult != null) _controller.clearPaymentResult();

    if (!mounted) return;
    setState(() {});

    if (errorMsg != null || paymentResult != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (errorMsg != null) {
          showAppSnack(context, errorMsg, isError: true);
        }
        if (paymentResult != null) {
          _showReceiptDialog(paymentResult);
        }
      });
    }
  }

  void _showPaymentDialog() {
    final order = _controller.state.currentOrder;
    if (order == null) return;
    final remaining = order.remaining;
    final controller = TextEditingController(
      text: _rupiahFormat(remaining.toStringAsFixed(0)),
    );

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24)),
        child: CashierPaymentSheet(
          total: remaining,
          controller: controller,
          onPay: (method, amount) async {
            Navigator.pop(ctx);
            // QRIS terintegrasi: uang harus terkonfirmasi penyedia SEBELUM
            // pembayaran dicatat. Bila outlet belum tersambung gateway,
            // alurnya jatuh ke QRIS manual seperti sebelumnya.
            if (method == 'qris' && !await _confirmQrisPaid(order.id, amount)) {
              return;
            }
            await _controller.processPayment(method, amount);
          },
        ),
      ),
    );
  }

  /// Terbitkan QR dan tunggu penyedia mengonfirmasi pembayaran.
  ///
  /// Mengembalikan true bila boleh lanjut mencatat pembayaran. Outlet yang
  /// BELUM tersambung gateway tetap boleh lanjut — QRIS-nya dianggap manual
  /// seperti sebelum fitur ini ada, jadi kasir tidak pernah terkunci hanya
  /// karena cloud belum dikonfigurasi.
  Future<bool> _confirmQrisPaid(String orderId, double amount) async {
    final info = await QrisService.instance.info();
    if (info == null || info['enabled'] != true) return true;
    if (!mounted) return false;

    final order = _controller.state.currentOrder;
    final paid = await showQrisPaymentDialog(
      context,
      orderId: orderId,
      amount: amount,
      description: 'Meja ${order?.tableNumber ?? '-'}',
    );
    if (paid == true) return true;

    if (mounted) {
      showAppSnack(context, 'Pembayaran QRIS belum terkonfirmasi — tidak dicatat',
          isError: true);
    }
    return false;
  }

  /// Pilih transaksi (sudah dibayar) untuk di-void.
  void _showVoidTransactionPicker() {
    showDialog(
      context: context,
      builder: (ctx) => _VoidTransactionPicker(
        getPaidOrders: _controller.getRecentPaidOrders,
        onPick: (order) {
          Navigator.pop(ctx);
          _showVoidPaidDialog(order);
        },
      ),
    );
  }

  /// Pilih transaksi lunas untuk cetak ulang struknya.
  void _showReprintPicker() {
    showDialog(
      context: context,
      builder: (ctx) => _VoidTransactionPicker(
        getPaidOrders: _controller.getRecentPaidOrders,
        title: 'Cetak Ulang Struk',
        icon: Icons.print_outlined,
        actionLabel: 'CETAK',
        onPick: (order) async {
          Navigator.pop(ctx);
          await _controller.reprintReceiptFor(order);
          if (!mounted) return;
          showAppSnack(context, 'Struk Meja ${order.tableNumber} dicetak ulang',
              icon: Icons.print_outlined);
        },
      ),
    );
  }

  /// Dialog otorisasi PIN + alasan untuk void transaksi lunas terpilih.
  Future<void> _showVoidPaidDialog(Order order) async {
    final res = await showPinAuthDialog(
      context,
      title: 'Void Transaksi',
      actionLabel: 'Void Transaksi',
      icon: Icons.block_outlined,
      details: {
        'Meja': order.tableNumber,
        'Status': 'LUNAS',
        'Total': CurrencyHelper.format(order.totalAmount),
        if (order.customerName?.isNotEmpty ?? false)
          'Pelanggan': order.customerName!,
      },
      reasonHint: 'Contoh: salah tagih, refund pelanggan',
    );
    if (res == null || !mounted) return;
    final result = await _controller.voidPaidOrder(
      orderId: order.id,
      pin: res.pin,
      reason: res.reason,
    );
    if (!mounted) return;
    if (result == 'ok') {
      showAppSnack(context, 'Transaksi Meja ${order.tableNumber} di-void',
          isError: true, icon: Icons.block_rounded);
    } else if (result == 'invalid_pin') {
      showAppSnack(context, 'PIN salah / tidak berwenang', isError: true);
    }
  }

  /// Dialog kompliment: catat siapa yang memberi & alasan, lalu gratiskan order.
  static String _rupiahFormat(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return '';
    final n = int.tryParse(digits) ?? 0;
    return n.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]}.',
    );
  }

  void _showReceiptDialog(Map<String, dynamic> result) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rXxl),
        title: Row(
          children: [
            const IconBadge(
                icon: Icons.check_circle_rounded,
                color: AppColors.moduleKasir,
                filled: true,
                size: 44),
            const SizedBox(width: AppSpacing.sm),
            Text('Pembayaran Berhasil', style: AppType.h3),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _receiptRow('Total',
                CurrencyHelper.format(result['total_amount'] as double)),
            _receiptRow('Bayar',
                CurrencyHelper.format(result['paid_amount'] as double)),
            const Divider(color: AppColors.surfaceMuted),
            _receiptRow(
              'Kembalian',
              CurrencyHelper.format(result['change'] as double),
              valueStyle: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColors.moduleKasir,
                fontSize: 18,
              ),
            ),
          ],
        ),
        actions: [
          AppButton(
            label: 'Selesai',
            accent: AppColors.moduleKasir,
            size: AppButtonSize.medium,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _receiptRow(String label, String value, {TextStyle? valueStyle}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textSecondary)),
          Text(value,
              style:
                  valueStyle ?? const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _showTableSelector() async {
    final tables = _controller.state.tables;
    final number = await showDialog<String>(
      context: context,
      builder: (_) => CashierTablePickerDialog(
        tables: tables
            .map((t) => CashierPickerTable(
                number: t.tableNumber, available: t.status == 'available'))
            .toList(),
        selectedNumber: _controller.state.selectedTable?.tableNumber,
      ),
    );
    if (number == null || !mounted) return;
    final table = tables.firstWhere((t) => t.tableNumber == number);
    if (table.status == 'available') {
      // Pesanan baru → input pax (wajib) + identitas customer (opsional).
      final res = await showPaxDialog(context);
      if (res == null) return; // dibatalkan
      _controller.selectTable(table);
      _controller.setPax(res.pax);
      _controller.setCustomer(
          name: res.customerName, phone: res.customerPhone);
    } else {
      _controller.selectTable(table); // muat order lama
    }
  }

  /// Buka reservasi cloud menjadi order: pilih reservasi → pilih meja kosong →
  /// order dibuat, DP tervalidasi tercatat, lalu meja itu dimuat di layar.
  Future<void> _showReservations() async {
    final r = await showReservationPicker(context);
    if (r == null || !mounted) return;

    try {
      // Reservasi yang sudah dibuka kembali ke meja aslinya, termasuk untuk
      // mengambil tambahan DP. Tidak perlu tersedia meja kosong lainnya.
      final existing = await OrderRepository().getOrderByReservation(r.id);
      if (!mounted) return;
      String tableNumber;
      if (existing != null) {
        tableNumber = existing.tableNumber;
      } else {
        final available = _controller.state.tables
            .where((t) => t.status == 'available')
            .toList();
        if (available.isEmpty) {
          showAppSnack(context, 'Tidak ada meja kosong untuk reservasi ini',
              isError: true);
          return;
        }
        final number = await showDialog<String>(
          context: context,
          builder: (_) => CashierTablePickerDialog(
            tables: available
                .map((t) => CashierPickerTable(
                    number: t.tableNumber, available: true))
                .toList(),
          ),
        );
        if (number == null || !mounted) return;
        tableNumber = number;
      }

      final cashierName = _controller.state.activeShift?.openedBy ?? 'Kasir';
      final opened = await ReservationService.instance.openAsOrder(
        reservation: r,
        tableNumber: tableNumber,
        cashierName: cashierName,
      );
      if (!mounted) return;
      await _controller.loadData();
      final actualTable = opened.order.tableNumber;
      final matching = _controller.state.tables
          .where((t) => t.tableNumber == actualTable);
      if (matching.isNotEmpty) _controller.selectTable(matching.first);
      await _controller.loadOrderForTable(actualTable);
      if (!mounted) return;
      final dp = opened.order.paidAmount > 0
          ? ', DP ${CurrencyHelper.format(opened.order.paidAmount)} tercatat'
          : '';
      final skipped = opened.skipped.isEmpty
          ? ''
          : '. Menu tak dikenal POS dilewati: ${opened.skipped.join(', ')}';
      showAppSnack(context,
          'Reservasi ${r.customerName} dibuka di Meja $actualTable$dp$skipped',
          isError: opened.skipped.isNotEmpty);
    } catch (e) {
      if (!mounted) return;
      showAppSnack(context, 'Gagal membuka reservasi: $e', isError: true);
    }
  }

  // ── Shift Gate ───────────────────────────────────────────────────────────

  Widget _buildShiftGate(CashierState state) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: AppBackground(
        child: Column(
          children: [
            // Header gradasi teal modul Kasir
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: AppColors.gradientOf(AppColors.moduleKasir),
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                boxShadow: AppShadows.glow(AppColors.moduleKasir, strength: 0.28),
              ),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 66,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Row(
                      children: [
                        AppIconButton(
                          icon: Icons.arrow_back_ios_new_rounded,
                          onPressed: () => Navigator.pop(context),
                          color: Colors.white,
                          filled: true,
                          size: 44,
                          tooltip: 'Kembali',
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
                              Text('Kasir',
                                  style: AppType.h3.copyWith(color: Colors.white)),
                              Text('Buka Shift untuk Memulai',
                                  style: AppType.caption
                                      .copyWith(color: AppColors.soft(Colors.white, 0.85))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Body — centered card
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
                          // Icon
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: AppColors.gradientOf(AppColors.moduleKasir),
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: AppRadius.rXl,
                              boxShadow: AppShadows.glow(AppColors.moduleKasir),
                            ),
                            child: const Icon(Icons.point_of_sale,
                                color: Colors.white, size: 40),
                          ),
                          const SizedBox(height: AppSpacing.xl),

                          // Title
                          Text('Buka Kasir', style: AppType.h1),
                          const SizedBox(height: AppSpacing.xs),

                          // Subtitle
                          Text(
                            'Masukkan modal kas awal untuk memulai shift',
                            textAlign: TextAlign.center,
                            style: AppType.body.copyWith(color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: AppSpacing.xxl),

                          // Kas Awal input
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Kas Awal', style: AppType.label),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          TextField(
                            controller: _openShiftCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [RupiahInputFormatter()],
                            decoration: const InputDecoration(
                              prefixText: 'Rp ',
                              hintText: '0',
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: AppSpacing.md, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: AppRadius.rSm,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: AppRadius.rSm,
                                borderSide: BorderSide(color: AppColors.border),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: AppRadius.rSm,
                                borderSide: BorderSide(
                                    color: AppColors.moduleKasir, width: 2),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xl),

                          // BUKA KASIR button
                          AppButton(
                            label: 'BUKA KASIR',
                            loading: state.isProcessing,
                            accent: AppColors.moduleKasir,
                            onPressed: () {
                              final rawDigits =
                                  _openShiftCtrl.text.replaceAll('.', '');
                              final cash = double.tryParse(rawDigits) ?? 0;
                              _controller.openShift(
                                openingCash: cash,
                              );
                            },
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

  // ── Shift Dialogs ────────────────────────────────────────────────────────

  Future<void> _showCloseShiftDialog() async {
    final shift = _controller.state.activeShift;
    if (shift == null) return;

    // Tagihan berjalan harus lunas dulu — dicegah SEBELUM dialog tutup kasir
    // dibuka supaya kasir tak mengisi setoran lalu ditolak di akhir.
    final unpaid = await _controller.unpaidTables();
    if (!mounted) return;
    if (unpaid.isNotEmpty) {
      await showAppModal<void>(
        context,
        title: 'Belum Bisa Tutup Kasir',
        icon: Icons.receipt_long_rounded,
        accent: AppColors.warning,
        scrollable: false,
        maxWidth: 440,
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${CashierRepository.unpaidBlockMessage(unpaid)}\n\n'
              'Selesaikan pembayarannya dulu lewat layar Kasir atau menu '
              'Transaksi. Item di Meja Titipan bisa ditarik ke tagihan lewat '
              '"Tarik dari Titipan". Setelah semuanya selesai, tutup kasir lagi.',
              style: AppType.body.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Mengerti',
              accent: AppColors.moduleKasir,
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      );
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => CloseShiftDialog(
        activeShift: shift,
        getShiftReport: () => _controller.getShiftReport(shiftId: shift.id),
        getShiftMovements: () => _controller.getShiftMovements(shiftId: shift.id),
        onClose: () => _controller.closeShift(shiftId: shift.id),
      ),
    );
  }

  // Satu container group dengan border
  // Tombol di dalam group
  // Ukuran tombol aksi header — SERAGAM & sebesar jari (target sentuh ~84×60).
  static const double _headerBtnW = kCashierHeaderBtnW;
  static const double _headerBtnH = kCashierHeaderBtnH;

  // Ukuran efektif tombol header — dikecilkan di HP agar header tak overflow.
  // Diset di awal [_buildHeader] berdasar lebar layar; default = ukuran tablet.
  double _hbW = _headerBtnW;
  double _hbH = _headerBtnH;

  /// Buka laci kasir MANUAL (mis. tukar uang / laci tak terbuka saat bayar).
  /// Sengaja tidak menghiraukan sakelar "otomatis" di Pengaturan: ini aksi
  /// eksplisit kasir, bukan otomatisasi.
  Future<void> _openCashDrawer() async {
    try {
      await CashDrawerService.instance.open();
      if (mounted) showAppSnack(context, 'Laci kasir dibuka');
    } catch (e) {
      if (mounted) {
        showAppSnack(
            context,
            'Gagal buka laci: '
            '${e.toString().replaceFirst('Exception: ', '')}',
            isError: true);
      }
    }
  }

  /// Isi bingkai header — urutan & warna tombolnya jadi acuan Kasir Station.
  List<Widget> _headerActions(CashierState state, double w) => [
        _syncButton(width: w),
        _groupDivider(),
        _headerBtn(
          icon: Icons.table_restaurant_outlined,
          label: state.currentOrder != null
              ? 'Meja ${state.currentOrder!.tableNumber}'
              : state.selectedTable != null
                  ? 'Meja ${state.selectedTable!.tableNumber}'
                  : 'Pilih Meja',
          onTap: _showTableSelector,
          width: w,
        ),
        _groupDivider(),
        _headerBtn(
          icon: Icons.event_seat_outlined,
          label: 'Reservasi',
          onTap: _showReservations,
          width: w,
        ),
        _groupDivider(),
        _headerBtn(
            icon: Icons.people_alt_outlined,
            label: 'Ganti Shift',
            onTap: _showSwapShiftDialog,
            width: w),
        _groupDivider(),
        _headerBtn(
            icon: Icons.account_balance_wallet_outlined,
            label: 'Kas',
            onTap: () => _showCashMovementDialog('in'),
            width: w),
        _groupDivider(),
        _headerBtn(
            icon: Icons.point_of_sale_outlined,
            label: 'Buka Laci',
            onTap: _openCashDrawer,
            width: w),
        _groupDivider(),
        _headerBtn(
            icon: Icons.history,
            label: 'Riwayat',
            onTap: _showMovementsHistory,
            width: w),
        _groupDivider(),
        _headerBtn(
            icon: Icons.remove_shopping_cart_outlined,
            label: 'Void',
            onTap: _showVoidTransactionPicker,
            iconColor: AppColors.danger,
            width: w),
        _groupDivider(),
        _headerBtn(
            icon: Icons.history_toggle_off,
            label: 'Histori Void',
            onTap: _showVoidHistory,
            iconColor: AppColors.danger,
            width: w),
        _groupDivider(),
        _headerBtn(
            icon: Icons.print_outlined,
            label: 'Cetak Ulang',
            onTap: _showReprintPicker,
            width: w),
        _groupDivider(),
        CashierHeaderButton(
          icon: Icons.refresh,
          label: 'Muat Ulang',
          onTap: () => _controller.loadData(),
          background: Colors.white,
          iconColor: AppColors.moduleKasir,
          width: w,
          height: _hbH,
        ),
        _groupDivider(),
        CashierHeaderButton(
          icon: Icons.logout,
          label: 'Tutup Kasir',
          onTap: _showCloseShiftDialog,
          background: AppColors.danger,
          iconColor: Colors.white,
          width: w,
          height: _hbH,
        ),
      ];

  Widget _headerBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    double? width,
  }) {
    return CashierHeaderButton(
      icon: icon,
      label: label,
      onTap: onTap,
      iconColor: iconColor,
      width: width ?? _hbW,
      height: _hbH,
    );
  }

  /// Tombol Sinkron di header (ukuran seragam 84×60): status + tap untuk
  /// sinkron ke cloud, dengan animasi berputar saat proses.
  Widget _syncButton({double? width}) {
    // Dengarkan status siklus dari service (true saat auto-sync timer maupun
    // manual) agar tombol ikut berputar walau sync dipicu otomatis.
    return ValueListenableBuilder<bool>(
      valueListenable: CloudSyncService.instance.syncing,
      builder: (_, syncing, __) => ValueListenableBuilder(
        valueListenable: _sync,
        builder: (_, s, __) => _SyncButton(
          syncing: syncing,
          status: s,
          onTap: _doSync,
          width: width ?? _hbW,
          height: _hbH,
        ),
      ),
    );
  }

  /// Jalankan sinkron ke cloud (push + pull + heartbeat) secara manual.
  Future<void> _doSync() async {
    // Siklus (auto/manual) sedang berjalan → jangan picu siklus kedua.
    // syncCycle() sendiri sudah anti-dobel, ini sekadar hindari snackbar ganda.
    if (CloudSyncService.instance.isSyncing) return;
    final cur = _sync.value;
    if (cur != null && !cur.enabled) {
      showAppSnack(context,
          'Sinkron cloud belum diaktifkan (Pengaturan → Cloud).',
          isError: true);
      return;
    }
    // Animasi berputar digerakkan oleh CloudSyncService.syncing (via listener).
    try {
      await CloudSyncService.instance.syncCycle();
    } catch (_) {}
    try {
      _sync.value = await CloudSyncService.instance.status();
    } catch (_) {}
    if (!mounted) return;
    final now = _sync.value;
    final ok = now != null && now.online && now.pending == 0;
    showAppSnack(
      context,
      ok
          ? 'Tersinkron ke cloud.'
          : (now != null && !now.online
              ? 'Offline — data tersimpan, dikirim saat online.'
              : 'Sinkron: ${now?.pending ?? 0} data masih menunggu.'),
      isError: !ok,
    );
  }

  // Separator tipis di dalam group
  Widget _groupDivider() => cashierGroupDivider();

  void _showMovementsHistory() {
    showDialog(
      context: context,
      builder: (ctx) => _MovementsHistoryDialog(
        getMovements: _controller.getShiftMovements,
      ),
    );
  }

  void _showVoidHistory() {
    showDialog(
      context: context,
      builder: (ctx) => _VoidHistoryDialog(
        getVoidedOrders: _controller.getVoidedOrders,
      ),
    );
  }

  void _showCashMovementDialog(String initialType) {
    showDialog(
      context: context,
      builder: (ctx) => _CashMovementDialog(
        initialType: initialType,
        onSave: (type, name, amount, note) async {
          await _controller.addCashMovement(
            type: type,
            name: name,
            amount: amount,
            note: note,
          );
        },
      ),
    );
  }

  void _showSwapShiftDialog() {
    final shift = _controller.state.activeShift;
    if (shift == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _SwapShiftDialog(
        activeShift: shift,
        getShiftReport: () => _controller.getShiftReport(shiftId: shift.id),
        getCashierUsers: _controller.getCashierUsers,
        getShiftMovements: () => _controller.getShiftMovements(shiftId: shift.id),
        onSwap: (handoverTo, newCash) => _controller.swapShift(
            shiftId: shift.id,
            handoverTo: handoverTo,
            newOpeningCash: newCash,
          ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;

    if (state.isLoading && state.products.isEmpty) {
      return const Scaffold(
        backgroundColor: AppColors.canvas,
        body: AppLoader(label: 'Memuat kasir...'),
      );
    }

    // Gate: if no active shift, show "Buka Kasir" screen
    if (!state.isLoading && state.activeShift == null) {
      return _buildShiftGate(state);
    }

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Column(
        children: [
          // ── Header ──
          _buildHeader(state),

          // ── Body ──
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isPhone = constraints.maxWidth < 600;
                if (isPhone) return _buildPhoneLayout(state);
                // Panel pesanan menyesuaikan lebar layar (proporsional, dibatasi).
                final cartWidth =
                    (constraints.maxWidth * 0.30).clamp(300.0, 440.0);
                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          _buildCategoryTabs(state),
                          Expanded(child: _buildProductGrid(state)),
                        ],
                      ),
                    ),
                    _buildCartPanel(state, width: cartWidth),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneLayout(CashierState state) {
    return Column(
      children: [
        _buildCategoryTabs(state),
        Expanded(child: _buildProductGrid(state)),
        _buildPhoneCartBar(state),
      ],
    );
  }

  Widget _buildPhoneCartBar(CashierState state) {
    final hasItems = state.cart.isNotEmpty || state.orderItems.isNotEmpty;
    if (!hasItems) return const SizedBox.shrink();

    final displayTotal = state.currentOrder?.totalAmount ?? state.cartTotal;

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
                onTap: () => _showPhoneCartSheet(),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${state.cartItemCount} item',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textTertiary),
                      ),
                      Text(
                        'Rp ${displayTotal.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.moduleKasir,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (state.currentOrder != null && state.cart.isNotEmpty) ...[
              _buildBarButton('TAMBAH', state.isProcessing,
                  _controller.createOrder),
              const SizedBox(width: 8),
              _buildBarButton('BAYAR', state.isProcessing, _showPaymentDialog),
            ] else if (state.currentOrder != null && !state.currentOrder!.isPaid)
              _buildBarButton('BAYAR', state.isProcessing, _showPaymentDialog)
            else if (state.currentOrder == null && state.cart.isNotEmpty)
              _buildBarButton(
                  'BUAT ORDER', state.isProcessing, _controller.createOrder),
          ],
        ),
      ),
    );
  }

  Widget _buildBarButton(
      String label, bool isLoading, VoidCallback onTap) {
    return AppButton(
      label: label,
      loading: isLoading,
      onPressed: onTap,
      accent: AppColors.moduleKasir,
      size: AppButtonSize.medium,
      expanded: false,
    );
  }

  void _showPhoneCartSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.92,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
              ),
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  final state = _controller.state;
                  return Column(
                    children: [
                      Center(
                        child: Container(
                          margin: const EdgeInsets.only(top: 12),
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppColors.borderStrong,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Row(
                          children: [
                            const Icon(Icons.receipt_long_outlined,
                                color: AppColors.moduleKasir, size: 20),
                            const SizedBox(width: 8),
                            const Text('Pesanan',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textPrimary)),
                            const Spacer(),
                            if (state.cartItemCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.soft(AppColors.moduleKasir, 0.14),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text('${state.cartItemCount} item',
                                    style: const TextStyle(
                                        color: AppColors.moduleKasir,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                              ),
                          ],
                        ),
                      ),
                      const Divider(),
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          children: _buildCartItemWidgets(state),
                        ),
                      ),
                      _buildCartBottom(state),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  void _showNoteDialog(String productId, String? current) {
    final ctrl = TextEditingController(text: current ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Catatan Item'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            hintText: 'Contoh: es sedikit, lebih pedas...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () {
              _controller.updateCartNote(productId, ctrl.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  /// Tambah menu ke keranjang. Menu yang punya add-on membuka dialog pemilih
  /// lebih dulu; menu yang barisnya SUDAH ada di keranjang langsung bertambah
  /// unit mengikuti racikan yang sudah dipilih (ubah lewat tombol edit di
  /// baris keranjang) supaya harga satu baris tidak ambigu.
  Future<void> _addProductToCart(Product product) async {
    final state = _controller.state;
    final hasAddons = (state.addonCounts[product.id] ?? 0) > 0;
    if (state.cart.containsKey(product.id) || !hasAddons) {
      _controller.addToCart(product);
      return;
    }

    final options = await _controller.addonsFor(product.id);
    if (!mounted) return;
    if (options.isEmpty) {
      _controller.addToCart(product);
      return;
    }

    final picked = await showAddonPicker(
      context,
      productName: product.name,
      basePrice: product.price,
      addons: options,
    );
    // Batal di dialog = batal menambah item, bukan menambah tanpa add-on.
    if (picked == null || !mounted) return;
    _controller.addToCart(product, addons: picked);
  }

  /// Ubah racikan add-on satu baris keranjang yang belum dikirim ke dapur.
  Future<void> _editCartAddons(Product product) async {
    final options = await _controller.addonsFor(product.id);
    if (!mounted || options.isEmpty) return;
    final picked = await showAddonPicker(
      context,
      productName: product.name,
      basePrice: product.price,
      addons: options,
      initial: _controller.state.cartAddons[product.id] ?? const [],
    );
    if (picked == null || !mounted) return;
    _controller.updateCartAddons(product.id, picked);
  }

  List<Widget> _buildCartItemWidgets(CashierState state) {
    return [
      ...state.cart.entries.map((entry) {
        final product = state.productCache[entry.key];
        if (product == null) return const SizedBox.shrink();
        final addons = state.cartAddons[entry.key] ?? const <SelectedAddon>[];
        return CashierCartItemTile(
          name: product.name,
          qty: entry.value,
          // Harga baris = harga menu + add-on, sama dengan yang nanti disimpan
          // di order_items.price.
          price: product.price + SelectedAddon.totalOf(addons),
          notes: state.cartNotes[entry.key],
          addonLabel: SelectedAddon.labelOf(addons),
          onAdd: () => _controller.addToCart(product),
          onRemove: () => _controller.removeFromCart(product.id),
          onEditNote: () =>
              _showNoteDialog(entry.key, state.cartNotes[entry.key]),
          onEditAddons: (state.addonCounts[entry.key] ?? 0) > 0
              ? () => _editCartAddons(product)
              : null,
        );
      }),
      if (state.orderItems.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('Dipesan',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary,
                  fontSize: 12)),
        ),
        ...state.orderItems.map((item) => CashierCartItemTile(
              name: item.productName,
              qty: item.qty,
              price: item.price,
              status: item.itemStatus,
              addonLabel: item.addonLabel,
              notes: item.notes.isEmpty ? null : item.notes,
              onDelete: () => showItemDeleteOptions(item),
            )),
      ],
    ];
  }

  Widget _buildHeader(CashierState state) {
    // Di HP (portrait sempit) kecilkan tombol/jarak header agar tak overflow;
    // di tablet nilai tetap seperti semula.
    final phone = context.isPhone;
    _hbW = phone ? 62.0 : _headerBtnW;
    _hbH = phone ? 54.0 : _headerBtnH;
    final backSize = phone ? 46.0 : 60.0;
    final edgeGap = phone ? 6.0 : 10.0;
    final headerH = phone ? 66.0 : 76.0;
    final padX = phone ? 10.0 : 16.0;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.gradientOf(AppColors.moduleKasir),
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        boxShadow: AppShadows.glow(AppColors.moduleKasir, strength: 0.28),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: headerH,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: padX),
            child: Row(
              children: [
                Material(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context),
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

                // ── SATU bingkai untuk semua tombol aksi ────────────────────
                // Sebelumnya tombol terpecah jadi beberapa grup + dua tombol
                // lepas di kanan; kini semuanya duduk dalam satu bingkai
                // bersambung yang dipisah garis tipis, warna tiap tombol tetap
                // (Void merah, Muat Ulang putih, Tutup Kasir merah).
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      // Bingkai memenuhi lebar bila muat (rapi, tanpa sisa
                      // ruang di kanan); bila sempit (HP) baru bisa digulir.
                      const count = 12; // sinkron, meja, reservasi, dan aksi kasir
                      const dividers = count - 1;
                      final natural = _hbW * count + dividers;
                      final fits = c.maxWidth >= natural;
                      final w = fits ? (c.maxWidth - dividers) / count : _hbW;
                      final frame =
                          cashierHeaderGroup(_headerActions(state, w));
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

  Widget _buildCategoryTabs(CashierState state) {
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
          _categoryChip('Semua', state.selectedCategory == null,
              () => _controller.selectCategory(null)),
          ...state.categories.map((cat) => _categoryChip(
                cat.name,
                state.selectedCategory?.id == cat.id,
                () => _controller.selectCategory(cat),
              )),
        ],
      ),
    );
  }

  Widget _buildProductGrid(CashierState state) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        // Di HP portrait (layar penuh, ~360–430) tampilkan 2 kolom agar kartu
        // tak terlalu kecil; di tablet ladder ukuran lama dipertahankan.
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
          itemCount: state.products.length,
          itemBuilder: (context, index) {
            final product = state.products[index];
            final inCart = state.cart[product.id] ?? 0;
            return CashierProductTile(
              product: product,
              inCart: inCart,
              hasAddons: (state.addonCounts[product.id] ?? 0) > 0,
              onTap: () => _addProductToCart(product),
            );
          },
        );
      },
    );
  }

  Widget _buildCartPanel(CashierState state, {double width = 320}) {
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
          // Header
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
            ),
            child: Row(
              children: [
                const Icon(Icons.receipt_long_outlined,
                    color: AppColors.moduleKasir, size: 20),
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
                if (state.cartItemCount > 0)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.soft(AppColors.moduleKasir, 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${state.cartItemCount} item',
                      style: const TextStyle(
                        color: AppColors.moduleKasir,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Jumlah tamu (pax)
          _buildPaxRow(state),

          // Cart items
          Expanded(
            child: _buildCartItems(state),
          ),

          // Bottom: total & actions
          _buildCartBottom(state),
        ],
      ),
    );
  }

  /// Baris jumlah tamu (pax). Editable saat membuat order baru; saat order
  /// sudah ada, tampilkan pax order tersebut (read-only).
  Widget _buildPaxRow(CashierState state) {
    final hasOrder = state.currentOrder != null;
    final value = hasOrder ? state.currentOrder!.pax : state.pax;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: Row(
        children: [
          const Icon(Icons.people_outline, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          const Text('Jumlah Tamu',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const Spacer(),
          if (hasOrder)
            Text('$value pax',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.bold))
          else
            Row(
              children: [
                _paxBtn(Icons.remove,
                    () => _controller.setPax(state.pax - 1)),
                Container(
                  width: 40,
                  alignment: Alignment.center,
                  child: Text('$value',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                _paxBtn(Icons.add, () => _controller.setPax(state.pax + 1)),
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
          child: Icon(icon, size: 18, color: AppColors.moduleKasir),
        ),
      ),
    );
  }

  Widget _buildCartItems(CashierState state) {
    if (state.cart.isEmpty && state.orderItems.isEmpty) {
      return const EmptyState(
        icon: Icons.shopping_cart_outlined,
        title: 'Belum ada item',
        message: 'Pilih menu untuk mulai pesanan',
        accent: AppColors.moduleKasir,
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      children: _buildCartItemWidgets(state),
    );
  }

  Widget _buildCartBottom(CashierState state) {
    final displayTotal = state.currentOrder?.totalAmount ?? state.cartTotal;
    // Rincian charge hanya untuk order aktif (charge tersimpan di DB).
    final hasOrder = state.currentOrder != null;
    final charges = hasOrder ? state.orderCharges : const <OrderAdditionalCharge>[];

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surfaceMuted)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Rincian Subtotal + charge/diskon/pajak (bila ada)
            if (hasOrder && charges.isNotEmpty) ...[
              _billRow('Subtotal', state.orderSubtotal),
              const SizedBox(height: 4),
              ...charges.map((c) {
                final isDiscount = c.appliedAmount < 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _billRow(
                    c.name,
                    c.appliedAmount,
                    signed: true,
                    color: isDiscount ? AppColors.danger : null,
                  ),
                );
              }),
              const Divider(height: 14, color: AppColors.border),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total', style: AppType.title),
                Text(
                  CurrencyHelper.format(displayTotal),
                  style: AppType.amount.copyWith(color: AppColors.moduleKasir),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (state.currentOrder != null && state.cart.isNotEmpty) ...[
              _buildActionButton(
                label: 'TAMBAH',
                isLoading: state.isProcessing,
                onTap: () => _controller.createOrder(),
              ),
              const SizedBox(height: 8),
              _buildActionButton(
                label: 'BAYAR',
                isLoading: state.isProcessing,
                onTap: _showPaymentDialog,
              ),
              const SizedBox(height: 8),
              buildOrderActionsPanel(state.isProcessing),
            ] else if (state.currentOrder != null &&
                !state.currentOrder!.isPaid) ...[
              _buildActionButton(
                label: 'BAYAR',
                isLoading: state.isProcessing,
                onTap: _showPaymentDialog,
              ),
              const SizedBox(height: 8),
              buildOrderActionsPanel(state.isProcessing),
            ] else if (state.currentOrder == null && state.cart.isNotEmpty)
              _buildActionButton(
                label: 'BUAT ORDER',
                isLoading: state.isProcessing,
                onTap: () => _controller.createOrder(),
              ),
          ],
        ),
      ),
    );
  }

  /// Baris rincian tagihan (Subtotal / Diskon / Pajak). [signed] menampilkan
  /// tanda +/- sesuai nilai; nilai negatif (diskon) otomatis ditandai minus.
  Widget _billRow(String label, double amount,
      {bool signed = false, Color? color}) {
    final prefix = signed && amount < 0 ? '- ' : (signed && amount > 0 ? '+ ' : '');
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
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

  Widget _buildActionButton({
    required String label,
    required bool isLoading,
    required VoidCallback onTap,
  }) =>
      CashierActionButton(label: label, isLoading: isLoading, onTap: onTap);

  /// Toggle "Aksi Lainnya": sembunyikan/tampilkan aksi sekunder agar daftar
  /// item tak tertutup di layar kecil. TAMBAH & BAYAR tetap selalu terlihat.

  Widget _categoryChip(String label, bool selected, VoidCallback onTap) =>
      CashierCategoryChip(label: label, selected: selected, onTap: onTap);
}

// ─── Widgets ─────────────────────────────────────────────────────────────────

// ── Tombol Sinkron header: status + animasi berputar saat proses ──
class _SyncButton extends StatefulWidget {
  final bool syncing;
  final ({bool enabled, int pending, bool online})? status;
  final VoidCallback onTap;
  final double width;
  final double height;

  const _SyncButton({
    required this.syncing,
    required this.status,
    required this.onTap,
    this.width = 84,
    this.height = 60,
  });

  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton>
    with SingleTickerProviderStateMixin {
  // Diinisialisasi EAGER di initState (bukan `late` malas) agar createTicker
  // memanggil TickerMode.of(context) saat elemen masih aktif — mencegah lookup
  // ancestor di dispose() yang memicu "deactivated widget's ancestor is unsafe".
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.syncing) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant _SyncButton old) {
    super.didUpdateWidget(old);
    if (widget.syncing && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.syncing && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    // Sync dimatikan di Pengaturan → tombol tampak nonaktif (redup, tak sinkron).
    final disabled = !widget.syncing && (s == null || !s.enabled);
    IconData icon;
    String label;
    Color color = Colors.white;

    if (widget.syncing) {
      icon = Icons.sync_rounded;
      label = 'Menyinkron';
    } else if (s == null || !s.enabled) {
      icon = Icons.cloud_off_rounded;
      label = 'Nonaktif';
      color = Colors.white.withValues(alpha: 0.55);
    } else if (!s.online) {
      icon = Icons.cloud_off_rounded;
      label = s.pending > 0 ? 'Offline ${s.pending}' : 'Offline';
      color = const Color(0xFFFCD34D); // amber terang di atas hijau
    } else if (s.pending > 0) {
      icon = Icons.cloud_upload_rounded;
      label = '${s.pending} Antre';
    } else {
      icon = Icons.cloud_done_rounded;
      label = 'Sinkron';
    }

    final iconWidget = Icon(icon, color: color, size: 22);

    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        // Duduk di dalam bingkai header bersama → tanpa latar & sudut sendiri.
        color: Colors.transparent,
        child: InkWell(
          // Nonaktif → tetap bisa ditekan agar memunculkan petunjuk aktivasi,
          // tapi tampil redup. Saat sedang sinkron → tidak bisa ditekan.
          onTap: widget.syncing ? null : widget.onTap,
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                widget.syncing
                    ? RotationTransition(turns: _spin, child: iconWidget)
                    : iconWidget,
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white
                            .withValues(alpha: disabled ? 0.7 : 1),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VoidTransactionPicker extends StatefulWidget {
  final Future<List<Order>> Function() getPaidOrders;
  final void Function(Order) onPick;
  final String title;
  final IconData icon;
  final String actionLabel;
  const _VoidTransactionPicker({
    required this.getPaidOrders,
    required this.onPick,
    this.title = 'Void Transaksi',
    this.icon = Icons.remove_shopping_cart_outlined,
    this.actionLabel = 'VOID',
  });

  @override
  State<_VoidTransactionPicker> createState() => _VoidTransactionPickerState();
}

class _VoidTransactionPickerState extends State<_VoidTransactionPicker> {
  final _searchCtrl = TextEditingController();
  List<Order>? _orders;
  String _query = '';
  bool _todayOnly = false;

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    final o = await widget.getPaidOrders();
    if (mounted) setState(() => _orders = o);
  }

  String _fmtTime(DateTime t) {
    final l = t.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(l.hour)}:${two(l.minute)}';
    if (l.year == now.year && l.month == now.month && l.day == now.day) {
      return 'Hari ini $hm';
    }
    return '${two(l.day)}/${two(l.month)} $hm';
  }

  bool _isToday(DateTime t) {
    final l = t.toLocal();
    final now = DateTime.now();
    return l.year == now.year && l.month == now.month && l.day == now.day;
  }

  List<Order>? _filtered() {
    final all = _orders;
    if (all == null) return null;
    final q = _query.trim().toLowerCase();
    final qDigits = q.replaceAll(RegExp(r'[^0-9]'), '');
    return all.where((o) {
      if (_todayOnly && !_isToday(o.updatedAt)) return false;
      if (q.isEmpty) return true;
      final byTable = o.tableNumber.toLowerCase().contains(q);
      final byAmount = qDigits.isNotEmpty &&
          o.totalAmount.toStringAsFixed(0).contains(qDigits);
      return byTable || byAmount;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final all = _orders;
    final filtered = _filtered();
    final total =
        filtered?.fold(0.0, (s, o) => s + o.totalAmount) ?? 0;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
          maxWidth: 540,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.soft(AppColors.danger, 0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(widget.icon,
                        color: AppColors.danger, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                        if (filtered != null)
                          Text(
                            '${filtered.length} transaksi • ${CurrencyHelper.format(total)}',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textTertiary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _orders == null
                        ? null
                        : () {
                            setState(() => _orders = null);
                            _loadOrders();
                          },
                    icon: const Icon(Icons.refresh, color: AppColors.textTertiary),
                    tooltip: 'Muat ulang',
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            // Search
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Cari meja atau nominal...',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surfaceMuted,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            // Filter chips
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  _filterChip('Semua', !_todayOnly,
                      () => setState(() => _todayOnly = false)),
                  const SizedBox(width: 8),
                  _filterChip('Hari Ini', _todayOnly,
                      () => setState(() => _todayOnly = true)),
                ],
              ),
            ),
            const Divider(height: 1),
            // List
            if (filtered == null)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.moduleKasir),
                ),
              )
            else if (filtered.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search_off,
                          size: 44, color: AppColors.textTertiary),
                      const SizedBox(height: 8),
                      Text(
                        (all?.isEmpty ?? true)
                            ? 'Belum ada transaksi lunas'
                            : 'Tidak ada hasil',
                        style: const TextStyle(color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _txCard(filtered[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.moduleKasir : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.textSecondary,
            )),
      ),
    );
  }

  Widget _txCard(Order o) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => widget.onPick(o),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppColors.soft(AppColors.moduleKasir, 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    o.tableNumber,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: AppColors.moduleKasir),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Meja ${o.tableNumber}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      '${o.basketSize} item • ${_fmtTime(o.updatedAt)}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(CurrencyHelper.format(o.totalAmount),
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.soft(AppColors.danger, 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(widget.actionLabel,
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: AppColors.danger)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoidHistoryDialog extends StatefulWidget {
  final Future<List<Order>> Function() getVoidedOrders;
  const _VoidHistoryDialog({required this.getVoidedOrders});

  @override
  State<_VoidHistoryDialog> createState() => _VoidHistoryDialogState();
}

class _VoidHistoryDialogState extends State<_VoidHistoryDialog> {
  final _searchCtrl = TextEditingController();
  List<Order>? _orders;
  String _query = '';
  bool _todayOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final o = await widget.getVoidedOrders();
    if (mounted) setState(() => _orders = o);
  }

  String _fmtTime(DateTime? t) {
    if (t == null) return '-';
    final l = t.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(l.hour)}:${two(l.minute)}';
    if (l.year == now.year && l.month == now.month && l.day == now.day) {
      return 'Hari ini $hm';
    }
    return '${two(l.day)}/${two(l.month)} $hm';
  }

  bool _isToday(DateTime? t) {
    if (t == null) return false;
    final l = t.toLocal();
    final now = DateTime.now();
    return l.year == now.year && l.month == now.month && l.day == now.day;
  }

  List<Order>? _filtered() {
    final all = _orders;
    if (all == null) return null;
    final q = _query.trim().toLowerCase();
    final qDigits = q.replaceAll(RegExp(r'[^0-9]'), '');
    return all.where((o) {
      if (_todayOnly && !_isToday(o.voidedAt)) return false;
      if (q.isEmpty) return true;
      final byTable = o.tableNumber.toLowerCase().contains(q);
      final byBy = (o.voidedBy ?? '').toLowerCase().contains(q);
      final byReason = (o.voidReason ?? '').toLowerCase().contains(q);
      final byAmount = qDigits.isNotEmpty &&
          o.totalAmount.toStringAsFixed(0).contains(qDigits);
      return byTable || byBy || byReason || byAmount;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final all = _orders;
    final filtered = _filtered();
    final total = filtered?.fold(0.0, (s, o) => s + o.totalAmount) ?? 0;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
          maxWidth: 540,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.soft(AppColors.danger, 0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.history_toggle_off,
                        color: AppColors.danger, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Histori Void',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                        if (filtered != null)
                          Text(
                            '${filtered.length} order • ${CurrencyHelper.format(total)}',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textTertiary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _orders == null
                        ? null
                        : () {
                            setState(() => _orders = null);
                            _load();
                          },
                    icon: const Icon(Icons.refresh, color: AppColors.textTertiary),
                    tooltip: 'Muat ulang',
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            // Search
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Cari meja, kasir, alasan, nominal...',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surfaceMuted,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            // Filter chips
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  _filterChip('Semua', !_todayOnly,
                      () => setState(() => _todayOnly = false)),
                  const SizedBox(width: 8),
                  _filterChip('Hari Ini', _todayOnly,
                      () => setState(() => _todayOnly = true)),
                ],
              ),
            ),
            const Divider(height: 1),
            // List
            if (filtered == null)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.moduleKasir),
                ),
              )
            else if (filtered.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search_off,
                          size: 44, color: AppColors.textTertiary),
                      const SizedBox(height: 8),
                      Text(
                        (all?.isEmpty ?? true)
                            ? 'Belum ada order yang di-void'
                            : 'Tidak ada hasil',
                        style: const TextStyle(color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _voidCard(filtered[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.moduleKasir : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.textSecondary,
            )),
      ),
    );
  }

  Widget _voidCard(Order o) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.soft(AppColors.danger, 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.soft(AppColors.danger, 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                o.tableNumber,
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: AppColors.danger),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Meja ${o.tableNumber}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.soft(AppColors.danger, 0.12),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text('VOID',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: AppColors.danger)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    const Icon(Icons.schedule,
                        size: 12, color: AppColors.textTertiary),
                    const SizedBox(width: 3),
                    Text(_fmtTime(o.voidedAt),
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textTertiary)),
                    const SizedBox(width: 10),
                    const Icon(Icons.person_outline,
                        size: 12, color: AppColors.textTertiary),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(o.voidedBy ?? '-',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textTertiary)),
                    ),
                  ],
                ),
                if ((o.voidReason ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.notes,
                              size: 12, color: AppColors.textTertiary),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              o.voidReason!,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            CurrencyHelper.format(o.totalAmount),
            style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: AppColors.danger,
                decoration: TextDecoration.lineThrough),
          ),
        ],
      ),
    );
  }
}

class _MovementsHistoryDialog extends StatefulWidget {
  final Future<List<CashMovement>> Function() getMovements;
  const _MovementsHistoryDialog({required this.getMovements});

  @override
  State<_MovementsHistoryDialog> createState() =>
      _MovementsHistoryDialogState();
}

class _MovementsHistoryDialogState extends State<_MovementsHistoryDialog> {
  List<CashMovement>? _movements;

  @override
  void initState() {
    super.initState();
    widget.getMovements().then((m) {
      if (mounted) setState(() => _movements = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    final movements = _movements;
    final cashIns =
        movements?.where((m) => m.isCashIn).toList() ?? [];
    final cashOuts =
        movements?.where((m) => !m.isCashIn).toList() ?? [];
    final totalIn = cashIns.fold(0.0, (s, m) => s + m.amount);
    final totalOut = cashOuts.fold(0.0, (s, m) => s + m.amount);

    return Dialog(
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header — tetap di atas
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMuted,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.account_balance_wallet_outlined,
                        color: AppColors.textSecondary, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Riwayat Kas Shift Ini',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                        if (movements != null)
                          Text(
                            '${movements.length} transaksi',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textTertiary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),

            if (movements == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(color: AppColors.moduleKasir),
              )
            else if (movements.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.inbox_outlined,
                        size: 44, color: AppColors.textTertiary),
                    SizedBox(height: 8),
                    Text('Belum ada transaksi kas',
                        style: TextStyle(color: AppColors.textTertiary)),
                  ],
                ),
              )
            else ...[
              // Summary strip — tetap terlihat
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    _chip('Masuk', totalIn, AppColors.moduleKasir),
                    const Spacer(),
                    _chip('Keluar', totalOut, AppColors.danger),
                    const Spacer(),
                    _chip(
                      'Net',
                      totalIn - totalOut,
                      (totalIn - totalOut) >= 0
                          ? AppColors.moduleKasir
                          : AppColors.danger,
                      bold: true,
                    ),
                  ],
                ),
              ),

              const Divider(height: 1, color: AppColors.surfaceMuted),

              // List — Flexible agar scroll saat banyak item
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: movements.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: AppColors.surfaceMuted),
                itemBuilder: (_, i) {
                  final m = movements[i];
                  final isIn = m.isCashIn;
                  final color = isIn
                      ? AppColors.moduleKasir
                      : AppColors.danger;
                  final time =
                      '${m.createdAt.hour.toString().padLeft(2, '0')}:${m.createdAt.minute.toString().padLeft(2, '0')}';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            isIn ? Icons.arrow_downward : Icons.arrow_upward,
                            size: 15,
                            color: color,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(m.counterpartName,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              if (m.note.isNotEmpty)
                                Text(m.note,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textTertiary)),
                              Text(time,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.textTertiary)),
                            ],
                          ),
                        ),
                        Text(
                          '${isIn ? '+' : '-'} ${CurrencyHelper.format(m.amount)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),          // closes Flexible
            ],          // closes else ...[
          ],            // closes Column children
        ),              // closes Column
      ),                // closes ConstrainedBox
    );
  }

  Widget _chip(String label, double amount, Color color,
      {bool bold = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 10, color: AppColors.textTertiary)),
        Text(CurrencyHelper.format(amount),
            style: TextStyle(
              fontSize: 12,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: color,
            )),
      ],
    );
  }
}

// ── Cash Movement Dialog ──────────────────────────────────────────────────────

class _CashMovementDialog extends StatefulWidget {
  final String initialType;
  final Future<void> Function(
      String type, String name, double amount, String note) onSave;

  const _CashMovementDialog({
    required this.initialType,
    required this.onSave,
  });

  @override
  State<_CashMovementDialog> createState() => _CashMovementDialogState();
}

class _CashMovementDialogState extends State<_CashMovementDialog> {
  late String _type;
  final _nameCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  bool get _isOut => _type == 'out';

  Color get _accentColor =>
      _isOut ? AppColors.danger : AppColors.moduleKasir;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _isOut ? Icons.arrow_upward : Icons.arrow_downward,
                    color: _accentColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Kas Non-Penjualan',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: AppColors.textTertiary),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Toggle Masuk / Keluar
            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  _typeBtn('in', 'Kas Masuk', Icons.add_circle_outline),
                  _typeBtn('out', 'Kas Keluar', Icons.remove_circle_outline),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Nama pihak
            TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: _isOut ? 'Keperluan / Penerima' : 'Sumber / Pemberi',
                hintText: _isOut ? 'Contoh: Bayar listrik' : 'Contoh: Setoran modal',
                prefixIcon: const Icon(Icons.person_outline,
                    color: AppColors.textTertiary, size: 20),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _accentColor, width: 2),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(height: 12),

            // Nominal
            TextField(
              controller: _amountCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [RupiahInputFormatter()],
              decoration: InputDecoration(
                labelText: 'Nominal',
                prefixText: 'Rp ',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _accentColor, width: 2),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),

            // Keterangan
            TextField(
              controller: _noteCtrl,
              decoration: InputDecoration(
                labelText: 'Keterangan',
                hintText: _isOut
                    ? 'Wajib diisi untuk kas keluar'
                    : 'Opsional',
                prefixIcon: const Icon(Icons.notes,
                    color: AppColors.textTertiary, size: 20),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _accentColor, width: 2),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(height: 20),

            // Submit
            AppButton(
              label: _isOut ? 'SIMPAN KAS KELUAR' : 'SIMPAN KAS MASUK',
              icon: _isOut ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              accent: _accentColor,
              loading: _saving,
              onPressed: _saving ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeBtn(String type, String label, IconData icon) {
    final selected = _type == type;
    final color =
        type == 'out' ? AppColors.danger : AppColors.moduleKasir;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _type = type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: selected ? Colors.white : AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? Colors.white
                        : AppColors.textSecondary,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final raw = _amountCtrl.text.replaceAll('.', '');
    final amount = double.tryParse(raw) ?? 0;
    final note = _noteCtrl.text.trim();

    if (name.isEmpty || amount <= 0) return;
    if (_isOut && note.isEmpty) return;

    setState(() => _saving = true);
    Navigator.pop(context);
    await widget.onSave(_type, name, amount, note);
  }
}

// All monetary summary fields come from the same report cutoff.
Map<String, double> _reportMethodTotals(Map<String, dynamic> report) {
  final methods = report['by_method'] as Map? ?? const {};
  return {
    for (final method in ['cash', 'card', 'qris', 'transfer'])
      method: ((methods[method] as Map?)?['total'] as num?)?.toDouble() ?? 0,
  };
}

// ── Close Shift Dialog ────────────────────────────────────────────────────────

class CloseShiftDialog extends StatefulWidget {
  final CashierShift activeShift;
  final Future<Map<String, dynamic>> Function() getShiftReport;
  final Future<List<CashMovement>> Function() getShiftMovements;
  final Future<String?> Function() onClose;

  const CloseShiftDialog({
    super.key,
    required this.activeShift,
    required this.getShiftReport,
    required this.getShiftMovements,
    required this.onClose,
  });

  @override
  State<CloseShiftDialog> createState() => _CloseShiftDialogState();
}

class _CloseShiftDialogState extends State<CloseShiftDialog> {
  Map<String, double>? _totals;
  Map<String, dynamic>? _report;
  List<CashMovement> _movements = [];
  bool _loading = true;
  bool _closing = false;
  String? _loadError;
  String? _closeError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() { _loading = true; _loadError = null; });
    Future.wait([
      widget.getShiftMovements(),
      widget.getShiftReport(),
    ]).then((r) {
      if ((r[1] as Map<String, dynamic>).isEmpty) {
        throw Exception('Laporan shift tidak tersedia. Muat ulang.');
      }
      if (mounted) {
        setState(() {
          _movements = r[0] as List<CashMovement>;
          _report = r[1] as Map<String, dynamic>;
          _totals = _reportMethodTotals(_report!);
          _loading = false;
        });
      }
    }).catchError((Object error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Gagal memuat ringkasan: ${error.toString().replaceFirst('Exception: ', '')}';
        });
      }
    });
  }

  String _duration() {
    final d = DateTime.now().difference(widget.activeShift.openedAt);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}j ${m}m' : '${m}m';
  }

  String _timeStr(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final totals = _totals;
    final cashIn = totals?['cash'] ?? 0;
    final cardIn = totals?['card'] ?? 0;
    final qrisIn = totals?['qris'] ?? 0;
    final transferIn = totals?['transfer'] ?? 0;
    final totalPendapatan = (_report?['sales_total'] as num?)?.toDouble() ?? 0;
    // Kas di Laci = ekspektasi kas fisik (modal + tunai + kas masuk − kas
    // keluar), SAMA dengan "KAS SEHARUSNYA" di struk & payload cloud
    // (CashierRepository.getShiftReport → expected_cash). Formula lama
    // (openingCash + cashIn saja) mengabaikan kas masuk/keluar sehingga
    // berbeda dari struk begitu ada catatan kas non-penjualan.
    final kasLaci = (_report?['expected_cash'] as num?)?.toDouble() ??
        (widget.activeShift.openingCash + cashIn);

    final cashIns = _movements.where((m) => m.isCashIn).toList();
    final cashOuts = _movements.where((m) => !m.isCashIn).toList();
    final totalMovIn = cashIns.fold(0.0, (s, m) => s + m.amount);
    final totalMovOut = cashOuts.fold(0.0, (s, m) => s + m.amount);

    return PopScope(
      canPop: !_closing,
      child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.logout,
                        color: AppColors.warning, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Tutup Kasir',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: _closing ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Ringkasan Shift
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('RINGKASAN SHIFT',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textTertiary,
                              letterSpacing: 0.8,
                            )),
                        const Spacer(),
                        if (!_loading)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.soft(AppColors.moduleKasir, 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('Durasi ${_duration()}',
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.moduleKasir,
                                    fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Kasir: ${widget.activeShift.openedBy}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 6),
                    ShiftPeriodSummary(shift: widget.activeShift, report: _report ?? const {}),
                    const SizedBox(height: 12),
                    if (_loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: SizedBox(
                            width: 24, height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppColors.moduleKasir),
                          ),
                        ),
                      )
                    else if (_loadError == null) ...[
                      _row('Kas Awal',
                          CurrencyHelper.format(widget.activeShift.openingCash),
                          isSubtle: true),
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Divider(height: 1, color: AppColors.border)),
                      _row('Tunai', CurrencyHelper.format(cashIn),
                          icon: Icons.money, iconColor: AppColors.moduleKasir),
                      const SizedBox(height: 6),
                      _row('Kartu', CurrencyHelper.format(cardIn),
                          icon: Icons.credit_card,
                          iconColor: AppColors.moduleProduk),
                      const SizedBox(height: 6),
                      _row('QRIS', CurrencyHelper.format(qrisIn),
                          icon: Icons.qr_code,
                          iconColor: AppColors.moduleMeja),
                      const SizedBox(height: 6),
                      _row('Transfer', CurrencyHelper.format(transferIn),
                          icon: Icons.account_balance,
                          iconColor: AppColors.warning),
                      const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Divider(height: 1, color: AppColors.border)),
                      Row(
                        children: [
                          const Text('Total Penjualan Shift',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                          const Spacer(),
                          Text(CurrencyHelper.format(totalPendapatan),
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.moduleKasir)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.successSoft,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppColors.moduleKasir
                                  .withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                                Icons.account_balance_wallet_outlined,
                                size: 16, color: AppColors.moduleKasir),
                            const SizedBox(width: 8),
                            const Text('Kas di Laci',
                                style: TextStyle(
                                    fontSize: 12, color: AppColors.moduleKasir)),
                            const Spacer(),
                            Text(CurrencyHelper.format(kasLaci),
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.moduleKasir)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Diskon / Kompliment / Void (pengawasan — tidak memengaruhi kas)
              if (!_loading && _report != null)
                Builder(builder: (_) {
                  final r = _report!;
                  final dCnt = (r['discount_count'] as num?)?.toInt() ?? 0;
                  final dTot = (r['discount_total'] as num?)?.toDouble() ?? 0;
                  final kCnt = (r['compliment_count'] as num?)?.toInt() ?? 0;
                  final kTot = (r['compliment_total'] as num?)?.toDouble() ?? 0;
                  final vCnt = (r['void_count'] as num?)?.toInt() ?? 0;
                  final vTot = (r['void_total'] as num?)?.toDouble() ?? 0;
                  final hCnt = (r['held_count'] as num?)?.toInt() ?? 0;
                  final hTot = (r['held_total'] as num?)?.toDouble() ?? 0;
                  if (dCnt == 0 && kCnt == 0 && vCnt == 0 && hCnt == 0) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('DISKON / KOMPLIMEN / VOID / TITIPAN',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textTertiary,
                                letterSpacing: 0.8,
                              )),
                          const SizedBox(height: 10),
                          _row('Diskon ($dCnt)', CurrencyHelper.format(dTot),
                              icon: Icons.local_offer_outlined,
                              iconColor: AppColors.accent),
                          const SizedBox(height: 6),
                          _row('Kompliment ($kCnt)',
                              CurrencyHelper.format(kTot),
                              icon: Icons.card_giftcard_outlined,
                              iconColor: AppColors.moduleWaiter),
                          const SizedBox(height: 6),
                          _row('Void ($vCnt)', CurrencyHelper.format(vTot),
                              icon: Icons.block_outlined,
                              iconColor: AppColors.danger),
                          if (hCnt > 0) ...[
                            const SizedBox(height: 6),
                            _row('Titipan blm terjual ($hCnt)',
                                CurrencyHelper.format(hTot),
                                icon: Icons.inventory_2_outlined,
                                iconColor: AppColors.warning),
                          ],
                        ],
                      ),
                    ),
                  );
                }),

              // Kas Non-Penjualan
              if (!_loading && _movements.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                        child: Row(
                          children: [
                            const Text('KAS NON-PENJUALAN',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textTertiary,
                                  letterSpacing: 0.8,
                                )),
                            const Spacer(),
                            Text(
                              'Net: ${CurrencyHelper.format(totalMovIn - totalMovOut)}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: (totalMovIn - totalMovOut) >= 0
                                    ? AppColors.moduleKasir
                                    : AppColors.danger,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: AppColors.border),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                          shrinkWrap: true,
                          children: [
                            if (cashIns.isNotEmpty) ...[
                              _movHeader('Kas Masuk', totalMovIn,
                                  AppColors.moduleKasir),
                              const SizedBox(height: 4),
                              ...cashIns.map(_movItem),
                            ],
                            if (cashOuts.isNotEmpty) ...[
                              if (cashIns.isNotEmpty)
                                const SizedBox(height: 10),
                              _movHeader('Kas Keluar', totalMovOut,
                                  AppColors.danger),
                              const SizedBox(height: 4),
                              ...cashOuts.map(_movItem),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),

              if (_loadError != null) ...[
                Text(_loadError!, key: const Key('shift-load-error'), style: const TextStyle(color: AppColors.danger)),
                TextButton(onPressed: _loading || _closing ? null : _load, child: const Text('Muat Ulang Ringkasan')),
              ],
              if (_closeError != null) ...[
                Text(_closeError!, key: const Key('shift-close-error'), style: const TextStyle(color: AppColors.danger)),
                const SizedBox(height: 12),
              ],
              // Actions
              Row(
                children: [
                  Expanded(
                    child: AppButton.neutral('Batal',
                        onPressed: _closing ? null : () => Navigator.pop(context)),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: AppButton(
                      label: 'TUTUP KASIR',
                      icon: Icons.logout_rounded,
                      accent: AppColors.warning,
                      loading: _closing,
                      onPressed: _closing || _loading || _loadError != null
                          ? null
                          : () async {
                              setState(() { _closing = true; _closeError = null; });
                              String? error;
                              try { error = await widget.onClose(); }
                              catch (e) { error = 'Gagal menutup shift: ${e.toString().replaceFirst('Exception: ', '')}'; }
                              if (!mounted) return;
                              if (error == null) {
                                Navigator.of(this.context).pop();
                              } else {
                                setState(() { _closing = false; _closeError = error; });
                              }
                            },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _row(String label, String value,
      {IconData? icon, Color? iconColor, bool isSubtle = false}) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 6),
        ],
        Text(label,
            style: TextStyle(
                fontSize: 13,
                color: isSubtle
                    ? AppColors.textTertiary
                    : AppColors.textSecondary)),
        const Spacer(),
        Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isSubtle
                    ? AppColors.textTertiary
                    : AppColors.textPrimary)),
      ],
    );
  }

  Widget _movHeader(String label, double total, Color color) {
    return Row(
      children: [
        Container(width: 6, height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        const Spacer(),
        Text(CurrencyHelper.format(total),
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }

  Widget _movItem(CashMovement m) {
    final time = _timeStr(m.createdAt);
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 4),
      child: Row(
        children: [
          Text(time,
              style: const TextStyle(fontSize: 11, color: AppColors.textTertiary)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.counterpartName,
                    style: const TextStyle(fontSize: 12)),
                if (m.note.isNotEmpty)
                  Text(m.note,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textTertiary)),
              ],
            ),
          ),
          Text(CurrencyHelper.format(m.amount),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ── Swap Shift Dialog ─────────────────────────────────────────────────────────

class _SwapShiftDialog extends StatefulWidget {
  final CashierShift activeShift;
  final Future<Map<String, dynamic>> Function() getShiftReport;
  final Future<List<User>> Function() getCashierUsers;
  final Future<List<CashMovement>> Function() getShiftMovements;
  final Future<String?> Function(String handoverTo, double newOpeningCash) onSwap;

  const _SwapShiftDialog({
    required this.activeShift,
    required this.getShiftReport,
    required this.getCashierUsers,
    required this.getShiftMovements,
    required this.onSwap,
  });

  @override
  State<_SwapShiftDialog> createState() => _SwapShiftDialogState();
}

class _SwapShiftDialogState extends State<_SwapShiftDialog> {
  Map<String, double>? _totals;
  Map<String, dynamic>? _report;
  List<User> _users = [];
  List<CashMovement> _movements = [];
  bool _loading = true;
  bool _submitting = false;
  String? _loadError;
  String? _submitError;
  bool _cashEmpty = false;
  String _handoverName = '';
  final _cashCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() { _loading = true; _loadError = null; });
    Future.wait([
      widget.getCashierUsers(),
      widget.getShiftMovements(),
      widget.getShiftReport(),
    ]).then((results) {
      if ((results[2] as Map<String, dynamic>).isEmpty) {
        throw Exception('Laporan shift tidak tersedia. Muat ulang.');
      }
      if (mounted) {
        final report = results[2] as Map<String, dynamic>;
        setState(() {
          _totals = _reportMethodTotals(report);
          _users = results[0] as List<User>;
          _movements = results[1] as List<CashMovement>;
          _report = report;
          _loading = false;
        });
        // Pra-isi dengan kas seharusnya (modal + tunai + kas masuk − keluar)
        // agar saldo tetap terbawa benar bila kasir tak mengubah nilainya —
        // sebelumnya field kosong tersubmit sebagai 0 (modal shift baru
        // hilang & struk mencetak selisih "Kurang" palsu sebesar ekspektasi).
        // Ekspektasi negatif (mis. banyak refund void) di-clamp ke 0: kas
        // fisik dihitung tak mungkin minus, dan formatInput menstrip tanda
        // minus sehingga -50.000 akan tampil keliru sebagai 50.000.
        final expected = (report['expected_cash'] as num?)?.toDouble() ?? 0;
        _cashCtrl.text =
            CurrencyHelper.formatInput(expected < 0 ? 0 : expected.round());
      }
    }).catchError((Object error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Gagal memuat ringkasan: ${error.toString().replaceFirst('Exception: ', '')}';
        });
      }
    });
  }

  @override
  void dispose() {
    _cashCtrl.dispose();
    super.dispose();
  }

  String _duration() {
    final d = DateTime.now().difference(widget.activeShift.openedAt);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}j ${m}m';
    return '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final totals = _totals;
    final cashIn = totals?['cash'] ?? 0;
    final cardIn = totals?['card'] ?? 0;
    final qrisIn = totals?['qris'] ?? 0;
    final transferIn = totals?['transfer'] ?? 0;
    final totalPendapatan = (_report?['sales_total'] as num?)?.toDouble() ?? 0;
    // Sama dengan expected_cash di CashierRepository.getShiftReport (modal +
    // tunai + kas masuk − kas keluar) — konsisten dengan struk & payload cloud.
    final kasLaci = (_report?['expected_cash'] as num?)?.toDouble() ??
        (widget.activeShift.openingCash + cashIn);

    return PopScope(
      canPop: !_submitting,
      child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.soft(AppColors.moduleKasir, 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.swap_horiz,
                        color: AppColors.moduleKasir, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Ganti Shift',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: _submitting ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Ringkasan Shift ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('RINGKASAN SHIFT',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textTertiary,
                              letterSpacing: 0.8,
                            )),
                        const Spacer(),
                        if (!_loading)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.soft(AppColors.moduleKasir, 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Durasi ${_duration()}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.moduleKasir,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Kasir: ${widget.activeShift.openedBy}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 6),
                    ShiftPeriodSummary(shift: widget.activeShift, report: _report ?? const {}),
                    const SizedBox(height: 12),

                    if (_loading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: SizedBox(
                            width: 24, height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.moduleKasir,
                            ),
                          ),
                        ),
                      )
                    else if (_loadError == null) ...[
                      _summaryRow('Kas Awal',
                          CurrencyHelper.format(widget.activeShift.openingCash),
                          isSubtle: true),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Divider(height: 1, color: AppColors.border),
                      ),
                      _summaryRow('Tunai',
                          CurrencyHelper.format(cashIn),
                          icon: Icons.money,
                          iconColor: AppColors.moduleKasir),
                      const SizedBox(height: 6),
                      _summaryRow('Kartu',
                          CurrencyHelper.format(cardIn),
                          icon: Icons.credit_card,
                          iconColor: AppColors.moduleProduk),
                      const SizedBox(height: 6),
                      _summaryRow('QRIS',
                          CurrencyHelper.format(qrisIn),
                          icon: Icons.qr_code,
                          iconColor: AppColors.moduleMeja),
                      const SizedBox(height: 6),
                      _summaryRow('Transfer',
                          CurrencyHelper.format(transferIn),
                          icon: Icons.account_balance,
                          iconColor: AppColors.warning),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Divider(height: 1, color: AppColors.border),
                      ),
                      Row(
                        children: [
                          const Text('Total Penjualan Shift',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                          const Spacer(),
                          Text(
                            CurrencyHelper.format(totalPendapatan),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: AppColors.moduleKasir,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.successSoft,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppColors.moduleKasir
                                  .withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.account_balance_wallet_outlined,
                                size: 16, color: AppColors.moduleKasir),
                            const SizedBox(width: 8),
                            const Text('Kas di Laci',
                                style: TextStyle(
                                    fontSize: 12, color: AppColors.moduleKasir)),
                            const Spacer(),
                            Text(
                              CurrencyHelper.format(kasLaci),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.moduleKasir,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // ── Diskon / Kompliment / Void (pengawasan) ──
              if (!_loading && _report != null)
                Builder(builder: (_) {
                  final r = _report!;
                  final dCnt = (r['discount_count'] as num?)?.toInt() ?? 0;
                  final dTot = (r['discount_total'] as num?)?.toDouble() ?? 0;
                  final kCnt = (r['compliment_count'] as num?)?.toInt() ?? 0;
                  final kTot = (r['compliment_total'] as num?)?.toDouble() ?? 0;
                  final vCnt = (r['void_count'] as num?)?.toInt() ?? 0;
                  final vTot = (r['void_total'] as num?)?.toDouble() ?? 0;
                  final hCnt = (r['held_count'] as num?)?.toInt() ?? 0;
                  final hTot = (r['held_total'] as num?)?.toDouble() ?? 0;
                  if (dCnt == 0 && kCnt == 0 && vCnt == 0 && hCnt == 0) {
                    return const SizedBox.shrink();
                  }
                  Widget line(
                          IconData ic, Color c, String label, double val) =>
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(children: [
                          Icon(ic, size: 16, color: c),
                          const SizedBox(width: 8),
                          Text(label,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                          const Spacer(),
                          Text(CurrencyHelper.format(val),
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                        ]),
                      );
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('DISKON / KOMPLIMEN / VOID / TITIPAN',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textTertiary,
                                letterSpacing: 0.8,
                              )),
                          line(Icons.local_offer_outlined, AppColors.accent,
                              'Diskon ($dCnt)', dTot),
                          line(Icons.card_giftcard_outlined,
                              AppColors.moduleWaiter, 'Kompliment ($kCnt)', kTot),
                          line(Icons.block_outlined, AppColors.danger,
                              'Void ($vCnt)', vTot),
                          if (hCnt > 0)
                            line(Icons.inventory_2_outlined, AppColors.warning,
                                'Titipan blm terjual ($hCnt)', hTot),
                        ],
                      ),
                    ),
                  );
                }),

              // ── Kas Non-Penjualan ──
              if (!_loading && _movements.isNotEmpty) ...[
                const SizedBox(height: 12),
                _movementsSection(),
              ],

              const SizedBox(height: 16),

              // ── Shift Baru ──
              const Text('SHIFT BARU',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textTertiary,
                    letterSpacing: 0.8,
                  )),
              const SizedBox(height: 10),
              Autocomplete<User>(
                displayStringForOption: (u) => u.fullName,
                optionsBuilder: (textEditingValue) {
                  final q = textEditingValue.text.toLowerCase();
                  final currentName =
                      widget.activeShift.openedBy.toLowerCase();
                  final filtered = _users.where(
                      (u) => u.fullName.toLowerCase() != currentName);
                  if (q.isEmpty) return filtered;
                  return filtered.where(
                      (u) => u.fullName.toLowerCase().contains(q));
                },
                onSelected: (u) =>
                    setState(() => _handoverName = u.fullName),
                fieldViewBuilder:
                    (ctx, fieldCtrl, focusNode, onFieldSubmit) {
                  fieldCtrl.addListener(
                      () => _handoverName = fieldCtrl.text);
                  return TextField(
                    controller: fieldCtrl,
                    focusNode: focusNode,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: 'Nama Kasir Baru',
                      hintText: 'Cari atau ketik nama...',
                      prefixIcon: const Icon(Icons.person_outline,
                          color: AppColors.textTertiary, size: 20),
                      suffixIcon: const Icon(Icons.arrow_drop_down,
                          color: AppColors.textTertiary),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.moduleKasir, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                    ),
                  );
                },
                optionsViewBuilder: (ctx, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (_, i) {
                            final user = options.elementAt(i);
                            return InkWell(
                              onTap: () => onSelected(user),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 14,
                                      backgroundColor: AppColors.soft(AppColors.moduleKasir, 0.14),
                                      child: Text(
                                        user.fullName[0].toUpperCase(),
                                        style: const TextStyle(
                                          color: AppColors.moduleKasir,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(user.fullName,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13)),
                                          Text(user.role,
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color: AppColors.textTertiary)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cashCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [RupiahInputFormatter()],
                onChanged: (_) {
                  if (_cashEmpty) setState(() => _cashEmpty = false);
                },
                decoration: InputDecoration(
                  labelText: 'Kas Awal Shift Baru',
                  prefixText: 'Rp ',
                  prefixIcon: const Icon(Icons.money,
                      color: AppColors.textTertiary, size: 20),
                  errorText: _cashEmpty ? 'Wajib diisi' : null,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: AppColors.moduleKasir, width: 2),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 14),
                ),
              ),
              const SizedBox(height: 20),

              if (_loadError != null) ...[
                Text(_loadError!, style: const TextStyle(color: AppColors.danger)),
                TextButton(onPressed: _loading || _submitting ? null : _load, child: const Text('Muat Ulang Ringkasan')),
              ],
              if (_submitError != null) ...[
                Text(_submitError!, style: const TextStyle(color: AppColors.danger)),
                const SizedBox(height: 12),
              ],
              // ── Actions ──
              Row(
                children: [
                  Expanded(
                    child: AppButton.neutral('Batal',
                        onPressed: _submitting ? null : () => Navigator.pop(context)),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: AppButton(
                      label: 'GANTI SHIFT',
                      icon: Icons.swap_horiz_rounded,
                      accent: AppColors.moduleKasir,
                      loading: _submitting,
                      onPressed: _submitting || _loading || _loadError != null
                          ? null
                          : () async {
                              final name = _handoverName.trim();
                              if (name.isEmpty) return;
                              final raw =
                                  _cashCtrl.text.replaceAll('.', '');
                              // Field sudah dipra-isi dengan kas seharusnya;
                              // kosong hanya bila kasir sengaja menghapusnya —
                              // wajibkan diisi, jangan diam-diam kirim 0
                              // (modal shift baru & carry-over tidak boleh 0
                              // tanpa sepengetahuan kasir).
                              if (raw.isEmpty) {
                                setState(() => _cashEmpty = true);
                                return;
                              }
                              final cash = double.tryParse(raw) ?? 0;
                              setState(() { _submitting = true; _submitError = null; });
                              String? error;
                              try { error = await widget.onSwap(name, cash); }
                              catch (e) { error = 'Gagal mengganti shift: ${e.toString().replaceFirst('Exception: ', '')}'; }
                              if (!mounted) return;
                              if (error == null) {
                                Navigator.of(this.context).pop();
                              } else {
                                setState(() { _submitting = false; _submitError = error; });
                              }
                            },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _movementsSection() {
    final cashIns = _movements.where((m) => m.isCashIn).toList();
    final cashOuts = _movements.where((m) => !m.isCashIn).toList();
    final totalIn = cashIns.fold(0.0, (s, m) => s + m.amount);
    final totalOut = cashOuts.fold(0.0, (s, m) => s + m.amount);
    final allItems = <Widget>[];

    if (cashIns.isNotEmpty) {
      allItems.add(_movGroupHeader(
          'Kas Masuk', totalIn, AppColors.moduleKasir));
      allItems.add(const SizedBox(height: 4));
      allItems.addAll(cashIns.map(_movRow));
    }
    if (cashOuts.isNotEmpty) {
      if (allItems.isNotEmpty) allItems.add(const SizedBox(height: 10));
      allItems.add(_movGroupHeader(
          'Kas Keluar', totalOut, AppColors.danger));
      allItems.add(const SizedBox(height: 4));
      allItems.addAll(cashOuts.map(_movRow));
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header tetap (tidak ikut scroll)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                const Text('KAS NON-PENJUALAN',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textTertiary,
                      letterSpacing: 0.8,
                    )),
                const Spacer(),
                Text(
                  'Net: ${CurrencyHelper.format(totalIn - totalOut)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: (totalIn - totalOut) >= 0
                        ? AppColors.moduleKasir
                        : AppColors.danger,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          // List scrollable dengan maxHeight
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              shrinkWrap: true,
              itemCount: allItems.length,
              itemBuilder: (_, i) => allItems[i],
            ),
          ),
        ],
      ),
    );
  }

  Widget _movGroupHeader(String label, double total, Color color) {
    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration:
              BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color)),
        const Spacer(),
        Text(CurrencyHelper.format(total),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color)),
      ],
    );
  }

  Widget _movRow(CashMovement m) {
    final time =
        '${m.createdAt.hour.toString().padLeft(2, '0')}:${m.createdAt.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 4),
      child: Row(
        children: [
          Text(time,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textTertiary)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.counterpartName,
                    style: const TextStyle(fontSize: 12)),
                if (m.note.isNotEmpty)
                  Text(m.note,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textTertiary)),
              ],
            ),
          ),
          Text(CurrencyHelper.format(m.amount),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value,
      {IconData? icon, Color? iconColor, bool isSubtle = false}) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: iconColor ?? AppColors.textTertiary),
          const SizedBox(width: 6),
        ],
        Text(label,
            style: TextStyle(
              fontSize: 13,
              color: isSubtle
                  ? AppColors.textTertiary
                  : AppColors.textSecondary,
            )),
        const Spacer(),
        Text(value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isSubtle
                  ? AppColors.textTertiary
                  : AppColors.textPrimary,
            )),
      ],
    );
  }
}

// ── Payment Sheet ─────────────────────────────────────────────────────────────


// ── Split Bill (pilih item per orang) ─────────────────────────────────────────
