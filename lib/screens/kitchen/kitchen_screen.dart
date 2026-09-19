import 'package:flutter/material.dart';

import '../../controllers/kitchen_controller.dart';
import '../../models/models.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';

// ── Palet gelap khusus layar Dapur/Bar (KDS) — kurangi silau, kontras tinggi ──
const _bg = Color(0xFF0F131B);
const _surface = Color(0xFF1A202C);
const _surfaceHi = Color(0xFF222A38);
const _border = Color(0xFF2A3342);
const _textHi = Color(0xFFEEF2F8);
const _textMid = Color(0xFFAEB7C8);
const _textLo = Color(0xFF6C7688);

Color _statusColor(String status) {
  switch (status) {
    case 'pending':
      return AppColors.warning;
    case 'cooking':
      return AppColors.info;
    case 'ready':
      return AppColors.success;
    default:
      return _textLo;
  }
}

class KitchenScreen extends StatefulWidget {
  const KitchenScreen({super.key});

  @override
  State<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends State<KitchenScreen> {
  late final KitchenController _controller;

  // 'antrian' (per meja) atau 'batch' (gabung item sama). Default Batch.
  String _viewMode = 'batch';

  @override
  void initState() {
    super.initState();
    _controller = KitchenController();
    _controller.addListener(_onStateChanged);
    _controller.loadOrders();
  }

  @override
  void deactivate() {
    _controller.removeListener(_onStateChanged);
    super.deactivate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final errorMsg = _controller.state.errorMessage;
    setState(() {});
    if (errorMsg != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showAppSnack(context, errorMsg, isError: true);
      });
    }
  }

  String _timeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    final minutes = diff.inMinutes;
    if (minutes < 1) return 'Baru';
    if (minutes < 60) return '$minutes mnt';
    final hours = diff.inHours;
    return '$hours jam';
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _header(state),
            _controls(state),
            _statsBar(state),
            Expanded(
              child: state.isLoading && state.flatItems.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.accent))
                  : state.flatItems.isEmpty
                      ? _empty()
                      : RefreshIndicator(
                          color: AppColors.accent,
                          backgroundColor: _surface,
                          onRefresh: _controller.loadOrders,
                          child: _viewMode == 'batch'
                              ? _batchList(state)
                              : _antrianList(state),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  String get _stationName =>
      _controller.state.selectedStation?.name ?? 'Dapur / Bar';
  bool get _isBarLike => _stationName.toLowerCase().contains('bar');

  // ── Header gelap ──
  Widget _header(KitchenState state) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.sm, context.pagePadX, AppSpacing.sm),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          _iconBtn(Icons.arrow_back_ios_new_rounded,
              () => Navigator.pop(context)),
          const SizedBox(width: AppSpacing.sm),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: AppColors.gradientOf(AppColors.moduleDapur)),
              borderRadius: AppRadius.rSm,
              boxShadow: AppShadows.glow(AppColors.moduleDapur, strength: 0.35),
            ),
            child: Icon(
                _isBarLike
                    ? Icons.local_bar_rounded
                    : Icons.soup_kitchen_rounded,
                color: Colors.white,
                size: 22),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_stationName,
                    style: AppType.h3.copyWith(color: _textHi),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text('${state.filteredOrders.length} pesanan aktif',
                    style: AppType.caption.copyWith(color: _textLo)),
              ],
            ),
          ),
          _LiveIndicator(active: state.filteredOrders.isNotEmpty),
          const SizedBox(width: AppSpacing.xs),
          state.isLoading
              ? const SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: AppColors.moduleDapur))))
              : _iconBtn(Icons.refresh_rounded, _controller.loadOrders),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return Material(
      color: _surface,
      borderRadius: AppRadius.rSm,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.rSm,
        child: SizedBox(
            width: 44, height: 44, child: Icon(icon, color: _textMid, size: 20)),
      ),
    );
  }

  // ── Kontrol: pemilih STASIUN (per printer) + mode (Antrian/Batch) ──
  Widget _controls(KitchenState state) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.sm, context.pagePadX, 0),
      child: Row(
        children: [
          Expanded(
            child: state.stations.isEmpty
                ? Row(children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 14, color: _textLo),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Semua item · atur stasiun di Pengaturan → Printer',
                        style: AppType.caption.copyWith(color: _textLo),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ])
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final s in state.stations)
                          Padding(
                            padding: const EdgeInsets.only(right: AppSpacing.xs),
                            child: _StationChip(
                              name: s.name,
                              isBar: s.name.toLowerCase().contains('bar'),
                              selected:
                                  s.address == state.selectedStation?.address,
                              onTap: () => _controller.setStation(s.address),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _Segmented(
            labels: const ['Antrian', 'Batch'],
            icons: const [Icons.view_list_rounded, Icons.layers_rounded],
            selected: _viewMode == 'batch' ? 1 : 0,
            onChanged: (i) =>
                setState(() => _viewMode = i == 1 ? 'batch' : 'antrian'),
          ),
        ],
      ),
    );
  }

  Widget _statsBar(KitchenState state) {
    final hasStats = state.pendingCount > 0 ||
        state.cookingCount > 0 ||
        state.readyCount > 0;
    if (!hasStats) return const SizedBox(height: AppSpacing.xs);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.sm, context.pagePadX, 0),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          if (state.pendingCount > 0)
            _StatChip('${state.pendingCount} Antri', AppColors.warning,
                Icons.schedule_rounded),
          if (state.cookingCount > 0)
            _StatChip('${state.cookingCount} Masak', AppColors.info,
                Icons.local_fire_department_rounded),
          if (state.readyCount > 0)
            _StatChip('${state.readyCount} Siap', AppColors.success,
                Icons.check_circle_rounded),
        ],
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
              _isBarLike
                  ? Icons.local_bar_rounded
                  : Icons.restaurant_menu_rounded,
              size: 64,
              color: _textLo),
          const SizedBox(height: AppSpacing.md),
          Text('Semua pesanan selesai',
              style: AppType.h3.copyWith(color: _textMid)),
          const SizedBox(height: AppSpacing.xs),
          Text('Belum ada pesanan untuk stasiun "$_stationName".',
              style: AppType.body.copyWith(color: _textLo),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  // ── Mode BATCH (list) ──
  Widget _batchList(KitchenState state) {
    final batches = _computeBatches(state);
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.md, context.pagePadX, context.pagePadY),
      itemCount: batches.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) => _BatchRow(
        batch: batches[i],
        timeAgo: _timeAgo(batches[i].oldest),
        onBatch: _controller.updateBatchStatus,
      ),
    );
  }

  // ── Mode ANTRIAN (per meja, list) ──
  Widget _antrianList(KitchenState state) {
    // Urutkan meja: yang punya item paling lama di atas.
    final entries = state.filteredOrders.entries.toList()
      ..sort((a, b) {
        DateTime oldest(List<OrderItem> items) => items
            .map((i) => i.createdAt)
            .reduce((x, y) => x.isBefore(y) ? x : y);
        return oldest(a.value).compareTo(oldest(b.value));
      });
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.md, context.pagePadX, context.pagePadY),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) {
        final e = entries[i];
        // urut item: pending → cooking → ready, lalu createdAt
        final items = [...e.value]..sort((a, b) {
            const order = ['pending', 'cooking', 'ready'];
            final ai = order.indexOf(a.itemStatus);
            final bi = order.indexOf(b.itemStatus);
            if (ai != bi) return ai.compareTo(bi);
            return a.createdAt.compareTo(b.createdAt);
          });
        return _TableSection(
          order: e.key,
          items: items,
          timeAgo: _timeAgo(
              items.map((i) => i.createdAt).reduce((x, y) => x.isBefore(y) ? x : y)),
          onUpdate: _controller.updateItemStatus,
          onReadyAll: () => _controller.markAllReady(e.key.id),
        );
      },
    );
  }

  List<_Batch> _computeBatches(KitchenState state) {
    final map = <String, List<({OrderItem item, String tableNumber})>>{};
    for (final e in state.flatItems) {
      map.putIfAbsent(e.item.productName, () => []).add(e);
    }
    final batches = map.entries.map((e) => _Batch(e.key, e.value)).toList();
    batches.sort((a, b) {
      int rank(_Batch x) => x.pendingQty > 0 ? 0 : (x.cookingQty > 0 ? 1 : 2);
      final ra = rank(a), rb = rank(b);
      if (ra != rb) return ra.compareTo(rb);
      return a.oldest.compareTo(b.oldest);
    });
    return batches;
  }
}

