import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/models/models.dart';
import 'package:pos_resto/screens/cashier/procurement_payout_dialog.dart';
import 'package:pos_resto/services/procurement_payout_service.dart';
import 'package:pos_resto/services/receipt_builder.dart';
import 'package:pos_resto/utils/currency.dart';
import 'package:pos_resto/widgets/ui/ui.dart';

CashPayout _payout(String id, {String status = 'pending', double amount = 250000}) => CashPayout(
      id: id,
      purchaseRequestId: 'PR$id',
      requestNumber: 'PR-2026-$id',
      itemsSummary: 'Servis mesin kopi',
      vendorName: 'CV Teknik',
      amount: amount,
      recipientName: 'Pak Teknisi',
      notes: 'Bayar saat selesai',
      status: status,
      assignedBy: 'Keuangan',
      assignedAt: DateTime(2026, 11, 18, 10),
      cashierName: status == 'paid' ? 'Kasir Uji' : '',
      authorizedBy: status == 'paid' ? 'Manajer' : '',
      paidAt: status == 'paid' ? DateTime(2026, 11, 18, 11) : null,
    );

class _FakeService extends ProcurementPayoutService {
  _FakeService(this.items);
  List<CashPayout> items;
  PayoutException? fetchError;
  final handedOver = <String>[];
  final returned = <String>[];

  @override
  Future<List<CashPayout>> fetch() async {
    if (fetchError != null) throw fetchError!;
    return items;
  }

  @override
  Future<PayoutHandOverResult> handOver(CashPayout p,
      {required String cashierName, required String authorizedBy}) async {
    handedOver.add('${p.id}|$cashierName|$authorizedBy');
    final paid = _payout(p.id, status: 'paid', amount: p.amount);
    items = [paid];
    return PayoutHandOverResult(
      payout: paid,
      movement: CashMovement(
          id: 'MV1', shiftId: 'S1', movementType: 'out', amount: p.amount,
          counterpartName: p.recipientName, createdAt: DateTime(2026, 11, 18, 11), cashPayoutId: p.id),
      confirmedOnline: true,
    );
  }

  @override
  Future<CashPayout> returnToFinance(CashPayout p, {required String reason, required String cashierName}) async {
    returned.add('${p.id}|$reason');
    items = [];
    return p;
  }
}

void main() {
  late _FakeService service;
  late List<String> printed;
  String? authorizer;

  Future<void> open(WidgetTester tester, {double drawer = 1000000}) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ProcurementPayoutDialog(
                service: service,
                authorize: (pin) async => pin == '1234' ? authorizer : null,
                cashierName: () async => 'Kasir Uji',
                drawerCash: () async => drawer,
                localMovement: (_) async => null,
                printProof: (p, m, reprint) async {
                  printed.add('${p.id}|${reprint ? 'ulang' : 'asli'}|${m?.id}');
                  return null;
                },
              ),
            ),
            child: const Text('Buka'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Buka'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    service = _FakeService([_payout('A')]);
    printed = [];
    authorizer = 'Manajer';
  });

  testWidgets('menampilkan tugas langsung dari cloud + peringatan kas laci kurang', (tester) async {
    await open(tester, drawer: 100000);
    expect(find.text('PR-2026-A'), findsOneWidget);
    expect(find.text(CurrencyHelper.format(250000)), findsOneWidget);
    expect(find.text('Serahkan kepada: Pak Teknisi'), findsOneWidget);
    expect(find.byKey(const Key('payout-drawer-short')), findsOneWidget);
  });

  testWidgets('Serahkan Kas: PIN manajer → kas diserahkan → bukti dicetak', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('payout-drawer-short')), findsNothing);
    await tester.tap(find.byKey(const Key('payout-handover-A')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'PIN Otorisasi'), '1234');
    await tester.tap(find.text('Serahkan Kas').last);
    await tester.pumpAndSettle();

    expect(service.handedOver, ['A|Kasir Uji|Manajer']);
    expect(printed, ['A|asli|MV1']);
    expect(find.textContaining('Pengajuan PR-2026-A tercatat dibayar'), findsOneWidget);
    expect(find.textContaining('Bukti penyerahan dicetak'), findsOneWidget);
    // Daftar dimuat ulang: kini riwayat dengan tombol cetak ulang.
    await tester.tap(find.byKey(const Key('payout-reprint-A')));
    await tester.pumpAndSettle();
    expect(printed.last, 'A|ulang|null');
  });

  testWidgets('PIN tidak berwenang: uang tidak keluar', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('payout-handover-A')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'PIN Otorisasi'), '9999');
    await tester.tap(find.text('Serahkan Kas').last);
    await tester.pumpAndSettle();
    expect(service.handedOver, isEmpty);
    expect(find.textContaining('PIN salah'), findsOneWidget);
  });

  testWidgets('Kembalikan ke Keuangan wajib alasan', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('payout-return-A')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('payout-return-confirm'));
    expect(tester.widget<AppButton>(confirm).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('payout-return-reason')), 'Harga di toko berbeda');
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(service.returned, ['A|Harga di toko berbeda']);
    expect(find.textContaining('dikembalikan ke Bagian Keuangan'), findsOneWidget);
  });

  testWidgets('tablet offline: tugas tidak bisa dibuka', (tester) async {
    service.fetchError = const PayoutException(ProcurementPayoutService.offlineMessage, offline: true);
    await open(tester);
    expect(find.byKey(const Key('payout-offline')), findsOneWidget);
    expect(find.textContaining('hanya bisa diproses saat online'), findsOneWidget);
    expect(find.byKey(const Key('payout-handover-A')), findsNothing);
  });

  test('bukti penyerahan kas memuat rincian & kolom tanda tangan', () {
    String render({DateTime? reprintedAt}) => latin1.decode(const ReceiptBuilder(paperWidth: 32).buildCashPayoutProof(
          outletName: 'Outlet Uji',
          requestNumber: 'PR-2026-A',
          vendorName: 'CV Teknik',
          itemsSummary: 'Servis mesin kopi',
          recipient: 'Pak Teknisi',
          amount: 250000,
          handedAt: DateTime(2026, 11, 18, 11, 5),
          cashierName: 'Kasir Uji',
          authorizedBy: 'Manajer',
          assignedBy: 'Keuangan',
          reprintedAt: reprintedAt,
        ));
    final text = render();
    expect(text, contains('BUKTI PENYERAHAN KAS'));
    expect(text, contains('PR-2026-A'));
    expect(text, matches(RegExp(r'JUMLAH +Rp 250\.000')));
    expect(text, contains('Diserahkan oleh'));
    expect(text, contains('Diterima oleh'));
    expect(text, contains('(Kasir Uji)'));
    expect(text, contains('(Pak Teknisi)'));
    expect(text, contains('18/11/2026 11:05'));
    expect(text, isNot(contains('CETAK ULANG')));
    expect(render(reprintedAt: DateTime(2026, 11, 19)), contains('*** CETAK ULANG ***'));
  });
}
