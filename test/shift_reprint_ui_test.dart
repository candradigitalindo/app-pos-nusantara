import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/screens/cashier/cashier_screen.dart';
import 'package:pos_resto/screens/cashier/shift_reprint_dialogs.dart';
import 'package:pos_resto/services/receipt_builder.dart';
import 'package:pos_resto/utils/currency.dart';
import 'package:pos_resto/widgets/ui/ui.dart';

final _opened = DateTime(2026, 11, 18, 9, 0);
final _closed = DateTime(2026, 11, 18, 21, 15);

CashierShift _shift(String id, {String? handoverTo, bool closed = true}) =>
    CashierShift(
      id: id,
      openedBy: 'Kasir Uji',
      openedAt: _opened,
      openingCash: 100000,
      closedAt: closed ? _closed : null,
      handoverTo: handoverTo,
      status: closed ? 'closed' : 'open',
      createdAt: _opened,
      updatedAt: _closed,
    );

Map<String, dynamic> _report() => {
      'period_start': _opened.toIso8601String(),
      'period_end': _closed.toIso8601String(),
      'crosses_day': false,
      'by_day': [
        {
          'date': '2026-11-18',
          'sales_count': 2,
          'sales_total': 66000.0,
          'cash_in_total': 0.0,
          'cash_out_total': 0.0,
        }
      ],
      'sales_count': 2,
      'sales_total': 66000.0,
      'opening_cash': 100000.0,
      'expected_cash': 166000.0,
      'by_method': {
        'cash': {'count': 2, 'total': 66000.0}
      },
      'menu_items_by_kind': [
        {
          'menu_kind': 'food',
          'label': 'Makanan',
          'quantity': 2,
          'items': [
            {'product_id': 'p1', 'product_name': 'Nasi Goreng', 'quantity': 2}
          ],
        },
        {
          'menu_kind': 'beverage',
          'label': 'Minuman',
          'quantity': 2,
          'items': [
            {'product_id': 'p2', 'product_name': 'Es Teh', 'quantity': 2}
          ],
        },
      ],
      'menu_quantity': 4,
    };

Future<void> _host(WidgetTester tester, Widget Function() dialog,
    {void Function(Object?)? onResult}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result =
                await showDialog<Object?>(context: context, builder: (_) => dialog());
            onResult?.call(result);
          },
          child: const Text('Buka'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Buka'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tutup kasir berhasil mengembalikan true agar cetak ulang ditawarkan',
      (tester) async {
    Object? result = 'belum';
    await _host(
      tester,
      () => CloseShiftDialog(
        activeShift: _shift('aktif', closed: false),
        getShiftReport: () async => _report(),
        getShiftMovements: () async => [],
        onClose: () async => null,
      ),
      onResult: (r) => result = r,
    );
    await tester.tap(find.byWidgetPredicate(
        (w) => w is AppButton && w.label == 'TUTUP KASIR'));
    await tester.pumpAndSettle();
    expect(find.byType(CloseShiftDialog), findsNothing);
    expect(result, isTrue);
  });

  testWidgets('dialog Kasir Ditutup: cetak ulang berkali-kali & tampilkan hasil',
      (tester) async {
    var calls = 0;
    String? nextError;
    await _host(
        tester,
        () => ShiftClosedDialog(onReprint: () async {
              calls++;
              return nextError;
            }));
    expect(find.text('Kasir Ditutup'), findsOneWidget);

    await tester.tap(find.byKey(const Key('shift-closed-reprint')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Salinan laporan dikirim ke printer kasir.'),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('shift-closed-reprint')));
    await tester.pumpAndSettle();
    expect(find.text('Salinan ke-2 dikirim ke printer kasir.'), findsOneWidget);

    nextError = 'Belum ada printer tersimpan.';
    await tester.tap(find.byKey(const Key('shift-closed-reprint')));
    await tester.pumpAndSettle();
    expect(find.text('Belum ada printer tersimpan.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('shift-closed-done')));
    await tester.pumpAndSettle();
    expect(find.byType(ShiftClosedDialog), findsNothing);
    expect(calls, 3);
  });

  testWidgets('daftar shift tertutup: label, ringkasan, tanda versi lama, cetak',
      (tester) async {
    final printed = <String>[];
    await _host(
      tester,
      () => ClosedShiftReprintDialog(
        loadShifts: () async => [
          (
            shift: _shift('serah', handoverTo: 'Kasir Sore'),
            salesTotal: 66000.0,
            salesCount: 2,
            frozen: true,
          ),
          (
            shift: _shift('lama'),
            salesTotal: null,
            salesCount: null,
            frozen: false,
          ),
        ],
        onReprint: (id) async {
          printed.add(id);
          return id == 'lama' ? 'Printer tidak merespons' : null;
        },
      ),
    );

    expect(find.textContaining('Ganti Shift · Rab, 18 Nov 2026'), findsOneWidget);
    expect(find.textContaining('Tutup Kasir · Rab, 18 Nov 2026'), findsOneWidget);
    expect(find.textContaining('09:00–21:15'), findsNWidgets(2));
    expect(find.textContaining('${CurrencyHelper.format(66000)} · 2 trx'),
        findsOneWidget);
    expect(find.text('Shift versi lama — dihitung ulang dari data tablet'),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('reprint-shift-serah')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reprint-shift-lama')));
    await tester.pumpAndSettle();
    expect(printed, ['serah', 'lama']);
    expect(find.text('Dikirim ke printer kasir'), findsOneWidget);
    expect(find.text('Printer tidak merespons'), findsOneWidget);
  });

  testWidgets('daftar kosong menjelaskan belum ada shift tertutup',
      (tester) async {
    await _host(
        tester,
        () => ClosedShiftReprintDialog(
            loadShifts: () async => [], onReprint: (_) async => null));
    expect(find.text('Belum ada shift yang ditutup di tablet ini.'),
        findsOneWidget);
  });

  test('struk cetak ulang bertanda jelas & isinya sama dengan aslinya', () {
    const builder = ReceiptBuilder(paperWidth: 32);
    String render({DateTime? reprintedAt, bool recomputed = false}) =>
        latin1.decode(builder.buildShiftReport(
          title: 'TUTUP KASIR',
          outletName: 'Outlet Uji',
          shift: _shift('s'),
          report: _report(),
          closedAt: _closed,
          reprintedAt: reprintedAt,
          recomputed: recomputed,
        ));

    final original = render();
    final copy = render(reprintedAt: DateTime(2026, 11, 19, 8, 5));
    expect(original, isNot(contains('CETAK ULANG')));
    expect(copy, contains('*** CETAK ULANG ***'));
    expect(copy, contains('Dicetak: 19/11/2026 08:05'));
    expect(copy, isNot(contains('Dihitung ulang')));
    // Bagian menu identik di kedua cetakan.
    String menu(String text) =>
        text.substring(text.indexOf('MENU TERJUAL'), text.indexOf('TOTAL QTY MENU'));
    expect(menu(copy), menu(original));
    expect(render(reprintedAt: DateTime(2026, 11, 19), recomputed: true),
        contains('Dihitung ulang dari data tablet'));
  });
}
