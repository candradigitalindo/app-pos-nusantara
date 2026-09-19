import 'dart:async';

import 'package:flutter/material.dart';

import '../../repositories/sync_queue_repository.dart';
import '../../services/cloud_sync_service.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/ui/ui.dart';

/// Monitor outbox sinkronisasi cloud: lihat pending/sukses/gagal + sync ulang.
class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  final _queue = SyncQueueRepository();

  static const _accent = AppColors.moduleKasir;

  Map<String, int> _stats = const {'pending': 0, 'success': 0, 'failed': 0};
  List<Map<String, dynamic>> _jobs = [];
  Map<String, dynamic> _recon = const {};
  bool _loading = true;
  bool _syncing = false;
  Timer? _auto;

  @override
  void initState() {
    super.initState();
    _load();
    _auto = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final stats = await _queue.stats();
    final jobs = await _queue.recentJobs();
    final recon = await _queue.reconciliation();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _jobs = jobs;
      _recon = recon;
      _loading = false;
    });
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final r = await CloudSyncService.instance.pushNow();
    if (!mounted) return;
    setState(() => _syncing = false);
    final msg = (r['unconfigured'] ?? 0) == 1
        ? 'Cloud belum dikonfigurasi (URL/API Key/Outlet ID)'
        : 'Terkirim: ${r['success']} sukses, ${r['failed']} gagal (dari ${r['sent']})';
    showAppSnack(context, msg);
    await _load();
  }

  Future<void> _retryFailed() async {
    await _queue.retryFailed();
    await _syncNow();
  }

  Future<void> _clearSuccess() async {
    final n = await _queue.clearSuccess();
    if (!mounted) return;
    showAppSnack(context, '$n riwayat sukses dibersihkan');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final failed = _stats['failed'] ?? 0;
    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            AppPageHeader(
              title: 'Status Sinkronisasi',
              subtitle: 'Outbox cloud (kirim ulang)',
              icon: Icons.cloud_sync_rounded,
              accent: _accent,
              actions: [
                if (_syncing)
                  const Padding(
                    padding: EdgeInsets.all(AppSpacing.sm),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  )
                else
                  AppIconButton(
                    icon: Icons.cloud_upload_rounded,
                    tooltip: 'Sync sekarang',
                    filled: true,
                    color: _accent,
                    size: 42,
                    onPressed: _syncNow,
                  ),
              ],
            ),
            _buildStatsBar(),
            _buildReconCard(),
            if (failed > 0) _buildRetryBanner(failed),
            Expanded(
              child: _loading
                  ? const AppLoader()
                  : _jobs.isEmpty
                      ? const EmptyState(
                          icon: Icons.cloud_done_rounded,
                          title: 'Tidak ada antrian sinkronisasi',
                          message: 'Semua data sudah terkirim ke cloud.',
                          accent: _accent,
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: _jobs.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (_, i) => _JobTile(job: _jobs[i]),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            // Wrap agar chip melipat (bukan overflow) saat sempit / angka besar.
            Expanded(
              child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _statChip('Antri', _stats['pending'] ?? 0, AppColors.warning),
                  _statChip('Terkirim', _stats['success'] ?? 0, AppColors.success),
                  _statChip('Gagal', _stats['failed'] ?? 0, AppColors.danger),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // Aksi sekunder (bukan CTA utama) → aksen GOLD tonal.
            AppButton(
              label: 'Bersihkan',
              icon: Icons.cleaning_services_rounded,
              variant: AppButtonVariant.tonal,
              accent: AppColors.accent,
              size: AppButtonSize.small,
              expanded: false,
              onPressed: (_stats['success'] ?? 0) > 0 ? _clearSuccess : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Kartu rekonsiliasi: berapa transaksi (uang) yang BELUM pasti terkirim ke
  /// cloud dalam jendela terakhir. Deteksi dini selisih per outlet.
  Widget _buildReconCard() {
    if (_recon.isEmpty) return const SizedBox.shrink();
    final days = _recon['window_days'] as int? ?? 30;
    final atRiskCount = _recon['at_risk_count'] as int? ?? 0;
    final atRiskAmount = _recon['at_risk_amount'] as double? ?? 0;
    final syncedCount = _recon['synced_count'] as int? ?? 0;
    final pending = _recon['pending_count'] as int? ?? 0;
    final failed = _recon['failed_count'] as int? ?? 0;
    final missing = _recon['missing_count'] as int? ?? 0;
    final clean = atRiskCount == 0;
    final color = clean ? AppColors.success : AppColors.danger;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
      child: AppCard(
        color: AppColors.soft(color, 0.08),
        border: Border.all(color: AppColors.soft(color, 0.3)),
        shadow: const [],
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(clean ? Icons.verified_rounded : Icons.warning_amber_rounded,
                    color: color, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Rekonsiliasi transaksi · $days hari',
                    style: AppType.bodySm.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Text('$syncedCount terkirim',
                    style: AppType.caption.copyWith(color: AppColors.success)),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (clean)
              Text('Semua transaksi terkonfirmasi terkirim (lokal).',
                  style: AppType.caption.copyWith(color: AppColors.success))
            else ...[
              Text(
                'Belum pasti terkirim: $atRiskCount transaksi · ${CurrencyHelper.format(atRiskAmount)}',
                style: AppType.bodySm
                    .copyWith(color: color, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                'Antri $pending · Gagal $failed · Tanpa entri $missing',
                style: AppType.caption.copyWith(color: AppColors.textSecondary),
              ),
              if (missing > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '⚠ "Tanpa entri" = transaksi lunas tanpa jejak antrian sync — '
                    'perlu diperiksa (kemungkinan ditandai terkirim keliru).',
                    style:
                        AppType.caption.copyWith(color: AppColors.warning),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statChip(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.soft(color, 0.10),
        borderRadius: AppRadius.rSm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$value', style: AppType.h3.copyWith(color: color)),
          Text(label,
              style: AppType.caption.copyWith(
                  color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildRetryBanner(int failed) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.xs, AppSpacing.md, 0),
      child: AppCard(
        color: AppColors.dangerSoft,
        border: Border.all(color: AppColors.soft(AppColors.danger, 0.3)),
        shadow: const [],
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_rounded,
                color: AppColors.danger, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text('$failed item gagal terkirim ke cloud',
                  style: AppType.bodySm.copyWith(
                      color: AppColors.danger, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              label: 'Coba Lagi',
              variant: AppButtonVariant.danger,
              size: AppButtonSize.small,
              expanded: false,
              onPressed: _retryFailed,
            ),
          ],
        ),
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final Map<String, dynamic> job;
  const _JobTile({required this.job});

  static const _labels = {
    'transaction': 'Transaksi',
    'cashier_shift': 'Shift Kasir',
    'cashier_cash_movement': 'Kas Masuk/Keluar',
    'product': 'Produk',
    'category': 'Kategori',
  };

  @override
  Widget build(BuildContext context) {
    final status = job['status'] as String;
    final type = job['entity_type'] as String? ?? '';
    final op = job['operation'] as String? ?? '';
    final retry = job['retry_count'] as int? ?? 0;
    final error = job['error_message'] as String?;

    final (color, icon, text) = switch (status) {
      'success' => (AppColors.success, Icons.check_circle_rounded, 'Terkirim'),
      'failed' => (AppColors.danger, Icons.error_rounded, 'Gagal'),
      _ => (AppColors.warning, Icons.schedule_rounded, 'Antri'),
    };

    return AppCard(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          IconBadge(icon: icon, color: color, size: 40),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_labels[type] ?? type,
                    style: AppType.title, maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('$op${retry > 0 ? ' · retry $retry' : ''}',
                    style: AppType.caption),
                if (status == 'failed' && error != null && error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(error,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.caption.copyWith(color: AppColors.danger)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          StatusPill(label: text, color: color, icon: icon),
        ],
      ),
    );
  }
}
