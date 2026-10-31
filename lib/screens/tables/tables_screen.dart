import 'package:flutter/material.dart';

import '../../controllers/tables_controller.dart';
import '../../models/models.dart';
import '../../services/app_events.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/ui/ui.dart';
import '../cashier/cashier_screen.dart';

class TablesScreen extends StatefulWidget {
  const TablesScreen({super.key});

  @override
  State<TablesScreen> createState() => _TablesScreenState();
}

class _TablesScreenState extends State<TablesScreen>
    with AppEventsRefresh<TablesScreen> {
  late final TablesController _controller;
  String _searchQuery = '';
  String _filterStatus = '';

  @override
  void initState() {
    super.initState();
    _controller = TablesController();
    _controller.addListener(_onStateChanged);
    _controller.loadTables();
    // Meja bisa terisi/kosong dari perangkat lain (station memesan / membayar)
    // atau dari layar kasir — ikut menyegar tanpa perlu Muat Ulang manual.
    listenDataChanges();
  }

  @override
  void onDataChanged() => _controller.loadTables();

  @override
  void deactivate() {
    _controller.removeListener(_onStateChanged);
    super.deactivate();
  }

  @override
  void dispose() {
    cancelDataChanges();
    _controller.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final state = _controller.state;

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
    showAppSnack(context, msg, isError: isError);
  }

  List<RestaurantTable> get _filteredTables {
    var result = _controller.state.tables;
    if (_searchQuery.isNotEmpty) {
      result = result
          .where((t) =>
              t.tableNumber.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }
    if (_filterStatus.isNotEmpty) {
      result = result.where((t) => t.status == _filterStatus).toList();
    }
    return result;
  }

  // ── Shared form fields ──────────────────────────────────────────────────────

  Widget _tableNumberField(TextEditingController controller) {
    return TextField(
      controller: controller,
      textCapitalization: TextCapitalization.characters,
      style: AppType.body,
      keyboardType: TextInputType.text,
      decoration: const InputDecoration(
        labelText: 'Nomor/Nama Meja',
        hintText: 'mis. 1, A5, VIP1',
        filled: true,
        fillColor: AppColors.surfaceMuted,
        border: OutlineInputBorder(
          borderRadius: AppRadius.rSm,
          borderSide: BorderSide.none,
        ),
        contentPadding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      ),
    );
  }

  Widget _capacityRow(int capacity, ValueChanged<int> onChanged) {
    const options = [2, 4, 6, 8, 10, 12];
    final value = options.contains(capacity) ? capacity : 4;
    return Row(
      children: [
        Text('Kapasitas', style: AppType.label),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: AppRadius.rSm,
            border: Border.all(color: AppColors.border),
          ),
          child: DropdownButton<int>(
            value: value,
            underline: const SizedBox(),
            borderRadius: AppRadius.rSm,
            style: AppType.body,
            items: options
                .map((n) => DropdownMenuItem(
                    value: n, child: Text('$n kursi', style: AppType.body)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }

  // ── Dialogs / sheets ────────────────────────────────────────────────────────

  void _showAddTableDialog() {
    final controller = TextEditingController();
    int capacity = 4;
    showAppModal(
      context,
      title: 'Tambah Meja',
      subtitle: 'Buat meja baru',
      icon: Icons.add_rounded,
      accent: AppColors.moduleMeja,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _tableNumberField(controller),
            const SizedBox(height: AppSpacing.md),
            _capacityRow(capacity, (v) => setDialogState(() => capacity = v)),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: AppButton.neutral('Batal',
                      onPressed: () => Navigator.pop(ctx)),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppButton(
                    label: 'Tambah',
                    accent: AppColors.moduleMeja,
                    onPressed: () {
                      if (controller.text.isNotEmpty) {
                        Navigator.pop(ctx);
                        _controller.addTable(
                          tableNumber: controller.text.trim(),
                          capacity: capacity,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Menu kelola meja (long-press) — Edit & Hapus agar mudah ditemukan.
  void _showManageSheet(RestaurantTable table) {
    showAppModal(
      context,
      title: 'Kelola Meja ${table.tableNumber}',
      subtitle: '${table.capacity} kursi',
      icon: Icons.table_restaurant_rounded,
      accent: AppColors.moduleMeja,
      scrollable: false,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _optionTile(
            icon: Icons.edit_outlined,
            color: AppColors.info,
            title: 'Edit Meja',
            subtitle: 'Ubah nomor & kapasitas',
            onTap: () {
              Navigator.pop(ctx);
              _showEditTableDialog(table);
            },
          ),
          _optionTile(
            icon: Icons.delete_outline_rounded,
            color: AppColors.danger,
            title: 'Hapus Meja',
            subtitle: 'Hapus meja permanen',
            onTap: () {
              Navigator.pop(ctx);
              _confirmDelete(table);
            },
          ),
        ],
      ),
    );
  }

  void _showEditTableDialog(RestaurantTable table) {
    final controller = TextEditingController(text: table.tableNumber);
    int capacity = table.capacity;
    showAppModal(
      context,
      title: 'Edit Meja',
      subtitle: 'Ubah data meja',
      icon: Icons.edit_outlined,
      accent: AppColors.moduleMeja,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _tableNumberField(controller),
            const SizedBox(height: AppSpacing.md),
            _capacityRow(capacity, (v) => setDialogState(() => capacity = v)),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: AppButton.neutral('Batal',
                      onPressed: () => Navigator.pop(ctx)),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppButton(
                    label: 'Simpan',
                    accent: AppColors.moduleMeja,
                    onPressed: () {
                      if (controller.text.trim().isNotEmpty) {
                        Navigator.pop(ctx);
                        _controller.editTable(
                          tableId: table.id,
                          tableNumber: controller.text.trim(),
                          capacity: capacity,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSeedDialog() async {
    final ok = await showAppConfirm(
      context,
      title: 'Buat Meja Otomatis',
      message: 'Buat 10 meja secara otomatis?',
      confirmText: 'Buat',
      icon: Icons.auto_fix_high_rounded,
    );
    if (ok) _controller.seedTables(count: 10);
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final filtered = _filteredTables;

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: AppBackground(
        child: Column(
          children: [
            // ── Header ──
            AppPageHeader(
              title: 'Manajemen Meja',
              subtitle: 'Kelola dan monitor status meja',
              icon: Icons.table_restaurant_rounded,
              accent: AppColors.moduleMeja,
              actions: [
                AppIconButton(
                  icon: Icons.add_rounded,
                  onPressed: _showAddTableDialog,
                  color: AppColors.moduleMeja,
                  filled: true,
                  tooltip: 'Tambah Meja',
                ),
                const SizedBox(width: AppSpacing.xs),
                if (state.isLoading)
                  const SizedBox(
                    width: 42,
                    height: 42,
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    ),
                  )
                else
                  AppIconButton(
                    icon: Icons.refresh_rounded,
                    onPressed: () => _controller.loadTables(),
                    color: AppColors.moduleMeja,
                    filled: true,
                    tooltip: 'Muat ulang',
                  ),
              ],
            ),

            // ── Stats + Filter ──
            if (state.tables.isNotEmpty) _buildTopBar(state),

            // ── Body ──
            Expanded(
              child: state.isLoading && state.tables.isEmpty
                  ? const AppLoader(label: 'Memuat meja...')
                  : state.tables.isEmpty
                      ? EmptyState(
                          icon: Icons.table_restaurant_rounded,
                          title: 'Belum ada meja',
                          message: 'Tambah meja atau buat secara otomatis',
                          actionLabel: 'Buat 10 Meja Otomatis',
                          onAction: _showSeedDialog,
                          accent: AppColors.moduleMeja,
                        )
                      : RefreshIndicator(
                          color: AppColors.moduleMeja,
                          onRefresh: _controller.loadTables,
                          child: GridView.builder(
                            padding: EdgeInsets.fromLTRB(
                              context.pagePadX,
                              AppSpacing.sm,
                              context.pagePadX,
                              context.pagePadY,
                            ),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount:
                                  context.gridColumns(minTileWidth: 150),
                              mainAxisSpacing: AppSpacing.md,
                              crossAxisSpacing: AppSpacing.md,
                              childAspectRatio: 0.88,
                            ),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final table = filtered[index];
                              final order =
                                  state.tableOrders[table.tableNumber];
                              return _TableCard(
                                table: table,
                                order: order,
                                onTap: () => _onTableTap(table),
                                onDelete: () => _showManageSheet(table),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Stats + Filter bar ──────────────────────────────────────────────────────

  Widget _buildTopBar(TablesState state) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.md, context.pagePadX, AppSpacing.xs),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _statTile(
                    '${state.tables.length}', 'Total Meja', AppColors.info),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: _statTile('${state.availableCount}', 'Tersedia',
                    AppColors.success),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: _statTile('${state.occupiedCount}', 'Terisi',
                    AppColors.moduleMeja),
              ),
              const SizedBox(width: AppSpacing.xs),
              AppButton(
                label: 'Auto',
                icon: Icons.auto_fix_high_rounded,
                variant: AppButtonVariant.tonal,
                accent: AppColors.accent, // aksi sekunder → SECONDARY gold
                size: AppButtonSize.small,
                expanded: false,
                onPressed: _showSeedDialog,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Portrait sempit: search penuh di atas, pill filter di baris sendiri
          // (hindari search terlalu mepet). Tablet/landscape tetap satu baris.
          if (context.isPhone) ...[
            _searchField(),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                _filterPill('Semua', ''),
                const SizedBox(width: AppSpacing.xxs),
                _filterPill('Tersedia', 'available'),
                const SizedBox(width: AppSpacing.xxs),
                _filterPill('Terisi', 'occupied'),
              ],
            ),
          ] else
            Row(
              children: [
                Expanded(child: _searchField()),
                const SizedBox(width: AppSpacing.xs),
                _filterPill('Semua', ''),
                const SizedBox(width: AppSpacing.xxs),
                _filterPill('Tersedia', 'available'),
                const SizedBox(width: AppSpacing.xxs),
                _filterPill('Terisi', 'occupied'),
              ],
            ),
        ],
      ),
    );
  }

  Widget _searchField() {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rMd,
        border: Border.all(color: AppColors.border),
      ),
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        style: AppType.body,
        decoration: InputDecoration(
          hintText: 'Cari nomor meja...',
          hintStyle: AppType.body.copyWith(color: AppColors.textTertiary),
          prefixIcon: const Icon(Icons.search_rounded,
              color: AppColors.textTertiary, size: 20),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        ),
      ),
    );
  }

  Widget _statTile(String value, String label, Color color) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: AppType.h3.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            label,
            style: AppType.caption.copyWith(color: AppColors.textTertiary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _filterPill(String label, String value) {
    final selected = _filterStatus == value;
    return GestureDetector(
      onTap: () => setState(() => _filterStatus = value),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          // Selected filter → SECONDARY gold (identitas hangat), unselected netral.
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: AppRadius.rPill,
          border: Border.all(
              color: selected ? AppColors.accent : AppColors.border),
        ),
        child: Text(
          label,
          style: AppType.label.copyWith(
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  void _onTableTap(RestaurantTable table) {
    if (table.status == 'available') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CashierScreen(initialTableNumber: table.tableNumber),
        ),
      ).then((_) => _controller.loadTables());
    } else {
      _showOccupiedOptions(table);
    }
  }

  void _showOccupiedOptions(RestaurantTable table) {
    final order = _controller.state.tableOrders[table.tableNumber];
    final subtitle = order != null
        ? '${order.basketSize} item · ${CurrencyHelper.format(order.totalAmount)}'
        : null;
    showAppModal(
      context,
      title: 'Meja ${table.tableNumber}',
      subtitle: subtitle,
      icon: Icons.table_restaurant_rounded,
      accent: AppColors.warning,
      scrollable: false,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _optionTile(
            icon: Icons.point_of_sale_outlined,
            color: AppColors.moduleKasir,
            title: 'Buka di Kasir',
            subtitle: 'Proses pembayaran',
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      CashierScreen(initialTableNumber: table.tableNumber),
                ),
              ).then((_) => _controller.loadTables());
            },
          ),
          _optionTile(
            icon: Icons.check_circle_outline_rounded,
            color: AppColors.success,
            title: 'Tandai Tersedia',
            subtitle: 'Bebaskan meja',
            onTap: () {
              Navigator.pop(ctx);
              _controller.updateTableStatus(table.tableNumber, 'available');
            },
          ),
        ],
      ),
    );
  }

  Widget _optionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Material(
        color: AppColors.surfaceAlt,
        borderRadius: AppRadius.rMd,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.rMd,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: [
                IconBadge(icon: icon, color: color, size: 44),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: AppType.title),
                      Text(subtitle,
                          style: AppType.caption
                              .copyWith(color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textTertiary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmDelete(RestaurantTable table) async {
    final ok = await showAppConfirm(
      context,
      title: 'Hapus Meja',
      message: 'Hapus Meja ${table.tableNumber}?',
      confirmText: 'Hapus',
      icon: Icons.delete_outline_rounded,
      destructive: true,
    );
    if (ok) _controller.deleteTable(table.id);
  }
}

// ── Table Card ────────────────────────────────────────────────────────────────

class _TableCard extends StatelessWidget {
  final RestaurantTable table;
  final Order? order;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _TableCard({
    required this.table,
    required this.order,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isAvailable = table.status == 'available';
    final statusColor = isAvailable ? AppColors.success : AppColors.warning;

    return Stack(
      children: [
        GestureDetector(
          onLongPress: onDelete,
          child: AppCard(
            onTap: onTap,
            accent: statusColor,
            color: isAvailable ? AppColors.surface : AppColors.warningSoft,
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
            // Struktur tetap (spaceBetween + Expanded di tengah) → semua kartu
            // seragam & tak pernah overflow, baik meja kosong maupun terisi.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Atas: pill status (kiri). Tombol kelola ada di Stack (kanan).
                Align(
                  alignment: Alignment.centerLeft,
                  child: StatusPill(
                    label: isAvailable ? 'Tersedia' : 'Terisi',
                    color: statusColor,
                    icon: isAvailable
                        ? Icons.check_circle_rounded
                        : Icons.people_alt_rounded,
                  ),
                ),

                // Tengah: nomor meja sebagai badge gradasi (hero) — anti-mepet.
                Expanded(
                  child: Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: AppColors.gradientOf(statusColor),
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: AppRadius.rMd,
                        boxShadow: AppShadows.glow(statusColor, strength: 0.28),
                      ),
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: FittedBox(
                          child: Text(
                            table.tableNumber,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 22,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Bawah: nominal (bila terisi) + kapasitas — selalu ada baris
                // kapasitas agar tinggi konten konsisten antar kartu.
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (order != null)
                      Text(
                        CurrencyHelper.format(order!.totalAmount),
                        style: AppType.amount
                            .copyWith(fontSize: 15, color: statusColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      '${table.capacity} kursi',
                      style:
                          AppType.caption.copyWith(color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // Tombol kelola (edit/hapus) — di pojok kanan atas, mudah ditemukan.
        Positioned(
          top: AppSpacing.xxs,
          right: AppSpacing.xxs,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onDelete,
              child: const Padding(
                padding: EdgeInsets.all(AppSpacing.xs),
                child: Icon(Icons.more_vert_rounded,
                    size: 18, color: AppColors.textTertiary),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
