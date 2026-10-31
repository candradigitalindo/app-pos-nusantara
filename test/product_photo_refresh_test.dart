import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_resto/controllers/cashier_controller.dart';
import 'package:pos_resto/controllers/waiter_controller.dart';
import 'package:pos_resto/models/models.dart' as m;
import 'package:pos_resto/repositories/cashier_repository.dart';
import 'package:pos_resto/repositories/order_repository.dart';
import 'package:pos_resto/repositories/product_repository.dart';
import 'package:pos_resto/repositories/table_repository.dart';
import 'package:sqflite/sqflite.dart';

// In-memory repository boundaries keep these controller tests independent of
// plugins, network and any operational database.
class _Products extends ProductRepository {
  _Products(this.rows);
  List<m.Product> rows;
  Future<List<m.Product>>? pendingRead;

  @override
  Future<List<m.Product>> getProducts({String? categoryId}) async {
    final pending = pendingRead;
    if (pending != null) return await pending;
    return rows;
  }

  @override
  Future<List<m.Category>> getCategories() async => [];

  @override
  Future<Map<String, int>> addonCountByProduct() async => {};
}

class _Tables extends TableRepository {
  _Tables(this.table);
  final m.RestaurantTable table;

  @override
  Future<List<m.RestaurantTable>> getTables() async => [table];
}

class _Cashier extends CashierRepository {
  @override
  Future<m.CashierShift?> getActiveShift({DatabaseExecutor? executor}) async =>
      null;
}

class _Orders extends OrderRepository {
  _Orders(this.order, this.items);
  final m.Order order;
  final List<m.OrderItem> items;

  @override
  Future<m.Order?> getOrderById(String id) async => order;

  @override
  Future<m.Order?> getOrderByTable(String tableNumber) async => order;

  @override
  Future<Map<String, m.Order>> getActiveOrdersByTable() async =>
      {order.tableNumber: order};

  @override
  Future<List<m.OrderItem>> getOrderItems(String orderId) async => items;

  @override
  Future<List<m.OrderAdditionalCharge>> getOrderCharges(String orderId) async =>
      [];
}

