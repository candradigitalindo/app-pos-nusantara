import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/cashier_controller.dart';
import '../../models/models.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/pin_auth_dialog.dart';
import '../../widgets/ui/ui.dart';
import 'cashier_widgets.dart';

/// Aksi order milik layar Kasir — Diskon, Kompliment, Split Bill, Gabung Bayar,
/// Pindah/Gabung Meja, Tarik dari Titipan, Cetak Tagihan, plus aksi per-item
/// (void / titip / pindah item).
///
/// Dipisah dari `cashier_screen.dart` supaya layar LAIN bisa memakai aksi yang
/// SAMA PERSIS — saat ini layar Transaksi untuk transaksi yang belum dibayar.
/// Semua dialog di sini bekerja pada [actionsController]; layar pemakai wajib
/// memastikan controller-nya sudah memilih order yang dimaksud
/// (`selectTable`), karena aksi membaca `state.currentOrder`/`state.orderItems`.
mixin CashierOrderActions<T extends StatefulWidget> on State<T> {
  /// Controller order yang dikenai aksi.
  CashierController get actionsController;

  CashierController get _controller => actionsController;

  // ── API publik (dipakai layar Kasir & Transaksi) ─────────────────────────
  void showDiscountDialog() => _showDiscountDialog();
  void showComplimentDialog() => _showComplimentDialog();
  Future<void> showSplitBillDialog() async {
    final guard = paymentGuard;
    if (guard != null && !await guard()) return;
    if (mounted) _showSplitBillDialog();
  }

  Future<void> showMixedPaymentDialog() async {
    final guard = paymentGuard;
    if (guard != null && !await guard()) return;
    if (mounted) _showMixedPaymentDialog();
  }

  void showMovePicker() => _showMovePicker();
  void showMergePicker() => _showMergePicker();
  Future<void> showHeldItemsPicker() => _showHeldItemsPicker();
  Future<void> printBillAction() => _printBill();
  Future<void> showItemDeleteOptions(OrderItem item) =>
      _showItemDeleteOptions(item);
  Future<int?> askUnitQty(int maxQty, {String title = 'Berapa unit?'}) =>
      _askUnitQty(maxQty, title: title);

  /// Bila diisi, dipanggil SEBELUM aksi yang mencatat pembayaran (Split Bill /
  /// Gabung Bayar). Kembalikan false untuk membatalkan. Dipakai layar Transaksi
  /// yang mewajibkan otorisasi PIN karena pembayaran dilakukan di luar kasir.
  Future<bool> Function()? get paymentGuard => null;

  /// Aksi sekunder terbuka/tertutup (toggle "Aksi Lainnya"). Selalu mulai
  /// tertutup supaya tombol aksi tidak "nongol" begitu saja.
  bool _moreActions = false;

  /// Buka/tutup panel aksi. Tidak memanggil setState — pemanggilnya yang
  /// menentukan bagian mana yang di-rebuild.
  void toggleOrderActions() => _moreActions = !_moreActions;

  /// Tutup panel aksi (mis. saat pengguna memilih transaksi lain).
  void resetOrderActions() => _moreActions = false;


  void _showSplitBillDialog() {
    if (_controller.state.currentOrder == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _SplitBillDialog(controller: _controller),
    );
  }

  void _showComplimentDialog() {
    final order = _controller.state.currentOrder;
    if (order == null) return;
    final items = _controller.state.orderItems;
    final pinCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();
    String? pinError;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          return _actionDialogShell(
            ctx: ctx,
            accent: AppColors.moduleWaiter,
            accentBg: AppColors.warningSoft,
            icon: Icons.card_giftcard,
            title: 'Kompliment',
            subtitle: 'Gratiskan seluruh tagihan order ini',
            children: [
              _orderSummaryCard(
                order: order,
                items: items,
                accent: AppColors.moduleWaiter,
                accentBg: AppColors.warningSoft,
                accentBorder: AppColors.soft(AppColors.warning, 0.35),
              ),
              const SizedBox(height: 16),
              // Banner total → gratis
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.warningSoft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.soft(AppColors.warning, 0.35)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Total dibayar',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.moduleWaiter)),
                    Row(
                      children: [
                        Text(CurrencyHelper.format(order.totalAmount),
                            style: const TextStyle(
                                fontSize: 14,
                                color: AppColors.moduleWaiter,
                                decoration: TextDecoration.lineThrough)),
                        const SizedBox(width: 10),
                        const Text('GRATIS',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: AppColors.moduleWaiter)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: pinCtrl,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'PIN Manager/SVP *',
                  hintText: 'Otorisasi kompliment',
                  prefixIcon: const Icon(Icons.lock_outline, size: 20),
                  border: const OutlineInputBorder(),
                  errorText: pinError,
                ),
                onChanged: (_) {
                  if (pinError != null) setS(() => pinError = null);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                textInputAction: TextInputAction.done,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Alasan (opsional)',
                  hintText: 'Contoh: tamu VIP, kompensasi keluhan',
                  prefixIcon: Icon(Icons.notes_outlined, size: 20),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            primaryLabel: 'Gratiskan',
            primaryIcon: Icons.card_giftcard,
            onPrimary: () async {
              final pin = pinCtrl.text.trim();
              if (pin.isEmpty) {
                setS(() => pinError = 'Wajib diisi');
                return;
              }
              // Otorisasi sama dengan void: PIN void bersama atau PIN user
              // ber-role admin/manager/svp. Nama pemberi = pemilik PIN, bukan
              // teks bebas — jejak kompliment jadi akuntabel.
              final by = await _controller.complimentAuthorizer(pin);
              if (by == null) {
                setS(() =>
                    pinError = 'PIN salah / tidak berwenang (Manager/SVP)');
                return;
              }
              final ok = await _controller.complimentCurrentOrder(
                complimentBy: by,
                reason: reasonCtrl.text.trim(),
              );
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (!mounted) return;
              if (ok) {
                showAppSnack(
                    context,
                    'Meja ${order.tableNumber} digratiskan (kompliment oleh $by)',
                    icon: Icons.card_giftcard);
              }
            },
          );
        },
      ),
    );
  }

  /// Kerangka dialog aksi yang lebih besar & konsisten (header berwarna,
  /// konten scrollable, tombol aksi lebar di bawah).
  Widget _actionDialogShell({
    required BuildContext ctx,
    required Color accent,
    required Color accentBg,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
    required String primaryLabel,
    required IconData primaryIcon,
    required Future<void> Function() onPrimary,
  }) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.of(ctx).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
              decoration: BoxDecoration(
                color: accentBg,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: AppRadius.rSm,
                    ),
                    child: Icon(icon, color: accent, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: AppType.h3.copyWith(color: accent)),
                        const SizedBox(height: 2),
                        Text(subtitle,
                            style: AppType.caption
                                .copyWith(color: accent.withValues(alpha: 0.75))),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: Icon(Icons.close, color: accent.withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
            // Body
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ),
            // Actions
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: Row(
                children: [
                  Expanded(
                    child: AppButton.neutral('Batal',
                        onPressed: () => Navigator.pop(ctx)),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: AppButton(
                      label: primaryLabel,
                      icon: primaryIcon,
                      accent: accent,
                      onPressed: onPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Kartu ringkasan order: meja, jumlah item, daftar item ringkas, subtotal.
  Widget _orderSummaryCard({
    required Order order,
    required List<OrderItem> items,
    required Color accent,
    required Color accentBg,
    required Color accentBorder,
  }) {
    final subtotal = items.fold<double>(0, (s, i) => s + i.subtotal);
    final itemCount = items.fold<int>(0, (s, i) => s + i.qty);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: accentBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Meja ${order.tableNumber}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              Text('$itemCount item',
                  style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w500)),
              if (order.customerName != null &&
                  order.customerName!.isNotEmpty) ...[
                const Text(' • ',
                    style: TextStyle(color: AppColors.textTertiary)),
                Flexible(
                  child: Text(order.customerName!,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textSecondary)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          // Daftar item ringkas (maks 4 baris, sisanya "+n lainnya")
          ...items.take(4).map((it) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Text('${it.qty}×',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textSecondary)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(it.productName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ),
                    Text(CurrencyHelper.format(it.subtotal),
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ),
              )),
          if (items.length > 4)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('+${items.length - 4} item lainnya',
                  style: const TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: AppColors.textTertiary)),
            ),
          const Divider(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Subtotal',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
              Text(CurrencyHelper.format(subtotal),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  /// Dialog diskon: pilih persen/rupiah, isi nilai, lihat pratinjau total baru.
  void _showDiscountDialog() {
    final order = _controller.state.currentOrder;
    if (order == null) return;
    final items = _controller.state.orderItems;
    final valueCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var isPercent = true;
    String? errorText;

    // Subtotal item (sebelum charge) untuk menghitung pratinjau diskon.
    final subtotal = items.fold<double>(0, (s, i) => s + i.subtotal);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final raw = valueCtrl.text.replaceAll(RegExp(r'[^\d]'), '');
          final v = double.tryParse(raw) ?? 0;
          double discount = isPercent ? subtotal * v / 100 : v;
          discount = discount.roundToDouble();
          if (discount > subtotal) discount = subtotal;
          final newTotal = (subtotal - discount).clamp(0, subtotal).toDouble();

          void applyPercent(int p) {
            setS(() {
              isPercent = true;
              errorText = null;
              valueCtrl.text = '$p';
            });
          }

          return _actionDialogShell(
            ctx: ctx,
            accent: AppColors.moduleProduk,
            accentBg: AppColors.soft(AppColors.moduleProduk, 0.15),
            icon: Icons.local_offer_outlined,
            title: 'Diskon',
            subtitle: 'Potong harga sebelum pembayaran',
            children: [
              _orderSummaryCard(
                order: order,
                items: items,
                accent: AppColors.moduleProduk,
                accentBg: AppColors.soft(AppColors.moduleProduk, 0.10),
                accentBorder: AppColors.soft(AppColors.moduleProduk, 0.30),
              ),
              const SizedBox(height: 16),
              // Toggle tipe
              Row(
                children: [
                  Expanded(
                    child: _discountTypeChip('Persen (%)', isPercent, () {
                      setS(() {
                        isPercent = true;
                        errorText = null;
                        valueCtrl.clear();
                      });
                    }),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _discountTypeChip('Rupiah (Rp)', !isPercent, () {
                      setS(() {
                        isPercent = false;
                        errorText = null;
                        valueCtrl.clear();
                      });
                    }),
                  ),
                ],
              ),
              // Preset cepat (hanya untuk persen)
              if (isPercent) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [5, 10, 15, 20, 25, 50]
                      .map((p) => _presetChip('$p%', () => applyPercent(p)))
                      .toList(),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: valueCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: isPercent ? null : [RupiahInputFormatter()],
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: isPercent ? 'Persentase' : 'Nominal',
                  prefixText: isPercent ? null : 'Rp ',
                  suffixText: isPercent ? '%' : null,
                  hintText: isPercent ? 'mis. 10' : '0',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
                onChanged: (_) => setS(() => errorText = null),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Catatan diskon (opsional)',
                  hintText: 'Contoh: member, promo, karyawan',
                  prefixIcon: Icon(Icons.label_outline, size: 20),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              // Pratinjau
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    _discountPreviewRow(
                        'Subtotal', CurrencyHelper.format(subtotal)),
                    const SizedBox(height: 6),
                    _discountPreviewRow(
                      isPercent && v > 0 ? 'Diskon (${v.toStringAsFixed(0)}%)' : 'Diskon',
                      '- ${CurrencyHelper.format(discount)}',
                      color: AppColors.danger,
                    ),
                    const Divider(height: 18),
                    _discountPreviewRow(
                      'Total Baru',
                      CurrencyHelper.format(newTotal),
                      bold: true,
                      color: AppColors.moduleKasir,
                    ),
                  ],
                ),
              ),
            ],
            primaryLabel: 'Terapkan',
            primaryIcon: Icons.check,
            onPrimary: () async {
              if (v <= 0) {
                setS(() => errorText = 'Nilai diskon harus lebih dari 0');
                return;
              }
              if (isPercent && v > 100) {
                setS(() => errorText = 'Persentase tidak boleh > 100');
                return;
              }
              final ok = await _controller.applyDiscountToCurrentOrder(
                chargeType: isPercent ? 'percentage' : 'fixed',
                value: v,
                note: noteCtrl.text.trim(),
              );
              if (!ctx.mounted) return;
              if (ok) {
                Navigator.pop(ctx);
                if (!mounted) return;
                showAppSnack(context,
                    'Diskon ${CurrencyHelper.format(discount)} diterapkan',
                    icon: Icons.local_offer_outlined);
              } else {
                setS(() => errorText = _controller.state.errorMessage ??
                    'Gagal menerapkan diskon');
              }
            },
          );
        },
      ),
    );
  }

  Widget _presetChip(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.soft(AppColors.moduleProduk, 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.soft(AppColors.moduleProduk, 0.30)),
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.moduleProduk)),
      ),
    );
  }

  Widget _discountTypeChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          color: selected ? AppColors.moduleProduk : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.textSecondary,
            )),
      ),
    );
  }

  Widget _discountPreviewRow(String label, String value,
      {bool bold = false, Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        Text(value,
            style: TextStyle(
                fontSize: bold ? 16 : 13,
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: color ?? AppColors.textPrimary)),
      ],
    );
  }

  Future<void> _showItemVoidDialog(OrderItem item) async {
    final n = await _askUnitQty(item.qty, title: 'Void berapa unit?');
    if (n == null || !mounted) return;
    final auth = await showPinAuthDialog(
      context,
      title: 'Hapus Item',
      actionLabel: 'Hapus Item',
      icon: Icons.delete_outline,
      details: {
        'Item': '${n}x ${item.productName}',
        'Harga': CurrencyHelper.format(item.price * n),
        if (item.waiterName.isNotEmpty) 'Pemesan': item.waiterName,
      },
      reasonHint: 'Contoh: salah input, pelanggan batal',
    );
    if (auth == null || !mounted) return;
    final res = await _controller.voidOrderItem(
      itemId: item.id,
      pin: auth.pin,
      reason: auth.reason,
      qty: n,
    );
    if (!mounted) return;
    final msg = res == 'ok'
        ? 'Item dihapus'
        : res == 'invalid_pin'
            ? 'PIN salah / tidak berwenang'
            : (_controller.state.errorMessage ?? 'Gagal hapus item');
    showAppSnack(context, msg, isError: res != 'ok');
  }

  /// Aksi hapus item → pilihan: Pindah ke meja lain (transfer) atau Void (hapus).
  /// Tampilkan modal di TENGAH layar (dialog), bukan meluncur dari bawah.
  /// Konten [builder] sama seperti bottom-sheet; hanya posisinya dipusatkan.
  Future<R?> _centeredModal<R>(
      {required Widget Function(BuildContext) builder}) {
    return showDialog<R>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surface,
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 460,
            maxHeight: MediaQuery.of(ctx).size.height * 0.82,
          ),
          child: builder(ctx),
        ),
      ),
    );
  }

  /// Tanya jumlah unit (1..[maxQty]). null = batal. Bila maxQty ≤ 1, langsung
  /// kembalikan 1 tanpa dialog (baris qty 1 tak perlu ditanya).
  Future<int?> _askUnitQty(int maxQty, {String title = 'Berapa unit?'}) async {
    if (maxQty <= 1) return 1;
    int qty = maxQty; // default: seluruh baris
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(title, style: const TextStyle(fontSize: 16)),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 36,
                color: AppColors.moduleKasir,
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: qty > 1 ? () => setD(() => qty--) : null,
              ),
              SizedBox(
                width: 64,
                child: Text('$qty',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 30, fontWeight: FontWeight.bold)),
              ),
              IconButton(
                iconSize: 36,
                color: AppColors.moduleKasir,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: qty < maxQty ? () => setD(() => qty++) : null,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, qty),
                child: Text('Pilih $qty dari $maxQty')),
          ],
        ),
      ),
    );
  }

  Future<void> _showItemDeleteOptions(OrderItem item) async {
    final choice = await _centeredModal<String>(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('${item.qty}x ${item.productName}',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                Text(CurrencyHelper.format(item.subtotal),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.moduleKasir)),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          ListTile(
            leading: const Icon(Icons.swap_horiz_rounded,
                color: AppColors.moduleKasir),
            title: const Text('Pindah ke meja lain'),
            subtitle: const Text(
                'Item pindah ke order meja aktif lain (tanpa cetak ulang)'),
            onTap: () => Navigator.pop(ctx, 'move'),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined,
                color: AppColors.accent),
            title: const Text('Titip ke Meja Titipan'),
            subtitle: const Text(
                'Simpan untuk tamu berikutnya — perlu PIN manajer'),
            onTap: () => Navigator.pop(ctx, 'titip'),
          ),
          ListTile(
            leading:
                const Icon(Icons.delete_outline, color: AppColors.danger),
            title: const Text('Void item (hapus)'),
            subtitle: const Text('Batalkan item — perlu PIN manajer'),
            onTap: () => Navigator.pop(ctx, 'void'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'void') {
      await _showItemVoidDialog(item);
    } else if (choice == 'move') {
      await _showItemMovePicker(item);
    } else if (choice == 'titip') {
      await _titipItem(item);
    }
  }

  /// Titip item ke Meja Titipan: peringatan keamanan pangan → PIN manajer → park.
  Future<void> _titipItem(OrderItem item) async {
    final n = await _askUnitQty(item.qty, title: 'Titip berapa unit?');
    if (n == null || !mounted) return;
    final proceed = await showAppConfirm(
      context,
      title: 'Titip ke Meja Titipan?',
      message: '${n}x ${item.productName} disimpan untuk dijual ke '
          'tamu berikutnya.\n\n'
          '⚠️ Pastikan item MASIH LAYAK & AMAN dikonsumsi. Untuk makanan '
          'matang/minuman terbuka yang sudah lama, sebaiknya Void (waste), '
          'bukan dititip.',
      confirmText: 'Lanjut Titip',
      icon: Icons.inventory_2_outlined,
    );
    if (proceed != true || !mounted) return;

    final auth = await showPinAuthDialog(
      context,
      title: 'Titip Item',
      actionLabel: 'Titip Item',
      icon: Icons.inventory_2_outlined,
      details: {
        'Item': '${n}x ${item.productName}',
        'Harga': CurrencyHelper.format(item.price * n),
      },
      reasonHint: 'Contoh: tamu batal, salah antar',
    );
    if (auth == null || !mounted) return;
    final res =
        await _controller.parkItem(itemId: item.id, pin: auth.pin, qty: n);
    if (!mounted) return;
    final msg = res == 'ok'
        ? 'Item dititip ke Meja Titipan'
        : res == 'invalid_pin'
            ? 'PIN salah / tidak berwenang'
            : (_controller.state.errorMessage ?? 'Gagal titip item');
    showAppSnack(context, msg, isError: res != 'ok');
  }

  /// Meja Titipan: ketuk item → tarik ke pesanan saat ini; atau Void (waste)
  /// item yang sudah tak layak. Menampilkan usia titip (item lama ditandai).
  Future<void> _showHeldItemsPicker() async {
    if (_controller.state.currentOrder == null) {
      showAppSnack(context, 'Buka order/meja dulu untuk menarik titipan',
          isError: true);
      return;
    }
    var held = await _controller.getHeldItems();
    if (!mounted) return;
    if (held.isEmpty) {
      showAppSnack(context, 'Tidak ada item di Meja Titipan');
      return;
    }

    String ageStr(DateTime t) {
      final d = DateTime.now().difference(t);
      if (d.inHours >= 1) return '${d.inHours}j ${d.inMinutes % 60}m';
      if (d.inMinutes >= 1) return '${d.inMinutes} menit';
      return 'baru saja';
    }

    await _centeredModal<void>(
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Future<void> reload() async {
            final fresh = await _controller.getHeldItems();
            if (ctx.mounted) setSheet(() => held = fresh);
          }

          return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text('Meja Titipan',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(
                        'Ketuk untuk tarik ke pesanan. Item lama bisa di-Void (waste).',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textTertiary)),
                  ),
                  const Divider(height: 1, color: AppColors.border),
                  if (held.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(
                        child: Text('Titipan kosong',
                            style:
                                TextStyle(color: AppColors.textTertiary)),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: held.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final it = held[i];
                          final stale = DateTime.now()
                                  .difference(it.updatedAt)
                                  .inHours >=
                              4;
                          return Material(
                            color: AppColors.surfaceMuted,
                            borderRadius: BorderRadius.circular(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
                                      final n = await _askUnitQty(it.qty,
                                          title: 'Tarik berapa unit?');
                                      if (n == null || !mounted) return;
                                      final res = await _controller
                                          .pullHeldItem(it.id, qty: n);
                                      if (!mounted) return;
                                      showAppSnack(
                                        context,
                                        res == 'ok'
                                            ? 'Titipan ditarik ke pesanan'
                                            : (_controller
                                                    .state.errorMessage ??
                                                'Gagal tarik titipan'),
                                        isError: res != 'ok',
                                      );
                                      if (res == 'ok') await reload();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          12, 10, 4, 10),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text('${it.qty}x ${it.productName}',
                                              style: const TextStyle(
                                                  fontWeight:
                                                      FontWeight.w600)),
                                          const SizedBox(height: 3),
                                          Row(children: [
                                            Icon(
                                                stale
                                                    ? Icons
                                                        .warning_amber_rounded
                                                    : Icons.schedule_rounded,
                                                size: 12,
                                                color: stale
                                                    ? AppColors.warning
                                                    : AppColors.textTertiary),
                                            const SizedBox(width: 4),
                                            Text(
                                                'dititip ${ageStr(it.updatedAt)} lalu',
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: stale
                                                        ? AppColors.warning
                                                        : AppColors
                                                            .textTertiary)),
                                            const SizedBox(width: 8),
                                            Text(
                                                CurrencyHelper.format(
                                                    it.subtotal),
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                    color: AppColors
                                                        .moduleKasir)),
                                          ]),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Void (waste)',
                                  icon: const Icon(Icons.delete_outline,
                                      color: AppColors.danger),
                                  onPressed: () async {
                                    final n = await _askUnitQty(it.qty,
                                        title: 'Void berapa unit?');
                                    if (n == null || !mounted) return;
                                    final auth = await showPinAuthDialog(
                                      context,
                                      title: 'Void Titipan',
                                      actionLabel: 'Void (Waste)',
                                      icon: Icons.delete_outline,
                                      details: {
                                        'Item': '${n}x ${it.productName}',
                                        'Harga': CurrencyHelper.format(
                                            it.price * n),
                                      },
                                      reasonHint:
                                          'Contoh: sudah tidak layak, kadaluarsa',
                                    );
                                    if (auth == null || !mounted) return;
                                    final res = await _controller.voidHeldItem(
                                        itemId: it.id,
                                        pin: auth.pin,
                                        reason: auth.reason,
                                        qty: n);
                                    if (!mounted) return;
                                    showAppSnack(
                                        context,
                                        res == 'ok'
                                            ? 'Titipan di-void (waste)'
                                            : res == 'invalid_pin'
                                                ? 'PIN salah / tidak berwenang'
                                                : 'Gagal void titipan',
                                        isError: res != 'ok');
                                    if (res == 'ok') await reload();
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              );
        },
      ),
    );
  }

  /// Pindahkan satu item ke order aktif di meja lain (Fase 1).
  Future<void> _showItemMovePicker(OrderItem item) async {
    final order = _controller.state.currentOrder;
    if (order == null) return;
    final n = await _askUnitQty(item.qty, title: 'Pindah berapa unit?');
    if (n == null || !mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => _MergePicker(
        getOrders: _controller.getMoveTargets,
        targetTable: order.tableNumber,
        title: 'Pindah item ke Meja:',
        headerIcon: Icons.swap_horiz_rounded,
        onPick: (dest) async {
          Navigator.pop(ctx);
          final res = await _controller.moveItemToTable(
            itemId: item.id,
            targetOrderId: dest.id,
            qty: n,
          );
          if (!mounted) return;
          showAppSnack(
            context,
            res == 'ok'
                ? 'Item dipindah ke Meja ${dest.tableNumber}'
                : (_controller.state.errorMessage ?? 'Gagal pindah item'),
            isError: res != 'ok',
          );
        },
      ),
    );
  }

  void _showMovePicker() {
    final order = _controller.state.currentOrder;
    if (order == null) return;
    final available = _controller.state.tables
        .where((t) => t.status == 'available')
        .toList();
    _centeredModal<void>(
      builder: (ctx) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pindah dari Meja ${order.tableNumber} ke:',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                if (available.isEmpty)
                  const Text('Tidak ada meja kosong',
                      style: TextStyle(color: AppColors.textTertiary))
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: available
                      .map((t) => Material(
                            color: AppColors.surfaceMuted,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () async {
                                Navigator.pop(ctx);
                                final ok = await _controller
                                    .moveOrderToTable(t.tableNumber);
                                if (!mounted) return;
                                showAppSnack(
                                    context,
                                    ok
                                        ? 'Pindah ke Meja ${t.tableNumber}'
                                        : _controller.state.errorMessage ??
                                            'Gagal pindah',
                                    isError: !ok);
                              },
                              child: Container(
                                width: 72,
                                height: 56,
                                alignment: Alignment.center,
                                child: Text(t.tableNumber,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ))
                            .toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
    );
  }

  // ── Gabung Meja ───────────────────────────────────────────────────────────
  void _showMergePicker() {
    final order = _controller.state.currentOrder;
    if (order == null) return;
    showDialog(
      context: context,
      builder: (ctx) => _MergePicker(
        getOrders: _controller.getMergeableOrders,
        targetTable: order.tableNumber,
        onPick: (src) async {
          Navigator.pop(ctx);
          final ok = await _controller.mergeTable(src.id);
          if (!mounted) return;
          showAppSnack(
              context,
              ok
                  ? 'Meja ${src.tableNumber} digabung ke ${order.tableNumber}'
                  : _controller.state.errorMessage ?? 'Gagal gabung',
              isError: !ok);
        },
      ),
    );
  }

  // ── Gabung Pembayaran (campur metode) ─────────────────────────────────────
  void _showMixedPaymentDialog() {
    if (_controller.state.currentOrder == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _MixedPaymentDialog(controller: _controller),
    );
  }

  Future<void> _printBill() async {
    final ok = await _controller.printCurrentBill();
    if (!mounted) return;
    showAppSnack(context, ok ? 'Tagihan dicetak' : 'Tidak ada order aktif',
        isError: !ok, icon: ok ? Icons.receipt_long_outlined : null);
  }

  /// Panel "Aksi Lainnya" — dipakai layar Kasir DAN Transaksi, jadi daftar,
  /// urutan, dan gaya tombolnya selalu sama.
  /// Panel selalu MULAI tertutup: tombol aksi baru terlihat setelah
  /// "Aksi Lainnya" diketuk.
  ///
  /// [expanded] true → langsung tampilkan tombolnya tanpa toggle.
  /// [onToggle] dipakai bila panel dirender di dalam modal/bottom-sheet: modal
  /// punya subtree sendiri yang tak ikut rebuild saat state layar berubah, jadi
  /// pemanggil menyediakan cara rebuild-nya sendiri (mis. `setState` milik
  /// [StatefulBuilder]).
  Widget buildOrderActionsPanel(bool isLoading,
      {bool expanded = false, VoidCallback? onToggle}) {
    if (expanded) return _buildSecondaryActions(isLoading);
    return Column(
      children: [
        Material(
          color: AppColors.soft(AppColors.accent, 0.10),
          borderRadius: AppRadius.rMd,
          child: InkWell(
            borderRadius: AppRadius.rMd,
            onTap: onToggle ?? () => setState(toggleOrderActions),
            child: Container(
              height: 44,
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                      _moreActions
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: AppColors.accentDark),
                  const SizedBox(width: 6),
                  Text(_moreActions ? 'Sembunyikan aksi' : 'Aksi Lainnya',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accentDark)),
                ],
              ),
            ),
          ),
        ),
        if (_moreActions) ...[
          const SizedBox(height: 8),
          _buildSecondaryActions(isLoading),
        ],
      ],
    );
  }

  /// Aksi sekunder pada order aktif (Diskon, Kompliment, Split, dll) — gold tonal.
  Widget _buildSecondaryActions(bool isLoading) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _secondaryButton(
                icon: Icons.local_offer_outlined,
                label: 'Diskon',
                color: AppColors.moduleProduk,
                borderColor: AppColors.soft(AppColors.moduleProduk, 0.40),
                onTap: isLoading ? null : showDiscountDialog,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _secondaryButton(
                icon: Icons.card_giftcard,
                label: 'Kompliment',
                color: AppColors.moduleWaiter,
                borderColor: AppColors.warning,
                onTap: isLoading ? null : showComplimentDialog,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _secondaryButton(
                icon: Icons.call_split,
                label: 'Split Bill',
                color: AppColors.moduleProduk,
                borderColor: AppColors.soft(AppColors.moduleProduk, 0.40),
                onTap: isLoading ? null : showSplitBillDialog,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _secondaryButton(
                icon: Icons.payments_outlined,
                label: 'Gabung Bayar',
                color: AppColors.moduleMeja,
                borderColor: AppColors.soft(AppColors.moduleMeja, 0.35),
                onTap: isLoading ? null : showMixedPaymentDialog,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _secondaryButton(
                icon: Icons.swap_horiz,
                label: 'Pindah Meja',
                color: AppColors.info,
                borderColor: AppColors.soft(AppColors.info, 0.40),
                onTap: isLoading ? null : showMovePicker,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _secondaryButton(
                icon: Icons.merge_type,
                label: 'Gabung Meja',
                color: AppColors.info,
                borderColor: AppColors.soft(AppColors.info, 0.40),
                onTap: isLoading ? null : showMergePicker,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: _secondaryButton(
            icon: Icons.inventory_2_outlined,
            label: 'Tarik dari Titipan',
            color: AppColors.accent,
            borderColor: AppColors.soft(AppColors.accent, 0.40),
            onTap: isLoading ? null : showHeldItemsPicker,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: _secondaryButton(
            icon: Icons.receipt_long_outlined,
            label: 'Cetak Tagihan',
            color: AppColors.moduleKasir,
            borderColor: AppColors.soft(AppColors.moduleKasir, 0.40),
            onTap: isLoading ? null : printBillAction,
          ),
        ),
      ],
    );
  }

  // ── Pindah Meja ───────────────────────────────────────────────────────────
  /// Hapus (void) satu item — wajib PIN Manager/SVP (atau PIN void bersama).
  Widget _secondaryButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color borderColor,
    required VoidCallback? onTap,
  }) =>
      CashierSecondaryButton(icon: icon, label: label, onTap: onTap);
}