// ── Data batch ──
class _Batch {
  final String productName;
  final List<({OrderItem item, String tableNumber})> lines;
  _Batch(this.productName, this.lines);

  int _qty(bool Function(OrderItem) t) =>
      lines.where((l) => t(l.item)).fold(0, (s, l) => s + l.item.qty);
  int get totalQty => lines.fold(0, (s, l) => s + l.item.qty);
  int get pendingQty => _qty((i) => i.itemStatus == 'pending');
  int get cookingQty => _qty((i) => i.itemStatus == 'cooking');
  int get readyQty => _qty((i) => i.itemStatus == 'ready');
  DateTime get oldest =>
      lines.map((l) => l.item.createdAt).reduce((a, b) => a.isBefore(b) ? a : b);
  List<String> idsWithStatus(Set<String> s) => lines
      .where((l) => s.contains(l.item.itemStatus))
      .map((l) => l.item.id)
      .toList();
  Color get overallColor => pendingQty > 0
      ? AppColors.warning
      : (cookingQty > 0 ? AppColors.info : AppColors.success);
}

// ── Baris Batch (list) ──
class _BatchRow extends StatelessWidget {
  final _Batch batch;
  final String timeAgo;
  final Future<void> Function(List<String> ids, String status) onBatch;

  const _BatchRow(
      {required this.batch, required this.timeAgo, required this.onBatch});

