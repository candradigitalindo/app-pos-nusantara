import 'package:flutter/material.dart';

import '../../controllers/cashier_controller.dart';
import '../../controllers/transactions_controller.dart';
import '../../services/app_events.dart';
import '../../models/models.dart';
import '../../services/qris_service.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/pin_auth_dialog.dart';
import '../../widgets/qris_payment_dialog.dart';
import '../../widgets/ui/ui.dart';
import '../cashier/cashier_order_actions.dart';
import '../cashier/cashier_widgets.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen>
    with AppEventsRefresh<TransactionsScreen>,
        CashierOrderActions<TransactionsScreen> {
  late final TransactionsController _controller;
  final _scrollController = ScrollController();

  /// Controller kasir khusus untuk menjalankan AKSI order (Diskon, Kompliment,
  /// Split Bill, Gabung Bayar, Pindah/Gabung Meja, Titipan, Cetak Tagihan) dari
  /// layar ini. Dialognya sama persis dengan layar Kasir karena berasal dari
  /// mixin [CashierOrderActions]; controller ini hanya perlu "menunjuk" order
  /// yang dipilih.
  late final CashierController _actions = CashierController();

  /// Id order yang controller aksinya sudah siap (currentOrder = order itu).
  String? _actionsOrderId;
  bool _preparingActions = false;

  @override
  CashierController get actionsController => _actions;

  /// Pembayaran dari daftar transaksi selalu digerbang PIN — termasuk Split
  /// Bill & Gabung Bayar — karena dilakukan di luar alur kasir.
  @override
  Future<bool> Function()? get paymentGuard => _authorizePaymentAction;

  /// Id transaksi terpilih (dipakai tampilan master-detail di tablet).
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _controller = TransactionsController();
    _controller.addListener(_onStateChanged);
    _controller.loadOrders(reset: true);
    _scrollController.addListener(_onScroll);
    _actions.addListener(_onActionsChanged);
    listenDataChanges();
  }

  /// Data berubah dari perangkat/aksi lain → segarkan daftar & order aksi.
  @override
  void onDataChanged() {
    _controller.loadOrders(reset: true);
    final id = _actionsOrderId;
    if (id != null) {
      _actionsOrderId = null;
      final order = _controller.state.orders
          .where((o) => o.id == id)
          .toList();
      if (order.isNotEmpty) _prepareActions(order.first);
    }
  }

  void _onActionsChanged() {
    if (!mounted) return;
    setState(() {});
    final err = _actions.state.errorMessage;
    if (err != null) {
      _actions.clearError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showAppSnack(context, err, isError: true);
      });
    }
  }

  /// Siapkan controller aksi untuk [order]: muat data kasir lalu tunjuk meja &
  /// order-nya, supaya dialog aksi membaca order yang benar.
  Future<void> _prepareActions(Order order) async {
    if (_actionsOrderId == order.id || _preparingActions) return;
    setState(() {
      _preparingActions = true;
      _actionsOrderId = null;
    });
    try {
      await _actions.loadData();
      final tables = _actions.state.tables
          .where((t) => t.tableNumber == order.tableNumber)
          .toList();
      if (tables.isNotEmpty) {
        _actions.selectTable(tables.first);
        await _actions.loadOrderForTable(order.tableNumber);
      }
      final ready = _actions.state.currentOrder?.id == order.id;
      if (!mounted) return;
      setState(() {
        _preparingActions = false;
        _actionsOrderId = ready ? order.id : null;
      });
    } catch (_) {
      if (mounted) setState(() => _preparingActions = false);
    }
  }

  Future<bool> _authorizePaymentAction() async {
    final auth = await showPinAuthDialog(
      context,
      title: 'Otorisasi Pembayaran',
      actionLabel: 'Lanjutkan',
      actionColor: AppColors.success,
      icon: Icons.payments_rounded,
      askReason: false,
      details: {
        'Meja': _actions.state.currentOrder?.tableNumber ?? '-',
        'Sisa tagihan':
            CurrencyHelper.format(_actions.state.currentOrder?.remaining ?? 0),
      },
    );
    if (auth == null || !mounted) return false;
    final by = await _controller.authorize(auth.pin);
    if (!mounted) return false;
    if (by == null) {
      showAppSnack(context, 'PIN salah / tidak berwenang', isError: true);
      return false;
    }
    return true;
  }

  /// Panel "Aksi Lainnya" untuk transaksi BELUM dibayar — tombol & urutannya
  /// sama dengan layar Kasir.
  Widget _actionsPanel(Order order,
      {bool expanded = false, VoidCallback? onToggle}) {
    if (_actionsOrderId != order.id) {
      if (!_preparingActions) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    return buildOrderActionsPanel(_actions.state.isProcessing,
        expanded: expanded, onToggle: onToggle);
  }

  @override
  void deactivate() {
    _controller.removeListener(_onStateChanged);
    super.deactivate();
  }

  @override
  void dispose() {
    cancelDataChanges();
    _controller.dispose();
    _actions.removeListener(_onActionsChanged);
    _actions.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final errorMsg = _controller.state.errorMessage;

    if (errorMsg != null) _controller.clearError();

    if (!mounted) return;
    setState(() {});

    if (errorMsg != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showAppSnack(context, errorMsg, isError: true);
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_controller.state.isLoadingMore &&
        _controller.state.hasMore) {
      _controller.loadMore();
    }
  }

  void _onTapOrder(Order order) {
    // Aksi selalu tertutup dulu saat berpindah transaksi.
    if (order.id != _selectedId) resetOrderActions();
    if (!order.isPaid && !order.isVoided) _prepareActions(order);
    if (context.isTablet) {
      setState(() => _selectedId = order.id);
    } else {
      _showOrderActions(order);
    }
  }

  // ── Aksi transaksi (void & bayar, ber-otoritas PIN) ────────────────────────

  void _showOrderActions(Order order) {
    showAppModal(
      context,
      title: 'Meja ${order.tableNumber}',
      subtitle: _statusText(order),
      icon: Icons.receipt_long_rounded,
      accent: AppColors.moduleTransaksi,
      scrollable: false,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              StatusPill(
                label: _statusLabel(order),
                color: _statusColor(order),
                icon: _statusIcon(order),
              ),
              const Spacer(),
              Text(
                CurrencyHelper.format(order.totalAmount),
                style: AppType.amount.copyWith(
                  color: order.isVoided
                      ? AppColors.textTertiary
                      : AppColors.textPrimary,
                  decoration:
                      order.isVoided ? TextDecoration.lineThrough : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${order.basketSize} item · ${_formatDate(order.createdAt)}',
            style: AppType.caption.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (order.isVoided)
            const _VoidNote()
          else if (!order.isPaid) ...[
            AppButton(
              label: 'Bayar',
              icon: Icons.payments_rounded,
              variant: AppButtonVariant.success,
              onPressed: () {
                Navigator.pop(ctx);
                _showPayDialog(order);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            StatefulBuilder(
              builder: (_, setSheet) => _actionsPanel(
                order,
                onToggle: () => setSheet(toggleOrderActions),
              ),
            ),
          ]
          else
            AppButton(
              label: 'Void Transaksi',
              icon: Icons.block_rounded,
              variant: AppButtonVariant.danger,
              onPressed: () {
                Navigator.pop(ctx);
                _showVoidDialog(order);
              },
            ),
        ],
      ),
    );
  }

  /// Bayar dari daftar transaksi memakai dialog pembayaran yang SAMA PERSIS
  /// dengan layar Kasir ([CashierPaymentSheet]) — metode, jumlah bayar, dan
  /// kembalian tampil identik, jadi kasir tak perlu belajar dua tampilan.
  /// Bedanya hanya satu: pembayaran dari sini tetap butuh otorisasi PIN
  /// Manager/SVP karena dilakukan di luar alur kasir.
  Future<void> _showPayDialog(Order order) async {
    final remaining = order.remaining;
    final amountCtrl = TextEditingController(
      text: CurrencyHelper.formatInput(remaining.round()),
    );
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: CashierPaymentSheet(
          total: remaining,
          controller: amountCtrl,
          onPay: (method, amount) async {
            Navigator.pop(ctx);
            await _processPayment(order, method, amount);
          },
        ),
      ),
    );
  }

  Future<void> _processPayment(
      Order order, String method, double amount) async {
    // QRIS terintegrasi: uang harus terkonfirmasi penyedia SEBELUM pembayaran
    // dicatat — sama seperti kasir. Outlet tanpa gateway lewat begitu saja.
    if (method == 'qris' && !await _confirmQrisPaid(order, amount)) return;
    if (!mounted) return;

    final auth = await showPinAuthDialog(
      context,
      title: 'Otorisasi Pembayaran',
      actionLabel: 'Bayar ${CurrencyHelper.format(amount)}',
      actionColor: AppColors.success,
      icon: Icons.payments_rounded,
      askReason: false,
      details: {
        'Meja': order.tableNumber,
        'Sisa tagihan': CurrencyHelper.format(order.remaining),
        'Metode': _methodLabel(method),
      },
    );
    if (auth == null || !mounted) return;

    final result = await _controller.payOrder(
      orderId: order.id,
      paymentMethod: method,
      paidAmount: amount,
      pin: auth.pin,
    );
    if (!mounted || result == null) return; // error via snackbar _onStateChanged
    final change = (result['change'] as num?)?.toDouble() ?? 0;
    showAppSnack(
      context,
      change > 0
          ? 'Lunas — kembalian ${CurrencyHelper.format(change)} · struk dicetak'
          : 'Lunas — struk dicetak',
    );
  }

  /// Terbitkan QR dan tunggu penyedia mengonfirmasi pembayaran (sama seperti
  /// kasir). Outlet yang belum tersambung gateway tetap boleh lanjut — QRIS-nya
  /// dianggap manual.
  Future<bool> _confirmQrisPaid(Order order, double amount) async {
    final info = await QrisService.instance.info();
    if (info == null || info['enabled'] != true) return true;
    if (!mounted) return false;

    final paid = await showQrisPaymentDialog(
      context,
      orderId: order.id,
      amount: amount,
      description: 'Meja ${order.tableNumber}',
    );
    if (paid == true) return true;

    if (mounted) {
      showAppSnack(context,
          'Pembayaran QRIS belum terkonfirmasi — tidak dicatat',
          isError: true);
    }
    return false;
  }

  String _methodLabel(String method) => const {
        'cash': 'Tunai',
        'card': 'Kartu',
        'qris': 'QRIS',
        'transfer': 'Transfer',
      }[method] ??
      method;

  /// Void transaksi lunas — wajib PIN Manager/SVP (atau PIN void bersama).
  Future<void> _showVoidDialog(Order order) async {
    final auth = await showPinAuthDialog(
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
    if (auth == null || !mounted) return;
    final res = await _controller.voidOrder(
      orderId: order.id,
      pin: auth.pin,
      reason: auth.reason,
    );
    if (!mounted) return;
    if (res == 'ok') {
      showAppSnack(context, 'Transaksi di-void');
    } else if (res == 'invalid_pin') {
      showAppSnack(context, 'PIN salah / tidak berwenang', isError: true);
    } // 'error' → snackbar via _onStateChanged
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final filtered = state.filteredOrders;
    final isTablet = context.isTablet;

    Order? selected;
    if (isTablet && _selectedId != null) {
      for (final o in state.orders) {
        if (o.id == _selectedId) {
          selected = o;
          break;
        }
      }
    }

    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            AppPageHeader(
              title: 'Transaksi',
              subtitle: 'Riwayat & laporan pendapatan',
              icon: Icons.receipt_long_rounded,
              accent: AppColors.moduleTransaksi,
              actions: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: state.isLoading
                      ? const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: AppColors.moduleTransaksi),
                          ),
                        )
                      : AppIconButton(
                          icon: Icons.refresh_rounded,
                          onPressed: () =>
                              _controller.loadOrders(reset: true),
                          filled: true,
                          color: AppColors.moduleTransaksi,
                          tooltip: 'Muat ulang',
                        ),
                ),
              ],
            ),
            Expanded(
              child: isTablet
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                            flex: 3, child: _buildMaster(state, filtered)),
                        const VerticalDivider(
                            width: 1, thickness: 1, color: AppColors.border),
                        Expanded(
                          flex: 2,
                          child: _DetailPanel(
                            order: selected,
                            onPay: _showPayDialog,
                            onVoid: _showVoidDialog,
                            extraActions: selected != null &&
                                    !selected.isPaid &&
                                    !selected.isVoided
                                ? _actionsPanel(selected)
                                : null,
                          ),
                        ),
                      ],
                    )
                  : _buildMaster(state, filtered),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMaster(TransactionsState state, List<Order> filtered) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              context.pagePadX, AppSpacing.md, context.pagePadX, 0),
          child: _RevenueCard(state: state),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
              context.pagePadX, AppSpacing.sm, context.pagePadX, 0),
          child: _FilterControl(
            current: state.filter,
            onChanged: _controller.setFilter,
            counts: {
              'all': state.orders.length,
              'paid': state.paidCount,
              'unpaid': state.unpaidCount,
              'voided': state.voidedCount,
            },
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(child: _listView(state, filtered)),
      ],
    );
  }

  Widget _listView(TransactionsState state, List<Order> filtered) {
    if (state.isLoading && filtered.isEmpty) {
      return const AppLoader(label: 'Memuat transaksi…');
    }
    if (filtered.isEmpty) {
      return EmptyState(
        icon: Icons.receipt_long_rounded,
        title: 'Tidak ada transaksi',
        message: 'Transaksi akan muncul di sini.',
        actionLabel: 'Muat Ulang',
        onAction: () => _controller.loadOrders(reset: true),
        accent: AppColors.moduleTransaksi,
      );
    }
    final isTablet = context.isTablet;
    return RefreshIndicator(
      color: AppColors.moduleTransaksi,
      onRefresh: () => _controller.loadOrders(reset: true),
      child: ListView.separated(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
            context.pagePadX, 0, context.pagePadX, context.pagePadY),
        itemCount: filtered.length + (state.isLoadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs),
        itemBuilder: (context, index) {
          if (index == filtered.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: AppColors.moduleTransaksi),
                ),
              ),
            );
          }
          final order = filtered[index];
          return _OrderCard(
            order: order,
            selected: isTablet && order.id == _selectedId,
            onTap: () => _onTapOrder(order),
          );
        },
      ),
    );
  }
}

