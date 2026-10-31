import 'package:flutter/material.dart';
import '../../theme/theme.dart';
import 'app_button.dart';

/// Helper modal responsif terpusat.
///
/// - Di ponsel: tampil sebagai bottom-sheet (mudah dijangkau ibu jari).
/// - Di tablet/desktop: tampil sebagai dialog terpusat dengan lebar nyaman.
///
/// Selalu membungkus konten dengan header (judul + tombol tutup) yang seragam
/// sehingga SEMUA modal terasa konsisten.
Future<T?> showAppModal<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData? icon,
  Color? accent,
  required Widget Function(BuildContext) builder,
  bool scrollable = true,
  double maxWidth = 520,
  bool dismissible = true,
}) {
  final isPhone = context.isPhone;

  Widget content(BuildContext ctx) => _ModalShell(
        title: title,
        subtitle: subtitle,
        icon: icon,
        accent: accent ?? AppColors.brand,
        isSheet: isPhone,
        scrollable: scrollable,
        child: builder(ctx),
      );

  if (isPhone) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.soft(Colors.black, 0.45),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: content(ctx),
      ),
    );
  }

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: title,
    barrierColor: AppColors.soft(Colors.black, 0.42),
    transitionDuration: AppMotion.normal,
    pageBuilder: (ctx, a1, a2) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, sec, _) {
      final curved = CurvedAnimation(parent: anim, curve: AppMotion.easeOut);
      // Keyboard hanya mendorong dari BAWAH. Dulu inset dipakai simetris
      // (atas + bawah) sehingga modal berisi beberapa kolom isian bisa
      // kehabisan ruang dan tampil "BOTTOM OVERFLOWED" saat keyboard muncul.
      final insets = MediaQuery.viewInsetsOf(ctx).bottom;
      final available = MediaQuery.sizeOf(ctx).height - insets;
      return Opacity(
        opacity: curved.value,
        child: Transform.scale(
          scale: 0.96 + 0.04 * curved.value,
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.xl,
                right: AppSpacing.xl,
                top: AppSpacing.xl,
                bottom: insets + AppSpacing.xl,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: available * 0.86,
                ),
                child: content(ctx),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Cangkang modal seragam (header + konten). Dipakai internal oleh [showAppModal],
/// tapi juga bisa dipakai langsung sebagai isi dialog kustom.
class _ModalShell extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color accent;
  final bool isSheet;
  final bool scrollable;
  final Widget child;

  const _ModalShell({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.isSheet,
    required this.scrollable,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final radius = isSheet
        ? const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl))
        : AppRadius.rXxl;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.soft(accent, 0.12),
                borderRadius: AppRadius.rSm,
              ),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppType.h3, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(subtitle!,
                      style: AppType.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          AppIconButton(
            icon: Icons.close_rounded,
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: 'Tutup',
          ),
        ],
      ),
    );

    final body = scrollable
        ? Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
              child: child,
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
            child: child,
          );

    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: AppShadows.modal,
      ),
      clipBehavior: Clip.antiAlias,
      // Material WAJIB: menyediakan ancestor Material untuk TextField/InkWell di
      // dalam modal — jalur dialog tablet (showGeneralDialog) tak menyediakannya.
      child: Material(
        color: AppColors.surface,
        child: SafeArea(
          top: false,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSheet)
              Container(
                margin: const EdgeInsets.only(top: AppSpacing.sm),
                width: 40,
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.borderStrong,
                  borderRadius: AppRadius.rPill,
                ),
              ),
            header,
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.md),
            body,
          ],
        ),
        ),
      ),
    );
  }
}

/// Dialog konfirmasi seragam (mis. hapus, void, batal). Mengembalikan `true`
/// bila pengguna menekan tombol konfirmasi.
Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'Ya, Lanjutkan',
  String cancelText = 'Batal',
  IconData icon = Icons.help_outline_rounded,
  bool destructive = false,
}) async {
  final accent = destructive ? AppColors.danger : AppColors.brand;
  final result = await showAppModal<bool>(
    context,
    title: title,
    icon: icon,
    accent: accent,
    scrollable: false,
    maxWidth: 440,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message, style: AppType.body.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: AppButton.neutral(cancelText,
                  onPressed: () => Navigator.of(ctx).pop(false)),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: AppButton(
                label: confirmText,
                variant: destructive
                    ? AppButtonVariant.danger
                    : AppButtonVariant.primary,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Snackbar seragam (sukses / error / info).
void showAppSnack(
  BuildContext context,
  String message, {
  bool isError = false,
  IconData? icon,
}) {
  final color = isError ? AppColors.danger : AppColors.success;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon ?? (isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded),
                color: color, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}
