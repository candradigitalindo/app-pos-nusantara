import '../controllers/kitchen_controller.dart';
import '../models/models.dart';
import 'station_api_client.dart';

/// Sumber data layar Dapur/Bar untuk mode STATION: datanya diambil dari Main
/// POS lewat [StationApiClient], bukan DB perangkat ini.
///
/// Layar & controller-nya sama persis dengan perangkat utama — yang berbeda
/// hanya kelas ini, sehingga tampilan dapur di station tak pernah melenceng.
class StationKitchenSource implements KitchenDataSource {
  final StationApiClient _api;

  StationKitchenSource({StationApiClient? api})
      : _api = api ?? StationApiClient.instance;

  @override
  Future<Map<Order, List<OrderItem>>> activeOrdersWithItems() async {
    final rows = await _api.getKitchenOrders();
    final result = <Order, List<OrderItem>>{};
    for (final row in rows) {
      final orderMap = row['order'];
      if (orderMap is! Map) continue;
      final order = Order.fromMap(orderMap.cast<String, dynamic>());
      final items = (row['items'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => OrderItem.fromMap(m.cast<String, dynamic>()))
          .toList();
      result[order] = items;
    }
    return result;
  }

  @override
  Future<void> updateItemStatus(String itemId, String status) =>
      _api.updateItemStatus(itemId, status);

  /// Pesanan baru / perubahan item dari perangkat lain langsung tampil.
  @override
  void watch(void Function() onChanged) {
    _api.connectWebSocket((event, _) {
      if (event == 'order_created' ||
          event == 'order_items_added' ||
          event == 'order_paid' ||
          event == 'order_updated') {
        onChanged();
      }
    });
  }

  @override
  void unwatch() => _api.disconnectWebSocket();
}
