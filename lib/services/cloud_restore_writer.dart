import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../utils/ulid.dart';

/// Writes a recovery response inside one caller-owned SQLite transaction.
/// Recovery only fills missing entities; it never replaces operational data.
class CloudRestoreWriter {
  CloudRestoreWriter(this.db);

  final DatabaseExecutor db;

  List<Map> records(dynamic raw, String label) =>
      _list(raw, label).map((value) => _map(value, label)).toList();

  Future<bool> _exists(String table, String id) async => (await db.query(table,
          columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1))
      .isNotEmpty;

  Future<bool> _pending(String type, String id) async => (await db.query(
          'sync_queue',
          columns: ['id'],
          where: "entity_type = ? AND entity_id = ? "
              "AND status IN ('pending', 'processing', 'failed', 'bundled')",
          whereArgs: [type, id],
          limit: 1))
      .isNotEmpty;

  /// Only an empty operational database can adopt cloud charge settings.
  /// On a working register, matching local definitions remain authoritative.
  Future<void> prepareCharges(dynamic raw) async {
    if (raw == null) return; // older servers did not export charge masters
    final masters = _list(raw, 'master biaya');
    final activity = await db.rawQuery('SELECT '
        '(SELECT COUNT(*) FROM orders) + '
        '(SELECT COUNT(*) FROM transactions) + '
        '(SELECT COUNT(*) FROM cashier_shifts) + '
        '(SELECT COUNT(*) FROM sync_queue WHERE entity_type = '
        "'additional_charge' AND status != 'success') AS count");
    if ((activity.single['count'] as num) != 0) return;

    final seen = <String>{};
    for (final value in masters) {
      final master = _map(value, 'master biaya');
      final syncId = _required(master, 'local_id');
      if (!seen.add(syncId)) {
        throw const FormatException('ID master biaya ganda');
      }
      final local = await db.query('additional_charges',
          where: 'sync_id = ?', whereArgs: [syncId]);
      if (local.length > 1) {
        throw const FormatException('ID master biaya lokal ganda');
      }
      if (local.isNotEmpty) continue;
      final now = DateTime.now().toIso8601String();
      await db.insert('additional_charges', {
        'sync_id': syncId,
        'name': _required(master, 'name'),
        'charge_type': _choice(master['charge_type'], ['percentage', 'fixed']),
        'value': _number(master['value'], 'nilai biaya'),
        'is_active': _flag(master['is_active']),
        'created_at': now,
        'updated_at': now,
      });
    }
    // Fresh installs may already have default tax rows. Do not match by name
    // or integer ID, and do not apply those defaults alongside restored taxes.
    final local = await db.query('additional_charges');
    for (final master in local) {
      if (!seen.contains(master['sync_id'])) {
        await db.update('additional_charges', {'is_active': 0},
            where: 'id = ?', whereArgs: [master['id']]);
      }
    }
  }

  Future<bool> shift(Map source) async {
    final id = _id(source);
    if (await _exists('cashier_shifts', id) ||
        await _pending('cashier_shift', id)) {
      return false;
    }
    // Older servers could return an old open snapshot after a shift closed.
    // Fail the caller's restore transaction instead of reactivating it or
    // restoring cash movements without their valid open parent.
    final status = source['status'];
    final closedAt = source['closed_at'];
    if ((status != null && status != 'open') ||
        (closedAt != null && closedAt != '')) {
      throw const FormatException(
          'Data pemulihan memuat shift yang sudah ditutup atau tidak valid.');
    }
    if ((await db.query('cashier_shifts', where: "status = 'open'", limit: 1))
        .isNotEmpty) {
      throw const FormatException('Ada shift lokal yang masih terbuka. '
          'Periksa shift sebelum memulihkan shift lain.');
    }
    final opened = _time(source['opened_at']);
    final openedAt = DateTime.parse(opened);
    for (final local in await db
        .query('cashier_shifts', columns: ['opened_at', 'closed_at'])) {
      final localOpened =
          DateTime.tryParse(local['opened_at'] as String)?.toLocal();
      final localClosed = local['closed_at'] == null
          ? null
          : DateTime.tryParse(local['closed_at'] as String)?.toLocal();
      if ((localOpened != null && !localOpened.isBefore(openedAt)) ||
          (localClosed != null && localClosed.isAfter(openedAt))) {
        throw const FormatException(
            'Shift pemulihan bertumpang tindih atau lebih lama dari riwayat lokal. '
            'Periksa riwayat dan sinkronkan penutupan shift dari perangkat asal.');
      }
    }
    final now = DateTime.now().toIso8601String();
    await db.insert('cashier_shifts', {
      'id': id,
      'opened_by': source['opened_by'] ?? source['opened_by_name'] ?? 'Kasir',
      'opened_at': opened,
      'opening_cash': _number(source['opening_cash'] ?? 0, 'kas awal'),
      'previous_shift_id': source['previous_shift_id'],
      'handover_to': source['handover_to'],
      'notes': source['notes'],
      'status': 'open',
      'created_at': _time(source['created_at'], fallback: now),
      'updated_at': _time(source['updated_at'], fallback: now),
    });
    return true;
  }

