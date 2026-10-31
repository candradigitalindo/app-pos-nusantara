// Byte perintah buka laci kasir (ESC/POS `ESC p m t1 t2`).
//
// Nilai t1/t2 bersatuan 2 ms dan hanya muat 1 byte (maks 255 → 510 ms), jadi
// konversi milidetik → satuan printer harus dijaga: salah clamp = laci tidak
// bereaksi (pulsa 0) atau byte meluber dan merusak perintah berikutnya.

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/services/cash_drawer_service.dart';

void main() {
  group('CashDrawerService.kickBytes', () {
    test('default: pin 2, pulsa 100ms', () {
      // 100ms → 50 satuan ON, OFF = 2× ON.
      expect(CashDrawerService.kickBytes(),
          [0x1B, 0x70, 0x00, 50, 100]);
    });

    test('pin 5 memakai m = 1', () {
      expect(CashDrawerService.kickBytes(pin: 5)[2], 0x01);
      expect(CashDrawerService.kickBytes(pin: 2)[2], 0x00);
    });

    test('pulsa panjang tetap muat 1 byte (clamp 255)', () {
      final b = CashDrawerService.kickBytes(pulseMs: 300);
      expect(b[3], 150);
      expect(b[4], 255); // 300 dipangkas ke 255, bukan meluber jadi 44
      expect(b.every((v) => v >= 0 && v <= 255), isTrue);
    });

    test('pulsa terlalu pendek tetap menghasilkan pulsa nyata', () {
      // 0/1 ms membulat ke 0 satuan → laci tak akan terpicu; harus jadi 1.
      expect(CashDrawerService.kickBytes(pulseMs: 0)[3], 1);
      expect(CashDrawerService.kickBytes(pulseMs: 1)[3], 1);
    });

    test('semua pilihan durasi di Pengaturan menghasilkan byte sah', () {
      for (final ms in CashDrawerSettings.pulseChoices) {
        final b = CashDrawerService.kickBytes(pulseMs: ms);
        expect(b.length, 5);
        expect(b[3], greaterThan(0));
        expect(b.every((v) => v <= 255), isTrue, reason: 'pulsa $ms ms');
      }
    });
  });
}
