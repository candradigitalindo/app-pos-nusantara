import 'package:flutter/material.dart';
import '../../theme/theme.dart';

/// Varian tombol — warna & bobot visual berbeda sesuai peran aksi.
enum AppButtonVariant {
  /// Aksi utama (gradasi brand, glow).
  primary,

  /// Aksi sekunder (permukaan netral, border).
  neutral,

  /// Aksi tonal berwarna aksen (latar lembut).
  tonal,

  /// Aksi berbahaya (merah).
  danger,

  /// Aksi sukses / konfirmasi (hijau).
  success,
}

enum AppButtonSize { small, medium, large }

/// Tombol serbaguna dengan target sentuh besar & gaya konsisten.
/// Menggantikan kebutuhan menulis style tombol berulang di tiap screen.
class AppButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final bool expanded;
  final bool loading;
  final Color? accent; // override warna untuk tonal/primary

  const AppButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.large,
    this.expanded = true,
    this.loading = false,
    this.accent,
  });

  const AppButton.primary(this.label,
      {super.key,
      this.icon,
      required this.onPressed,
      this.size = AppButtonSize.large,
      this.expanded = true,
      this.loading = false,
      this.accent})
      : variant = AppButtonVariant.primary;

  const AppButton.neutral(this.label,
      {super.key,
      this.icon,
      required this.onPressed,
      this.size = AppButtonSize.large,
      this.expanded = true,
      this.loading = false})
      : variant = AppButtonVariant.neutral,
        accent = null;

  double get _height => switch (size) {
        AppButtonSize.small => 40,
        AppButtonSize.medium => 48,
        AppButtonSize.large => 56,
      };

  double get _fontSize => switch (size) {
        AppButtonSize.small => 13,
        AppButtonSize.medium => 15,
        AppButtonSize.large => 16,
      };

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || loading;
    final Color base = accent ??
        switch (variant) {
          AppButtonVariant.primary => AppColors.brand,
          AppButtonVariant.tonal => AppColors.brand,
          AppButtonVariant.danger => AppColors.danger,
          AppButtonVariant.success => AppColors.success,
          AppButtonVariant.neutral => AppColors.textSecondary,
        };

    final bool isGradient = variant == AppButtonVariant.primary;
    final bool isSolid =
        variant == AppButtonVariant.danger || variant == AppButtonVariant.success;
    final bool isTonal = variant == AppButtonVariant.tonal;
    final bool isNeutral = variant == AppButtonVariant.neutral;

    final Color fg = isGradient || isSolid
        ? Colors.white
        : isTonal
            ? base
            : AppColors.textPrimary;

    const radius = AppRadius.rMd;

    final child = Row(
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: _fontSize + 2,
            height: _fontSize + 2,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
          )
        else if (icon != null) ...[
          Icon(icon, size: _fontSize + 4, color: fg),
          const SizedBox(width: AppSpacing.xs),
        ],
        if (!loading)
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _fontSize,
                fontWeight: FontWeight.w700,
                color: fg,
                letterSpacing: -0.2,
              ),
            ),
          ),
      ],
    );

    return Opacity(
      opacity: disabled && !loading ? 0.5 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: disabled ? null : onPressed,
          borderRadius: radius,
          child: Ink(
            height: _height,
            decoration: BoxDecoration(
              gradient: isGradient
                  ? LinearGradient(
                      // Gradasi brand default; bila accent khusus diberi, pakai
                      // gradasi warna aksen tersebut (mis. tombol otorisasi merah).
                      colors: accent == null
                          ? AppColors.brandGradient
                          : AppColors.gradientOf(accent!),
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              color: isGradient
                  ? null
                  : isSolid
                      ? base
                      : isTonal
                          ? AppColors.soft(base, 0.12)
                          : AppColors.surface,
              borderRadius: radius,
              border: isNeutral
                  ? Border.all(color: AppColors.borderStrong, width: 1.5)
                  : isTonal
                      ? Border.all(color: AppColors.soft(base, 0.25))
                      : null,
              boxShadow: (isGradient || isSolid) && !disabled
                  ? AppShadows.glow(base, strength: 0.32)
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tombol ikon bulat/kotak dengan latar lembut — praktis untuk toolbar & header.
class AppIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final String? tooltip;
  final bool filled;

  const AppIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.color,
    this.size = 44,
    this.tooltip,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    final btn = Material(
      color: filled ? AppColors.soft(c, 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(size * 0.28),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(size * 0.28),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.5, color: c),
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}
