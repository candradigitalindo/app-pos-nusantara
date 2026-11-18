import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/procurement_payout_service.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/pin_auth_dialog.dart';
import '../../widgets/ui/ui.dart';

String _two(int v) => v.toString().padLeft(2, '0');
String _when(DateTime? t) {
  if (t == null) return '-';
  final l = t.toLocal();
  return '${_two(l.day)}/${_two(l.month)} ${_two(l.hour)}:${_two(l.minute)}';
}

/// Tugas "Bayar Pengadaan" dari Bagian Keuangan (sumber dana Kas Kasir Outlet).
/// Daftar diambil langsung dari cloud setiap kali dibuka; memproses tugas
/// wajib online.
class ProcurementPayoutDialog extends StatefulWidget {
  final ProcurementPayoutService service;
  final Future<String?> Function(String pin) authorize;
  final Future<String> Function() cashierName;
  final Future<double?> Function() drawerCash;
  final Future<CashMovement?> Function(String movementId) localMovement;
  final Future<String?> Function(CashPayout payout, CashMovement? movement, bool reprint) printProof;

  const ProcurementPayoutDialog({
    super.key,
    required this.service,
    required this.authorize,
    required this.cashierName,
    required this.drawerCash,
    required this.localMovement,
    required this.printProof,
  });

  @override
  State<ProcurementPayoutDialog> createState() => _ProcurementPayoutDialogState();
}

enum _Tone { success, warning, error }

