import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../repositories/product_repository.dart';
import '../../services/cash_drawer_service.dart';
import '../../services/printer_service.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';

class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen>
    with SingleTickerProviderStateMixin {
  final _service = PrinterService();
  final _productRepo = ProductRepository();
  late final TabController _tabController;

  static const _accent = AppColors.brand; // seragam hijau primer (bukan biru)

  // Saved printers
  List<PrinterDevice> _saved = [];

  // Kategori menu (untuk assign per printer)
  List<Category> _categories = [];

  // Laci kasir (cash drawer) — dibuka lewat printer struk.
  CashDrawerSettings _drawer = const CashDrawerSettings();
  bool _drawerTesting = false;

  // Bluetooth scan
  List<PrinterDevice> _btDevices = [];
  bool _btScanning = false;
  String? _btError;

  // LAN scan
  List<PrinterDevice> _lanDevices = [];
  bool _lanScanning = false;
  int _lanProgress = 0;
  String? _lanError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadSaved();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    final results = await Future.wait([
      _service.getSavedPrinters(),
      _productRepo.getCategories(),
      CashDrawerService.instance.settings(),
    ]);
    if (mounted) {
      setState(() {
        _saved = results[0] as List<PrinterDevice>;
        _categories = results[1] as List<Category>;
        _drawer = results[2] as CashDrawerSettings;
      });
    }
  }

  // ── Bluetooth ──────────────────────────────────────────────────────────────

  Future<void> _scanBluetooth() async {
    setState(() {
      _btScanning = true;
      _btError = null;
      _btDevices = [];
    });
    try {
      final devices = await _service.scanBluetooth();
      if (mounted) setState(() => _btDevices = devices);
    } catch (e) {
      if (mounted) setState(() => _btError = e.toString());
    } finally {
      if (mounted) setState(() => _btScanning = false);
    }
  }

  // ── LAN ────────────────────────────────────────────────────────────────────

  Future<void> _scanLan() async {
    setState(() {
      _lanScanning = true;
      _lanError = null;
      _lanDevices = [];
      _lanProgress = 0;
    });
    try {
      final devices = await _service.scanLan(
        onProgress: (current, total) {
          if (mounted) setState(() => _lanProgress = current);
        },
      );
      if (mounted) setState(() => _lanDevices = devices);
    } catch (e) {
      if (mounted) setState(() => _lanError = e.toString());
    } finally {
      if (mounted) setState(() => _lanScanning = false);
    }
  }

  /// Tambah printer LAN manual via IP:port — jalan keluar bila auto-scan gagal
  /// (WiFi client-isolation, beda subnet, atau printer lambat balas).
  void _showManualLanDialog() {
    final ipCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '9100');
    final nameCtrl = TextEditingController();
    String? error;
    var testing = false;

    showAppModal(
      context,
      title: 'Tambah Printer LAN',
      icon: Icons.lan_rounded,
      accent: _accent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: ipCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Alamat IP printer *',
                hintText: 'mis. 192.168.1.50',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: portCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '9100',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nama (opsional)',
                    ),
                  ),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(error!,
                  style: AppType.caption.copyWith(color: AppColors.danger)),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: AppButton.neutral('Batal',
                      onPressed: () => Navigator.pop(ctx)),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppButton(
                    label: 'Tes & Simpan',
                    icon: Icons.check_rounded,
                    accent: _accent,
                    loading: testing,
                    onPressed: () async {
                      final ip = ipCtrl.text.trim();
                      final port =
                          int.tryParse(portCtrl.text.trim()) ?? 9100;
                      if (!_isValidIp(ip)) {
                        setS(() => error = 'Format IP tidak valid');
                        return;
                      }
                      setS(() {
                        testing = true;
                        error = null;
                      });
                      final reachable = await _service.pingLan(ip, port);
                      if (!ctx.mounted) return;
                      if (!reachable) {
                        setS(() {
                          testing = false;
                          error =
                              'Tidak bisa terhubung ke $ip:$port. Pastikan printer menyala & satu jaringan.';
                        });
                        return;
                      }
                      final device = PrinterDevice(
                        name: nameCtrl.text.trim().isEmpty
                            ? 'Printer LAN ($ip)'
                            : nameCtrl.text.trim(),
                        address: '$ip:$port',
                        type: PrinterType.lan,
                      );
                      Navigator.pop(ctx);
                      await _save(device);
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

  bool _isValidIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _save(PrinterDevice device) async {
    await _service.savePrinter(device);
    await _loadSaved();
    if (mounted) {
      showAppSnack(context, '${device.name} disimpan');
    }
  }

  /// Aktif/nonaktifkan peran khusus (Checker/Kasir).
  Future<void> _toggleRole(PrinterDevice device, String role) async {
    await _service.savePrinter(device.toggleRole(role));
    await _loadSaved();
  }

  /// Aktif/nonaktifkan kategori menu yang dicetak printer ini.
  Future<void> _toggleCategory(PrinterDevice device, String categoryId) async {
    await _service.savePrinter(device.toggleCategory(categoryId));
    await _loadSaved();
  }

  /// Ubah lebar kertas printer (32 = 58mm, 48 = 80mm).
  Future<void> _setPaper(PrinterDevice device, int cols) async {
    await _service.savePrinter(device.copyWith(paperCols: cols));
    await _loadSaved();
  }

  /// Ubah rangkap cetak struk (1 = biasa, 2 = + salinan "COPY").
  Future<void> _setCopies(PrinterDevice device, int copies) async {
    await _service.savePrinter(device.copyWith(copies: copies));
    await _loadSaved();
  }

  Future<void> _remove(PrinterDevice device) async {
    final ok = await showAppConfirm(
      context,
      title: 'Hapus Printer?',
      message: 'Hapus "${device.name}" dari daftar?',
      confirmText: 'Hapus',
      icon: Icons.print_disabled_rounded,
      destructive: true,
    );
    if (ok) {
      await _service.removePrinter(device.address);
      await _loadSaved();
    }
  }

  Future<void> _testPrint(PrinterDevice device) async {
    showAppSnack(context, 'Mengirim test print ke ${device.name}...');
    try {
      await _service.testPrint(device);
      if (mounted) {
        showAppSnack(context, 'Test print berhasil: ${device.name}');
      }
    } catch (e) {
      if (mounted) {
        showAppSnack(context, 'Gagal: $e', isError: true);
      }
    }
  }

  // ── Laci kasir (cash drawer) ───────────────────────────────────────────────

  Future<void> _saveDrawer(CashDrawerSettings next) async {
    await CashDrawerService.instance.save(next);
    if (mounted) setState(() => _drawer = next);
  }

  /// Tes buka laci memakai pengaturan yang SEDANG tampil (pin & durasi pulsa),
  /// supaya kasir bisa mencoba kombinasi sebelum yakin menyimpannya.
  Future<void> _testDrawer() async {
    setState(() => _drawerTesting = true);
    try {
      await CashDrawerService.instance
          .open(pin: _drawer.pin, pulseMs: _drawer.pulseMs);
      if (mounted) showAppSnack(context, 'Perintah buka laci terkirim');
    } catch (e) {
      if (mounted) {
        showAppSnack(context, 'Gagal buka laci: ${e.toString().replaceFirst('Exception: ', '')}',
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _drawerTesting = false);
    }
  }

  /// Nama printer yang akan memicu laci (mengikuti aturan pemilihan di service).
  String get _drawerPrinterLabel {
    if (_saved.isEmpty) return 'belum ada printer';
    if (_drawer.printerAddress.isNotEmpty) {
      for (final p in _saved) {
        if (p.address == _drawer.printerAddress) return p.name;
      }
    }
    final cashiers =
        _saved.where((p) => p.hasRole(PrinterRole.cashier)).toList();
    if (cashiers.isNotEmpty) return cashiers.first.name;
    return _saved
        .firstWhere((p) => !p.hasRole(PrinterRole.checker),
            orElse: () => _saved.first)
        .name;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            const AppPageHeader(
              title: 'Pengaturan Printer',
              subtitle: 'Bluetooth & LAN (ESC-POS)',
              icon: Icons.print_rounded,
              accent: _accent,
            ),
            Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: TabBar(
                controller: _tabController,
                labelColor: _accent,
                unselectedLabelColor: AppColors.textTertiary,
                indicatorColor: _accent,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(icon: Icon(Icons.print_rounded), text: 'Tersimpan'),
                  Tab(icon: Icon(Icons.bluetooth_rounded), text: 'Bluetooth'),
                  Tab(icon: Icon(Icons.lan_rounded), text: 'LAN'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildSavedTab(),
                  _buildBluetoothTab(),
                  _buildLanTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab: Saved ─────────────────────────────────────────────────────────────

  Widget _buildSavedTab() {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _buildCashDrawerCard(),
        const SizedBox(height: AppSpacing.md),
        if (_saved.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: AppSpacing.lg),
            child: EmptyState(
              icon: Icons.print_disabled_rounded,
              title: 'Belum ada printer tersimpan',
              message: 'Scan Bluetooth atau LAN untuk menambahkan.',
              accent: _accent,
            ),
          )
        else
          for (var i = 0; i < _saved.length; i++)
            Padding(
              padding: EdgeInsets.only(
                  bottom: i == _saved.length - 1 ? 0 : AppSpacing.sm),
              child: _PrinterTile(
                device: _saved[i],
                isSaved: true,
                onSave: null,
                onRemove: () => _remove(_saved[i]),
                onTest: () => _testPrint(_saved[i]),
                onRoleToggle: (role) => _toggleRole(_saved[i], role),
                categories: _categories,
                onCategoryToggle: (catId) => _toggleCategory(_saved[i], catId),
                onPaperChange: (cols) => _setPaper(_saved[i], cols),
                onCopiesChange: (n) => _setCopies(_saved[i], n),
              ),
            ),
      ],
    );
  }

  /// Kartu pengaturan LACI KASIR. Laci POS menempel di port RJ11 printer struk,
  /// jadi pengaturannya duduk bersama printer — bukan di layar terpisah.
  Widget _buildCashDrawerCard() {
    Widget chip(String label, bool selected, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.surfaceMuted,
            borderRadius: AppRadius.rXs,
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.textTertiary,
              )),
        ),
      );
    }

    Widget group(IconData icon, String label, List<Widget> chips) => Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: AppColors.moduleKasir),
              const SizedBox(width: 5),
              Text(label, style: AppType.label),
            ]),
            ...chips,
          ],
        );

    return AppCard(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconBadge(
                icon: Icons.point_of_sale_rounded,
                color: AppColors.moduleKasir,
                size: 44,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Laci Kasir', style: AppType.title),
                    const SizedBox(height: 2),
                    Text(
                      _drawer.enabled
                          ? 'Terbuka otomatis saat pembayaran lunas'
                          : 'Otomatis mati — buka lewat tombol "Buka Laci"',
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              Switch(
                value: _drawer.enabled,
                onChanged: (v) => _saveDrawer(_drawer.copyWith(enabled: v)),
              ),
            ],
          ),
          const Divider(height: AppSpacing.lg, color: AppColors.border),
          group(Icons.payments_outlined, 'Buka untuk:', [
            chip('Tunai saja', _drawer.cashOnly,
                () => _saveDrawer(_drawer.copyWith(cashOnly: true))),
            chip('Semua metode', !_drawer.cashOnly,
                () => _saveDrawer(_drawer.copyWith(cashOnly: false))),
          ]),
          const SizedBox(height: AppSpacing.sm),
          group(Icons.print_rounded, 'Printer laci:', [
            chip('Ikut printer kasir', _drawer.printerAddress.isEmpty,
                () => _saveDrawer(_drawer.copyWith(printerAddress: ''))),
            for (final p in _saved)
              chip(p.name, _drawer.printerAddress == p.address,
                  () => _saveDrawer(_drawer.copyWith(printerAddress: p.address))),
          ]),
          const SizedBox(height: AppSpacing.sm),
          group(Icons.cable_rounded, 'Pin konektor:', [
            chip('Pin 2', _drawer.pin == 2,
                () => _saveDrawer(_drawer.copyWith(pin: 2))),
            chip('Pin 5', _drawer.pin == 5,
                () => _saveDrawer(_drawer.copyWith(pin: 5))),
          ]),
          const SizedBox(height: AppSpacing.sm),
          group(Icons.timer_outlined, 'Durasi pulsa:', [
            for (final ms in CashDrawerSettings.pulseChoices)
              chip('$ms ms', _drawer.pulseMs == ms,
                  () => _saveDrawer(_drawer.copyWith(pulseMs: ms))),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Laci dibuka lewat printer: $_drawerPrinterLabel. '
            'Bila laci tidak bereaksi, coba ganti pin (2 ↔ 5) atau perpanjang durasi pulsa.',
            style: AppType.caption.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Tes Buka Laci',
            icon: Icons.lock_open_rounded,
            accent: AppColors.accent,
            size: AppButtonSize.medium,
            loading: _drawerTesting,
            onPressed: _drawerTesting || _saved.isEmpty ? null : _testDrawer,
          ),
        ],
      ),
    );
  }

  // ── Tab: Bluetooth ─────────────────────────────────────────────────────────

  Widget _buildBluetoothTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: AppButton(
            label: _btScanning ? 'Mencari...' : 'Scan Bluetooth',
            icon: _btScanning ? null : Icons.bluetooth_searching_rounded,
            accent: _accent,
            loading: _btScanning,
            onPressed: _btScanning ? null : _scanBluetooth,
          ),
        ),
        if (_btError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: _ErrorBanner(message: _btError!),
          ),
        Expanded(
          child: _btDevices.isEmpty && !_btScanning
              ? const EmptyState(
                  icon: Icons.bluetooth_rounded,
                  title: 'Cari printer Bluetooth',
                  message:
                      'Tekan Scan untuk mencari printer\n(hanya perangkat yang sudah dipasangkan).',
                  accent: _accent,
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  itemCount: _btDevices.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) {
                    final d = _btDevices[i];
                    final alreadySaved =
                        _saved.any((s) => s.address == d.address);
                    return _PrinterTile(
                      device: d,
                      isSaved: alreadySaved,
                      onSave: alreadySaved ? null : () => _save(d),
                      onRemove: alreadySaved ? () => _remove(d) : null,
                      onTest: () => _testPrint(d),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── Tab: LAN ───────────────────────────────────────────────────────────────

  Widget _buildLanTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppButton(
                label: _lanScanning
                    ? 'Scanning... ($_lanProgress/254)'
                    : 'Scan Printer LAN (port 9100)',
                icon: _lanScanning ? null : Icons.search_rounded,
                accent: _accent,
                onPressed: _lanScanning ? null : _scanLan,
              ),
              if (_lanScanning) ...[
                const SizedBox(height: AppSpacing.sm),
                ClipRRect(
                  borderRadius: AppRadius.rPill,
                  child: LinearProgressIndicator(
                    value: _lanProgress / 254,
                    minHeight: 6,
                    color: _accent,
                    backgroundColor: AppColors.soft(_accent, 0.12),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              AppButton.neutral(
                'Tambah manual via IP',
                icon: Icons.add_link_rounded,
                onPressed: _lanScanning ? null : _showManualLanDialog,
              ),
            ],
          ),
        ),
        if (_lanError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: _ErrorBanner(message: _lanError!),
          ),
        Expanded(
          child: _lanDevices.isEmpty && !_lanScanning
              ? const EmptyState(
                  icon: Icons.lan_rounded,
                  title: 'Cari printer LAN',
                  message:
                      'Tekan Scan untuk mendeteksi printer di jaringan\n(port 9100 / ESC-POS).',
                  accent: _accent,
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  itemCount: _lanDevices.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) {
                    final d = _lanDevices[i];
                    final alreadySaved =
                        _saved.any((s) => s.address == d.address);
                    return _PrinterTile(
                      device: d,
                      isSaved: alreadySaved,
                      onSave: alreadySaved ? null : () => _save(d),
                      onRemove: alreadySaved ? () => _remove(d) : null,
                      onTest: () => _testPrint(d),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ─── Reusable Widgets ─────────────────────────────────────────────────────────

class _PrinterTile extends StatelessWidget {
  final PrinterDevice device;
  final bool isSaved;
  final VoidCallback? onSave;
  final VoidCallback? onRemove;
  final VoidCallback? onTest;
  final void Function(String role)? onRoleToggle;
  final List<Category> categories;
  final void Function(String categoryId)? onCategoryToggle;
  final void Function(int cols)? onPaperChange;
  final void Function(int copies)? onCopiesChange;

  const _PrinterTile({
    required this.device,
    required this.isSaved,
    required this.onSave,
    required this.onRemove,
    required this.onTest,
    this.onRoleToggle,
    this.categories = const [],
    this.onCategoryToggle,
    this.onPaperChange,
    this.onCopiesChange,
  });

  @override
  Widget build(BuildContext context) {
    final isBt = device.type == PrinterType.bluetooth;
    // Ikon device seragam hijau primer (Bluetooth maupun LAN) — bukan biru.
    const color = AppColors.moduleKasir;

    return AppCard(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconBadge(
                icon: isBt ? Icons.bluetooth_rounded : Icons.lan_rounded,
                color: color,
                size: 44,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name,
                        style: AppType.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(device.address, style: AppType.caption),
                    if (isSaved) ...[
                      const SizedBox(height: AppSpacing.xs),
                      const StatusPill(
                        label: 'Tersimpan',
                        color: AppColors.success,
                        icon: Icons.check_rounded,
                      ),
                    ],
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onTest != null)
                    AppIconButton(
                      icon: Icons.print_rounded,
                      color: AppColors.accent, // gold: beda dari Simpan/Hapus
                      tooltip: 'Test Print',
                      size: 40,
                      onPressed: onTest,
                    ),
                  if (onSave != null)
                    AppIconButton(
                      icon: Icons.save_rounded,
                      color: AppColors.success,
                      tooltip: 'Simpan',
                      size: 40,
                      onPressed: onSave,
                    ),
                  if (onRemove != null)
                    AppIconButton(
                      icon: Icons.delete_outline_rounded,
                      color: AppColors.danger,
                      tooltip: 'Hapus',
                      size: 40,
                      onPressed: onRemove,
                    ),
                ],
              ),
            ],
          ),
          if (isSaved && onRoleToggle != null) ...[
            const Divider(height: AppSpacing.lg, color: AppColors.border),
            _buildCategorySelector(),
            const SizedBox(height: AppSpacing.sm),
            _buildRoleSelector(),
            const SizedBox(height: AppSpacing.sm),
            _buildPaperSelector(),
            const SizedBox(height: AppSpacing.sm),
            _buildCopiesSelector(),
          ],
        ],
      ),
    );
  }

  /// Pilih lebar kertas: 58mm (32 kolom) / 80mm (48 kolom).
  Widget _buildPaperSelector() {
    Widget chip(String label, int cols) {
      final selected = device.paperCols == cols;
      return GestureDetector(
        onTap: () => onPaperChange?.call(cols),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 6),
          decoration: BoxDecoration(
            // Segmented selector aktif → aksen GOLD (identitas sekunder).
            color: selected ? AppColors.accent : AppColors.surfaceMuted,
            borderRadius: AppRadius.rXs,
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.textTertiary,
              )),
        ),
      );
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.straighten_rounded,
              size: 14, color: AppColors.moduleKasir),
          const SizedBox(width: 5),
          Text('Lebar kertas:', style: AppType.label),
        ]),
        chip('58mm', 32),
        chip('80mm', 48),
      ],
    );
  }

  /// Rangkap cetak: 1× (biasa) / 2× (rangkap). Berlaku untuk struk kasir
  /// (salinan ke-2 bertanda "COPY") MAUPUN tiket dapur/bar (tiket kerja
  /// identik, mis. lini masak + expo).
  Widget _buildCopiesSelector() {
    Widget chip(String label, int n) {
      final selected = device.copies == n;
      return GestureDetector(
        onTap: () => onCopiesChange?.call(n),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : AppColors.surfaceMuted,
            borderRadius: AppRadius.rXs,
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.textTertiary,
              )),
        ),
      );
    }

    // Wrap agar chip tak terpotong keluar kartu saat sempit (bisa di-tap).
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.content_copy_rounded,
              size: 14, color: AppColors.moduleKasir),
          const SizedBox(width: 5),
          Text('Rangkap cetak:', style: AppType.label),
        ]),
        chip('1×', 1),
        chip('2× (Copy)', 2),
      ],
    );
  }

  /// Pilih KATEGORI menu yang dicetak printer ini (bisa lebih dari satu).
  Widget _buildCategorySelector() {
    final isChecker = device.hasRole(PrinterRole.checker);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.restaurant_menu_rounded,
                size: 14, color: AppColors.success),
            const SizedBox(width: 5),
            Text('Cetak kategori menu:', style: AppType.label),
          ],
        ),
        const SizedBox(height: 6),
        if (isChecker)
          Text(
            'Printer ini Checker — otomatis mencetak SEMUA pesanan.',
            style: AppType.caption.copyWith(color: AppColors.moduleProduk),
          )
        else if (categories.isEmpty)
          Text('Belum ada kategori menu.',
              style: AppType.caption.copyWith(color: AppColors.textTertiary))
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: categories.map((cat) {
              final selected = device.printsCategory(cat.id);
              return GestureDetector(
                onTap: () => onCategoryToggle?.call(cat.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.success
                        : AppColors.surfaceMuted,
                    borderRadius: AppRadius.rXs,
                    border: Border.all(
                        color: selected
                            ? AppColors.success
                            : AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(selected ? Icons.check_rounded : Icons.add_rounded,
                          size: 13,
                          color: selected
                              ? Colors.white
                              : AppColors.textTertiary),
                      const SizedBox(width: 4),
                      Text(cat.name,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? Colors.white
                                : AppColors.textSecondary,
                          )),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        if (!isChecker &&
            device.categoryIds.isEmpty &&
            !device.hasRole(PrinterRole.cashier))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '⚠ Belum ada kategori/peran — printer ini hanya dipakai bila tak ada printer lain.',
              style: AppType.caption.copyWith(color: AppColors.warning),
            ),
          ),
      ],
    );
  }

  /// Peran khusus: Checker (salinan seluruh pesanan) & Kasir (struk).
  Widget _buildRoleSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Peran khusus:', style: AppType.label),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: PrinterRole.selectable.map((value) {
            final label = PrinterRole.labels[value] ?? value;
            final selected = device.hasRole(value);
            return GestureDetector(
              onTap: () => onRoleToggle!(value),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: 6),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.moduleProduk
                      : AppColors.surfaceMuted,
                  borderRadius: AppRadius.rXs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 13,
                      color: selected ? Colors.white : AppColors.textTertiary,
                    ),
                    const SizedBox(width: 5),
                    Text(label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? Colors.white
                              : AppColors.textSecondary,
                        )),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.dangerSoft,
        borderRadius: AppRadius.rSm,
        border: Border.all(color: AppColors.soft(AppColors.danger, 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppColors.danger, size: 18),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(message,
                style: AppType.bodySm.copyWith(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}
