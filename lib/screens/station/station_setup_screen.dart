import 'package:flutter/material.dart';

import '../../services/station_api_client.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';

/// Layar setup mode Station: temukan Main POS di jaringan lalu hubungkan.
class StationSetupScreen extends StatefulWidget {
  /// Kembali ke halaman pemilihan peran perangkat (opsional).
  final VoidCallback? onBackToRole;

  /// Dipanggil saat berhasil terhubung ke Main POS. StationGate memakainya
  /// untuk lanjut ke LOGIN PIN (bukan langsung ke pemesanan). WAJIB — layar ini
  /// selalu di bawah StationGate; tak boleh ada jalur yang melewati login.
  final VoidCallback onConnected;
  const StationSetupScreen(
      {super.key, this.onBackToRole, required this.onConnected});

  @override
  State<StationSetupScreen> createState() => _StationSetupScreenState();
}

class _StationSetupScreenState extends State<StationSetupScreen> {
  final _api = StationApiClient.instance;
  final _manualCtrl = TextEditingController();

  static const _accent = AppColors.moduleKasir;

  List<StationServer> _found = [];
  bool _scanning = false;
  int _progress = 0;
  String? _error;
  String? _connecting;

  @override
  void dispose() {
    _manualCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = [];
      _progress = 0;
      _error = null;
    });
    try {
      final servers = await _api.discover(
        onProgress: (c, t) {
          if (mounted) setState(() => _progress = (c / t * 100).round());
        },
      );
      if (mounted) setState(() => _found = servers);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(String baseUrl, String name) async {
    setState(() => _connecting = baseUrl);
    final server = await _api.ping(baseUrl);
    if (!mounted) return;
    setState(() => _connecting = null);
    if (server == null) {
      setState(() => _error = 'Tidak dapat terhubung ke $baseUrl');
      return;
    }
    await _api.save(server.baseUrl, outletCode: server.outletCode);
    if (!mounted) return;
    // Terhubung → serahkan ke StationGate untuk lanjut ke LOGIN PIN.
    widget.onConnected();
  }

  Future<void> _connectManual() async {
    var input = _manualCtrl.text.trim();
    if (input.isEmpty) return;
    if (!input.startsWith('http')) {
      input = 'http://$input:${StationApiClient.serverPort}';
    }
    await _connect(input, input);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: AppColors.sidebarGradient,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(context),
              Padding(
                padding: EdgeInsets.fromLTRB(context.pagePadX, AppSpacing.xs,
                    context.pagePadX, AppSpacing.md),
                child: _buildControls(),
              ),
              Expanded(child: _buildResultSheet()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final canBack = Navigator.of(context).canPop();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.sm, context.pagePadX, AppSpacing.md),
      child: Row(
        children: [
          if (canBack) ...[
            AppIconButton(
              icon: Icons.arrow_back_ios_new_rounded,
              onPressed: () => Navigator.of(context).maybePop(),
              color: Colors.white,
              filled: true,
              size: 44,
              tooltip: 'Kembali',
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.soft(Colors.white, 0.95),
              borderRadius: AppRadius.rSm,
              border: Border.all(color: AppColors.soft(Colors.white, 0.6)),
              boxShadow: AppShadows.glow(AppColors.greenDark, strength: 0.4),
            ),
            child: const Icon(Icons.wifi_tethering_rounded,
                color: AppColors.green, size: 24),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hubungkan ke Main POS',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  'Temukan kasir utama di WiFi yang sama',
                  style: TextStyle(fontSize: 12.5, color: Colors.white70),
                ),
              ],
            ),
          ),
          if (widget.onBackToRole != null) ...[
            const SizedBox(width: AppSpacing.sm),
            AppIconButton(
              icon: Icons.swap_horiz_rounded,
              onPressed: _confirmBackToRole,
              color: Colors.white,
              filled: true,
              size: 44,
              tooltip: 'Ganti peran perangkat',
            ),
          ],
        ],
      ),
    );
  }

  /// Konfirmasi lalu kembali ke halaman pemilihan peran perangkat.
  Future<void> _confirmBackToRole() async {
    final ok = await showAppConfirm(
      context,
      title: 'Ganti peran perangkat?',
      message: 'Perangkat akan kembali ke halaman pemilihan peran '
          '(Kasir Utama / Station). Koneksi ke Main POS saat ini dilepas.',
      confirmText: 'Ganti Peran',
      icon: Icons.swap_horiz_rounded,
    );
    if (ok) widget.onBackToRole?.call();
  }

  Widget _buildControls() {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          AppButton(
            label: _scanning
                ? 'Mencari... $_progress%'
                : 'Cari Main POS (port ${StationApiClient.serverPort})',
            icon: Icons.wifi_find_rounded,
            accent: _accent,
            onPressed: _scanning ? null : _scan,
          ),
          if (_scanning) ...[
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: AppRadius.rPill,
              child: LinearProgressIndicator(
                value: _progress / 100,
                minHeight: 6,
                color: _accent,
                backgroundColor: Colors.white.withValues(alpha: 0.15),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: _buildManualField()),
              const SizedBox(width: AppSpacing.sm),
              AppButton(
                label: 'Hubung',
                variant: AppButtonVariant.neutral,
                size: AppButtonSize.medium,
                expanded: false,
                onPressed: _connecting != null ? null : _connectManual,
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.16),
                borderRadius: AppRadius.rSm,
                border: Border.all(color: AppColors.danger.withValues(alpha: 0.32)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 16, color: Color(0xFFFCA5A5)),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFFCA5A5),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildManualField() {
    return TextField(
      controller: _manualCtrl,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      cursorColor: _accent,
      decoration: InputDecoration(
        hintText: 'atau IP manual, mis. 192.168.1.10',
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 13),
        isDense: true,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.rSm,
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rSm,
          borderSide: BorderSide(color: _accent, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildResultSheet() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      clipBehavior: Clip.antiAlias,
      child: _buildResultBody(),
    );
  }

  Widget _buildResultBody() {
    if (_found.isEmpty) {
      if (_scanning) {
        return const AppLoader(label: 'Memindai jaringan...');
      }
      return const EmptyState(
        icon: Icons.wifi_find_rounded,
        title: 'Belum ada Main POS',
        message:
            'Tekan "Cari Main POS" untuk menemukan perangkat kasir utama di WiFi yang sama.',
        accent: _accent,
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(context.pagePadX, AppSpacing.lg,
          context.pagePadX, AppSpacing.lg),
      itemCount: _found.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (_, i) {
        final s = _found[i];
        final loading = _connecting == s.baseUrl;
        return AppCard(
          onTap: loading ? null : () => _connect(s.baseUrl, s.outletName),
          accent: _accent,
          child: Row(
            children: [
              // SECONDARY gold: sorot Main POS yang ditemukan (aksen premium)
              // di dalam kartu ber-aksen hijau.
              const IconBadge(
                  icon: Icons.point_of_sale_rounded,
                  color: AppColors.accent,
                  size: 46),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(s.outletName,
                        style: AppType.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${s.baseUrl} · ${s.connectedStations} station',
                      style: AppType.caption.copyWith(color: AppColors.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textTertiary),
            ],
          ),
        );
      },
    );
  }
}
