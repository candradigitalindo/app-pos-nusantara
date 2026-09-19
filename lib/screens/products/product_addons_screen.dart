import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../repositories/product_repository.dart';
import '../../theme/theme.dart';
import '../../utils/currency.dart';
import '../../widgets/ui/ui.dart';

/// Pengelolaan add-on/modifier satu produk (mis. "Extra keju +5.000").
///
/// Add-on yang dihapus di sini hanya ditandai terhapus — baris pesanan lama
/// menyimpan salinan nama & harganya, jadi struk historis tetap utuh.
class ProductAddonsScreen extends StatefulWidget {
  final Product product;
  const ProductAddonsScreen({super.key, required this.product});

  @override
  State<ProductAddonsScreen> createState() => _ProductAddonsScreenState();
}

class _ProductAddonsScreenState extends State<ProductAddonsScreen> {
  final _repo = ProductRepository();

  List<ProductAddon> _addons = [];
  bool _loading = true;
  String? _error;

  static const _accent = AppColors.moduleProduk;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _repo.getAllAddons(widget.product.id);
      if (!mounted) return;
      setState(() {
        _addons = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Gagal memuat add-on: $e';
        _loading = false;
      });
    }
  }

  Future<void> _showForm({ProductAddon? addon}) async {
    final nameCtrl = TextEditingController(text: addon?.name ?? '');
    final groupCtrl = TextEditingController(text: addon?.groupName ?? '');
    final priceCtrl = TextEditingController(
      text: (addon?.price ?? 0) > 0
          ? CurrencyHelper.formatInput(addon!.price.toInt())
          : '',
    );
    var rawPrice = addon?.price ?? 0;

    final saved = await showAppModal<bool>(
      context,
      title: addon == null ? 'Tambah Add-on' : 'Edit Add-on',
      subtitle: widget.product.name,
      icon: Icons.tune_rounded,
      accent: _accent,
      maxWidth: 460,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nama add-on *',
              hintText: 'Contoh: Extra keju',
              prefixIcon: Icon(Icons.add_circle_outline_rounded),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: priceCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Harga tambahan',
              hintText: '0 untuk tambahan gratis',
              prefixIcon: Icon(Icons.payments_outlined),
            ),
            onChanged: (v) {
              // Format ulang sambil mengetik ("5000" → "5.000") dan jaga kursor
              // tetap di akhir agar pemisah ribuan tidak melompatkannya.
              rawPrice = CurrencyHelper.parseInput(v);
              final formatted = CurrencyHelper.formatInput(v);
              priceCtrl.value = TextEditingValue(
                text: formatted,
                selection: TextSelection.collapsed(offset: formatted.length),
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: groupCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Kelompok (opsional)',
              hintText: 'Contoh: Topping, Level pedas',
              prefixIcon: Icon(Icons.folder_outlined),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Kelompok hanya merapikan tampilan pilihan di kasir. '
            'Tamu tetap bebas memilih berapa pun add-on.',
            style: AppType.caption.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppButton(
            label: addon == null ? 'Tambah' : 'Simpan Perubahan',
            icon: addon == null ? Icons.add_rounded : Icons.check_rounded,
            accent: _accent,
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) {
                showAppSnack(ctx, 'Nama add-on wajib diisi', isError: true);
                return;
              }
              Navigator.pop(ctx, true);
            },
          ),
        ],
      ),
    );

    if (saved != true) return;

    try {
      if (addon == null) {
        await _repo.createAddon(
          productId: widget.product.id,
          name: nameCtrl.text.trim(),
          price: rawPrice,
          groupName: groupCtrl.text.trim(),
          // Add-on baru selalu di urutan paling belakang.
          sortOrder: _addons.length,
        );
      } else {
        await _repo.updateAddon(addon.copyWith(
          name: nameCtrl.text.trim(),
          price: rawPrice,
          groupName: groupCtrl.text.trim(),
        ));
      }
      await _load();
      if (mounted) {
        showAppSnack(context, addon == null ? 'Add-on ditambahkan' : 'Add-on diperbarui');
      }
    } catch (e) {
      if (mounted) showAppSnack(context, 'Gagal menyimpan: $e', isError: true);
    }
  }

  Future<void> _toggleActive(ProductAddon addon) async {
    try {
      await _repo.updateAddon(
        addon.copyWith(isActive: addon.isActive == 1 ? 0 : 1),
      );
      await _load();
    } catch (e) {
      if (mounted) showAppSnack(context, 'Gagal mengubah: $e', isError: true);
    }
  }

  Future<void> _confirmDelete(ProductAddon addon) async {
    final ok = await showAppModal<bool>(
      context,
      title: 'Hapus Add-on',
      subtitle: addon.name,
      icon: Icons.delete_outline_rounded,
      accent: AppColors.danger,
      maxWidth: 420,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Add-on ini tidak lagi ditawarkan saat memesan. '
            'Pesanan dan struk lama yang memakainya tidak berubah.',
            style: AppType.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(
                child: AppButton.neutral('Batal',
                    onPressed: () => Navigator.pop(ctx, false)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Hapus',
                  icon: Icons.delete_outline_rounded,
                  accent: AppColors.danger,
                  onPressed: () => Navigator.pop(ctx, true),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (ok != true) return;
    try {
      await _repo.deleteAddon(addon.id);
      await _load();
      if (mounted) showAppSnack(context, 'Add-on dihapus');
    } catch (e) {
      if (mounted) showAppSnack(context, 'Gagal menghapus: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('Add-on Menu'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              widget.product.name,
              style: AppType.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showForm(),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Tambah Add-on'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: AppType.body),
              const SizedBox(height: AppSpacing.md),
              AppButton.neutral('Muat ulang', onPressed: _load),
            ],
          ),
        ),
      );
    }
    if (_addons.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tune_rounded,
                  size: 48, color: AppColors.textTertiary),
              const SizedBox(height: AppSpacing.md),
              Text('Belum ada add-on', style: AppType.h3),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Tambahkan pilihan seperti "Extra keju" atau "Level pedas". '
                'Kasir akan ditawari pilihan ini saat menu dipesan.',
                textAlign: TextAlign.center,
                style: AppType.body.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, 96),
      itemCount: _addons.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs),
      itemBuilder: (context, i) => _tile(_addons[i]),
    );
  }

  Widget _tile(ProductAddon addon) {
    final active = addon.isActive == 1;
    return AppCard(
      onTap: () => _showForm(addon: addon),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  addon.name,
                  style: AppType.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color:
                        active ? AppColors.textPrimary : AppColors.textTertiary,
                    decoration: active ? null : TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      addon.price > 0
                          ? '+${CurrencyHelper.format(addon.price)}'
                          : 'Gratis',
                      style: AppType.caption.copyWith(
                        color: _accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (addon.groupName.isNotEmpty) ...[
                      Text(' · ',
                          style: AppType.caption
                              .copyWith(color: AppColors.textTertiary)),
                      Text(addon.groupName,
                          style: AppType.caption
                              .copyWith(color: AppColors.textTertiary)),
                    ],
                    if (!active) ...[
                      Text(' · ',
                          style: AppType.caption
                              .copyWith(color: AppColors.textTertiary)),
                      Text('Nonaktif',
                          style: AppType.caption
                              .copyWith(color: AppColors.textTertiary)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: active ? 'Nonaktifkan' : 'Aktifkan',
            onPressed: () => _toggleActive(addon),
            icon: Icon(
              active
                  ? Icons.toggle_on_rounded
                  : Icons.toggle_off_outlined,
              color: active ? _accent : AppColors.textTertiary,
              size: 28,
            ),
          ),
          IconButton(
            tooltip: 'Hapus',
            onPressed: () => _confirmDelete(addon),
            icon: const Icon(Icons.delete_outline_rounded,
                color: AppColors.danger, size: 20),
          ),
        ],
      ),
    );
  }
}
