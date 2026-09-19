import 'dart:typed_data';

import '../models/models.dart';
import 'logo_service.dart';

// ─── Data classes ─────────────────────────────────────────────────────────────

class ReceiptItem {
  final String name;
  final int quantity;
  final double price;
  final double total;
  final String? notes;

  /// Ringkasan add-on baris ini, mis. "Extra keju, Pedas". Harganya sudah
  /// termasuk di [price] — dicetak sebagai rincian agar tamu tahu tambahan
  /// apa yang membuat harganya berbeda dari harga menu di daftar.
  final String addons;
  final String ordererName; // siapa yang memesan item ini (untuk pengelompokan)

  const ReceiptItem({
    required this.name,
    required this.quantity,
    required this.price,
    required this.total,
    this.notes,
    this.addons = '',
    this.ordererName = '',
  });
}

class ReceiptCharge {
  final String name;
  final double amount;

  const ReceiptCharge({required this.name, required this.amount});
}

class ReceiptData {
  final String orderId;
  final String receiptNumber;
  final String tableNumber;
  final String? customerName;
  final String cashierName; // kasir yang MEMPROSES pembayaran
  final String ordererName; // siapa yang MEMESAN (pembuat order)
  final String waiterName;
  final int pax;
  final List<ReceiptItem> items;
  final double subtotal;
  final List<ReceiptCharge> charges;
  final double chargesTotal;
  final double total;
  final String paymentMethod;
  final double paidAmount;
  final double changeAmount;
  final DateTime dateTime;
  final bool isBill; // true = bill (belum bayar), false = receipt (sudah bayar)
  final String outletName;
  final String outletAddress;
  final String outletPhone;
  final String receiptFooter;

  const ReceiptData({
    required this.orderId,
    required this.receiptNumber,
    required this.tableNumber,
    this.customerName,
    this.cashierName = 'Kasir',
    this.ordererName = '',
    this.waiterName = '',
    this.pax = 1,
    required this.items,
    required this.subtotal,
    this.charges = const [],
    this.chargesTotal = 0,
    required this.total,
    this.paymentMethod = 'cash',
    this.paidAmount = 0,
    this.changeAmount = 0,
    required this.dateTime,
    this.isBill = false,
    this.outletName = 'POS Resto',
    this.outletAddress = '',
    this.outletPhone = '',
    this.receiptFooter = 'Terima Kasih!',
  });

  factory ReceiptData.fromPaymentResult({
    required Map<String, dynamic> result,
    required Order order,
    required List<OrderItem> orderItems,
    required List<OrderAdditionalCharge> charges,
    String cashierName = 'Kasir',
    String ordererName = '',
    String outletName = 'POS Resto',
    String outletAddress = '',
    String outletPhone = '',
    String receiptFooter = 'Terima Kasih!',
  }) {
    final subtotal = orderItems.fold(0.0, (sum, i) => sum + i.qty * i.price);
    final chargesTotal = charges.fold(0.0, (sum, c) => sum + c.appliedAmount);

    return ReceiptData(
      orderId: order.id,
      receiptNumber: 'TRX-${order.id.substring(0, 8).toUpperCase()}',
      tableNumber: order.tableNumber,
      customerName: order.customerName,
      cashierName: cashierName,
      ordererName: ordererName.isNotEmpty
          ? ordererName
          : (order.createdBy ?? ''),
      pax: order.pax,
      items: orderItems
          .map((i) => ReceiptItem(
                name: i.productName,
                quantity: i.qty,
                price: i.price,
                total: i.qty * i.price,
                notes: i.notes.isNotEmpty ? i.notes : null,
                addons: i.addonLabel,
                ordererName: i.waiterName,
              ))
          .toList(),
      subtotal: subtotal,
      charges: charges
          .map((c) => ReceiptCharge(name: c.name, amount: c.appliedAmount))
          .toList(),
      chargesTotal: chargesTotal,
      total: order.totalAmount,
      paymentMethod: result['payment_method'] as String? ?? 'cash',
      paidAmount: (result['paid_amount'] as num?)?.toDouble() ?? 0,
      changeAmount: (result['change'] as num?)?.toDouble() ?? 0,
      dateTime: DateTime.now(),
      isBill: false,
      outletName: outletName,
      outletAddress: outletAddress,
      outletPhone: outletPhone,
      receiptFooter: receiptFooter,
    );
  }
}

