import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/reservation_service.dart';
import '../theme/theme.dart';
import 'ui/ui.dart';

/// Daftar reservasi hari ini dari cloud. Mengembalikan reservasi yang dipilih
/// kasir untuk dibuka menjadi order; pemilihan meja dilakukan pemanggil.
Future<CloudReservation?> showReservationPicker(BuildContext context) {
  return showAppModal<CloudReservation>(
    context,
    title: 'Reservasi Hari Ini',
    subtitle: 'Buka menjadi order meja. DP yang sudah divalidasi ikut tercatat.',
    icon: Icons.event_seat_outlined,
    accent: AppColors.moduleKasir,
    maxWidth: 640,
    builder: (_) => const _ReservationList(),
  );
}

class _ReservationList extends StatefulWidget {
  const _ReservationList();

  @override
  State<_ReservationList> createState() => _ReservationListState();
}

class _ReservationListState extends State<_ReservationList> {
  final _rupiah =
      NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);
  bool _loading = true;
  String _error = '';
  List<CloudReservation> _list = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final list = await ReservationService.instance.fetchToday();
      if (!mounted) return;
      setState(() => _list = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Gagal memuat reservasi: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error.isNotEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.danger)),
          ),
          TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Coba lagi')),
        ],
      );
    }
    if (_list.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Tidak ada reservasi untuk hari ini.\nReservasi yang menunggu DP atau sudah dikonfirmasi akan tampil di sini.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Muat ulang')),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Muat ulang')),
        ),
        for (final r in _list) _card(context, r),
      ],
    );
  }

  Widget _card(BuildContext context, CloudReservation r) {
    final menu = r.items.map((i) => '${i.qty}× ${i.productName}').join(', ');
    final confirmed = r.isConfirmed;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(r.customerName.isEmpty ? 'Tanpa nama' : r.customerName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: confirmed ? AppColors.successSoft : AppColors.warningSoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  confirmed ? 'Dikonfirmasi' : 'Menunggu DP',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: confirmed ? AppColors.success : AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${r.time.isEmpty ? '-' : r.time} · ${r.pax} tamu'
            '${r.customerPhone.isEmpty ? '' : ' · ${r.customerPhone}'}',
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
          if (menu.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(menu,
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
          ],
          if (r.notes.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Catatan: ${r.notes}',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    _money('Total', r.total),
                    _money('DP tervalidasi', r.paidAmount),
                    _money('Sisa', r.remaining, strong: true),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(r),
                icon: const Icon(Icons.table_restaurant_outlined, size: 18),
                label: const Text('Buka ke Meja'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _money(String label, double v, {bool strong = false}) => RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: _rupiah.format(v),
              style: TextStyle(
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
          ],
        ),
      );
}
