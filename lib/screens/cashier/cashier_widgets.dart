import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/menu_avatar.dart';
import '../../widgets/ui/ui.dart';

/// Komponen tampilan Kasir yang dipakai BERSAMA oleh kasir perangkat utama
/// (`cashier_screen.dart`) dan Kasir Station (`station/cashier_station_screen`).
///
/// Tujuannya satu: kasir yang biasa memakai perangkat utama menemukan tata
/// letak, ukuran tombol, dan istilah yang sama persis di station — tak perlu
/// pelatihan ulang. Karena itu jangan menyalin ulang widget di sini ke salah
/// satu layar; ubah di file ini agar keduanya ikut berubah.

// ── Ukuran tombol header (target sentuh ~84×60, mengecil di HP) ─────────────
const double kCashierHeaderBtnW = 84;
const double kCashierHeaderBtnH = 60;

/// Bungkus beberapa tombol header jadi satu grup berlatar transparan.
Widget cashierHeaderGroup(List<Widget> children) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

Widget cashierGroupDivider() => Container(
      width: 1,
      color: Colors.white.withValues(alpha: 0.2),
    );

/// Tombol di dalam grup header. [enabled] false = fungsi tak tersedia di
/// perangkat ini (mis. aksi laci uang di station): tampil redup, ketukan
/// diteruskan ke [onTap] agar layar bisa menjelaskan alasannya.
///
/// [background] mengisi segmen dengan warna sendiri (mis. putih untuk "Muat
/// Ulang", merah untuk "Tutup Kasir") sehingga tombol berwarna tetap bisa
/// duduk di dalam SATU bingkai header bersama tombol lain.
class CashierHeaderButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? background;
  final double width;
  final double height;
  final bool enabled;

  const CashierHeaderButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.background,
    this.width = kCashierHeaderBtnW,
    this.height = kCashierHeaderBtnH,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? Colors.white;
    final shown = enabled ? color : color.withValues(alpha: 0.45);
    return Material(
      color: background ?? Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: shown, size: 22),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Text(label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: shown,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chip kategori di atas grid menu.
class CashierCategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const CashierCategoryChip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: Material(
        // SECONDARY gold untuk kategori terpilih (identitas hijau+emas).
        color: selected ? AppColors.accent : AppColors.surfaceMuted,
        borderRadius: AppRadius.rPill,
        child: InkWell(
          borderRadius: AppRadius.rPill,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.xs),
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.center,
            child: Text(
              label,
              style: AppType.label.copyWith(
                color: selected ? Colors.white : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tombol aksi utama panel pesanan (BUAT ORDER / TAMBAH / BAYAR).
class CashierActionButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final VoidCallback? onTap;

  const CashierActionButton(
      {super.key,
      required this.label,
      required this.isLoading,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: label,
      loading: isLoading,
      onPressed: onTap,
      accent: AppColors.moduleKasir,
      size: AppButtonSize.medium,
    );
  }
}

/// Tombol aksi sekunder ("Aksi Lainnya") — gold tonal.
class CashierSecondaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const CashierSecondaryButton(
      {super.key, required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: label,
      icon: icon,
      onPressed: onTap,
      variant: AppButtonVariant.tonal,
      accent: AppColors.accent,
      size: AppButtonSize.medium,
    );
  }
}

class CashierProductTile extends StatelessWidget {
  final Product product;
  final int inCart;

  /// Menu ini punya add-on — ditandai agar kasir tahu sebelum menekan bahwa
  /// akan muncul dialog pilihan tambahan.
  final bool hasAddons;
  final VoidCallback onTap;

  const CashierProductTile({
    super.key,
    required this.product,
    required this.inCart,
    this.hasAddons = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = inCart > 0;
    return Material(
      color: active ? AppColors.soft(AppColors.moduleKasir, 0.10) : AppColors.surface,
      borderRadius: AppRadius.rLg,
      child: InkWell(
        borderRadius: AppRadius.rLg,
        onTap: onTap,
        splashColor: AppColors.soft(AppColors.moduleKasir, 0.10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: AppRadius.rLg,
            border: Border.all(
              color: active
                  ? AppColors.soft(AppColors.moduleKasir, 0.45)
                  : AppColors.border,
              width: active ? 1.5 : 1,
            ),
            boxShadow: active ? null : AppShadows.card,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: AppRadius.rMd,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: MenuAvatar.fill(name: product.name),
                        ),
                        if (active)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.xs, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.moduleKasir,
                                borderRadius: AppRadius.rSm,
                                boxShadow: AppShadows.glow(AppColors.moduleKasir),
                              ),
                              child: Text(
                                '$inCart',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        if (hasAddons)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: AppRadius.rSm,
                                boxShadow: AppShadows.card,
                              ),
                              child: const Icon(
                                Icons.tune_rounded,
                                size: 13,
                                color: AppColors.moduleKasir,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                // Tinggi tetap 2 baris → nama panjang tampil penuh & area gambar
                // tetap seragam di semua tile.
                SizedBox(
                  height: 34,
                  child: Text(
                    product.name,
                    style: AppType.label
                        .copyWith(color: AppColors.textPrimary, height: 1.2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  CurrencyHelper.format(product.price),
                  style: AppType.body.copyWith(
                    color: AppColors.moduleKasir,
                    fontWeight: FontWeight.w800,
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

class CashierCartItemTile extends StatelessWidget {
  final String name;
  final int qty;
  final double price;
  final String? status;
  final String? notes;

  /// Ringkasan add-on baris ini, mis. "Extra keju, Pedas". Kosong = tanpa
  /// tambahan. Harganya sudah termasuk di [price].
  final String addonLabel;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;
  final VoidCallback? onEditNote;
  final VoidCallback? onEditAddons; // null bila menu tak punya add-on
  final VoidCallback? onDelete; // hapus/void item (butuh PIN manager/SVP)

  const CashierCartItemTile({
    super.key,
    required this.name,
    required this.qty,
    required this.price,
    this.status,
    this.notes,
    this.addonLabel = '',
    this.onAdd,
    this.onRemove,
    this.onEditNote,
    this.onEditAddons,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          // Tombol catatan diletakkan PALING DEPAN (sebelum item) agar terpisah
          // jauh dari tombol +/− di kanan — mengurangi risiko salah ketuk.
          if (onEditNote != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: onEditNote,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (notes != null && notes!.isNotEmpty)
                        ? AppColors.soft(AppColors.moduleKasir, 0.12)
                        : AppColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    (notes != null && notes!.isNotEmpty)
                        ? Icons.edit_note_rounded
                        : Icons.note_add_outlined,
                    size: 20,
                    color: (notes != null && notes!.isNotEmpty)
                        ? AppColors.moduleKasir
                        : AppColors.textTertiary,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$qty×  $name',
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 13)),
                Text(
                  '@ ${CurrencyHelper.format(price)}  •  '
                  '${CurrencyHelper.format(price * qty)}',
                  style: const TextStyle(
                      color: AppColors.moduleKasir,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (addonLabel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: GestureDetector(
                      onTap: onEditAddons,
                      child: Text(
                        '+ $addonLabel',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (notes != null && notes!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '📝 $notes',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                // Baris tanpa add-on terpilih tetap bisa diracik lewat pintasan
                // ini — tanpa perlu menghapus lalu menambah ulang itemnya.
                if (addonLabel.isEmpty && onEditAddons != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: GestureDetector(
                      onTap: onEditAddons,
                      child: const Text(
                        '+ Tambahan',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.moduleKasir,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (status != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _statusColor(status!).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                status!.toUpperCase(),
                style: TextStyle(
                    fontSize: 9,
                    color: _statusColor(status!),
                    fontWeight: FontWeight.w600),
              ),
            ),
          if (status != null && onDelete != null)
            GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 44,
                height: 44,
                margin: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  color: AppColors.soft(AppColors.danger, 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.delete_outline,
                    size: 16, color: AppColors.danger),
              ),
            ),
          if (status == null) ...[
            if (onRemove != null)
              GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.remove, size: 16),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text('$qty',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
            ),
            if (onAdd != null)
              GestureDetector(
                onTap: onAdd,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.moduleKasir,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.add, size: 16, color: Colors.white),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'pending':
        return AppColors.warning;
      case 'cooking':
        return AppColors.moduleProduk;
      case 'ready':
        return AppColors.success;
      case 'served':
        return AppColors.textTertiary;
      default:
        return AppColors.textTertiary;
    }
  }
}

// ── Movements History Dialog ──────────────────────────────────────────────────

class CashierPaymentSheet extends StatefulWidget {
  final double total;
  final TextEditingController controller;
  final void Function(String method, double amount) onPay;

  const CashierPaymentSheet({
    super.key,
    required this.total,
    required this.controller,
    required this.onPay,
  });

  @override
  State<CashierPaymentSheet> createState() => _CashierPaymentSheetState();
}

class _CashierPaymentSheetState extends State<CashierPaymentSheet> {
  String _method = 'cash';

  double get _parsedAmount {
    final raw = widget.controller.text.replaceAll('.', '');
    return double.tryParse(raw) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final change = _parsedAmount - widget.total;

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pembayaran', style: AppType.h2),
                    const SizedBox(height: 2),
                    Text(
                      'Total: ${CurrencyHelper.format(widget.total)}',
                      style: AppType.title.copyWith(color: AppColors.moduleKasir),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: AppColors.textTertiary),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Payment method
          Text('Metode Pembayaran', style: AppType.label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              _methodChip('cash', 'Tunai', Icons.money),
              _methodChip('card', 'Kartu', Icons.credit_card),
              _methodChip('qris', 'QRIS', Icons.qr_code),
              _methodChip('transfer', 'Transfer', Icons.account_balance),
            ],
          ),
          const SizedBox(height: 20),

          // Amount input (only cash)
          if (_method == 'cash') ...[
            Text('Jumlah Bayar', style: AppType.label),
            const SizedBox(height: 8),
            TextField(
              controller: widget.controller,
              keyboardType: TextInputType.number,
              inputFormatters: [RupiahInputFormatter()],
              decoration: InputDecoration(
                prefixText: 'Rp ',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: AppColors.moduleKasir, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Text(
              change >= 0
                  ? 'Kembalian: ${CurrencyHelper.format(change)}'
                  : 'Kurang: ${CurrencyHelper.format(-change)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: change >= 0
                    ? AppColors.moduleKasir
                    : AppColors.danger,
              ),
            ),
            const SizedBox(height: 16),
          ],

          const SizedBox(height: 4),
          AppButton(
            label: 'PROSES PEMBAYARAN',
            icon: Icons.check_circle_outline_rounded,
            accent: AppColors.moduleKasir,
            onPressed: () {
              if (_method == 'cash') {
                if (_parsedAmount < widget.total) return;
                widget.onPay(_method, _parsedAmount);
              } else {
                widget.onPay(_method, widget.total);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _methodChip(String value, String label, IconData icon) {
    final selected = _method == value;
    return ChoiceChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 16,
              color: selected ? Colors.white : AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(label),
        ],
      ),
      selected: selected,
      onSelected: (_) => setState(() => _method = value),
      selectedColor: AppColors.moduleKasir,
      labelStyle: TextStyle(
          color: selected ? Colors.white : AppColors.textSecondary,
          fontWeight: FontWeight.w600),
    );
  }
}

/// Meja untuk [CashierTablePickerDialog] — sengaja ringkas supaya bisa diisi
/// dari model lokal (perangkat utama) maupun map JSON dari Main POS (station).
class CashierPickerTable {
  final String number;
  final bool available;
  const CashierPickerTable({required this.number, required this.available});
}

/// Dialog "Pilih Meja" — pop dengan NOMOR meja terpilih, atau null bila batal.
class CashierTablePickerDialog extends StatefulWidget {
  final List<CashierPickerTable> tables;
  final String? selectedNumber;
  const CashierTablePickerDialog(
      {super.key, required this.tables, this.selectedNumber});

  @override
  State<CashierTablePickerDialog> createState() => _CashierTablePickerDialogState();
}

class _CashierTablePickerDialogState extends State<CashierTablePickerDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final q = _q.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.tables
        : widget.tables
            .where((t) => t.number.toLowerCase().contains(q))
            .toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: SizedBox(
        // Selalu tampil BESAR; bila meja banyak → area daftar yang scroll.
        width: size.width > 820 ? 760 : size.width * 0.9,
        height: size.height * 0.82,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.table_restaurant_outlined,
                      color: AppColors.moduleKasir, size: 26),
                  const SizedBox(width: 10),
                  const Text('Pilih Meja',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: 'Cari meja... (mis. A5, 12)',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: filtered.isEmpty
                    ? const Center(
                        child: Text('Meja tidak ditemukan',
                            style: TextStyle(color: AppColors.textTertiary)))
                    : GridView.builder(
                        padding: EdgeInsets.zero,
                        // Kolom mengisi lebar; di HP lebih sedikit agar tak
                        // sempit, sisanya scroll ke bawah.
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: context.isPhone ? 3 : 5,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 1.25,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => _tile(filtered[i]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(CashierPickerTable table) {
    final isAvailable = table.available;
    final isSelected = widget.selectedNumber == table.number;
    return Material(
      color: isSelected
          ? AppColors.moduleKasir
          : isAvailable
              ? AppColors.surfaceMuted
              : AppColors.warningSoft,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pop(context, table.number),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                table.number,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isSelected
                      ? Colors.white
                      : !isAvailable
                          ? AppColors.warning
                          : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                isAvailable ? 'Tersedia' : 'Terisi',
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected ? Colors.white70 : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
