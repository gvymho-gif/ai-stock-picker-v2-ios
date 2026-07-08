import 'dart:async';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';

/// 智能预警服务 — 价格预警 + 技术指标预警 + 新闻预警
class AlertService {
  static final AlertService _instance = AlertService._();
  factory AlertService() => _instance;
  AlertService._();

  static const _keyAlerts = 'price_alerts_v2';
  static const _callbackName = 'alertCheckCallback';

  /// 注册后台任务（仅 Android 使用 flutter_background_service，iOS 跳过）
  static Future<void> registerBackgroundTask() async {
    if (!Platform.isAndroid) return;
    // TODO: iOS 后台任务暂不实现（workmanager 插件与 Xcode 15+ 不兼容）
  }

  /// 添加价格预警
  Future<bool> addPriceAlert({
    required String stockCode,
    required String stockName,
    required double targetPrice,
    required String condition, // 'above' or 'below'
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final alerts = await getAlerts();
    alerts.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'type': 'price',
      'stockCode': stockCode,
      'stockName': stockName,
      'targetPrice': targetPrice,
      'condition': condition,
      'enabled': true,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString(_keyAlerts, _encode(alerts));
    return true;
  }

  /// 添加技术指标预警
  Future<bool> addIndicatorAlert({
    required String stockCode,
    required String stockName,
    required String indicator, // 'macd_golden', 'macd_death', 'rsi_overbought', 'rsi_oversold'
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final alerts = await getAlerts();
    alerts.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'type': 'indicator',
      'stockCode': stockCode,
      'stockName': stockName,
      'indicator': indicator,
      'enabled': true,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString(_keyAlerts, _encode(alerts));
    return true;
  }

  /// 获取所有预警
  Future<List<Map<String, dynamic>>> getAlerts() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_keyAlerts);
    if (str == null) return [];
    try {
      return List<Map<String, dynamic>>.from(_decode(str));
    } catch (_) {
      return [];
    }
  }

  /// 删除预警
  Future<void> deleteAlert(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final alerts = await getAlerts();
    alerts.removeWhere((a) => a['id'] == id);
    await prefs.setString(_keyAlerts, _encode(alerts));
  }

  /// 启用/禁用预警
  Future<void> toggleAlert(String id, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    final alerts = await getAlerts();
    final idx = alerts.indexWhere((a) => a['id'] == id);
    if (idx >= 0) {
      alerts[idx]['enabled'] = enabled;
      await prefs.setString(_keyAlerts, _encode(alerts));
    }
  }

  String _encode(List<Map<String, dynamic>> data) {
    final buf = StringBuffer();
    for (final item in data) {
      buf.writeln(item.entries.map((e) => '${e.key}=${e.value}').join('|'));
    }
    return buf.toString();
  }

  List<Map<String, dynamic>> _decode(String str) {
    final result = <Map<String, dynamic>>[];
    for (final line in str.split('\n')) {
      if (line.trim().isEmpty) continue;
      final map = <String, dynamic>{};
      for (final part in line.split('|')) {
        final kv = part.split('=');
        if (kv.length >= 2) {
          final key = kv[0];
          final value = kv.sublist(1).join('=');
          if (value == 'true') {
            map[key] = true;
          } else if (value == 'false') {
            map[key] = false;
          } else if (double.tryParse(value) != null) {
            map[key] = double.parse(value);
          } else {
            map[key] = value;
          }
        }
      }
      if (map.isNotEmpty) result.add(map);
    }
    return result;
  }
}

/// 后台任务回调（已移除 workmanager 依赖）
@pragma('vm:entry-point')
void callbackDispatcher() {
  // iOS 不再使用 workmanager，此函数保留以避免编译错误
}
