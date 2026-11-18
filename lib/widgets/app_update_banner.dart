import 'package:flutter/material.dart';

import '../services/app_update_service.dart';
import '../theme/theme.dart';
import 'ui/ui.dart';

/// Minta konfirmasi lalu mulai pemasangan. Pesan dari layanan (izin belum
/// diberikan, berkas rusak, dll.) ditampilkan sebagai snackbar.
Future<void> confirmAndInstallUpdate(
    BuildContext context, AppUpdateService service) async {
  final release = service.state.value.release;
  final ok = await showAppConfirm(
    context,
    title: 'Pasang ${release?.displayName ?? 'versi baru'}?',
    message: 'Aplikasi POS akan tertutup sebentar selama pemasangan, lalu buka '
        'lagi dari layar utama tablet. Pesanan, data, dan pengaturan tetap '
        'tersimpan. Sebaiknya dipasang setelah tutup kasir.',
    confirmText: 'Pasang sekarang',
    cancelText: 'Nanti',
    icon: Icons.system_update_rounded,
  );
  if (!ok || !context.mounted) return;
  final message = await service.install();
  if (message != null && context.mounted) {
    showAppSnack(context, message, isWarning: true);
  }
}

/// Tawaran pembaruan di Beranda & layar Buka Kasir. Tersembunyi bila tidak
/// ada versi baru.
class AppUpdateBanner extends StatelessWidget {
  final AppUpdateService? service;
  final EdgeInsetsGeometry padding;

  const AppUpdateBanner({
    super.key,
    this.service,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final svc = service ?? AppUpdateService.instance;
    return ValueListenableBuilder<AppUpdateState>(
      valueListenable: svc.state,
      builder: (context, s, _) {
        final release = s.release;
        final visible = release != null &&
            (s.phase == AppUpdatePhase.downloading ||
                s.phase == AppUpdatePhase.ready ||
                s.phase == AppUpdatePhase.installing ||
                (s.phase == AppUpdatePhase.failed && s.updateAvailable));
        if (!visible) return const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: _UpdateStrip(service: svc, state: s, release: release),
        );
      },
    );
  }
}

class _UpdateStrip extends StatelessWidget {
  final AppUpdateService service;
  final AppUpdateState state;
  final AppRelease release;

  const _UpdateStrip(
      {required this.service, required this.state, required this.release});

  @override
  Widget build(BuildContext context) {
    final name = release.displayName;
    final (IconData icon, Color color, String title, String subtitle) =
        switch (state.phase) {
      AppUpdatePhase.downloading => (
          Icons.downloading_rounded,
          AppColors.info,
          'Mengunduh versi baru $name',
          '${((state.progress ?? 0) * 100).round()}% · berjalan di latar '
              'belakang, kasir tetap bisa dipakai',
        ),
      AppUpdatePhase.ready => (
          Icons.system_update_rounded,
          AppColors.success,
          'Versi baru $name siap dipasang',
          state.message ??
              'Data & pengaturan tetap aman. Sebaiknya dipasang setelah '
                  'tutup kasir.',
        ),
      AppUpdatePhase.installing => (
          Icons.install_mobile_rounded,
          AppColors.success,
          'Memasang $name…',
          'Ikuti dialog Android. Aplikasi akan tertutup sebentar — buka '
              'lagi POS setelah selesai.',
        ),
      _ => (
          Icons.report_problem_rounded,
          AppColors.warning,
          'Pembaruan $name belum bisa diunduh',
          state.message ?? 'Dicoba lagi otomatis.',
        ),
    };
    return AppCard(
      key: const Key('app-update-banner'),
      color: AppColors.soft(color, 0.08),
      border: Border.all(color: AppColors.soft(color, 0.35)),
      shadow: const [],
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconBadge(icon: icon, color: color, size: 40),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppType.title),
                    const SizedBox(height: 2),
                    Text(subtitle, style: AppType.caption),
                  ],
                ),
              ),
              if (state.phase == AppUpdatePhase.ready) ...[
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  key: const Key('app-update-install'),
                  label: 'Pasang',
                  icon: Icons.system_update_rounded,
                  size: AppButtonSize.medium,
                  expanded: false,
                  accent: AppColors.success,
                  onPressed: () => confirmAndInstallUpdate(context, service),
                ),
              ],
              if (state.phase == AppUpdatePhase.failed) ...[
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  key: const Key('app-update-retry'),
                  label: 'Coba lagi',
                  variant: AppButtonVariant.tonal,
                  size: AppButtonSize.medium,
                  expanded: false,
                  accent: AppColors.warning,
                  onPressed: () => service.check(userInitiated: true),
                ),
              ],
            ],
          ),
          if (state.phase == AppUpdatePhase.downloading) ...[
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: state.progress,
                minHeight: 6,
                color: color,
                backgroundColor: AppColors.soft(color, 0.15),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Kartu "Pembaruan Aplikasi" di Pengaturan: versi terpasang, status, dan
/// tombol periksa/pasang manual.
class AppUpdateCard extends StatelessWidget {
  final AppUpdateService? service;
  const AppUpdateCard({super.key, this.service});

  @override
  Widget build(BuildContext context) {
    final svc = service ?? AppUpdateService.instance;
    return ValueListenableBuilder<AppUpdateState>(
      valueListenable: svc.state,
      builder: (context, s, _) {
        final status = switch (s.phase) {
          AppUpdatePhase.idle => 'Belum diperiksa',
          AppUpdatePhase.checking => 'Memeriksa versi terbaru…',
          AppUpdatePhase.upToDate => 'Sudah versi terbaru',
          AppUpdatePhase.downloading =>
            'Mengunduh ${s.release?.displayName ?? ''} '
                '(${((s.progress ?? 0) * 100).round()}%)',
          AppUpdatePhase.ready => '${s.release?.displayName} siap dipasang',
          AppUpdatePhase.installing => 'Sedang memasang…',
          AppUpdatePhase.failed => s.message ?? 'Pemeriksaan gagal',
        };
        final busy = s.phase == AppUpdatePhase.checking ||
            s.phase == AppUpdatePhase.downloading ||
            s.phase == AppUpdatePhase.installing;
        return AppCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const IconBadge(
                      icon: Icons.system_update_rounded,
                      color: AppColors.moduleKasir,
                      size: 40),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pembaruan Aplikasi', style: AppType.title),
                        Text('Terpasang: ${s.currentDisplay}',
                            key: const Key('app-update-current'),
                            style: AppType.caption),
                        Text(status,
                            key: const Key('app-update-status'),
                            style: AppType.caption.copyWith(
                                color: s.phase == AppUpdatePhase.failed
                                    ? AppColors.danger
                                    : AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
              if (!svc.supported) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('Pembaruan otomatis hanya tersedia di tablet Android.',
                    style: AppType.caption),
              ] else ...[
                const SizedBox(height: AppSpacing.md),
                if (s.phase == AppUpdatePhase.ready)
                  AppButton(
                    key: const Key('app-update-card-install'),
                    label: 'Pasang ${s.release?.displayName ?? ''}',
                    icon: Icons.system_update_rounded,
                    accent: AppColors.success,
                    onPressed: () => confirmAndInstallUpdate(context, svc),
                  )
                else
                  AppButton(
                    key: const Key('app-update-check'),
                    label: busy ? 'Memproses…' : 'Periksa pembaruan',
                    icon: Icons.refresh_rounded,
                    variant: AppButtonVariant.tonal,
                    accent: AppColors.moduleKasir,
                    loading: s.phase == AppUpdatePhase.checking,
                    onPressed:
                        busy ? null : () => svc.check(userInitiated: true),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
