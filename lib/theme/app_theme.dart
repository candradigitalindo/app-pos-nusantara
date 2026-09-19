import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// Membangun [ThemeData] terpusat dari token design system.
///
/// Menyetel tema untuk komponen Material bawaan (dialog, tombol, input,
/// app bar, kartu, snackbar, dll) sekaligus — sehingga SEMUA screen otomatis
/// tampil premium & konsisten walau belum di-refactor per widget.
class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.brand,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.danger,
      surfaceContainerLowest: AppColors.surface,
      surfaceContainerLow: AppColors.surfaceAlt,
      outlineVariant: AppColors.border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.canvas,
      splashFactory: InkSparkle.splashFactory,
      textTheme: _textTheme,
      fontFamily: null,

      // ── AppBar ────────────────────────────────────────────────────────────
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: AppType.h3,
        iconTheme: const IconThemeData(color: AppColors.textPrimary, size: 22),
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),

      // ── Kartu ─────────────────────────────────────────────────────────────
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.rLg,
          side: BorderSide(color: AppColors.border),
        ),
      ),

      // ── Dialog ────────────────────────────────────────────────────────────
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rXxl),
        titleTextStyle: AppType.h2,
        contentTextStyle: AppType.body,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      ),

      // ── Bottom sheet ──────────────────────────────────────────────────────
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
        clipBehavior: Clip.antiAlias,
        showDragHandle: true,
        dragHandleColor: AppColors.borderStrong,
      ),

      // ── Tombol utama (Elevated / Filled) ─────────────────────────────────
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: AppColors.textOnBrand,
          disabledBackgroundColor: AppColors.surfaceMuted,
          disabledForegroundColor: AppColors.textTertiary,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          textStyle: AppType.title,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: AppColors.textOnBrand,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          textStyle: AppType.title,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
        ),
      ),

      // ── Tombol garis (Outlined) ──────────────────────────────────────────
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.brand,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          textStyle: AppType.title,
          side: const BorderSide(color: AppColors.borderStrong, width: 1.5),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
        ),
      ),

      // ── Tombol teks ──────────────────────────────────────────────────────
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.brand,
          textStyle: AppType.title,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.rSm),
        ),
      ),

      // ── Input / TextField ────────────────────────────────────────────────
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
        hintStyle: AppType.body.copyWith(color: AppColors.textTertiary),
        labelStyle: AppType.body.copyWith(color: AppColors.textSecondary),
        prefixIconColor: AppColors.textTertiary,
        suffixIconColor: AppColors.textTertiary,
        border: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.brand, width: 2),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.danger, width: 1.5),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: AppRadius.rMd,
          borderSide: BorderSide(color: AppColors.danger, width: 2),
        ),
      ),

      // ── Chip ──────────────────────────────────────────────────────────────
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceMuted,
        selectedColor: AppColors.soft(AppColors.brand, 0.12),
        side: const BorderSide(color: AppColors.border),
        labelStyle: AppType.label,
        secondaryLabelStyle: AppType.label,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rPill),
      ),

      // ── Divider ───────────────────────────────────────────────────────────
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),

      // ── Snackbar ──────────────────────────────────────────────────────────
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.textPrimary,
        contentTextStyle: AppType.body.copyWith(color: Colors.white),
        actionTextColor: AppColors.brandLight,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.rMd),
        insetPadding: const EdgeInsets.all(AppSpacing.md),
      ),

      // ── Icon ──────────────────────────────────────────────────────────────
      iconTheme: const IconThemeData(color: AppColors.textSecondary, size: 22),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.brand),
      dividerColor: AppColors.border,

      // ── Switch / Checkbox / Radio ─────────────────────────────────────────
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : Colors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.brand : AppColors.borderStrong,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.brand : Colors.transparent,
        ),
        side: const BorderSide(color: AppColors.borderStrong, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.brand : AppColors.borderStrong,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: AppColors.brand,
        unselectedLabelColor: AppColors.textTertiary,
        labelStyle: AppType.title,
        unselectedLabelStyle: AppType.body,
        indicatorColor: AppColors.brand,
        dividerColor: Colors.transparent,
      ),
    );
  }

  static TextTheme get _textTheme => TextTheme(
        displayLarge: AppType.display,
        headlineLarge: AppType.h1,
        headlineMedium: AppType.h2,
        headlineSmall: AppType.h3,
        titleLarge: AppType.title,
        titleMedium: AppType.label,
        bodyLarge: AppType.bodyLg,
        bodyMedium: AppType.body,
        bodySmall: AppType.bodySm,
        labelLarge: AppType.label,
        labelMedium: AppType.caption,
        labelSmall: AppType.overline,
      );
}
