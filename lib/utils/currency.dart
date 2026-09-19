import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Formatter input nominal: menambahkan pemisah ribuan (titik) saat mengetik,
/// mis. "41800" → "41.800". Parsing balik: CurrencyHelper.parseInput.
class RupiahInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return const TextEditingValue(text: '');
    final formatted = CurrencyHelper.formatInput(digits);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class CurrencyHelper {
  /// "41800" / 41800 → "41.800" (tanpa simbol, untuk isi field input).
  static String formatInput(Object value) {
    final digits = value.toString().replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
      buf.write(digits[i]);
    }
    return buf.toString();
  }

  /// Teks field ber-format ("41.800") → nilai double (41800).
  static double parseInput(String text) =>
      double.tryParse(text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  static final _format = NumberFormat.currency(
    locale: 'id_ID',
    symbol: 'Rp ',
    decimalDigits: 0,
  );

  static String format(double amount) {
    return _format.format(amount);
  }
}
