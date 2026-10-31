import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/services/receipt_builder.dart';

final _openedAt = DateTime(2026, 11, 1, 8);
final _closedAt = DateTime(2026, 11, 1, 16);
final _shift = CashierShift(
  id: 'menu-shift',
  openedBy: 'Kasir Uji',
  openedAt: _openedAt,
  openingCash: 100000,
  createdAt: _openedAt,
  updatedAt: _closedAt,
);

Map<String, dynamic> _group(String kind, String label,
        Map<String, int> quantities) =>
    {
      'menu_kind': kind,
      'label': label,
      'quantity': quantities.values.fold<int>(0, (sum, qty) => sum + qty),
      'items': [
        for (final item in quantities.entries)
          {
            'product_id': null,
            'product_name': item.key,
            'quantity': item.value,
          },
      ],
    };

Map<String, dynamic> _report({bool empty = false}) => {
      'sales_count': empty ? 0 : 7,
      'sales_total': empty ? 0.0 : 500000.0,
      'opening_cash': 100000.0,
      'expected_cash': empty ? 100000.0 : 600000.0,
      'by_method': {
        'cash': {'count': empty ? 0 : 7, 'total': empty ? 0.0 : 500000.0},
      },
      'menu_items_by_kind': [
        _group('food', 'Makanan',
            empty ? {} : {'Nasi Goreng Resep Lama': 12, 'Roti Bakar': 3}),
        _group('beverage', 'Minuman', empty ? {} : {'Es Teh': 4}),
        _group('activity', 'Aktivitas', empty ? {} : {'ATV Overland': 2}),
        _group('other', 'Lainnya', empty ? {} : {'Biaya Parkir': 1}),
      ],
      'menu_quantity': empty ? 0 : 22,
    };

List<int> _print(int width, Map<String, dynamic> report,
        {String title = 'TUTUP KASIR'}) =>
    ReceiptBuilder(paperWidth: width).buildShiftReport(
      title: title,
      outletName: 'Outlet Uji',
      shift: _shift,
      report: report,
      closedAt: _closedAt,
      handoverToName: title == 'GANTI SHIFT' ? 'Kasir Berikut' : null,
    );

// Decode only the ESC/POS commands emitted by this report. Unexpected control
// bytes fail the test instead of silently disappearing from the assertions.
String _text(List<int> bytes) {
  final printable = <int>[];
  var offset = 0;
  while (offset < bytes.length) {
    final byte = bytes[offset];
    if (byte == 0x1b) {
      final command = bytes[offset + 1];
      expect([0x40, 0x45, 0x61], contains(command));
      offset += command == 0x40 ? 2 : 3;
    } else if (byte == 0x1d) {
      final command = bytes[offset + 1];
      expect([0x21, 0x56], contains(command));
      offset += command == 0x56 ? 4 : 3;
    } else {
      expect(byte == 0x0a || byte >= 0x20, isTrue);
      printable.add(byte);
      offset++;
    }
  }
  return latin1.decode(printable);
}

String _menuSection(String text, int width) {
  final start = text.indexOf('MENU TERJUAL\n');
  expect(start, greaterThanOrEqualTo(0));
  return text.substring(start, text.indexOf('-' * width, start));
}