// ─── ESC/POS Commands ─────────────────────────────────────────────────────────

class _Esc {
  static const int esc = 0x1B;
  static const int gs = 0x1D;

  static List<int> init() => [esc, 0x40];
  static List<int> feedLine([int n = 1]) => List.filled(n, 0x0A);
  static List<int> boldOn() => [esc, 0x45, 0x01];
  static List<int> boldOff() => [esc, 0x45, 0x00];
  static List<int> centerAlign() => [esc, 0x61, 0x01];
  static List<int> leftAlign() => [esc, 0x61, 0x00];
  static List<int> fontLarge() => [gs, 0x21, 0x11];
  static List<int> fontNormal() => [gs, 0x21, 0x00];
  // Ukuran karakter variabel: w/h = pengali 0..7 (0 = 1x). GS ! n.
  static List<int> size(int w, int h) => [gs, 0x21, ((w & 7) << 4) | (h & 7)];
  static List<int> cutPartial() => [gs, 0x56, 0x41, 0x03];
  static List<int> line(String s) => [...s.codeUnits, 0x0A];
}

// ─── ReceiptBuilder ───────────────────────────────────────────────────────────

class ReceiptBuilder {
  /// Paper width in characters (58mm ≈ 32 chars, 80mm ≈ 48 chars)
  final int paperWidth;

  const ReceiptBuilder({this.paperWidth = 32});

  /// Lebar cetak dalam dot untuk logo: 80mm (≥44 kolom) = 576, selain itu 384.
  int get _logoDotWidth =>
      paperWidth >= 44 ? LogoService.dotsWidth80 : LogoService.dotsWidth58;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Build ESC/POS bytes for a full receipt (after payment).
  /// [isCopy] = true untuk rangkap ke-2 → diberi tanda "COPY / SALINAN" di
  /// bawah header agar mudah dibedakan dari struk asli.
  Uint8List buildReceipt(ReceiptData data, {bool isCopy = false}) {
    final buf = <int>[];
    _addHeader(buf, data);
    if (isCopy) _addCopyBanner(buf);
    _addDivider(buf);
    _addOrderInfo(buf, data);
    _addDivider(buf);
    _addItems(buf, data.items);
    _addDivider(buf);
    _addTotals(buf, data);
    if (!data.isBill) _addPaymentInfo(buf, data);
    _addDivider(buf);
    _addFooter(buf, data);
    buf.addAll(_Esc.cutPartial());
    return Uint8List.fromList(buf);
  }

