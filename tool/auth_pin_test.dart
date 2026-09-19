// Verifikasi logika PIN: ganti PIN bisa login, PIN unik ditegakkan.
// Mereplikasi logika AuthService (hash + register/update + loginByPin).
// Jalankan: dart run tool/auth_pin_test.dart
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late Database db;
String hashPin(String pin) => sha256.convert(utf8.encode(pin)).toString();
bool verifyBcrypt(String pin, String hash) =>
    hash.contains('dummyhash') && pin == '1234';
bool pinMatches(String pin, String hash) =>
    hash == hashPin(pin) || verifyBcrypt(pin, hash);

Future<void> ensurePinUnique(String pin, {String? exceptId}) async {
  final rows = await db.query('users', columns: ['id', 'password_hash']);
  for (final m in rows) {
    if (exceptId != null && m['id'] == exceptId) continue;
    if (pinMatches(pin, m['password_hash'] as String)) {
      throw Exception('PIN sudah dipakai user lain');
    }
  }
}

Future<String> registerUser(String username, String pin) async {
  await ensurePinUnique(pin);
  final id = 'U-$username';
  await db.insert('users', {
    'id': id, 'username': username, 'password_hash': hashPin(pin),
    'full_name': username, 'role': 'cashier', 'is_active': 1,
  });
  return id;
}

Future<void> updatePin(String id, String newPin) async {
  await ensurePinUnique(newPin, exceptId: id);
  await db.update('users', {'password_hash': hashPin(newPin)},
      where: 'id = ?', whereArgs: [id]);
}

Future<String> loginByPin(String pin) async {
  final ph = hashPin(pin);
  final rows = await db.query('users', where: 'is_active = 1');
  for (final m in rows) {
    if ((m['password_hash'] as String) == ph) return m['id'] as String;
  }
  for (final m in rows) {
    if (verifyBcrypt(pin, m['password_hash'] as String)) return m['id'] as String;
  }
  throw Exception('PIN salah');
}

void check(String label, bool ok) =>
    print('${ok ? "LULUS ✅" : "GAGAL ❌"}  $label');

Future<void> main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''CREATE TABLE users(id TEXT PRIMARY KEY, username TEXT,
      password_hash TEXT, full_name TEXT, role TEXT, is_active INTEGER)''');
  // Seed admin (dummyhash menerima 1234)
  await db.insert('users', {
    'id': 'admin', 'username': 'admin',
    'password_hash': r'$2a$10$dummyhashforcandradigitalpos',
    'full_name': 'Manager', 'role': 'manager', 'is_active': 1,
  });

  print('=== UJI LOGIKA PIN ===\n');

  // Default admin login dengan 1234
  check('login admin default (1234)', await loginByPin('1234') == 'admin');

  // Buat user budi PIN 5678, login
  final budi = await registerUser('budi', '5678');
  check('login budi (5678) setelah dibuat', await loginByPin('5678') == budi);

  // GANTI PIN budi -> 9999, lalu login dengan PIN BARU
  await updatePin(budi, '9999');
  check('login budi dengan PIN BARU (9999)', await loginByPin('9999') == budi);

  // PIN lama tidak berlaku lagi
  var lamaDitolak = false;
  try {
    await loginByPin('5678');
  } catch (_) {
    lamaDitolak = true;
  }
  check('PIN lama (5678) ditolak setelah diganti', lamaDitolak);

  // PIN unik: tak boleh buat user dengan PIN 9999 (sudah dipakai budi)
  var unikDitegakkan = false;
  try {
    await registerUser('andi', '9999');
  } catch (_) {
    unikDitegakkan = true;
  }
  check('buat user PIN duplikat (9999) ditolak', unikDitegakkan);

  // PIN 1234 tak boleh dipakai user lain selama admin masih default
  var pin1234Ditolak = false;
  try {
    await registerUser('cici', '1234');
  } catch (_) {
    pin1234Ditolak = true;
  }
  check('PIN 1234 dipakai saat admin default ditolak', pin1234Ditolak);

  await db.close();
}