void main() {
  for (final width in [32, 48]) {
    for (final title in ['TUTUP KASIR', 'GANTI SHIFT']) {
      test('$title prints grouped menu quantities on $width columns', () {
        final text = _text(_print(width, _report(), title: title));
        final menu = _menuSection(text, width);
        expect(text, contains('$title\n'));
        expect(menu, contains('Transaksi selesai pada shift ini\n'));
        if (title == 'GANTI SHIFT') {
          expect(text, contains('Serah ke: Kasir Berikut'));
        }
        expect(menu, contains(RegExp(r'Nama menu +Qty')));
        var previous = -1;
        for (final kind in ['Makanan', 'Minuman', 'Aktivitas', 'Lainnya']) {
          final index = menu.indexOf('\n$kind\n');
          expect(index, greaterThan(previous));
          previous = index;
        }
        for (final row in {
          'Nasi Goreng Resep Lama': 12,
          'Roti Bakar': 3,
          'Es Teh': 4,
          'ATV Overland': 2,
          'Biaya Parkir': 1,
          'Qty Makanan': 15,
          'Qty Minuman': 4,
          'Qty Aktivitas': 2,
          'Qty Lainnya': 1,
          'TOTAL QTY MENU': 22,
        }.entries) {
          expect(menu,
              contains(RegExp('${RegExp.escape(row.key)} +${row.value}\n')));
        }
        expect(menu.split('\n').every((line) => line.length <= width), isTrue);
        // Item units are separate from transaction count and drawer money.
        expect(text, contains(RegExp(r'Total Transaksi +7')));
        expect(text, contains(RegExp(r'Penjualan Shift +500\.000')));
        expect(text, contains(RegExp(r'KAS SEHARUSNYA +600\.000')));
      });
    }

    test('long names wrap without losing quantity on $width columns', () {
      const name = 'Paket Nasi Goreng Spesial dengan Telur dan Ayam '
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
      final report = _report(empty: true);
      (report['menu_items_by_kind'] as List)[0] =
          _group('food', 'Makanan', {name: 12345});
      report['menu_quantity'] = 12345;
      final menu = _menuSection(_text(_print(width, report)), width);
      final itemLines = menu
          .substring(menu.indexOf('\nMakanan\n') + '\nMakanan\n'.length,
              menu.indexOf('Qty Makanan'))
          .trim()
          .split('\n');
      expect(itemLines.length, greaterThan(1));
      expect(itemLines.first, matches(RegExp(r' +12345$')));
      itemLines[0] = itemLines.first.replaceFirst(RegExp(r' +12345$'), '');
      expect(itemLines.join('').replaceAll(' ', ''), name.replaceAll(' ', ''));
      expect(menu.split('\n').every((line) => line.length <= width), isTrue);
      expect(menu, contains(RegExp(r'Qty Makanan +12345')));
      expect(menu, contains(RegExp(r'TOTAL QTY MENU +12345')));
    });

    test('empty shift prints all four empty kinds on $width columns', () {
      final menu =
          _menuSection(_text(_print(width, _report(empty: true))), width);
      for (final kind in ['Makanan', 'Minuman', 'Aktivitas', 'Lainnya']) {
        expect(menu, contains('$kind\n-\n'));
        expect(menu, contains(RegExp('Qty $kind +0\n')));
      }
      expect(menu, contains(RegExp(r'TOTAL QTY MENU +0\n')));
    });

    test('legacy report does not imply zero menu sales on $width columns', () {
      final legacy = _report()
        ..remove('menu_items_by_kind')
        ..remove('menu_quantity');
      final text = _text(_print(width, legacy));
      expect(text, isNot(contains('MENU TERJUAL')));
      expect(text, isNot(contains('TOTAL QTY MENU')));
      expect(text, contains(RegExp(r'Penjualan Shift +500\.000')));
      expect(text, contains('KAS LACI'));
    });
  }

  test('menu names cannot insert lines or ESC/POS control commands', () {
    final report = _report(empty: true);
    (report['menu_items_by_kind'] as List)[1] = _group(
        'beverage', 'Minuman', {'Es\nTeh\tManis\r\x1b@\x1dVA\x03\x7f': 2});
    report['menu_quantity'] = 2;
    final bytes = _print(32, report);
    final menu = _menuSection(_text(bytes), 32);
    expect(menu, contains(RegExp(r'Es Teh Manis @ VA +2\n')));
    expect(bytes.where((byte) => byte == 0x1b).length,
        _print(32, _report(empty: true)).where((byte) => byte == 0x1b).length);
    expect(bytes.where((byte) => byte == 0x1d).length,
        _print(32, _report(empty: true)).where((byte) => byte == 0x1d).length);
  });

  test('unsupported Unicode cannot truncate into printer control bytes', () {
    final report = _report(empty: true);
    (report['menu_items_by_kind'] as List)[1] = _group('beverage', 'Minuman',
        {'Teh \u011b \u010a \u{1f964} Caf\u00e9': 2});
    report['menu_quantity'] = 2;
    final bytes = _print(32, report);
    final menu = _menuSection(_text(bytes), 32);
    expect(menu, contains(RegExp(r'Teh \? \? \? Café +2\n')));
    final emptyBytes = _print(32, _report(empty: true));
    for (final control in [0x1b, 0x1d, 0x0a]) {
      expect(bytes.where((byte) => byte == control).length,
          emptyBytes.where((byte) => byte == control).length);
    }
  });
}
