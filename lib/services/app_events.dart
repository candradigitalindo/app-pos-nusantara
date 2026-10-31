import 'dart:async';

import 'package:flutter/widgets.dart';

import 'local_api_server.dart';

/// Kanal perubahan data di dalam SATU perangkat.
///
/// Dipakai supaya layar yang sedang terbuka (Meja, Kasir, Dapur, Waiter,
/// Dashboard) ikut menyegar saat data order/meja berubah — termasuk perubahan
/// yang datang dari perangkat lain lewat [LocalApiServer] (station memesan,
/// station membayar). Tanpa ini, perubahan hanya terlihat setelah pengguna
/// menekan Muat Ulang atau membuka ulang layarnya.
///
/// Sisi sebaliknya (perubahan di perangkat utama → station) ditangani
/// [LocalApiServer.broadcast]: repositori memanggil [notifyDataChanged] yang
/// menyiarkan ke station sekaligus mengabari layar lokal.
class AppEvents {
  static final AppEvents instance = AppEvents._();
  AppEvents._();

  final _controller = StreamController<String>.broadcast();

  /// Nama event mengikuti event WebSocket station: order_created,
  /// order_items_added, order_paid, order_updated.
  Stream<String> get stream => _controller.stream;

  void emit(String event) {
    if (!_controller.isClosed) _controller.add(event);
  }
}

/// Beritahu SEMUA yang perlu tahu bahwa data order/meja berubah di perangkat
/// ini: layar lokal (lewat [AppEvents]) dan station yang terhubung (lewat
/// WebSocket [LocalApiServer], bila server-nya hidup).
///
/// Aman dipanggil dari repositori mana pun — bila mode Station tidak aktif,
/// [LocalApiServer.broadcast] hanya mengabari layar lokal.
void notifyDataChanged(String event) =>
    LocalApiServer.instance.broadcast(event, const {});

/// Dipakai State layar yang harus ikut menyegar saat data order/meja berubah.
///
/// Pemanggilan di-debounce: satu aksi sering menghasilkan beberapa event
/// beruntun (mis. bayar → meja jadi kosong), dan layar cukup memuat ulang
/// sekali.
mixin AppEventsRefresh<T extends StatefulWidget> on State<T> {
  StreamSubscription<String>? _appEventsSub;
  Timer? _appEventsDebounce;

  /// Muat ulang data layar ini.
  void onDataChanged();

  void listenDataChanges() {
    _appEventsSub = AppEvents.instance.stream.listen((_) {
      _appEventsDebounce?.cancel();
      _appEventsDebounce = Timer(const Duration(milliseconds: 350), () {
        if (mounted) onDataChanged();
      });
    });
  }

  void cancelDataChanges() {
    _appEventsSub?.cancel();
    _appEventsSub = null;
    _appEventsDebounce?.cancel();
    _appEventsDebounce = null;
  }
}
