import 'dart:ui';
import 'package:flutter/material.dart';
import '../../theme/theme.dart';

/// Kartu permukaan standar — putih, sudut lembut, border halus, bayangan tipis.
/// Fondasi visual untuk hampir semua panel di aplikasi.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? color;
  final BorderRadius? radius;
  final Border? border;
  final List<BoxShadow>? shadow;
  final Color? accent; // bila diisi, border kiri/aksen memakai warna ini

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.color,
    this.radius,
    this.border,
    this.shadow,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final r = radius ?? AppRadius.rLg;
    final content = AnimatedContainer(
      duration: AppMotion.fast,
      padding: padding ?? const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: r,
        border: border ??
            Border.all(
              color: accent != null
                  ? AppColors.soft(accent!, 0.22)
                  : AppColors.border,
            ),
        boxShadow: shadow ?? AppShadows.card,
      ),
      child: child,
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      borderRadius: r,
      child: InkWell(
        onTap: onTap,
        borderRadius: r,
        splashColor: AppColors.soft(accent ?? AppColors.brand, 0.08),
        highlightColor: AppColors.soft(accent ?? AppColors.brand, 0.04),
        child: content,
      ),
    );
  }
}

/// Kartu kaca (frosted glass) — latar buram + blur ala iOS.
/// Cocok di atas latar bergradasi / berwarna (header, hero, overlay).
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? radius;
  final double blur;
  final Color tint;
  final Color borderColor;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.radius,
    this.blur = 18,
    this.tint = AppColors.glassOnDark,
    this.borderColor = const Color(0x33FFFFFF),
  });

  @override
  Widget build(BuildContext context) {
    final r = radius ?? AppRadius.rLg;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding ?? const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: tint,
            borderRadius: r,
            border: Border.all(color: borderColor),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Kapsul ikon dengan latar aksen lembut (dipakai di kartu menu, list, stat).
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final bool filled; // true = gradasi penuh + glow, false = latar lembut

  const IconBadge({
    super.key,
    required this.icon,
    required this.color,
    this.size = 44,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: filled
            ? LinearGradient(
                colors: AppColors.gradientOf(color),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: filled ? null : AppColors.soft(color, 0.12),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: filled ? AppShadows.glow(color) : null,
      ),
      child: Icon(
        icon,
        size: size * 0.5,
        color: filled ? Colors.white : color,
      ),
    );
  }
}