  @override
  Widget build(BuildContext context) {
    final color = batch.overallColor;
    final pendingIds = batch.idsWithStatus({'pending'});
    final activeIds = batch.idsWithStatus({'pending', 'cooking'});
    final compact = context.isPhone;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(batch.productName,
            style: AppType.h3.copyWith(color: _textHi),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.schedule_rounded, size: 12, color: _textLo),
          const SizedBox(width: 4),
          Flexible(
            child: Text('tunggu $timeAgo · ${batch.lines.length} meja',
                style: AppType.caption.copyWith(color: _textLo),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xxs,
          children: [
            for (final l in batch.lines)
              _MejaTag(
                  table: l.tableNumber,
                  qty: l.item.qty,
                  status: l.item.itemStatus,
                  note: l.item.notes),
          ],
        ),
      ],
    );

    final masakBtn = AppButton(
      label: 'Masak Semua',
      icon: Icons.local_fire_department_rounded,
      onPressed: () => onBatch(pendingIds, 'cooking'),
      accent: AppColors.info,
      size: AppButtonSize.small,
    );
    final siapBtn = AppButton(
      label: 'Siap Semua',
      icon: Icons.check_rounded,
      onPressed: () => onBatch(activeIds, 'ready'),
      accent: AppColors.success,
      size: AppButtonSize.small,
    );

    final Widget body = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _QtyBadge(qty: batch.totalQty),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: info),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(children: [
                if (pendingIds.isNotEmpty) ...[
                  Expanded(child: masakBtn),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(child: siapBtn),
              ]),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _QtyBadge(qty: batch.totalQty),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: info),
              const SizedBox(width: AppSpacing.md),
              SizedBox(
                width: 168,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pendingIds.isNotEmpty) ...[
                      masakBtn,
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    siapBtn,
                  ],
                ),
              ),
            ],
          );

    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Garis aksen kiri (warna status) — via Stack agar borderRadius seragam.
          Positioned(
              left: 0, top: 0, bottom: 0, child: Container(width: 4, color: color)),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
            child: body,
          ),
        ],
      ),
    );
  }
}

// ── Seksi per meja (Antrian) ──
class _TableSection extends StatelessWidget {
  final Order order;
  final List<OrderItem> items;
  final String timeAgo;
  final Future<void> Function(String id, String status) onUpdate;
  final VoidCallback onReadyAll;

  const _TableSection({
    required this.order,
    required this.items,
    required this.timeAgo,
    required this.onUpdate,
    required this.onReadyAll,
  });

