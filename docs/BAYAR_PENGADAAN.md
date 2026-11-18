# Bayar Pengadaan dari Kas Kasir Outlet (v10.20)

Bagian Keuangan memilih **Sumber Dana** saat membayar pengajuan pengadaan:
Kantor Pusat (transfer/VA) atau **Kas Kasir Outlet**. Pilihan kedua membuat
*tugas* untuk tablet kasir outlet pengajuan itu — belum ada uang keluar.

## Aturan

- Tugas diambil **langsung dari cloud** (bukan lewat sinkron berkala). Tombol
  **Bayar Pengadaan** + lencana jumlah tugas muncul di header kasir hanya bila
  ada tugas; jumlahnya diperbarui tiap 30 detik selama layar kasir terbuka dan
  dimuat ulang setiap dialog dibuka.
- **Wajib online.** Tablet offline tidak bisa membuka maupun memproses tugas.
- Uang keluar dari laci wajib **PIN Manager/SVP** (sama dengan void).
- Nominal diserahkan **persis** seperti yang ditetapkan. Bila berbeda, kasir
  **Kembalikan ke Keuangan** dengan alasan.
- Kas keluar dicatat di **shift berjalan** (wajib buka kasir), tampil di laporan
  tutup kasir, dan membawa `cash_payout_id` sehingga cloud membukukannya sekali.

## Alur teknis

1. `GET  /api/v1/outlets/:id/procurement-payouts` — tugas terbuka + riwayat 3 hari.
2. **Serahkan Kas** (setelah PIN):
   1. `POST …/:payoutId/claim {movement_local_id, cashier_name, authorized_by}` —
      tugas terkunci (keuangan tidak bisa menarik). Id kas keluar dibuat tablet
      sebelum klaim sehingga klaim ulang idempoten.
   2. Kas keluar dicatat lokal (`cashier_cash_movements.cash_payout_id`, DB v18)
      + outbox `cashier_cash_movement` membawa `cash_payout_id`. Bila gagal,
      tablet memanggil `…/release` (uang belum keluar).
   3. `POST …/:payoutId/complete {movement_local_id}` — cloud mencatat
      pembayaran pengajuan (metode `outlet_cash`). Bila gagal, kas keluar yang
      tersinkron menuntaskannya (jalur tahan-putus); kasir TIDAK mengulang
      penyerahan.
   4. Cetak **Bukti Penyerahan Kas** (tanda tangan kasir & penerima).
3. `POST …/:payoutId/return {reason, cashier_name}` — kembalikan ke Keuangan.
4. Tugas diklaim tapi kas keluarnya tidak ada di tablet → **Batalkan Klaim**
   (`release`) atau **Lanjutkan Penyerahan**; bila kas keluar sudah tercatat →
   **Konfirmasi ke Cloud** (`complete`).

Status tugas: `pending` → `claimed` → `paid`; atau `returned` (kasir) /
`cancelled` (ditarik keuangan sebelum diklaim).

Kode: `lib/services/procurement_payout_service.dart`,
`lib/screens/cashier/procurement_payout_dialog.dart`,
`CashierRepository.recordProcurementPayout`, `ReceiptBuilder.buildCashPayoutProof`.
Tes: `test/procurement_payout_service_test.dart`, `test/procurement_payout_dialog_test.dart`.
