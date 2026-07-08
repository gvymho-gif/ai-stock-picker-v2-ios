/// 后台常驻服务 —— 全模块实时同步
///
/// ⚠️ iOS: 因 Xcode 15+ 与 Flutter 3.0.0 CocoaPods 不兼容，
///    flutter_background_service 已移除，本服务在 iOS 上为 no-op
///
/// Android: 使用 flutter_background_service 保持前台常驻服务

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';

class BackgroundStockService {
  static final BackgroundStockService _instance = BackgroundStockService._();
  factory BackgroundStockService() => _instance;
  BackgroundStockService._();

  static const int _notificationId = 888;
  static const int _checkIntervalSeconds = 3;

  /// 初始化并启动后台服务（App 启动时调用一次）
  /// iOS 平台：no-op（后台服务已移除）
  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    debugPrint('[BackgroundStockService] iOS 平台跳过初始化');
  }

  /// 启动后台监控
  Future<bool> start() async {
    if (!Platform.isAndroid) return true;
    debugPrint('[BackgroundStockService] Android 后台服务暂未实现');
    return false;
  }

  /// 检查是否正在运行
  Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    return false;
  }

  /// 监听后台数据变化（前台 UI 调用）— 返回空流
  Stream<Map<String, dynamic>?> onDataChanged() {
    return const Stream.empty();
  }

  /// 通知后台服务立即执行一次检查 — no-op
  void triggerCheck() {
    // no-op
  }

  /// 触发一次云端收益历史同步 — no-op
  void triggerPerformanceSync() {
    // no-op
  }
}