// ── Revenue Card ──────────────────────────────────────────────────────────────

class _RevenueCard extends StatelessWidget {
  final TransactionsState state;
  const _RevenueCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final paidColor = Color.lerp(AppColors.success, Colors.white, 0.5)!;
    final unpaidColor = Color.lerp(AppColors.warning, Colors.white, 0.35)!;
    final voidColor = Color.lerp(AppColors.danger, Colors.white, 0.5)!;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.gradientOf(AppColors.moduleTransaksi),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: AppRadius.rXl,
        boxShadow: AppShadows.glow(AppColors.moduleTransaksi, strength: 0.3),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.xs),
                decoration: BoxDecoration(
                  color: AppColors.soft(Colors.white, 0.18),
                  borderRadius: AppRadius.rSm,
                ),
                child: const Icon(Icons.account_balance_wallet_rounded,
                    color: Colors.white, size: 18),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                'Total Pendapatan',
                style: AppType.label
                    .copyWith(color: AppColors.soft(Colors.white, 0.85)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            CurrencyHelper.format(state.totalRevenue),
            style: AppType.amountLg.copyWith(color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _mini('${state.paidCount}', 'Lunas', paidColor),
              const SizedBox(width: AppSpacing.lg),
              _mini('${state.unpaidCount}', 'Belum', unpaidColor),
              const SizedBox(width: AppSpacing.lg),
              _mini('${state.voidedCount}', 'Void', voidColor),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: AppSpacing.xxs),
                decoration: BoxDecoration(
                  color: AppColors.soft(Colors.white, 0.18),
                  borderRadius: AppRadius.rPill,
                ),
                child: Text(
                  '${state.orders.length}${state.hasMore ? '+' : ''} order',
                  style: AppType.caption
                      .copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mini(String value, String label, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: AppType.h3.copyWith(color: color)),
        Text(label,
            style: AppType.caption
                .copyWith(color: AppColors.soft(Colors.white, 0.7))),
      ],
    );
  }
}

