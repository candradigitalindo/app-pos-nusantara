import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/models.dart';
import '../../services/auth_service.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final _auth = AuthService();
  List<User>? _users;

  static const _accent = AppColors.moduleProduk;

  static const _roleLabels = {
    'admin': 'Admin',
    'manager': 'Manager',
    'svp': 'SVP',
    'cashier': 'Kasir',
    'waiter': 'Waiter',
    'kitchen': 'Dapur',
    'bar': 'Bar',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await _auth.getUsers();
    if (mounted) setState(() => _users = u);
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    showAppSnack(context, msg, isError: error);
  }

  void _showForm({User? existing}) {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.fullName ?? '');
    final userCtrl = TextEditingController(text: existing?.username ?? '');
    final pinCtrl = TextEditingController();
    var role = existing?.role ?? 'cashier';
    String? error;

    showAppModal(
      context,
      title: isEdit ? 'Ubah User' : 'Tambah User',
      icon: isEdit ? Icons.manage_accounts_rounded : Icons.person_add_rounded,
      accent: _accent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: nameCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nama Lengkap'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: userCtrl,
              enabled: !isEdit, // username tak diubah saat edit
              decoration: InputDecoration(
                labelText: 'Username',
                helperText: isEdit ? 'Username tidak dapat diubah' : null,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: 'Peran'),
              items: AuthService.roles
                  .map((r) => DropdownMenuItem(
                        value: r,
                        child: Text(_roleLabels[r] ?? r),
                      ))
                  .toList(),
              onChanged: (v) => setS(() => role = v ?? role),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: InputDecoration(
                labelText: isEdit ? 'PIN Baru (opsional)' : 'PIN (4 digit)',
                counterText: '',
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(error!,
                  style: AppType.caption.copyWith(color: AppColors.danger)),
            ],
            const SizedBox(height: AppSpacing.md),
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
                    accent: _accent,
                    onPressed: () async {
                      try {
                        if (isEdit) {
                          await _auth.updateUser(
                            id: existing.id,
                            fullName: nameCtrl.text,
                            role: role,
                            newPin: pinCtrl.text,
                          );
                        } else {
                          await _auth.registerUser(
                            username: userCtrl.text,
                            fullName: nameCtrl.text,
                            role: role,
                            pin: pinCtrl.text,
                          );
                        }
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        _snack(isEdit ? 'User diperbarui' : 'User ditambahkan');
                        await _load();
                      } catch (e) {
                        setS(() =>
                            error = e.toString().replaceFirst('Exception: ', ''));
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleActive(User u) async {
    await _auth.setUserActive(u.id, u.isActive != 1);
    await _load();
  }

  Future<void> _confirmDelete(User u) async {
    final ok = await showAppConfirm(
      context,
      title: 'Hapus User?',
      message:
          'Hapus akun "${u.fullName}" (@${u.username})? Tindakan ini permanen.',
      confirmText: 'Hapus',
      icon: Icons.person_remove_rounded,
      destructive: true,
    );
    if (!ok) return;
    try {
      await _auth.deleteUser(u.id);
      _snack('User "${u.fullName}" dihapus');
      await _load();
    } catch (e) {
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'admin':
        return AppColors.danger;
      case 'manager':
        return AppColors.accent;
      case 'svp':
        return AppColors.moduleMeja;
      case 'cashier':
        return AppColors.moduleKasir;
      case 'waiter':
        return AppColors.moduleProduk;
      case 'kitchen':
        return AppColors.moduleDapur;
      case 'bar':
        return AppColors.info;
      default:
        return AppColors.textTertiary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    return Scaffold(
      body: AppBackground(
        child: Column(
          children: [
            AppPageHeader(
              title: 'Manajemen User',
              subtitle: 'Kelola akun & peran',
              icon: Icons.group_rounded,
              accent: _accent,
              actions: [
                AppButton(
                  label: 'Tambah',
                  icon: Icons.person_add_rounded,
                  size: AppButtonSize.small,
                  expanded: false,
                  accent: _accent,
                  onPressed: () => _showForm(),
                ),
              ],
            ),
            Expanded(
              child: users == null
                  ? const AppLoader(label: 'Memuat user...')
                  : users.isEmpty
                      ? EmptyState(
                          icon: Icons.group_rounded,
                          title: 'Belum ada user',
                          message: 'Tambahkan akun kasir, waiter, atau manager.',
                          actionLabel: 'Tambah User',
                          onAction: () => _showForm(),
                          accent: _accent,
                        )
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(
                              context.pagePadX, AppSpacing.md,
                              context.pagePadX, AppSpacing.xl),
                          itemCount: users.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (_, i) => _userCard(users[i]),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _userCard(User u) {
    final active = u.isActive == 1;
    final roleColor = _roleColor(u.role);
    final initial = u.fullName.isNotEmpty
        ? u.fullName.characters.first.toUpperCase()
        : '?';

    return AppCard(
      onTap: () => _showForm(existing: u),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.soft(roleColor, 0.14),
              borderRadius: AppRadius.rSm,
            ),
            child: Text(initial,
                style: TextStyle(
                    color: roleColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 18)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  u.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.title.copyWith(
                    color: active ? AppColors.textPrimary : AppColors.textTertiary,
                    decoration:
                        active ? null : TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(
                      child: Text('@${u.username}',
                          style: AppType.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    StatusPill(
                      label: _roleLabels[u.role] ?? u.role,
                      color: roleColor,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Switch(
            value: active,
            onChanged: (_) => _toggleActive(u),
          ),
          AppIconButton(
            icon: Icons.delete_outline_rounded,
            color: AppColors.danger,
            tooltip: 'Hapus User',
            onPressed: () => _confirmDelete(u),
          ),
        ],
      ),
    );
  }
}
