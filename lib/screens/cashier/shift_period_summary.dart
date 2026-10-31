import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';

/// Calendar-day detail is separate from the full drawer/shift ledger.
class ShiftPeriodSummary extends StatelessWidget {
  final CashierShift shift;
  final Map<String, dynamic> report;

  const ShiftPeriodSummary(
      {super.key, required this.shift, required this.report});

  static String dateTimeLabel(DateTime value) {
    final t = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)}/${t.year} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    DateTime? timestamp(String key) =>
        DateTime.tryParse(report[key]?.toString() ?? '')?.toLocal();
    final start = timestamp('period_start') ?? shift.openedAt.toLocal();
    final end = timestamp('period_end') ?? shift.closedAt ?? DateTime.now();
    final last = end.isAfter(start)
        ? end.subtract(const Duration(microseconds: 1))
        : end;
    final crossesDay = report['crosses_day'] as bool? ??
        (start.year != last.year ||
            start.month != last.month ||
            start.day != last.day);
    final days =
        (report['by_day'] as List? ?? const []).whereType<Map>().toList();
    final outside = (report['out_of_period_movement_count'] as num? ?? 0) > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Periode shift: ${dateTimeLabel(start)} – ${dateTimeLabel(end)}',
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        if (crossesDay) ...[
          const SizedBox(height: 8),
          const Text(
            'Shift melintasi tanggal. Penjualan per hari dirinci di bawah; total shift mencakup seluruh periode.',
            style: TextStyle(
                fontSize: 12,
                color: AppColors.warning,
                fontWeight: FontWeight.w600),
          ),
        ],
        if (outside) ...[
          const SizedBox(height: 8),
          const Text(
              'Ada mutasi kas di luar rentang shift; periksa rincian kas.',
              style: TextStyle(fontSize: 12, color: AppColors.warning)),
        ],
        if (days.isNotEmpty && (crossesDay || days.length > 1 || outside)) ...[
          const SizedBox(height: 12),
          const Text('PENJUALAN PER HARI',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final day in days)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 12, runSpacing: 3, children: [
                      Text('${day['date'] ?? '-'}',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      Text(
                          '${(day['sales_count'] as num? ?? 0).toInt()} transaksi',
                          style: const TextStyle(fontSize: 12)),
                      Text(
                          CurrencyHelper.format(
                              (day['sales_total'] as num? ?? 0).toDouble()),
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                    ]),
                    if ((day['cash_in_total'] as num? ?? 0) != 0 ||
                        (day['cash_out_total'] as num? ?? 0) != 0)
                      Text(
                          'Kas masuk ${CurrencyHelper.format((day['cash_in_total'] as num? ?? 0).toDouble())} · Kas keluar ${CurrencyHelper.format((day['cash_out_total'] as num? ?? 0).toDouble())}',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary)),
                    if (day['outside_shift'] == true)
                      const Text('Memuat mutasi di luar rentang shift',
                          style: TextStyle(
                              fontSize: 11, color: AppColors.warning)),
                  ]),
            ),
          const Text(
              'Kas laci mencakup modal awal dan seluruh mutasi kas shift.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ],
    );
  }
}