class _SplitBillDialog extends StatefulWidget {
  final CashierController controller;
  const _SplitBillDialog({required this.controller});

  @override
  State<_SplitBillDialog> createState() => _SplitBillDialogState();
}

class _SplitBillDialogState extends State<_SplitBillDialog> {
  final _paidQty = <String, int>{}; // unit sudah dibayar per item (sesi ini)
  final _selQty = <String, int>{}; // unit dipilih untuk bagian saat ini
  String _method = 'cash';
  int _payer = 1;

  CashierController get _c => widget.controller;

  List<OrderItem> get _items => _c.state.orderItems;

  int _paidOf(String id) => _paidQty[id] ?? 0;
  int _selOf(String id) => _selQty[id] ?? 0;
  int _availOf(OrderItem i) => i.qty - _paidOf(i.id);

  bool get _hasSelection => _selQty.values.any((q) => q > 0);

  /// Semua sisa unit (dari item yang belum lunas) tercentang → bagian terakhir
  /// (bayar sisa persis, hindari selisih pembulatan).
  bool get _isFinalSelection {
    var anyAvail = false;
    for (final i in _items) {
      final avail = _availOf(i);
      if (avail <= 0) continue;
      anyAvail = true;
      if (_selOf(i.id) != avail) return false;
    }
    return anyAvail;
  }