  /// Penanda salinan (rangkap ke-2), dicetak tebal & di tengah.
  void _addCopyBanner(List<int> buf) {
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line('*** COPY / SALINAN ***'));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.leftAlign());
  }

  /// Laporan TUTUP KASIR / GANTI SHIFT untuk printer kasir.
  /// [title] = 'TUTUP KASIR' atau 'GANTI SHIFT'. [report] dari
  /// CashierRepository.getShiftReport. [countedCash] = kas dihitung fisik
  /// (untuk hitung selisih); null → tak ditampilkan.
  Uint8List buildShiftReport({
    required String title,
    required String outletName,
    required CashierShift shift,
    required Map<String, dynamic> report,
    List<CashMovement> movements = const [],
    DateTime? closedAt,
    String? handoverToName,
    double? countedCash,
  }) {
    final buf = <int>[];
    buf.addAll(_Esc.init());

    // Header
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.size(1, 1));
    buf.addAll(_Esc.line(outletName));
    buf.addAll(_Esc.size(0, 0));
    buf.addAll(_Esc.line(title));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.line(_divider()));

    // Info shift
    buf.addAll(_Esc.line('Kasir : ${shift.openedBy}'));
    buf.addAll(_Esc.line('Buka  : ${_formatDateTime(shift.openedAt)}'));
    buf.addAll(
        _Esc.line('Tutup : ${_formatDateTime(closedAt ?? DateTime.now())}'));
    if (handoverToName != null && handoverToName.isNotEmpty) {
      buf.addAll(_Esc.line('Serah ke: $handoverToName'));
    }
    buf.addAll(_Esc.line(_divider()));

    // Penjualan per metode
    final byMethod = (report['by_method'] as Map?) ?? const {};
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line('PENJUALAN PER METODE'));
    buf.addAll(_Esc.boldOff());
    for (final m in const ['cash', 'qris', 'card', 'transfer']) {
      final v = (byMethod[m] as Map?) ?? const {};
      final cnt = (v['count'] as num?)?.toInt() ?? 0;
      final total = (v['total'] as num?)?.toDouble() ?? 0;
      buf.addAll(_Esc.line(_rightAlign(
          '${_paymentMethodLabel(m)} ($cnt)', _formatAmount(total))));
    }
    buf.addAll(_Esc.line(_divider()));

    // Total penjualan
    final salesCount = (report['sales_count'] as num?)?.toInt() ?? 0;
    final salesTotal = (report['sales_total'] as num?)?.toDouble() ?? 0;
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line(_rightAlign('Total Transaksi', '$salesCount')));
    buf.addAll(
        _Esc.line(_rightAlign('Total Penjualan', _formatAmount(salesTotal))));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.line(_divider()));

    // Pengawasan: diskon, kompliment, void (tidak memengaruhi kas laci)
    final discountCount = (report['discount_count'] as num?)?.toInt() ?? 0;
    final discountTotal = (report['discount_total'] as num?)?.toDouble() ?? 0;
    final complimentCount = (report['compliment_count'] as num?)?.toInt() ?? 0;
    final complimentTotal =
        (report['compliment_total'] as num?)?.toDouble() ?? 0;
    final voidCount = (report['void_count'] as num?)?.toInt() ?? 0;
    final voidTotal = (report['void_total'] as num?)?.toDouble() ?? 0;
    final heldCount = (report['held_count'] as num?)?.toInt() ?? 0;
    final heldTotal = (report['held_total'] as num?)?.toDouble() ?? 0;
    if (discountCount > 0 ||
        complimentCount > 0 ||
        voidCount > 0 ||
        heldCount > 0) {
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line('DISKON / KOMPLIMEN / VOID / TITIPAN'));
      buf.addAll(_Esc.boldOff());
      buf.addAll(_Esc.line(_rightAlign(
          'Diskon ($discountCount)', _formatAmount(discountTotal))));
      buf.addAll(_Esc.line(_rightAlign(
          'Kompliment ($complimentCount)', _formatAmount(complimentTotal))));
      buf.addAll(_Esc
          .line(_rightAlign('Void ($voidCount)', _formatAmount(voidTotal))));
      if (heldCount > 0) {
        buf.addAll(_Esc.line(_rightAlign(
            'Titipan blm terjual ($heldCount)', _formatAmount(heldTotal))));
      }
      buf.addAll(_Esc.line(_divider()));
    }

    // Rincian per kasir (termasuk kasir station)
    final byCashier = (report['by_cashier'] as List?) ?? const [];
    if (byCashier.isNotEmpty) {
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line('PER KASIR'));
      buf.addAll(_Esc.boldOff());
      for (final c in byCashier) {
        final m = (c as Map?) ?? const {};
        final name = (m['cashier'] as String?) ?? '-';
        final cnt = (m['count'] as num?)?.toInt() ?? 0;
        final total = (m['total'] as num?)?.toDouble() ?? 0;
        buf.addAll(
            _Esc.line(_rightAlign('$name ($cnt)', _formatAmount(total))));
      }
      buf.addAll(_Esc.line(_divider()));
    }

    // Kas laci
    final openingCash = (report['opening_cash'] as num?)?.toDouble() ?? 0;
    final cashSales =
        (((byMethod['cash'] as Map?) ?? const {})['total'] as num?)
                ?.toDouble() ??
            0;
    final cashInTotal = (report['cash_in_total'] as num?)?.toDouble() ?? 0;
    final cashInCount = (report['cash_in_count'] as num?)?.toInt() ?? 0;
    final cashOutTotal = (report['cash_out_total'] as num?)?.toDouble() ?? 0;
    final cashOutCount = (report['cash_out_count'] as num?)?.toInt() ?? 0;
    final expectedCash = (report['expected_cash'] as num?)?.toDouble() ?? 0;
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line('KAS LACI'));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.line(_rightAlign('Modal Awal', _formatAmount(openingCash))));
    buf.addAll(
        _Esc.line(_rightAlign('Penjualan Tunai', _formatAmount(cashSales))));

    // Rincian pemasukan lain (kas masuk per item)
    final ins = movements.where((m) => m.movementType == 'in').toList();
    if (ins.isNotEmpty) {
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line('PEMASUKAN LAIN'));
      buf.addAll(_Esc.boldOff());
      for (final m in ins) {
        buf.addAll(_Esc.line(
            _rightAlign(' ${_movementLabel(m)}', _formatAmount(m.amount))));
      }
    }
    buf.addAll(_Esc.line(
        _rightAlign('Kas Masuk ($cashInCount)', _formatAmount(cashInTotal))));

    // Rincian pengeluaran lain (kas keluar per item)
    final outs = movements.where((m) => m.movementType == 'out').toList();
    if (outs.isNotEmpty) {
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line('PENGELUARAN LAIN'));
      buf.addAll(_Esc.boldOff());
      for (final m in outs) {
        buf.addAll(_Esc.line(_rightAlign(
            ' ${_movementLabel(m)}', '-${_formatAmount(m.amount)}')));
      }
    }
    buf.addAll(_Esc.line(_rightAlign(
        'Kas Keluar ($cashOutCount)', '-${_formatAmount(cashOutTotal)}')));
    buf.addAll(_Esc.line(_divider()));
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.size(1, 1));
    buf.addAll(_Esc.line(_rightAlignW(
        'KAS SEHARUSNYA', _formatAmount(expectedCash), paperWidth ~/ 2)));
    buf.addAll(_Esc.size(0, 0));
    buf.addAll(_Esc.boldOff());

    // Kas dihitung & selisih
    if (countedCash != null) {
      buf.addAll(
          _Esc.line(_rightAlign('Kas Dihitung', _formatAmount(countedCash))));
      final selisih = countedCash - expectedCash;
      final label = selisih == 0
          ? 'Selisih'
          : (selisih > 0 ? 'Selisih (Lebih)' : 'Selisih (Kurang)');
      final sign = selisih < 0 ? '-' : '';
      buf.addAll(_Esc.boldOn());
      buf.addAll(
          _Esc.line(_rightAlign(label, '$sign${_formatAmount(selisih)}')));
      buf.addAll(_Esc.boldOff());
    }
    buf.addAll(_Esc.line(_divider()));

    // Footer + tanda tangan
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.line('Dicetak: ${_formatDateTime(DateTime.now())}'));
    buf.addAll(_Esc.feedLine(2));
    buf.addAll(_Esc.line('Tanda Tangan Kasir'));
    buf.addAll(_Esc.feedLine(3));
    buf.addAll(_Esc.line('(__________________)'));
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.feedLine(2));
    buf.addAll(_Esc.cutPartial());
    return Uint8List.fromList(buf);
  }

  /// Ringkasan kerja seorang kasir di station (saat "Selesai Kerja").
  /// BUKAN penutupan shift — shift laci kas tetap di perangkat utama.
  Uint8List buildCashierSession({
    required String outletName,
    required String cashierName,
    required DateTime loginAt,
    required DateTime endAt,
    required Map<String, dynamic> summary,
  }) {
    final buf = <int>[];
    buf.addAll(_Esc.init());
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.size(1, 1));
    buf.addAll(_Esc.line(outletName));
    buf.addAll(_Esc.size(0, 0));
    buf.addAll(_Esc.line('RINGKASAN KASIR'));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.line(_divider()));
    buf.addAll(_Esc.line('Kasir   : $cashierName'));
    buf.addAll(_Esc.line('Login   : ${_formatDateTime(loginAt)}'));
    buf.addAll(_Esc.line('Selesai : ${_formatDateTime(endAt)}'));
    buf.addAll(_Esc.line(_divider()));

    final byMethod = (summary['by_method'] as Map?) ?? const {};
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line('PEMBAYARAN DIPROSES'));
    buf.addAll(_Esc.boldOff());
    for (final m in const ['cash', 'qris', 'card', 'transfer']) {
      final v = (byMethod[m] as Map?) ?? const {};
      final cnt = (v['count'] as num?)?.toInt() ?? 0;
      final total = (v['total'] as num?)?.toDouble() ?? 0;
      buf.addAll(_Esc.line(_rightAlign(
          '${_paymentMethodLabel(m)} ($cnt)', _formatAmount(total))));
    }
    buf.addAll(_Esc.line(_divider()));

    final count = (summary['count'] as num?)?.toInt() ?? 0;
    final total = (summary['total'] as num?)?.toDouble() ?? 0;
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line(_rightAlign('Jml Pembayaran', '$count')));
    buf.addAll(_Esc.size(1, 1));
    buf.addAll(_Esc.line(
        _rightAlignW('TOTAL', _formatAmount(total), paperWidth ~/ 2)));
    buf.addAll(_Esc.size(0, 0));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.line(_divider()));

    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.line('Bukan penutupan shift.'));
    buf.addAll(_Esc.line('Shift laci kas ditutup'));
    buf.addAll(_Esc.line('di perangkat utama.'));
    buf.addAll(_Esc.feedLine(2));
    buf.addAll(_Esc.cutPartial());
    return Uint8List.fromList(buf);
  }

  /// Tiket dapur/bar versi BESAR & informatif. Item dicetak font dobel agar
  /// terbaca dari jarak jauh; dilengkapi nomor meja besar, waktu, dan pemesan.
  Uint8List buildKitchenOrder({
    required String orderId,
    required String tableNumber,
    required String waiterName,
    required List<OrderItem> items,
    required DateTime dateTime,
    String printerLabel = 'DAPUR',
    bool isAdditional = false,
    String placedBy = '',
    String? customerName,
    int pax = 0,
    bool isCopy = false,
  }) {
    final buf = <int>[];
    final qtyTotal = items.fold<int>(0, (s, i) => s + i.qty);
    final orderer = placedBy.isNotEmpty
        ? placedBy
        : (waiterName.isNotEmpty ? waiterName : '-');

    buf.addAll(_Esc.init());
    if (isCopy) _addCopyBanner(buf); // rangkap ke-2+ ditandai COPY

    // ── Judul: status pesanan (BESAR) — baru / tambahan ──
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.size(1, 1)); // 2x
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line(isAdditional ? 'PESANAN TAMBAHAN' : 'PESANAN BARU'));
    buf.addAll(_Esc.size(0, 0));
    buf.addAll(_Esc.boldOff());

    // ── Nomor meja SANGAT besar (info terpenting) ──
    buf.addAll(_Esc.size(2, 2)); // 3x
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line('MEJA $tableNumber'));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.size(0, 0));

    // ── Info pesanan ──
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.line(_divider()));
    buf.addAll(_Esc.line('No    : ${orderId.substring(0, 8).toUpperCase()}'));
    buf.addAll(_Esc.line('Waktu : ${_formatDateTime(dateTime)}'));
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line('Pemesan: $orderer'));
    buf.addAll(_Esc.boldOff());
    if (customerName != null && customerName.isNotEmpty) {
      final paxStr = pax > 0 ? ' ($pax org)' : '';
      buf.addAll(_Esc.line('Pelanggan: $customerName$paxStr'));
    }
    buf.addAll(_Esc.line(_divider()));

    // ── Daftar item (font dobel) ──
    for (final item in items) {
      buf.addAll(_Esc.size(1, 1)); // 2x
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line('${item.qty}x ${item.productName}'));
      buf.addAll(_Esc.boldOff());
      buf.addAll(_Esc.size(0, 0));
      if (item.addonLabel.isNotEmpty) {
        buf.addAll(_Esc.boldOn());
        buf.addAll(_Esc.line('   + ${item.addonLabel}'));
        buf.addAll(_Esc.boldOff());
      }
      if (item.notes.isNotEmpty) {
        buf.addAll(_Esc.boldOn());
        buf.addAll(_Esc.line('   >> ${item.notes}'));
        buf.addAll(_Esc.boldOff());
      }
    }

    buf.addAll(_Esc.line(_divider()));
    buf.addAll(_Esc.line('Total item: $qtyTotal'));

    // ── Label printer/stasiun (kecil, di bawah) ──
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.line('[ $printerLabel ]'));
    buf.addAll(_Esc.line('--- CUT ---'));
    buf.addAll(_Esc.feedLine(3));
    buf.addAll(_Esc.cutPartial());
    return Uint8List.fromList(buf);
  }

  /// Tiket CHECKER / ekspeditor: salinan SELURUH pesanan dengan tag tujuan
  /// (DAPUR/BAR) di tiap item, agar pengecek bisa merakit pesanan lengkap.
  Uint8List buildCheckerOrder({
    required String orderId,
    required String tableNumber,
    required String waiterName,
    required List<OrderItem> items,
    required DateTime dateTime,
    Map<String, String> categoryNames = const {},
    bool isAdditional = false,
    String? customerName,
    int pax = 0,
  }) {
    final buf = <int>[];
    buf.addAll(_Esc.init());
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line('CHECKER'));
    buf.addAll(_Esc.boldOff());
    if (isAdditional) {
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line('*** TAMBAHAN ***'));
      buf.addAll(_Esc.boldOff());
    }
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.line(_divider()));
    buf.addAll(_Esc.line('No: ${orderId.substring(0, 8).toUpperCase()}'));
    buf.addAll(_Esc.line('Meja: $tableNumber'));
    if (waiterName.isNotEmpty) {
      buf.addAll(_Esc.line('Waiter: $waiterName'));
    }
    if (customerName != null && customerName.isNotEmpty) {
      final paxStr = pax > 0 ? ' ($pax pax)' : '';
      buf.addAll(_Esc.line('Pelanggan: $customerName$paxStr'));
    }
    buf.addAll(_Esc.line(_formatDateTime(dateTime)));
    buf.addAll(_Esc.line('Total item: ${items.length}'));
    buf.addAll(_Esc.line(_divider()));

    for (final item in items) {
      final cat = categoryNames[item.categoryId];
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line('${item.qty}x ${item.productName}'));
      buf.addAll(_Esc.boldOff());
      if (cat != null && cat.isNotEmpty) {
        buf.addAll(_Esc.line('    [$cat]'));
      }
      if (item.addonLabel.isNotEmpty) {
        buf.addAll(_Esc.line('    + ${item.addonLabel}'));
      }
      if (item.notes.isNotEmpty) {
        buf.addAll(_Esc.line('    - ${item.notes}'));
      }
    }

    buf.addAll(_Esc.line(_divider()));
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.line('--- CUT ---'));
    buf.addAll(_Esc.feedLine(3));
    buf.addAll(_Esc.cutPartial());
    return Uint8List.fromList(buf);
  }

  // ── Private helpers ─────────────────────────────────────────────────────────

  void _addHeader(List<int> buf, ReceiptData data) {
    buf.addAll(_Esc.init());
    buf.addAll(_Esc.centerAlign());
    // Logo struk (bila di-set) — di paling atas, dipusatkan. Dibaca dari cache
    // lokal (offline). Hanya untuk struk pembayaran & tagihan.
    final logo = LogoService.instance.escposRaster(_logoDotWidth);
    if (logo != null) buf.addAll(logo);
    buf.addAll(_Esc.fontLarge());
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line(data.outletName));
    buf.addAll(_Esc.fontNormal());
    buf.addAll(_Esc.boldOff());
    if (data.outletAddress.isNotEmpty) {
      buf.addAll(_Esc.line(data.outletAddress));
    }
    if (data.outletPhone.isNotEmpty) {
      buf.addAll(_Esc.line('Telp: ${data.outletPhone}'));
    }
    // Judul jenis dokumen
    buf.addAll(_Esc.feedLine());
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line(data.isBill ? '== TAGIHAN ==' : '== STRUK PEMBAYARAN =='));
    if (data.isBill) {
      buf.addAll(_Esc.line('(Belum Dibayar)'));
    }
    buf.addAll(_Esc.boldOff());
  }

  /// Baris "Label : value" dengan label rata kolom agar titik dua sejajar.
  String _kv(String label, String value) => '${label.padRight(9)}: $value';

  void _addOrderInfo(List<int> buf, ReceiptData data) {
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.line(_kv('No', data.receiptNumber)));
    buf.addAll(_Esc.line(_kv('Waktu', _formatDateTime(data.dateTime))));
    buf.addAll(_Esc.line(_kv('Meja', '${data.tableNumber}   (Pax ${data.pax})')));
    // Pemesan di header HANYA bila satu pemesan. Bila >1, ditampilkan
    // sebagai sub-header per grup di daftar item (lihat _addItems).
    final distinctOrderers = data.items
        .map((i) => i.ordererName.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (distinctOrderers.length < 2 && data.ordererName.isNotEmpty) {
      buf.addAll(_Esc.line(_kv('Pemesan', data.ordererName)));
    }
    // Kasir = pemroses pembayaran (hanya struk pembayaran). Untuk bill,
    // tampilkan juga sebagai petugas yang mencetak.
    if (data.cashierName.isNotEmpty) {
      buf.addAll(_Esc.line(_kv(data.isBill ? 'Petugas' : 'Kasir', data.cashierName)));
    }
    if (data.waiterName.isNotEmpty) {
      buf.addAll(_Esc.line(_kv('Waiter', data.waiterName)));
    }
    if (data.customerName != null && data.customerName!.isNotEmpty) {
      buf.addAll(_Esc.line(_kv('Pelanggan', data.customerName!)));
    }
    // No. HP customer TIDAK dicetak di struk (cukup nama) — tetap disimpan & sync.
  }

  void _addItems(List<int> buf, List<ReceiptItem> items) {
    buf.addAll(_Esc.leftAlign());

    // Kelompokkan item per PEMESAN (menjaga urutan kemunculan).
    final groups = <String, List<ReceiptItem>>{};
    for (final it in items) {
      (groups[it.ordererName] ??= []).add(it);
    }
    // Kelompokkan per pemesan HANYA bila ada >1 pemesan berbeda (kalau cuma
    // satu, baris "Pemesan" di atas sudah cukup — hindari redundan).
    final namedGroups = groups.keys.where((k) => k.trim().isNotEmpty).length;
    final showHeaders = namedGroups >= 2;

    void printOne(ReceiptItem item) {
      final left = '${item.quantity}x ${item.name}';
      buf.addAll(_Esc.line(_rightAlign(left, _formatAmount(item.total))));
      if (item.quantity > 1) {
        buf.addAll(_Esc.line('    @ ${_formatAmount(item.price)}'));
      }
      if (item.addons.isNotEmpty) {
        buf.addAll(_Esc.line('    + ${item.addons}'));
      }
      if (item.notes != null && item.notes!.isNotEmpty) {
        buf.addAll(_Esc.line('    - ${item.notes}'));
      }
    }

    if (!showHeaders) {
      for (final it in items) {
        printOne(it);
      }
      return;
    }

    var first = true;
    groups.forEach((orderer, list) {
      // Pembatas antar grup pemesan (grup pertama sudah punya divider di atas).
      if (!first) buf.addAll(_Esc.line(_divider()));
      first = false;
      // "Pemesan : Nama" (tebal) DI ATAS item-itemnya + garis pembatas.
      buf.addAll(_Esc.boldOn());
      buf.addAll(_Esc.line(
          'Pemesan : ${orderer.trim().isEmpty ? 'Lainnya' : orderer}'));
      buf.addAll(_Esc.boldOff());
      buf.addAll(_Esc.line(_divider()));
      for (final it in list) {
        printOne(it);
      }
    });
  }

  void _addTotals(List<int> buf, ReceiptData data) {
    buf.addAll(_Esc.leftAlign());
    buf.addAll(
        _Esc.line(_rightAlign('Subtotal', _formatAmount(data.subtotal))));

    for (final charge in data.charges) {
      final label = charge.name;
      final amount = charge.amount >= 0
          ? _formatAmount(charge.amount)
          : '-${_formatAmount(-charge.amount)}';
      buf.addAll(_Esc.line(_rightAlign(label, amount)));
    }

    buf.addAll(_Esc.line(_divider()));
    // TOTAL dicetak font dobel agar menonjol (lebar efektif = setengah kolom).
    buf.addAll(_Esc.size(1, 1));
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line(
        _rightAlignW('TOTAL', _formatAmount(data.total), paperWidth ~/ 2)));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.size(0, 0));
  }

  void _addPaymentInfo(List<int> buf, ReceiptData data) {
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.feedLine()); // jeda dari blok TOTAL
    final methodLabel = _paymentMethodLabel(data.paymentMethod);
    buf.addAll(
        _Esc.line(_rightAlign('Bayar ($methodLabel)', _formatAmount(data.paidAmount))));
    if (data.paymentMethod == 'cash') {
      buf.addAll(
          _Esc.line(_rightAlign('Kembalian', _formatAmount(data.changeAmount))));
    }
  }

  void _addFooter(List<int> buf, ReceiptData data) {
    buf.addAll(_Esc.centerAlign());
    buf.addAll(_Esc.feedLine());
    if (data.isBill) {
      buf.addAll(_Esc.line('Mohon lakukan pembayaran di kasir'));
      buf.addAll(_Esc.feedLine());
    }
    buf.addAll(_Esc.boldOn());
    buf.addAll(_Esc.line(data.receiptFooter));
    buf.addAll(_Esc.boldOff());
    buf.addAll(_Esc.feedLine(3));
  }

  void _addDivider(List<int> buf) {
    buf.addAll(_Esc.leftAlign());
    buf.addAll(_Esc.line(_divider()));
  }

  String _divider() => '-' * paperWidth;

  /// Label gerakan kas: nama lawan transaksi → catatan → default.
  /// Dipotong agar muat di samping nominal.
  String _movementLabel(CashMovement m) {
    var s = m.counterpartName.trim();
    if (s.isEmpty) s = m.note.trim();
    if (s.isEmpty) s = m.movementType == 'in' ? 'Kas masuk' : 'Kas keluar';
    final max = paperWidth - 13; // sisakan ruang untuk nominal
    if (max > 1 && s.length > max) s = s.substring(0, max);
    return s;
  }

  /// Right-align value against label within paperWidth.
  String _rightAlign(String label, String value) =>
      _rightAlignW(label, value, paperWidth);

  /// Right-align value against label within [cols] kolom.
  String _rightAlignW(String label, String value, int cols) {
    final space = cols - label.length - value.length;
    if (space <= 0) return '$label $value';
    return '$label${' ' * space}$value';
  }

  String _formatAmount(double amount) {
    // Format as integer Rupiah without symbol (e.g. "25.000")
    final abs = amount.abs();
    final intVal = abs.round();
    final s = intVal.toString();
    // Insert thousand separators
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  String _formatDateTime(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final y = dt.year;
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$d/$mo/$y $h:$mi';
  }

  String _paymentMethodLabel(String method) {
    switch (method) {
      case 'cash':
        return 'Tunai';
      case 'card':
        return 'Kartu';
      case 'qris':
        return 'QRIS';
      case 'transfer':
        return 'Transfer';
      case 'compliment':
        return 'Compliment';
      default:
        return method;
    }
  }
}
