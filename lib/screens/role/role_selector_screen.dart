import 'package:flutter/material.dart';

import '../../services/device_role_service.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';

/// Pemilih peran perangkat saat pertama kali (atau diubah dari Settings):
/// Main POS (server) vs Station (client/tablet pelayan).
class RoleSelectorScreen extends StatelessWidget {
  /// Dipanggil setelah peran dipilih agar root me-refresh routing.
  final VoidCallback onSelected;
  const RoleSelectorScreen({super.key, required this.onSelected});

  Future<void> _choose(BuildContext context, DeviceRole role) async {
    await DeviceRoleService.instance.setRole(role);
    if (role == DeviceRole.mainPos) {
      await DeviceRoleService.instance.startMainPosServices();
    }
    onSelected();
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
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(
                  context.isPhone ? AppSpacing.lg : AppSpacing.xl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildBranding(context),
                    SizedBox(
                        height:
                            context.isPhone ? AppSpacing.lg : AppSpacing.xxl),
                    LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth > 560;
                        final mainPos = _RoleCard(
                          icon: Icons.point_of_sale_rounded,
                          title: 'Kasir Utama',
                          badge: 'SERVER',
                          subtitle:
                              'Main POS — server, kasir, dapur, laporan. Menjalankan API untuk station.',
                          accent: AppColors.brand,
                          onTap: () => _choose(context, DeviceRole.mainPos),
                        );
                        final station = _RoleCard(
                          icon: Icons.tablet_mac_rounded,
                          title: 'Station Pelayan',
                          badge: 'CLIENT',
                          subtitle:
                              'Client — pesan dari meja, terhubung ke Main POS via WiFi. Tanpa server.',
                          // SECONDARY gold: bedakan kartu Station (client) dari
                          // Main POS (hijau) — identitas primer+sekunder.
                          accent: AppColors.accent,
                          onTap: () => _choose(context, DeviceRole.station),
                        );
                        if (wide) {
                          return IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: mainPos),
                                const SizedBox(width: AppSpacing.md),
                                Expanded(child: station),
                              ],
                            ),
                          );
                        }
                        return Column(
                          children: [
                            mainPos,
                            const SizedBox(height: AppSpacing.md),
                            station,
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'Peran bisa diubah nanti dari Pengaturan.',
                      textAlign: TextAlign.center,
                      style: AppType.caption.copyWith(
                        color: AppColors.soft(Colors.white, 0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBranding(BuildContext context) {
    final compact = context.isPhone;
    return Column(
      children: [
        Container(
          width: compact ? 64 : 76,
          height: compact ? 64 : 76,
          decoration: BoxDecoration(
            color: AppColors.soft(Colors.white, 0.95),
            borderRadius: AppRadius.rXl,
            border: Border.all(color: AppColors.soft(Colors.white, 0.6)),
            boxShadow: AppShadows.glow(AppColors.greenDark, strength: 0.4),
          ),
          child: Icon(Icons.devices_other_rounded,
              color: AppColors.green, size: compact ? 32 : 38),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Perangkat ini sebagai?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 22 : 26,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Pilih peran perangkat untuk memulai',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String badge;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.badge,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final compact = context.isPhone;
    return AppCard(
      onTap: onTap,
      accent: accent,
      padding: EdgeInsets.all(compact ? AppSpacing.lg : AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconBadge(
                  icon: icon, color: accent, size: compact ? 48 : 60,
                  filled: true),
              const Spacer(),
              StatusPill(label: badge, color: accent),
            ],
          ),
          SizedBox(height: compact ? AppSpacing.md : AppSpacing.lg),
          Text(title, style: AppType.h2),
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitle,
            style: AppType.body.copyWith(color: AppColors.textSecondary),
          ),
          SizedBox(height: compact ? AppSpacing.md : AppSpacing.lg),
          Row(
            children: [
              Text('Pilih', style: AppType.label.copyWith(color: accent)),
              const SizedBox(width: AppSpacing.xxs),
              Icon(Icons.arrow_forward_rounded, size: 18, color: accent),
            ],
          ),
        ],
      ),
    );
  }
}