  void _setQty(String id, int q, int max) {
    final v = q.clamp(0, max);
    setState(() {
      if (v == 0) {
        _selQty.remove(id);
      } else {
        _selQty[id] = v;
      }
    });
  }

  Future<void> _payPart() async {
    if (!_hasSelection) return;
    final res = await _c.paySplitByQty(
      qtyByItem: Map<String, int>.from(_selQty),
      method: _method,
      isFinal: _isFinalSelection,
    );
    if (res == null) {
      if (mounted && _c.state.errorMessage != null) {
        showAppSnack(context, _c.state.errorMessage!, isError: true);
      }
      return;
    }
    if (!mounted) return;
    if (res['payment_status'] == 'paid') {
      Navigator.pop(context);
      showAppSnack(context, 'Split bill selesai — semua bagian lunas');
      return;
    }
    setState(() {
      _selQty.forEach((id, q) => _paidQty[id] = _paidOf(id) + q);
      _selQty.clear();
      _payer++;
    });
  }

  /// Baris item dengan stepper jumlah unit (0..sisa). Item lunas dikunci.
  Widget _splitItemRow(OrderItem it) {
    final total = it.qty;
    final paid = _paidOf(it.id);
    final avail = total - paid;
    final sel = _selOf(it.id);
    final done = avail <= 0;
    return Opacity(
      opacity: done ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.productName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        decoration: done ? TextDecoration.lineThrough : null,
                      )),
                  Text(
                    done
                        ? 'LUNAS · ${total}x'
                        : '${CurrencyHelper.format(it.price)} / unit · sisa $avail dari ${total}x',
                    style: TextStyle(
                      fontSize: 11,
                      color: done
                          ? AppColors.moduleKasir
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (!done)
              Row(
                children: [
                  _qtyBtn(Icons.remove, sel > 0,
                      () => _setQty(it.id, sel - 1, avail)),
                  Container(
                    width: 34,
                    alignment: Alignment.center,
                    child: Text('$sel',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  _qtyBtn(Icons.add, sel < avail,
                      () => _setQty(it.id, sel + 1, avail)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _qtyBtn(IconData icon, bool enabled, VoidCallback onTap) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: enabled ? AppColors.soft(AppColors.moduleProduk, 0.10) : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 18,
            color: enabled ? AppColors.moduleProduk : AppColors.textTertiary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final share = _c.splitShareForQty(_selQty);
    final order = _c.state.currentOrder;
    final remaining = order?.remaining ?? 0;
    final allSelected = _isFinalSelection;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              decoration: BoxDecoration(
                color: AppColors.soft(AppColors.moduleProduk, 0.10),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.call_split, color: AppColors.moduleProduk),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Split Bill',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppColors.moduleProduk)),
                        Text('Bagian ke-$_payer • sisa tagihan ${CurrencyHelper.format(remaining)}',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.moduleProduk)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.moduleProduk),
                  ),
                ],
              ),
            ),
            // Items
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: Text(
                        'Pilih jumlah unit untuk pembayar bagian ini:',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ),
                  ..._items.map(_splitItemRow),
                ],
              ),
            ),
            const Divider(height: 1),
            // Method + amount + pay
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      _mChip('cash', 'Tunai', Icons.money),
                      _mChip('card', 'Kartu', Icons.credit_card),
                      _mChip('qris', 'QRIS', Icons.qr_code),
                      _mChip('transfer', 'Transfer', Icons.account_balance),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(allSelected ? 'Bayar sisa (bagian akhir)' : 'Bagian ini',
                          style: const TextStyle(
                              fontSize: 14, color: AppColors.textSecondary)),
                      Text(
                        CurrencyHelper.format(allSelected ? remaining : share),
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.moduleProduk),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AppButton(
                    label: 'Bayar Bagian Ini',
                    icon: Icons.payments_outlined,
                    accent: AppColors.moduleProduk,
                    loading: _c.state.isProcessing,
                    size: AppButtonSize.medium,
                    onPressed: (!_hasSelection || _c.state.isProcessing)
                        ? null
                        : _payPart,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mChip(String value, String label, IconData icon) {
    final selected = _method == value;
    return GestureDetector(
      onTap: () => setState(() => _method = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.moduleProduk : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? Colors.white : AppColors.textSecondary),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.textSecondary,
                )),
          ],
        ),
      ),
    );
  }
}

