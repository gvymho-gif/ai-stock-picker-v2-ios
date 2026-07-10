/// 收益统计组件
///
/// 在首页实时资讯模块下面显示
/// 包含每日明细表、核心统计指标、可视化图表
/// 支持手动添加每日收益记录
/// 支持全自动更新（打开APP时自动检查并执行）
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../theme/app_theme.dart';
import '../theme/app_text.dart';
import '../services/expert_performance_service.dart';
import '../services/backup_service.dart';
import '../services/jianguoyun_service.dart';
import '../services/local_data_service.dart';
import '../services/trading_day_cloud_service.dart';
import '../services/hot_investment_service.dart';
import '../services/background_service.dart';
import '../models/hot_investment_model.dart';
import '../models/trading_day_record.dart';
import '../screens/trading_day_records_screen.dart';
import '../utils/trading_day_utils.dart';

/// 统计项数据类
class _StatItem {
  final String label;
  final String value;
  final Color color;

  _StatItem(this.label, this.value, this.color);
}

class _StatItemWithIcon {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String label;
  final String value;
  final Color valueColor;

  const _StatItemWithIcon({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.valueColor,
  });
}

/// 收益统计组件
class ExpertPerformanceWidget extends StatefulWidget {
  const ExpertPerformanceWidget({Key? key}) : super(key: key);

  @override
  State<ExpertPerformanceWidget> createState() => _ExpertPerformanceWidgetState();
}

class _ExpertPerformanceWidgetState extends State<ExpertPerformanceWidget> with WidgetsBindingObserver {
  List<DailyExpertPerformance> _history = [];
  bool _loading = true;  // 首次加载状态
  bool _isRefreshing = false;  // ★ 后台刷新状态（不显示整体loading）
  bool _expanded = false;
  bool _showAddForm = false;
  bool _settling = false; // 结算进行中
  bool _recreating = false; // 重建进行中
  bool _backingUp = false; // 备份进行中
  bool _restoring = false; // 恢复进行中
  bool _exporting = false; // 本地导出进行中
  bool _importing = false; // 本地导入进行中
  bool _jgyUploading = false; // 坚果云上传
  bool _jgyDownloading = false; // 坚果云下载
  bool _autoSettling = false; // 自动结算开关
  Timer? _autoSettleTimer; // 自动结算定时器
  List<TradingDayRecord> _tradingRecords = []; // 交易日记录缓存
  // 沪深300日涨跌幅缓存：Map<日期YYYY-MM-DD, 涨跌幅%>
  Map<String, double> _hs300DailyChanges = {};
  // 中证1000日涨跌幅缓存：Map<日期YYYY-MM-DD, 涨跌幅%>
  Map<String, double> _zz1000DailyChanges = {};

  // ★ 时间范围筛选状态
  int _trendTimeRange = 1; // 0=近7天, 1=近30天, 2=近90天, 3=自定义, 4=全部
  int _barTimeRange = 1;   // 0=近7天, 1=近30天, 2=近90天, 3=自定义, 4=全部
  DateTime? _trendCustomStart; // 自定义起始日期
  DateTime? _trendCustomEnd;   // 自定义结束日期
  DateTime? _barCustomStart;   // 柱状图自定义起始日期
  DateTime? _barCustomEnd;     // 柱状图自定义结束日期
  int? _trendTooltipIndex;     // 已废弃，保留兼容
  Offset? _trendPointerDownPos; // 趋势图按下位置（区分点击/拖动）

  // 实时价格刷新相关
  Timer? _refreshTimer; // 定时刷新器
  bool _refreshingPrices = false; // 正在刷新价格
  Map<String, double> _liveChangePercents = {}; // 实时涨跌幅缓存: stockCode → changePercent
  bool _wasTradingTime = false; // 上一轮是否处于交易时间（用于检测交易结束时刻）
  int _refreshCount = 0; // 刷新计数器（用于节流保存）
  StreamSubscription<Map<String, dynamic>?>? _bgSub; // 后台数据变更监听

  // 表单控制器
  final _dateCtrl = TextEditingController();
  final List<StockFormData> _stockForms = [];

  /// 修正股票代码格式：.SH → .SS，纯数字推断交易所
  static String _fixStockCode(String code) {
    if (!code.contains('.')) return code; // 纯数字，不处理
    final parts = code.split('.');
    if (parts.length != 2) return code;
    final numCode = parts[0];
    final suffix = parts[1].toUpperCase();
    // .SH → .SS（新浪格式转项目格式）
    if (suffix == 'SH') return '$numCode.SS';
    // 已经是标准格式
    if (suffix == 'SS' || suffix == 'SZ' || suffix == 'BJ') return code;
    return code;
  }

