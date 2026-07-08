/// 收益统计 - 后台任务Worker
///
/// 配合Android WorkManager / flutter_background_service，实现后台自动更新
/// iOS 因 Xcode 15+ 兼容性问题已移除 workmanager 依赖

import 'dart:async';
import 'dart:io' show Platform;
// import 'package:workmanager/workmanager.dart'; // 已移除：iOS 不兼容
import 'expert_performance_service.dart';

/// 后台任务回调调度器（必须是顶级函数，不能放在class里）
@pragma('vm:entry-point')
void callbackDispatcher() {
  // 已移除 workmanager 依赖
  print('callbackDispatcher: workmanager 已移除，此函数保留以避免编译错误');
}

/// 后台执行检查（结算已过期记录 + 创建新记录）
/// 每日循环：20:00创建新记录（锁定6只+起始价）→ 次日19:30结算 → 20:00新一轮
/// 有效期：创建日20:00 ~ 次日19:30
/// 结算时间推迟到19:30：15:00收盘时API数据可能不准确，19:30后数据已更新
Future<void> _checkAndExecuteInBackground() async {
  try {
    print('后台任务开始执行...');

    final now = DateTime.now();
    final today = _formatDate(now);
    // 当前有效期内的记录日期
    final activeDate = now.hour >= 20 ? today : _formatDate(now.subtract(const Duration(days: 1)));

    // 1. 19:30后结算所有已过有效期的记录（仅交易日）
    final isSettleWindow = now.hour > 19 || (now.hour == 19 && now.minute >= 30);
    if (isSettleWindow && ExpertPerformanceService.isTradingDay()) {
      final history = await ExpertPerformanceService.getHistory();
      final needSettleCount = history.where((r) {
        if (r.date == activeDate) return false; // 跳过当前有效期内的
        if (!r.isSettled) return true;
        if (r.stocks.every((s) => s.changePercent == 0)) return true;
        return false;
      }).length;

      if (needSettleCount > 0) {
        print('发现 $needSettleCount 条需要结算的记录，开始结算...');
        await ExpertPerformanceService.autoSettleYesterdayRecord();
        print('结算完成');
      }
    }

    // 2. 如果今天没有记录且已过20:00，创建今日记录
    final isCreateWindow = now.hour >= 20;
    final latestHistory = await ExpertPerformanceService.getHistory();
    final todayExists = latestHistory.any((r) => r.date == today);
    if (!todayExists && ExpertPerformanceService.isTradingDay() && isCreateWindow) {
      print('开始创建今日记录: $today');
      await ExpertPerformanceService.autoCreateTodayRecord();
      print('创建完成');
    }

    print('后台任务执行完成');
  } catch (e, stackTrace) {
    print('后台任务执行失败: $e');
    print('堆栈: $stackTrace');
  }
}

/// 格式化日期
String _formatDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

/// 专家选股后台Worker注册类
class ExpertPerformanceWorker {
  static const String checkAndExecute = 'check_and_execute';

  /// 注册周期性后台任务（仅 Android，iOS 跳过）
  static Future<void> registerTask() async {
    if (!Platform.isAndroid) {
      print('registerTask: iOS 平台跳过 workmanager 注册');
      return;
    }
    // TODO: Android 端可改用 flutter_background_service 替代
    print('registerTask: 后台任务暂未实现（workmanager 已移除）');
  }

  /// 取消后台任务（仅 Android）
  static Future<void> cancelTask() async {
    if (!Platform.isAndroid) return;
    print('cancelTask: 后台任务取消跳过');
  }

  /// 手动触发检查（供前台调用）
  static Future<void> executeCheck() async {
    await _checkAndExecuteInBackground();
  }
}
