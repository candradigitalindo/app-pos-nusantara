import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/models.dart';
import 'theme/theme.dart';
import 'services/auth_service.dart';
import 'services/data_retention_service.dart';
import 'services/device_role_service.dart';
import 'services/station_api_client.dart';
import 'screens/login/login_screen.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/role/role_selector_screen.dart';
import 'screens/station/station_screen.dart';
import 'screens/station/station_login_screen.dart';
import 'screens/station/cashier_station_screen.dart';
import 'screens/station/station_setup_screen.dart';

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});

class AuthState {
  final User? user;
  final bool isLoading;
  final bool isChecked;

  const AuthState({this.user, this.isLoading = false, this.isChecked = false});

  bool get isLoggedIn => user != null;

  AuthState copyWith({User? user, bool? isLoading, bool? isChecked}) {
    return AuthState(
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      isChecked: isChecked ?? this.isChecked,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService = AuthService();

  AuthNotifier() : super(const AuthState()) {
    checkSession();
    _runRetention();
  }

  /// Run data retention cleanup in background on app start
  void _runRetention() {
    Future.microtask(() async {
      try {
        final service = DataRetentionService();
        await service.runIfNeeded();
      } catch (_) {
        // Silent fail - don't block app startup
      }
    });
  }

  Future<void> checkSession() async {
    state = state.copyWith(isLoading: true);
    final loggedIn = await _authService.checkSession();
    state = AuthState(
      user: loggedIn ? _authService.currentUser : null,
      isLoading: false,
      isChecked: true,
    );
  }

  Future<void> login(String username, String pin) async {
    state = state.copyWith(isLoading: true);
    try {
      final user = await _authService.login(username, pin);
      state = AuthState(user: user, isLoading: false, isChecked: true);
    } catch (e) {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  /// Login hanya dengan PIN — masuk sebagai user yang PIN-nya cocok.
  Future<void> loginByPin(String pin) async {
    state = state.copyWith(isLoading: true);
    try {
      final user = await _authService.loginByPin(pin);
      state = AuthState(user: user, isLoading: false, isChecked: true);
    } catch (e) {
      state = state.copyWith(isLoading: false);
      rethrow;
    }
  }

  Future<void> logout() async {
    await _authService.logout();
    state = const AuthState(isChecked: true);
  }
}

class PosRestoApp extends StatelessWidget {
  const PosRestoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        title: 'POS Resto',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const RootGate(),
      ),
    );
  }
}

/// Router awal berdasarkan peran perangkat:
/// belum dipilih → pemilih peran; station → gerbang station; main pos → login.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  DeviceRole? _role;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final role = await DeviceRoleService.instance.getRole();
    if (!mounted) return;
    setState(() {
      _role = role;
      _loading = false;
    });
  }

  /// Kembali ke halaman pemilihan peran (mis. Station salah pilih / pindah
  /// perangkat). Peran dibersihkan lalu RootGate memuat ulang → RoleSelector.
  Future<void> _resetRole() async {
    await DeviceRoleService.instance.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_role == null) {
      return RoleSelectorScreen(onSelected: _load);
    }
    if (_role == DeviceRole.station) {
      return StationGate(onExitRole: _resetRole);
    }
    return const AuthWrapper();
  }
}

/// Gerbang mode Station: kalau sudah ada Main POS tersimpan & hidup → langsung
/// ordering; kalau belum → layar setup koneksi.
class StationGate extends StatefulWidget {
  /// Kembali ke pemilihan peran perangkat (dipicu dari setup/login station).
  final VoidCallback onExitRole;
  const StationGate({super.key, required this.onExitRole});

  @override
  State<StationGate> createState() => _StationGateState();
}

class _StationGateState extends State<StationGate> {
  bool _loading = true;
  bool _connected = false;
  Map<String, dynamic>? _user; // user login station (menentukan tampilan)

  @override
  void initState() {
    super.initState();
    // Sesi ditolak Main POS (401, mis. Main POS restart) → paksa kembali ke
    // LOGIN otomatis, jadi station tak pernah nyangkut di pemesanan.
    StationApiClient.instance.onUnauthorized = () {
      if (mounted && _user != null) setState(() => _user = null);
    };
    _check();
  }

  @override
  void dispose() {
    StationApiClient.instance.onUnauthorized = null;
    super.dispose();
  }

  Future<void> _check() async {
    final api = StationApiClient.instance;
    final saved = await api.loadSaved();
    var ok = false;
    if (saved != null) {
      final server = await api.ping(saved);
      if (server != null) {
        ok = true;
        // Pastikan outlet_code tersimpan (untuk auto-rediscovery saat IP ganti)
        await api.save(server.baseUrl, outletCode: server.outletCode);
      } else {
        // IP tersimpan tak merespons → coba temukan di IP baru (DHCP berubah)
        ok = await api.rediscover();
      }
    }
    if (!mounted) return;
    setState(() {
      _connected = ok;
      _loading = false;
    });
  }

  /// Setup berhasil terhubung → tampilkan LOGIN (bukan langsung ke pemesanan).
  /// Token baru diperoleh saat login PIN; tanpa itu API Main POS menolak.
  void _onConnected() => setState(() => _connected = true);

  /// Ganti Main POS: lepas koneksi & sesi, kembali ke setup → login.
  Future<void> _changeServer() async {
    StationApiClient.instance.clearToken();
    await StationApiClient.instance.clear();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _user = null;
    });
  }

  /// Logout station → kembali ke LOGIN PIN (token dibuang).
  void _logout() {
    StationApiClient.instance.clearToken();
    setState(() => _user = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Alur wajib: (1) belum terhubung → setup, (2) terhubung tapi belum login
    // → login PIN (dapat token), (3) sudah login → tampilan sesuai peran.
    if (!_connected) {
      return StationSetupScreen(
        onConnected: _onConnected,
        onBackToRole: widget.onExitRole,
      );
    }
    if (_user == null) {
      return StationLoginScreen(
        onLoggedIn: (u) => setState(() => _user = u),
        onBackToRole: widget.onExitRole,
      );
    }
    final role = (_user!['role'] as String? ?? 'waiter').toLowerCase();
    final isCashier = role == 'cashier' ||
        role == 'admin' ||
        role == 'manager' ||
        role == 'svp';
    if (isCashier) {
      return CashierStationScreen(user: _user!, onLogout: _logout);
    }
    return StationScreen(
      user: _user!,
      onLogout: _logout,
      onChangeServer: _changeServer,
    );
  }
}

class AuthWrapper extends ConsumerWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);

    if (!authState.isChecked || authState.isLoading) {
      return const _BrandSplash();
    }

    if (authState.isLoggedIn) {
      return const DashboardScreen();
    }

    return const LoginScreen();
  }
}

/// Splash brand saat memeriksa sesi — logo gradasi + glow ala iOS.
class _BrandSplash extends StatelessWidget {
  const _BrandSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: AppColors.canvasGradient,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: AppColors.brandGradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: AppRadius.rXl,
                  boxShadow: AppShadows.glow(AppColors.brand, strength: 0.45),
                ),
                child: const Icon(Icons.restaurant_menu_rounded,
                    size: 48, color: Colors.white),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text('POS Resto', style: AppType.h1),
              const SizedBox(height: AppSpacing.xs),
              Text('Point of Sale System',
                  style: AppType.caption.copyWith(color: AppColors.textTertiary)),
              const SizedBox(height: AppSpacing.xl),
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
