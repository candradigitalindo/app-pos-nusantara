import 'cloud_sync_service.dart';

enum SyncTone { success, warning, error }

/// Pesan hasil tombol Sinkron di kasir, diturunkan dari status SETELAH siklus.
///
/// Dulu tiga keadaan berbeda sama-sama tampil merah ("Offline"/"gagal"),
/// padahal data sudah masuk cloud:
///  - cloud tak terjangkau → memang belum terkirim (merah);
///  - data masih antre (masuk selama sinkron / belum terkonfirmasi) → koneksi
///    sehat, terkirim di siklus berikutnya (kuning);
///  - sebagian item DITOLAK cloud → koneksi & data lain sudah masuk, item itu
///    perlu dibetulkan datanya (kuning, bukan "offline").
({String message, SyncTone tone}) describeManualSync(SyncIndicator? s) {
  if (s == null) {
    return (
      message: 'Status sinkron belum terbaca. Coba lagi.',
      tone: SyncTone.error,
    );
  }
  if (!s.online) {
    final waiting = s.pending + s.rejected;
    return (
      message: waiting > 0
          ? 'Cloud tidak terjangkau. $waiting data aman di tablet dan '
              'dikirim otomatis saat koneksi pulih.'
          : 'Cloud tidak terjangkau. Coba lagi setelah koneksi pulih.',
      tone: SyncTone.error,
    );
  }
  final rejected = s.rejected > 0
      ? '${s.rejected} data ditolak cloud — cek Pengaturan → Status '
          'Sinkronisasi.'
      : '';
  if (s.pending > 0) {
    return (
      message: 'Terhubung ke cloud. ${s.pending} data baru masih antre dan '
          'dikirim otomatis.${rejected.isEmpty ? '' : ' $rejected'}',
      tone: SyncTone.warning,
    );
  }
  if (s.rejected > 0) {
    return (
      message: 'Data lain sudah tersinkron. $rejected',
      tone: SyncTone.warning,
    );
  }
  return (message: 'Tersinkron ke cloud.', tone: SyncTone.success);
}