void main() {
  final time = DateTime.utc(2026, 10, 21, 6);
  final original = m.Product(
      id: 'product',
      name: 'Harga saat keranjang dibuat',
      code: 'MENU-1',
      description: 'Keterangan awal',
      photoUrl: 'https://cloud.test/old.png',
      price: 10000,
      stock: 8,
      categoryId: 'category',
      createdAt: time,
      updatedAt: time);
  final changed = m.Product(
      id: original.id,
      name: 'Nama terbaru dari cloud',
      photoUrl: 'https://cloud.test/new.png',
      price: 99000,
      stock: 0,
      createdAt: time,
      updatedAt: time.add(const Duration(days: 1)));
  final table = m.RestaurantTable(
      id: 'table', tableNumber: '5', createdAt: time, updatedAt: time);
  final order = m.Order(
      id: 'order',
      tableNumber: table.tableNumber,
      totalAmount: 7000,
      paidAmount: 1000,
      paymentStatus: 'partial',
      createdAt: time,
      updatedAt: time);
  final item = m.OrderItem(
      id: 'existing-item',
      orderId: order.id,
      productName: 'Item sudah dipesan',
      qty: 1,
      price: 7000,
      createdAt: time,
      updatedAt: time);
  const addon = m.SelectedAddon(id: 'addon', name: 'Keju', price: 2000);

  void expectPhotoOnly(m.Product product, String url) {
    expect(product.toMap(), {...original.toMap(), 'photo_url': url});
  }

  test('withPhotoUrl preserves every original product field', () {
    expectPhotoOnly(original.withPhotoUrl(changed.photoUrl), changed.photoUrl);
    expectPhotoOnly(original.withPhotoUrl(''), '');
    expect(original.photoUrl, 'https://cloud.test/old.png');
  });

  test('cashier photo refresh preserves current order and in-flight cart edits',
      () async {
    final products = _Products([original]);
    final controller = CashierController(
        productRepo: products,
        tableRepo: _Tables(table),
        cashierRepo: _Cashier(),
        orderRepo: _Orders(order, [item]));
    addTearDown(controller.dispose);
    await controller.loadData();
    controller.selectTable(table);
    await controller.loadOrderForTable(table.tableNumber);
    controller.addToCart(original, addons: [addon]);
    controller.addToCart(original);
    controller.updateCartNote(original.id, 'Tanpa cabai');
    controller.setPax(3);
    controller.setCustomer(name: 'Tamu', phone: '08000');

    final loaded = Completer<List<m.Product>>();
    products.pendingRead = loaded.future;
    final refreshing = controller.refreshProductPhotos();
    // A user can still add an item while the photo metadata query is pending.
    controller.addToCart(original);
    final before = controller.state;
    loaded.complete([changed]);
    await refreshing;
    products.pendingRead = null;

    void expectOperationalStateUnchanged() {
      final state = controller.state;
      expect(state.cart, {original.id: 3});
      expect(state.cartTotal, 36000);
      expect(state.cartNotes, before.cartNotes);
      expect(state.cartAddons, before.cartAddons);
      expect(state.currentOrder, same(order));
      expect(state.currentOrder!.paidAmount, 1000);
      expect(state.orderItems, before.orderItems);
      expect(state.orderCharges, before.orderCharges);
      expect(state.selectedTable, same(table));
      expect(state.pax, 3);
      expect(state.customerName, 'Tamu');
      expect(state.customerPhone, '08000');
      expect(state.isLoading, before.isLoading);
      expect(state.isProcessing, before.isProcessing);
    }

    expectPhotoOnly(controller.state.products.single, changed.photoUrl);
    expectPhotoOnly(controller.state.productCache[original.id]!, changed.photoUrl);
    expectOperationalStateUnchanged();

    // Product deletion clears the displayed image without rewriting a cart
    // that was already being prepared at its original price.
    products.rows = [];
    await controller.refreshProductPhotos();
    expectPhotoOnly(controller.state.products.single, '');
    expectPhotoOnly(controller.state.productCache[original.id]!, '');
    expectOperationalStateUnchanged();
  });

  test('waiter photo replacement and clearing preserve cart and detail state',
      () async {
    final products = _Products([original]);
    final controller = WaiterController(
        productRepo: products,
        tableRepo: _Tables(table),
        orderRepo: _Orders(order, [item]));
    addTearDown(controller.dispose);
    await controller.selectTableForOrder(table);
    controller.addToCart(original, addons: [addon]);
    controller.addToCart(original);
    controller.updateCartNote(original.id, 'Pisah saus');
    controller.setPax(4);
    controller.setCustomer(name: 'Tamu waiter', phone: '08111');
    await controller.loadTables();
    await controller.viewOrderDetail(table);
    final before = controller.state;

    for (final url in [changed.photoUrl, '']) {
      products.rows = [changed.withPhotoUrl(url)];
      await controller.refreshProductPhotos();
      final state = controller.state;
      expectPhotoOnly(state.products.single, url);
      expectPhotoOnly(state.productCache[original.id]!, url);
      expect(state.cart, {original.id: 2});
      expect(state.cartTotal, 24000);
      expect(state.cartNotes, before.cartNotes);
      expect(state.cartAddons, before.cartAddons);
      expect(state.currentOrder, same(order));
      expect(state.currentOrderItems, before.currentOrderItems);
      expect(state.tableOrders, before.tableOrders);
      expect(state.selectedTable, same(table));
      expect(state.viewMode, 'detail');
      expect(state.pax, 4);
      expect(state.customerName, 'Tamu waiter');
      expect(state.customerPhone, '08111');
      expect(state.isLoading, before.isLoading);
      expect(state.isProcessing, before.isProcessing);
    }
  });
}
