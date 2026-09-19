import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../controllers/dashboard_controller.dart';
import '../../models/models.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/ui/ui.dart';
import '../cashier/cashier_screen.dart';
import '../tables/tables_screen.dart';
import '../kitchen/kitchen_screen.dart';
import '../waiter/waiter_screen.dart';
import '../products/products_screen.dart';
import '../transactions/transactions_screen.dart';
import '../settings/settings_screen.dart';

class _MenuItem {
  final String key;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool isPrimary;

  const _MenuItem({
    required this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.isPrimary = false,
  });
}

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final DashboardController _controller;

  static const _roleMenuAccess = <String, Set<String>>{
    'admin': {
      'dashboard', 'produk', 'meja', 'waiter',
      'dapur', 'kasir', 'transaksi', 'pengaturan',
    },
    'manager': {
      'dashboard', 'produk', 'meja', 'waiter',
      'dapur', 'kasir', 'transaksi', 'pengaturan',
    },
    'svp': {
      'dashboard', 'produk', 'meja', 'waiter',
      'dapur', 'kasir', 'transaksi', 'pengaturan',
    },
    'cashier': {'kasir', 'meja', 'transaksi'},
    'waiter': {'meja', 'waiter'},
    'kitchen': {'dapur'},
    'bar': {'dapur'},
  };

  static const _allMenuItems = <_MenuItem>[
    _MenuItem(
      key: 'kasir',
      icon: Icons.point_of_sale_rounded,
      title: 'Kasir',
      subtitle: 'Proses Pembayaran',
      color: AppColors.moduleKasir,
      isPrimary: true,
    ),
    _MenuItem(
      key: 'meja',
      icon: Icons.table_restaurant_rounded,
      title: 'Meja',
      subtitle: 'Status & Manajemen',
      color: AppColors.moduleMeja,
      isPrimary: true,
    ),
    _MenuItem(
      key: 'dapur',
      icon: Icons.soup_kitchen_rounded,
      title: 'Dapur',
      subtitle: 'Display Pesanan',
      color: AppColors.moduleDapur,
    ),
    _MenuItem(
      key: 'waiter',
      icon: Icons.room_service_rounded,
      title: 'Waiter',
      subtitle: 'Layanan Pesanan',
      color: AppColors.moduleWaiter,
    ),
    _MenuItem(
      key: 'produk',
      icon: Icons.inventory_2_rounded,
      title: 'Produk',
      subtitle: 'Kelola Menu',
      color: AppColors.moduleProduk,
    ),
    _MenuItem(
      key: 'transaksi',
      icon: Icons.receipt_long_rounded,
      title: 'Transaksi',
      subtitle: 'Riwayat',
      color: AppColors.moduleTransaksi,
    ),
    _MenuItem(
      key: 'pengaturan',
      icon: Icons.settings_rounded,
      title: 'Pengaturan',
      subtitle: 'Konfigurasi',
      color: AppColors.modulePengaturan,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _controller = DashboardController();
    _controller.addListener(_onStateChanged);
    _controller.initialize();
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
    setState(() {});
  }

  bool _navigating = false;

  void _push(Widget screen) {
    // Guard anti dobel-tap: tap cepat kedua jangan push route ganda.
    if (_navigating) return;
    _navigating = true;
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen))
        .then((_) {
      _navigating = false;
      _controller.refresh();
    });
  }

  Widget _screenFor(String key) {
    switch (key) {
      case 'kasir':
        return const CashierScreen();
      case 'meja':
        return const TablesScreen();
      case 'dapur':
        return const KitchenScreen();
      case 'waiter':
        return const WaiterScreen();
      case 'produk':
        return const ProductsScreen();
      case 'transaksi':
        return const TransactionsScreen();
      case 'pengaturan':
        return const SettingsScreen();
      default:
        return const SizedBox.shrink();
    }
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Selamat Pagi';
    if (hour < 15) return 'Selamat Siang';
    if (hour < 18) return 'Selamat Sore';
    return 'Selamat Malam';
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final user = authState.user;
    final role = user?.role ?? '';
    final allowedMenus = _roleMenuAccess[role] ?? <String>{};
    final dashState = _controller.state;
    final isAdmin = role == 'admin' || role == 'manager' || role == 'svp';

    final allowed =
        _allMenuItems.where((m) => allowedMenus.contains(m.key)).toList();
    final primaries = allowed.where((m) => m.isPrimary).toList();
    final secondaries = allowed.where((m) => !m.isPrimary).toList();

    if (context.isPhone) {
      return _buildPhone(user, role, primaries, secondaries, dashState, isAdmin);
    }
    return _buildTablet(user, role, allowed, primaries, secondaries, dashState, isAdmin);
  }

  // ── Tablet Layout ──────────────────────────────────────────────────────────

  Widget _buildTablet(
    User? user,
    String role,
    List<_MenuItem> allowed,
    List<_MenuItem> primaries,
    List<_MenuItem> secondaries,
    DashboardState dashState,
    bool isAdmin,
  ) {
    return Scaffold(
      body: AppBackground(
        child: Row(
          children: [
            _Sidebar(
              user: user,
              role: role,
              allowed: allowed,
              onTap: (key) => _push(_screenFor(key)),
              onLogout: () => ref.read(authProvider.notifier).logout(),
            ),
            Expanded(
              child: SafeArea(
                left: false,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            context.pagePadX, context.pagePadY, context.pagePadX, 0),
                        child: _WelcomeBar(greeting: _greeting(), user: user, role: role),
                      ),
                    ),
                    if (isAdmin)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                              context.pagePadX, AppSpacing.lg, context.pagePadX, 0),
                          child: _StatsRow(state: dashState),
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(context.pagePadX, AppSpacing.xl,
                          context.pagePadX, context.pagePadY),
                      sliver: SliverToBoxAdapter(
                        child: _MenuBody(
                          primaries: primaries,
                          secondaries: secondaries,
                          onTap: (key) => _push(_screenFor(key)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Phone Layout ───────────────────────────────────────────────────────────

  Widget _buildPhone(
    User? user,
    String role,
    List<_MenuItem> primaries,
    List<_MenuItem> secondaries,
    DashboardState dashState,
    bool isAdmin,
  ) {
    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            _PhoneTopNav(
              user: user,
              greeting: _greeting(),
              onLogout: () => ref.read(authProvider.notifier).logout(),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(context.pagePadX),
                children: [
                  if (isAdmin) ...[
                    _StatsGrid(state: dashState),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  _MenuBody(
                    primaries: primaries,
                    secondaries: secondaries,
                    onTap: (key) => _push(_screenFor(key)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Welcome bar ───────────────────────────────────────────────────────────────

class _WelcomeBar extends StatelessWidget {
  final String greeting;
  final User? user;
  final String role;
  const _WelcomeBar({required this.greeting, required this.user, required this.role});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(greeting, style: AppType.caption.copyWith(color: AppColors.textTertiary)),
              const SizedBox(height: 2),
              Text(
                user?.fullName ?? 'Pengguna',
                style: AppType.h2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        _DateBadge(),
      ],
    );
  }
}

class _DateBadge extends StatelessWidget {
  static const _days = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun',
    'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'
  ];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final label = '${_days[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: AppRadius.rPill,
        border: Border.all(color: AppColors.soft(AppColors.accent, 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.calendar_today_rounded, size: 14, color: AppColors.accentDark),
          const SizedBox(width: AppSpacing.xs),
          Text(label, style: AppType.label.copyWith(color: AppColors.accentDark)),
        ],
      ),
    );
  }
}

// ── Menu body (primaries + secondaries) ───────────────────────────────────────

class _MenuBody extends StatelessWidget {
  final List<_MenuItem> primaries;
  final List<_MenuItem> secondaries;
  final void Function(String key) onTap;

  const _MenuBody({
    required this.primaries,
    required this.secondaries,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isPhone = context.isPhone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (primaries.isNotEmpty) ...[
          const SectionHeader('Operasional'),
          LayoutBuilder(
            builder: (context, c) {
              // 1 kolom di HP, 2 kolom di tablet — kartu utama besar & jelas.
              final cols = isPhone ? 1 : (primaries.length >= 2 ? 2 : 1);
              return _grid(
                cols: cols,
                aspect: isPhone ? 2.9 : 2.5,
                children: primaries
                    .map((m) => _PrimaryCard(item: m, onTap: () => onTap(m.key)))
                    .toList(),
              );
            },
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
        if (secondaries.isNotEmpty) ...[
          const SectionHeader('Manajemen'),
          LayoutBuilder(
            builder: (context, c) {
              final cols = context.responsive<int>(
                compact: 2,
                medium: 3,
                expanded: secondaries.length >= 4 ? 4 : secondaries.length,
                large: secondaries.length >= 4 ? 4 : secondaries.length,
              ).clamp(1, 4);
              return _grid(
                cols: cols,
                aspect: isPhone ? 2.3 : 1.7,
                children: secondaries
                    .map((m) => _SecondaryCard(item: m, onTap: () => onTap(m.key)))
                    .toList(),
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _grid({required int cols, required double aspect, required List<Widget> children}) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: cols,
      mainAxisSpacing: AppSpacing.sm,
      crossAxisSpacing: AppSpacing.sm,
      childAspectRatio: aspect,
      children: children,
    );
  }
}

// ── Sidebar (dinamis: penuh / rail) ───────────────────────────────────────────

class _Sidebar extends StatefulWidget {
  final User? user;
  final String role;
  final List<_MenuItem> allowed;
  final void Function(String key) onTap;
  final VoidCallback onLogout;

  const _Sidebar({
    required this.user,
    required this.role,
    required this.allowed,
    required this.onTap,
    required this.onLogout,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool? _userCollapsed; // null = ikuti ukuran layar; true/false = override manual

  @override
  Widget build(BuildContext context) {
    // Rail otomatis di tablet kecil; penuh di tablet besar. Pengguna bisa override.
    final autoCollapsed = context.sidebarIsRail;
    final collapsed = _userCollapsed ?? autoCollapsed;
    final width = collapsed ? 76.0 : context.responsive(compact: 220.0, expanded: 236.0, large: 260.0);

    final primaries = widget.allowed.where((m) => m.isPrimary).toList();
    final secondaries = widget.allowed.where((m) => !m.isPrimary).toList();

    return AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.emphasized,
      width: width,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: AppColors.sidebarGradient,
          stops: [0.0, 0.5, 1.0],
        ),
        boxShadow: [
          BoxShadow(color: Color(0x33151935), blurRadius: 28, offset: Offset(6, 0)),
        ],
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            _buildHeader(collapsed),
            _divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                children: [
                  if (primaries.isNotEmpty) ...[
                    _SidebarGroup(label: 'Operasional', collapsed: collapsed),
                    ...primaries.map((m) => _SidebarItem(
                          item: m,
                          onTap: () => widget.onTap(m.key),
                          collapsed: collapsed,
                        )),
                    const SizedBox(height: AppSpacing.xs),
                  ],
                  if (secondaries.isNotEmpty) ...[
                    _SidebarGroup(label: 'Manajemen', collapsed: collapsed),
                    ...secondaries.map((m) => _SidebarItem(
                          item: m,
                          onTap: () => widget.onTap(m.key),
                          collapsed: collapsed,
                        )),
                  ],
                ],
              ),
            ),
            _divider(),
            _buildUserSection(collapsed),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(
        height: 1,
        color: AppColors.soft(Colors.white, 0.18),
      );

  Widget _buildHeader(bool collapsed) {
    // Tile logo putih-frosted (glass) dengan ikon hijau — kontras & bersih di
    // atas latar hijau majoo.
    final logo = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: AppColors.soft(Colors.white, 0.92),
        borderRadius: AppRadius.rSm,
        border: Border.all(color: AppColors.soft(Colors.white, 0.5)),
        boxShadow: AppShadows.glow(AppColors.greenDark, strength: 0.3),
      ),
      child: const Icon(Icons.restaurant_menu_rounded, color: AppColors.green, size: 22),
    );

    final canToggle = !context.sidebarIsRail; // di tablet kecil tetap rail

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: GestureDetector(
            onTap: canToggle ? () => setState(() => _userCollapsed = false) : null,
            child: logo,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
      child: Row(
        children: [
          logo,
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nusantara',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
                Text(
                  'POS System',
                  style: TextStyle(fontSize: 11, color: AppColors.soft(Colors.white, 0.8)),
                ),
              ],
            ),
          ),
          if (canToggle)
            GestureDetector(
              onTap: () => setState(() => _userCollapsed = true),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.soft(Colors.white, 0.16),
                  borderRadius: AppRadius.rXs,
                  border: Border.all(color: AppColors.soft(Colors.white, 0.3)),
                ),
                child: const Icon(Icons.chevron_left_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildUserSection(bool collapsed) {
    final initial = (widget.user?.fullName ?? '?').isEmpty
        ? '?'
        : (widget.user?.fullName ?? '?')[0].toUpperCase();

    final avatar = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.soft(Colors.white, 0.22),
        borderRadius: AppRadius.rSm,
        border: Border.all(color: AppColors.soft(Colors.white, 0.35)),
      ),
      alignment: Alignment.center,
      child: Text(initial,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
    );

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          children: [
            avatar,
            const SizedBox(height: AppSpacing.xs),
            AppIconButton(
              icon: Icons.logout_rounded,
              onPressed: widget.onLogout,
              color: Colors.white,
              tooltip: 'Keluar',
              size: 38,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.user?.fullName ?? '',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _roleLabel(widget.role),
                  style: TextStyle(color: AppColors.soft(Colors.white, 0.75), fontSize: 11),
                ),
              ],
            ),
          ),
          AppIconButton(
            icon: Icons.logout_rounded,
            onPressed: widget.onLogout,
            color: Colors.white,
            tooltip: 'Keluar',
            size: 38,
          ),
        ],
      ),
    );
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'admin':
        return 'Administrator';
      case 'manager':
        return 'Manager';
      case 'svp':
        return 'SVP';
      case 'cashier':
        return 'Kasir';
      case 'waiter':
        return 'Waiter';
      case 'kitchen':
        return 'Dapur';
      case 'bar':
        return 'Bar';
      default:
        return role;
    }
  }
}

class _SidebarGroup extends StatelessWidget {
  final String label;
  final bool collapsed;
  const _SidebarGroup({required this.label, required this.collapsed});

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Center(
          child: Container(
            width: 28,
            height: 1,
            color: AppColors.soft(Colors.white, 0.22),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxs),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: AppColors.soft(Colors.white, 0.62),
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final _MenuItem item;
  final VoidCallback onTap;
  final bool collapsed;

  const _SidebarItem({
    required this.item,
    required this.onTap,
    required this.collapsed,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final collapsed = widget.collapsed;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: collapsed ? widget.item.title : '',
        preferBelow: false,
        decoration: const BoxDecoration(
          color: AppColors.greenDark,
          borderRadius: AppRadius.rXs,
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            margin: EdgeInsets.symmetric(horizontal: collapsed ? AppSpacing.xs : AppSpacing.sm, vertical: 2),
            decoration: BoxDecoration(
              color: _hovered ? AppColors.soft(Colors.white, 0.18) : Colors.transparent,
              borderRadius: AppRadius.rSm,
              border: _hovered
                  ? Border.all(color: AppColors.soft(Colors.white, 0.26))
                  : null,
            ),
            padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : AppSpacing.xs, vertical: 7),
            child: collapsed
                ? Center(child: _iconBox(collapsed))
                : Row(
                    children: [
                      _iconBox(collapsed),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          widget.item.title,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: _hovered ? FontWeight.w700 : FontWeight.w500,
                            color: _hovered ? Colors.white : AppColors.soft(Colors.white, 0.82),
                          ),
                        ),
                      ),
                      if (_hovered)
                        const Icon(Icons.chevron_right_rounded,
                            size: 16, color: Colors.white),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _iconBox(bool collapsed) {
    final size = collapsed ? 36.0 : 32.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // Chip putih-frosted (glass) di atas hijau; ikon tetap warna modul agar
        // tiap menu mudah dikenali/diingat.
        color: AppColors.soft(Colors.white, _hovered ? 0.32 : 0.18),
        borderRadius: AppRadius.rXs,
        border: Border.all(color: AppColors.soft(Colors.white, 0.22)),
      ),
      child: Icon(
        widget.item.icon,
        size: collapsed ? 19 : 17,
        color: Colors.white,
      ),
    );
  }
}

// ── Stats Row (tablet) ────────────────────────────────────────────────────────

class _StatsRow extends StatelessWidget {
  final DashboardState state;
  const _StatsRow({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.isLoading) {
      return const SizedBox(height: 76, child: AppLoader());
    }
    final cards = _statCards(state, compact: false);
    return Row(
      children: [
        for (int i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }
}

// ── Stats Grid (phone) ────────────────────────────────────────────────────────

class _StatsGrid extends StatelessWidget {
  final DashboardState state;
  const _StatsGrid({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.isLoading) {
      return const SizedBox(height: 60, child: AppLoader());
    }
    // 2 kolom di HP; aspect lebih tinggi (2.4) memberi ruang vertikal agar
    // kartu tak overflow di portrait sempit (~360px).
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: context.gridColumns(minTileWidth: 150).clamp(1, 2),
      mainAxisSpacing: AppSpacing.xs,
      crossAxisSpacing: AppSpacing.xs,
      childAspectRatio: 2.4,
      children: _statCards(state, compact: true),
    );
  }
}

List<Widget> _statCards(DashboardState state, {required bool compact}) => [
      _StatCard(
        label: compact ? 'Revenue' : 'Revenue Hari Ini',
        value: CurrencyHelper.format(state.todayRevenue),
        icon: Icons.trending_up_rounded,
        color: AppColors.success,
        compact: compact,
      ),
      _StatCard(
        label: 'Order Aktif',
        value: '${state.totalActiveOrders}',
        icon: Icons.receipt_long_rounded,
        color: AppColors.accent, // SECONDARY gold
        compact: compact,
      ),
      _StatCard(
        label: 'Meja Terisi',
        value: '${state.occupiedTables}/${state.totalTables}',
        icon: Icons.table_restaurant_rounded,
        color: AppColors.brand,
        compact: compact,
      ),
      _StatCard(
        label: compact ? 'Shift' : 'Status Shift',
        value: state.hasActiveShift ? 'Aktif' : 'Tidak Ada',
        icon: Icons.schedule_rounded,
        color: state.hasActiveShift ? AppColors.brand : AppColors.textTertiary,
        compact: compact,
      ),
    ];

// ── Stat Card ─────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool compact;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.all(compact ? AppSpacing.sm : AppSpacing.md),
      child: Row(
        children: [
          IconBadge(icon: icon, color: color, size: compact ? 34 : 46),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  value,
                  style: (compact ? AppType.title : AppType.amount).copyWith(color: color),
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
          ),
        ],
      ),
    );
  }
}

// ── Primary Card ──────────────────────────────────────────────────────────────

class _PrimaryCard extends StatelessWidget {
  final _MenuItem item;
  final VoidCallback onTap;

  const _PrimaryCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      accent: item.color,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          IconBadge(icon: item.icon, color: item.color, size: 56, filled: true),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.h2,
                ),
                const SizedBox(height: 2),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption,
                ),
              ],
            ),
          ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.soft(item.color, 0.1),
              borderRadius: AppRadius.rXs,
            ),
            child: Icon(Icons.arrow_forward_rounded, size: 18, color: item.color),
          ),
        ],
      ),
    );
  }
}

// ── Secondary Card ────────────────────────────────────────────────────────────

class _SecondaryCard extends StatelessWidget {
  final _MenuItem item;
  final VoidCallback onTap;

  const _SecondaryCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Row(
        children: [
          IconBadge(icon: item.icon, color: item.color, size: 40),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label,
                ),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption.copyWith(color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Phone Top Nav ─────────────────────────────────────────────────────────────

class _PhoneTopNav extends StatelessWidget {
  final User? user;
  final String greeting;
  final VoidCallback onLogout;

  const _PhoneTopNav({required this.user, required this.greeting, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    final initial = (user?.fullName ?? '?').isEmpty ? '?' : (user?.fullName ?? '?')[0].toUpperCase();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: AppColors.sidebarGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: Color(0x22065F46), blurRadius: 14, offset: Offset(0, 6)),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: AppRadius.rSm,
                ),
                child: const Icon(Icons.restaurant_menu_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(greeting,
                        style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.85))),
                    Text(
                      user?.fullName ?? 'Nusantara POS',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Text(initial,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
              ),
              const SizedBox(width: AppSpacing.xs),
              GestureDetector(
                onTap: onLogout,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: AppRadius.rXs,
                  ),
                  child: const Icon(Icons.logout_rounded, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
