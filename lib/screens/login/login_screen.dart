import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app.dart';
import '../../config/app_config.dart';
import '../../theme/theme.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  String _pinCode = '';
  String? _error;
  bool _loading = false;
  late AnimationController _shakeController;
  // Versi + build code asli (versionCode). Default dari AppConfig sebelum termuat.
  String _versionLabel = 'v${AppConfig.version}';

  // Aksen putih glass di atas latar hijau majoo.
  static const _accent = Colors.white;
  static const _glassBorder = Color(0x33FFFFFF);

  Future<void> _submitPin() async {
    if (_pinCode.length != 4 || _loading) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Login berbasis PIN: masuk sebagai user yang PIN-nya cocok.
      await ref.read(authProvider.notifier).loginByPin(_pinCode);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _pinCode = '';
          _loading = false;
        });
        _shakeController.forward(from: 0).then((_) => _shakeController.reverse());
      }
    }
  }

  void _tapPin(int digit) {
    if (_pinCode.length >= 4 || _loading) return;
    setState(() {
      _error = null;
      _pinCode += digit.toString();
    });
    if (_pinCode.length == 4) {
      _submitPin();
    }
  }

  void _deletePin() {
    if (_pinCode.isEmpty) return;
    setState(() {
      _pinCode = _pinCode.substring(0, _pinCode.length - 1);
      _error = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() =>
          _versionLabel = 'v${pkg.version} · build ${pkg.buildNumber}');
    } catch (_) {
      // biarkan default dari AppConfig
    }
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = context.isPhone;
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: AppColors.greenGradient,
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
                  _buildBranding(compact),
                  SizedBox(height: compact ? AppSpacing.xl : AppSpacing.xxl),
                  _buildLoginCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBranding(bool compact) {
    return Column(
      children: [
        Container(
          width: compact ? 64 : 76,
          height: compact ? 64 : 76,
          decoration: BoxDecoration(
            color: AppColors.soft(Colors.white, 0.95),
            borderRadius: AppRadius.rXl,
            border: Border.all(color: AppColors.soft(Colors.white, 0.6)),
            boxShadow: AppShadows.glow(AppColors.greenDark, strength: 0.4),
          ),
          child: Icon(Icons.restaurant_menu_rounded,
              color: AppColors.green, size: compact ? 32 : 38),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Nusantara POS',
          style: TextStyle(
            fontSize: compact ? 24 : 28,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Point of Sale System',
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
                'Masuk dengan PIN',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
              ),
              const SizedBox(height: 4),
              Text(
                'Masukkan 4 digit PIN Anda',
                style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.5)),
              ),
              const SizedBox(height: AppSpacing.xl),

              _buildPinDots(),
              const SizedBox(height: AppSpacing.md),

              if (_error != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.15),
                    borderRadius: AppRadius.rSm,
                    border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                        color: Color(0xFFFCA5A5), fontSize: 13, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.center,
                  ),
                ),

              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(strokeWidth: 3, color: _accent),
                  ),
                )
              else
                _buildNumpad(),

              const SizedBox(height: AppSpacing.lg),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinDots() {
    return AnimatedBuilder(
      animation: _shakeController,
      builder: (context, child) {
        // Getaran horizontal saat PIN salah.
        final dx = math.sin(_shakeController.value * math.pi * 4) * 10;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(4, (index) {
          final filled = index < _pinCode.length;
          return AnimatedContainer(
            duration: AppMotion.fast,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            width: filled ? 18 : 15,
            height: filled ? 18 : 15,
            decoration: BoxDecoration(
              color: filled ? _accent : Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: filled ? null : Border.all(color: Colors.white.withValues(alpha: 0.25)),
              boxShadow: filled
                  ? [BoxShadow(color: _accent.withValues(alpha: 0.6), blurRadius: 12)]
                  : null,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildNumpad() {
    return Column(
      children: [
        for (var row = 0; row < 3; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: List.generate(3, (col) {
                final digit = row * 3 + col + 1;
                return Expanded(child: _buildNumButton(digit.toString()));
              }),
            ),
          ),
        Row(
          children: [
            const Expanded(child: SizedBox()),
            Expanded(child: _buildNumButton('0')),
            Expanded(child: _buildKeyButton(child: Icon(Icons.backspace_rounded,
                color: AppColors.soft(Colors.white, 0.6), size: 24), onTap: _deletePin, subtle: true)),
          ],
        ),
      ],
    );
  }

  Widget _buildNumButton(String text) => _buildKeyButton(
        onTap: () => _tapPin(int.parse(text)),
        child: Text(
          text,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      );

  Widget _buildKeyButton({
    required Widget child,
    required VoidCallback onTap,
    bool subtle = false,
  }) {
    final height = context.isPhone ? 54.0 : 60.0;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxs),
      child: Material(
        color: Colors.transparent,
        borderRadius: AppRadius.rMd,
        child: InkWell(
          borderRadius: AppRadius.rMd,
          onTap: onTap,
          splashColor: _accent.withValues(alpha: 0.2),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: subtle ? 0.04 : 0.08),
              borderRadius: AppRadius.rMd,
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text('Koneksi aman',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.4))),
            ],
          ),
          Text(_versionLabel,
              style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.4))),
        ],
      ),
    );
  }
}
