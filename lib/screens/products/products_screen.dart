import 'package:flutter/material.dart';

import '../../controllers/products_controller.dart';
import '../../models/models.dart';
import '../../theme/theme.dart';
import 'product_addons_screen.dart';
import '../../utils/currency.dart';
import '../../widgets/menu_avatar.dart';
import '../../widgets/ui/ui.dart';

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  late final ProductsController _controller;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = ProductsController();
    _controller.addListener(_onStateChanged);
    _controller.loadData();
  }

  @override
  void deactivate() {
    _controller.removeListener(_onStateChanged);
    super.deactivate();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final state = _controller.state;

    final errorMsg = state.errorMessage;
    final successMsg = state.successMessage;

    if (errorMsg != null || successMsg != null) _controller.clearMessages();

    if (!mounted) return;
    setState(() {});

    if (errorMsg != null || successMsg != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (errorMsg != null) _showSnack(errorMsg, isError: true);
        if (successMsg != null) _showSnack(successMsg);
      });
    }
  }

  void _showSnack(String msg, {bool isError = false}) =>
      showAppSnack(context, msg, isError: isError);

  String _getCategoryName(String? catId) {
    if (catId == null) return 'Tanpa Kategori';
    final cat =
        _controller.state.categories.where((c) => c.id == catId).firstOrNull;
    return cat?.name ?? 'Tanpa Kategori';
  }

  /// Tampilkan pesan & batalkan aksi bila sync cloud aktif. True = terblokir.
  bool _blockedBySync() {
    if (!_controller.state.syncEnabled) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Sync cloud aktif — produk & kategori hanya bisa diubah dari cloud.'),
        backgroundColor: AppColors.warning,
      ),
    );
    return true;
  }

  void _showProductForm({Product? product}) {
    if (_blockedBySync()) return;
    final state = _controller.state;
    final nameCtrl = TextEditingController(text: product?.name);
    final codeCtrl = TextEditingController(text: product?.code);
    final descCtrl = TextEditingController(text: product?.description);
    final priceCtrl = TextEditingController(
        text: product != null && product.price > 0
            ? CurrencyHelper.format(product.price)
            : '');
    String? selectedCatId = product?.categoryId ?? state.selectedCategory?.id;
    double rawPrice = product?.price ?? 0;

    showAppModal(
      context,
      title: product == null ? 'Tambah Produk' : 'Edit Produk',
      subtitle: product == null
          ? 'Tambahkan produk baru ke menu'
          : 'Update informasi produk',
      icon: Icons.inventory_2_rounded,
      accent: AppColors.moduleProduk,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _FormSection(
              children: [
                _formField('Nama Produk *', nameCtrl, hint: 'Contoh: Teh Manis'),
                const Divider(height: 1, color: AppColors.border),
                _categoryField(state, selectedCatId,
                    (v) => setModalState(() => selectedCatId = v)),
                const Divider(height: 1, color: AppColors.border),
                _priceField(priceCtrl,
                    onChanged: (v, parsed) => rawPrice = parsed),
                const Divider(height: 1, color: AppColors.border),
                _formField('Kode Produk', codeCtrl, hint: 'Contoh: TEH-001'),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _FormSection(
              children: [
                _formField('Deskripsi', descCtrl,
                    hint: 'Deskripsi produk...', maxLines: 3),
              ],
            ),
            // Add-on butuh produk yang sudah tersimpan (punya id), jadi hanya
            // muncul saat mengedit — bukan saat membuat produk baru.
            if (product != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _FormSection(
                children: [
                  ListTile(
                    leading: const Icon(Icons.tune_rounded,
                        color: AppColors.moduleProduk),
                    title: Text('Add-on Menu', style: AppType.body),
                    subtitle: Text(
                      'Pilihan tambahan seperti "Extra keju"',
                      style: AppType.caption
                          .copyWith(color: AppColors.textTertiary),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded,
                        color: AppColors.textTertiary),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ProductAddonsScreen(product: product),
                        ),
                      ).then((_) => _controller.loadData());
                    },
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: product == null ? 'Tambah Produk' : 'Simpan Perubahan',
              icon: product == null ? Icons.add_rounded : Icons.check_rounded,
              accent: AppColors.moduleProduk,
              onPressed: () {
                if (nameCtrl.text.isEmpty ||
                    selectedCatId == null ||
                    rawPrice <= 0) {
                  showAppSnack(ctx, 'Nama, kategori, dan harga wajib diisi',
                      isError: true);
                  return;
                }
                Navigator.pop(ctx);
                if (product == null) {
                  _controller.createProduct(
                    name: nameCtrl.text.trim(),
                    code: codeCtrl.text.trim().isEmpty
                        ? null
                        : codeCtrl.text.trim(),
                    description: descCtrl.text.trim().isEmpty
                        ? null
                        : descCtrl.text.trim(),
                    price: rawPrice,
                    categoryId: selectedCatId,
                  );
                } else {
                  _controller.updateProduct(Product(
                    id: product.id,
                    name: nameCtrl.text.trim(),
                    code: codeCtrl.text.trim().isEmpty
                        ? null
                        : codeCtrl.text.trim(),
                    description: descCtrl.text.trim().isEmpty
                        ? null
                        : descCtrl.text.trim(),
                    price: rawPrice,
                    categoryId: selectedCatId,
                    stock: product.stock,
                    isDeleted: product.isDeleted,
                    createdAt: product.createdAt,
                    updatedAt: DateTime.now(),
                  ));
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _formField(String label, TextEditingController ctrl,
      {String hint = '', int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppType.label.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.xxs),
          TextField(
            controller: ctrl,
            maxLines: maxLines,
            style: AppType.body,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: AppType.body.copyWith(color: AppColors.textTertiary),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryField(ProductsState state, String? selected,
      ValueChanged<String?> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Kategori *',
              style: AppType.label.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.xxs),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selected,
              isExpanded: true,
              isDense: true,
              style: AppType.body.copyWith(color: AppColors.textPrimary),
              icon: const Icon(Icons.expand_more_rounded,
                  color: AppColors.textTertiary),
              hint: Text('Pilih kategori',
                  style: AppType.body.copyWith(color: AppColors.textTertiary)),
              items: state.categories
                  .map((c) =>
                      DropdownMenuItem(value: c.id, child: Text(c.name)))
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _priceField(TextEditingController ctrl,
      {required void Function(String, double) onChanged}) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Harga *',
              style: AppType.label.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.xxs),
          Row(
            children: [
              Text('Rp ',
                  style: AppType.body.copyWith(
                      color: AppColors.textTertiary,
                      fontWeight: FontWeight.w600)),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  style: AppType.body,
                  decoration: InputDecoration(
                    hintText: '0',
                    hintStyle:
                        AppType.body.copyWith(color: AppColors.textTertiary),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                  onChanged: (v) {
                    final clean = v.replaceAll('.', '').replaceAll(',', '');
                    onChanged(v, double.tryParse(clean) ?? 0);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showCategoryForm({Category? existing}) {
    if (_blockedBySync()) return;
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    var printDest = existing?.printDestination ?? 'kitchen';

    showAppModal(
      context,
      title: isEdit ? 'Ubah Kategori' : 'Tambah Kategori',
      subtitle: isEdit
          ? 'Perbarui nama kategori'
          : 'Kelompokkan produk ke dalam kategori',
      icon: Icons.folder_rounded,
      accent: AppColors.moduleProduk,
      maxWidth: 460,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          Widget destChip(String label, IconData icon, String value) {
            final sel = printDest == value;
            return Expanded(
              child: GestureDetector(
                onTap: () => setModal(() => printDest = value),
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm, horizontal: AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: sel
                        ? AppColors.soft(AppColors.moduleProduk, 0.12)
                        : AppColors.surfaceMuted,
                    borderRadius: AppRadius.rMd,
                    border: Border.all(
                        color: sel ? AppColors.moduleProduk : AppColors.border,
                        width: sel ? 1.5 : 1),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon,
                          size: 22,
                          color: sel
                              ? AppColors.moduleProduk
                              : AppColors.textTertiary),
                      const SizedBox(height: 4),
                      Text(label,
                          style: AppType.label.copyWith(
                              color: sel
                                  ? AppColors.moduleProduk
                                  : AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: AppType.body,
                decoration: const InputDecoration(labelText: 'Nama Kategori'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: descCtrl,
                style: AppType.body,
                decoration:
                    const InputDecoration(labelText: 'Deskripsi (opsional)'),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('TUJUAN STASIUN', style: AppType.overline),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  destChip('Dapur', Icons.soup_kitchen_rounded, 'kitchen'),
                  const SizedBox(width: AppSpacing.sm),
                  destChip('Bar', Icons.local_bar_rounded, 'bar'),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Menentukan item kategori ini tampil di Display Dapur atau Bar '
                '(mengikuti kategori, sejalan dengan routing printer).',
                style: AppType.caption.copyWith(color: AppColors.textTertiary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: AppButton.neutral('Batal',
                        onPressed: () => Navigator.pop(ctx)),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppButton(
                      label: isEdit ? 'Simpan' : 'Tambah',
                      accent: AppColors.moduleProduk,
                      onPressed: () {
                        if (nameCtrl.text.trim().isEmpty) return;
                        Navigator.pop(ctx);
                        if (existing != null) {
                          _controller.updateCategory(existing,
                              name: nameCtrl.text.trim(),
                              printDestination: printDest);
                        } else {
                          _controller.createCategory(
                            name: nameCtrl.text.trim(),
                            description: descCtrl.text.trim().isEmpty
                                ? null
                                : descCtrl.text.trim(),
                            printDestination: printDest,
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(Product product) async {
    if (_blockedBySync()) return;
    final ok = await showAppConfirm(
      context,
      title: 'Hapus Produk',
      message: 'Hapus "${product.name}"? Tindakan ini tidak dapat dibatalkan.',
      confirmText: 'Hapus',
      icon: Icons.delete_outline_rounded,
      destructive: true,
    );
    if (ok) _controller.deleteProduct(product.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final filtered = state.filteredProducts;

    final Widget refreshAction = state.isLoading
        ? const SizedBox(
            width: 42,
            height: 42,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: AppColors.moduleProduk),
              ),
            ),
          )
        : AppIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Muat ulang',
            onPressed: () => _controller.loadData(),
            color: AppColors.moduleProduk,
            size: 42,
          );

    final Widget addProductAction = context.isPhone
        ? AppIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Tambah Produk',
            onPressed: () => _showProductForm(),
            color: AppColors.moduleProduk,
            filled: true,
            size: 42,
          )
        : AppButton(
            label: 'Tambah Produk',
            icon: Icons.add_rounded,
            onPressed: () => _showProductForm(),
            accent: AppColors.moduleProduk,
            size: AppButtonSize.small,
            expanded: false,
          );

    final actions = <Widget>[
      if (!state.syncEnabled) ...[
        AppIconButton(
          icon: Icons.create_new_folder_rounded,
          tooltip: 'Tambah Kategori',
          onPressed: _showCategoryForm,
          color: AppColors.moduleProduk,
          size: 42,
        ),
        const SizedBox(width: AppSpacing.xxs),
        addProductAction,
        const SizedBox(width: AppSpacing.xxs),
      ],
      refreshAction,
    ];

    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            AppPageHeader(
              title: 'Produk',
              subtitle: '${filtered.length} produk tersedia',
              icon: Icons.inventory_2_rounded,
              accent: AppColors.moduleProduk,
              actions: actions,
            ),

            // ── Banner: dikelola via cloud ──
            if (state.syncEnabled) _syncBanner(),

            // ── Search ──
            _searchBar(),

            // ── Category tabs ──
            _categoryTabs(state),

            // ── Product grid ──
            Expanded(
              child: state.isLoading && state.products.isEmpty
                  ? const AppLoader(label: 'Memuat produk...')
                  : filtered.isEmpty
                      ? _emptyState()
                      : GridView.builder(
                          padding: EdgeInsets.all(context.pagePadX),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: context.gridColumns(
                                minTileWidth: 150, gap: AppSpacing.sm),
                            mainAxisSpacing: AppSpacing.sm,
                            crossAxisSpacing: AppSpacing.sm,
                            childAspectRatio: 0.76,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final product = filtered[index];
                            return _ProductCard(
                              product: product,
                              categoryName:
                                  _getCategoryName(product.categoryId),
                              onEdit: () => _showProductForm(product: product),
                              onDelete: () => _confirmDelete(product),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _syncBanner() {
    return Padding(
      padding:
          EdgeInsets.fromLTRB(context.pagePadX, AppSpacing.sm, context.pagePadX, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.warningSoft,
          borderRadius: AppRadius.rMd,
          border: Border.all(color: AppColors.soft(AppColors.warning, 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_done_rounded,
                size: 18, color: AppColors.warning),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                'Sync cloud aktif — produk & kategori dikelola dari cloud, tidak bisa diedit di sini.',
                style: AppType.caption.copyWith(
                    color: AppColors.warning, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.pagePadX, AppSpacing.sm, context.pagePadX, AppSpacing.xs),
      child: TextField(
        controller: _searchCtrl,
        onChanged: _controller.setSearchQuery,
        textInputAction: TextInputAction.search,
        style: AppType.body,
        decoration: const InputDecoration(
          hintText: 'Cari produk...',
          prefixIcon:
              Icon(Icons.search_rounded, color: AppColors.moduleProduk),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.rMd,
            borderSide: BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadius.rMd,
            borderSide: BorderSide(color: AppColors.moduleProduk, width: 2),
          ),
        ),
      ),
    );
  }

  Widget _categoryTabs(ProductsState state) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
            horizontal: context.pagePadX, vertical: AppSpacing.xs),
        children: [
          _catChip('Semua', state.selectedCategory == null,
              () => _controller.selectCategory(null)),
          ...state.categories.map((cat) => _catChip(
                cat.name,
                state.selectedCategory?.id == cat.id,
                () => _controller.selectCategory(cat),
                onLongPress: state.syncEnabled
                    ? null
                    : () => _showCategoryForm(existing: cat),
              )),
        ],
      ),
    );
  }

  Widget _catChip(String label, bool selected, VoidCallback onTap,
      {VoidCallback? onLongPress}) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            // SECONDARY gold untuk chip kategori terpilih (identitas hijau+emas).
            gradient: selected
                ? const LinearGradient(colors: AppColors.accentGradient)
                : null,
            color: selected ? null : AppColors.surface,
            borderRadius: AppRadius.rPill,
            border: Border.all(
                color: selected ? Colors.transparent : AppColors.border),
            boxShadow: selected
                ? AppShadows.glow(AppColors.accent, strength: 0.25)
                : null,
          ),
          child: Text(
            label,
            style: AppType.label.copyWith(
                color: selected ? Colors.white : AppColors.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return EmptyState(
      icon: Icons.inventory_2_rounded,
      title: 'Belum ada produk',
      message: 'Tambah produk atau muat data contoh untuk memulai',
      actionLabel: 'Tambah Data Contoh',
      onAction: _controller.seedSampleData,
      accent: AppColors.moduleProduk,
    );
  }
}

// ── Form Section Card ─────────────────────────────────────────────────────────

class _FormSection extends StatelessWidget {
  final List<Widget> children;
  const _FormSection({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.rLg,
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.card,
      ),
      child: Column(children: children),
    );
  }
}

// ── Product Card ──────────────────────────────────────────────────────────────

class _ProductCard extends StatelessWidget {
  final Product product;
  final String categoryName;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ProductCard({
    required this.product,
    required this.categoryName,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onDelete,
      child: AppCard(
        onTap: onEdit,
        accent: AppColors.moduleProduk,
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Avatar besar mengisi atas kartu
            Expanded(
              child: MenuAvatar.fill(name: product.name),
            ),
            const SizedBox(height: AppSpacing.xs),
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
            Row(
              children: [
                Text(
                  CurrencyHelper.format(product.price),
                  style: AppType.label.copyWith(
                    color: AppColors.moduleProduk,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs, vertical: 2),
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceMuted,
                      borderRadius: AppRadius.rXs,
                    ),
                    child: Text(
                      categoryName,
                      style: AppType.caption.copyWith(
                        fontSize: 10,
                        color: AppColors.textTertiary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
