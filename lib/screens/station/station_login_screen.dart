import 'package:flutter/material.dart';

import '../../services/station_api_client.dart';
import '../../theme/theme.dart';
import '../../widgets/ui/ui.dart';

/// Login PIN di perangkat Station. Memverifikasi ke Main POS lalu menyerahkan
/// data user {id, full_name, username, role} ke [onLoggedIn]. Role menentukan
/// tampilan berikutnya (kasir vs waiter).
class StationLoginScreen extends StatefulWidget {
  final void Function(Map<String, dynamic> user) onLoggedIn;

  /// Kembali ke halaman pemilihan peran perangkat (opsional).
  final VoidCallback? onBackToRole;
  const StationLoginScreen({
    super.key,
    required this.onLoggedIn,
    this.onBackToRole,
  });

  @override
  State<StationLoginScreen> createState() => _StationLoginScreenState();
}

class _StationLoginScreenState extends State<StationLoginScreen> {
  String _pin = '';
  bool _busy = false;
  String? _error;

  // Warna khusus konteks gelap login. SECONDARY gold untuk indikator PIN —
  // hangat & mewah di atas forest gelap (tombol konfirmasi tetap hijau).
  static const _accent = AppColors.accent;
  static const _glassBorder = Color(0x1FFFFFFF);

  void _tap(String d) {
    if (_busy || _pin.length >= 8) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _del() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await StationApiClient.instance.authPin(_pin);
      if (!mounted) return;
      if (user == null) {
        setState(() {
          _error = 'PIN salah';
          _pin = '';
          _busy = false;
        });
        return;
      }
      widget.onLoggedIn(user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Gagal menghubungi Main POS';
        _busy = false;
      });
    }
  }

  /// Konfirmasi lalu kembali ke halaman pemilihan peran perangkat.
  Future<void> _confirmBackToRole() async {
    final ok = await showAppConfirm(
      context,
      title: 'Ganti peran perangkat?',
      message: 'Perangkat akan kembali ke halaman pemilihan peran '
          '(Kasir Utama / Station). Koneksi ke Main POS saat ini dilepas.',
      confirmText: 'Ganti Peran',
      icon: Icons.swap_horiz_rounded,
    );
    if (ok) widget.onBackToRole?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: AppColors.sidebarGradient,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildBranding(context),
                  const SizedBox(height: AppSpacing.xl),
                  _buildLoginCard(),
                  if (widget.onBackToRole != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    TextButton.icon(
                      onPressed: _busy ? null : _confirmBackToRole,
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: const Text('Ganti peran perangkat'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.soft(Colors.white, 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBranding(BuildContext context) {
    final compact = context.isPhone;
    return Column(
      children: [
        Container(
          width: compact ? 64 : 72,
          height: compact ? 64 : 72,
          decoration: BoxDecoration(
            color: AppColors.soft(Colors.white, 0.95),
            borderRadius: AppRadius.rXl,
            border: Border.all(color: AppColors.soft(Colors.white, 0.6)),
            boxShadow: AppShadows.glow(AppColors.greenDark, strength: 0.4),
          ),
          child: Icon(Icons.point_of_sale_rounded,
              color: AppColors.green, size: compact ? 32 : 36),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Login Station',
          style: TextStyle(
            fontSize: compact ? 22 : 26,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Peran menentukan tampilan',
          style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.6)),
        ),
      ],
    );
  }

  Widget _buildLoginCard() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: ClipRRect(
        borderRadius: AppRadius.rXxl,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: AppRadius.rXxl,
            border: Border.all(color: _glassBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 40,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Masukkan PIN',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
              ),
              const SizedBox(height: 4),
              Text(
                'Verifikasi PIN ke Main POS',
                style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.5)),
              ),
              const SizedBox(height: AppSpacing.xl),
              _buildPinDots(),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 24,
                child: Center(
                  child: _error != null
                      ? Text(
                          _error!,
                          style: const TextStyle(
                            color: Color(0xFFFCA5A5),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : (_busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.4, color: _accent),
                            )
                          : null),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _PinPad(onTap: _tap, onDelete: _del, onSubmit: _submit),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinDots() {
    final count = _pin.isEmpty ? 4 : _pin.length;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (index) {
        final filled = index < _pin.length;
        return AnimatedContainer(
          duration: AppMotion.fast,
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          width: filled ? 18 : 15,
          height: filled ? 18 : 15,
          decoration: BoxDecoration(
            color: filled ? _accent : Colors.white.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border:
                filled ? null : Border.all(color: Colors.white.withValues(alpha: 0.25)),
            boxShadow: filled
                ? [BoxShadow(color: _accent.withValues(alpha: 0.6), blurRadius: 12)]
                : null,
          ),
        );
      }),
    );
  }
}

class _PinPad extends StatelessWidget {
  final void Function(String) onTap;
  final VoidCallback onDelete;
  final VoidCallback onSubmit;
  const _PinPad(
      {required this.onTap, required this.onDelete, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: [
                for (final d in row)
                  Expanded(
                    child: _KeyButton(
                      onTap: () => onTap(d),
                      child: Text(
                        d,
                        style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _KeyButton(
                onTap: onDelete,
                subtle: true,
                child: Icon(Icons.backspace_rounded,
                    color: AppColors.soft(Colors.white, 0.6), size: 24),
              ),
            ),
            Expanded(
              child: _KeyButton(
                onTap: () => onTap('0'),
                child: const Text(
                  '0',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                ),
              ),
            ),
            Expanded(
              child: _KeyButton(
                onTap: onSubmit,
                accent: true,
                child: const Icon(Icons.check_rounded,
                    color: AppColors.green, size: 26),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _KeyButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool subtle;
  final bool accent;
  const _KeyButton({
    required this.child,
    required this.onTap,
    this.subtle = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final height = context.isPhone ? 54.0 : 60.0;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxs),
      child: Material(
        color: Colors.transparent,
        borderRadius: AppRadius.rMd,
        child: InkWell(
          borderRadius: AppRadius.rMd,
          onTap: onTap,
          splashColor: Colors.white.withValues(alpha: 0.25),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              // Tombol konfirmasi = putih solid (aksi utama) di atas latar hijau.
              color: accent
                  ? AppColors.soft(Colors.white, 0.95)
                  : Colors.white.withValues(alpha: subtle ? 0.04 : 0.08),
              borderRadius: AppRadius.rMd,
              border: accent
                  ? null
                  : Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