// ── Pilih Meja: dialog tengah, besar, scroll, dengan pencarian ────────────────
// ── Gabung Meja: pilih order meja lain ────────────────────────────────────────
class _MergePicker extends StatefulWidget {
  final Future<List<Order>> Function() getOrders;
  final String targetTable;
  final void Function(Order) onPick;
  final String? title; // null → judul default "Gabung ke Meja X"
  final IconData headerIcon;
  const _MergePicker(
      {required this.getOrders,
      required this.targetTable,
      required this.onPick,
      this.title,
      this.headerIcon = Icons.merge_type});

  @override
  State<_MergePicker> createState() => _MergePickerState();
}

class _MergePickerState extends State<_MergePicker> {
  List<Order>? _orders;

  @override
  void initState() {
    super.initState();
    widget.getOrders().then((o) {
      if (mounted) setState(() => _orders = o);
    });
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: 480, maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Icon(widget.headerIcon, color: AppColors.info),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        widget.title ?? 'Gabung ke Meja ${widget.targetTable}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (orders == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(color: AppColors.info),
              )
            else if (orders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Text('Tidak ada meja lain dengan pesanan aktif',
                    style: TextStyle(color: AppColors.textTertiary)),
              )
            else
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: orders.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final o = orders[i];
                    return Material(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => widget.onPick(o),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: AppColors.soft(AppColors.info, 0.14),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                alignment: Alignment.center,
                                child: Text(o.tableNumber,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                        color: AppColors.info)),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Meja ${o.tableNumber}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14)),
                                    Text('${o.basketSize} item',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: AppColors.textTertiary)),
                                  ],
                                ),
                              ),
                              Text(CurrencyHelper.format(o.totalAmount),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14)),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Gabung Pembayaran: bayar campur metode (cash + qris dll) ──────────────────