  /// 安全转 double
  static double _safeDoubleVal(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  /// 显示提示
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _addStockForm(); // 至少添加一个表单
    _loadDataQuietly(); // ★ 静默加载：先显示缓存数据，后台更新
    _checkAndExecute(); // 打开APP时立即检查并执行
    _startLiveRefresh(); // 启动实时价格刷新

    // ★ 监听后台服务数据变更通知
    _bgSub = BackgroundStockService().onDataChanged().listen((data) {
      if (data != null && mounted) {
        final module = data['module']?.toString() ?? '';
        if (module == 'expert_performance' || module.isEmpty) {
          // 后台已更新 SharedPreferences，静默重新加载
          _loadData(silent: true);
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从后台恢复到前台时，静默检查是否需要创建/结算
      _checkAndExecute();
      // 回到前台时，如果在结算窗口期则静默刷新价格
      if (_isSettlementWindow()) {
        _refreshLivePrices();
      }
      // ★ 后台服务可能已更新 SharedPreferences，强制从磁盘重新加载
      _loadData(silent: true);
    } else if (state == AppLifecycleState.paused) {
      // ★ App进入后台时保存当前交易数据，防止被系统杀掉后数据丢失
      _saveCurrentTradingData();
    }
  }

  // ★ 是否已在20:00后自动创建了今日记录（防止重复触发）
  bool _hasAutoCreatedTodayRecord = false;

  /// 启动实时价格定时刷新（每3秒，仅在交易时间段）
  /// ★ 交易结束时自动保存数据到SharedPreferences（冻结收盘数据）
  /// ★ 20:00后自动创建今日选股记录（每晚20:00自动获取最新6只股票）
  void _startLiveRefresh() {
    _refreshTimer?.cancel();
    _wasTradingTime = _isSettlementWindow();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final inWindow = _isSettlementWindow();
      if (inWindow) {
        _wasTradingTime = true;
        _refreshLivePrices();
        _refreshCount++;
        // ★ 每30秒保存一次到SharedPreferences（10次刷新 = 30秒），确保数据持久化
        if (_refreshCount % 10 == 0) {
          _saveCurrentTradingData();
        }
        // ★ 在结算窗口内，说明还没到20:00，重置创建标记
        _hasAutoCreatedTodayRecord = false;
      } else if (_wasTradingTime) {
        // ★ 刚离开结算窗口（19:30），保存当前数据作为收盘冻结数据
        _wasTradingTime = false;
        _saveCurrentTradingData();
        print('[收益统计] 结算窗口结束（19:30），数据已冻结保存');
      }

      // ★ 20:00后自动创建今日选股记录（每晚20:00获取最新6只股票）
      // App在前台时，定时器会持续运行，19:30后也会每3秒tick一次
      // 检测到20:00后且今日记录不存在时，自动触发创建
      final now = DateTime.now();
      final isAfter20 = now.hour >= 20;
      if (isAfter20 && !_hasAutoCreatedTodayRecord) {
        _hasAutoCreatedTodayRecord = true; // 标记已触发，防止重复
        _checkAndExecute(); // 创建今日记录
      }
    });
    // 首次延迟3秒后刷新
    Future.delayed(const Duration(seconds: 3), () {
      if (_isSettlementWindow()) {
        _refreshLivePrices();
      }
      // ★ 如果启动时已过20:00且今日无记录，立即创建
      final now = DateTime.now();
      if (now.hour >= 20 && !_hasAutoCreatedTodayRecord) {
        _hasAutoCreatedTodayRecord = true;
        _checkAndExecute();
      }
    });
  }

  /// 判断当前是否在A股正式交易时间段（9:30-15:00）
  /// ★ 9:30开盘，15:00收盘；集合竞价阶段不参与止盈止损判断
  bool _isTradingTime() {
    final now = DateTime.now();
    // ★ 非交易日（周末+节假日）不算交易时间
    if (!TradingDayUtils.isSecuritiesTradingDay(now)) return false;
    final hour = now.hour;
    final minute = now.minute;
    final timeInMinutes = hour * 60 + minute;

    // 上午交易时间: 9:30 - 11:30
    final amStart = 9 * 60 + 30;  // 9:30
    final amEnd = 11 * 60 + 30;   // 11:30

    // 下午交易时间: 13:00 - 15:00
    final pmStart = 13 * 60;      // 13:00
    final pmEnd = 15 * 60;        // ★ 15:00收盘

    return (timeInMinutes >= amStart && timeInMinutes <= amEnd) ||
           (timeInMinutes >= pmStart && timeInMinutes <= pmEnd);
  }

  /// 判断当前是否在结算时间窗口（9:30-15:05）
  /// 此期间涨跌幅数据实时更新，15:05后才结算冻结
  /// ★ 9:30起才刷新（集合竞价阶段9:15-9:30价格不稳定）
  bool _isSettlementWindow() {
    final now = DateTime.now();
    // ★ 非交易日（周末+节假日）不算结算窗口
    if (!TradingDayUtils.isSecuritiesTradingDay(now)) return false;
    final timeInMinutes = now.hour * 60 + now.minute;
    final windowStart = 9 * 60 + 30;   // ★ 9:30（集合竞价阶段不刷新）
    final windowEnd = 15 * 60 + 5;    // 15:05
    return timeInMinutes >= windowStart && timeInMinutes < windowEnd;
  }

  /// 判断当前是否在收盘后冻结期（15:05-20:00）
  /// 此期间涨跌幅数据已结算冻结，不再从API更新
  bool _isPostMarketTime() {
    final now = DateTime.now();
    final timeInMinutes = now.hour * 60 + now.minute;
    final postMarketStart = 15 * 60 + 5;  // 15:05
    final postMarketEnd = 20 * 60;         // 20:00
    return timeInMinutes >= postMarketStart && timeInMinutes < postMarketEnd;
  }

  /// 交易时间结束时保存当前数据到SharedPreferences
  /// 确保15:05后的收盘数据持久化，app重启后不会丢失
  Future<void> _saveCurrentTradingData() async {
    if (_history.isEmpty) return;

    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();
    
    // 确定当前应该显示哪天的记录
    String displayDate;
    if (now.hour >= 20) {
      displayDate = today;
    } else {
      displayDate = _getYesterdayString();
      if (!_history.any((r) => r.date == displayDate)) {
        if (_history.isNotEmpty) {
          displayDate = _history.first.date;
        }
      }
    }

    var activeRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    if (activeRecord.stocks.isEmpty && _history.isNotEmpty) {
      activeRecord = _history.first;
    }
    if (activeRecord.stocks.isEmpty) return;
    if (activeRecord.isSettled) return; // 已结算的不需要保存

    // 将实时缓存数据写入记录
    bool anyUpdated = false;
    for (var stock in activeRecord.stocks) {
      final liveChange = _liveChangePercents[stock.code];
      if (liveChange != null) {
        stock.changePercent = liveChange;
        anyUpdated = true;
      }
    }

    if (anyUpdated) {
      // 重新计算统计数据
      double totalChange = 0;
      int upCount = 0;
      int downCount = 0;
      for (var stock in activeRecord.stocks) {
        totalChange += stock.changePercent;
        if (stock.changePercent > 0) upCount++;
        else if (stock.changePercent < 0) downCount++;
      }
      activeRecord.dailyAvgChange = totalChange / activeRecord.stocks.length;
      activeRecord.upCount = upCount;
      activeRecord.downCount = downCount;

      // 保存到SharedPreferences
      await ExpertPerformanceService.saveDailyRecord(activeRecord);
      print('[收益统计] 交易数据已保存: ${activeRecord.date}, 平均涨跌=${activeRecord.dailyAvgChange.toStringAsFixed(2)}%');
    }
  }

  /// 实时刷新当前显示股票的价格
  /// ★ 交易时间(9:30-15:05)内每3秒调用一次
  /// ★ 并行请求6只股票，确保3秒内完成刷新
  /// ★ 同时更新 _liveChangePercents（UI显示）和 stock.changePercent（持久化备用）
  /// ★ 交易时间内无论记录是否已结算，都实时刷新显示
  Future<void> _refreshLivePrices() async {
    if (_refreshingPrices || !mounted) return;
    if (_history.isEmpty) return;

    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();
    
    // 确定当前应该显示哪天的记录
    String displayDate;
    if (now.hour >= 20) {
      displayDate = today;
    } else {
      displayDate = _getYesterdayString();
      // 如果昨天没有记录，找历史记录中最近的日期
      if (!_history.any((r) => r.date == displayDate)) {
        if (_history.isNotEmpty) {
          displayDate = _history.first.date;
        }
      }
    }

    // 找到当前显示的记录（优先displayDate，找不到则用最新一条）
    var activeRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    if (activeRecord.stocks.isEmpty && _history.isNotEmpty) {
      activeRecord = _history.first;
    }
    if (activeRecord.stocks.isEmpty) return;

    // ★ 交易时间内：无论是否已结算，都实时刷新（用户需要看到当前涨跌幅）
    // 非交易时间：已结算的记录不需要刷新

    _refreshingPrices = true;
    try {
      final api = LocalDataService();

      // ★ 并行请求所有股票数据（6只同时请求，总耗时≈单只耗时，远小于3秒）
      final futures = activeRecord.stocks.map((stock) async {
        try {
          final stockData = await api.searchStock(stock.code);
          if (stockData.isNotEmpty) {
            final changePct = _safeDoubleVal(stockData['change_pct']);
            if (changePct != 0) {
              return MapEntry(stock.code, changePct);
            } else {
              // API未返回涨跌幅时回退到自行计算
              final currentPrice = _safeDoubleVal(stockData['price']);
              if (currentPrice > 0 && stock.startPrice > 0) {
                final changePercent = (currentPrice - stock.startPrice) / stock.startPrice * 100;
                return MapEntry(stock.code, changePercent);
              }
            }
          }
        } catch (_) {
          // 忽略单只股票的获取失败
        }
        return null;
      }).toList();

      // 等待所有请求完成
      final results = await Future.wait(futures);

      // 更新缓存和记录
      bool anyUpdated = false;
      for (int i = 0; i < results.length; i++) {
        final result = results[i];
        if (result != null) {
          final code = result.key;
          final changePct = result.value;
          _liveChangePercents[code] = changePct;
          // ★ 结算窗口期内：无论是否已结算，都同步更新changePercent
          activeRecord.stocks[i].changePercent = changePct;
          anyUpdated = true;
        }
      }

      // ★★★ 关键修复：结算窗口期内实时保存数据 ★★★
      // 之前只在 !activeRecord.isSettled 时才保存，导致已结算记录在交易时间内不会更新
      // 正确逻辑：结算窗口期内(9:30-19:30)无论是否已结算，都实时更新保存
      // 19:30后数据才冻结，不再更新
      if (anyUpdated) {
        // 重新计算 totalChange 和 avgChange
        double totalChange = 0.0;
        int upCount = 0;
        int downCount = 0;
        for (var stock in activeRecord.stocks) {
          final cp = stock.changePercent;
          totalChange += cp;
          if (cp > 0) upCount++;
          if (cp < 0) downCount++;
        }
        activeRecord.dailyAvgChange = totalChange / (activeRecord.stocks.isNotEmpty ? activeRecord.stocks.length : 1);
        activeRecord.upCount = upCount;
        activeRecord.downCount = downCount;
        // ★ 保存到 SharedPreferences（持久化）
        await ExpertPerformanceService.saveDailyRecord(activeRecord);

        // ★ 同步更新 _tradingRecords 缓存，让 _buildCoreStats 能读到最新数据
        final codes = activeRecord.stocks.map((s) => s.code).toList();
        final names = activeRecord.stocks.map((s) => s.name).toList();
        final changes = activeRecord.stocks.map((s) => s.changePercent).toList();
        // 找到 _tradingRecords 中对应的记录并更新
        bool tradingRecordFound = false;
        for (int idx = 0; idx < _tradingRecords.length; idx++) {
          if (_tradingRecords[idx].date == activeRecord.date) {
            _tradingRecords[idx] = TradingDayRecord(
              date: activeRecord.date,
              stockCodes: codes,
              stockNames: names,
              stockChanges: changes,
              totalChangePercent: totalChange,
              avgChangePercent: totalChange / (codes.isNotEmpty ? codes.length : 1),
              notes: _tradingRecords[idx].notes,
              reviewContent: _tradingRecords[idx].reviewContent,
              reviewGeneratedAt: _tradingRecords[idx].reviewGeneratedAt,
            );
            tradingRecordFound = true;
            break;
          }
        }
        // ★ 如果 _tradingRecords 中没有该日期的记录，创建一条新的
        if (!tradingRecordFound) {
          final newTradingRecord = TradingDayRecord(
            date: activeRecord.date,
            stockCodes: codes,
            stockNames: names,
            stockChanges: changes,
            totalChangePercent: totalChange,
            avgChangePercent: totalChange / (codes.isNotEmpty ? codes.length : 1),
            notes: '',
          );
          _tradingRecords.insert(0, newTradingRecord);
          _tradingRecords.sort((a, b) => b.date.compareTo(a.date));
        }

        // ★ 同时保存到 TradingDayCloudService（云端同步）
        try {
          final updatedRecord = TradingDayRecord(
            date: activeRecord.date,
            stockCodes: codes,
            stockNames: names,
            stockChanges: changes,
            totalChangePercent: totalChange,
            avgChangePercent: totalChange / (codes.isNotEmpty ? codes.length : 1),
            notes: '',
            reviewContent: null,
            reviewGeneratedAt: null,
          );
          await TradingDayCloudService.addRecord(updatedRecord);
        } catch (e) {
          print('[收益统计] 保存交易日记录失败: $e');
        }

        print('[收益统计] 实时数据已保存: ${activeRecord.date}, avg=${activeRecord.dailyAvgChange.toStringAsFixed(2)}%');
      }

      if (mounted && anyUpdated) {
        // ★ 仅在有数据变化时 setState，触发数字更新
        // 不传空 setState，避免无意义的整体重建
        setState(() {
          // _liveChangePercents 和 activeRecord.stocks 已经就地更新
          // 这里只需通知 Flutter 重新读取这些值来更新UI
        });
      }
    } finally {
      _refreshingPrices = false;
    }
  }

  /// 检查并执行相应操作（打开APP时调用）
  Future<void> _checkAndExecute() async {
    try {
      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // === 第0步：修正所有股票的code格式 ===
      final history = await ExpertPerformanceService.getHistory();
      bool codeFixed = false;
      for (var record in history) {
        for (var stock in record.stocks) {
          final fixedCode = _fixStockCode(stock.code);
          if (fixedCode != stock.code) {
            print('[收益统计] 修正代码: ${stock.code} → $fixedCode');
            stock.code = fixedCode;
            codeFixed = true;
          }
        }
        if (codeFixed) {
          await ExpertPerformanceService.saveDailyRecord(record);
        }
      }

      // === 第1步：自动结算 ===
      // 结算所有已过有效期的记录（不限制时间，确保收市后数据能被正确结算）
      // 有效期：创建日20:00 ~ 次日19:00，过了有效期的记录都需要结算
      await _forceSettle(history, today);

      // === 第2步：创建今日记录 ===
      // 创建时间：每天20:00后
      // 记录有效期：20:00 ~ 次日19:00
      final isCreateWindow = now.hour >= 20;
      final latestHistory = await ExpertPerformanceService.getHistory();
      final todayRecordExists = latestHistory.any((r) => r.date == today);

      print('[收益统计] 检查创建: hour=${now.hour}, isCreateWindow=$isCreateWindow, todayRecordExists=$todayRecordExists');

      if (!todayRecordExists && isCreateWindow) {
        print('[收益统计] 开始创建今日记录: $today');
        final created = await ExpertPerformanceService.autoCreateTodayRecord();
        if (created) {
          // ★ 新记录创建成功：清除旧股票的实时缓存，确保新股票显示0.00%
          _liveChangePercents.clear();
          await _loadData();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已创建今日选股记录'),
                duration: Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } else {
          print('[收益统计] 创建今日记录失败');
          if (mounted) {
            _showSnackBar('自动创建记录失败，请点击🔄按钮手动刷新');
          }
        }
      }
    } catch (e) {
      print('[收益统计] 自动检查执行失败: $e');
    }
  }

  /// 切换自动结算开关
  void _toggleAutoSettle() {
    if (_autoSettling) {
      // 关闭
      _autoSettleTimer?.cancel();
      _autoSettleTimer = null;
      setState(() => _autoSettling = false);
      _showSnackBar('已暂停自动结算');
    } else {
      // 检查是否在交易时间
      if (!_isTradingTime()) {
        _showSnackBar('当前非交易时间，无法启动自动结算');
        return;
      }
      // 开启
      setState(() => _autoSettling = true);
      _showSnackBar('🔄 自动结算已启动（每3秒）');
      // 立即执行一次
      _doAutoSettle();
      // 每3秒执行
      _autoSettleTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!_isTradingTime()) {
          _autoSettleTimer?.cancel();
          _autoSettleTimer = null;
          if (mounted) {
            setState(() => _autoSettling = false);
            _showSnackBar('已离开交易时间，自动结算已暂停');
          }
          return;
        }
        _doAutoSettle();
      });
    }
  }

  /// 执行一次自动结算（只刷新当前显示记录的实时价格到UI）
  Future<void> _doAutoSettle() async {
    if (!mounted || _history.isEmpty) return;

    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();
    
    // 确定当前应该显示哪天的记录
    String displayDate;
    if (now.hour >= 20) {
      displayDate = today;
    } else {
      displayDate = _getYesterdayString();
      if (!_history.any((r) => r.date == displayDate)) {
        if (_history.isNotEmpty) {
          displayDate = _history.first.date;
        }
      }
    }

    var activeRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    if (activeRecord.stocks.isEmpty && _history.isNotEmpty) {
      activeRecord = _history.first;
    }
    if (activeRecord.stocks.isEmpty) return;

    // 获取实时价格并更新 liveChangePercents
    final api = LocalDataService();
    bool anyUpdated = false;
    for (var stock in activeRecord.stocks) {
      try {
        final currentPrice = await api.getPrice(stock.code);
        if (currentPrice > 0 && stock.startPrice > 0) {
          final changePercent = (currentPrice - stock.startPrice) / stock.startPrice * 100;
          _liveChangePercents[stock.code] = changePercent;
          anyUpdated = true;
        }
      } catch (_) {}
    }

    if (anyUpdated && mounted) {
      setState(() {});
    }
  }

  /// 强制结算所有已过有效期的记录
  /// 结算条件：
  /// - 昨天的记录：19:30前允许重新结算（因为15:00收盘时API数据可能不准确）
  /// - 更早的记录：未结算 或 假结算(changePercent全为0)
  /// - ⚠️ 今天新创建的记录：不处理（还没到收盘时间）
  /// - 19:30为硬截止，之后不再修改昨天数据，确保20:00创建新记录不受干扰
  Future<void> _forceSettle(List<DailyExpertPerformance> history, String today) async {
    final now = DateTime.now();
    final isBeforeSettlementDeadline = now.hour < 19 || (now.hour == 19 && now.minute < 30);
    final yesterday = _getYesterdayString();

    // 筛选需要结算的记录
    final settleableRecords = history.where((r) {
      if (r.date == today) {
        // 今天的记录：不处理（新创建的记录，还没到收盘）
        return false;
      }
      if (r.date == yesterday) {
        // 昨天的记录：仅19:30前允许重新结算
        return isBeforeSettlementDeadline;
      }
      // 更早的记录：检查是否已超过有效期（创建日20:00 → 下一个交易日19:00）
      if (r.stocks.every((s) => s.changePercent == 0)) return true; // 假结算，重新结算
      if (!r.isSettled) {
        // 未结算的记录：检查当前时间是否已超过该记录的有效期截止时间
        // 有效期截止到记录日期的下一个交易日的19:00
        final recordDate = DateTime.parse(r.date);
        final nextTradingDay = _getNextTradingDay(recordDate);
        final deadline = DateTime(nextTradingDay.year, nextTradingDay.month, nextTradingDay.day, 19, 0);
        // 如果当前时间已超过截止时间，才进行结算
        return now.isAfter(deadline);
      }
      return false;
    }).toList();

    if (settleableRecords.isEmpty) {
      return; // 没有需要结算的记录，静默返回
    }

    setState(() => _settling = true);

    final api = LocalDataService();
    int settledCount = 0;
    int failedCount = 0;
    final debugInfo = <String>[];

    for (var record in settleableRecords) {
      debugInfo.add('日期: ${record.date}, 股票数: ${record.stocks.length}');
      double totalChange = 0;
      int upCount = 0;
      int downCount = 0;
      int successCount = 0;

      for (var stock in record.stocks) {
        try {
          // 使用 searchStock 获取完整行情数据，直接用API返回的涨跌幅
          final stockData = await api.searchStock(stock.code);
          debugInfo.add('  ${stock.name}(${stock.code})');
          if (stockData.isNotEmpty) {
            final currentPrice = _safeDoubleVal(stockData['price']);
            final changePct = _safeDoubleVal(stockData['change_pct']);
            debugInfo.add('    现价=$currentPrice, API涨跌=${changePct.toStringAsFixed(2)}%, 起始价=${stock.startPrice}');

            if (currentPrice > 0 && stock.startPrice > 0) {
              stock.settlementPrice = currentPrice;
              // 优先使用API直接返回的涨跌幅（基于昨收价计算，与盘中显示一致）
              if (changePct != 0) {
                stock.changePercent = changePct;
              } else {
                stock.changePercent = (currentPrice - stock.startPrice) / stock.startPrice * 100;
              }
              totalChange += stock.changePercent;
              if (stock.changePercent > 0) {
                upCount++;
              } else if (stock.changePercent < 0) {
                downCount++;
              }
              successCount++;
            } else {
              totalChange += 0;
              debugInfo.add('    → 跳过: 现价或起始价为0');
            }
          } else {
            totalChange += 0;
            debugInfo.add('    → 获取行情数据失败');
          }
        } catch (e) {
          totalChange += 0;
          debugInfo.add('  ${stock.name}(${stock.code}) 异常: $e');
        }
      }

      if (successCount > 0 && record.stocks.isNotEmpty) {
        // 平均收益率 = 6只股票涨跌幅之和 / 6（失败的股票算0%）
        record.dailyAvgChange = totalChange / record.stocks.length;
        record.upCount = upCount;
        record.downCount = downCount;
        record.isSettled = true;
        await ExpertPerformanceService.saveDailyRecord(record);
        settledCount++;
        debugInfo.add('  → 结算成功: ${record.dailyAvgChange.toStringAsFixed(2)}%');

        // ★ 同步更新交易日记录
        try {
          final existingTradingRecords = await TradingDayCloudService.getLocalRecords();
          TradingDayRecord? existingTrading;
          for (var r in existingTradingRecords) {
            if (r.date == record.date) { existingTrading = r; break; }
          }
          
          final codes = record.stocks.map((s) => s.code).toList();
          final names = record.stocks.map((s) => s.name).toList();
          final changes = record.stocks.map((s) => s.changePercent).toList();
          
          if (existingTrading == null) {
            // 没有该日期的交易日记录 → 创建新记录
            final tradingRecord = TradingDayRecord(
              date: record.date,
              stockCodes: codes,
              stockNames: names,
              stockChanges: changes,
              totalChangePercent: record.dailyAvgChange * record.stocks.length,
              avgChangePercent: record.dailyAvgChange,
              notes: '结算后自动同步',
            );
            await TradingDayCloudService.addRecord(tradingRecord);
            debugInfo.add('  → 交易日记录已创建');
          } else {
            // 已有记录 → 用结算结果更新（重新结算时需要同步更新涨跌数据）
            // 判断是否有用户AI点评（reviewContent），有则保留
            final updatedTrading = TradingDayRecord(
              date: existingTrading.date,
              stockCodes: codes.isNotEmpty ? codes : existingTrading.stockCodes,
              stockNames: names.isNotEmpty ? names : existingTrading.stockNames,
              stockChanges: changes.isNotEmpty ? changes : existingTrading.stockChanges,
              totalChangePercent: record.dailyAvgChange * record.stocks.length,
              avgChangePercent: record.dailyAvgChange,
              notes: existingTrading.notes,
              reviewContent: existingTrading.reviewContent,
              reviewGeneratedAt: existingTrading.reviewGeneratedAt,
            );
            await TradingDayCloudService.addRecord(updatedTrading);
            debugInfo.add('  → 交易日记录已同步更新');
          }
        } catch (e) {
          debugInfo.add('  → 交易日记录同步失败: $e');
        }

        // 结算成功后自动备份
        ExpertPerformanceService.autoBackup();
      } else {
        failedCount++;
        debugInfo.add('  → 结算失败: 所有股票价格获取为0');
      }
    }

    // 打印调试信息
    for (var line in debugInfo) {
      print('[专家收益] $line');
    }

    setState(() => _settling = false);
    await _loadData();

    if (mounted) {
      if (settledCount > 0) {
        _showSnackBar('结算完成: 成功 $settledCount 条${failedCount > 0 ? "，失败 $failedCount 条" : ""}');
      } else {
        _showSnackBar('结算失败: 所有股票价格获取为0，请检查股票代码格式');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _autoSettleTimer?.cancel();
    _bgSub?.cancel();
    _dateCtrl.dispose();
    for (var form in _stockForms) {
      form.dispose();
    }
    super.dispose();
  }

  /// ★ 静默加载数据：先从缓存同步读取立即显示，再后台更新
  ///   核心原则：用户打开页面时数据已在，不会有闪烁/转圈
  Future<void> _loadDataQuietly() async {
    // 第0步：从云端同步收益历史（如果本地为空，则从服务器拉取）
    try {
      // 先看本地有没有数据，没有才触发云端同步（减少不必要的网络请求）
      final prefs = await SharedPreferences.getInstance();
      final localJson = prefs.getString('expert_performance_history');
      if (localJson == null || localJson.isEmpty) {
        final count = await ExpertPerformanceService.syncPerformanceFromCloud();
        if (count > 0) {
          print('[收益统计] 首次云端同步: 获取 $count 天历史数据');
        }
      }
    } catch (_) {}

    // 第一步：同步读取缓存数据，立即渲染（无 setState 闪烁）
    try {
      final cachedHistory = await ExpertPerformanceService.getHistory();
      final cachedTradingRecords = await TradingDayCloudService.getLocalRecords();
      if (cachedHistory.isNotEmpty) {
        // ★ 过滤非交易日数据（周末+节假日），与 _loadData 保持一致
        _history = cachedHistory
            .where((r) => !TradingDayUtils.isNonTradingDayStr(r.date))
            .toList();
        _tradingRecords = cachedTradingRecords
            .where((r) => !TradingDayUtils.isNonTradingDayStr(r.date))
            .toList();
        _loading = false; // 有缓存数据，标记加载完成
        if (mounted) setState(() {}); // 仅此一次 setState，把缓存数据渲染出来
      }
    } catch (_) {}

    // 第二步：后台执行完整的 _loadData 逻辑（包含API刷新、自动结算等）
    // 不会再设 _loading=true，因为缓存数据已显示
    await _loadData(silent: true);
  }

  /// 加载收益统计数据
  /// ★ silent=true 时后台静默刷新，不显示整体loading
  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      // ★ 只有在确实没有任何缓存数据时才显示全屏loading
      // 已有数据时即使非silent模式也静默更新
      if (_history.isEmpty) {
        setState(() => _loading = true);
      } else {
        setState(() => _isRefreshing = true);
      }
    } else {
      // silent模式：永远不显示全屏loading，仅标记后台刷新
      if (_history.isEmpty) {
        setState(() => _isRefreshing = true);
      }
      // 已有数据时甚至不需要 setState，数据到了再更新
    }
    try {
      final history = await ExpertPerformanceService.getHistory();
      final tradingRecords = await TradingDayCloudService.getLocalRecords();
      final now = DateTime.now();
      final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // ★ 修复：不再在 _loadData 中强制覆盖交易日记录
      // 之前这里有3处覆盖逻辑导致用户手动编辑的数据被旧数据覆盖：
      // 1. 硬编码修正05-14数据 → 删除（用户可自行编辑）
      // 2. 硬编码导入历史数据 → 改为仅首次导入
      // 3. 自动同步 expertPerformance → tradingDayRecords → 删除（尊重用户手动编辑）
      //
      // ★ 结算时间已推迟到19:30：
      // 15:00收盘时API数据可能不准确，19:30前重新打开App会自动从API重新结算
      // 19:30后的结算结果视为最终数据，不再重算

      // 仅首次导入历史数据（如果交易日记录完全为空）
      if (tradingRecords.isEmpty) {
        final historicalData = [
          {'date': '2026-04-17', 'total': 15.10, 'avg': 2.52},
          {'date': '2026-04-20', 'total': 18.90, 'avg': 3.02},
          {'date': '2026-04-21', 'total': -8.32, 'avg': -1.38},
          {'date': '2026-04-22', 'total': 12.50, 'avg': 2.08},
          {'date': '2026-04-23', 'total': 11.33, 'avg': 1.89},
          {'date': '2026-04-24', 'total': -13.85, 'avg': -2.30},
          {'date': '2026-04-27', 'total': 23.23, 'avg': 3.89},
          {'date': '2026-04-28', 'total': 5.60, 'avg': 0.93},
          {'date': '2026-04-29', 'total': -11.33, 'avg': -1.89},
          {'date': '2026-04-30', 'total': 37.77, 'avg': 6.30},
          {'date': '2026-05-06', 'total': 16.33, 'avg': 2.73},
          {'date': '2026-05-07', 'total': 5.77, 'avg': 0.96},
          {'date': '2026-05-08', 'total': 18.93, 'avg': 3.16},
          {'date': '2026-05-11', 'total': 16.16, 'avg': 2.69},
          {'date': '2026-05-12', 'total': -5.77, 'avg': -0.96},
          {'date': '2026-05-13', 'total': 8.42, 'avg': 1.40},
          {'date': '2026-05-14', 'total': -6.19, 'avg': 1.03},
        ];
        for (var data in historicalData) {
          final date = data['date'] as String;
          final avg = data['avg'] as double;
          final total = data['total'] as double;

          final historyRecord = TradingDayRecord(
            date: date,
            stockCodes: List.filled(6, 'HIST'),
            stockNames: List.filled(6, '历史数据'),
            stockChanges: List.filled(6, avg),
            totalChangePercent: total,
            avgChangePercent: avg,
            notes: '历史数据导入',
          );
          await TradingDayCloudService.addRecord(historyRecord);
        }

        // 同时补齐 ExpertPerformance 记录
        final historyMap = {for (var r in history) r.date: r};
        for (var data in historicalData) {
          final date = data['date'] as String;
          final avg = data['avg'] as double;
          final total = data['total'] as double;
          final isUp = avg >= 0;

          if (historyMap[date] == null) {
            final stocks = List.generate(6, (i) => StockPerformance(
              name: '历史数据${i + 1}',
              code: 'HIST${i + 1}',
              startPrice: 10.0,
              strategy: i < 3 ? 'A股游资' : '隔夜导航',
              changePercent: avg,
              settlementPrice: 10.0 * (1 + avg / 100),
            ));
            final perfRecord = DailyExpertPerformance(
              date: date,
              stocks: stocks,
              dailyAvgChange: avg,
              upCount: isUp ? 6 : 0,
              downCount: isUp ? 0 : 6,
              isSettled: true,
            );
            await ExpertPerformanceService.saveDailyRecord(perfRecord);
          }
        }
        print('[收益统计] 首次导入历史数据完成');
      }

      // ★ 不再自动同步 expertPerformance → tradingDayRecords
      // 用户手动编辑的交易日记录应该被尊重，不被自动覆盖
      // 只有在 autoSettle 结算时才同步（且同步前检查用户是否手动编辑过）

      // ★★★ 19:30前重新获取昨天的收盘数据（核心修复）★★★
      // 问题：15:00收盘时API数据可能不准确（盘中临时价≠收盘价），结算后数据错误
      // 方案：19:30前每次打开App都从API重新获取昨天数据
      // 19:30为硬截止：之后不再修改昨天数据，确保20:00创建新记录不受干扰
      // ⚠️ 重要：只修正昨天的记录（today - 1天），不碰今天新创建的记录
      // ★ 额外修复：昨天必须也是交易日，非交易日（如端午节）不执行重新获取
      final isBeforeSettlementDeadline = now.hour < 19 || (now.hour == 19 && now.minute < 30);
      if (isBeforeSettlementDeadline) {
        // 找到昨天的记录（_getYesterdayString 已修复为返回上一个交易日）
        final yesterday = _getYesterdayString();
        DailyExpertPerformance? yesterdayRecord;
        for (var r in history) {
          if (r.date == yesterday) { yesterdayRecord = r; break; }
        }
        // ★ 如果昨天是交易日且有已结算记录，重新获取API数据
        if (yesterdayRecord != null && yesterdayRecord.isSettled) {
          print('[收益统计] 19:30前重新获取昨天数据: ${yesterdayRecord.date}');
          final api = LocalDataService();
          double totalChange = 0;
          int upCount = 0;
          int downCount = 0;
          int successCount = 0;

          for (var stock in yesterdayRecord.stocks) {
            try {
              final stockData = await api.searchStock(stock.code);
              if (stockData.isNotEmpty) {
                final currentPrice = _safeDoubleVal(stockData['price']);
                final changePct = _safeDoubleVal(stockData['change_pct']);
                if (currentPrice > 0 && stock.startPrice > 0) {
                  stock.settlementPrice = currentPrice;
                  if (changePct != 0) {
                    stock.changePercent = changePct;
                  } else {
                    stock.changePercent = (currentPrice - stock.startPrice) / stock.startPrice * 100;
                  }
                  totalChange += stock.changePercent;
                  if (stock.changePercent > 0) upCount++;
                  else if (stock.changePercent < 0) downCount++;
                  successCount++;
                }
              }
            } catch (e) {
              print('[收益统计] 获取${stock.name}失败: $e');
            }
          }

          if (successCount > 0) {
            yesterdayRecord.dailyAvgChange = totalChange / yesterdayRecord.stocks.length;
            yesterdayRecord.upCount = upCount;
            yesterdayRecord.downCount = downCount;
            yesterdayRecord.isSettled = true;
            await ExpertPerformanceService.saveDailyRecord(yesterdayRecord);

            // 同步更新交易日记录
            try {
              final codes = yesterdayRecord.stocks.map((s) => s.code).toList();
              final names = yesterdayRecord.stocks.map((s) => s.name).toList();
              final changes = yesterdayRecord.stocks.map((s) => s.changePercent).toList();
              TradingDayRecord? existingTrading;
              for (var r in tradingRecords) {
                if (r.date == yesterday) { existingTrading = r; break; }
              }
              final updatedTrading = TradingDayRecord(
                date: yesterday,
                stockCodes: codes.isNotEmpty ? codes : existingTrading?.stockCodes ?? [],
                stockNames: names.isNotEmpty ? names : existingTrading?.stockNames ?? [],
                stockChanges: changes.isNotEmpty ? changes : existingTrading?.stockChanges ?? [],
                totalChangePercent: yesterdayRecord.dailyAvgChange * yesterdayRecord.stocks.length,
                avgChangePercent: yesterdayRecord.dailyAvgChange,
                notes: existingTrading?.notes,
                reviewContent: existingTrading?.reviewContent,
                reviewGeneratedAt: existingTrading?.reviewGeneratedAt,
              );
              await TradingDayCloudService.addRecord(updatedTrading);
            } catch (e) {
              print('[收益统计] 交易日记录同步失败: $e');
            }

            print('[收益统计] 昨天数据已更新: 平均涨跌=${yesterdayRecord.dailyAvgChange.toStringAsFixed(2)}%');
            ExpertPerformanceService.autoBackup();
          }
        }
      }
      // ★★★ 根据时间阶段更新当天记录的涨跌幅 ★★★
      // 正确逻辑：
      //   20:00~9:30(次日): 新6只股票全部显示0.00%（新记录，尚未开盘）
      //   9:30~15:05: 交易时间，实时更新涨跌幅并保存到SharedPreferences
      //   15:05~19:30: 收盘后冻结，保持收盘数据不变（app重启也不丢失）
      DailyExpertPerformance? todayRecord;
      for (var r in history) {
        if (r.date == today) { todayRecord = r; break; }
      }

      if (todayRecord != null && !todayRecord.isSettled) {
        if (_isTradingTime()) {
          // === 交易时间 (9:30-15:05): 并行获取6只股票实时数据并保存 ===
          print('[收益统计] 交易时间内更新今天实时价格: ${todayRecord.date}');
          final api = LocalDataService();

          // ★ 并行请求所有股票数据
          final futures = <Future<Map<String, dynamic>?>>[];
          for (int i = 0; i < todayRecord.stocks.length; i++) {
            final stock = todayRecord.stocks[i];
            futures.add(api.searchStock(stock.code).then((stockData) {
              if (stockData.isNotEmpty) {
                final currentPrice = _safeDoubleVal(stockData['price']);
                final changePct = _safeDoubleVal(stockData['change_pct']);
                if (currentPrice > 0 && stock.startPrice > 0) {
                  final liveChange = changePct != 0
                      ? changePct
                      : (currentPrice - stock.startPrice) / stock.startPrice * 100;
                  return {'index': i, 'changePercent': liveChange, 'settlementPrice': currentPrice};
                }
              }
              return null;
            }).catchError((_) => null));
          }

          final results = await Future.wait(futures);
          double totalChange = 0;
          int upCount = 0;
          int downCount = 0;
          int successCount = 0;

          for (final result in results) {
            if (result != null) {
              final idx = result['index'] as int;
              final changePercent = result['changePercent'] as double;
              final settlementPrice = result['settlementPrice'] as double;
              final stock = todayRecord.stocks[idx];
              stock.changePercent = changePercent;
              stock.settlementPrice = settlementPrice;
              totalChange += changePercent;
              if (changePercent > 0) upCount++;
              else if (changePercent < 0) downCount++;
              successCount++;
            }
          }

          if (successCount > 0) {
            todayRecord.dailyAvgChange = totalChange / todayRecord.stocks.length;
            todayRecord.upCount = upCount;
            todayRecord.downCount = downCount;
            // ★ 保存到SharedPreferences，确保收盘后数据持久化
            await ExpertPerformanceService.saveDailyRecord(todayRecord);
            // 同步更新实时缓存
            for (var stock in todayRecord.stocks) {
              _liveChangePercents[stock.code] = stock.changePercent;
            }
            print('[收益统计] 交易时间数据已保存: 平均涨跌=${todayRecord.dailyAvgChange.toStringAsFixed(2)}%');
          }
        } else if (_isPostMarketTime()) {
          // === 收盘后 (15:05-19:30): 冻结涨跌幅数据 ===
          // 如果涨跌幅全为0（app刚打开，尚未获取过数据），从API并行获取一次并保存
          if (todayRecord.stocks.every((s) => s.changePercent == 0)) {
            print('[收益统计] 收盘后首次加载，获取收盘数据...');
            final api = LocalDataService();

            // ★ 并行请求所有股票数据
            final futures = <Future<Map<String, dynamic>?>>[];
            for (int i = 0; i < todayRecord.stocks.length; i++) {
              final stock = todayRecord.stocks[i];
              futures.add(api.searchStock(stock.code).then((stockData) {
                if (stockData.isNotEmpty) {
                  final currentPrice = _safeDoubleVal(stockData['price']);
                  final changePct = _safeDoubleVal(stockData['change_pct']);
                  if (currentPrice > 0 && stock.startPrice > 0) {
                    final change = changePct != 0
                        ? changePct
                        : (currentPrice - stock.startPrice) / stock.startPrice * 100;
                    return {'index': i, 'changePercent': change, 'settlementPrice': currentPrice};
                  }
                }
                return null;
              }).catchError((_) => null));
            }

            final results = await Future.wait(futures);
            double totalChange = 0;
            int upCount = 0;
            int downCount = 0;
            int successCount = 0;

            for (final result in results) {
              if (result != null) {
                final idx = result['index'] as int;
                final changePercent = result['changePercent'] as double;
                final settlementPrice = result['settlementPrice'] as double;
                final stock = todayRecord.stocks[idx];
                stock.settlementPrice = settlementPrice;
                stock.changePercent = changePercent;
                totalChange += changePercent;
                if (changePercent > 0) upCount++;
                else if (changePercent < 0) downCount++;
                successCount++;
              }
            }

            if (successCount > 0) {
              todayRecord.dailyAvgChange = totalChange / todayRecord.stocks.length;
              todayRecord.upCount = upCount;
              todayRecord.downCount = downCount;
              // 保存冻结数据到SharedPreferences
              await ExpertPerformanceService.saveDailyRecord(todayRecord);
              print('[收益统计] 收盘数据已冻结: 平均涨跌=${todayRecord.dailyAvgChange.toStringAsFixed(2)}%');
            }
          }
          // 已有数据：保持不变（冻结），不再从API更新
        }
        // 20:00后新记录：stock.changePercent默认为0.0，无需额外处理
        // _liveChangePercents已在创建记录时清除，确保新股票显示0.00%
      }

      // 获取沪深300和中证1000日K数据
      Map<String, double> hs300Data = {};
      Map<String, double> zz1000Data = {};
      if (history.isNotEmpty) {
        try {
          hs300Data = await ExpertPerformanceService.fetchHS300DailyChanges();
          debugPrint('[收益统计] 沪深300数据: ${hs300Data.length}条');
        } catch (e) {
          debugPrint('[收益统计] 沪深300数据获取失败: $e');
        }
        try {
          zz1000Data = await ExpertPerformanceService.fetchZZ1000DailyChanges();
          debugPrint('[收益统计] 中证1000数据: ${zz1000Data.length}条');
        } catch (e) {
          debugPrint('[收益统计] 中证1000数据获取失败: $e');
        }
      }

      // ★ 过滤非交易日数据（周末+节假日），确保图表和统计不显示非交易日
      final filteredHistory = history
          .where((r) => !TradingDayUtils.isNonTradingDayStr(r.date))
          .toList();
      final filteredTradingRecords = tradingRecords
          .where((r) => !TradingDayUtils.isNonTradingDayStr(r.date))
          .toList();

      setState(() {
        _history = filteredHistory;
        _tradingRecords = filteredTradingRecords;
        _hs300DailyChanges = hs300Data;
        _zz1000DailyChanges = zz1000Data;
        _loading = false;
        _isRefreshing = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _isRefreshing = false;
      });
    }
  }

  /// 添加股票表单
  void _addStockForm() {
    if (_stockForms.length >= 6) return;
    setState(() {
      _stockForms.add(StockFormData());
    });
  }

  /// 移除股票表单
  void _removeStockForm(int index) {
    if (_stockForms.length <= 1) return;
    setState(() {
      _stockForms[index].dispose();
      _stockForms.removeAt(index);
    });
  }

  /// 保存记录
  Future<void> _saveRecord() async {
    if (_dateCtrl.text.isEmpty) {
      _showSnackBar('请输入日期');
      return;
    }

    final stocks = <StockPerformance>[];
    double totalChange = 0;
    int upCount = 0;
    int downCount = 0;

    for (var form in _stockForms) {
      if (form.nameCtrl.text.isEmpty) continue;

      final startPrice = double.tryParse(form.startPriceCtrl.text) ?? 0;
      final settlementPrice = double.tryParse(form.settlementPriceCtrl.text) ?? 0;

      if (startPrice == 0) continue;

      final changePercent = (settlementPrice - startPrice) / startPrice * 100;
      totalChange += changePercent;

      if (changePercent >= 0) {
        upCount++;
      } else {
        downCount++;
      }

      stocks.add(StockPerformance(
        name: form.nameCtrl.text,
        code: form.codeCtrl.text,
        startPrice: startPrice,
        settlementPrice: settlementPrice,
        changePercent: changePercent,
      ));
    }

    if (stocks.isEmpty) {
      _showSnackBar('请至少添加一只股票');
      return;
    }

    final record = DailyExpertPerformance(
      date: _dateCtrl.text,
      stocks: stocks,
      dailyAvgChange: totalChange / stocks.length,
      upCount: upCount,
      downCount: downCount,
    );

    await ExpertPerformanceService.saveDailyRecord(record);
    await _loadData();

    setState(() {
      _showAddForm = false;
      _clearForms();
    });

    _showSnackBar('保存成功');
  }

  /// 清空表单
  void _clearForms() {
    _dateCtrl.clear();
    for (var form in _stockForms) {
      form.dispose();
    }
    _stockForms.clear();
    _addStockForm();
  }

  // ========== 备份/恢复方法 ==========

  /// ☁️ 云端备份到 Gitee（包含收益统计+交易日记录+热点投资）
  /// 合并成一个文件上传，只管理一个SHA，最可靠
  Future<void> _doCloudBackup() async {
    final token = await ExpertPerformanceService.getGiteeToken();
    if (token == null || token.isEmpty) {
      _showSnackBar('请先在设置页配置 Gitee 私人令牌');
      return;
    }

    setState(() => _backingUp = true);
    try {
      // 1. 获取收益统计数据
      final history = await ExpertPerformanceService.getHistory();
      // 2. 获取交易日记录数据
      final tradingRecords = await TradingDayCloudService.getLocalRecords();
      // 3. 获取热点投资组合数据
      final hotInvestService = HotInvestmentService();
      await hotInvestService.load();
      final hotPortfolios = hotInvestService.portfolios;
      final archiveCount = hotInvestService.calendarArchive.length;

      if (history.isEmpty && tradingRecords.isEmpty && hotPortfolios.isEmpty && archiveCount == 0) {
        _showSnackBar('暂无数据可备份');
        setState(() => _backingUp = false);
        return;
      }

      final repo = await BackupService.getFullRepoPath();
      if (repo == null) {
        if (mounted) _showSnackBar('获取仓库路径失败，请重新保存令牌');
        setState(() => _backingUp = false);
        return;
      }

      // 4. 构建合并的备份数据（一个文件包含所有模块数据）
      final combinedData = <String, dynamic>{
        'version': 3,
        'backupTime': DateTime.now().toIso8601String(),
        'expertPerformanceCount': history.length,
        'tradingDayCount': tradingRecords.length,
        'hotInvestmentCount': hotPortfolios.length,
        'hotInvestmentArchiveCount': archiveCount,
        'expertPerformance': history.map((r) => r.toJson()).toList(),
        'tradingDayRecords': tradingRecords.map((r) => r.toJson()).toList(),
        'hotInvestmentPortfolios': hotPortfolios.map((p) => p.toJson()).toList(),
        'hotInvestmentCalendarArchive': hotInvestService.calendarArchive,
      };
      final json = const JsonEncoder.withIndent('  ').convert(combinedData);

      // 5. 一次上传（所有模块共用同一个文件，同一路径，同一个SHA管理）
      print('[备份] 开始上传合并备份（收益${history.length}条+交易日${tradingRecords.length}条+热点投资${hotPortfolios.length}个+归档$archiveCount条）...');
      final result = await BackupService.backupToGiteeWithDetail(token, repo, json);
      print('[备份] 上传结果: ${result['ok']}');

      if (mounted) {
        if (result['ok'] == true) {
          _showSnackBar('☁️ 云端备份成功（收益${history.length}条+交易日${tradingRecords.length}条+热点投资${hotPortfolios.length}个+归档$archiveCount条）');
        } else {
          _showSnackBar('云端备份失败: ${result['error']}');
        }
      }
    } catch (e) {
      if (mounted) _showSnackBar('云端备份异常: $e');
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  /// 📥 从 Gitee 云端恢复（包含收益统计+交易日记录）
  /// 从合并的备份文件中恢复所有数据
  Future<void> _doCloudRestore() async {
    final token = await ExpertPerformanceService.getGiteeToken();
    if (token == null || token.isEmpty) {
      _showSnackBar('请先在设置页配置 Gitee 私人令牌');
      return;
    }

    // 确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认恢复'),
        content: const Text('云端数据将覆盖本地所有记录（收益统计+交易日记录+热点投资），是否继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认恢复')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _restoring = true);
    try {
      final repo = await BackupService.getFullRepoPath();
      if (repo == null) {
        if (mounted) _showSnackBar('获取仓库路径失败，请检查令牌是否有效');
        setState(() => _restoring = false);
        return;
      }

      // 下载合并的备份文件
      print('[备份] 开始从云端下载合并备份...');
      final content = await BackupService.restoreFromGitee(token, repo);
      if (content == null) {
        if (mounted) _showSnackBar('云端无备份数据');
        setState(() => _restoring = false);
        return;
      }

      final data = jsonDecode(content);
      int expertCount = 0;
      int tradingCount = 0;
      int hotCount = 0;
      int archiveCount = 0;

      // 1. 恢复交易日记录（version 2+ 格式）
      if (data is Map && data['tradingDayRecords'] is List) {
        final records = (data['tradingDayRecords'] as List)
            .map((j) => TradingDayRecord.fromJson(j))
            .toList();
        await TradingDayCloudService.saveRecordsLocally(records);
        tradingCount = records.length;
        print('[备份] 交易日记录恢复: $tradingCount 条');
      }

      // 2. 恢复收益统计（兼容 version 1/2/3 格式）
      final ok = await ExpertPerformanceService.restoreFromBackupJson(content);
      if (ok) {
        await _loadData();
        expertCount = data['expertPerformanceCount'] ?? data['recordCount'] ?? 0;
        print('[备份] 收益统计恢复: $expertCount 条');
      }

      // 3. 恢复热点投资组合 + 日历归档（version 3 格式）
      final hotService = HotInvestmentService();
      await hotService.load();
      if (data is Map && data['hotInvestmentPortfolios'] is List) {
        try {
          final rawList = data['hotInvestmentPortfolios'] as List;
          final List<HotInvestmentPortfolio> portfolios = rawList
            .map((j) => HotInvestmentPortfolio.fromJson(j as Map<String, dynamic>))
            .toList();
          await hotService.replacePortfolios(portfolios);
          hotCount = portfolios.length;
          print('[备份] 热点投资恢复: $hotCount 个');
        } catch (e) {
          print('[备份] 热点投资恢复失败: $e');
        }
      }
      // 恢复日历归档
      if (data is Map && data['hotInvestmentCalendarArchive'] is List) {
        try {
          final archiveRaw = data['hotInvestmentCalendarArchive'] as List;
          await hotService.replaceCalendarArchive(archiveRaw.cast<Map<String, dynamic>>());
          archiveCount = archiveRaw.length;
          print('[备份] 日历归档恢复: $archiveCount 条');
        } catch (e) {
          print('[备份] 日历归档恢复失败: $e');
        }
      }

      if (mounted) {
        if (tradingCount > 0 || expertCount > 0 || hotCount > 0 || archiveCount > 0) {
          _showSnackBar('📥 云端恢复成功（收益$expertCount条+交易日$tradingCount条+热点投资${hotCount}个+归档$archiveCount条）');
        } else {
          _showSnackBar('云端无有效数据');
        }
      }
    } catch (e) {
      if (mounted) _showSnackBar('云端恢复异常: $e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  /// 🥜 上传到坚果云（收益统计+交易日记录）
  Future<void> _doJianguoyunUpload() async {
    final configured = await JianguoyunService.isConfigured();
    if (!configured) { _showSnackBar('请先在设置中配置坚果云应用名称和应用密码'); return; }
    setState(() => _jgyUploading = true);
    try {
      final history = await ExpertPerformanceService.getHistory();
      final tradingRecords = await TradingDayCloudService.getLocalRecords();
      final data = {
        'version': 2, 'exportTime': DateTime.now().toIso8601String(),
        'expertPerformanceCount': history.length, 'tradingDayCount': tradingRecords.length,
        'expertPerformance': history.map((r) => r.toJson()).toList(),
        'tradingDayRecords': tradingRecords.map((r) => r.toJson()).toList(),
      };
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final result = await JianguoyunService.upload('收益统计', json);
      if (mounted) _showSnackBar(result['ok'] == true ? '🥜 坚果云上传成功（收益${history.length}条+交易日${tradingRecords.length}条）' : '上传失败: ${result['error']}');
    } catch (e) { if (mounted) _showSnackBar('坚果云上传异常: $e'); } finally { if (mounted) setState(() => _jgyUploading = false); }
  }

  /// 📥 从坚果云下载（收益统计+交易日记录）
  Future<void> _doJianguoyunDownload() async {
    final configured = await JianguoyunService.isConfigured();
    if (!configured) { _showSnackBar('请先在设置中配置坚果云应用名称和应用密码'); return; }
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('确认下载'), content: const Text('坚果云数据将覆盖本地收益统计和交易日记录，是否继续？'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认下载'))],
    ));
    if (confirmed != true) return;
    setState(() => _jgyDownloading = true);
    try {
      final content = await JianguoyunService.download('收益统计');
      if (content == null) { _showSnackBar('坚果云暂无备份数据'); setState(() => _jgyDownloading = false); return; }
      final data = jsonDecode(content);
      int expertCount = 0, tradingCount = 0;
      if (data['tradingDayRecords'] is List) {
        final records = (data['tradingDayRecords'] as List).map((j) => TradingDayRecord.fromJson(j)).toList();
        await TradingDayCloudService.saveRecordsLocally(records);
        tradingCount = records.length;
      }
      final ok = await ExpertPerformanceService.restoreFromBackupJson(content);
      if (ok) { await _loadData(); expertCount = data['expertPerformanceCount'] ?? 0; }
      _showSnackBar('🥜 坚果云下载成功（收益$expertCount条+交易日$tradingCount条）');
    } catch (e) { _showSnackBar('下载失败：数据格式不正确'); } finally { if (mounted) setState(() => _jgyDownloading = false); }
  }

  /// 💾 导出到本地（弹出JSON对话框，用户可复制保存到文件）
  Future<void> _doLocalExport() async {
    setState(() => _exporting = true);
    try {
      // 1. 获取收益统计数据
      final history = await ExpertPerformanceService.getHistory();
      // 2. 获取交易日记录数据
      final tradingRecords = await TradingDayCloudService.getLocalRecords();

      if (history.isEmpty && tradingRecords.isEmpty) {
        _showSnackBar('暂无数据可导出');
        setState(() => _exporting = false);
        return;
      }

      // 3. 构建合并的备份数据
      final combinedData = {
        'type': '收益统计',
        'version': 2,
        'exportTime': DateTime.now().toIso8601String(),
        'expertPerformanceCount': history.length,
        'tradingDayCount': tradingRecords.length,
        'expertPerformance': history.map((r) => r.toJson()).toList(),
        'tradingDayRecords': tradingRecords.map((r) => r.toJson()).toList(),
      };
      final json = const JsonEncoder.withIndent('  ').convert(combinedData);

      if (!mounted) return;

      final colors = AppColors.of(context);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          title: Row(children: [
            Icon(Icons.save_alt, color: colors.primary, size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text('导出本地备份', style: AppText.h3.copyWith(color: colors.textPrimary))),
          ]),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: SingleChildScrollView(
              child: SelectableText(
                json,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFCCCCCC)),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('📋 已复制，可粘贴到文本文件保存（收益${history.length}条+交易日${tradingRecords.length}条）'), behavior: SnackBarBehavior.floating),
                );
              },
              child: Text('关闭', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _showSnackBar('本地导出异常: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 📂 从本地导入（弹出文本框，用户粘贴JSON后导入）
  Future<void> _doLocalImport() async {
    final colors = AppColors.of(context);
    final controller = TextEditingController();

    final jsonStr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(children: [
          Icon(Icons.file_open, color: colors.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(child: Text('导入本地备份', style: AppText.h3.copyWith(color: colors.textPrimary))),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('粘贴之前导出的 JSON 备份内容，\n将覆盖当前收益统计和交易日记录。',
              style: AppText.body2.copyWith(color: colors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFCCCCCC)),
              decoration: InputDecoration(
                hintText: '粘贴 JSON 内容...',
                hintStyle: TextStyle(color: colors.textHint),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.border),
                ),
                filled: true,
                fillColor: colors.surfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
            child: const Text('确认导入', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    controller.dispose();
    if (jsonStr == null || jsonStr.isEmpty) return;

    setState(() => _importing = true);
    try {
      final data = jsonDecode(jsonStr);
      int expertCount = 0;
      int tradingCount = 0;

      // 1. 恢复交易日记录
      if (data['tradingDayRecords'] is List) {
        final records = (data['tradingDayRecords'] as List)
            .map((j) => TradingDayRecord.fromJson(j))
            .toList();
        await TradingDayCloudService.saveRecordsLocally(records);
        tradingCount = records.length;
      }

      // 2. 恢复收益统计
      final ok = await ExpertPerformanceService.restoreFromBackupJson(jsonStr);
      if (ok) {
        await _loadData();
        expertCount = data['expertPerformanceCount'] ?? data['recordCount'] ?? 0;
      }

      if (mounted) {
        _showSnackBar('📂 本地导入成功（收益$expertCount条+交易日$tradingCount条）');
      }
    } catch (e) {
      if (mounted) _showSnackBar('导入失败：数据格式不正确');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 显示提示
  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题栏（点击展开/折叠）
        GestureDetector(
          onTap: () {
            final newExpanded = !_expanded;
            setState(() => _expanded = newExpanded);
            // ★ 展开时不再重新 _loadData，数据已在 initState 加载
            // 后台定时刷新 (_startLiveRefresh) 负责更新数字
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ========== 第一行：标题 + 主要操作按钮 ==========
                Row(
                  children: [
                    // 展开/折叠图标
                    AnimatedRotation(
                      turns: _expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      child: Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 8),

                    // 标题
                    Text(
                      '📊 收益统计',
                      style: AppText.h3.copyWith(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    const Spacer(),

                    // 添加按钮
                    GestureDetector(
                      onTap: () => setState(() => _showAddForm = !_showAddForm),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: colors.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          _showAddForm ? Icons.close : Icons.add,
                          size: 18,
                          color: colors.primary,
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // 手动创建今日记录按钮（仅20:00后可用）
                    if (_expanded)
                      GestureDetector(
                        onTap: () async {
                          final now = DateTime.now();
                          if (now.hour < 20) {
                            _showSnackBar('创建时间为每晚20:00后');
                            return;
                          }
                          if (!ExpertPerformanceService.isTradingDay()) {
                            _showSnackBar('今天不是交易日，无需创建');
                            return;
                          }
                          final created = await ExpertPerformanceService.autoCreateTodayRecord();
                          if (created) {
                            await _loadData();
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已创建今日选股记录（锁定6只至明日19:00）'),
                                  duration: Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          } else {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('创建失败（今日已有记录）'),
                                  duration: Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colors.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.playlist_add,
                            size: 18,
                            color: colors.primary,
                          ),
                        ),
                      ),

                    const SizedBox(width: 8),

                    // 🔄 刷新按钮
                    if (_expanded)
                      GestureDetector(
                        onTap: _recreating ? null : () async {
                          final now = DateTime.now();
                          if (now.hour < 20) {
                            _showSnackBar('刷新时间为每晚20:00后');
                            return;
                          }
                          if (!ExpertPerformanceService.isTradingDay()) {
                            _showSnackBar('今天不是交易日，无需刷新');
                            return;
                          }
                          setState(() => _recreating = true);
                          try {
                            final recreated = await ExpertPerformanceService.forceRecreateTodayRecord();
                            await _loadData();
                            if (mounted) {
                              if (recreated) {
                                _showSnackBar('已刷新今日选股（获取最新A股游资+隔夜导航各前3名）');
                              } else {
                                _showSnackBar('刷新失败，请检查网络后重试');
                              }
                            }
                          } catch (e) {
                            if (mounted) {
                              _showSnackBar('刷新异常: $e');
                            }
                          } finally {
                            if (mounted) {
                              setState(() => _recreating = false);
                            }
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colors.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _recreating
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: colors.primary,
                                  ),
                                )
                              : Icon(
                                  Icons.refresh,
                                  size: 18,
                                  color: colors.primary,
                                ),
                        ),
                      ),

                    const SizedBox(width: 8),

                    // 强制结算按钮
                    if (_expanded)
                      GestureDetector(
                        onTap: _settling ? null : () async {
                          try {
                            final history = await ExpertPerformanceService.getHistory();
                            if (history.isEmpty) {
                              _showSnackBar('暂无历史记录');
                              return;
                            }
                            for (var record in history) {
                              for (var stock in record.stocks) {
                                stock.code = _fixStockCode(stock.code);
                              }
                            }
                            final today = '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}';
                            await _forceSettle(history, today);
                          } catch (e) {
                            setState(() => _settling = false);
                            _showSnackBar('结算异常: $e');
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colors.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _settling
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: colors.primary,
                                  ),
                                )
                              : Icon(
                                  Icons.check_circle_outline,
                                  size: 18,
                                  color: colors.primary,
                                ),
                        ),
                      ),
                  ],
                ),

                // ========== 第二行：备份/恢复按钮（展开时显示） ==========
                if (_expanded) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // 📊 交易日记录
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const TradingDayRecordsScreen(),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.teal.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.table_chart,
                            size: 18,
                            color: Colors.teal,
                          ),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // ☁️ 云端备份
                      GestureDetector(
                        onTap: _backingUp ? null : _doCloudBackup,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _backingUp
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.orange,
                                  ),
                                )
                              : Icon(
                                  Icons.cloud_upload,
                                  size: 18,
                                  color: Colors.orange,
                                ),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // 📥 云端恢复
                      GestureDetector(
                        onTap: _restoring ? null : _doCloudRestore,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _restoring
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.blue,
                                  ),
                                )
                              : Icon(
                                  Icons.cloud_download,
                                  size: 18,
                                  color: Colors.blue,
                                ),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // 🥜 坚果云上传
                      GestureDetector(
                        onTap: _jgyUploading ? null : _doJianguoyunUpload,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _jgyUploading
                              ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber.shade700))
                              : Icon(Icons.cloud_sync, size: 18, color: Colors.amber.shade700),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // 🥜 坚果云下载
                      GestureDetector(
                        onTap: _jgyDownloading ? null : _doJianguoyunDownload,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.amber.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _jgyDownloading
                              ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber.shade700))
                              : Icon(Icons.cloud_done, size: 18, color: Colors.amber.shade700),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // 💾 本地导出
                      GestureDetector(
                        onTap: _exporting ? null : _doLocalExport,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _exporting
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.green,
                                  ),
                                )
                              : Icon(
                                  Icons.file_download,
                                  size: 18,
                                  color: Colors.green,
                                ),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // 📂 本地导入
                      GestureDetector(
                        onTap: _importing ? null : _doLocalImport,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.purple.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _importing
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.purple,
                                  ),
                                )
                              : Icon(
                                  Icons.file_upload,
                                  size: 18,
                                  color: Colors.purple,
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        // 展开内容
        // ★★★ 关键修复：首次加载完成前（_loading=true）不显示内容，避免全页面转圈
        if (_expanded && !_loading) ...[
          const SizedBox(height: 12),
          _buildContent(),
        ],

        // 添加记录表单
        if (_showAddForm) ...[
          const SizedBox(height: 12),
          _buildAddForm(),
        ],
      ],
    );
  }

  /// 构建展开内容
  Widget _buildContent() {
    // ★★★ 优化：有缓存数据时永远不显示全屏loading
    // 即使 _loading=true 且 _history 非空，也直接显示已有数据
    if (_history.isEmpty && _loading && !_isRefreshing) {
      // 只有真正的首次加载（无任何缓存数据）才显示转圈
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_history.isEmpty) {
      return _buildEmptyView();
    }

    // ★ 后台刷新时显示已有数据，同时显示顶部刷新指示器

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ★ 不再显示后台刷新进度条，完全无感刷新
        // 后台更新数据后 setState 只会更新变化的数字

        // 核心统计指标
        _buildCoreStats(),
        const SizedBox(height: 16),

        // 每日明细表
        _buildDailyDetailTable(),
        const SizedBox(height: 16),

        // 收益趋势曲线图
        _buildTrendChart(),
        const SizedBox(height: 16),

        // 单日盈亏柱状图
        _buildDailyBarChart(),
      ],
    );
  }

  /// 构建空视图
  Widget _buildEmptyView() {
    final colors = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          Icon(
            Icons.bar_chart,
            size: 48,
            color: colors.textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            '暂无收益统计数据',
            style: AppText.body1.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            '点击+按钮添加记录',
            style: AppText.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  /// 构建核心统计指标
  /// 盈亏分布 + 当日总涨幅：使用实时价格计算
  /// 平均收益率：从 _tradingRecords 状态变量计算
  Widget _buildCoreStats() {
    final colors = AppColors.of(context);
    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();

    if (_history.isEmpty) {
      return const SizedBox();
    }

    // ★ 平均收益率：统一使用 TradingStatistics.fromRecords（与交易日记录页面一致）
    //   基于10万本金复利累计 / 天数，而非简单算术平均
    double avgReturn = 0.0;
    if (_tradingRecords.isNotEmpty) {
      final stats = TradingStatistics.fromRecords(_tradingRecords);
      avgReturn = stats.dailyAvgReturn;
    }

    // 当日总涨幅 + 盈亏分布：显示当前有效期内记录的数据
    String displayDate;
    if (now.hour >= 20) {
      displayDate = today;
    } else {
      displayDate = _getYesterdayString();
      if (!_history.any((r) => r.date == displayDate)) {
        if (_history.isNotEmpty) {
          displayDate = _history.first.date;
        }
      }
    }
    var activeRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    if (activeRecord.stocks.isEmpty && _history.isNotEmpty) {
      activeRecord = _history.first;
    }
    final hasActiveRecord = activeRecord.stocks.isNotEmpty;

    // ★★★ 当日涨跌幅显示规则 ★★★
    // 时间线：
    //   20:00 创建新6只 → 每只显示 0.00%（尚未开盘）
    //   20:00~次日09:30 → 每只显示 0.00%（非交易时段）
    //   09:30~15:05 → 每只按实时数据更新
    //   15:05 后 → 冻结，保持收盘数据不变
    // 盈亏分布 + 当日总涨幅
    int? profitUpCount;    // 涨的数量
    int? profitDownCount;  // 跌的数量
    String profitText = '--'; // 无数据时的文字
    String dailyChange = '--';
    Color dailyChangeColor = colors.textSecondary;

    if (hasActiveRecord) {
      final now = DateTime.now();
      final timeInMinutes = now.hour * 60 + now.minute;

      // ★ 非交易日（周末+节假日） → 显示 0.00%
      final isNonTradingDay = !TradingDayUtils.isSecuritiesTradingDay(now);
      // ★ 非交易时段：15:05~09:30（即 < 09:30 或 > 15:05）
      final isNonTradingHours = timeInMinutes < (9 * 60 + 30) || timeInMinutes > (15 * 60 + 5);
      // ★ 收盘冻结时段：15:05~20:00（15:05后不再更新，用最后一次数据）
      final isAfterMarketClose = timeInMinutes >= (15 * 60 + 5) && timeInMinutes < (20 * 60);

      if (isNonTradingDay || (isNonTradingHours && !activeRecord.isSettled)) {
        // ★ 非交易日 或 非交易时段且未结算：每只显示 0.00%
        profitUpCount = 0;
        profitDownCount = 0;
        dailyChange = '0.00%';
        dailyChangeColor = colors.textSecondary;
      } else if (isAfterMarketClose && activeRecord.isSettled) {
        // ★ 15:05后已结算：用冻结的收盘数据
        profitUpCount = activeRecord.upCount;
        profitDownCount = activeRecord.downCount;
        final settledTotalChange = activeRecord.dailyAvgChange * activeRecord.stocks.length;
        dailyChange = '${settledTotalChange.toStringAsFixed(2)}%';
        dailyChangeColor = settledTotalChange >= 0 ? Colors.red : Colors.green;
      } else {
        // ★ 交易时段 09:30~15:05 或结算窗口：用实时/保存数据
        int upCount = 0;
        int downCount = 0;
        double totalChange = 0;
        int liveCount = 0;
        int savedCount = 0;

        for (var stock in activeRecord.stocks) {
          // 结算窗口期优先使用实时缓存（09:30-15:05）
          final liveChange = _liveChangePercents[stock.code];
          if (liveChange != null && _isSettlementWindow()) {
            totalChange += liveChange;
            liveCount++;
            if (liveChange > 0) upCount++;
            else if (liveChange < 0) downCount++;
          } else if (stock.changePercent != 0) {
            // 收盘后或已保存的数据
            totalChange += stock.changePercent;
            savedCount++;
            if (stock.changePercent > 0) upCount++;
            else if (stock.changePercent < 0) downCount++;
          } else if (activeRecord.isSettled) {
            // 已结算但0%
            savedCount++;
          }
        }

        if (liveCount > 0 || savedCount > 0) {
          profitUpCount = upCount;
          profitDownCount = downCount;
          dailyChange = '${totalChange.toStringAsFixed(2)}%';
          dailyChangeColor = totalChange >= 0 ? Colors.red : Colors.green;
        } else if (activeRecord.isSettled) {
          profitUpCount = activeRecord.upCount;
          profitDownCount = activeRecord.downCount;
          final settledTotalChange = activeRecord.dailyAvgChange * activeRecord.stocks.length;
          dailyChange = '${settledTotalChange.toStringAsFixed(2)}%';
          dailyChangeColor = settledTotalChange >= 0 ? Colors.red : Colors.green;
        } else {
          // 新记录：尚未开盘
          profitText = '0.00%';
        }
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '核心统计指标',
            style: AppText.h3.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              // 盈亏分布：红涨绿跌
              _buildProfitStatItem(
                upCount: profitUpCount,
                downCount: profitDownCount,
                fallbackText: profitText,
              ),
              _buildStatItem(
                icon: Icons.percent,
                label: '当日总涨幅',
                value: dailyChange,
                color: dailyChangeColor,
              ),
              _buildStatItem(
                icon: Icons.assessment,
                label: '日平均收益',
                value: '${avgReturn.toStringAsFixed(2)}%',
                color: avgReturn >= 0 ? Colors.red : Colors.green,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 构建统计项
  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final colors = AppColors.of(context);

    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 8),
        Text(
          label,
          style: AppText.caption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: AppText.h3.copyWith(
            color: color,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  /// 构建盈亏分布统计项（红涨绿跌）
  Widget _buildProfitStatItem({
    int? upCount,
    int? downCount,
    String fallbackText = '--',
  }) {
    final colors = AppColors.of(context);

    // 构建红涨绿跌的文字
    Widget valueWidget;
    if (upCount != null && downCount != null) {
      valueWidget = RichText(
        text: TextSpan(
          style: AppText.h3.copyWith(fontWeight: FontWeight.w800),
          children: [
            TextSpan(
              text: '$upCount涨',
              style: TextStyle(color: Colors.red),
            ),
            TextSpan(
              text: ':',
              style: TextStyle(color: colors.textSecondary),
            ),
            TextSpan(
              text: '$downCount跌',
              style: TextStyle(color: Colors.green),
            ),
          ],
        ),
      );
    } else {
      valueWidget = Text(
        fallbackText,
        style: AppText.h3.copyWith(
          color: colors.textSecondary,
          fontWeight: FontWeight.w800,
        ),
      );
    }

    return Column(
      children: [
        Icon(Icons.trending_up, color: colors.primary, size: 28),
        const SizedBox(height: 8),
        Text(
          '盈亏分布',
          style: AppText.caption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        valueWidget,
      ],
    );
  }

  /// 构建每日明细表
  /// 显示当前有效期内的记录：
  /// - 20:00~23:59 显示今天新创建的记录（待结算，显示起始价）
  /// - 00:00~18:59 显示昨晚创建的记录（即昨天日期的记录，待结算，显示起始价）
  /// - 已结算的记录显示涨跌幅
  Widget _buildDailyDetailTable() {
    final colors = AppColors.of(context);
    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();

    // 确定当前应该显示哪天的记录：
    // 20:00后 → 显示今天的记录（今晚20:00刚创建的）
    // 20:00前 → 找今天19:00前有效的记录（即昨天20:00后创建的）
    // 周末/节假日找不到 → 找最近的一个交易日记录
    String displayDate;
    if (now.hour >= 20) {
      // 20:00后：显示今天新创建的记录
      displayDate = today;
    } else {
      // 20:00前：找昨天或更早的最近一条记录
      // 先从昨天开始往前找，找到最近有记录的一天
      displayDate = _getYesterdayString();
      // 如果昨天没有记录，尝试找历史记录中最近的日期
      if (!_history.any((r) => r.date == displayDate)) {
        // 找历史记录中最新的日期（应该是最近一个交易日）
        if (_history.isNotEmpty) {
          displayDate = _history.first.date;
        }
      }
    }

    var displayRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    var hasRecord = displayRecord.date == displayDate && displayRecord.stocks.isNotEmpty;

    // 周末/节假日找不到 displayDate 的记录，使用最新一条
    if (!hasRecord && _history.isNotEmpty) {
      displayRecord = _history.first;
      hasRecord = displayRecord.stocks.isNotEmpty;
    }

    if (!hasRecord) {
      // 没有有效期内记录
      final isAfter20 = now.hour >= 20;
      final settledHistory = _history.where((r) => r.isSettled).toList();
      final latestSettled = settledHistory.isNotEmpty ? settledHistory.first : null;

      // 20:00后没有今日记录 → 显示刷新提示
      if (isAfter20 && latestSettled == null) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '每日明细表',
                style: AppText.h3.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '暂无记录，点击标题栏🔄按钮获取最新选股',
                style: AppText.body1.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        );
      }

      // 有已结算记录但今日无记录 → 显示最新已结算 + 提示
      if (latestSettled != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSettledDetailTable(latestSettled, colors),
            if (isAfter20)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '💡 点击标题栏🔄按钮可刷新今日最新选股',
                  style: AppText.caption.copyWith(color: colors.textSecondary),
                ),
              ),
          ],
        );
      }

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '每日明细表',
              style: AppText.h3.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无记录（每晚20:00自动更新）',
              style: AppText.body1.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    // 有效期内的记录
    final isSettled = displayRecord.isSettled;
    final subtitle = isSettled
        ? '${displayRecord.date} (已结算)'
        : '${displayRecord.date} (待结算)';

    // 按策略分组显示
    final hotMoneyStocks = displayRecord.stocks.where((s) => s.strategy == 'A股游资').toList();
    final overnightStocks = displayRecord.stocks.where((s) => s.strategy == '隔夜导航').toList();
    final otherStocks = displayRecord.stocks.where((s) => s.strategy != 'A股游资' && s.strategy != '隔夜导航').toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '每日明细表 ($subtitle)',
                style: AppText.h3.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (now.hour >= 20 && !isSettled)
                GestureDetector(
                  onTap: _recreating ? null : () async {
                    if (!ExpertPerformanceService.isTradingDay()) {
                      _showSnackBar('今天不是交易日');
                      return;
                    }
                    setState(() => _recreating = true);
                    try {
                      final recreated = await ExpertPerformanceService.forceRecreateTodayRecord();
                      await _loadData();
                      if (mounted) {
                        _showSnackBar(recreated ? '已刷新今日选股' : '刷新失败，请重试');
                      }
                    } finally {
                      if (mounted) setState(() => _recreating = false);
                    }
                  },
                  child: _recreating
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: colors.primary),
                        )
                      : Icon(Icons.refresh, size: 18, color: colors.primary),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // 6只股票统一显示（不分组）
          ...displayRecord.stocks.map((stock) => _buildStockRow(stock, isSettled, colors, displayDate)),
        ],
      ),
    );
  }

  /// 构建股票行
  /// ★ 涨跌幅显示逻辑（结算窗口期 9:30-19:30）：
  ///   结算窗口期内: 优先使用实时缓存 _liveChangePercents 显示实时涨跌幅
  ///   结算窗口期外或已结算: 使用保存的 stock.changePercent（冻结数据）
  ///   新记录(20:00后)/无数据: 显示 0.00%（灰色）
  Widget _buildStockRow(StockPerformance stock, bool isSettled, AppColorScheme colors, String recordDate) {
    String valueText;
    Color valueColor;

    // ★ 尚未到下一个交易日确认时间 → 显示 0.00%
    if (TradingDayUtils.shouldRecordShowZero(recordDate)) {
      valueText = '0.00%';
      valueColor = colors.textSecondary;
    } else {
      final liveChange = _liveChangePercents[stock.code];
      if (liveChange != null && _isSettlementWindow()) {
        final isUp = liveChange >= 0;
        valueText = '${isUp ? "+" : ""}${liveChange.toStringAsFixed(2)}%';
        valueColor = isUp ? Colors.red : Colors.green;
      } else if (isSettled || stock.changePercent != 0) {
        final isUp = stock.changePercent >= 0;
        valueText = '${isUp ? "+" : ""}${stock.changePercent.toStringAsFixed(2)}%';
        valueColor = isUp ? Colors.red : Colors.green;
      } else {
        valueText = '0.00%';
        valueColor = colors.textSecondary;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              stock.name,
              style: AppText.body1.copyWith(color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              stock.code,
              style: AppText.body1.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              valueText,
              style: AppText.body1.copyWith(
                color: valueColor,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  /// 已结算记录的明细表
  Widget _buildSettledDetailTable(DailyExpertPerformance record, AppColorScheme colors) {
    // 按策略分组
    final hotMoneyStocks = record.stocks.where((s) => s.strategy == 'A股游资').toList();
    final overnightStocks = record.stocks.where((s) => s.strategy == '隔夜导航').toList();
    final otherStocks = record.stocks.where((s) => s.strategy != 'A股游资' && s.strategy != '隔夜导航').toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '每日明细表 (${record.date})',
            style: AppText.h3.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          ...record.stocks.map((stock) => _buildStockRow(stock, true, colors, record.date)),
        ],
      ),
    );
  }

  /// 获取昨天日期字符串
  static String _getYesterdayString() {
    // ★ 修复：返回上一个交易日（跳过周末+节假日），而不是简单的昨天
    var yesterday = DateTime.now().subtract(const Duration(days: 1));
    while (_isNonTradingDay(yesterday)) {
      yesterday = yesterday.subtract(const Duration(days: 1));
    }
    return '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
  }

  /// 获取指定日期的下一个交易日（跳过周末+A股节假日）
  /// 用于计算记录有效期截止时间（创建日20:00 → 下一个交易日19:00）
  static DateTime _getNextTradingDay(DateTime date) {
    var nextDay = date.add(const Duration(days: 1));
    // 跳过周末（周六=6, 周日=7）和A股节假日
    while (_isNonTradingDay(nextDay)) {
      nextDay = nextDay.add(const Duration(days: 1));
    }
    return nextDay;
  }

  /// A股非交易日判断：周末或节假日
  static bool _isNonTradingDay(DateTime date) {
    if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
      return true;
    }
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return _kExpertHolidayDates.contains(dateStr);
  }

  static const Set<String> _kExpertHolidayDates = {
    '2026-01-01',
    '2026-02-16', '2026-02-17', '2026-02-18', '2026-02-19',
    '2026-02-20', '2026-02-21', '2026-02-22',
    '2026-04-04', '2026-04-05', '2026-04-06',
    '2026-05-01', '2026-05-02', '2026-05-03', '2026-05-04', '2026-05-05',
    '2026-06-19', '2026-06-20', '2026-06-21',
    '2026-09-25', '2026-09-26', '2026-09-27',
    '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04',
    '2026-10-05', '2026-10-06', '2026-10-07',
  };

  /// 构建收益趋势曲线图（专业金融风格）
  /// ★ 使用交易日记录的 avgChangePercent 计算累计收益
  Widget _buildTrendChart() {
    final colors = AppColors.of(context);

    if (_history.isEmpty) return const SizedBox();

    // ★ 建立交易日记录映射，优先使用交易日记录的数据
    final tradingRecordMap = <String, double>{};

    for (var tr in _tradingRecords) {
      // ★ 尚未到下一个交易日确认时间的记录按0计算
      tradingRecordMap[tr.date] = TradingDayUtils.shouldRecordShowZero(tr.date)
          ? 0.0
          : tr.avgChangePercent;
    }

    // 按日期正序排列
    var sorted = [..._history]
      ..sort((a, b) => a.date.compareTo(b.date));

    // ★ 根据时间范围筛选数据
    if (_trendTimeRange == 3 && _trendCustomStart != null && _trendCustomEnd != null) {
      // 自定义日期范围
      sorted = _filterByDateRange(sorted, _trendCustomStart!, _trendCustomEnd!);
    } else if (_trendTimeRange == 4) {
      // 全部数据：不过滤
    } else {
      final daysMap = {0: 7, 1: 30, 2: 90};
      if (sorted.length > daysMap[_trendTimeRange]!) {
        sorted = sorted.sublist(sorted.length - daysMap[_trendTimeRange]!);
      }
    }

    // ★ 所有模式统一：简单累计平均（固定投资，每天独立计算）
    const double initialCapital = 100000.0;

    final spots = <FlSpot>[];
    final dateLabels = <String>[];
    final dailyChanges = <double>[];

    double simpleCumulative = 0.0;
    double maxDrawdownPercent = 0.0;
    double peakCumulative = 0.0;

    for (int i = 0; i < sorted.length; i++) {
      final dailyChangePercent = tradingRecordMap[sorted[i].date] ?? sorted[i].dailyAvgChange;
      dailyChanges.add(dailyChangePercent);

      // ★ 简单累加（固定投资，每天独立）
      simpleCumulative += dailyChangePercent;

      // 最大回撤：基于累计值的回落幅度
      if (simpleCumulative > peakCumulative) peakCumulative = simpleCumulative;
      final drawdownPct = peakCumulative - simpleCumulative;
      if (drawdownPct > maxDrawdownPercent) maxDrawdownPercent = drawdownPct;

      spots.add(FlSpot(i.toDouble(), simpleCumulative));
      dateLabels.add(sorted[i].date.substring(5));
    }

    // Y轴范围 — 合并沪深300数据（起始日2026-04-20）
    final hs300Spots = <FlSpot>[];
    {
      const hs300BaseDate = '2026-04-20';
      int baseIdx = -1;
      for (int i = 0; i < sorted.length; i++) {
        if (sorted[i].date.compareTo(hs300BaseDate) >= 0) {
          baseIdx = i;
          break;
        }
      }
      double hs300Cum = 0.0;
      for (int i = 0; i < sorted.length; i++) {
        if (baseIdx >= 0 && i >= baseIdx) {
          final nextDay = ExpertPerformanceService.nextDay(sorted[i].date);
          final change = _hs300DailyChanges[nextDay] ?? 0.0;
          hs300Cum += change;
        }
        hs300Spots.add(FlSpot(i.toDouble(), baseIdx >= 0 && i >= baseIdx ? hs300Cum : 0.0));
      }
    }
    // 中证1000收盘价折线图色点（起始日2026-04-20，橙色）
    final zz1000Spots = <FlSpot>[];
    {
      const zz1000BaseDate = '2026-04-20';
      int baseIdx = -1;
      for (int i = 0; i < sorted.length; i++) {
        if (sorted[i].date.compareTo(zz1000BaseDate) >= 0) {
          baseIdx = i;
          break;
        }
      }
      double zz1000Cum = 0.0;
      for (int i = 0; i < sorted.length; i++) {
        if (baseIdx >= 0 && i >= baseIdx) {
          final nextDay = ExpertPerformanceService.nextDay(sorted[i].date);
          final change = _zz1000DailyChanges[nextDay] ?? 0.0;
          zz1000Cum += change;
        }
        zz1000Spots.add(FlSpot(i.toDouble(), baseIdx >= 0 && i >= baseIdx ? zz1000Cum : 0.0));
      }
    }
    final allYValues = [...spots.map((s) => s.y), ...hs300Spots.map((s) => s.y), ...zz1000Spots.map((s) => s.y)];
    final yMin = allYValues.isEmpty ? -1.0 : (allYValues.reduce(math.min) - 1).floorToDouble();
    final yMax = allYValues.isEmpty ? 1.0 : (allYValues.reduce(math.max) + 1).ceilToDouble();
    final zeroY = 0.0;

    // 统计数据
    final currentReturn = spots.isNotEmpty ? spots.last.y : 0.0;
    final totalProfitAmount = initialCapital * (currentReturn / 100);
    // ★ 较上周：取7天前数据点（若无则取最早点）
    final prevIdx = spots.length > 7 ? spots.length - 8 : 0;
    final prevReturn = spots[prevIdx].y;
    final periodChange = currentReturn - prevReturn;
    // 沪深300当前收益率和周期变化
    final hs300CurrentReturn = hs300Spots.isNotEmpty ? hs300Spots.last.y : 0.0;
    final hs300PrevReturn = hs300Spots.length > 1 ? hs300Spots[hs300Spots.length - 2].y : hs300CurrentReturn;
    final hs300PeriodChange = hs300CurrentReturn - hs300PrevReturn;
    // 中证1000当前收益率和周期变化
    final zz1000CurrentReturn = zz1000Spots.isNotEmpty ? zz1000Spots.last.y : 0.0;
    final zz1000PrevReturn = zz1000Spots.length > 1 ? zz1000Spots[zz1000Spots.length - 2].y : zz1000CurrentReturn;
    final zz1000PeriodChange = zz1000CurrentReturn - zz1000PrevReturn;

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ★ 标题栏：左侧图标+标题，右侧收益率
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.trending_up,
                  color: Color(0xFF3B82F6),
                  size: 18,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '累计收益趋势',
                style: AppText.h3.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              const Spacer(),
              // 左右数据列：IntrinsicHeight + stretch 保证等高对齐
              IntrinsicHeight(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 蓝色+橙色：沪深300/中证1000上下排列
                    if (hs300Spots.length >= 2 || zz1000Spots.length >= 2)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hs300Spots.length >= 2)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('沪深300 ',
                                    style: TextStyle(color: Color(0xFF3B82F6), fontWeight: FontWeight.w700, fontSize: 12)),
                                Text('${hs300CurrentReturn >= 0 ? '+' : ''}${hs300CurrentReturn.toStringAsFixed(2)}%',
                                    style: TextStyle(
                                        color: hs300CurrentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                                        fontWeight: FontWeight.w800, fontSize: 12)),
                              ],
                            ),
                          if (zz1000Spots.length >= 2)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text('中证1000 ',
                                    style: TextStyle(color: Color(0xFFFF8C00), fontWeight: FontWeight.w700, fontSize: 12)),
                                Text('${zz1000CurrentReturn >= 0 ? '+' : ''}${zz1000CurrentReturn.toStringAsFixed(2)}%',
                                    style: TextStyle(
                                        color: zz1000CurrentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                                        fontWeight: FontWeight.w800, fontSize: 12)),
                              ],
                            ),
                        ],
                      ),
                    const SizedBox(width: 6),
                    Container(width: 1, color: colors.border),
                    const SizedBox(width: 6),
                    // 红色方框：专家数据
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${currentReturn >= 0 ? '+' : ''}${currentReturn.toStringAsFixed(2)}%',
                          style: TextStyle(
                            color: currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                        ),
                        Text(
                          '较上周 ${periodChange >= 0 ? '+' : ''}${periodChange.toStringAsFixed(2)}%',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ★ 时间筛选标签
          _buildTimeFilterTabs(),
          const SizedBox(height: 8),
          // ★ 累计收益趋势图
          _buildScrollableTrendChart(spots, dateLabels, dailyChanges, yMin, yMax, zeroY, hs300Spots, zz1000Spots),
          const SizedBox(height: 8),
          // ★ 底部统计卡片
          _buildTrendStats(currentReturn, totalProfitAmount, dailyChanges, maxDrawdownPercent),
        ],
      ),
    );
  }

  /// ★ 构建累计收益趋势图时间筛选标签（不换行，均匀分布）
  Widget _buildTimeFilterTabs() {
    final colors = AppColors.of(context);
    final tabs = ['近7天', '近30天', '近90天', '自定义', '全部'];

    return Row(
      children: tabs.asMap().entries.map((entry) {
        final index = entry.key;
        final tab = entry.value;
        final isSelected = index == _trendTimeRange;
        final isCustom = index == 3;
        return GestureDetector(
          onTap: () async {
            if (isCustom) {
              // ★ 自定义：弹出菜单选择
              final result = await _showCustomDateRangePicker(
                currentStart: _trendCustomStart,
                currentEnd: _trendCustomEnd,
              );
              if (result != null) {
                setState(() {
                  _trendTimeRange = 3;
                  _trendCustomStart = result['start'];
                  _trendCustomEnd = result['end'];
                });
              }
            } else {
              setState(() {
                _trendTimeRange = index;
                _trendCustomStart = null;
                _trendCustomEnd = null;
              });
            }
          },
          child: Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF3B82F6) : colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? const Color(0xFF3B82F6) : colors.border,
              ),
            ),
            child: Text(
              (isSelected && isCustom && _trendCustomStart != null && _trendCustomEnd != null)
                  ? '${_trendCustomStart!.month}/${_trendCustomStart!.day}-${_trendCustomEnd!.month}/${_trendCustomEnd!.day}'
                  : tab,
              style: TextStyle(
                color: isSelected ? Colors.white : colors.textSecondary,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// ★ 构建趋势图底部统计
  Widget _buildTrendStats(double currentReturn, double totalProfitAmount, List<double> dailyChanges, double maxDrawdownPercent) {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 计算波动率 - 基于每日收益率百分比
    double volatility = 0.0;
    if (dailyChanges.length > 1) {
      final avg = dailyChanges.reduce((a, b) => a + b) / dailyChanges.length;
      final variance = dailyChanges.map((x) => math.pow(x - avg, 2)).reduce((a, b) => a + b) / (dailyChanges.length - 1);
      volatility = math.sqrt(variance);
    }

    // ★ 计算总盈亏比：总盈利 ÷ 总亏损（收益为负时自动 <1，符合直觉）
    double totalProfit = 0.0;
    double totalLoss = 0.0;
    double winLossRatio = 0.0;
    for (var change in dailyChanges) {
      if (change > 0) {
        totalProfit += change;
      } else if (change < 0) {
        totalLoss += change.abs();
      }
    }
    if (totalProfit > 0 && totalLoss > 0) {
      winLossRatio = totalProfit / totalLoss;
    }

    final stats = [
      _StatItemWithIcon(
        icon: Icons.trending_up_rounded,
        iconBg: const Color(0xFF3B82F6).withOpacity(0.15),
        iconColor: const Color(0xFF3B82F6),
        label: '当前收益率',
        value: '${currentReturn >= 0 ? '+' : ''}${currentReturn.toStringAsFixed(2)}%',
        valueColor: currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
      ),
      _StatItemWithIcon(
        icon: Icons.balance_rounded,
        iconBg: const Color(0xFF8B5CF6).withOpacity(0.15),
        iconColor: const Color(0xFF8B5CF6),
        label: '总盈亏比',
        value: winLossRatio > 0
            ? '${currentReturn >= 0 ? '+' : '-'}${winLossRatio.toStringAsFixed(2)}'
            : '--',
        valueColor: currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
      ),
      _StatItemWithIcon(
        icon: Icons.speed_rounded,
        iconBg: const Color(0xFFF59E0B).withOpacity(0.15),
        iconColor: const Color(0xFFF59E0B),
        label: '日收益波动率',
        value: '${volatility.toStringAsFixed(2)}%',
        valueColor: const Color(0xFFF59E0B),
      ),
      _StatItemWithIcon(
        icon: Icons.trending_down_rounded,
        iconBg: const Color(0xFF10B981).withOpacity(0.15),
        iconColor: const Color(0xFF10B981),
        label: '最大回撤',
        value: '-${maxDrawdownPercent.toStringAsFixed(2)}%',
        valueColor: const Color(0xFF10B981),
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151928) : const Color(0xFFF5F6FA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: stats.map((stat) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    color: stat.iconBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(stat.icon, color: stat.iconColor, size: 9),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        stat.label,
                        softWrap: false,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 8,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        stat.value,
                        softWrap: false,
                        style: TextStyle(
                          color: stat.valueColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        )).toList(),
      ),
    );
  }

  /// ★ 自定义日期范围选择器（直接弹出日期选择，无中间菜单）
  Future<Map<String, DateTime>?> _showCustomDateRangePicker({DateTime? currentStart, DateTime? currentEnd}) async {
    final now = DateTime.now();
    final defaultStart = currentStart ?? now.subtract(const Duration(days: 30));
    final defaultEnd = currentEnd ?? now;

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: defaultStart, end: defaultEnd),
      firstDate: DateTime(2020),
      lastDate: now,
      helpText: '选择日期区间',
      cancelText: '取消',
      confirmText: '确定',
      saveText: '确定',
      builder: (context, child) {
        // ★ 根据系统主题自动切换浅色/深色模式
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Theme(
          data: isDark
              ? ThemeData.dark().copyWith(
                  colorScheme: const ColorScheme.dark(
                    primary: Color(0xFF3B82F6),
                    onPrimary: Colors.white,
                    surface: Color(0xFF1E1E2E),
                    onSurface: Colors.white,
                    onSurfaceVariant: Color(0xFFB0B0C0),
                  ),
                  dialogBackgroundColor: const Color(0xFF1E1E2E),
                  scaffoldBackgroundColor: const Color(0xFF121220),
                )
              : ThemeData.light().copyWith(
                  colorScheme: const ColorScheme.light(
                    primary: Color(0xFF1B3A6B),
                    onPrimary: Colors.white,
                    surface: Colors.white,
                    onSurface: Color(0xFF1A1A2E),
                    onSurfaceVariant: Color(0xFF666666),
                  ),
                  dialogBackgroundColor: Colors.white,
                  scaffoldBackgroundColor: const Color(0xFFF5F5F5),
                ),
          child: child!,
        );
      },
    );

    if (picked == null) return null;
    return {'start': picked.start, 'end': picked.end};
  }

  /// ★ 根据日期范围过滤历史数据
  List<DailyExpertPerformance> _filterByDateRange(List<DailyExpertPerformance> sorted, DateTime start, DateTime end) {
    final startStr = '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    final endStr = '${end.year}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}';
    return sorted.where((r) => r.date.compareTo(startStr) >= 0 && r.date.compareTo(endStr) <= 0).toList();
  }

  /// 构建趋势图主体（独立方法，避免括号嵌套错误）
  Widget _buildTrendChartBody(
    List<FlSpot> spots,
    List<String> dateLabels,
    List<double> dailyChanges,
    double yMin,
    double yMax,
    double zeroY,
    double cumulativeReturn,
  ) {
    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: math.max((yMax - yMin) / 5, 1),
          getDrawingHorizontalLine: (value) => FlLine(
            color: value == zeroY
                ? Colors.grey.withOpacity(0.5)
                : Colors.grey.withOpacity(0.15),
            strokeWidth: value == zeroY ? 1.5 : 0.5,
            dashArray: value == zeroY ? null : [4, 4],
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              interval: math.max((yMax - yMin) / 5, 1),
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${value.toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: Colors.grey[500],
                    fontSize: 10,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= dateLabels.length) return const SizedBox();
                final int step;
                if (spots.length <= 12) {
                  step = 1;
                } else if (spots.length <= 24) {
                  step = 2;
                } else {
                  step = 3;
                }
                if (idx % step != 0) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    dateLabels[idx],
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          ),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minY: yMin,
        maxY: yMax,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.3,
            color: const Color(0xFFE05555).withOpacity(0.9),
            barWidth: 2.0,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                final isUp = index < dailyChanges.length && dailyChanges[index] >= 0;
                final baseColor = isUp 
                  ? const Color(0xFFCE4346)  // 暗红（上涨点）
                  : const Color(0xFF52C87A); // 翠绿（下跌点）
                return FlDotCirclePainter(
                  radius: 3.5,
                  gradient: LinearGradient(colors: [ baseColor,  baseColor]),
                  strokeWidth: 1.5,
                  strokeColor: const Color(0x80FFFFFF),  // ★ 白色亮边
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(colors: [ const Color(0xFFE05555).withOpacity(0.05),  const Color(0xFFE05555).withOpacity(0.05)]),
            ),
            aboveBarData: BarAreaData(show: false),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            tooltipBgColor: Colors.grey[800]!,
            tooltipRoundedRadius: 6,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: (touchedSpots) => touchedSpots.map((spot) {
              final idx = spot.x.toInt();
              final isUp = idx < dailyChanges.length && dailyChanges[idx] >= 0;
              return LineTooltipItem(
                '${dateLabels[idx]}\n${spot.y >= 0 ? '+' : ''}${spot.y.toStringAsFixed(2)}%',
                TextStyle(
                  color: isUp ? Colors.red[300] : Colors.green[300],
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  /// ★ 1:1 复刻参考图——分段折线渲染
  /// 含渐变区域填充 + 多层辉光线条 + 精致数据点
  List<LineChartBarData> _buildSegmentedLineBars(
    List<FlSpot> spots,
    List<double> dailyChanges,
  ) {
    final List<LineChartBarData> result = [];

    if (spots.length < 2) return result;

    // 涨跌配色（参考图中使用的颜色）
    const upColor = Color(0xFFF55555);   // 柔红色
    const downColor = Color(0xFF3DC896); // 柔绿色

    for (int i = 0; i < spots.length - 1; i++) {
      final isUp = (i + 1) < dailyChanges.length && dailyChanges[i + 1] >= 0;
      final color = isUp ? upColor : downColor;

      // Layer 1: 区域填充渐变（线到零线→深蓝底色）
      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true,
        curveSmoothness: 0.3,
        color: Colors.transparent,
        barWidth: 0,
        dotData: FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withOpacity(0.18),
              color.withOpacity(0.06),
              color.withOpacity(0.0),
            ],
            stops: const [0.0, 0.4, 1.0],
          ),
          applyCutOffY: true,
        ),
        aboveBarData: BarAreaData(show: false),
      ));

      // Layer 2: 外层光晕（宽幅、极淡）
      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true,
        curveSmoothness: 0.3,
        color: color.withOpacity(0.18),
        barWidth: 6.0,
        dotData: FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
        aboveBarData: BarAreaData(show: false),
      ));

      // Layer 3: 中层光晕
      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true,
        curveSmoothness: 0.3,
        color: color.withOpacity(0.40),
        barWidth: 3.0,
        dotData: FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
        aboveBarData: BarAreaData(show: false),
      ));

      // Layer 4: 主线（实色细线 + 辉光阴影）
      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true,
        curveSmoothness: 0.3,
        color: color,
        barWidth: 2.0,
        shadow: Shadow(
          color: color.withOpacity(0.5),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
        dotData: FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
        aboveBarData: BarAreaData(show: false),
      ));
    }

    // Layer 5: 数据点（白色外圈 + 实心内填）
    result.add(LineChartBarData(
      spots: spots,
      isCurved: false,
      color: Colors.transparent,
      barWidth: 0,
      dotData: FlDotData(
        show: true,
        getDotPainter: (spot, percent, barData, index) {
          final idx = spot.x.toInt();
          final isUp = idx < dailyChanges.length && dailyChanges[idx] >= 0;
          return FlDotCirclePainter(
            radius: 2.0,
            gradient: LinearGradient(colors: [ isUp ? upColor : downColor,  isUp ? upColor : downColor]),
            strokeWidth: 1.2,
            strokeColor: Colors.white,
          );
        },
      ),
      belowBarData: BarAreaData(show: false),
      aboveBarData: BarAreaData(show: false),
    ));

    return result;
  }

  /// ★ 1:1 复刻参考图——可滚动趋势图
  /// ★ 处理趋势图点击：计算最近数据点并弹出提示
  OverlayEntry? _trendOverlayEntry;

  /// ★ 点击趋势图数据点，用 Overlay 显示提示（不触发 setState，不影响滚动）
  void _showTrendTooltip(
    PointerUpEvent event,
    List<FlSpot> spots,
    List<String> dateLabels,
    List<double> dailyChanges,
    bool isDark, {
    List<FlSpot> hs300Spots = const [],
    List<FlSpot> zz1000Spots = const [],
  }) {
    // 先移除旧提示
    _removeTrendTooltip();
    if (spots.isEmpty) return;

    // 根据全局坐标计算点击位置对应的数据点
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final localPos = box.globalToLocal(event.position);
    // 估算点击的是第几个数据点（基于屏幕宽度比例）
    final screenWidth = MediaQuery.of(context).size.width;
    final chartAreaWidth = screenWidth - 72; // 减去Y轴和间距
    final ratio = (localPos.dx - 42).clamp(0.0, chartAreaWidth) / chartAreaWidth;
    final idx = (ratio * (spots.length - 1)).round().clamp(0, spots.length - 1);

    final spot = spots[idx];
    final isUp = idx < dailyChanges.length && dailyChanges[idx] >= 0;
    String tooltipText = '${dateLabels[idx]}\n专家: ${spot.y >= 0 ? '+' : ''}${spot.y.toStringAsFixed(2)}%';
    // 附加沪深300数据
    if (idx < hs300Spots.length) {
      final hsVal = hs300Spots[idx].y;
      tooltipText += '\n沪深300: ${hsVal >= 0 ? '+' : ''}${hsVal.toStringAsFixed(2)}%';
    }
    // 附加中证1000数据
    if (idx < zz1000Spots.length) {
      final zzVal = zz1000Spots[idx].y;
      if (zzVal != 0.0 || (zz1000Spots.isNotEmpty && idx >= zz1000Spots.length - 10)) {
        tooltipText += '\n中证1000: ${zzVal >= 0 ? '+' : ''}${zzVal.toStringAsFixed(2)}%';
      }
    }

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 全屏透明层，点击关闭
          Positioned.fill(
            child: GestureDetector(
              onTap: _removeTrendTooltip,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // 提示框
          Positioned(
            left: (event.position.dx - 55).clamp(8.0, screenWidth - 120),
            top: (event.position.dy - 75).clamp(40.0, event.position.dy - 10),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E2240) : const Color(0xFF333333),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  tooltipText,
                  style: TextStyle(
                    color: isUp ? const Color(0xFFFF8A8A) : const Color(0xFF6FDFD6),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    _trendOverlayEntry = entry;
    overlay?.insert(entry);
  }

  void _removeTrendTooltip() {
    _trendOverlayEntry?.remove();
    _trendOverlayEntry = null;
  }

  Widget _buildScrollableTrendChart(
    List<FlSpot> spots,
    List<String> dateLabels,
    List<double> dailyChanges,
    double yMin,
    double yMax,
    double zeroY,
    List<FlSpot> hs300Spots,
    List<FlSpot> zz1000Spots,
  ) {
    final interval = math.max((yMax - yMin) / 5, 1);
    final yLabelCount = ((yMax - yMin) / interval).ceil() + 1;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 深色背景色
    final chartBgDark = isDark ? const Color(0xFF121626) : const Color(0xFFF8F9FC);
    final labelColor = isDark ? const Color(0xFF8890A8) : const Color(0xFF8E8E93);
    final zeroLineColor = isDark ? const Color(0xFF2D3148) : const Color(0xFFE5E5EA);
    final gridColor = isDark ? const Color(0xFF232740) : const Color(0xFFEFF0F5);

    // 合并lineBarsData：专家收益折线 + 沪深300蓝色折线
    final allLineBars = <LineChartBarData>[
      ..._buildSegmentedLineBars(spots, dailyChanges),
    ];
    // 沪深300蓝色直线
    if (hs300Spots.length >= 2) {
      allLineBars.add(LineChartBarData(
        spots: hs300Spots,
        isCurved: false,
        color: const Color(0xFF3B82F6),
        barWidth: 2.0,
        dotData: FlDotData(
          show: true,
          getDotPainter: (spot, percent, barData, index) =>
              FlDotCirclePainter(radius: 2.5, color: const Color(0xFF3B82F6), strokeWidth: 0),
        ),
        belowBarData: BarAreaData(show: false),
      ));
    }
    // 中证1000橙色直线
    if (zz1000Spots.length >= 2) {
      allLineBars.add(LineChartBarData(
        spots: zz1000Spots,
        isCurved: false,
        color: const Color(0xFFFF8C00),
        barWidth: 2.0,
        dotData: FlDotData(
          show: true,
          getDotPainter: (spot, percent, barData, index) =>
              FlDotCirclePainter(radius: 2.0, color: const Color(0xFFFF8C00), strokeWidth: 0),
        ),
        belowBarData: BarAreaData(show: false),
      ));
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
            ? [const Color(0xFF0D1120), const Color(0xFF13182B)]
            : [const Color(0xFFF8F9FC), const Color(0xFFF0F1F5)],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左侧固定 Y 轴
          SizedBox(
            width: 38,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(yLabelCount, (i) {
                final value = yMax - (i * interval);
                final isZero = (value - zeroY).abs() < 0.01;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    '${value.toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: isZero
                        ? (isDark ? const Color(0xFFC0C8D8) : const Color(0xFF555555))
                        : labelColor,
                      fontSize: 9,
                      fontWeight: isZero ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(width: 4),
          // 右侧可滑动图表
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) => _trendPointerDownPos = event.position,
              onPointerUp: (event) {
                // 短按=点击显示提示，长拖=滚动（不处理）
                if (_trendPointerDownPos != null &&
                    (event.position - _trendPointerDownPos!).distance < 15) {
                  _showTrendTooltip(event, spots, dateLabels, dailyChanges, isDark, hs300Spots: hs300Spots, zz1000Spots: zz1000Spots);
                }
                _trendPointerDownPos = null;
              },
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: SizedBox(
                  width: math.max(spots.length * 5.5, MediaQuery.of(context).size.width - 72),
                  child: LineChart(
                    LineChartData(
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: 1,
                            reservedSize: 18,
                            getTitlesWidget: (value, meta) {
                              final idx = value.toInt();
                              if (idx < 0 || idx >= dateLabels.length) return const SizedBox();
                              final step = spots.length > 20 ? 3 : (spots.length > 10 ? 2 : 1);
                              if (idx % step != 0) return const SizedBox();
                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  dateLabels[idx],
                                  style: TextStyle(
                                    color: labelColor,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: interval.toDouble(),
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: (value - zeroY).abs() < 0.01
                            ? zeroLineColor
                            : gridColor,
                          strokeWidth: (value - zeroY).abs() < 0.01 ? 1.0 : 0.5,
                          dashArray: [4, 4],
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      minY: yMin,
                      maxY: yMax,
                      lineBarsData: allLineBars,
                      lineTouchData: LineTouchData(enabled: false),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ★ 按照附件模板重新设计
  Widget _buildDailyBarChart() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_history.isEmpty) return const SizedBox();

    // 取所有历史数据，按日期正序（左旧右新）
    var recent = [..._history]
      ..sort((a, b) => a.date.compareTo(b.date));

    // ★ 根据时间范围筛选数据
    if (_barTimeRange == 3 && _barCustomStart != null && _barCustomEnd != null) {
      // 自定义日期范围
      recent = _filterByDateRange(recent, _barCustomStart!, _barCustomEnd!);
    } else if (_barTimeRange == 4) {
      // 全部数据：不过滤
    } else {
      final daysMap = {0: 7, 1: 30, 2: 90};
      if (recent.length > daysMap[_barTimeRange]!) {
        recent = recent.sublist(recent.length - daysMap[_barTimeRange]!);
      }
    }

    // ★ 建立交易日记录映射，优先使用交易日记录中的 avgChangePercent
    final tradingRecordMap = <String, double>{};
    for (var tr in _tradingRecords) {
      // ★ 尚未到下一个交易日确认时间的记录按0计算
      tradingRecordMap[tr.date] = TradingDayUtils.shouldRecordShowZero(tr.date)
          ? 0.0
          : tr.avgChangePercent;
    }

    final dateLabels = <String>[];
    final barGroups = <BarChartGroupData>[];
    int upDays = 0;
    int downDays = 0;
    int flatDays = 0;

    for (int i = 0; i < recent.length; i++) {
      final record = recent[i];
      // ★ 优先使用交易日记录的 avgChangePercent，否则使用 ExpertPerformance 的 dailyAvgChange
      final avgChange = tradingRecordMap[record.date] ?? record.dailyAvgChange;
      final isUp = avgChange > 0;
      final isDown = avgChange < 0;
      final isFlat = avgChange == 0;

      // 统计涨跌天数
      if (isUp) upDays++;
      else if (isDown) downDays++;
      else flatDays++;

      dateLabels.add(record.date.substring(5)); // MM-DD

      barGroups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: avgChange,
            color: isUp ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
            width: recent.length > 15 ? 6 : 10,
            borderRadius: isUp
                ? const BorderRadius.only(
                    topLeft: Radius.circular(3),
                    topRight: Radius.circular(3),
                  )
                : const BorderRadius.only(
                    bottomLeft: Radius.circular(3),
                    bottomRight: Radius.circular(3),
                  ),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: isUp
                  ? [const Color(0xFFFCA5A5), const Color(0xFFEF4444)]
                  : [const Color(0xFF86EFAC), const Color(0xFF22C55E)],
            ),
          ),
        ],
        showingTooltipIndicators: [],
      ));
    }

    // Y轴范围（使用交易日记录的数据计算）
    final allValues = recent.map((r) => tradingRecordMap[r.date] ?? r.dailyAvgChange).toList();
    final yMin = allValues.isEmpty ? -1.0 : (allValues.reduce(math.min) - 0.5).floorToDouble();
    final yMax = allValues.isEmpty ? 1.0 : (allValues.reduce(math.max) + 0.5).ceilToDouble();

    // 计算图表宽度：数据多时加宽以支持左右滑动
    final chartWidth = math.max(barGroups.length * 5.5, MediaQuery.of(context).size.width - 64);

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ★ 标题栏：左侧图标+标题
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.bar_chart,
                  color: Color(0xFFF59E0B),
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '单日平均涨跌',
                style: AppText.h3.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ★ 时间筛选标签（第二行）
          _buildBarTimeFilterTabs(),
          const SizedBox(height: 8),
          // ★ 左侧固定Y轴 + 右侧可滑动柱状图（与累计收益趋势图滚动方式一致）
          Container(
            height: 140,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                  ? [const Color(0xFF0D1120), const Color(0xFF13182B)]
                  : [const Color(0xFFF8F9FC), const Color(0xFFF0F1F5)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左侧固定 Y 轴
                SizedBox(
                  width: 38,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: () {
                      final interval = math.max((yMax - yMin) / 5, 1);
                      final yLabelCount = ((yMax - yMin) / interval).ceil() + 1;
                      return List.generate(yLabelCount, (i) {
                        final value = yMax - (i * interval);
                        final isZero = value.abs() < 0.05;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            '${value >= 0 ? '+' : ''}${value.toStringAsFixed(0)}%',
                            style: TextStyle(
                              color: isZero
                                ? (isDark ? const Color(0xFFC0C8D8) : const Color(0xFF555555))
                                : (isDark ? const Color(0xFF8890A8) : const Color(0xFF8E8E93)),
                              fontSize: 9,
                              fontWeight: isZero ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        );
                      });
                    }(),
                  ),
                ),
                const SizedBox(width: 4),
                // 右侧可滑动图表
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: SizedBox(
                      width: math.max(barGroups.length * 5.5, MediaQuery.of(context).size.width - 72),
                      child: BarChart(
                        BarChartData(
                          alignment: BarChartAlignment.spaceBetween,
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            horizontalInterval: math.max((yMax - yMin) / 5, 1),
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: value.abs() < 0.05
                                  ? (isDark ? const Color(0xFF2D3148) : const Color(0xFFE5E5EA))
                                  : (isDark ? const Color(0xFF232740) : const Color(0xFFEFF0F5)),
                              strokeWidth: value.abs() < 0.05 ? 1.0 : 0.5,
                              dashArray: value.abs() < 0.05 ? null : [4, 4],
                            ),
                          ),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                interval: 1,
                                getTitlesWidget: (value, meta) {
                                  final idx = value.toInt();
                                  if (idx < 0 || idx >= dateLabels.length) return const SizedBox();
                                  final step = barGroups.length > 15 ? 3 : (barGroups.length > 7 ? 2 : 1);
                                  if (idx % step != 0) return const SizedBox();
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      dateLabels[idx],
                                      style: TextStyle(
                                        color: isDark ? const Color(0xFF8890A8) : const Color(0xFF8E8E93),
                                        fontSize: 9,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          borderData: FlBorderData(show: false),
                          minY: yMin,
                          maxY: yMax,
                          barGroups: barGroups,
                          barTouchData: BarTouchData(
                            touchTooltipData: BarTouchTooltipData(
                              tooltipBgColor: isDark ? const Color(0xFF1E2240) : const Color(0xFF333333),
                              tooltipRoundedRadius: 6,
                              fitInsideHorizontally: true,
                              fitInsideVertically: true,
                              tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                final val = rod.toY;
                                return BarTooltipItem(
                                  '${dateLabels[group.x]}\n${val >= 0 ? '+' : ''}${val.toStringAsFixed(2)}%',
                                  TextStyle(
                                    color: val >= 0 ? const Color(0xFFFF8A8A) : const Color(0xFF6FDFD6),
                                    fontWeight: FontWeight.w600,
                                    fontSize: 11,
                                    height: 1.3,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // ★ 底部统计：上涨天数、下跌天数、平盘天数
          _buildBarStats(upDays, downDays, flatDays),
        ],
      ),
    );
  }

  /// ★ 构建图例项
  Widget _buildLegendItem(String label, Color color) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  /// ★ 构建柱状图时间筛选标签
  Widget _buildBarTimeFilterTabs() {
    final colors = AppColors.of(context);
    final tabs = ['近7天', '近30天', '近90天', '自定义', '全部'];

    return Row(
      children: tabs.asMap().entries.map((entry) {
        final index = entry.key;
        final tab = entry.value;
        final isSelected = index == _barTimeRange;
        final isCustom = index == 3;
        return GestureDetector(
          onTap: () async {
            if (isCustom) {
              // ★ 自定义：弹出菜单选择
              final result = await _showCustomDateRangePicker(
                currentStart: _barCustomStart,
                currentEnd: _barCustomEnd,
              );
              if (result != null) {
                setState(() {
                  _barTimeRange = 3;
                  _barCustomStart = result['start'];
                  _barCustomEnd = result['end'];
                });
              }
            } else {
              setState(() {
                _barTimeRange = index;
                _barCustomStart = null;
                _barCustomEnd = null;
              });
            }
          },
          child: Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFFF59E0B) : colors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? const Color(0xFFF59E0B) : colors.border,
              ),
            ),
            child: Text(
              (isSelected && isCustom && _barCustomStart != null && _barCustomEnd != null)
                  ? '${_barCustomStart!.month}/${_barCustomStart!.day}-${_barCustomEnd!.month}/${_barCustomEnd!.day}'
                  : tab,
              style: TextStyle(
                color: isSelected ? Colors.white : colors.textSecondary,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// ★ 构建柱状图底部统计
  Widget _buildBarStats(int upDays, int downDays, int flatDays) {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151928) : const Color(0xFFF5F6FA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(child: _buildDayStat('上涨天数', upDays.toString(), const Color(0xFFEF4444))),
          Container(width: 1, height: 18, color: colors.border),
          Expanded(child: _buildDayStat('下跌天数', downDays.toString(), const Color(0xFF22C55E))),
          Container(width: 1, height: 18, color: colors.border),
          Expanded(child: _buildDayStat('平盘天数', flatDays.toString(), Colors.grey[400]!)),
        ],
      ),
    );
  }

  /// ★ 构建天数统计项
  Widget _buildDayStat(String label, String value, Color color) {
    final colors = AppColors.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 8,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: TextStyle(
            color: colors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  /// 构建添加记录表单  /// 构建添加记录表单
  Widget _buildAddForm() {
    final colors = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '添加每日记录',
            style: AppText.h3.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),

          // 日期输入
          TextField(
            controller: _dateCtrl,
            decoration: InputDecoration(
              labelText: '日期 (YYYY-MM-DD)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 股票表单列表
          ..._stockForms.asMap().entries.map((entry) {
            final index = entry.key;
            final form = entry.value;
            return _buildStockForm(index, form);
          }).toList(),

          const SizedBox(height: 12),

          // 添加股票按钮
          if (_stockForms.length < 6)
            ElevatedButton.icon(
              onPressed: _addStockForm,
              icon: const Icon(Icons.add),
              label: const Text('添加股票'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
              ),
            ),

          const SizedBox(height: 16),

          // 保存按钮
          ElevatedButton(
            onPressed: _saveRecord,
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('保存记录'),
          ),
        ],
      ),
    );
  }

  /// 构建单只股票表单
  Widget _buildStockForm(int index, StockFormData form) {
    final colors = AppColors.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '股票 ${index + 1}',
                style: AppText.body1.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_stockForms.length > 1)
                IconButton(
                  onPressed: () => _removeStockForm(index),
                  icon: const Icon(Icons.delete, color: Colors.red),
                  iconSize: 20,
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: form.nameCtrl,
            decoration: InputDecoration(
              labelText: '股票名称',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: form.codeCtrl,
            decoration: InputDecoration(
              labelText: '股票代码',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: form.startPriceCtrl,
                  decoration: InputDecoration(
                    labelText: '起始价 (T日20:00)',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: form.settlementPriceCtrl,
                  decoration: InputDecoration(
                    labelText: '结算价 (T+1日15:05)',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 股票表单数据
class StockFormData {
  final nameCtrl = TextEditingController();
  final codeCtrl = TextEditingController();
  final startPriceCtrl = TextEditingController();
  final settlementPriceCtrl = TextEditingController();

  void dispose() {
    nameCtrl.dispose();
    codeCtrl.dispose();
    startPriceCtrl.dispose();
    settlementPriceCtrl.dispose();
  }
}
