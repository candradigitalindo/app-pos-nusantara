import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import 'ui/ui.dart';

/// Hasil dialog pesanan baru: jumlah pax (wajib) + identitas customer (opsional).
class PaxResult {
  final int pax;
  final String? customerName;
  final String? customerPhone;
  const PaxResult({required this.pax, this.customerName, this.customerPhone});
}

/// Dialog input jumlah tamu (pax) + identitas customer untuk pesanan BARU.
/// Hanya pax yang wajib; Nama & No. HP opsional. Mengembalikan [PaxResult],
/// atau null bila dibatalkan.
///
/// Responsif: bottom-sheet di ponsel, dialog terpusat di tablet.
Future<PaxResult?> showPaxDialog(BuildContext context, {int initial = 1}) {
  return showAppModal<PaxResult>(
    context,
    title: 'Pesanan Baru',
    subtitle: 'Jumlah tamu (pax) wajib diisi',
    icon: Icons.groups_rounded,
    accent: AppColors.moduleKasir,
    dismissible: false,
    maxWidth: 460,
    builder: (_) => _PaxInputBody(initial: initial),
  );
}

class _PaxInputBody extends StatefulWidget {
  final int initial;
  const _PaxInputBody({required this.initial});

  @override
  State<_PaxInputBody> createState() => _PaxInputBodyState();
}

class _PaxInputBodyState extends State<_PaxInputBody> {
  late int _pax = widget.initial.clamp(1, 99);
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  static const _accent = AppColors.moduleKasir;

  void _set(int v) => setState(() => _pax = v.clamp(1, 99));

  void _submit() {
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    Navigator.pop(
      context,
      PaxResult(
        pax: _pax,
        customerName: name.isEmpty ? null : name,
        customerPhone: phone.isEmpty ? null : phone,
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pax stepper — besar di tengah
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: AppRadius.rXl,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _stepBtn(Icons.remove_rounded, () => _set(_pax - 1)),
                Container(
                  width: 120,
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$_pax',
                          style: const TextStyle(
                              fontSize: 46, fontWeight: FontWeight.w800, height: 1.0)),
                      Text('pax', style: AppType.caption.copyWith(color: AppColors.textTertiary)),
                    ],
                  ),
                ),
                _stepBtn(Icons.add_rounded, () => _set(_pax + 1)),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text('IDENTITAS CUSTOMER (OPSIONAL)', style: AppType.overline),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nama (opsional)',
            prefixIcon: Icon(Icons.person_rounded),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]'))],
          decoration: const InputDecoration(
            labelText: 'No. HP (opsional)',
            prefixIcon: Icon(Icons.phone_rounded),
          ),
        ),
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
                label: 'Lanjut',
                icon: Icons.arrow_forward_rounded,
                onPressed: _submit,
                accent: _accent,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback onTap) => Material(
        color: _accent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
      );
}
