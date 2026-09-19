import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/print_queue_service.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';

/// Monitor antrian cetak dapur/bar: lihat pending/done/failed + cetak ulang.
class PrintQueueScreen extends StatefulWidget {
  const PrintQueueScreen({super.key});

  @override
  State<PrintQueueScreen> createState() => _PrintQueueScreenState();
}

class _PrintQueueScreenState extends State<PrintQueueScreen> {
  final _service = PrintQueueService.instance;

  static const _accent = AppColors.moduleWaiter;

  Map<String, int> _stats = const {'pending': 0, 'done': 0, 'failed': 0};
  List<Map<String, dynamic>> _jobs = [];
  bool _loading = true;
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    _load();
    // Auto-refresh tiap 2 detik agar status job terlihat hidup
    _autoRefresh = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final stats = await _service.stats();
    final jobs = await _service.recentJobs();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _jobs = jobs;
      _loading = false;
    });
  }

  Future<void> _reprintJob(String id) async {
    await _service.reprint(id);
    if (mounted) {
      showAppSnack(context, 'Mencetak ulang ke printer...');
    }
    _load();
  }

  Future<void> _retryFailed() async {
    await _service.retryFailed();
    if (!mounted) return;
    showAppSnack(context, 'Job gagal dimasukkan ulang ke antrian');
    await _load();
  }

  Future<void> _clearDone() async {
    final n = await _service.clearDone();
    if (!mounted) return;
    showAppSnack(context, '$n riwayat cetak dibersihkan');
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
              title: 'Antrian Cetak',
              subtitle: 'Status cetak dapur & bar',
              icon: Icons.print_rounded,
              accent: _accent,
              actions: [
                AppIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Muat ulang',
                  filled: true,
                  color: _accent,
                  size: 42,
                  onPressed: () => _load(),
                ),
              ],
            ),
            _buildStatsBar(),
            if (failed > 0) _buildRetryBanner(failed),
            Expanded(
              child: _loading
                  ? const AppLoader()
                  : _jobs.isEmpty
                      ? const EmptyState(
                          icon: Icons.print_disabled_rounded,
                          title: 'Belum ada riwayat cetak',
                          message: 'Tiket cetak dapur/bar akan muncul di sini.',
                          accent: _accent,
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            itemCount: _jobs.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: AppSpacing.sm),
                            itemBuilder: (_, i) => _JobTile(
                              job: _jobs[i],
                              onReprint: () =>
                                  _reprintJob(_jobs[i]['id'] as String),
                            ),
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
                  _statChip('Selesai', _stats['done'] ?? 0, AppColors.success),
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
              onPressed: (_stats['done'] ?? 0) > 0 ? _clearDone : null,
            ),
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
          Text('$value',
              style: AppType.h3.copyWith(color: color)),
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
            const Icon(Icons.warning_amber_rounded,
                color: AppColors.danger, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text('$failed cetakan gagal terkirim ke printer',
                  style: AppType.bodySm.copyWith(
                      color: AppColors.danger, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: AppSpacing.sm),
            AppButton(
              label: 'Cetak Ulang',
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
  final VoidCallback? onReprint;
  const _JobTile({required this.job, this.onReprint});

  @override
  Widget build(BuildContext context) {
    final status = job['status'] as String;
    final role = job['role'] as String? ?? '';
    final type = job['printer_type'] as String? ?? '';
    final label = (job['label'] as String?) ?? '';
    final retry = job['retry_count'] as int? ?? 0;
    final error = job['error_message'] as String?;

    final (color, icon, text) = switch (status) {
      'done' => (AppColors.success, Icons.check_circle_rounded, 'Terkirim'),
      'failed' => (AppColors.danger, Icons.error_rounded, 'Gagal'),
      _ => (AppColors.warning, Icons.schedule_rounded, 'Menunggu'),
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
                Text(label.isNotEmpty ? label : '${role.toUpperCase()} ($type)',
                    style: AppType.title, maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  '${role.toUpperCase()} · $type${retry > 0 ? ' · retry $retry' : ''}',
                  style: AppType.caption,
                ),
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
          // Cetak ulang per-tiket (selain yang masih menunggu).
          if (status != 'pending' && onReprint != null) ...[
            const SizedBox(width: AppSpacing.xxs),
            AppIconButton(
              icon: Icons.refresh_rounded,
              color: AppColors.moduleProduk,
              tooltip: 'Cetak ulang',
              size: 40,
              onPressed: onReprint,
            ),
          ],
        ],
      ),
    );
  }
}
