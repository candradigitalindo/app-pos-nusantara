import '../database/database.dart';
import '../services/app_events.dart';
import '../models/models.dart';
import '../utils/ulid.dart';

class TableRepository {
  final AppDatabase _db = AppDatabase.instance;

  Future<List<RestaurantTable>> getTables() async {
    // Urut numerik: "2" sebelum "10" (kolom String, jadi CAST dulu).
    // Fallback urut teks untuk nomor non-numerik (mis. "VIP").
    final results = await _db.query('tables',
        orderBy: 'CAST(table_number AS INTEGER) ASC, table_number ASC');
    return results.map((m) => RestaurantTable.fromMap(m)).toList();
  }

  Future<RestaurantTable> createTable({
    required String tableNumber,
    int capacity = 4,
  }) async {
    final now = DateTime.now();
    final table = RestaurantTable(
      id: Ulid.generate(),
      tableNumber: tableNumber,
      capacity: capacity,
      status: 'available',
      createdAt: now,
      updatedAt: now,
    );
    await _db.insert('tables', table.toMap());
    return table;
  }

  Future<void> updateTable({
    required String tableId,
    String? tableNumber,
    int? capacity,
    String? status,
  }) async {
    final values = <String, dynamic>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (tableNumber != null) values['table_number'] = tableNumber;
    if (capacity != null) values['capacity'] = capacity;
    if (status != null) values['status'] = status;
    await _db.update(
      'tables',
      values,
      where: 'id = ?',
      whereArgs: [tableId],
    );
    notifyDataChanged('order_updated');
  }

  Future<void> updateTableStatus(String tableNumber, String status) async {
    await _db.update(
      'tables',
      {
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'table_number = ?',
      whereArgs: [tableNumber],
    );
    notifyDataChanged('order_updated');
  }

  Future<void> deleteTable(String id) async {
    await _db.delete('tables', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> seedTables({int count = 10}) async {
    final existing = await getTables();
    if (existing.isNotEmpty) return;

    for (int i = 1; i <= count; i++) {
      await createTable(
        tableNumber: i.toString(),
        capacity: i <= 5 ? 4 : (i <= 8 ? 6 : 8),
      );
    }
  }
}
