import 'package:flutter/material.dart';
import '../../theme/theme.dart';
import 'app_button.dart';

/// Label bagian (mis. "OPERASIONAL", "MANAJEMEN") — huruf kapital renggang.
class SectionHeader extends StatelessWidget {
  final String label;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const SectionHeader(
    this.label, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: AppSpacing.sm),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: Text(label.toUpperCase(), style: AppType.overline)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Kapsul status berwarna (badge) — untuk status meja/order/pembayaran, dll.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  final bool solid;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = solid ? Colors.white : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 5),
      decoration: BoxDecoration(
        color: solid ? color : AppColors.soft(color, 0.12),
        borderRadius: AppRadius.rPill,
        border: solid ? null : Border.all(color: AppColors.soft(color, 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg),
          ),
        ],
      ),
    );
  }
}

/// Tampilan keadaan kosong yang ramah (ikon lembut + pesan + aksi opsional).
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color? accent;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = accent ?? AppColors.brand;
    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [AppColors.soft(c, 0.14), AppColors.soft(c, 0.04)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Icon(icon, size: 44, color: AppColors.soft(c, 0.9)),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(title, style: AppType.h3, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              message!,
              style: AppType.body.copyWith(color: AppColors.textTertiary),
              textAlign: TextAlign.center,
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: actionLabel!,
              icon: Icons.add_rounded,
              onPressed: onAction,
              expanded: false,
              accent: c,
            ),
          ],
        ],
      ),
    );

    // Anti-overflow: terpusat bila ruang cukup, bisa digulir bila layar pendek
    // (mis. ponsel landscape). Aman juga di konteks tinggi tak terbatas.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxHeight.isFinite) return Center(child: content);
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

/// Loader terpusat seragam.
class AppLoader extends StatelessWidget {
  final String? label;
  const AppLoader({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2.8),
          ),
          if (label != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(label!, style: AppType.caption),
          ],
        ],
      ),
    );
  }
}

/// Latar halaman dengan gradasi halus — dipakai sebagai `body` scaffold agar
/// semua layar punya kedalaman lembut yang seragam.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: AppColors.canvasGradient,
        ),
      ),
      child: child,
    );
  }
}

/// Header halaman premium (untuk screen yang dibuka dari dashboard).
/// Responsif: judul + subjudul + tombol kembali + slot aksi kanan.
class AppPageHeader extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color accent;
  final List<Widget> actions;
  final bool showBack;
  final VoidCallback? onBack;

  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.accent = AppColors.brand,
    this.actions = const [],
    this.showBack = true,
    this.onBack,
  });

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.pagePadX, vertical: AppSpacing.sm),
          child: Row(
            children: [
              if (showBack) ...[
                AppIconButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                  filled: true,
                  size: 42,
                  tooltip: 'Kembali',
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (icon != null) ...[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: AppColors.gradientOf(accent)),
                    borderRadius: AppRadius.rSm,
                    boxShadow: AppShadows.glow(accent, strength: 0.28),
                  ),
                  child: Icon(icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: AppType.h3, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: AppType.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}