class _ProcurementPayoutDialogState extends State<ProcurementPayoutDialog> {
  List<CashPayout>? _items;
  String? _loadError;
  bool _loading = false;
  double? _drawer;
  final _recordedLocally = <String, bool>{};
  String? _busyId;
  ({String text, _Tone tone})? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final items = await widget.service.fetch();
      final drawer = await widget.drawerCash();
      final recorded = <String, bool>{};
      for (final p in items.where((p) => p.isClaimed && p.movementLocalId.isNotEmpty)) {
        recorded[p.id] = await widget.localMovement(p.movementLocalId) != null;
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _drawer = drawer;
        _recordedLocally
          ..clear()
          ..addAll(recorded);
        _loading = false;
      });
    } on PayoutException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Gagal memuat tugas: $e';
        _loading = false;
      });
    }
  }

  void _say(String text, _Tone tone) {
    if (mounted) setState(() => _notice = (text: text, tone: tone));
  }

  Future<void> _run(CashPayout p, Future<void> Function() action) async {
    setState(() {
      _busyId = p.id;
      _notice = null;
    });
    try {
      await action();
    } on PayoutException catch (e) {
      _say(e.message, _Tone.error);
    } catch (e) {
      _say(e.toString().replaceFirst('Exception: ', ''), _Tone.error);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    await _load();
  }

  Future<void> _handOver(CashPayout p) async {
    final auth = await showPinAuthDialog(
      context,
      title: 'Serahkan Kas Pengadaan',
      actionLabel: 'Serahkan Kas',
      actionColor: AppColors.success,
      icon: Icons.payments_rounded,
      askReason: false,
      details: {
        'Pengajuan': p.requestNumber,
        'Diterima oleh': p.recipientName,
        'Nominal': CurrencyHelper.format(p.amount),
      },
    );
    if (auth == null || !mounted) return;
    final authorizer = await widget.authorize(auth.pin);
    if (authorizer == null) {
      _say('PIN salah atau tidak berwenang (perlu Manager / SVP).', _Tone.error);
      return;
    }
    final cashier = await widget.cashierName();
    await _run(p, () async {
      final result = await widget.service.handOver(p, cashierName: cashier, authorizedBy: authorizer);
      final printError = await widget.printProof(result.payout, result.movement, false);
      final base = result.confirmedOnline
          ? 'Kas ${CurrencyHelper.format(p.amount)} diserahkan ke ${p.recipientName}. '
              'Pengajuan ${p.requestNumber} tercatat dibayar.'
          : result.warning!;
      _say(printError == null ? '$base Bukti penyerahan dicetak.' : '$base $printError',
          result.confirmedOnline && printError == null ? _Tone.success : _Tone.warning);
    });
  }

  Future<void> _return(CashPayout p) async {
    final reason = await _askReason(p);
    if (reason == null || !mounted) return;
    final cashier = await widget.cashierName();
    await _run(p, () async {
      await widget.service.returnToFinance(p, reason: reason, cashierName: cashier);
      _say('Tugas ${p.requestNumber} dikembalikan ke Bagian Keuangan.', _Tone.success);
    });
  }

  Future<String?> _askReason(CashPayout p) {
    final ctrl = TextEditingController();
    return showAppModal<String>(
      context,
      title: 'Kembalikan ke Keuangan',
      icon: Icons.undo_rounded,
      accent: AppColors.warning,
      scrollable: false,
      maxWidth: 460,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${p.requestNumber} · ${CurrencyHelper.format(p.amount)}',
                style: AppType.body.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const Key('payout-return-reason'),
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              maxLength: 500,
              onChanged: (_) => setLocal(() {}),
              decoration: const InputDecoration(
                hintText: 'Contoh: harga di toko berbeda, kas laci tidak cukup',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              key: const Key('payout-return-confirm'),
              label: 'Kembalikan',
              variant: AppButtonVariant.tonal,
              accent: AppColors.warning,
              onPressed: ctrl.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(ctrl.text.trim()),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(CashPayout p) => _run(p, () async {
        await widget.service.confirm(p);
        _say('Penyerahan ${p.requestNumber} terkonfirmasi di cloud.', _Tone.success);
      });

  Future<void> _release(CashPayout p) async {
    final ok = await showAppConfirm(
      context,
      title: 'Batalkan klaim?',
      message: 'Lakukan ini hanya bila uang BELUM diserahkan. Tugas kembali '
          'menunggu dan bisa diproses ulang.',
      confirmText: 'Batalkan klaim',
      icon: Icons.undo_rounded,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(p, () async {
      await widget.service.release(p);
      _say('Klaim ${p.requestNumber} dibatalkan.', _Tone.success);
    });
  }

  Future<void> _reprint(CashPayout p) async {
    final movement = p.movementLocalId.isEmpty ? null : await widget.localMovement(p.movementLocalId);
    final err = await widget.printProof(p, movement, true);
    _say(err ?? 'Bukti penyerahan ${p.requestNumber} dicetak ulang.', err == null ? _Tone.success : _Tone.error);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items ?? const <CashPayout>[];
    final open = items.where((p) => p.isOpen).toList();
    final history = items.where((p) => !p.isOpen).toList();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 620, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const IconBadge(icon: Icons.payments_rounded, color: AppColors.moduleKasir, size: 40),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Bayar Pengadaan', style: AppType.title),
                    Text('Tugas dari Bagian Keuangan · langsung dari cloud', style: AppType.caption),
                  ]),
                ),
                IconButton(
                  key: const Key('payout-refresh'),
                  tooltip: 'Muat ulang',
                  onPressed: _loading || _busyId != null ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: 'Tutup',
                  onPressed: _busyId != null ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: AppColors.textTertiary),
                ),
              ]),
              if (_notice != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _NoticeBox(text: _notice!.text, tone: _notice!.tone),
              ],
              const SizedBox(height: AppSpacing.md),
              if (_loading && _items == null)
                const Padding(padding: EdgeInsets.all(AppSpacing.xl), child: Center(child: CircularProgressIndicator()))
              else if (_loadError != null && _items == null)
                _OfflineBox(message: _loadError!, onRetry: _load)
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (_loadError != null) _NoticeBox(text: _loadError!, tone: _Tone.error),
                      if (open.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: Text('Tidak ada tugas Bayar Pengadaan untuk outlet ini.',
                              textAlign: TextAlign.center,
                              style: AppType.body.copyWith(color: AppColors.textSecondary)),
                        ),
                      for (final p in open) ...[
                        _OpenPayoutCard(
                          payout: p,
                          drawer: _drawer,
                          recordedLocally: _recordedLocally[p.id] ?? false,
                          busy: _busyId == p.id,
                          locked: _busyId != null && _busyId != p.id,
                          onHandOver: () => _handOver(p),
                          onReturn: () => _return(p),
                          onConfirm: () => _confirm(p),
                          onRelease: () => _release(p),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                      if (history.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text('Riwayat 3 hari terakhir', style: AppType.label),
                        const SizedBox(height: AppSpacing.xs),
                        for (final p in history) _HistoryRow(payout: p, onReprint: () => _reprint(p)),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeBox extends StatelessWidget {
  final String text;
  final _Tone tone;
  const _NoticeBox({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _Tone.success => AppColors.success,
      _Tone.warning => AppColors.warning,
      _Tone.error => AppColors.danger,
    };
    return Container(
      key: const Key('payout-notice'),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.soft(color, 0.10),
        border: Border.all(color: AppColors.soft(color, 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: AppType.bodySm.copyWith(fontWeight: FontWeight.w600)),
    );
  }
}

class _OfflineBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _OfflineBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, color: AppColors.warning, size: 40),
          const SizedBox(height: AppSpacing.sm),
          Text(message, key: const Key('payout-offline'), textAlign: TextAlign.center, style: AppType.body),
          const SizedBox(height: AppSpacing.md),
          AppButton(label: 'Coba lagi', icon: Icons.refresh_rounded, expanded: false, onPressed: onRetry),
        ]),
      );
}