class _MixedPaymentDialog extends StatefulWidget {
  final CashierController controller;
  const _MixedPaymentDialog({required this.controller});

  @override
  State<_MixedPaymentDialog> createState() => _MixedPaymentDialogState();
}

class _MixedPaymentDialogState extends State<_MixedPaymentDialog> {
  final _amountCtrl = TextEditingController();
  String _method = 'cash';
  final _lines = <({String method, double amount})>[];

  CashierController get _c => widget.controller;
  double get _remaining => _c.state.currentOrder?.remaining ?? 0;

  @override
  void initState() {
    super.initState();
    _amountCtrl.text = _remaining.toStringAsFixed(0);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPayment() async {
    final raw = _amountCtrl.text.replaceAll(RegExp(r'[^\d]'), '');
    var amount = double.tryParse(raw) ?? 0;
    if (amount <= 0) return;
    if (amount > _remaining) amount = _remaining;
    final method = _method;
    final res = await _c.payPartial(amount: amount, method: method);
    if (res == null) {
      if (mounted && _c.state.errorMessage != null) {
        showAppSnack(context, _c.state.errorMessage!, isError: true);
      }
      return;
    }
    if (!mounted) return;
    if (res['payment_status'] == 'paid') {
      Navigator.pop(context);
      showAppSnack(context, 'Pembayaran gabungan selesai — lunas');
      return;
    }
    setState(() {
      _lines.add((method: method, amount: amount));
      _amountCtrl.text = _remaining.toStringAsFixed(0);
    });
  }

  String _methodLabel(String m) => const {
        'cash': 'Tunai',
        'card': 'Kartu',
        'qris': 'QRIS',
        'transfer': 'Transfer',
      }[m] ?? m;

  @override
  Widget build(BuildContext context) {
    final order = _c.state.currentOrder;
    final total = order?.totalAmount ?? 0;
    final paid = total - _remaining;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.payments_outlined, color: AppColors.moduleMeja),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Gabung Pembayaran',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _row('Total', total, bold: true),
                    const SizedBox(height: 4),
                    _row('Terbayar', paid, color: AppColors.moduleKasir),
                    const Divider(height: 16),
                    _row('Sisa', _remaining,
                        bold: true, color: AppColors.danger),
                  ],
                ),
              ),
              if (_lines.isNotEmpty) ...[
                const SizedBox(height: 10),
                ..._lines.map((l) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('• ${_methodLabel(l.method)}',
                              style: const TextStyle(fontSize: 13)),
                          Text(CurrencyHelper.format(l.amount),
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    )),
              ],
              const SizedBox(height: 14),
              const Text('Metode',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _mChip('cash', 'Tunai', Icons.money),
                  _mChip('card', 'Kartu', Icons.credit_card),
                  _mChip('qris', 'QRIS', Icons.qr_code),
                  _mChip('transfer', 'Transfer', Icons.account_balance),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amountCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [RupiahInputFormatter()],
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  labelText: 'Jumlah bayar (metode ini)',
                  prefixText: 'Rp ',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              AppButton(
                label: _remaining > 0 ? 'Tambah Pembayaran' : 'Lunas',
                icon: Icons.add_rounded,
                accent: AppColors.moduleMeja,
                loading: _c.state.isProcessing,
                onPressed: _c.state.isProcessing ? null : _addPayment,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, double v, {bool bold = false, Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        Text(CurrencyHelper.format(v),
            style: TextStyle(
                fontSize: bold ? 16 : 13,
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: color ?? AppColors.textPrimary)),
      ],
    );
  }

  Widget _mChip(String value, String label, IconData icon) {
    final selected = _method == value;
    return GestureDetector(
      onTap: () => setState(() => _method = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppColors.moduleMeja : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: selected ? Colors.white : AppColors.textSecondary),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.textSecondary,
                )),
          ],
        ),
      ),
    );
  }
}
