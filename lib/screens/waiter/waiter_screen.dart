import 'package:flutter/material.dart';

import '../../controllers/waiter_controller.dart';
import '../../models/models.dart';
import '../../services/app_events.dart';
import '../../theme/theme.dart';
import '../../widgets/addon_picker_dialog.dart';
import '../../utils/currency.dart';
import '../../widgets/menu_avatar.dart';
import '../../widgets/pax_input_dialog.dart';
import '../../widgets/ui/ui.dart';

class WaiterScreen extends StatefulWidget {
  const WaiterScreen({super.key});

  @override
  State<WaiterScreen> createState() => _WaiterScreenState();
}

class _WaiterScreenState extends State<WaiterScreen>
    with AppEventsRefresh<WaiterScreen> {
  late final WaiterController _controller;
  String _searchQuery = '';
  String _filterStatus = 'all';
  final _menuSearchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = WaiterController();
    _controller.addListener(_onStateChanged);
    _controller.loadTables();
    listenDataChanges();
  }

  /// Daftar meja disegarkan hanya saat waiter TIDAK sedang menyusun pesanan,
  /// supaya keranjang/menu yang sedang dibuka tidak terganggu.
  @override
  void onDataChanged() {
    if (_controller.state.viewMode == 'tables') _controller.loadTables();
  }

  @override
  void deactivate() {
    _controller.removeListener(_onStateChanged);
    super.deactivate();
  }

  @override
  void dispose() {
    cancelDataChanges();
    _menuSearchCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final state = _controller.state;

    // Reset kolom cari menu saat tidak lagi di tampilan order
    if (state.viewMode != 'order' && _menuSearchCtrl.text.isNotEmpty) {
      _menuSearchCtrl.clear();
    }

    final errorMsg = state.errorMessage;
    final successMsg = state.successMessage;

    if (errorMsg != null || successMsg != null) _controller.clearMessages();

    if (!mounted) return;
    setState(() {});

    if (errorMsg != null || successMsg != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (errorMsg != null) _showSnack(errorMsg, isError: true);
        if (successMsg != null) _showSnack(successMsg);
      });
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    showAppSnack(context, msg, isError: isError);
  }

  List<RestaurantTable> get _filteredTables {
    var result = _controller.state.tables;
    if (_filterStatus == 'available') {
      result = result.where((t) => t.status == 'available').toList();
    } else if (_filterStatus == 'occupied') {
      result = result.where((t) => t.status == 'occupied').toList();
    }
    if (_searchQuery.isNotEmpty) {
      result = result
          .where((t) =>
              t.tableNumber.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }
    return result;
  }

  /// Tambah menu ke keranjang; menu ber-add-on membuka dialog pemilih dulu.
  /// Baris yang sudah ada di keranjang langsung bertambah unit mengikuti
  /// racikan yang dipilih sebelumnya.
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
      accent: AppColors.moduleWaiter,
    );
    // Batal = batal menambah item, bukan menambah tanpa add-on.
    if (picked == null || !mounted) return;
    _controller.addToCart(product, addons: picked);
  }

  Future<void> _editCartAddons(Product product) async {
    final options = await _controller.addonsFor(product.id);
    if (!mounted || options.isEmpty) return;
    final picked = await showAddonPicker(
      context,
      productName: product.name,
      basePrice: product.price,
      addons: options,
      initial: _controller.state.cartAddons[product.id] ?? const [],
      accent: AppColors.moduleWaiter,
    );
    if (picked == null || !mounted) return;
    _controller.updateCartAddons(product.id, picked);
  }

  void _showNoteDialog(String productId, String? current) {
    final ctrl = TextEditingController(text: current ?? '');
    showAppModal<void>(
      context,
      title: 'Catatan Item',
      subtitle: 'Instruksi khusus untuk dapur',
      icon: Icons.edit_note_rounded,
      accent: AppColors.moduleWaiter,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
              hintText: 'Contoh: es sedikit, lebih pedas...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: AppButton.neutral(
                  'Batal',
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Simpan',
                  accent: AppColors.moduleWaiter,
                  onPressed: () {
                    _controller.updateCartNote(productId, ctrl.text.trim());
                    Navigator.pop(ctx);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _selectTable(RestaurantTable table) async {
    if (table.status == 'available') {
      // Pesanan baru → input pax (wajib) + identitas customer (opsional).
      final res = await showPaxDialog(context);
      if (res == null) return; // dibatalkan
      await _controller.selectTableForOrder(table);
      _controller.setPax(res.pax);
      _controller.setCustomer(
          name: res.customerName, phone: res.customerPhone);
    } else {
      _controller.viewOrderDetail(table);
    }
  }

  void _selectCategory(Category? cat) {
    if (_menuSearchCtrl.text.isNotEmpty) {
      _menuSearchCtrl.clear();
    }
    _controller.selectCategory(cat);
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;

    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            _buildHeader(state),
            Expanded(
              child: state.isLoading &&
                      state.viewMode == 'tables' &&
                      state.tables.isEmpty
                  ? const AppLoader(label: 'Memuat meja...')
                  : _buildBody(state),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader(WaiterState state) {
    final inTableView = state.viewMode == 'tables';

    final title = inTableView
        ? 'Waiter'
        : state.viewMode == 'order'
            ? 'Order — Meja ${state.selectedTable?.tableNumber ?? ''}'
            : 'Detail — Meja ${state.selectedTable?.tableNumber ?? ''}';
    final subtitle = inTableView
        ? 'Layanan Pesanan'
        : state.viewMode == 'order'
            ? 'Pilih menu untuk dipesan'
            : 'Detail pesanan aktif';

    return Column(
      children: [
        AppPageHeader(
          title: title,
          subtitle: subtitle,
          icon: Icons.room_service_rounded,
          accent: AppColors.moduleWaiter,
          onBack: inTableView
              ? () => Navigator.pop(context)
              : _controller.goBackToTables,
          actions: [
            // Di ponsel: pindahkan pill hitungan ke bawah (search bar) agar
            // header tak overflow. Di tablet: tetap tampil di header.
            if (inTableView && !context.isPhone) ...[
              StatusPill(
                label: '${state.availableCount} Tersedia',
                color: AppColors.success,
                icon: Icons.event_available_rounded,
              ),
              const SizedBox(width: AppSpacing.xs),
              StatusPill(
                label: '${state.occupiedCount} Terisi',
                color: AppColors.warning,
                icon: Icons.chair_rounded,
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            if (state.viewMode == 'order' && state.cartItemCount > 0) ...[
              StatusPill(
                label: '${state.cartItemCount} item',
                color: AppColors.moduleWaiter,
                solid: true,
                icon: Icons.shopping_bag_rounded,
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
            state.isLoading
                ? const SizedBox(
                    width: 42,
                    height: 42,
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : AppIconButton(
                    icon: inTableView
                        ? Icons.refresh_rounded
                        : Icons.table_restaurant_rounded,
                    onPressed: inTableView
                        ? () => _controller.loadTables()
                        : _controller.goBackToTables,
                    color: AppColors.moduleWaiter,
                    filled: true,
                    size: 44,
                    tooltip: inTableView ? 'Muat ulang' : 'Kembali ke meja',
                  ),
          ],
        ),
        if (inTableView) _buildTableSearchBar(state),
      ],
    );
  }

  Widget _buildTableSearchBar(WaiterState state) {
    final searchField = Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        style: AppType.body,
        decoration: InputDecoration(
          hintText: 'Cari meja...',
          hintStyle: AppType.body.copyWith(color: AppColors.textTertiary),
          prefixIcon: const Icon(Icons.search_rounded,
              color: AppColors.textTertiary, size: 20),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
              vertical: 12, horizontal: AppSpacing.xs),
        ),
      ),
    );

    // Ponsel portrait: search penuh selebar layar, lalu baris hitungan +
    // filter yang bisa digeser horizontal (hindari Row sempit yang overflow).
    if (context.isPhone) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
            context.pagePadX, AppSpacing.sm, context.pagePadX, 0),
        child: Column(
          children: [
            searchField,
            const SizedBox(height: AppSpacing.sm),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  StatusPill(
                    label: '${state.availableCount} Tersedia',
                    color: AppColors.success,
                    icon: Icons.event_available_rounded,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  StatusPill(
                    label: '${state.occupiedCount} Terisi',
                    color: AppColors.warning,
                    icon: Icons.chair_rounded,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _filterPill('Semua', 'all'),
                  const SizedBox(width: AppSpacing.xxs),
                  _filterPill('Tersedia', 'available'),
                  const SizedBox(width: AppSpacing.xxs),
                  _filterPill('Terisi', 'occupied'),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Tablet / landscape: tata letak asli — search melebar + filter sejajar.
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.sm, context.pagePadX, 0),
      child: Row(
        children: [
          Expanded(child: searchField),
          const SizedBox(width: AppSpacing.xs),
          _filterPill('Semua', 'all'),
          const SizedBox(width: AppSpacing.xxs),
          _filterPill('Tersedia', 'available'),
          const SizedBox(width: AppSpacing.xxs),
          _filterPill('Terisi', 'occupied'),
        ],
      ),
    );
  }

  // ── Body Router ──────────────────────────────────────────────────────────

  Widget _buildBody(WaiterState state) {
    switch (state.viewMode) {
      case 'order':
        return _buildOrderView(state);
      case 'detail':
        return _buildDetailView(state);
      default:
        return _buildTablesView(state);
    }
  }

  // ── Tables View ──────────────────────────────────────────────────────────

  Widget _buildTablesView(WaiterState state) {
    final filtered = _filteredTables;

    if (filtered.isEmpty) {
      return const EmptyState(
        icon: Icons.table_restaurant_outlined,
        title: 'Tidak ada meja',
        message: 'Belum ada meja yang cocok dengan pencarian.',
        accent: AppColors.moduleWaiter,
      );
    }

    return RefreshIndicator(
      color: AppColors.moduleWaiter,
      onRefresh: _controller.loadTables,
      child: GridView.builder(
        padding: EdgeInsets.all(context.pagePadX),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: context.responsive(
              compact: 3, medium: 4, expanded: 5, large: 6),
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          childAspectRatio: 0.95,
        ),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final table = filtered[index];
          final order = state.tableOrders[table.tableNumber];
          return _WaiterTableCard(
            table: table,
            order: order,
            onTap: () => _selectTable(table),
          );
        },
      ),
    );
  }

  // ── Order View ───────────────────────────────────────────────────────────

  Widget _buildOrderView(WaiterState state) {
    if (state.isLoading) {
      return const AppLoader(label: 'Memuat menu...');
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isPhone = constraints.maxWidth < 600;
        if (isPhone) return _buildPhoneOrderView(state);

        // Lebar kolom pesanan disamakan dengan Kasir: proporsional 30% layar,
        // dibatasi 300–440px (sebelumnya tetap 320px → terasa sempit).
        final cartWidth =
            (constraints.maxWidth * 0.30).clamp(300.0, 440.0);
        return Row(
          children: [
            Expanded(child: _buildOrderProductPanel(state)),
            _CartPanel(
              state: state,
              width: cartWidth,
              onAdd: (p) => _controller.addToCart(p),
              onRemove: (id) => _controller.removeFromCart(id),
              onEditNote: (id, current) => _showNoteDialog(id, current),
              onEditAddons: _editCartAddons,
              onSubmit: () => _controller.createOrder(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPhoneOrderView(WaiterState state) {
    return Column(
      children: [
        Expanded(child: _buildOrderProductPanel(state)),
        if (state.cart.isNotEmpty) _buildWaiterCartBar(state),
      ],
    );
  }

  Widget _buildOrderProductPanel(WaiterState state) {
    return Column(
      children: [
        // Toolbar: pencarian menu
        Container(
          color: AppColors.surface,
          padding: EdgeInsets.fromLTRB(
              context.pagePadX, AppSpacing.sm, context.pagePadX, AppSpacing.xs),
          child: TextField(
            controller: _menuSearchCtrl,
            onChanged: (v) => _controller.searchProducts(v),
            style: AppType.body,
            decoration: InputDecoration(
              hintText: 'Cari menu...',
              hintStyle: AppType.body.copyWith(color: AppColors.textTertiary),
              prefixIcon: const Icon(Icons.search_rounded,
                  color: AppColors.textTertiary, size: 20),
              suffixIcon: _menuSearchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: AppColors.textTertiary, size: 20),
                      onPressed: () {
                        _menuSearchCtrl.clear();
                        _controller.searchProducts('');
                        setState(() {});
                      },
                    ),
              filled: true,
              fillColor: AppColors.surfaceMuted,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: const OutlineInputBorder(
                borderRadius: AppRadius.rMd,
                borderSide: BorderSide.none,
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: AppRadius.rMd,
                borderSide: BorderSide.none,
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: AppRadius.rMd,
                borderSide:
                    BorderSide(color: AppColors.moduleWaiter, width: 1.5),
              ),
            ),
          ),
        ),
        // Toolbar: kategori
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: SizedBox(
            height: 44,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: context.pagePadX),
              child: Row(
                children: [
                  _catChip('Semua', state.selectedCategory == null,
                      () => _selectCategory(null)),
                  ...state.categories.map((cat) => _catChip(
                        cat.name,
                        state.selectedCategory?.id == cat.id,
                        () => _selectCategory(cat),
                      )),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: state.products.isEmpty
              ? const EmptyState(
                  icon: Icons.restaurant_menu_rounded,
                  title: 'Tidak ada produk',
                  message: 'Coba kategori atau kata kunci lain.',
                  accent: AppColors.moduleWaiter,
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final cols = context
                        .gridColumns(
                          minTileWidth: 150,
                          gap: AppSpacing.sm,
                          maxWidth: constraints.maxWidth,
                        )
                        .clamp(2, 6);
                    return GridView.builder(
                      padding: EdgeInsets.all(context.pagePadX),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        mainAxisSpacing: AppSpacing.sm,
                        crossAxisSpacing: AppSpacing.sm,
                        childAspectRatio: 0.82,
                      ),
                      itemCount: state.products.length,
                      itemBuilder: (context, index) {
                        final product = state.products[index];
                        final inCart = state.cart[product.id] ?? 0;
                        return _WaiterProductTile(
                          product: product,
                          inCart: inCart,
                          hasAddons:
                              (state.addonCounts[product.id] ?? 0) > 0,
                          onTap: () => _addProductToCart(product),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildWaiterCartBar(WaiterState state) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
          boxShadow: AppShadows.card,
        ),
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _showWaiterCartSheet(state),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  alignment: Alignment.center,
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    Text(
                      '${state.cartItemCount} item',
                      style: AppType.caption
                          .copyWith(color: AppColors.textTertiary),
                    ),
                    Text(
                      _formatTotal(state.cartTotal),
                      style:
                          AppType.amount.copyWith(color: AppColors.moduleWaiter),
                    ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            _waiterPaxStepper(state),
            const SizedBox(width: AppSpacing.xs),
            AppButton(
              label: 'Kirim',
              icon: Icons.send_rounded,
              accent: AppColors.moduleWaiter,
              size: AppButtonSize.medium,
              expanded: false,
              loading: state.isProcessing,
              onPressed: () => _controller.createOrder(),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTotal(double total) {
    return 'Rp ${total.toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]}.',
        )}';
  }

  /// Stepper jumlah tamu (pax) untuk order baru — kompak.
  Widget _waiterPaxStepper(WaiterState state) {
    Widget btn(IconData icon, VoidCallback onTap) => Material(
          color: AppColors.surfaceMuted,
          borderRadius: AppRadius.rXs,
          child: InkWell(
            borderRadius: AppRadius.rXs,
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(icon, size: 18, color: AppColors.moduleWaiter),
            ),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.people_outline_rounded,
            size: 18, color: AppColors.textTertiary),
        const SizedBox(width: AppSpacing.xxs),
        btn(Icons.remove_rounded, () => _controller.setPax(state.pax - 1)),
        Container(
          width: 30,
          alignment: Alignment.center,
          child: Text('${state.pax}', style: AppType.title),
        ),
        btn(Icons.add_rounded, () => _controller.setPax(state.pax + 1)),
      ],
    );
  }

  void _showWaiterCartSheet(WaiterState initialState) {
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
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
                boxShadow: AppShadows.modal,
              ),
              clipBehavior: Clip.antiAlias,
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  final state = _controller.state;
                  return Column(
                    children: [
                      Center(
                        child: Container(
                          margin: const EdgeInsets.only(top: AppSpacing.sm),
                          width: 40,
                          height: 4,
                          decoration: const BoxDecoration(
                            color: AppColors.borderStrong,
                            borderRadius: AppRadius.rPill,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                            AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
                        child: Row(
                          children: [
                            const IconBadge(
                              icon: Icons.receipt_long_rounded,
                              color: AppColors.moduleWaiter,
                              size: 34,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text('Pesanan', style: AppType.h3),
                            const Spacer(),
                            if (state.cartItemCount > 0)
                              StatusPill(
                                label: '${state.cartItemCount} item',
                                color: AppColors.moduleWaiter,
                              ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          padding:
                              const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                          children: state.cart.entries.map((entry) {
                            final product = state.productCache[entry.key];
                            if (product == null) return const SizedBox.shrink();
                            final addons = state.cartAddons[entry.key] ??
                                const <SelectedAddon>[];
                            return _CartItem(
                              name: product.name,
                              qty: entry.value,
                              price: product.price +
                                  SelectedAddon.totalOf(addons),
                              notes: state.cartNotes[entry.key],
                              addonLabel: SelectedAddon.labelOf(addons),
                              onAdd: () => _controller.addToCart(product),
                              onRemove: () =>
                                  _controller.removeFromCart(product.id),
                              onEditNote: () => _showNoteDialog(
                                  entry.key, state.cartNotes[entry.key]),
                              onEditAddons:
                                  (state.addonCounts[entry.key] ?? 0) > 0
                                      ? () => _editCartAddons(product)
                                      : null,
                            );
                          }).toList(),
                        ),
                      ),
                      Container(
                        decoration: const BoxDecoration(
                          color: AppColors.surface,
                          border:
                              Border(top: BorderSide(color: AppColors.border)),
                        ),
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: SafeArea(
                          top: false,
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Total', style: AppType.title),
                                  Text(
                                    _formatTotal(state.cartTotal),
                                    style: AppType.amount.copyWith(
                                        color: AppColors.moduleWaiter),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              if (state.cart.isNotEmpty) ...[
                                Row(
                                  children: [
                                    const Icon(Icons.people_outline_rounded,
                                        size: 18,
                                        color: AppColors.textSecondary),
                                    const SizedBox(width: AppSpacing.xs),
                                    Text('Jumlah Tamu',
                                        style: AppType.body.copyWith(
                                            color: AppColors.textSecondary)),
                                    const Spacer(),
                                    _waiterPaxStepper(state),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                AppButton(
                                  label: 'Kirim Pesanan',
                                  icon: Icons.send_rounded,
                                  accent: AppColors.moduleWaiter,
                                  loading: state.isProcessing,
                                  onPressed: () {
                                    Navigator.pop(sheetContext);
                                    _controller.createOrder();
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
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

  // ── Detail View ──────────────────────────────────────────────────────────

  Widget _buildDetailView(WaiterState state) {
    final order = state.currentOrder;
    if (order == null) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Order tidak ditemukan',
        accent: AppColors.moduleWaiter,
      );
    }
    if (state.isLoading) {
      return const AppLoader(label: 'Memuat pesanan...');
    }

    return SingleChildScrollView(
      padding: context.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Order summary hero card
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.moduleWaiter, AppColors.moduleDapur],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: AppRadius.rXl,
              boxShadow: AppShadows.glow(AppColors.moduleWaiter, strength: 0.32),
            ),
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.soft(Colors.white, 0.18),
                        borderRadius: AppRadius.rSm,
                      ),
                      child: Text(
                        order.orderStatus.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text('${order.basketSize} item',
                        style: TextStyle(
                            color: AppColors.soft(Colors.white, 0.8),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  CurrencyHelper.format(order.totalAmount),
                  style: AppType.amountLg.copyWith(color: Colors.white),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    _summaryChip(Icons.table_restaurant_rounded,
                        'Meja ${order.tableNumber}'),
                    _summaryChip(Icons.people_outline_rounded, '${order.pax} pax'),
                    _summaryChip(
                      Icons.payments_outlined,
                      order.paymentStatus == 'paid' ? 'Lunas' : 'Belum Bayar',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Items card
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                      AppSpacing.md, AppSpacing.md, AppSpacing.xs),
                  child: Text('Item Pesanan', style: AppType.title),
                ),
                ...state.currentOrderItems.asMap().entries.map((e) {
                  final i = e.key;
                  final item = e.value;
                  return Column(
                    children: [
                      if (i > 0)
                        const Divider(
                            height: 1,
                            color: AppColors.border,
                            indent: AppSpacing.md,
                            endIndent: AppSpacing.md),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                        child: Row(
                          children: [
                            // Qty badge
                            Container(
                              width: 34,
                              height: 34,
                              decoration: const BoxDecoration(
                                color: AppColors.surfaceMuted,
                                borderRadius: AppRadius.rXs,
                              ),
                              child: Center(
                                child: Text('${item.qty}x',
                                    style: AppType.label.copyWith(
                                        color: AppColors.textSecondary)),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),

                            // Name + notes
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.productName, style: AppType.body),
                                  if (item.notes.isNotEmpty)
                                    Text(item.notes,
                                        style: AppType.caption.copyWith(
                                            color: AppColors.textTertiary)),
                                ],
                              ),
                            ),

                            // Subtotal + status
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  CurrencyHelper.format(item.subtotal),
                                  style: AppType.body.copyWith(
                                    color: AppColors.moduleWaiter,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                StatusPill(
                                  label: item.itemStatus.toUpperCase(),
                                  color: _statusColor(item.itemStatus),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }),

                // Total row
                Container(
                  decoration: const BoxDecoration(
                    border: Border(
                        top: BorderSide(color: AppColors.border, width: 1.5)),
                  ),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total', style: AppType.h3),
                      Text(
                        CurrencyHelper.format(order.totalAmount),
                        style: AppType.amount
                            .copyWith(color: AppColors.moduleWaiter),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Actions
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cetak Bill',
                  icon: Icons.print_outlined,
                  variant: AppButtonVariant.tonal,
                  accent: AppColors.accent, // aksi sekunder → SECONDARY gold
                  onPressed: () => _controller.printBill(order.id),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Tambah Item',
                  icon: Icons.add_shopping_cart_outlined,
                  accent: AppColors.moduleWaiter,
                  onPressed: () =>
                      _controller.selectTableForOrder(state.selectedTable!),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: AppButton.neutral(
                  'Pindah Meja',
                  icon: Icons.swap_horiz_rounded,
                  onPressed: () => _showMovePicker(state),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton.neutral(
                  'Gabung Meja',
                  icon: Icons.merge_type_rounded,
                  onPressed: () => _showMergePicker(state),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Pindah / Gabung Meja ───────────────────────────────────────────────────

  Future<void> _showMovePicker(WaiterState state) async {
    final order = state.currentOrder;
    if (order == null) return;
    // Meja kosong sebagai tujuan pindah.
    final targets = state.tables
        .where((t) =>
            t.status == 'available' && t.tableNumber != order.tableNumber)
        .toList();
    if (!mounted) return;
    if (targets.isEmpty) {
      _showSnack('Tidak ada meja kosong', isError: true);
      return;
    }
    final picked = await showAppModal<String>(
      context,
      title: 'Pindah ke Meja',
      subtitle: 'Pilih meja tujuan yang kosong',
      icon: Icons.swap_horiz_rounded,
      accent: AppColors.moduleWaiter,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: targets
            .map((t) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const IconBadge(
                    icon: Icons.table_restaurant_rounded,
                    color: AppColors.moduleWaiter,
                    size: 40,
                  ),
                  title: Text('Meja ${t.tableNumber}', style: AppType.body),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textTertiary),
                  onTap: () => Navigator.pop(ctx, t.tableNumber),
                ))
            .toList(),
      ),
    );
    if (picked == null || !mounted) return;
    final ok = await _controller.moveOrderToTable(picked);
    if (!mounted) return;
    _showSnack(
      ok
          ? 'Pesanan dipindah ke Meja $picked'
          : state.errorMessage ?? 'Gagal pindah meja',
      isError: !ok,
    );
  }

  Future<void> _showMergePicker(WaiterState state) async {
    final order = state.currentOrder;
    if (order == null) return;
    final mergeable = await _controller.getMergeableOrders();
    if (!mounted) return;
    if (mergeable.isEmpty) {
      _showSnack('Tidak ada meja lain untuk digabung', isError: true);
      return;
    }
    final picked = await showAppModal<Order>(
      context,
      title: 'Gabung ke Meja ${order.tableNumber}',
      subtitle: 'Pilih meja yang item-nya akan dipindah ke sini',
      icon: Icons.merge_type_rounded,
      accent: AppColors.moduleWaiter,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: mergeable
            .map((o) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const IconBadge(
                    icon: Icons.merge_type_rounded,
                    color: AppColors.moduleWaiter,
                    size: 40,
                  ),
                  title: Text('Meja ${o.tableNumber}', style: AppType.body),
                  subtitle: Text(
                    '${o.basketSize} item · ${CurrencyHelper.format(o.totalAmount)}',
                    style: AppType.caption,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textTertiary),
                  onTap: () => Navigator.pop(ctx, o),
                ))
            .toList(),
      ),
    );
    if (picked == null || !mounted) return;
    final ok = await _controller.mergeTable(picked.id);
    if (!mounted) return;
    _showSnack(
      ok
          ? 'Meja ${picked.tableNumber} digabung ke Meja ${order.tableNumber}'
          : state.errorMessage ?? 'Gagal gabung meja',
      isError: !ok,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Widget _filterPill(String label, String value) {
    final selected = _filterStatus == value;
    return GestureDetector(
      onTap: () => setState(() => _filterStatus = value),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        alignment: Alignment.center,
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          // Selected filter → SECONDARY gold (identitas hangat), unselected netral.
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: AppRadius.rPill,
          border: Border.all(
              color: selected ? AppColors.accent : AppColors.border),
        ),
        child: Text(label,
            style: AppType.label.copyWith(
              color: selected ? Colors.white : AppColors.textSecondary,
            )),
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
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            // Kategori terpilih → SECONDARY gold; kategori lain tetap netral.
            color: selected ? AppColors.accent : AppColors.surfaceMuted,
            borderRadius: AppRadius.rPill,
            border: Border.all(
                color: selected ? AppColors.accent : AppColors.border),
          ),
          child: Text(label,
              style: AppType.label.copyWith(
                color: selected ? Colors.white : AppColors.textSecondary,
              )),
        ),
      ),
    );
  }

  Widget _summaryChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.soft(Colors.white, 0.18),
        borderRadius: AppRadius.rSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.soft(Colors.white, 0.85)),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'pending':
        return AppColors.warning;
      case 'cooking':
        return AppColors.info;
      case 'ready':
        return AppColors.success;
      default:
        return AppColors.textTertiary;
    }
  }
}

// ── Cart Panel ────────────────────────────────────────────────────────────────

class _CartPanel extends StatelessWidget {
  final WaiterState state;
  final void Function(Product) onAdd;
  final void Function(String) onRemove;
  final void Function(String productId, String? current) onEditNote;
  final void Function(Product) onEditAddons;
  final VoidCallback onSubmit;
  final double width;

  const _CartPanel({
    required this.state,
    required this.onAdd,
    required this.onRemove,
    required this.onEditNote,
    required this.onEditAddons,
    required this.onSubmit,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                const IconBadge(
                  icon: Icons.receipt_long_rounded,
                  color: AppColors.moduleWaiter,
                  size: 34,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('Pesanan', style: AppType.h3),
                const Spacer(),
                if (state.cartItemCount > 0)
                  StatusPill(
                    label: '${state.cartItemCount} item',
                    color: AppColors.moduleWaiter,
                  ),
              ],
            ),
          ),

          // Items
          Expanded(
            child: state.cart.isEmpty
                ? const EmptyState(
                    icon: Icons.shopping_cart_outlined,
                    title: 'Belum ada item',
                    message: 'Pilih menu untuk mulai memesan.',
                    accent: AppColors.moduleWaiter,
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    children: state.cart.entries.map((entry) {
                      final product = state.productCache[entry.key];
                      if (product == null) return const SizedBox.shrink();
                      final addons =
                          state.cartAddons[entry.key] ?? const <SelectedAddon>[];
                      return _CartItem(
                        name: product.name,
                        qty: entry.value,
                        price: product.price + SelectedAddon.totalOf(addons),
                        notes: state.cartNotes[entry.key],
                        addonLabel: SelectedAddon.labelOf(addons),
                        onAdd: () => onAdd(product),
                        onRemove: () => onRemove(product.id),
                        onEditNote: () =>
                            onEditNote(entry.key, state.cartNotes[entry.key]),
                        onEditAddons: (state.addonCounts[entry.key] ?? 0) > 0
                            ? () => onEditAddons(product)
                            : null,
                      );
                    }).toList(),
                  ),
          ),

          // Bottom
          Container(
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.border))),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Total', style: AppType.title),
                    Text(
                      CurrencyHelper.format(state.cartTotal),
                      style:
                          AppType.amount.copyWith(color: AppColors.moduleWaiter),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                if (state.cart.isNotEmpty)
                  AppButton(
                    label: 'Kirim Pesanan',
                    icon: Icons.send_rounded,
                    accent: AppColors.moduleWaiter,
                    loading: state.isProcessing,
                    onPressed: onSubmit,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Cart Item ─────────────────────────────────────────────────────────────────

class _CartItem extends StatelessWidget {
  final String name;
  final int qty;
  final double price;
  final String? notes;

  /// Ringkasan add-on baris ini; harganya sudah termasuk di [price].
  final String addonLabel;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;
  final VoidCallback? onEditNote;
  final VoidCallback? onEditAddons; // null bila menu tak punya add-on

  const _CartItem({
    required this.name,
    required this.qty,
    required this.price,
    this.notes,
    this.addonLabel = '',
    this.onAdd,
    this.onRemove,
    this.onEditNote,
    this.onEditAddons,
  });

  @override
  Widget build(BuildContext context) {
    final hasNotes = notes != null && notes!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      child: Row(
        children: [
          // Tombol catatan paling depan (sebelum item) agar jauh dari +/−.
          if (onEditNote != null)
            GestureDetector(
              onTap: onEditNote,
              child: Container(
                width: 44,
                height: 44,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: hasNotes
                      ? AppColors.soft(AppColors.moduleWaiter, 0.12)
                      : AppColors.surfaceMuted,
                  borderRadius: AppRadius.rXs,
                ),
                child: Icon(
                  hasNotes ? Icons.edit_note_rounded : Icons.note_add_outlined,
                  size: 20,
                  color: hasNotes
                      ? AppColors.moduleWaiter
                      : AppColors.textTertiary,
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppType.body),
                Text(CurrencyHelper.format(price * qty),
                    style: AppType.caption.copyWith(
                        color: AppColors.moduleWaiter,
                        fontWeight: FontWeight.w700)),
                if (addonLabel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: GestureDetector(
                      onTap: onEditAddons,
                      child: Text(
                        '+ $addonLabel',
                        style: AppType.caption.copyWith(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (hasNotes)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '📝 $notes',
                      style: AppType.caption.copyWith(
                        color: AppColors.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                if (addonLabel.isEmpty && onEditAddons != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: GestureDetector(
                      onTap: onEditAddons,
                      child: Text(
                        '+ Tambahan',
                        style: AppType.caption.copyWith(
                          color: AppColors.moduleWaiter,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onRemove != null)
            GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                    color: AppColors.surfaceMuted,
                    borderRadius: AppRadius.rXs),
                child: const Icon(Icons.remove_rounded,
                    size: 16, color: AppColors.textSecondary),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Text('$qty', style: AppType.title),
          ),
          if (onAdd != null)
            GestureDetector(
              onTap: onAdd,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                    color: AppColors.moduleWaiter,
                    borderRadius: AppRadius.rXs),
                child: const Icon(Icons.add_rounded,
                    size: 16, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Waiter Table Card ─────────────────────────────────────────────────────────

class _WaiterTableCard extends StatelessWidget {
  final RestaurantTable table;
  final Order? order;
  final VoidCallback onTap;

  const _WaiterTableCard({
    required this.table,
    required this.order,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isAvailable = table.status == 'available';
    final statusColor = isAvailable ? AppColors.success : AppColors.warning;

    return AppCard(
      onTap: onTap,
      accent: statusColor,
      color: isAvailable ? null : AppColors.warningSoft,
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBadge(
              icon: Icons.table_restaurant_rounded,
              color: statusColor,
              size: 40),
          const SizedBox(height: AppSpacing.xs),
          Text(table.tableNumber,
              style: AppType.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.xxs),
          StatusPill(
            label: isAvailable ? 'Tersedia' : 'Terisi',
            color: statusColor,
          ),
          if (order != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              CurrencyHelper.format(order!.totalAmount),
              style: AppType.caption.copyWith(color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Waiter Product Tile ───────────────────────────────────────────────────────

class _WaiterProductTile extends StatelessWidget {
  final Product product;
  final int inCart;

  /// Menu ini punya add-on — ditandai agar waiter tahu akan muncul dialog.
  final bool hasAddons;
  final VoidCallback onTap;

  const _WaiterProductTile({
    required this.product,
    required this.inCart,
    this.hasAddons = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selected = inCart > 0;
    return AppCard(
      onTap: onTap,
      accent: selected ? AppColors.moduleWaiter : null,
      color: selected ? AppColors.soft(AppColors.moduleWaiter, 0.1) : null,
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Avatar besar mengisi bagian atas kartu
          Expanded(
            child: ClipRRect(
              borderRadius: AppRadius.rMd,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MenuAvatar.fill(name: product.name),
                  ),
                  if (selected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xs, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.moduleWaiter,
                          borderRadius: AppRadius.rXs,
                          boxShadow:
                              AppShadows.glow(AppColors.moduleWaiter, strength: 0.4),
                        ),
                        child: Text('$inCart',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            )),
                      ),
                    ),
                  if (hasAddons)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppRadius.rXs,
                          boxShadow: AppShadows.card,
                        ),
                        child: const Icon(
                          Icons.tune_rounded,
                          size: 13,
                          color: AppColors.moduleWaiter,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            height: 34,
            child: Text(product.name,
                style: AppType.label.copyWith(height: 1.2),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 2),
          Text(CurrencyHelper.format(product.price),
              style: AppType.label.copyWith(color: AppColors.moduleWaiter)),
        ],
      ),
    );
  }
}
