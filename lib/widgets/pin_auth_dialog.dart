import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import 'ui/ui.dart';

/// Hasil dialog otorisasi: PIN + alasan (bila diminta).
class PinAuthResult {
  final String pin;
  final String reason;
  const PinAuthResult({required this.pin, this.reason = ''});
}

/// Dialog OTORISASI PIN (Manager/SVP) yang besar & informatif — dipakai untuk
/// aksi sensitif: void transaksi, hapus item, bayar dari layar transaksi, dll.
/// [details] = rincian aksi (label → nilai) yang ditampilkan di kartu info.
/// Mengembalikan [PinAuthResult] atau null bila dibatalkan.
///
/// Responsif: bottom-sheet di ponsel, dialog terpusat di tablet.
Future<PinAuthResult?> showPinAuthDialog(
  BuildContext context, {
  required String title,
  required String actionLabel,
  Color actionColor = AppColors.danger,
  IconData icon = Icons.verified_user_rounded,
  Map<String, String> details = const {},
  bool askReason = true,
  String reasonHint = 'Contoh: salah input, refund pelanggan',
}) {
  return showAppModal<PinAuthResult>(
    context,
    title: title,
    subtitle: 'Perlu otorisasi Manager / SVP',
    icon: icon,
    accent: actionColor,
    maxWidth: 480,
    builder: (_) => _PinAuthBody(
      actionLabel: actionLabel,
      actionColor: actionColor,
      details: details,
      askReason: askReason,
      reasonHint: reasonHint,
    ),
  );
}

class _PinAuthBody extends StatefulWidget {
  final String actionLabel;
  final Color actionColor;
  final Map<String, String> details;
  final bool askReason;
  final String reasonHint;

  const _PinAuthBody({
    required this.actionLabel,
    required this.actionColor,
    required this.details,
    required this.askReason,
    required this.reasonHint,
  });

  @override
  State<_PinAuthBody> createState() => _PinAuthBodyState();
}

class _PinAuthBodyState extends State<_PinAuthBody> {
  final _pinCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  bool _pinEmpty = false;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty) {
      setState(() => _pinEmpty = true);
      return;
    }
    Navigator.pop(context, PinAuthResult(pin: pin, reason: _reasonCtrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Kartu rincian aksi
        if (widget.details.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: AppRadius.rMd,
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: widget.details.entries
                  .map((e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 110,
                              child: Text(e.key, style: AppType.caption),
                            ),
                            Expanded(child: Text(e.value, style: AppType.label)),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],

        // Input PIN besar
        TextField(
          controller: _pinCtrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 12),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) {
            if (_pinEmpty) setState(() => _pinEmpty = false);
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'PIN Otorisasi',
            hintText: '••••',
            counterText: '',
            errorText: _pinEmpty ? 'PIN wajib diisi' : null,
            prefixIcon: const Icon(Icons.lock_rounded),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'PIN yang berlaku: akun Admin / Manager / SVP, atau PIN void outlet.',
          style: AppType.caption.copyWith(color: AppColors.textTertiary),
        ),

        if (widget.askReason) ...[
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _reasonCtrl,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Alasan (opsional)',
              hintText: widget.reasonHint,
              prefixIcon: const Icon(Icons.notes_rounded),
            ),
          ),
        ],

        const SizedBox(height: AppSpacing.xl),
        Row(
          children: [
            Expanded(
              child: AppButton.neutral('Batal', onPressed: () => Navigator.pop(context)),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: 2,
              child: AppButton(
                label: widget.actionLabel,
                onPressed: _submit,
                accent: widget.actionColor,
                variant: AppButtonVariant.primary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
