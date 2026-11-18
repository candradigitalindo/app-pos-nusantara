import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/ui/ui.dart';

typedef ClosedShiftSummary = ({
  CashierShift shift,
  double? salesTotal,
  int? salesCount,
  bool frozen
});

const _days = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', //
  'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des',
];

String _two(int v) => v.toString().padLeft(2, '0');
String _time(DateTime t) {
  final l = t.toLocal();
  return '${_two(l.hour)}:${_two(l.minute)}';
}

String _date(DateTime t) {
  final l = t.toLocal();
  return '${_days[l.weekday - 1]}, ${l.day} ${_months[l.month - 1]} ${l.year}';
}

/// Ditampilkan tepat setelah tutup kasir berhasil. Laporan sudah otomatis
/// masuk antrean cetak; dialog ini memberi jalan cetak ulang di tempat
/// (kertas habis, struk rusak, atau butuh salinan untuk owner/keuangan).
class ShiftClosedDialog extends StatefulWidget {
  /// Mengembalikan null bila salinan masuk antrean cetak, atau pesan error.
  final Future<String?> Function() onReprint;

  const ShiftClosedDialog({super.key, required this.onReprint});

  @override
  State<ShiftClosedDialog> createState() => _ShiftClosedDialogState();
}

class _ShiftClosedDialogState extends State<ShiftClosedDialog> {
  bool _printing = false;
  String? _result;
  bool _resultIsError = false;
  int _copies = 0;

  Future<void> _reprint() async {
    setState(() {
      _printing = true;
      _result = null;
    });
    String? error;
    try {
      error = await widget.onReprint();
    } catch (e) {
      error = 'Gagal mencetak laporan: $e';
    }
    if (!mounted) return;
    setState(() {
      _printing = false;
      _resultIsError = error != null;
      if (error == null) _copies++;
      _result = error ??
          (_copies == 1
              ? 'Salinan laporan dikirim ke printer kasir.'
              : 'Salinan ke-$_copies dikirim ke printer kasir.');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const IconBadge(
                  icon: Icons.check_circle_rounded,
                  color: AppColors.success,
                  size: 56),
              const SizedBox(height: AppSpacing.md),
              Text('Kasir Ditutup',
                  textAlign: TextAlign.center, style: AppType.h3),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Laporan tutup kasir sudah dikirim ke printer kasir. '
                'Tekan Cetak Ulang bila struknya tidak keluar atau perlu '
                'salinan — isinya sama persis dengan cetakan pertama.',
                textAlign: TextAlign.center,
                style: AppType.body.copyWith(color: AppColors.textSecondary),
              ),
              if (_result != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _result!,
                  key: const Key('shift-reprint-result'),
                  textAlign: TextAlign.center,
                  style: AppType.bodySm.copyWith(
                    color:
                        _resultIsError ? AppColors.danger : AppColors.success,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                key: const Key('shift-closed-reprint'),
                label: 'Cetak Ulang',
                icon: Icons.print_outlined,
                variant: AppButtonVariant.tonal,
                accent: AppColors.moduleKasir,
                loading: _printing,
                onPressed: _printing ? null : _reprint,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                key: const Key('shift-closed-done'),
                label: 'Selesai',
                accent: AppColors.moduleKasir,
                onPressed:
                    _printing ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Daftar shift yang sudah ditutup di tablet ini (terbaru dulu). Ketuk satu
/// shift untuk mencetak ulang laporan TUTUP KASIR / GANTI SHIFT-nya.
class ClosedShiftReprintDialog extends StatefulWidget {
  final Future<List<ClosedShiftSummary>> Function() loadShifts;

  /// Mengembalikan null bila salinan masuk antrean cetak, atau pesan error.
  final Future<String?> Function(String shiftId) onReprint;

  const ClosedShiftReprintDialog({
    super.key,
    required this.loadShifts,
    required this.onReprint,
  });

  @override
  State<ClosedShiftReprintDialog> createState() =>
      _ClosedShiftReprintDialogState();
}

class _ClosedShiftReprintDialogState extends State<ClosedShiftReprintDialog> {
  List<ClosedShiftSummary>? _shifts;
  String? _loadError;
  String? _printingId;
  final _results = <String, ({String text, bool error})>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final shifts = await widget.loadShifts();
      if (mounted) setState(() => _shifts = shifts);
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Gagal memuat daftar shift: $e');
    }
  }

  Future<void> _reprint(String shiftId) async {
    setState(() {
      _printingId = shiftId;
      _results.remove(shiftId);
    });
    String? error;
    try {
      error = await widget.onReprint(shiftId);
    } catch (e) {
      error = 'Gagal mencetak laporan: $e';
    }
    if (!mounted) return;
    setState(() {
      _printingId = null;
      _results[shiftId] = (
        text: error ?? 'Dikirim ke printer kasir',
        error: error != null,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final shifts = _shifts;
    Widget body;
    if (_loadError != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_loadError!,
              style: AppType.bodySm.copyWith(color: AppColors.danger)),
          TextButton(onPressed: _load, child: const Text('Muat Ulang')),
        ],
      );
    } else if (shifts == null) {
      body = const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (shifts.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text('Belum ada shift yang ditutup di tablet ini.',
            textAlign: TextAlign.center,
            style: AppType.body.copyWith(color: AppColors.textSecondary)),
      );
    } else {
      body = Flexible(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: shifts.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs),
          itemBuilder: (_, i) => _tile(shifts[i]),
        ),
      );
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const IconBadge(
                      icon: Icons.print_outlined,
                      color: AppColors.moduleKasir,
                      size: 40),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Cetak Ulang Laporan Tutup Kasir',
                            style: AppType.title),
                        Text('Pilih shift — isi sama dengan cetakan asli',
                            style: AppType.caption),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close,
                        color: AppColors.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              body,
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(ClosedShiftSummary s) {
    final shift = s.shift;
    final closedAt = shift.closedAt ?? shift.updatedAt;
    final handover = (shift.handoverTo ?? '').trim().isNotEmpty;
    final printing = _printingId == shift.id;
    final result = _results[shift.id];
    final sales = s.salesTotal == null
        ? null
        : '${CurrencyHelper.format(s.salesTotal!)}'
            '${s.salesCount == null ? '' : ' · ${s.salesCount} trx'}';
    return AppCard(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: InkWell(
        key: Key('reprint-shift-${shift.id}'),
        onTap: _printingId != null ? null : () => _reprint(shift.id),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${handover ? 'Ganti Shift' : 'Tutup Kasir'} · '
                      '${_date(closedAt)}',
                      style: AppType.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                      '${_time(shift.openedAt)}–${_time(closedAt)} · '
                      '${shift.openedBy}${sales == null ? '' : ' · $sales'}',
                      style: AppType.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (!s.frozen)
                    Text('Shift versi lama — dihitung ulang dari data tablet',
                        style: AppType.caption
                            .copyWith(color: AppColors.warning)),
                  if (result != null)
                    Text(result.text,
                        style: AppType.caption.copyWith(
                          color: result.error
                              ? AppColors.danger
                              : AppColors.success,
                          fontWeight: FontWeight.w700,
                        )),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            printing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Icon(Icons.print_rounded,
                    color: AppColors.moduleKasir),
          ],
        ),
      ),
    );
  }
}