// ── Filter Segmented Control ──────────────────────────────────────────────────

class _FilterControl extends StatelessWidget {
  final String current;
  final ValueChanged<String> onChanged;
  final Map<String, int> counts;

  const _FilterControl({
    required this.current,
    required this.onChanged,
    required this.counts,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.xxs),
      child: Row(
        children: [
          _seg('all', 'Semua'),
          _seg('paid', 'Lunas'),
          _seg('unpaid', 'Belum'),
          _seg('voided', 'Void'),
        ],
      ),
    );
  }

  Widget _seg(String value, String label) {
    final selected = current == value;
    final count = counts[value] ?? 0;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            // Segmen aktif ditandai SECONDARY gold (identitas hijau+emas).
            color: selected ? AppColors.accentSoft : Colors.transparent,
            borderRadius: AppRadius.rSm,
            boxShadow: selected ? AppShadows.card : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppType.caption.copyWith(
                  color: selected
                      ? AppColors.accentDark
                      : AppColors.textTertiary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
              if (count > 0)
                Text(
                  '$count',
                  style: AppType.overline.copyWith(
                    color: selected
                        ? AppColors.accentDark
                        : AppColors.textTertiary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Order Card ────────────────────────────────────────────────────────────────

class _OrderCard extends StatelessWidget {
  final Order order;
  final bool selected;
  final VoidCallback? onTap;
  const _OrderCard({required this.order, this.selected = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(order);

    return AppCard(
      onTap: onTap,
      accent: selected ? AppColors.moduleTransaksi : null,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
      child: Row(
        children: [
          IconBadge(icon: _statusIcon(order), color: color, size: 46),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text('Meja ${order.tableNumber}',
                          style: AppType.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    StatusPill(label: _statusLabel(order), color: color),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${order.basketSize} item · ${_formatDate(order.createdAt)}',
                  style: AppType.caption
                      .copyWith(color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                CurrencyHelper.format(order.totalAmount),
                style: AppType.amount.copyWith(
                  fontSize: 16,
                  color: order.isVoided
                      ? AppColors.textTertiary
                      : AppColors.textPrimary,
                  decoration:
                      order.isVoided ? TextDecoration.lineThrough : null,
                ),
              ),
              if (order.pax > 0)
                Text('${order.pax} pax',
                    style: AppType.caption
                        .copyWith(color: AppColors.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Detail Panel (master-detail di tablet) ────────────────────────────────────

class _DetailPanel extends StatelessWidget {
  final Order? order;
  final void Function(Order) onPay;
  final void Function(Order) onVoid;

  /// Panel "Aksi Lainnya" (sama seperti Kasir) untuk transaksi belum dibayar.
  final Widget? extraActions;

  const _DetailPanel({
    required this.order,
    required this.onPay,
    required this.onVoid,
    this.extraActions,
  });

  @override
  Widget build(BuildContext context) {
    final o = order;
    if (o == null) {
      return const EmptyState(
        icon: Icons.touch_app_rounded,
        title: 'Pilih transaksi',
        message: 'Ketuk transaksi di daftar untuk melihat detail & aksinya.',
        accent: AppColors.moduleTransaksi,
      );
    }

    final color = _statusColor(o);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(context.pagePadX, AppSpacing.md,
          context.pagePadX, context.pagePadY),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            accent: color,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconBadge(icon: _statusIcon(o), color: color, size: 52),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Meja ${o.tableNumber}',
                              style: AppType.h2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          if (o.customerName?.isNotEmpty ?? false) ...[
                            const SizedBox(height: 2),
                            Text(o.customerName!,
                                style: AppType.caption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ],
                        ],
                      ),
                    ),
                    StatusPill(
                        label: _statusLabel(o),
                        color: color,
                        icon: _statusIcon(o)),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Total',
                    style: AppType.caption
                        .copyWith(color: AppColors.textTertiary)),
                const SizedBox(height: 2),
                Text(
                  CurrencyHelper.format(o.totalAmount),
                  style: AppType.amountLg.copyWith(
                    color: o.isVoided
                        ? AppColors.textTertiary
                        : AppColors.textPrimary,
                    decoration:
                        o.isVoided ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.md),
                _DetailRow(label: 'Item', value: '${o.basketSize}'),
                if (o.pax > 0) _DetailRow(label: 'Pax', value: '${o.pax}'),
                _DetailRow(label: 'Waktu', value: _formatDate(o.createdAt)),
                if (!o.isPaid && !o.isVoided)
                  _DetailRow(
                    label: 'Sisa',
                    value: CurrencyHelper.format(o.remaining),
                    valueColor: AppColors.danger,
                  ),
                if (o.isVoided) ...[
                  _DetailRow(label: 'Void oleh', value: o.voidedBy ?? '-'),
                  if (o.voidReason?.isNotEmpty ?? false)
                    _DetailRow(label: 'Alasan', value: o.voidReason!),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (o.isVoided)
            const _VoidNote()
          else if (!o.isPaid) ...[
            AppButton(
              label: 'Bayar',
              icon: Icons.payments_rounded,
              variant: AppButtonVariant.success,
              onPressed: () => onPay(o),
            ),
            if (extraActions != null) ...[
              const SizedBox(height: AppSpacing.sm),
              extraActions!,
            ],
          ] else
            AppButton(
              label: 'Void Transaksi',
              icon: Icons.block_rounded,
              variant: AppButtonVariant.danger,
              onPressed: () => onVoid(o),
            ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _DetailRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppType.caption.copyWith(color: AppColors.textTertiary)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: AppType.label
                  .copyWith(color: valueColor ?? AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Void note (info transaksi sudah di-void) ──────────────────────────────────

class _VoidNote extends StatelessWidget {
  const _VoidNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 18, color: AppColors.textTertiary),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text('Transaksi sudah di-void.', style: AppType.bodySm),
          ),
        ],
      ),
    );
  }
}

// ── Status helpers ────────────────────────────────────────────────────────────

Color _statusColor(Order o) {
  if (o.isVoided) return AppColors.textTertiary;
  if (o.isPaid) return AppColors.success;
  if (o.paymentStatus == 'partial') return AppColors.warning;
  return AppColors.danger;
}

String _statusLabel(Order o) {
  if (o.isVoided) return 'VOID';
  if (o.paymentStatus == 'paid') return 'LUNAS';
  if (o.paymentStatus == 'partial') return 'SEBAGIAN';
  return 'BELUM';
}

IconData _statusIcon(Order o) {
  if (o.isVoided) return Icons.cancel_rounded;
  if (o.isPaid) return Icons.check_circle_rounded;
  return Icons.pending_rounded;
}

String _statusText(Order o) {
  if (o.isVoided) {
    final by = o.voidedBy ?? '-';
    final reason =
        (o.voidReason?.isNotEmpty ?? false) ? ' · ${o.voidReason}' : '';
    return 'VOID · $by$reason';
  }
  if (o.isPaid) return 'Lunas';
  return 'Belum lunas · sisa ${CurrencyHelper.format(o.remaining)}';
}

String _formatDate(DateTime dt) {
  final now = DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
  return '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
}