  Future<bool> order(Map source) async {
    final id = _id(source);
    if (await _exists('orders', id) || await _pending('order', id)) {
      return false;
    }
    // A locally retained settlement also protects an order whose detail has
    // been removed by retention from being resurrected by an old cloud row.
    if ((await db.query('transactions',
            columns: ['id'],
            where: 'order_id = ? AND cancelled_at IS NULL',
            whereArgs: [id],
            limit: 1))
        .isNotEmpty) {
      return false;
    }

    final pay = source['payment_info'] == null
        ? <String, dynamic>{}
        : _map(source['payment_info'], 'rincian pembayaran');
    final snapshot = pay['restore'] == null
        ? <String, dynamic>{}
        : _map(pay['restore'], 'snapshot pemulihan');
    final structured = pay['restore'] != null;
    if (structured && snapshot['version'] != 1) {
      throw const FormatException(
          'Versi pemulihan belum didukung. Perbarui aplikasi POS.');
    }
    final paid = _number(pay['paid_amount'] ?? 0, 'saldo pembayaran');
    final total = _number(source['total_amount'], 'total order');
    if (paid < 0 || total < 0 || paid > total + 0.01) {
      throw const FormatException('Saldo order tidak valid');
    }
    final status = pay['payment_status'] ?? (paid > 0 ? 'partial' : 'unpaid');
    if (status == 'paid' ||
        (pay['voided_at'] != null && pay['voided_at'] != '')) {
      return false;
    }
    _choice(status, ['unpaid', 'partial']);
    if ((status == 'unpaid' && paid > 0) ||
        (status == 'partial' && paid <= 0)) {
      throw const FormatException('Status dan saldo pembayaran berbeda');
    }

    final items = _list(source['items'], 'item order');
    final payments = structured
        ? _list(snapshot['payments'], 'riwayat pembayaran')
        : const [];
    final charges =
        structured ? _list(snapshot['charges'], 'biaya order') : const [];
    final now = DateTime.now().toIso8601String();
    final created =
        _time(source['created_at'], fallback: structured ? null : now);
    final updated =
        _time(source['updated_at'], fallback: structured ? null : created);
    final holding = _flag(snapshot['is_holding'] ?? source['is_holding'] ?? 0);
    final merged = _flag(snapshot['is_merged'] ?? 0);
    final tableNumber = source['table_number'];
    if (holding == 0 &&
        merged == 0 &&
        (tableNumber is! String ||
            tableNumber.trim().isEmpty ||
            tableNumber.trim() == '-' ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(tableNumber))) {
      throw const FormatException('Nama meja order pemulihan tidak valid. '
          'Perbaiki meja di POS asal sebelum memulihkan.');
    }
    await db.insert('orders', {
      'id': id,
      'table_number': tableNumber ?? '-',
      'customer_name': source['customer_name'],
      'customer_phone': snapshot['customer_phone'] ?? source['customer_phone'],
      'customer_id': snapshot['customer_id'],
      'pax': source['pax'] ?? 1,
      'basket_size': items.length,
      'total_amount': total,
      'paid_amount': paid,
      'payment_status': status,
      'order_status': _choice(
          source['order_status'] ?? source['status'] ?? 'cooking',
          ['cooking', 'ready', 'served']),
      'created_by': snapshot['created_by'] ?? source['created_by'],
      'reservation_id': snapshot['reservation_id'],
      'is_holding': holding,
      'is_merged': merged,
      'merged_from': snapshot['merged_from'],
      'discount_note': snapshot['discount_note'] ?? pay['discount_note'],
      'complimented_at':
          pay['complimented_at'] == null || pay['complimented_at'] == ''
              ? null
              : _time(pay['complimented_at']),
      'compliment_by': pay['compliment_by'],
      'compliment_reason': pay['compliment_reason'],
      'created_at': created,
      'updated_at': updated,
    });

    double subtotal = 0;
    for (final value in items) {
      final item = _map(value, 'item order');
      final itemId = item['id'] ?? (structured ? null : Ulid.generate());
      final qty = _number(item['qty'] ?? item['quantity'], 'jumlah item');
      final price = _number(item['price'], 'harga item');
      if (qty <= 0 || qty != qty.roundToDouble() || price < 0) {
        throw const FormatException('Jumlah atau harga item tidak valid');
      }
      subtotal += qty * price;
      await db.insert('order_items', {
        'id': _stableId(itemId),
        'order_id': id,
        'product_id': item['product_id'],
        'category_id': item['category_id'],
        'product_name': item['product_name'] ?? item['name'] ?? '-',
        'qty': qty.toInt(),
        'price': price,
        'destination':
            _choice(item['destination'] ?? 'kitchen', ['kitchen', 'bar']),
        'item_status': _choice(
            item['status'] ?? item['item_status'] ?? 'pending',
            ['pending', 'cooking', 'ready', 'served']),
        'notes': item['notes'] ?? '',
        'addons': item['addons'] ?? '',
        'waiter_name': item['waiter_name'] ?? '',
        'is_additional': _flag(item['is_additional'] ?? 0),
        'created_at':
            _time(item['created_at'], fallback: structured ? null : created),
        'updated_at':
            _time(item['updated_at'], fallback: structured ? null : updated),
      });
    }

    if (!structured && (subtotal - total).abs() > 0.01) {
      throw const FormatException(
          'Rincian biaya atau diskon order lama belum lengkap. '
          'Sinkronkan POS asal sebelum memulihkan.');
    }

    double recorded = 0;
    for (final value in payments) {
      final payment = _map(value, 'pembayaran');
      final amount = _number(payment['amount'], 'jumlah pembayaran');
      if (amount <= 0) {
        throw const FormatException('Jumlah pembayaran tidak valid');
      }
      recorded += amount;
      await db.insert('payments', {
        'id': _stableId(payment['id']),
        'order_id': id,
        'amount': amount,
        'payment_method': _choice(payment['payment_method'],
            ['cash', 'card', 'qris', 'transfer', 'reservasi_dp']),
        'payment_note': payment['payment_note'],
        'created_by': payment['created_by'] ?? '',
        'created_at': _time(payment['created_at']),
      });
    }
    if (structured && (recorded - paid).abs() > 0.01) {
      throw const FormatException('Rincian pembayaran cloud belum lengkap. '
          'Sinkronkan POS asal sebelum memulihkan.');
    }
    // A legacy paid total is retained without inventing payment rows. The
    // repository's reconciliation guard blocks payment/top-up until repaired.
    double chargeTotal = 0;
    for (final value in charges) {
      final charge = _map(value, 'biaya order');
      int? masterId;
      if (_flag(charge['is_auto']) == 1) {
        final syncId = _required(charge, 'sync_id');
        final master = await db.query('additional_charges',
            columns: ['id'], where: 'sync_id = ?', whereArgs: [syncId]);
        if (master.length != 1) {
          throw const FormatException(
              'Master biaya belum tersedia atau bertabrakan. '
              'Periksa sinkronisasi biaya sebelum memulihkan order.');
        }
        masterId = master.single['id'] as int;
      } else if (charge['sync_id'] != null && charge['sync_id'] != '') {
        throw const FormatException('Identitas biaya manual tidak valid');
      }
      final applied = _number(charge['applied_amount'], 'jumlah biaya');
      chargeTotal += applied;
      await db.insert('order_additional_charges', {
        'order_id': id,
        'charge_id': masterId,
        'name': _required(charge, 'name'),
        'charge_type': _choice(charge['charge_type'], ['percentage', 'fixed']),
        'value': _number(charge['value'], 'nilai biaya'),
        'applied_amount': applied,
        'created_at': _time(charge['created_at']),
        'updated_at': _time(charge['updated_at']),
      });
    }
    if (structured &&
        ((subtotal + chargeTotal).clamp(0, double.infinity) - total).abs() >
            0.01) {
      throw const FormatException(
          'Item dan biaya cloud tidak sesuai total order. '
          'Sinkronkan POS asal sebelum memulihkan.');
    }
    if (holding == 0 && merged == 0) {
      await _occupyTable(tableNumber as String, id, now);
    }
    return true;
  }