  @override
  Widget build(BuildContext context) {
    final anyActive =
        items.any((i) => i.itemStatus == 'pending' || i.itemStatus == 'cooking');
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header meja
          Container(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
            color: _surfaceHi,
            child: Row(
              children: [
                const Icon(Icons.table_restaurant_rounded,
                    size: 18, color: AppColors.moduleMeja),
                const SizedBox(width: AppSpacing.xs),
                // Fleksibel + ellipsis: nama meja / meta panjang tak overflow di
                // portrait sempit; tombol "Siap Semua" tetap terdorong ke kanan.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text('Meja ${order.tableNumber}',
                            style: AppType.title.copyWith(color: _textHi),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Flexible(
                        child: Text('· ${items.length} item · $timeAgo',
                            style: AppType.caption.copyWith(color: _textLo),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
                if (anyActive)
                  TextButton.icon(
                    onPressed: onReadyAll,
                    icon: const Icon(Icons.done_all_rounded, size: 16),
                    label: const Text('Siap Semua'),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.success,
                        visualDensity: VisualDensity.compact),
                  ),
              ],
            ),
          ),
          // Item-item
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: _border),
            _ItemRow(item: items[i], onUpdate: onUpdate),
          ],
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final OrderItem item;
  final Future<void> Function(String id, String status) onUpdate;
  const _ItemRow({required this.item, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    final c = _statusColor(item.itemStatus);
    String? next;
    String? label;
    IconData? icon;
    switch (item.itemStatus) {
      case 'pending':
        next = 'cooking';
        label = 'Masak';
        icon = Icons.local_fire_department_rounded;
        break;
      case 'cooking':
        next = 'ready';
        label = 'Siap';
        icon = Icons.check_rounded;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      child: Row(
        children: [
          Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: AppSpacing.xs),
          _QtyBadge(qty: item.qty, small: true),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.productName,
                    style: AppType.body.copyWith(color: _textHi),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (item.notes.isNotEmpty)
                  Text(item.notes,
                      style: AppType.caption.copyWith(
                          color: AppColors.warning,
                          fontStyle: FontStyle.italic),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          if (next != null)
            SizedBox(
              height: 34,
              child: AppButton(
                label: label!,
                icon: icon,
                onPressed: () => onUpdate(item.id, next!),
                accent: item.itemStatus == 'pending'
                    ? AppColors.info
                    : AppColors.success,
                size: AppButtonSize.small,
                expanded: false,
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                  color: AppColors.soft(AppColors.success, 0.16),
                  borderRadius: AppRadius.rPill),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle_rounded,
                    size: 13, color: AppColors.success),
                SizedBox(width: 4),
                Text('Siap',
                    style: TextStyle(
                        color: AppColors.success,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
        ],
      ),
    );
  }
}

// ── Widget kecil ──

class _QtyBadge extends StatelessWidget {
  final int qty;
  final bool small;
  const _QtyBadge({required this.qty, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: small ? 6 : AppSpacing.xs, vertical: small ? 2 : 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: AppColors.accentGradient),
        borderRadius: AppRadius.rXs,
      ),
      child: Text('×$qty',
          style: (small ? AppType.caption : AppType.title)
              .copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
    );
  }
}

class _MejaTag extends StatelessWidget {
  final String table;
  final int qty;
  final String status;
  final String note;
  const _MejaTag(
      {required this.table,
      required this.qty,
      required this.status,
      required this.note});

  @override
  Widget build(BuildContext context) {
    final c = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 4),
      decoration: BoxDecoration(
        color: _surfaceHi,
        borderRadius: AppRadius.rXs,
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('Meja $table',
              style: AppType.caption
                  .copyWith(color: _textMid, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          Text('×$qty',
              style: AppType.caption
                  .copyWith(color: _textHi, fontWeight: FontWeight.w800)),
          if (note.isNotEmpty) ...[
            const SizedBox(width: 4),
            const Icon(Icons.sticky_note_2_rounded,
                size: 11, color: AppColors.warning),
          ],
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  const _StatChip(this.label, this.color, this.icon);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.soft(color, 0.18),
        borderRadius: AppRadius.rPill,
        border: Border.all(color: AppColors.soft(color, 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ── Chip pemilih stasiun (per printer) ──
class _StationChip extends StatelessWidget {
  final String name;
  final bool isBar;
  final bool selected;
  final VoidCallback onTap;
  const _StationChip({
    required this.name,
    required this.isBar,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : _surface,
          borderRadius: AppRadius.rPill,
          border: Border.all(color: selected ? AppColors.accent : _border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isBar ? Icons.local_bar_rounded : Icons.soup_kitchen_rounded,
                size: 15, color: selected ? Colors.white : _textMid),
            const SizedBox(width: 6),
            Text(name,
                style: AppType.label
                    .copyWith(color: selected ? Colors.white : _textMid),
                maxLines: 1),
          ],
        ),
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  final List<String> labels;
  final List<IconData> icons;
  final int selected;
  final ValueChanged<int> onChanged;

  const _Segmented({
    required this.labels,
    required this.icons,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: AppRadius.rPill,
        border: Border.all(color: _border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (int i = 0; i < labels.length; i++) _seg(i)],
      ),
    );
  }

  Widget _seg(int i) {
    final sel = i == selected;
    return GestureDetector(
      onTap: () => onChanged(i),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: sel ? AppColors.accent : Colors.transparent,
          borderRadius: AppRadius.rPill,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icons[i], size: 16, color: sel ? Colors.white : _textMid),
            const SizedBox(width: 6),
            Text(labels[i],
                style: AppType.label
                    .copyWith(color: sel ? Colors.white : _textMid)),
          ],
        ),
      ),
    );
  }
}

class _LiveIndicator extends StatelessWidget {
  final bool active;
  const _LiveIndicator({required this.active});

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.moduleDapur : AppColors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.soft(color, 0.16),
        borderRadius: AppRadius.rPill,
        border: Border.all(color: AppColors.soft(color, 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: active
                ? _PulseDot(color: color)
                : DecoratedBox(
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 6),
          Text(active ? 'LIVE' : 'SIAP',
              style: AppType.overline.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller.drive(CurveTween(curve: Curves.easeInOut)),
      child: DecoratedBox(
        decoration:
            BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
