import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/qris_service.dart';
import '../theme/theme.dart';
import '../utils/currency.dart';
import 'ui/ui.dart';

/// Dialog pembayaran QRIS terintegrasi: terbitkan tagihan, tampilkan QR, lalu
/// pantau sampai penyedia mengonfirmasi uangnya masuk.
///
/// Mengembalikan `true` HANYA bila tagihan benar-benar berstatus lunas —
/// pemanggil baru boleh mencatat pembayaran setelah itu. Nilai `false`/null
/// berarti batal, kedaluwarsa, atau gagal, dan tagihan TIDAK boleh dicatat.
Future<bool?> showQrisPaymentDialog(
  BuildContext context, {
  required String orderId,
  required double amount,
  required String description,
}) {
  return showAppModal<bool>(
    context,
    title: 'Pembayaran QRIS',
    subtitle: 'Tamu memindai kode di layar',
    icon: Icons.qr_code_2_rounded,
    accent: AppColors.moduleKasir,
    dismissible: false,
    maxWidth: 460,
    builder: (_) => _QrisPaymentBody(
      orderId: orderId,
      amount: amount,
      description: description,
    ),
  );
}

class _QrisPaymentBody extends StatefulWidget {
  final String orderId;
  final double amount;
  final String description;

  const _QrisPaymentBody({
    required this.orderId,
    required this.amount,
    required this.description,
  });

  @override
  State<_QrisPaymentBody> createState() => _QrisPaymentBodyState();
}

class _QrisPaymentBodyState extends State<_QrisPaymentBody> {
  static const _accent = AppColors.moduleKasir;

  StreamSubscription<QrisCharge>? _watch;
  QrisCharge? _charge;
  String? _error;
  bool _issuing = true;

  @override
  void initState() {
    super.initState();
    _issue();
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  Future<void> _issue() async {
    setState(() {
      _issuing = true;
      _error = null;
    });
    try {
      final charge = await QrisService.instance.createCharge(
        orderId: widget.orderId,
        amount: widget.amount,
        description: widget.description,
      );
      if (!mounted) return;
      setState(() {
        _charge = charge;
        _issuing = false;
      });
      _startWatching(charge.chargeId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _issuing = false;
        _error = 'Gagal menerbitkan QR: $e';
      });
    }
  }

  void _startWatching(String chargeId) {
    _watch?.cancel();
    _watch = QrisService.instance.watch(chargeId).listen((charge) {
      if (!mounted) return;
      setState(() => _charge = charge);
      // Hanya status lunas yang menutup dialog dengan hasil sukses; sisanya
      // dibiarkan terlihat agar kasir tahu apa yang terjadi.
      if (charge.isPaid) Navigator.pop(context, true);
    });
  }

  Future<void> _simulate() async {
    final id = _charge?.chargeId;
    if (id == null) return;
    try {
      await QrisService.instance.simulatePaid(id);
      // Status sebenarnya tetap datang lewat pemantauan, jadi tidak ada
      // jalur yang menutup dialog tanpa konfirmasi server.
    } catch (e) {
      if (mounted) showAppSnack(context, 'Simulasi gagal: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_issuing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_error!, style: AppType.body, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton.neutral('Tutup',
                    onPressed: () => Navigator.pop(context, false)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Coba Lagi',
                  icon: Icons.refresh_rounded,
                  accent: _accent,
                  onPressed: _issue,
                ),
              ),
            ],
          ),
        ],
      );
    }

    final charge = _charge!;
    final expired = charge.status == 'expired';
    final failed = charge.status == 'failed';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: AppRadius.rLg,
              border: Border.all(color: AppColors.border),
            ),
            child: Opacity(
              // QR yang tak lagi berlaku diredupkan supaya tamu tidak
              // memindai kode yang pasti ditolak.
              opacity: (expired || failed) ? 0.25 : 1,
              child: QrImageView(
                data: charge.qrString,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: Text(
            CurrencyHelper.format(charge.amount),
            style: AppType.amountLg.copyWith(color: _accent),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Center(child: _statusLine(charge, expired, failed)),
        if (charge.isMock) ...[
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.soft(AppColors.warning, 0.12),
              borderRadius: AppRadius.rMd,
            ),
            child: Row(
              children: [
                const Icon(Icons.science_outlined,
                    size: 18, color: AppColors.warning),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Penyedia tiruan aktif — tidak ada uang sungguhan yang '
                    'berpindah. Pasang penyedia asli sebelum dipakai melayani tamu.',
                    style: AppType.caption
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.neutral(
            'Tandai Lunas (simulasi)',
            icon: Icons.check_circle_outline_rounded,
            onPressed: charge.isPending ? _simulate : null,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: AppButton.neutral(
                charge.isPending ? 'Batal' : 'Tutup',
                onPressed: () => Navigator.pop(context, false),
              ),
            ),
            if (expired || failed) ...[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Terbitkan Ulang',
                  icon: Icons.refresh_rounded,
                  accent: _accent,
                  onPressed: _issue,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _statusLine(QrisCharge charge, bool expired, bool failed) {
    if (expired) {
      return Text('QR kedaluwarsa — terbitkan ulang',
          style: AppType.body.copyWith(color: AppColors.danger));
    }
    if (failed) {
      return Text('Pembayaran gagal di penyedia',
          style: AppType.body.copyWith(color: AppColors.danger));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text('Menunggu pembayaran tamu...',
            style: AppType.body.copyWith(color: AppColors.textSecondary)),
      ],
    );
  }
}