  Future<void> _occupyTable(
      String tableNumber, String orderId, String now) async {
    final conflicting = await db.query('orders',
        columns: ['id'],
        where: "table_number = ? AND id != ? AND payment_status != 'paid' "
            'AND voided_at IS NULL AND is_holding = 0 AND is_merged = 0',
        whereArgs: [tableNumber, orderId],
        limit: 1);
    if (conflicting.isNotEmpty) {
      throw FormatException(
          'Meja $tableNumber sudah memiliki tagihan lokal lain. '
          'Periksa tagihan sebelum memulihkan.');
    }
    final tables = await db.query('tables',
        columns: ['id'],
        where: 'table_number = ?',
        whereArgs: [tableNumber],
        limit: 1);
    if (tables.isEmpty) {
      // A fresh install may not have its table configuration yet. Create a
      // normal table so the restored bill is reachable from the cashier UI.
      await db.insert('tables', {
        'id': Ulid.generate(),
        'table_number': tableNumber,
        'capacity': 4,
        'status': 'occupied',
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await db.update('tables', {'status': 'occupied', 'updated_at': now},
          where: 'id = ?', whereArgs: [tables.single['id']]);
    }
  }

  Future<bool> movement(Map source) async {
    final id = _id(source);
    if (await _exists('cashier_cash_movements', id) ||
        await _pending('cashier_cash_movement', id)) {
      return false;
    }
    final shiftId = _required(source, 'shift_id');
    if (!await _exists('cashier_shifts', shiftId)) {
      throw const FormatException('Shift untuk pergerakan kas belum tersedia');
    }
    await db.insert('cashier_cash_movements', {
      'id': id,
      'shift_id': shiftId,
      'movement_type':
          _choice(source['movement_type'] ?? source['type'], ['in', 'out']),
      'amount': _number(source['amount'], 'jumlah kas'),
      'counterpart_name': source['counterpart_name'] ?? source['name'] ?? '-',
      'note': source['note'] ?? '',
      'created_at': _time(source['created_at']),
    });
    return true;
  }

  String _id(Map value) => _required(value,
      value['local_id'] == null || value['local_id'] == '' ? 'id' : 'local_id');

  String _required(Map value, String key) {
    final text = value[key];
    if (text is! String || text.isEmpty) {
      throw FormatException('$key tidak tersedia');
    }
    return text;
  }

  String _stableId(dynamic value) {
    if (value is! String || value.length != 26) {
      throw const FormatException('ID item/pembayaran pemulihan tidak valid');
    }
    return value;
  }

  Map _map(dynamic value, String label) {
    if (value is String) value = jsonDecode(value);
    if (value is! Map) throw FormatException('$label tidak valid');
    return value;
  }

  List _list(dynamic value, String label) {
    if (value is String) value = jsonDecode(value);
    if (value is! List) throw FormatException('$label tidak lengkap');
    return value;
  }

  double _number(dynamic value, String label) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number == null || !number.isFinite) {
      throw FormatException('$label tidak valid');
    }
    return number;
  }

  int _flag(dynamic value) {
    if (value == true || value == 1) return 1;
    if (value == false || value == 0) return 0;
    throw const FormatException('Penanda pemulihan tidak valid');
  }

  String _choice(dynamic value, List<String> allowed) {
    if (value is! String || !allowed.contains(value)) {
      throw const FormatException('Status/jenis pemulihan tidak valid');
    }
    return value;
  }

  String _time(dynamic value, {String? fallback}) {
    if (value == null || value == '') {
      if (fallback != null) return fallback;
      throw const FormatException('Waktu asli pemulihan tidak tersedia');
    }
    final time = value is String ? DateTime.tryParse(value) : null;
    if (time == null) {
      throw const FormatException('Waktu pemulihan tidak valid');
    }
    return time.toLocal().toIso8601String();
  }
}
