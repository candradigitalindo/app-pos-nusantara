import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../controllers/station_controller.dart';
import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../services/device_role_service.dart';
import '../../services/printer_service.dart';
import '../../services/receipt_builder.dart';
import '../../services/station_api_client.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/ui/ui.dart';
import '../settings/printer_settings_screen.dart';

/// Layar utama mode Station: pilih meja → menu → kirim order ke Main POS.
class StationScreen extends StatefulWidget {
  /// User login station (opsional) + aksi logout. Diisi saat dirutekan dari
  /// StationGate berdasar peran; null bila dibuka langsung.
  final Map<String, dynamic>? user;
  final VoidCallback? onLogout;

  /// Ganti Main POS: dikelola StationGate (lepas koneksi → setup → login).
  final VoidCallback? onChangeServer;

  const StationScreen(
      {super.key, this.user, this.onLogout, this.onChangeServer});

  @override
  State<StationScreen> createState() => _StationScreenState();
}

class _StationScreenState extends State<StationScreen> {
  final _controller = StationController();

  static const _accent = AppColors.moduleKasir;

  // Auto-logout saat idle (sama seperti Main POS): tak ada interaksi selama
  // _idleSeconds → peringatan _warnSeconds detik → logout sungguhan (bukan
  // sekadar layar terkunci yang bisa dibuka dengan satu ketukan tanpa PIN).
  static const _idleSeconds = 10;
  static const _warnSeconds = 10;
  Timer? _idleTimer;
  bool _warningShown = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChange);
    _controller.init();
    _resetIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _controller.removeListener(_onChange);
    _controller.dispose();
    super.dispose();
  }

  // ── Inactivity ────────────────────────────────────────────────────────────────

  void _resetIdle() {
    _idleTimer?.cancel();
    if (_warningShown) return;
    _idleTimer = Timer(const Duration(seconds: _idleSeconds), _onIdle);
  }

  Future<void> _onIdle() async {
    if (!mounted || _warningShown) return;
    _warningShown = true;
    final stay = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const IdleWarningDialog(seconds: _warnSeconds),
    );
    _warningShown = false;
    if (!mounted) return;
    if (stay == true) {
      _resetIdle(); // waiter masih di sini
    } else {
      _logout(); // waktu habis → logout
    }
  }

  void _logout() {
    _idleTimer?.cancel();
    _controller.goBackToTables(); // bersihkan keranjang sebelum keluar
    widget.onLogout?.call();
  }

  void _onChange() {
    if (!mounted) return;
    final err = _controller.errorMessage;
    final ok = _controller.successMessage;
    if (err != null || ok != null) _controller.clearMessages();
    setState(() {});
    if (err != null || ok != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showAppSnack(context, err ?? ok!, isError: err != null);
      });
    }
  }

  Future<void> _changeServer() async {
    // Serahkan ke StationGate: lepas koneksi & sesi, kembali ke setup → login.
    widget.onChangeServer?.call();
  }

  Future<void> _exitStationMode() async {
    final ok = await showAppConfirm(
      context,
      title: 'Keluar Mode Station?',
      message:
          'Perangkat kembali ke pemilihan peran. Koneksi Main POS yang tersimpan akan dihapus.',
      confirmText: 'Keluar',
      icon: Icons.logout_rounded,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await StationApiClient.instance.clear();
    await DeviceRoleService.instance.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const RootGate()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final inTables = _controller.viewMode == 'tables';
    return Scaffold(
      body: AppBackground(
        child: Listener(
          // Setiap sentuhan mereset timer idle.
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _resetIdle(),
          child: Stack(
            children: [
              Column(
                children: [
                  AppPageHeader(
                    title: _headerTitle(),
                    subtitle: _headerSubtitle(inTables),
                    icon: Icons.room_service_rounded,
                    accent: _accent,
                    showBack: !inTables,
                    onBack: _controller.goBackToTables,
                    actions: inTables ? _tablesActions() : const [],
                  ),
                  Expanded(child: _body()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Subjudul header: petunjuk di daftar meja, dan ringkasan order berjalan
  /// saat sedang menambah item (kasir perlu tahu apa yang sudah dipesan).
  String? _headerSubtitle(bool inTables) {
    if (inTables) return 'Pilih meja untuk mulai pesan';
    if (_controller.viewMode == 'order' && _controller.isAddingToOrder) {
      final order = _controller.currentOrder;
      if (order == null) return null;
      final count = (order['items'] as List?)?.length ?? 0;
      final total = (order['total_amount'] as num?)?.toDouble() ?? 0;
      return 'Sudah dipesan: $count item · ${CurrencyHelper.format(total)}';
    }
    return null;
  }

  String _headerTitle() {
    switch (_controller.viewMode) {
      case 'order':
        return 'Order — Meja ${_controller.selectedTable?['table_number'] ?? ''}';
      case 'detail':
        return 'Detail — Meja ${_controller.selectedTable?['table_number'] ?? ''}';
      default:
        return 'Station — Pesanan';
    }
  }

  List<Widget> _tablesActions() {
    return [
      AppIconButton(
        icon: Icons.refresh_rounded,
        onPressed: _controller.loadTables,
        tooltip: 'Muat ulang',
      ),
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
        onSelected: (v) {
          if (v == 'printer') _openPrinterSettings();
          if (v == 'server') _changeServer();
          if (v == 'exit') _exitStationMode();
          if (v == 'logout') widget.onLogout?.call();
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
              value: 'printer', child: Text('Pengaturan Printer')),
          if (widget.onLogout != null)
            const PopupMenuItem(
                value: 'logout', child: Text('Logout (ganti user)')),
          const PopupMenuItem(value: 'server', child: Text('Ganti Main POS')),
          const PopupMenuItem(value: 'exit', child: Text('Keluar Mode Station')),
        ],
      ),
    ];
  }

  Widget _body() {
    switch (_controller.viewMode) {
      case 'order':
        return _orderView();
      case 'detail':
        return _detailView();
      default:
        return _tablesView();
    }
  }

  // ── Tables ──────────────────────────────────────────────────────────────────

  Widget _tablesView() {
    if (_controller.isLoading && _controller.tables.isEmpty) {
      return const AppLoader(label: 'Memuat meja...');
    }
    if (_controller.tables.isEmpty) {
      return const EmptyState(
        icon: Icons.table_restaurant_rounded,
        title: 'Tidak ada meja',
        message: 'Belum ada meja yang tersedia dari Main POS.',
        accent: _accent,
      );
    }
    return RefreshIndicator(
      onRefresh: _controller.loadTables,
      child: GridView.builder(
        padding: context.pagePadding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: context.gridColumns(minTileWidth: 150),
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          childAspectRatio: 1,
        ),
        itemCount: _controller.tables.length,
        itemBuilder: (_, i) {
          final t = _controller.tables[i];
          final available = t['status'] == 'available';
          final order = t['active_order'];
          final color = available ? AppColors.success : AppColors.warning;
          return AppCard(
            onTap: () => available
                ? _controller.selectTableForOrder(t)
                : _controller.viewOrderDetail(t),
            accent: color,
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconBadge(
                    icon: Icons.table_restaurant_rounded, color: color, size: 44),
                const SizedBox(height: AppSpacing.xs),
                Text('${t['table_number']}',
                    style: AppType.h3, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.xxs),
                StatusPill(
                  label: available ? 'Tersedia' : 'Terisi',
                  color: color,
                  icon: available
                      ? Icons.check_circle_outline_rounded
                      : Icons.people_alt_rounded,
                ),
                if (order is Map && order['total_amount'] != null) ...[
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    CurrencyHelper.format((order['total_amount'] as num).toDouble()),
                    style: AppType.caption.copyWith(color: AppColors.textTertiary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Order (menu + cart) ───────────────────────────────────────────────────────

  Widget _orderView() {
    // Default: tampilan seperti POS utama (Kasir) — dua panel: menu | kolom
    // pesanan samping. Menyesuaikan ukuran layar: pada layar kecil (ponsel)
    // jatuh ke layout ringkas (menu + cart bar bawah + sheet).
    return LayoutBuilder(
      builder: (context, constraints) {
        final menu = Column(
          children: [
            _categoryBar(),
            Expanded(child: _productGrid()),
          ],
        );
        if (constraints.maxWidth < 600) {
          return Column(
            children: [
              Expanded(child: menu),
              if (_controller.cart.isNotEmpty)
                _cartBar(isAdd: _controller.isAddingToOrder),
            ],
          );
        }
        // Lebar kolom pesanan disamakan dengan Kasir (proporsional 30%, 300–440).
        final cartWidth =
            (constraints.maxWidth * 0.30).clamp(300.0, 440.0);
        return Row(
          children: [
            Expanded(child: menu),
            _stationCartPanel(
                width: cartWidth, isAdd: _controller.isAddingToOrder),
          ],
        );
      },
    );
  }

  /// Kolom pesanan samping (layar besar) — meniru panel keranjang POS utama:
  /// header, daftar item, lalu total + tombol Kirim/Tambah di bawah.
  Widget _stationCartPanel({required double width, required bool isAdd}) {
    final empty = _controller.cart.isEmpty;
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                const Icon(Icons.shopping_cart_rounded,
                    color: _accent, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Text(isAdd ? 'Tambah Item' : 'Pesanan', style: AppType.title),
                const Spacer(),
                Text('${_controller.cartItemCount} item',
                    style: AppType.caption
                        .copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
          Expanded(
            child: isAdd
                ? ListView(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    children: [
                      _existingOrderSummary(),
                      const SizedBox(height: AppSpacing.sm),
                      const SectionHeader('Item Baru'),
                      if (empty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.md),
                          child: Text(
                            'Pilih menu untuk menambah item ke order ini.',
                            textAlign: TextAlign.center,
                            style: AppType.caption
                                .copyWith(color: AppColors.textTertiary),
                          ),
                        )
                      else
                        ..._controller.cart.entries.map(_cartItemRow),
                    ],
                  )
                : empty
                    ? const EmptyState(
                        icon: Icons.shopping_cart_outlined,
                        title: 'Keranjang kosong',
                        message: 'Pilih menu untuk memulai pesanan.',
                        accent: _accent,
                      )
                    : ListView(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        children:
                            _controller.cart.entries.map(_cartItemRow).toList(),
                      ),
          ),
          if (!empty)
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Total', style: AppType.body),
                        Text(CurrencyHelper.format(_controller.cartTotal),
                            style: AppType.amount.copyWith(color: _accent)),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton(
                      label: isAdd ? 'TAMBAH' : 'KIRIM',
                      icon: isAdd ? Icons.add_rounded : Icons.send_rounded,
                      accent: _accent,
                      loading: _controller.isProcessing,
                      onPressed: _controller.isProcessing
                          ? null
                          : () => _submitWithPin(isAdd),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Ringkasan item yang SUDAH masuk ke order aktif — tampil saat mode tambah
  /// item supaya penambah tahu apa yang sudah dipesan sebelumnya.
  Widget _existingOrderSummary() {
    final order = _controller.currentOrder;
    if (order == null) return const SizedBox.shrink();
    final items = (order['items'] as List?) ?? const [];
    final total = (order['total_amount'] as num?)?.toDouble() ?? 0;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: AppRadius.rSm,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_rounded,
                  size: 16, color: AppColors.textTertiary),
              const SizedBox(width: AppSpacing.xs),
              Text('Pesanan Sebelumnya',
                  style:
                      AppType.label.copyWith(color: AppColors.textSecondary)),
              const Spacer(),
              Text('${items.length} item',
                  style: AppType.caption
                      .copyWith(color: AppColors.textTertiary)),
            ],
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text('Belum ada item terkirim.',
                  style: AppType.caption
                      .copyWith(color: AppColors.textTertiary)),
            )
          else
            ...items.map((it) {
              final m = it as Map;
              final qty = (m['qty'] as num?)?.toInt() ?? 0;
              final price = (m['price'] as num?)?.toDouble() ?? 0;
              final notes = m['notes'] as String?;
              final status = m['item_status'] as String? ?? '';
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 30,
                      child: Text('${qty}x',
                          style: AppType.caption.copyWith(
                              color: _accent, fontWeight: FontWeight.w700)),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(m['product_name'] as String? ?? '',
                              style: AppType.bodySm,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          if (notes?.isNotEmpty == true)
                            Text(notes!,
                                style: AppType.caption
                                    .copyWith(color: AppColors.textTertiary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    if (status.isNotEmpty) ...[
                      const SizedBox(width: AppSpacing.xxs),
                      Text(status,
                          style: AppType.caption
                              .copyWith(color: _statusColor(status))),
                    ],
                    const SizedBox(width: AppSpacing.xs),
                    Text(CurrencyHelper.format(qty * price),
                        style: AppType.caption
                            .copyWith(color: AppColors.textSecondary)),
                  ],
                ),
              );
            }),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Divider(height: 1, color: AppColors.border),
          ),
          Row(
            children: [
              Text('Total sebelumnya', style: AppType.caption),
              const Spacer(),
              Text(CurrencyHelper.format(total),
                  style: AppType.label.copyWith(color: AppColors.textPrimary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _categoryBar() {
    return Container(
      height: 54,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        children: [
          _catChip('Semua', _controller.selectedCategory == null,
              () => _controller.selectCategory(null)),
          ..._controller.categories.map((cat) => _catChip(
                cat.name,
                _controller.selectedCategory?.id == cat.id,
                () => _controller.selectCategory(cat),
              )),
        ],
      ),
    );
  }

  Widget _catChip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            // SECONDARY gold untuk kategori terpilih (aksentuasi sekunder).
            color: selected ? AppColors.accentSoft : AppColors.surfaceMuted,
            borderRadius: AppRadius.rPill,
            border: Border.all(
                color: selected ? AppColors.accent : AppColors.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: selected ? AppColors.accentDark : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _productGrid() {
    if (_controller.isLoading && _controller.products.isEmpty) {
      return const AppLoader(label: 'Memuat produk...');
    }
    if (_controller.products.isEmpty) {
      return const EmptyState(
        icon: Icons.restaurant_menu_rounded,
        title: 'Tidak ada produk',
        message: 'Belum ada produk pada kategori ini.',
        accent: _accent,
      );
    }
    return GridView.builder(
      padding: context.pagePadding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: context.gridColumns(minTileWidth: 200),
        mainAxisSpacing: AppSpacing.sm,
        crossAxisSpacing: AppSpacing.sm,
        childAspectRatio: 1.9,
      ),
      itemCount: _controller.products.length,
      itemBuilder: (_, i) {
        final p = _controller.products[i];
        final inCart = _controller.cart[p.id] ?? 0;
        final active = inCart > 0;
        return AppCard(
          onTap: () => _controller.addToCart(p),
          accent: active ? _accent : null,
          color: active ? AppColors.soft(_accent, 0.08) : null,
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Flexible + jarak kecil: nama 2 baris (mis. "Nasi Goreng
              // Spesial") tak lagi melewati tinggi kartu.
              Flexible(
                child: Text(p.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.title),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      CurrencyHelper.format(p.price),
                      style: AppType.label.copyWith(color: _accent),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (active)
                    StatusPill(label: '$inCart', color: _accent, solid: true),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _cartBar({required bool isAdd}) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
          boxShadow: AppShadows.card,
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _showCartSheet,
                behavior: HitTestBehavior.opaque,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${_controller.cartItemCount} item · ketuk lihat',
                        style: AppType.caption
                            .copyWith(color: AppColors.textTertiary)),
                    Text(CurrencyHelper.format(_controller.cartTotal),
                        style: AppType.amount.copyWith(color: _accent)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 160,
              child: AppButton(
                label: isAdd ? 'TAMBAH' : 'KIRIM',
                icon: isAdd ? Icons.add_rounded : Icons.send_rounded,
                accent: _accent,
                loading: _controller.isProcessing,
                onPressed: _controller.isProcessing
                    ? null
                    : () => _submitWithPin(isAdd),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Minta PIN waiter dulu, lalu kirim order / tambah item dengan namanya.
  Future<void> _submitWithPin(bool isAdd) async {
    final name = await _showWaiterPinDialog();
    if (name == null || !mounted) return;
    if (isAdd) {
      await _controller.submitAddItems(waiterName: name);
    } else {
      await _controller.submitOrder(waiterName: name);
    }
  }

  /// Dialog PIN: verifikasi ke Main POS, kembalikan nama waiter (atau null).
  ///
  /// Timer idle dijeda selama dialog terbuka — sentuhan di dalam dialog tak
  /// sampai ke Listener layar, jadi tanpa ini waiter bisa ter-logout justru
  /// saat sedang mengetik PIN.
  Future<String?> _showWaiterPinDialog() async {
    _idleTimer?.cancel();
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _WaiterPinDialog(controller: _controller),
    );
    _resetIdle();
    return name;
  }

  /// Dialog catatan item di keranjang (mis. "tanpa sambal", "level 2").
  Future<void> _showItemNoteDialog(
      String productId, String productName, String current) async {
    final ctrl = TextEditingController(text: current);
    final result = await showAppModal<String>(
      context,
      title: 'Catatan Item',
      subtitle: productName,
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
            maxLength: 100,
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            decoration: const InputDecoration(
              hintText: 'mis. tanpa sambal, level 2, pisah es',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              if (current.isNotEmpty) ...[
                Expanded(
                  child: AppButton(
                    label: 'Hapus',
                    icon: Icons.delete_outline_rounded,
                    variant: AppButtonVariant.danger,
                    onPressed: () => Navigator.pop(ctx, ''),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: AppButton(
                  label: 'Simpan',
                  accent: _accent,
                  onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (result == null) return; // batal
    _controller.setNote(productId, result);
  }

  /// Baris satu item keranjang — dipakai di panel samping (layar besar) &
  /// bottom-sheet (layar kecil) agar konsisten.
  Widget _cartItemRow(MapEntry<String, int> e) {
    final p = _controller.productCache[e.key];
    if (p == null) return const SizedBox.shrink();
    final note = _controller.cartNotes[e.key] ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            // Tombol catatan paling depan (sebelum item) agar jauh dari +/−.
            AppIconButton(
              icon: note.isNotEmpty
                  ? Icons.edit_note_rounded
                  : Icons.note_add_outlined,
              onPressed: () => _showItemNoteDialog(e.key, p.name, note),
              color: note.isNotEmpty ? _accent : AppColors.textTertiary,
              tooltip: 'Catatan item',
              size: 44,
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(p.name, style: AppType.title),
                  const SizedBox(height: 2),
                  Text(CurrencyHelper.format(p.price * e.value),
                      style: AppType.bodySm),
                  if (note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('📝 $note',
                          style: AppType.caption.copyWith(
                              fontStyle: FontStyle.italic,
                              color: AppColors.textTertiary)),
                    ),
                ],
              ),
            ),
            AppIconButton(
              icon: Icons.remove_circle_outline_rounded,
              onPressed: () => _controller.removeFromCart(e.key),
              color: AppColors.textSecondary,
              size: 44,
            ),
            Text('${e.value}',
                style: AppType.title, textAlign: TextAlign.center),
            AppIconButton(
              icon: Icons.add_circle_rounded,
              onPressed: () => _controller.addToCart(p),
              color: _accent,
              size: 44,
            ),
          ],
        ),
      ),
    );
  }

  void _showCartSheet() {
    final isAdd = _controller.isAddingToOrder;
    showAppModal(
      context,
      title: isAdd ? 'Tambah Item' : 'Pesanan',
      icon: Icons.shopping_cart_rounded,
      accent: _accent,
      builder: (_) => ListenableBuilder(
        listenable: _controller,
        builder: (_, __) {
          final cartRows = _controller.cart.isEmpty
              ? [
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                    child: Text('Keranjang kosong',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.textTertiary)),
                  )
                ]
              : _controller.cart.entries.map(_cartItemRow).toList();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isAdd) ...[
                _existingOrderSummary(),
                const SizedBox(height: AppSpacing.sm),
                const SectionHeader('Item Baru'),
              ],
              ...cartRows,
            ],
          );
        },
      ),
    );
  }

  // ── Detail (order aktif + tambah item) ─────────────────────────────────────────

  Widget _detailView() {
    if (_controller.isLoading) {
      return const AppLoader(label: 'Memuat order...');
    }
    final order = _controller.currentOrder;
    if (order == null) {
      return const EmptyState(
        icon: Icons.receipt_long_rounded,
        title: 'Order tidak ditemukan',
        accent: _accent,
      );
    }
    final items = (order['items'] as List?) ?? [];

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: context.pagePadding,
            children: [
              AppCard(
                accent: _accent,
                child: Row(
                  children: [
                    const IconBadge(
                        icon: Icons.table_restaurant_rounded,
                        color: _accent,
                        size: 48,
                        filled: true),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Meja ${order['table_number']}',
                              style: AppType.h3),
                          const SizedBox(height: 2),
                          Text('Total pesanan', style: AppType.caption),
                        ],
                      ),
                    ),
                    Text(
                      CurrencyHelper.format(
                          (order['total_amount'] as num?)?.toDouble() ?? 0),
                      style: AppType.amount.copyWith(color: _accent),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              const SectionHeader('Item Pesanan'),
              ...items.map((it) {
                final m = it as Map;
                final status = m['item_status'] as String? ?? '';
                final notes = m['notes'] as String?;
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.soft(_accent, 0.12),
                            borderRadius: AppRadius.rSm,
                          ),
                          child: Text('${m['qty']}x',
                              style: AppType.label.copyWith(color: _accent)),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(m['product_name'] as String? ?? '',
                                  style: AppType.body,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              if (notes?.isNotEmpty == true)
                                Text(notes!,
                                    style: AppType.caption
                                        .copyWith(color: AppColors.textTertiary),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        if (status.isNotEmpty) ...[
                          const SizedBox(width: AppSpacing.xs),
                          StatusPill(label: status, color: _statusColor(status)),
                        ],
                        IconButton(
                          icon: const Icon(Icons.more_vert, size: 20),
                          color: AppColors.textTertiary,
                          tooltip: 'Aksi item',
                          onPressed: () => _showDetailItemActions(m),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        // Aksi order: pindah/gabung meja + cetak tagihan + tambah item.
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(context.pagePadX, AppSpacing.sm,
                context.pagePadX, AppSpacing.sm),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        label: 'Pindah Meja',
                        icon: Icons.swap_horiz_rounded,
                        variant: AppButtonVariant.neutral,
                        onPressed: _moveOrderTable,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: AppButton(
                        label: 'Gabung Meja',
                        icon: Icons.call_merge_rounded,
                        variant: AppButtonVariant.neutral,
                        onPressed: _mergeTable,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        label: 'Cetak Tagihan',
                        icon: Icons.receipt_long_outlined,
                        variant: AppButtonVariant.neutral,
                        onPressed: _printBill,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: AppButton(
                        label: 'Tambah Item',
                        icon: Icons.add_shopping_cart_rounded,
                        variant: AppButtonVariant.tonal,
                        accent: _accent,
                        onPressed: _controller.startAddItems,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Aksi item terkirim: Pindah / Titip / Void (per-unit) ────────────────────

  /// Tanya jumlah unit (1..[maxQty]). null = batal. maxQty ≤ 1 → 1 tanpa dialog.
  Future<int?> _askUnitQty(int maxQty, {String title = 'Berapa unit?'}) async {
    if (maxQty <= 1) return 1;
    int qty = maxQty;
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(title, style: const TextStyle(fontSize: 16)),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 36,
                color: _accent,
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: qty > 1 ? () => setD(() => qty--) : null,
              ),
              SizedBox(
                width: 64,
                child: Text('$qty',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 30, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                iconSize: 36,
                color: _accent,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: qty < maxQty ? () => setD(() => qty++) : null,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, qty),
                child: Text('Pilih $qty dari $maxQty')),
          ],
        ),
      ),
    );
  }

  /// Otorisasi manajer: PIN → verifikasi ke Main POS → cek role. Return nama
  /// authorizer, atau null bila batal/gagal/tak berwenang.
  Future<String?> _managerAuth() async {
    _idleTimer?.cancel(); // jangan logout saat manajer sedang mengetik PIN
    final ctrl = TextEditingController();
    final pin = await showAppModal<String>(
      context,
      title: 'Otorisasi Manajer',
      subtitle: 'Masukkan PIN Manager / SVP / Admin',
      icon: Icons.lock_outline,
      accent: _accent,
      scrollable: false,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            decoration: const InputDecoration(
                hintText: 'PIN', border: OutlineInputBorder()),
          ),
          const SizedBox(height: AppSpacing.xs),
          AppButton(
            label: 'Verifikasi',
            accent: _accent,
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          ),
        ],
      ),
    );
    _resetIdle();
    if (pin == null || pin.isEmpty || !mounted) return null;
    final user = await _controller.authPin(pin);
    if (!mounted) return null;
    if (user == null) {
      showAppSnack(context, 'PIN salah', isError: true);
      return null;
    }
    final role = (user['role'] as String?) ?? '';
    if (!AuthService.voidAuthorizedRoles.contains(role)) {
      showAppSnack(context, 'Tidak berwenang (butuh Manager/SVP/Admin)',
          isError: true);
      return null;
    }
    return user['full_name'] as String? ?? 'Manager';
  }

  Future<void> _showDetailItemActions(Map m) async {
    final itemId = m['id'] as String?;
    if (itemId == null) return;
    final maxQty = (m['qty'] as num?)?.toInt() ?? 1;
    final name = m['product_name'] as String? ?? '';
    final choice = await showAppModal<String>(
      context,
      title: '${maxQty}x $name',
      icon: Icons.more_horiz_rounded,
      accent: _accent,
      scrollable: false,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded, color: _accent),
            title: const Text('Pindah ke meja lain'),
            subtitle: const Text('Tanpa cetak dapur ulang'),
            onTap: () => Navigator.pop(ctx, 'move'),
          ),
          ListTile(
            leading:
                const Icon(Icons.inventory_2_outlined, color: AppColors.accent),
            title: const Text('Titip ke Meja Titipan'),
            subtitle: const Text('Perlu PIN manajer'),
            onTap: () => Navigator.pop(ctx, 'titip'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppColors.danger),
            title: const Text('Void item'),
            subtitle: const Text('Perlu PIN manajer'),
            onTap: () => Navigator.pop(ctx, 'void'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    final n = await _askUnitQty(maxQty, title: 'Berapa unit?');
    if (n == null || !mounted) return;

    if (choice == 'void') {
      final by = await _managerAuth();
      if (by == null || !mounted) return;
      final ok = await _controller.voidDetailItem(itemId: itemId, qty: n, by: by);
      _snackResult(ok, 'Item di-void');
    } else if (choice == 'titip') {
      final by = await _managerAuth();
      if (by == null || !mounted) return;
      final ok = await _controller.parkDetailItem(itemId: itemId, qty: n, by: by);
      _snackResult(ok, 'Item dititip ke Meja Titipan');
    } else if (choice == 'move') {
      final target = await _moveTargetPicker();
      if (target == null || !mounted) return;
      final ok = await _controller.moveDetailItem(
          itemId: itemId, qty: n, targetOrderId: target, by: 'Station');
      _snackResult(ok, 'Item dipindah');
    }
  }

  /// Picker order aktif meja lain untuk tujuan pindah item.
  Future<String?> _moveTargetPicker() async {
    final orderId = _controller.currentOrder?['id'] as String?;
    if (orderId == null) return null;
    final orders = await _controller.activeOrdersExcept(orderId);
    if (!mounted) return null;
    if (orders.isEmpty) {
      showAppSnack(context, 'Tidak ada meja lain dengan order aktif',
          isError: true);
      return null;
    }
    return showAppModal<String>(
      context,
      title: 'Pindah ke meja:',
      icon: Icons.swap_horiz_rounded,
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
  }

  void _snackResult(bool ok, String okMsg) {
    if (!mounted) return;
    showAppSnack(context, ok ? okMsg : (_controller.errorMessage ?? 'Gagal'),
        isError: !ok);
  }

  // ── Pindah / Gabung Meja (paritas waiter utama) ─────────────────────────────

  /// Pindahkan SELURUH order aktif ke meja kosong lain.
  Future<void> _moveOrderTable() async {
    final empty = _controller.tables
        .where((t) => t['active_order'] == null)
        .toList();
    if (empty.isEmpty) {
      showAppSnack(context, 'Tidak ada meja kosong', isError: true);
      return;
    }
    final target = await showAppModal<String>(
      context,
      title: 'Pindah Order ke Meja',
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
    final ok = await _controller.moveOrderToTable(target);
    _snackResult(ok, 'Order dipindah ke meja $target');
  }

  /// Gabung order meja lain ke order aktif saat ini.
  Future<void> _mergeTable() async {
    final orders = await _controller.mergeableOrders();
    if (!mounted) return;
    if (orders.isEmpty) {
      showAppSnack(context, 'Tidak ada meja lain untuk digabung',
          isError: true);
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
    final ok = await _controller.mergeFrom(source);
    _snackResult(ok, 'Meja digabung');
  }

  // ── Printer station (struk tagihan + pengaturan) ────────────────────────────

  /// Buka Pengaturan Printer di perangkat station (config printer lokal sendiri).
  void _openPrinterSettings() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const PrinterSettingsScreen()));
  }

  /// Cetak TAGIHAN (bill, belum bayar) order aktif ke printer LOKAL station.
  Future<void> _printBill() async {
    final orderId = _controller.currentOrder?['id'] as String?;
    if (orderId == null) return;
    try {
      final full = await _controller.getOrderFull(orderId);
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
        cashierName: 'Station',
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
      await _sendToStationPrinter((cols, isCopy) =>
          ReceiptBuilder(paperWidth: cols).buildReceipt(data, isCopy: isCopy));
      if (mounted) showAppSnack(context, 'Tagihan dicetak');
    } catch (e) {
      if (mounted) {
        showAppSnack(context, 'Gagal cetak tagihan: $e', isError: true);
      }
    }
  }

  /// Kirim bytes ke printer kasir LOKAL station (fallback non-checker, lalu
  /// pertama). Printer dikonfigurasi di perangkat station via Pengaturan Printer.
  Future<void> _sendToStationPrinter(
      List<int> Function(int cols, bool isCopy) build) async {
    final ps = PrinterService();
    final saved = await ps.getSavedPrinters();
    if (saved.isEmpty) {
      if (mounted) {
        showAppSnack(
            context, 'Belum ada printer di perangkat ini (Pengaturan Printer)',
            isError: true);
      }
      return;
    }
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
    // Rangkap: salinan ke-2..N bertanda "COPY" (printer.copies dari Pengaturan).
    for (var c = 2; c <= printer.copies; c++) {
      await send(build(printer.paperCols, true));
    }
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'served':
      case 'ready':
      case 'done':
        return AppColors.success;
      case 'cooking':
      case 'preparing':
        return AppColors.warning;
      default:
        return AppColors.info;
    }
  }
}

/// Dialog peringatan idle: hitung mundur [seconds] detik. Pop true bila waiter
/// menekan "Saya masih di sini"; pop false otomatis saat waktu habis.
/// Dialog verifikasi PIN waiter sebelum mengirim order/tambahan.
class _WaiterPinDialog extends StatefulWidget {
  final StationController controller;
  const _WaiterPinDialog({required this.controller});

  @override
  State<_WaiterPinDialog> createState() => _WaiterPinDialogState();
}

/// Cara memasukkan PIN disamakan dengan LOGIN station: digit ke-4 langsung
/// diproses (tanpa tombol Verifikasi), dan PIN salah menahan dialog ini —
/// isian dikosongkan + pesan error, bukan menutup dialog.
class _WaiterPinDialogState extends State<_WaiterPinDialog> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _verifying = false;
  String? _error;

  /// PIN selalu 4 digit (lihat Manajemen User).
  static const _pinLength = 4;

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Dipanggil tiap ketikan: begitu genap 4 digit, langsung verifikasi.
  void _onChanged(String value) {
    if (_error != null) setState(() => _error = null);
    if (value.length == _pinLength) _verify();
  }

  Future<void> _verify() async {
    final pin = _ctrl.text.trim();
    if (pin.isEmpty || _verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final user = await widget.controller.authPin(pin);
      if (!mounted) return;
      if (user == null) {
        _failed('PIN salah');
        return;
      }
      Navigator.pop(context, user['full_name'] as String? ?? 'Waiter');
    } catch (e) {
      if (!mounted) return;
      _failed('Gagal verifikasi: $e');
    }
  }

  /// PIN salah → tetap di dialog ini, isian dikosongkan agar bisa langsung
  /// mengetik ulang (sama seperti layar login).
  void _failed(String message) {
    setState(() {
      _verifying = false;
      _error = message;
      _ctrl.clear();
    });
    // Kembalikan fokus + keyboard supaya waiter bisa langsung mengetik ulang
    // tanpa menyentuh kolomnya lagi (sama seperti layar login).
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.rXxl),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const IconBadge(
                icon: Icons.pin_rounded,
                color: AppColors.moduleKasir,
                size: 48),
            const SizedBox(height: AppSpacing.sm),
            Text('PIN Waiter', style: AppType.h3, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              'Masukkan PIN untuk verifikasi nama pemesan.',
              textAlign: TextAlign.center,
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _ctrl,
              focusNode: _focus,
              autofocus: true,
              enabled: !_verifying,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: _pinLength,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: InputDecoration(
                counterText: '',
                hintText: '••••',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onChanged: _onChanged,
              onSubmitted: (_) => _verify(),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 20,
              child: Center(
                child: _verifying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: AppColors.moduleKasir),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton.neutral(
              'Batal',
              onPressed: _verifying ? null : () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}
