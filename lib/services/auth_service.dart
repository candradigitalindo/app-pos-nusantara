import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../database/database.dart';
import '../models/models.dart';
import '../utils/ulid.dart';

class AuthService {
  final AppDatabase _db = AppDatabase.instance;

  User? _currentUser;
  User? get currentUser => _currentUser;
  bool get isLoggedIn => _currentUser != null;

  /// Login with username and PIN (4 digit)
  Future<User> login(String username, String pin) async {
    final results = await _db.query(
      'users',
      where: 'username = ? AND is_active = 1',
      whereArgs: [username],
    );

    if (results.isEmpty) {
      throw Exception('Username tidak ditemukan');
    }

    final user = User.fromMap(results.first);

    // Verifikasi hash PIN. Jalur backdoor 'dummyhash' (menerima 1234 tanpa
    // hash sungguhan) DIHAPUS — akun seed dimigrasi ke hash asli di DB v10.
    final pinHash = _hashPin(pin);
    if (user.passwordHash != pinHash) {
      throw Exception('PIN salah');
    }

    _currentUser = user;
    await _saveSession(user);
    return user;
  }

  /// Login BERBASIS PIN: temukan user aktif yang PIN-nya cocok, lalu masuk
  /// sebagai user tersebut. PIN unik antar user dijamin saat register/update.
  Future<User> loginByPin(String pin) async {
    final pinHash = _hashPin(pin);
    final rows = await _db.query('users', where: 'is_active = 1');
    for (final m in rows) {
      if ((m['password_hash'] as String) == pinHash) {
        final u = User.fromMap(m);
        _currentUser = u;
        await _saveSession(u);
        return u;
      }
    }
    throw Exception('PIN salah');
  }

  /// Logout
  Future<void> logout() async {
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_user_id');
  }

  /// Check if there's an active session
  Future<bool> checkSession() async {
    final userId = await _loadSession();
    if (userId == null) return false;

    final results = await _db.query(
      'users',
      where: 'id = ? AND is_active = 1',
      whereArgs: [userId],
    );

    if (results.isEmpty) {
      await logout();
      return false;
    }

    _currentUser = User.fromMap(results.first);
    return true;
  }

  // ── Manajemen User (admin) ──────────────────────────────────────────────────

  static const List<String> roles = [
    'admin',
    'manager',
    'svp',
    'cashier',
    'waiter',
    'kitchen',
    'bar',
  ];

  /// Peran yang berwenang mengotorisasi VOID transaksi (selain PIN void bersama).
  static const List<String> voidAuthorizedRoles = ['admin', 'manager', 'svp'];

  /// Daftar semua user (untuk layar manajemen).
  Future<List<User>> getUsers() async {
    final db = await _db.database;
    final rows = await db.query('users', orderBy: 'is_active DESC, full_name ASC');
    return rows.map((m) => User.fromMap(m)).toList();
  }

  /// Apakah [pin] akan membuka akun ber-hash [existingHash]?
  /// Dipakai untuk menjaga PIN unik antar user (login berbasis PIN).
  bool _pinMatches(String pin, String existingHash) =>
      existingHash == _hashPin(pin);

  /// Lempar error bila [pin] sudah dipakai user lain (selain [exceptId]).
  Future<void> _ensurePinUnique(String pin, {String? exceptId}) async {
    final db = await _db.database;
    final rows = await db.query('users', columns: ['id', 'password_hash']);
    for (final m in rows) {
      if (exceptId != null && m['id'] == exceptId) continue;
      if (_pinMatches(pin, m['password_hash'] as String)) {
        throw Exception('PIN sudah dipakai user lain');
      }
    }
  }

  /// Buat akun baru. PIN 4 digit, username unik, PIN unik.
  Future<User> registerUser({
    required String username,
    required String fullName,
    required String role,
    required String pin,
  }) async {
    final uname = username.trim().toLowerCase();
    if (uname.isEmpty) throw Exception('Username wajib diisi');
    if (fullName.trim().isEmpty) throw Exception('Nama wajib diisi');
    if (!roles.contains(role)) throw Exception('Peran tidak valid');
    if (pin.length != 4 || int.tryParse(pin) == null) {
      throw Exception('PIN harus 4 digit angka');
    }
    final db = await _db.database;
    final exists = await db.query('users',
        where: 'username = ?', whereArgs: [uname], limit: 1);
    if (exists.isNotEmpty) throw Exception('Username sudah dipakai');
    await _ensurePinUnique(pin); // PIN tidak boleh sama dengan user lain

    final now = DateTime.now();
    final user = User(
      id: _ulid(),
      username: uname,
      passwordHash: _hashPin(pin),
      fullName: fullName.trim(),
      role: role,
      isActive: 1,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert('users', user.toMap());
    return user;
  }

  /// Ubah data user. PIN baru opsional (kosong = tidak diubah).
  Future<void> updateUser({
    required String id,
    required String fullName,
    required String role,
    String? newPin,
  }) async {
    if (fullName.trim().isEmpty) throw Exception('Nama wajib diisi');
    if (!roles.contains(role)) throw Exception('Peran tidak valid');
    final data = <String, dynamic>{
      'full_name': fullName.trim(),
      'role': role,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (newPin != null && newPin.isNotEmpty) {
      if (newPin.length != 4 || int.tryParse(newPin) == null) {
        throw Exception('PIN harus 4 digit angka');
      }
      await _ensurePinUnique(newPin, exceptId: id); // unik selain dirinya
      data['password_hash'] = _hashPin(newPin);
    }
    final db = await _db.database;
    await db.update('users', data, where: 'id = ?', whereArgs: [id]);
  }

  /// Hapus akun. Tidak boleh menghapus user terakhir atau akun yang sedang login.
  Future<void> deleteUser(String id) async {
    final db = await _db.database;
    final all = await db.query('users', columns: ['id']);
    if (all.length <= 1) {
      throw Exception('Tidak bisa hapus — minimal harus ada 1 user');
    }
    final currentId = await _loadSession();
    if (currentId == id) {
      throw Exception('Tidak bisa hapus akun yang sedang login');
    }
    await db.delete('users', where: 'id = ?', whereArgs: [id]);
  }

  /// Aktif/nonaktifkan user (nonaktif tak bisa login).
  Future<void> setUserActive(String id, bool active) async {
    final db = await _db.database;
    await db.update(
      'users',
      {'is_active': active ? 1 : 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  String _ulid() => Ulid.generate();

  /// Ambil user yang sedang login dari sesi (current_user_id di prefs) tanpa
  /// perlu login ulang. Dipakai mis. untuk mencatat siapa pembuat order.
  Future<User?> currentUserFromSession() async {
    if (_currentUser != null) return _currentUser;
    final userId = await _loadSession();
    if (userId == null) return null;
    final results = await _db.query(
      'users',
      where: 'id = ? AND is_active = 1',
      whereArgs: [userId],
    );
    if (results.isEmpty) return null;
    _currentUser = User.fromMap(results.first);
    return _currentUser;
  }

  String _hashPin(String pin) {
    final bytes = utf8.encode(pin);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<void> _saveSession(User user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_user_id', user.id);
  }

  Future<String?> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user_id');
  }
}