class _OpenPayoutCard extends StatelessWidget {
  final CashPayout payout;
  final double? drawer;
  final bool recordedLocally;
  final bool busy;
  final bool locked;
  final VoidCallback onHandOver;
  final VoidCallback onReturn;
  final VoidCallback onConfirm;
  final VoidCallback onRelease;

  const _OpenPayoutCard({
    required this.payout,
    required this.drawer,
    required this.recordedLocally,
    required this.busy,
    required this.locked,
    required this.onHandOver,
    required this.onReturn,
    required this.onConfirm,
    required this.onRelease,
  });

  @override
  Widget build(BuildContext context) {
    final p = payout;
    final short = drawer != null && drawer! < p.amount;
    final disabled = busy || locked;
    return AppCard(
      key: Key('payout-${p.id}'),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.requestNumber, style: AppType.title),
              if (p.itemsSummary.isNotEmpty) Text(p.itemsSummary, style: AppType.caption),
              if (p.vendorName.isNotEmpty) Text('Vendor: ${p.vendorName}', style: AppType.caption),
            ]),
          ),
          Text(CurrencyHelper.format(p.amount),
              style: AppType.h3.copyWith(color: AppColors.moduleKasir, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: AppSpacing.xs),
        Text('Serahkan kepada: ${p.recipientName}', style: AppType.body.copyWith(fontWeight: FontWeight.w600)),
        if (p.notes.isNotEmpty) Text('Catatan: ${p.notes}', style: AppType.caption),
        Text('Ditetapkan ${p.assignedBy.isEmpty ? 'Bagian Keuangan' : p.assignedBy} · ${_when(p.assignedAt)}',
            style: AppType.caption),
        if (p.isPending && short) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Perkiraan kas di laci ${CurrencyHelper.format(drawer!)} — kurang dari nominal. '
            'Tunda atau kembalikan ke Keuangan.',
            key: const Key('payout-drawer-short'),
            style: AppType.caption.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700),
          ),
        ],
        if (p.isClaimed) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            recordedLocally
                ? 'Kas sudah diserahkan & tercatat — menunggu konfirmasi cloud.'
                : 'Penyerahan belum selesai di tablet ini (diklaim ${p.cashierName.isEmpty ? '' : '${p.cashierName} '}${_when(p.claimedAt)}).',
            style: AppType.caption.copyWith(color: AppColors.warning, fontWeight: FontWeight.w700),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        if (busy)
          const Center(child: Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 2.4)))
        else if (p.isPending)
          Row(children: [
            Expanded(
              child: AppButton(
                key: Key('payout-return-${p.id}'),
                label: 'Kembalikan ke Keuangan',
                variant: AppButtonVariant.neutral,
                size: AppButtonSize.medium,
                onPressed: disabled ? null : onReturn,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: AppButton(
                key: Key('payout-handover-${p.id}'),
                label: 'Serahkan Kas',
                icon: Icons.payments_rounded,
                size: AppButtonSize.medium,
                accent: AppColors.success,
                onPressed: disabled ? null : onHandOver,
              ),
            ),
          ])
        else if (recordedLocally)
          AppButton(
            key: Key('payout-confirm-${p.id}'),
            label: 'Konfirmasi ke Cloud',
            icon: Icons.cloud_upload_rounded,
            size: AppButtonSize.medium,
            onPressed: disabled ? null : onConfirm,
          )
        else
          Row(children: [
            Expanded(
              child: AppButton(
                key: Key('payout-release-${p.id}'),
                label: 'Batalkan Klaim',
                variant: AppButtonVariant.neutral,
                size: AppButtonSize.medium,
                onPressed: disabled ? null : onRelease,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: AppButton(
                key: Key('payout-resume-${p.id}'),
                label: 'Lanjutkan Penyerahan',
                size: AppButtonSize.medium,
                accent: AppColors.success,
                onPressed: disabled ? null : onHandOver,
              ),
            ),
          ]),
      ]),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final CashPayout payout;
  final VoidCallback onReprint;
  const _HistoryRow({required this.payout, required this.onReprint});

  @override
  Widget build(BuildContext context) {
    final p = payout;
    final (label, color) = switch (p.status) {
      'paid' => ('Diserahkan ${p.cashierName} · ${_when(p.paidAt)}', AppColors.success),
      'returned' => ('Dikembalikan: ${p.resolutionReason}', AppColors.warning),
      _ => ('Ditarik Bagian Keuangan', AppColors.textTertiary),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p.requestNumber} · ${CurrencyHelper.format(p.amount)} · ${p.recipientName}',
                style: AppType.bodySm, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(label, style: AppType.caption.copyWith(color: color), maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (p.isPaid)
          IconButton(
            key: Key('payout-reprint-${p.id}'),
            tooltip: 'Cetak ulang bukti',
            onPressed: onReprint,
            icon: const Icon(Icons.print_outlined, color: AppColors.moduleKasir),
          ),
      ]),
    );
  }
}
