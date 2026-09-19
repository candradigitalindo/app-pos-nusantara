import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/theme.dart';
import '../utils/currency.dart';
import 'ui/ui.dart';

/// Dialog pemilih add-on/modifier untuk satu menu (mis. "Extra keju +5.000").
///
/// Mengembalikan daftar add-on terpilih — daftar kosong berarti tamu tidak
/// mengambil tambahan apa pun, dan `null` berarti dialog dibatalkan (pemanggil
/// harus membatalkan penambahan item, bukan menambahkannya tanpa add-on).
///
/// Pemilihan bersifat bebas/multi-pilih; [ProductAddon.groupName] hanya
/// mengelompokkan tampilan agar daftar panjang tetap terbaca.
Future<List<SelectedAddon>?> showAddonPicker(
  BuildContext context, {
  required String productName,
  required double basePrice,
  required List<ProductAddon> addons,
  List<SelectedAddon> initial = const [],
  Color accent = AppColors.moduleKasir,
}) {
  return showAppModal<List<SelectedAddon>>(
    context,
    title: productName,
    subtitle: 'Pilih tambahan (opsional)',
    icon: Icons.tune_rounded,
    accent: accent,
    maxWidth: 460,
    builder: (_) => _AddonPickerBody(
      basePrice: basePrice,
      addons: addons,
      initial: initial,
      accent: accent,
    ),
  );
}

class _AddonPickerBody extends StatefulWidget {
  final double basePrice;
  final List<ProductAddon> addons;
  final List<SelectedAddon> initial;
  final Color accent;

  const _AddonPickerBody({
    required this.basePrice,
    required this.addons,
    required this.initial,
    required this.accent,
  });

  @override
  State<_AddonPickerBody> createState() => _AddonPickerBodyState();
}

class _AddonPickerBodyState extends State<_AddonPickerBody> {
  late final Set<String> _picked = {...widget.initial.map((a) => a.id)};

  double get _addonTotal => widget.addons
      .where((a) => _picked.contains(a.id))
      .fold<double>(0, (s, a) => s + a.price);

  void _toggle(String id) => setState(() {
        if (!_picked.remove(id)) _picked.add(id);
      });

  void _submit() {
    final chosen = widget.addons
        .where((a) => _picked.contains(a.id))
        .map(SelectedAddon.fromAddon)
        .toList();
    Navigator.pop(context, chosen);
  }

  /// Kelompokkan menurut group_name, mempertahankan urutan sort_order asli.
  /// Add-on tanpa grup masuk ke kelompok tanpa judul di paling atas.
  Map<String, List<ProductAddon>> get _grouped {
    final map = <String, List<ProductAddon>>{};
    for (final a in widget.addons) {
      map.putIfAbsent(a.groupName, () => []).add(a);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _grouped;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scroll ditangani oleh shell modal (showAppModal scrollable: true),
        // jadi daftar di sini cukup mengalir apa adanya.
        for (final entry in groups.entries) ...[
          if (entry.key.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(entry.key.toUpperCase(), style: AppType.overline),
            const SizedBox(height: AppSpacing.xs),
          ],
          for (final addon in entry.value) _tile(addon),
        ],
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: AppRadius.rLg,
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _addonTotal > 0
                      ? 'Harga menu + ${CurrencyHelper.format(_addonTotal)} tambahan'
                      : 'Tanpa tambahan',
                  style: AppType.caption
                      .copyWith(color: AppColors.textTertiary),
                ),
              ),
              Text(
                CurrencyHelper.format(widget.basePrice + _addonTotal),
                style: AppType.body.copyWith(
                  fontWeight: FontWeight.w700,
                  color: widget.accent,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: AppButton.neutral(
                'Batal',
                onPressed: () => Navigator.pop(context),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: 2,
              child: AppButton(
                label: 'Tambahkan',
                icon: Icons.add_shopping_cart_rounded,
                onPressed: _submit,
                accent: widget.accent,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tile(ProductAddon addon) {
    final selected = _picked.contains(addon.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Material(
        color: selected ? widget.accent.withValues(alpha: .08) : AppColors.surfaceAlt,
        borderRadius: AppRadius.rLg,
        child: InkWell(
          borderRadius: AppRadius.rLg,
          onTap: () => _toggle(addon.id),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              borderRadius: AppRadius.rLg,
              border: Border.all(
                color: selected ? widget.accent : AppColors.border,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 22,
                  color: selected ? widget.accent : AppColors.textTertiary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    addon.name,
                    style: AppType.body.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  addon.price > 0
                      ? '+${CurrencyHelper.format(addon.price)}'
                      : 'Gratis',
                  style: AppType.caption.copyWith(
                    color: addon.price > 0
                        ? AppColors.textSecondary
                        : AppColors.textTertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
