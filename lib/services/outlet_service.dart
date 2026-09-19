import 'package:shared_preferences/shared_preferences.dart';

class OutletService {
  static const String defaultCloudApiUrl = 'https://pos.nbp.co.id';

  static const _keyName = 'outlet_name';
  static const _keyCode = 'outlet_code';
  static const _keyAddress = 'outlet_address';
  static const _keyPhone = 'outlet_phone';
  static const _keySocial = 'outlet_social';
  static const _keyReceiptFooter = 'outlet_receipt_footer';
  static const _keyTargetSpend = 'outlet_target_spend_per_pax';
  static const _keyCloudApiUrl = 'outlet_cloud_api_url';
  static const _keyCloudApiKey = 'outlet_cloud_api_key';
  static const _keyCloudOutletId = 'outlet_cloud_outlet_id';
  static const _keySyncEnabled = 'outlet_sync_enabled';
  static const _keySyncInterval = 'outlet_sync_interval';
  static const _keyRetentionDays = 'outlet_retention_days';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<OutletInfo> loadOutlet() async {
    final prefs = await _prefs;
    var cloudApiUrl = prefs.getString(_keyCloudApiUrl) ?? defaultCloudApiUrl;
    if (cloudApiUrl == 'https://api-pos.nbp.co.id') {
      cloudApiUrl = defaultCloudApiUrl;
      await prefs.setString(_keyCloudApiUrl, cloudApiUrl);
    }
    return OutletInfo(
      name: prefs.getString(_keyName) ?? '',
      code: prefs.getString(_keyCode) ?? '',
      address: prefs.getString(_keyAddress) ?? '',
      phone: prefs.getString(_keyPhone) ?? '',
      socialMedia: prefs.getString(_keySocial) ?? '',
      receiptFooter: prefs.getString(_keyReceiptFooter) ?? '',
      targetSpendPerPax: prefs.getInt(_keyTargetSpend) ?? 0,
      cloudApiUrl: cloudApiUrl,
      cloudApiKey: prefs.getString(_keyCloudApiKey) ?? '',
      cloudOutletId: prefs.getString(_keyCloudOutletId) ?? '',
      syncEnabled: prefs.getBool(_keySyncEnabled) ?? false,
      syncInterval: prefs.getInt(_keySyncInterval) ?? 5,
      retentionDays: prefs.getInt(_keyRetentionDays) ?? 0,
    );
  }

  Future<void> saveOutlet(OutletInfo info) async {
    final prefs = await _prefs;
    await Future.wait([
      prefs.setString(_keyName, info.name),
      prefs.setString(_keyCode, info.code),
      prefs.setString(_keyAddress, info.address),
      prefs.setString(_keyPhone, info.phone),
      prefs.setString(_keySocial, info.socialMedia),
      prefs.setString(_keyReceiptFooter, info.receiptFooter),
      prefs.setInt(_keyTargetSpend, info.targetSpendPerPax),
    ]);
  }

  Future<void> saveCloudSettings({
    required String cloudApiUrl,
    required String cloudApiKey,
    String? cloudOutletId,
    required bool syncEnabled,
    required int syncInterval,
  }) async {
    final prefs = await _prefs;
    await Future.wait([
      prefs.setString(_keyCloudApiUrl, cloudApiUrl),
      prefs.setString(_keyCloudApiKey, cloudApiKey),
      if (cloudOutletId != null) prefs.setString(_keyCloudOutletId, cloudOutletId),
      prefs.setBool(_keySyncEnabled, syncEnabled),
      prefs.setInt(_keySyncInterval, syncInterval),
    ]);
  }

  Future<void> saveRetentionDays(int days) async {
    final prefs = await _prefs;
    await prefs.setInt(_keyRetentionDays, days);
  }

  static const _keyVoidPin = 'manager_void_pin';

  /// PIN manager untuk otorisasi void order. Default '1234'.
  Future<String> getVoidPin() async {
    final prefs = await _prefs;
    return prefs.getString(_keyVoidPin) ?? '1234';
  }
}

class OutletInfo {
  final String name;
  final String code;
  final String address;
  final String phone;
  final String socialMedia;
  final String receiptFooter;
  final int targetSpendPerPax;
  final String cloudApiUrl;
  final String cloudApiKey;
  final String cloudOutletId;
  final bool syncEnabled;
  final int syncInterval;
  final int retentionDays;

  const OutletInfo({
    this.name = '',
    this.code = '',
    this.address = '',
    this.phone = '',
    this.socialMedia = '',
    this.receiptFooter = '',
    this.targetSpendPerPax = 0,
    this.cloudApiUrl = '',
    this.cloudApiKey = '',
    this.cloudOutletId = '',
    this.syncEnabled = false,
    this.syncInterval = 5,
    this.retentionDays = 0,
  });

  OutletInfo copyWith({
    String? name,
    String? code,
    String? address,
    String? phone,
    String? socialMedia,
    String? receiptFooter,
    int? targetSpendPerPax,
    String? cloudApiUrl,
    String? cloudApiKey,
    String? cloudOutletId,
    bool? syncEnabled,
    int? syncInterval,
    int? retentionDays,
  }) {
    return OutletInfo(
      name: name ?? this.name,
      code: code ?? this.code,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      socialMedia: socialMedia ?? this.socialMedia,
      receiptFooter: receiptFooter ?? this.receiptFooter,
      targetSpendPerPax: targetSpendPerPax ?? this.targetSpendPerPax,
      cloudApiUrl: cloudApiUrl ?? this.cloudApiUrl,
      cloudApiKey: cloudApiKey ?? this.cloudApiKey,
      cloudOutletId: cloudOutletId ?? this.cloudOutletId,
      syncEnabled: syncEnabled ?? this.syncEnabled,
      syncInterval: syncInterval ?? this.syncInterval,
      retentionDays: retentionDays ?? this.retentionDays,
    );
  }
}
