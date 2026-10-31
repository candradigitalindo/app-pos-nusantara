import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app.dart';
import '../../controllers/settings_controller.dart';
import '../../models/models.dart';
import '../../repositories/order_repository.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/device_role_service.dart';
import '../../services/logo_service.dart';
import '../../services/outlet_service.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';
import 'print_queue_screen.dart';
import 'user_management_screen.dart';
import 'printer_settings_screen.dart';
import 'sync_status_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final SettingsController _controller;
  late final TabController _tabController;
  final _orderRepo = OrderRepository();

  static const _accent = AppColors.modulePengaturan;

  // Outlet
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _socialCtrl = TextEditingController();
  final _footerCtrl = TextEditingController();
  final _targetSpendCtrl = TextEditingController();

  // Cloud
  final _apiUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _outletIdCtrl = TextEditingController();
  CloudEnv _cloudEnv = CloudEnv.production;
  /// URL terakhir yang diisi saat mode development, dipakai lagi kalau
  /// pengguna bolak-balik production ↔ development.
  String _devApiUrl = '';
  bool _syncEnabled = false;
  int _syncInterval = 5;
  bool _testingConnection = false;
  DateTime? _lastSyncAt;
  Timer? _lastSyncRefresh;

  // Logo struk (disimpan lokal via LogoService)
  Uint8List? _logoPreview = LogoService.instance.previewBytes;
  bool _logoBusy = false;

  // Additional charges
  List<AdditionalCharge> _charges = [];
  bool _loadingCharges = false;

  // Versi aplikasi (nama versi + build code asli dari versionCode)
  String _appVersion = 'POS Resto';

  static const _tabs = [
    Tab(icon: Icon(Icons.store_rounded), text: 'Outlet'),
    Tab(icon: Icon(Icons.receipt_rounded), text: 'Biaya'),
    Tab(icon: Icon(Icons.cloud_rounded), text: 'Cloud'),
    Tab(icon: Icon(Icons.storage_rounded), text: 'Data'),
    Tab(icon: Icon(Icons.tune_rounded), text: 'Aplikasi'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _controller = SettingsController();
    _controller.addListener(_onStateChanged);
    _controller.loadSettings().then((_) => _populate());
    _loadCharges();
    _loadAppVersion();
    _refreshLastSync();
    // Refresh waktu sync terakhir tiap 20 detik agar perubahan dari sync
    // background ikut terlihat tanpa keluar dari layar.
    _lastSyncRefresh =
        Timer.periodic(const Duration(seconds: 20), (_) => _refreshLastSync());
  }

  Future<void> _refreshLastSync() async {
    final t = await CloudSyncService.instance.lastSyncAt();
    if (!mounted) return;
    setState(() => _lastSyncAt = t);
  }

  /// Muat versi aplikasi memakai build code ASLI (versionCode → buildNumber),
  /// bukan angka statis. Contoh: "POS Resto v1.2.0 (build 83213480)".
  Future<void> _loadAppVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersion =
          'POS Resto v${pkg.version} (build ${pkg.buildNumber})');
    } catch (_) {
      // biarkan default
    }
  }

  String _formatLastSync(DateTime? t) {
    if (t == null) return 'belum pernah';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'baru saja';
    if (d.inMinutes < 60) return '${d.inMinutes} menit lalu';
    if (d.inHours < 24) return '${d.inHours} jam lalu';
    return '${d.inDays} hari lalu';
  }

  @override
  void dispose() {
    _lastSyncRefresh?.cancel();
    _tabController.dispose();
    _controller.removeListener(_onStateChanged);
    _controller.dispose();
    for (final c in [
      _nameCtrl, _codeCtrl, _addressCtrl, _phoneCtrl,
      _socialCtrl, _footerCtrl, _targetSpendCtrl,
      _apiUrlCtrl, _apiKeyCtrl, _outletIdCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    final msg =
        _controller.state.successMessage ?? _controller.state.errorMessage;
    if (msg != null) {
      final isSuccess = _controller.state.successMessage != null;
      _controller.clearMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showAppSnack(context, msg, isError: !isSuccess);
      });
    }
  }

  void _populate() {
    if (!mounted) return; // dipanggil dari .then() async — State bisa sudah dibuang
    final info = _controller.state.outletInfo;
    _nameCtrl.text = info.name;
    _codeCtrl.text = info.code;
    _addressCtrl.text = info.address;
    _phoneCtrl.text = info.phone;
    _socialCtrl.text = info.socialMedia;
    _footerCtrl.text = info.receiptFooter;
    _targetSpendCtrl.text =
        info.targetSpendPerPax > 0 ? info.targetSpendPerPax.toString() : '';
    _apiUrlCtrl.text = info.cloudApiUrl;
    _apiKeyCtrl.text = info.cloudApiKey;
    _outletIdCtrl.text = info.cloudOutletId;
    setState(() {
      _cloudEnv = info.cloudEnv;
      if (_cloudEnv == CloudEnv.development) _devApiUrl = info.cloudApiUrl;
      _syncEnabled = info.syncEnabled;
      _syncInterval = info.syncInterval;
    });
  }

  Future<void> _loadCharges() async {
    setState(() => _loadingCharges = true);
    try {
      final charges = await _orderRepo.getActiveCharges();
      if (mounted) setState(() { _charges = charges; _loadingCharges = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingCharges = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            const AppPageHeader(
              title: 'Pengaturan',
              subtitle: 'Konfigurasi outlet & aplikasi',
              icon: Icons.settings_rounded,
              accent: _accent,
            ),
            Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              child: TabBar(
                controller: _tabController,
                tabs: _tabs,
                labelColor: _accent,
                unselectedLabelColor: AppColors.textTertiary,
                indicatorColor: _accent,
                indicatorSize: TabBarIndicatorSize.label,
                labelStyle: AppType.caption.copyWith(fontWeight: FontWeight.w700),
                unselectedLabelStyle: AppType.caption,
              ),
            ),
            Expanded(
              child: _controller.state.isLoading
                  ? const AppLoader(label: 'Memuat pengaturan...')
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _tabOutlet(),
                        _tabBiaya(),
                        _tabCloud(),
                        _tabData(),
                        _tabAplikasi(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Tab: Outlet ───────────────────────────────────────────────────────────

  Future<void> _pickLogo() async {
    if (_logoBusy) return;
    try {
      final xfile = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
      );
      if (xfile == null) return;
      setState(() => _logoBusy = true);
      final bytes = await xfile.readAsBytes();
      final err = await LogoService.instance.saveFromBytes(bytes);
      if (!mounted) return;
      setState(() {
        _logoBusy = false;
        _logoPreview = LogoService.instance.previewBytes;
      });
      showAppSnack(context, err ?? 'Logo struk tersimpan.', isError: err != null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _logoBusy = false);
      showAppSnack(context, 'Gagal memilih gambar: $e', isError: true);
    }
  }

  Future<void> _removeLogo() async {
    final ok = await showAppConfirm(
      context,
      title: 'Hapus Logo Struk?',
      message: 'Logo akan dihapus dari struk pembayaran & tagihan.',
      confirmText: 'Hapus',
      icon: Icons.delete_rounded,
      destructive: true,
    );
    if (!ok) return;
    await LogoService.instance.remove();
    if (!mounted) return;
    setState(() => _logoPreview = null);
    showAppSnack(context, 'Logo struk dihapus.');
  }

  Widget _logoCard() {
    final has = _logoPreview != null;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconBadge(
                  icon: Icons.image_rounded, color: AppColors.accent, size: 40),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Logo Struk', style: AppType.title),
                    Text('Tampil di atas struk pembayaran & tagihan',
                        style: AppType.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Pratinjau (latar putih seperti kertas struk)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 96, maxHeight: 170),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: AppRadius.rMd,
              border: Border.all(color: AppColors.border),
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: has
                ? Image.memory(_logoPreview!, fit: BoxFit.contain)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add_photo_alternate_rounded,
                          size: 34, color: AppColors.textTertiary),
                      const SizedBox(height: 6),
                      Text('Belum ada logo',
                          style: AppType.caption
                              .copyWith(color: AppColors.textTertiary)),
                    ],
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // Aturan ukuran
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.infoSoft,
              borderRadius: AppRadius.rSm,
              border: Border.all(color: AppColors.soft(AppColors.info, 0.25)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 16, color: AppColors.info),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Gunakan gambar hitam-putih kontras tinggi (dicetak monokrom). '
                    'Lebar ideal 384px untuk 58mm / 576px untuk 80mm, tinggi maks ±200px. '
                    'Ukuran & posisi diatur otomatis (dipusatkan, tak boros kertas).',
                    style: AppType.caption
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: has ? 'Ganti Logo' : 'Unggah Logo',
                  icon: Icons.upload_rounded,
                  onPressed: _logoBusy ? null : _pickLogo,
                  loading: _logoBusy,
                  variant: AppButtonVariant.tonal,
                  accent: AppColors.accent,
                ),
              ),
              if (has) ...[
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  label: 'Hapus',
                  icon: Icons.delete_outline_rounded,
                  onPressed: _logoBusy ? null : _removeLogo,
                  variant: AppButtonVariant.danger,
                  expanded: false,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _tabOutlet() {
    // Kolom DATA outlet (form + tombol simpan).
    final dataCol = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _group([
          _field(_nameCtrl, 'Nama Outlet', Icons.store_rounded),
          _div(),
          _field(_codeCtrl, 'Kode Outlet', Icons.tag_rounded),
          _div(),
          _field(_addressCtrl, 'Alamat', Icons.location_on_rounded,
              maxLines: 2),
          _div(),
          _field(_phoneCtrl, 'Telepon', Icons.phone_rounded,
              keyboardType: TextInputType.phone),
          _div(),
          _field(_socialCtrl, 'Media Sosial', Icons.alternate_email_rounded),
          _div(),
          _field(_footerCtrl, 'Catatan Struk', Icons.receipt_rounded,
              maxLines: 2),
          _div(),
          _field(_targetSpendCtrl, 'Target Spend / Pax', Icons.people_rounded,
              keyboardType: TextInputType.number, prefix: 'Rp '),
        ]),
        const SizedBox(height: AppSpacing.lg),
        _saveBtn('Simpan Profil', _controller.state.isSaving, () {
          _controller.saveOutlet(_controller.state.outletInfo.copyWith(
            name: _nameCtrl.text.trim(),
            code: _codeCtrl.text.trim(),
            address: _addressCtrl.text.trim(),
            phone: _phoneCtrl.text.trim(),
            socialMedia: _socialCtrl.text.trim(),
            receiptFooter: _footerCtrl.text.trim(),
            targetSpendPerPax: int.tryParse(_targetSpendCtrl.text) ?? 0,
          ));
        }),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: LayoutBuilder(
        builder: (context, c) {
          // 2 kolom (Data | Logo) di layar lebar; menumpuk 1 kolom bila sempit.
          if (c.maxWidth >= 720) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: dataCol),
                const SizedBox(width: AppSpacing.lg),
                Expanded(flex: 2, child: _logoCard()),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              dataCol,
              const SizedBox(height: AppSpacing.lg),
              _logoCard(),
            ],
          );
        },
      ),
    );
  }

  // ── Tab: Biaya Tambahan ───────────────────────────────────────────────────

  Widget _tabBiaya() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
          child: Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Biaya Tambahan', style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary)),
                    Text('Pajak, Service Charge, dll',
                        style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                  ],
                ),
              ),
              AppButton(
                label: 'Tambah',
                icon: Icons.add_rounded,
                size: AppButtonSize.small,
                expanded: false,
                accent: _accent,
                onPressed: () => _showChargeDialog(),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingCharges
              ? const AppLoader()
              : _charges.isEmpty
                  ? EmptyState(
                      icon: Icons.receipt_long_rounded,
                      title: 'Belum ada biaya tambahan',
                      message: 'Tambahkan pajak, service charge, atau biaya lain.',
                      actionLabel: 'Tambah Biaya',
                      onAction: () => _showChargeDialog(),
                      accent: _accent,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      itemCount: _charges.length,
                      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                      itemBuilder: (_, i) => _chargeCard(_charges[i]),
                    ),
        ),
      ],
    );
  }

  // ── Tab: Cloud ────────────────────────────────────────────────────────────

  Widget _tabCloud() {
    final apiKey = _apiKeyCtrl.text.trim();
    final isConfigured = apiKey.isNotEmpty;
    final statusColor = isConfigured ? AppColors.success : AppColors.warning;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            color: AppColors.soft(statusColor, 0.10),
            border: Border.all(color: AppColors.soft(statusColor, 0.32)),
            shadow: const [],
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                IconBadge(
                  icon: isConfigured
                      ? Icons.cloud_done_rounded
                      : Icons.cloud_off_rounded,
                  color: statusColor,
                  size: 44,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isConfigured
                            ? 'Cloud terkonfigurasi'
                            : 'Cloud belum dikonfigurasi — isi API Key',
                        style: AppType.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isConfigured
                            ? 'Mode ${_cloudEnv.label} • Sync terakhir: '
                                '${_formatLastSync(_lastSyncAt)}'
                            : 'Mode ${_cloudEnv.label}',
                        style: AppType.caption,
                      ),
                    ],
                  ),
                ),
                StatusPill(
                  label: isConfigured ? 'Aktif' : 'Perlu diisi',
                  color: statusColor,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _group([
            _envRow(),
            _div(),
            if (_cloudEnv == CloudEnv.production)
              _readonlyUrlRow()
            else
              _field(_apiUrlCtrl, 'URL Server Cloud', Icons.cloud_rounded,
                  keyboardType: TextInputType.url),
            _div(),
            _field(_apiKeyCtrl, 'API Key', Icons.vpn_key_rounded),
            _div(),
            _switchRow(
              'Aktifkan Sync',
              'Sinkronisasi otomatis ke cloud',
              Icons.sync_rounded,
              _syncEnabled,
              (v) => setState(() => _syncEnabled = v),
            ),
            _div(),
            _dropdownRow<int>(
              'Interval Sync',
              'Menit antar sinkronisasi',
              Icons.timer_rounded,
              _syncInterval,
              [1, 3, 5, 10, 15, 30],
              (v) => setState(() => _syncInterval = v ?? 5),
              labelMap: const {
                1: '1 menit', 3: '3 menit', 5: '5 menit',
                10: '10 menit', 15: '15 menit', 30: '30 menit',
              },
            ),
          ]),
          const SizedBox(height: AppSpacing.md),
          _saveBtn(
            _testingConnection ? 'Menyimpan & menyambungkan...' : 'Simpan & Sambungkan',
            _controller.state.isSaving || _testingConnection,
            _saveAndConnect,
          ),
          const SizedBox(height: AppSpacing.sm),
          // Aksi sekunder (bukan CTA utama) → aksen GOLD tonal.
          AppButton(
            label: 'Status Sinkronisasi',
            icon: Icons.sync_rounded,
            variant: AppButtonVariant.tonal,
            accent: AppColors.accent,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncStatusScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAndConnect() async {
    final url = _cloudEnv == CloudEnv.production
        ? OutletService.productionCloudApiUrl
        : _apiUrlCtrl.text.trim();
    if (_cloudEnv == CloudEnv.development && !_isValidCloudUrl(url)) {
      showAppSnack(
        context,
        'URL server tidak valid. Contoh: http://192.168.1.10:8080',
        isError: true,
      );
      return;
    }
    if (_cloudEnv == CloudEnv.development) _devApiUrl = url;
    _apiUrlCtrl.text = url;

    // Simpan dulu
    await _controller.saveCloud(
      cloudEnv: _cloudEnv,
      cloudApiUrl: url,
      cloudApiKey: _apiKeyCtrl.text.trim(),
      cloudOutletId: _outletIdCtrl.text.trim(),
      syncEnabled: _syncEnabled,
      syncInterval: _syncInterval,
    );
    if (!mounted) return;

    // Cek koneksi & auto-discover outlet
    setState(() => _testingConnection = true);
    final result = await CloudSyncService.instance.testConnection();
    if (!mounted) return;
    setState(() => _testingConnection = false);

    final ok = result['success'] == true;
    if (ok) {
      _outletIdCtrl.text = result['outlet_id'] as String;
      // Muat ulang profil outlet (nama/kode/alamat dari cloud) ke field tab Outlet
      await _controller.loadSettings();
      if (!mounted) return;
      _populate();
      await _refreshLastSync();
      if (!mounted) return;
    }
    showAppSnack(
      context,
      ok
          ? 'Terhubung! ${result['outlet_name']} — '
              '${result['products']} produk, ${result['categories']} kategori '
              'dari cloud (hapus lokal: ${result['deleted_products'] ?? 0} produk, '
              '${result['deleted_categories'] ?? 0} kategori)'
          : 'Tersimpan, tapi koneksi gagal: ${result['error']}',
      isError: !ok,
    );
  }

  bool _isValidCloudUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.host.isNotEmpty;
  }

  void _setCloudEnv(CloudEnv env) {
    if (_cloudEnv == env) return;
    setState(() {
      if (_cloudEnv == CloudEnv.development) {
        _devApiUrl = _apiUrlCtrl.text.trim();
      }
      _cloudEnv = env;
      _apiUrlCtrl.text = env == CloudEnv.production
          ? OutletService.productionCloudApiUrl
          : (_devApiUrl == OutletService.productionCloudApiUrl
              ? ''
              : _devApiUrl);
    });
  }

  Widget _envRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconBadge(icon: Icons.dns_rounded, color: _accent, size: 40),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mode Server', style: AppType.title),
                Text(
                  _cloudEnv == CloudEnv.production
                      ? 'URL terkunci ke server resmi'
                      : 'Isi URL server sendiri untuk pengujian',
                  style: AppType.caption,
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Expanded(
                      child: _envChip(
                          CloudEnv.production, Icons.verified_rounded),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: _envChip(
                          CloudEnv.development, Icons.code_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _envChip(CloudEnv env, IconData icon) {
    final selected = _cloudEnv == env;
    final color =
        env == CloudEnv.production ? AppColors.success : AppColors.warning;
    return GestureDetector(
      onTap: () => _setCloudEnv(env),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.soft(color, selected ? 0.16 : 0.06),
          borderRadius: AppRadius.rSm,
          border: Border.all(
            color: AppColors.soft(color, selected ? 0.48 : 0.16),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? color : AppColors.textTertiary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                env.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.label.copyWith(
                  color: selected ? color : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readonlyUrlRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          const IconBadge(
              icon: Icons.cloud_rounded, color: _accent, size: 40),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('URL Server Cloud',
                    style: AppType.caption
                        .copyWith(color: AppColors.textTertiary)),
                const SizedBox(height: 2),
                Text(
                  _apiUrlCtrl.text.isEmpty
                      ? OutletService.productionCloudApiUrl
                      : _apiUrlCtrl.text,
                  style: AppType.body,
                ),
              ],
            ),
          ),
          const Icon(Icons.lock_rounded,
              size: 16, color: AppColors.textTertiary),
        ],
      ),
    );
  }

  // ── Tab: Data ─────────────────────────────────────────────────────────────

  Widget _tabData() {
    final retentionDays = _controller.state.outletInfo.retentionDays;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _group([
            _dropdownRow<int>(
              'Retensi Data Lokal',
              'Data lengkap tetap tersimpan di cloud. Default 90 hari (3 bulan).',
              Icons.history_rounded,
              retentionDays <= 0 ? 90 : retentionDays,
              [30, 60, 90, 180, 365],
              (v) => _controller.saveRetention(v ?? 90),
              labelMap: const {
                30: '30 hari', 60: '60 hari',
                90: '90 hari (3 bulan)', 180: '6 bulan', 365: '1 tahun',
              },
            ),
          ]),
          const SizedBox(height: AppSpacing.sm),
          _group([
            _settingRow(
              Icons.download_rounded,
              'Seed Data Contoh',
              'Isi produk & meja sample untuk uji coba',
              accent: AppColors.brand, // seragam hijau (bukan biru)
              onTap: () => _controller.seedData(),
            ),
            _div(),
            _settingRow(
              Icons.cloud_download_rounded,
              'Pulihkan dari Cloud',
              'Tarik shift terbuka & order belum dibayar dari cloud',
              accent: AppColors.moduleKasir,
              onTap: _restoreFromCloud,
            ),
            _div(),
            _settingRow(
              Icons.delete_forever_rounded,
              'Reset Database',
              'Hapus semua data transaksi di perangkat ini (cloud tetap)',
              danger: true,
              onTap: _showResetDialog,
            ),
          ]),
        ],
      ),
    );
  }

  // ── Tab: Aplikasi ─────────────────────────────────────────────────────────

  Widget _tabAplikasi() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: _group([
        _settingRow(
          Icons.print_rounded,
          'Pengaturan Printer',
          'Konfigurasi printer Bluetooth & LAN',
          accent: AppColors.brand, // seragam hijau (bukan biru)
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const PrinterSettingsScreen()),
          ),
        ),
        _div(),
        _settingRow(
          Icons.print_rounded,
          'Antrian Cetak Dapur/Bar',
          'Pantau status cetak & cetak ulang yang gagal',
          accent: AppColors.moduleWaiter,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PrintQueueScreen()),
          ),
        ),
        _div(),
        _settingRow(
          Icons.group_rounded,
          'Manajemen User',
          'Kelola akun kasir, waiter, manager, admin',
          accent: AppColors.moduleProduk,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const UserManagementScreen()),
          ),
        ),
        _div(),
        _settingRow(
          Icons.devices_other_rounded,
          'Peran Perangkat',
          'Saat ini: Kasir Utama (Main POS)',
          accent: AppColors.moduleMeja,
          onTap: _changeDeviceRole,
        ),
        _div(),
        _settingRow(
          Icons.info_rounded,
          'Versi Aplikasi',
          _appVersion,
        ),
      ]),
    );
  }

  Future<void> _changeDeviceRole() async {
    final ok = await showAppConfirm(
      context,
      title: 'Ganti Peran Perangkat?',
      message:
          'Perangkat akan kembali ke layar pemilihan peran. Gunakan ini bila '
          'ingin menjadikan perangkat ini sebagai Station pelayan.',
      confirmText: 'Lanjut',
      icon: Icons.devices_other_rounded,
    );
    if (!ok || !mounted) return;
    await DeviceRoleService.instance.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const RootGate()),
      (route) => false,
    );
  }

  // ── Charge helpers ────────────────────────────────────────────────────────

  Widget _chargeCard(AdditionalCharge charge) {
    final isActive = charge.isActive == 1;
    final valueStr = charge.chargeType == 'percentage'
        ? '${charge.value.toStringAsFixed(charge.value % 1 == 0 ? 0 : 1)}%'
        : 'Rp ${charge.value.toStringAsFixed(0)}';
    final accent = isActive ? AppColors.success : AppColors.textTertiary;
    final typeLabel = charge.chargeType == 'percentage' ? 'Persentase' : 'Tetap';

    return AppCard(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      accent: isActive ? AppColors.success : null,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.soft(accent, 0.12),
              borderRadius: AppRadius.rXs,
            ),
            child: Text(valueStr,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w800, color: accent)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(charge.name, style: AppType.title, maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(typeLabel, style: AppType.caption),
                    const SizedBox(width: AppSpacing.xs),
                    StatusPill(
                      label: isActive ? 'Aktif' : 'Nonaktif',
                      color: isActive ? AppColors.success : AppColors.textTertiary,
                    ),
                  ],
                ),
              ],
            ),
          ),
          AppIconButton(
            icon: Icons.edit_rounded,
            color: _accent,
            tooltip: 'Edit',
            onPressed: () => _showChargeDialog(existing: charge),
          ),
        ],
      ),
    );
  }

  void _showChargeDialog({AdditionalCharge? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final valueCtrl = TextEditingController(
        text: existing?.value.toString() ?? '');
    String type = existing?.chargeType ?? 'percentage';
    bool isActive = existing == null || existing.isActive == 1;

    showAppModal(
      context,
      title: existing == null ? 'Tambah Biaya Tambahan' : 'Edit Biaya Tambahan',
      icon: Icons.receipt_rounded,
      accent: _accent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nama (cth: PPN, Service Charge)',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: valueCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Nilai',
                      suffixText: type == 'percentage' ? '%' : 'Rp',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                DropdownButton<String>(
                  value: type,
                  items: const [
                    DropdownMenuItem(
                        value: 'percentage', child: Text('  %  ')),
                    DropdownMenuItem(
                        value: 'fixed', child: Text('  Rp  ')),
                  ],
                  onChanged: (v) => setS(() => type = v ?? 'percentage'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            SwitchListTile(
              value: isActive,
              title: const Text('Aktif'),
              onChanged: (v) => setS(() => isActive = v),
              contentPadding: EdgeInsets.zero,
            ),
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
                    label: 'Simpan',
                    accent: _accent,
                    onPressed: () async {
                      final name = nameCtrl.text.trim();
                      final value = double.tryParse(valueCtrl.text) ?? 0;
                      if (name.isEmpty) return;
                      Navigator.pop(ctx);
                      try {
                        if (existing == null) {
                          await _orderRepo.createAdditionalCharge(
                              name: name,
                              chargeType: type,
                              value: value,
                              isActive: isActive);
                        } else {
                          await _orderRepo.updateAdditionalCharge(
                              id: existing.id!,
                              name: name,
                              chargeType: type,
                              value: value,
                              isActive: isActive);
                        }
                        _loadCharges();
                      } catch (e) {
                        if (mounted) {
                          showAppSnack(context, 'Error: $e', isError: true);
                        }
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

  Future<void> _performReset() async {
    final ok = await _controller.resetDatabase();
    if (!mounted || !ok) return;
    // Kembali ke RootGate agar seluruh state UI ikut bersih.
    // Tidak menarik data dari cloud — reset hanya membersihkan lokal.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const RootGate()),
      (route) => false,
    );
  }

  Future<void> _restoreFromCloud() async {
    showAppSnack(context, 'Memulihkan data dari cloud...');
    final r = await CloudSyncService.instance.restoreFromCloud();
    if (!mounted) return;
    final hasError = r['unconfigured'] == true || r['error'] != null;
    final msg = r['unconfigured'] == true
        ? 'Cloud belum dikonfigurasi.'
        : r['error'] != null
            ? 'Gagal memulihkan: ${r['error']}'
            : 'Dipulihkan: ${r['orders'] ?? 0} order, '
                '${r['shifts'] ?? 0} shift, ${r['movements'] ?? 0} kas.';
    showAppSnack(context, msg, isError: hasError);
  }

  Future<void> _showResetDialog() async {
    final ok = await showAppConfirm(
      context,
      title: 'Reset Database?',
      message:
          'Semua data transaksi akan dihapus permanen dan tidak dapat dikembalikan.',
      confirmText: 'Reset',
      icon: Icons.delete_forever_rounded,
      destructive: true,
    );
    if (ok) await _performReset();
  }

  // ── Widget helpers ────────────────────────────────────────────────────────

  Widget _group(List<Widget> children) => AppCard(
        padding: EdgeInsets.zero,
        child: Column(children: children),
      );

  Widget _div() => const Padding(
        padding: EdgeInsets.only(left: 68, right: AppSpacing.md),
        child: Divider(height: 1, color: AppColors.border),
      );

  Widget _field(TextEditingController ctrl, String label, IconData icon,
      {int maxLines = 1,
      TextInputType keyboardType = TextInputType.text,
      bool obscure = false,
      String? prefix}) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: maxLines > 1
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Padding(
            padding: EdgeInsets.only(top: maxLines > 1 ? 6 : 0),
            child: IconBadge(icon: icon, color: _accent, size: 40),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: ctrl,
              maxLines: maxLines,
              keyboardType: keyboardType,
              obscureText: obscure,
              style: AppType.body,
              decoration: InputDecoration(
                labelText: label,
                prefixText: prefix,
                labelStyle:
                    AppType.caption.copyWith(color: AppColors.textTertiary),
                floatingLabelStyle:
                    AppType.caption.copyWith(color: _accent),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchRow(String title, String subtitle, IconData icon, bool value,
      ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      child: Row(
        children: [
          IconBadge(icon: icon, color: _accent, size: 40),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppType.title),
                Text(subtitle, style: AppType.caption),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _dropdownRow<T>(String title, String subtitle, IconData icon,
      T value, List<T> options, ValueChanged<T?> onChanged,
      {Map<T, String>? labelMap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          IconBadge(icon: icon, color: _accent, size: 40),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppType.title),
                Text(subtitle, style: AppType.caption),
              ],
            ),
          ),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox(),
            style: AppType.label.copyWith(color: AppColors.textPrimary),
            items: options
                .map((v) => DropdownMenuItem(
                    value: v,
                    child: Text(labelMap?[v] ?? v.toString())))
                .toList(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _settingRow(IconData icon, String title, String subtitle,
      {Color? accent, bool danger = false, VoidCallback? onTap}) {
    final c = danger ? AppColors.danger : (accent ?? _accent);
    final titleColor = danger ? AppColors.danger : AppColors.textPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              IconBadge(icon: icon, color: c, size: 44),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppType.title.copyWith(color: titleColor)),
                    Text(subtitle, style: AppType.caption),
                  ],
                ),
              ),
              if (onTap != null)
                const Icon(Icons.chevron_right_rounded,
                    size: 22, color: AppColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _saveBtn(String label, bool isLoading, VoidCallback onTap) => AppButton(
        label: label,
        accent: _accent,
        loading: isLoading,
        onPressed: onTap,
      );
}
