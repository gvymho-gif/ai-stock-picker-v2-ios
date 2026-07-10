/// 横屏布局 - 严格按照App内对应模块样式复制
/// 左侧15%(指数) | 中间40%(核心统计+明细表) | 右侧45%(趋势图+柱状图)
/// 所有内容按比例缩小，信息与竖屏完全一致

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_theme.dart';
import '../theme/app_text.dart';
import '../services/expert_performance_service.dart';
import '../services/trading_day_cloud_service.dart';
import '../services/local_data_service.dart';
import '../services/foreign_holder_service.dart';
import '../services/background_service.dart';
import '../models/trading_day_record.dart';
import '../utils/trading_day_utils.dart';
import 'landscape_index_panel.dart';

class LandscapePerformanceGrid extends StatefulWidget {
  const LandscapePerformanceGrid({Key? key}) : super(key: key);

  @override
  State<LandscapePerformanceGrid> createState() => _LandscapePerformanceGridState();
}

class _LandscapePerformanceGridState extends State<LandscapePerformanceGrid> with TickerProviderStateMixin {
  List<DailyExpertPerformance> _history = [];
  List<TradingDayRecord> _tradingRecords = [];
  bool _loading = true;
  Map<String, double> _liveChangePercents = {};
  // 沪深300日涨跌幅缓存：Map<日期YYYY-MM-DD, 涨跌幅%>
  Map<String, double> _hs300DailyChanges = {};
  // 中证1000日涨跌幅缓存：Map<日期YYYY-MM-DD, 涨跌幅%>
  Map<String, double> _zz1000DailyChanges = {};
  int _trendTimeRange = 1;
  int _barTimeRange = 1;
  DateTime? _trendCustomStart;
  DateTime? _trendCustomEnd;
  DateTime? _barCustomStart;
  DateTime? _barCustomEnd;
  Timer? _refreshTimer;
  StreamSubscription<Map<String, dynamic>?>? _bgSub; // 后台数据变更监听
  double _northNetFlow = 0.0;  // 北向资金净流入（亿元）
  double _southNetFlow = 0.0;  // 南向资金净流入（亿元）
  bool _northAvailable = false;  // 北向数据是否可用
  double _northTotalAmount = 0.0;  // 北向当日成交总额（亿元）
  bool _northIsTotal = false;  // 北向显示的是成交总额
  Timer? _capitalFlowTimer;

  // 南向资金箭头拖尾动画 — 墙钟时间驱动，无缝循环
  late final Ticker _arrowTicker;
  final ValueNotifier<double> _arrowPhase = ValueNotifier(0.0);
  static const _arrowCycleMs = 4800.0;  // 4.8s呼吸周期（降速50%）

  // 图表全屏切换：0=正常, 1=趋势图全屏, 2=柱状图全屏
  int _fullScreenChart = 0;

  // 全屏过渡动画
  late final AnimationController _fsAnimController;
  late final Animation<double> _fsScaleAnim;
  late final Animation<double> _fsFadeAnim;
  late final Animation<Offset> _fsSlideAnim;
  // 记录进入全屏前的图表位置，用于 Hero 式过渡
  Rect? _chartOriginRect;
  // 全屏下滑退出 — 原始指针追踪（绕过手势竞技场）
  double? _fsPointerDownY;
  DateTime? _fsPointerDownTime;
  // 趋势图点击提示状态
  Offset? _trendPointerDownPos;
  OverlayEntry? _trendOverlayEntry;

  // 按比例缩小，基准0.78
  static const double _scale = 0.78;
  double _s(double v) => v * _scale;
  double _fs(double v) => v * _scale;

  @override
  void initState() {
    super.initState();
    _arrowTicker = createTicker((_) {
      _arrowPhase.value = (DateTime.now().millisecondsSinceEpoch % _arrowCycleMs.toInt()) / _arrowCycleMs;
    })..start();

    // 全屏过渡动画：弹出 + 弹回 (elasticOut), 淡入淡出 + 上滑
    _fsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _fsScaleAnim = CurvedAnimation(parent: _fsAnimController, curve: Curves.elasticOut);
    _fsFadeAnim = CurvedAnimation(parent: _fsAnimController, curve: Interval(0, 0.55, curve: Curves.easeOut));
    _fsSlideAnim = Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(
      CurvedAnimation(parent: _fsAnimController, curve: Interval(0, 0.7, curve: Curves.easeOutQuad)),
    );

    _loadData();

    // ★ 监听后台服务数据变更通知
    _bgSub = BackgroundStockService().onDataChanged().listen((data) {
      if (data != null && mounted) {
        final module = data['module']?.toString() ?? '';
        if (module == 'expert_performance' || module.isEmpty) {
          _loadData();
        }
      }
    });
  }

  @override
  void dispose() {
    _fsAnimController.dispose();
    _refreshTimer?.cancel();
    _capitalFlowTimer?.cancel();
    _bgSub?.cancel();
    _arrowTicker.dispose();
    _arrowPhase.dispose();
    super.dispose();
  }

  bool _isHKTrading() {
    final now = DateTime.now();
    if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) return false;
    final min = now.hour * 60 + now.minute;
    return (min >= 570 && min < 720) || (min >= 780 && min < 960);
  }

  Future<void> _loadData() async {
    try {
      final history = await ExpertPerformanceService.getHistory();
      final tradingRecords = await TradingDayCloudService.getLocalRecords();
      // 获取沪深300数据（覆盖从最早记录日期到明天）
      Map<String, double> hs300Data = {};
      Map<String, double> zz1000Data = {};
      if (history.isNotEmpty) {
        try {
          hs300Data = await ExpertPerformanceService.fetchHS300DailyChanges();
          debugPrint('[横屏收益] 沪深300数据: ${hs300Data.length}条');
        } catch (e) {
          debugPrint('[横屏收益] 沪深300数据获取失败: $e');
        }
        try {
          zz1000Data = await ExpertPerformanceService.fetchZZ1000DailyChanges();
          debugPrint('[横屏收益] 中证1000数据: ${zz1000Data.length}条');
        } catch (e) {
          debugPrint('[横屏收益] 中证1000数据获取失败: $e');
        }
      }
      if (mounted) {
        // ★ 过滤非交易日数据（周末+节假日），与竖屏保持一致
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
        });
      }
      _startLiveRefresh();
      _fetchCapitalFlow();
      _startCapitalFlowRefresh();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startLiveRefresh() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refreshLivePrices());
  }

  Future<void> _fetchCapitalFlow() async {
    try {
      final data = await ForeignHolderService.fetchNorthSouthFlow();
      if (mounted) {
        setState(() {
          _northNetFlow = data['north_net'] ?? 0.0;
          _southNetFlow = data['south_net'] ?? 0.0;
          _northAvailable = data['north_available'] ?? false;
          _northTotalAmount = data['north_total_amount'] ?? 0.0;
          _northIsTotal = data['north_is_total'] ?? false;
        });
      }
    } catch (e) {
      print('南北向资金获取失败: $e');
    }
  }

  void _startCapitalFlowRefresh() {
    _capitalFlowTimer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchCapitalFlow());
  }

  Future<void> _refreshLivePrices() async {
    if (_history.isEmpty) return;
    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();
    String displayDate = now.hour >= 20 ? today : _getYesterdayString();
    var activeRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    if (activeRecord.stocks.isEmpty && _history.isNotEmpty) activeRecord = _history.first;
    if (activeRecord.stocks.isEmpty) return;

    final api = LocalDataService();
    bool anyUpdated = false;
    for (var stock in activeRecord.stocks) {
      try {
        final stockData = await api.searchStock(stock.code);
        if (stockData.isNotEmpty) {
          final changePct = _safeDouble(stockData['change_pct']);
          if (changePct != 0) {
            _liveChangePercents[stock.code] = changePct;
            stock.changePercent = changePct;
            anyUpdated = true;
          }
        }
      } catch (_) {}
    }
    if (anyUpdated && mounted) setState(() {});
  }

  double _safeDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  String _getYesterdayString() {
    // ★ 修复：返回上一个交易日（跳过周末+节假日），而不是简单的昨天
    var yesterday = DateTime.now().subtract(const Duration(days: 1));
    while (TradingDayUtils.isNonTradingDayStr(
      '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}',
    )) {
      yesterday = yesterday.subtract(const Duration(days: 1));
    }
    return '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    // 全屏图表模式
    if (_fullScreenChart > 0) {
      return _buildFullScreenChart();
    }

    return Row(
      children: [
        // 左侧15%：指数滚动面板
        Expanded(flex: 15, child: const LandscapeIndexPanel()),
        // 中间40%：核心统计+明细表+南北向资金
        Expanded(
          flex: 40,
          child: Padding(
            padding: EdgeInsets.all(_s(4)),
            child: Column(
              children: [
                // 核心统计指标 - 30%
                Expanded(flex: 30, child: _buildCoreStats()),
                SizedBox(height: _s(4)),
                // 每日明细表 - 50%
                Expanded(flex: 50, child: _buildDailyDetailTable()),
                SizedBox(height: _s(4)),
                // 南北向资金流向 - 20%
                Expanded(flex: 20, child: _buildCapitalFlow()),
              ],
            ),
          ),
        ),
        // 右侧45%：趋势图+柱状图（支持点击全屏）
        Expanded(
          flex: 45,
          child: Padding(
            padding: EdgeInsets.all(_s(4)),
            child: Column(
              children: [
                // 累计收益趋势 — 点击全屏（带动画）
                Expanded(
                  flex: 1,
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _fullScreenChart = 1);
                      _fsAnimController.forward(from: 0);
                    },
                    child: _buildTrendChart(),
                  ),
                ),
                SizedBox(height: _s(4)),
                // 单日平均涨跌 — 点击全屏（带动画）
                Expanded(
                  flex: 1,
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _fullScreenChart = 2);
                      _fsAnimController.forward(from: 0);
                    },
                    child: _buildDailyBarChart(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 全屏图表模式 — 带缩放+淡入+微上滑进场动画
  Widget _buildFullScreenChart() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 退出全屏：先反向播放动画，动画结束后切换状态
    void exitFullScreen() {
      _fsAnimController.reverse().then((_) {
        if (mounted) setState(() => _fullScreenChart = 0);
      });
    }

    return AnimatedBuilder(
      animation: _fsAnimController,
      builder: (context, child) {
        final scale = 0.70 + 0.30 * _fsScaleAnim.value;   // 0.70 → 1.0, elasticOut 会冲到 1.0+ 再弹回
        final opacity = _fsFadeAnim.value;                  // 0.0 → 1.0
        final slide = _fsSlideAnim.value;                   // 微上滑

        return Transform.translate(
          offset: Offset(0, slide.dy * 30),
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity,
              child: child,
            ),
          ),
        );
      },
      child: Listener(
        // 用 Listener 替代 GestureDetector，绕过手势竞技场
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _fsPointerDownY = event.position.dy;
          _fsPointerDownTime = DateTime.now();
        },
        onPointerUp: (event) {
          if (_fsPointerDownY != null && _fsPointerDownTime != null) {
            final dy = event.position.dy - _fsPointerDownY!;
            final dt = DateTime.now().difference(_fsPointerDownTime!).inMilliseconds;
            if (dy > 80 && dt < 500) {
              exitFullScreen();
            }
          }
        },
        child: Container(
          color: isDark ? const Color(0xFF0B1424) : const Color(0xFFF5F5F7),
          padding: EdgeInsets.all(_s(8)),
          child: _fullScreenChart == 1
              ? _buildFullScreenTrendChartContent()
              : _buildFullScreenBarChartContent(),
        ),
      ),
    );
  }

  /// 移除趋势图点击提示浮层
  void _removeTrendTooltip() {
    _trendOverlayEntry?.remove();
    _trendOverlayEntry = null;
  }

  /// 点击趋势图数据点，用 Overlay 显示提示
  void _showTrendTooltip(
    BuildContext chartCtx,
    PointerUpEvent event,
    List<FlSpot> spots,
    List<String> dateLabels,
    List<double> dailyChanges,
    bool isDark, {
    List<FlSpot> hs300Spots = const [],
    List<FlSpot> zz1000Spots = const [],
  }) {
    _removeTrendTooltip();
    if (spots.isEmpty) return;

    final box = chartCtx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final localPos = box.globalToLocal(event.position);
    final ratio = (localPos.dx / box.size.width).clamp(0.0, 1.0);
    final idx = (ratio * (spots.length - 1)).round().clamp(0, spots.length - 1);

    final spot = spots[idx];
    final isUp = idx < dailyChanges.length && dailyChanges[idx] >= 0;
    String tooltipText = '${dateLabels[idx]}\n专家: ${spot.y >= 0 ? '+' : ''}${spot.y.toStringAsFixed(2)}%';
    if (idx < hs300Spots.length) {
      final hsVal = hs300Spots[idx].y;
      tooltipText += '\n沪深300: ${hsVal >= 0 ? '+' : ''}${hsVal.toStringAsFixed(2)}%';
    }
    if (idx < zz1000Spots.length) {
      final zzVal = zz1000Spots[idx].y;
      tooltipText += '\n中证1000: ${zzVal >= 0 ? '+' : ''}${zzVal.toStringAsFixed(2)}%';
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _removeTrendTooltip,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
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

  // ===== 全屏趋势图：Y轴固定 + 横向滚动（无 Expanded 嵌套，靠显式宽度） =====
  Widget _buildFullScreenTrendChartContent() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_history.isEmpty) return const Center(child: Text('暂无数据'));

    // ——— 数据准备（与 _buildTrendChart 一致）———
    final tradingRecordMap = <String, double>{};
    for (var tr in _tradingRecords) {
      // ★ 尚未到下一个交易日确认时间的记录按0计算
      tradingRecordMap[tr.date] = TradingDayUtils.shouldRecordShowZero(tr.date)
          ? 0.0
          : tr.avgChangePercent;
    }

    var sorted = [..._history]..sort((a, b) => a.date.compareTo(b.date));
    if (_trendTimeRange == 3 && _trendCustomStart != null && _trendCustomEnd != null) {
      sorted = _filterByDateRange(sorted, _trendCustomStart!, _trendCustomEnd!);
    } else if (_trendTimeRange != 4) {
      final daysMap = {0: 7, 1: 30, 2: 90};
      if (sorted.length > daysMap[_trendTimeRange]!) {
        sorted = sorted.sublist(sorted.length - daysMap[_trendTimeRange]!);
      }
    }

    final spots = <FlSpot>[];
    final dateLabels = <String>[];
    final dailyChanges = <double>[];
    double simpleCumulative = 0.0;
    for (int i = 0; i < sorted.length; i++) {
      final dc = tradingRecordMap[sorted[i].date] ?? sorted[i].dailyAvgChange;
      dailyChanges.add(dc);
      simpleCumulative += dc;
      spots.add(FlSpot(i.toDouble(), simpleCumulative));
      dateLabels.add(sorted[i].date.substring(5));
    }

    // 沪深300 T+1日涨跌幅数据 + Y轴范围（起始日2026-04-20）
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
    // ★ 中证1000 T+1日涨跌幅数据（与沪深300逻辑一致，橙色折线）
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
    double chartYMin, chartYMax, niceInterval;
    int tickCount;
    {
      final allYValues = [...spots.map((s) => s.y), ...hs300Spots.map((s) => s.y), ...zz1000Spots.map((s) => s.y)];
      chartYMin = allYValues.isEmpty ? -1.0 : (allYValues.reduce(math.min) - 1).floorToDouble();
      chartYMax = allYValues.isEmpty ? 1.0 : (allYValues.reduce(math.max) + 1).ceilToDouble();
      if (chartYMin > -5) chartYMin = -5;
      if (chartYMax < 5) chartYMax = 5;
      niceInterval = math.max((chartYMax - chartYMin) / 5, 1);
      tickCount = ((chartYMax - chartYMin) / niceInterval).ceil() + 1;
    }
    const zeroY = 0.0;

    final labelColor = isDark ? const Color(0xFF8890A8) : const Color(0xFF8E8E93);
    final zeroLineColor = isDark ? const Color(0xFF2D3148) : const Color(0xFFE5E5EA);
    final gridColor = isDark ? const Color(0xFF232740) : const Color(0xFFEFF0F5);

    final currentReturn = spots.isNotEmpty ? spots.last.y : 0.0;
    const double initialCapital = 100000.0;
    final totalProfitAmount = initialCapital * (currentReturn / 100);
    // ★ 较上周：取7天前数据点（若无则取最早点）
    final prevIdx = spots.length > 7 ? spots.length - 8 : 0;
    final prevReturn = spots[prevIdx].y;
    final periodChange = currentReturn - prevReturn;
    // 沪深300当前收益率和周期变化
    final hs300CurrentReturn = hs300Spots.isNotEmpty ? hs300Spots.last.y : 0.0;
    final hs300PrevReturn = hs300Spots.length > 1 ? hs300Spots[hs300Spots.length - 2].y : hs300CurrentReturn;
    final hs300PeriodChange = hs300CurrentReturn - hs300PrevReturn;
    // 中证1000当前收益率
    final zz1000CurrentReturn = zz1000Spots.isNotEmpty ? zz1000Spots.last.y : 0.0;

    double maxDrawdownPercent = 0.0;
    double peakCumulative = 0.0;
    double running = 0.0;
    for (final dc in dailyChanges) {
      running += dc;
      if (running > peakCumulative) peakCumulative = running;
      final drawdownPct = peakCumulative - running;
      if (drawdownPct > maxDrawdownPercent) maxDrawdownPercent = drawdownPct;
    }

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

    // ——— 全屏布局：标题 + 筛选 + 图表 + 底部统计 ———
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题栏
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.trending_up, color: Color(0xFF3B82F6), size: 18),
            ),
            const SizedBox(width: 8),
            Text('累计收益趋势',
                style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
            const Spacer(),
            // 左右数据列：IntrinsicHeight + stretch 保证等高，仅底部对齐
            IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 蓝色+橙色：沪深300/中证1000底部紧凑对齐
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
                      Text('${currentReturn >= 0 ? '+' : ''}${currentReturn.toStringAsFixed(2)}%',
                          style: TextStyle(
                              color: currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                              fontWeight: FontWeight.w800, fontSize: 20)),
                      Text('较上周 ${periodChange >= 0 ? '+' : ''}${periodChange.toStringAsFixed(2)}%',
                          style: TextStyle(color: colors.textSecondary, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // 时间筛选
        _buildTrendTimeFilterTabs(tabScale: 2.0),
        const SizedBox(height: 6),
        // 图表区（占满剩余高度）
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final perPointW = 24.0;
              final chartW = math.max(spots.length * perPointW, constraints.maxWidth);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Y轴 — 固定不动
                  SizedBox(
                    width: 48,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(tickCount, (i) {
                        final value = chartYMax - (i * niceInterval);
                        final isZero = (value - zeroY).abs() < 0.01;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}%',
                            style: TextStyle(
                              color: isZero
                                  ? (isDark ? const Color(0xFFC0C8D8) : const Color(0xFF555555))
                                  : labelColor,
                              fontSize: 13,
                              fontWeight: isZero ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 图表区 — 横向滚动（带点击提示）
                  Builder(
                    builder: (chartCtx) {
                      return Expanded(
                        child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (event) => _trendPointerDownPos = event.position,
                          onPointerUp: (event) {
                            if (_trendPointerDownPos != null &&
                                (event.position - _trendPointerDownPos!).distance < 15) {
                              _showTrendTooltip(chartCtx, event, spots, dateLabels, dailyChanges, isDark,
                                hs300Spots: hs300Spots, zz1000Spots: zz1000Spots);
                            }
                            _trendPointerDownPos = null;
                          },
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            child: SizedBox(
                              width: chartW,
                              height: constraints.maxHeight,
                              child: LineChart(
                          LineChartData(
                            minX: 0,
                            maxX: math.max(0, (spots.length - 1).toDouble()),
                            titlesData: FlTitlesData(
                              leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true, interval: 1, reservedSize: 22,
                                  getTitlesWidget: (value, meta) {
                                    final idx = value.toInt();
                                    if (idx < 0 || idx >= dateLabels.length) return const SizedBox();
                                    final step = spots.length > 20 ? 3 : (spots.length > 10 ? 2 : 1);
                                    if (idx % step != 0) return const SizedBox();
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(dateLabels[idx],
                                          style: TextStyle(color: labelColor, fontSize: 13)),
                                    );
                                  },
                                ),
                              ),
                            ),
                            gridData: FlGridData(
                              show: true, drawVerticalLine: false, horizontalInterval: niceInterval,
                              getDrawingHorizontalLine: (value) => FlLine(
                                color: (value - zeroY).abs() < 0.01 ? zeroLineColor : gridColor,
                                strokeWidth: (value - zeroY).abs() < 0.01 ? 1.0 : 0.5,
                                dashArray: [4, 4],
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            minY: chartYMin, maxY: chartYMax,
                            lineBarsData: [
                              ..._buildSegmentedLineBars(spots, dailyChanges),
                              if (hs300Spots.length >= 2)
                                LineChartBarData(
                                  spots: hs300Spots,
                                  isCurved: false,
                                  gradient: LinearGradient(colors: [ const Color(0xFF3B82F6),  const Color(0xFF3B82F6)]),
                                  barWidth: 2.0,
                                  dotData: FlDotData(
                                    show: true,
                                    getDotPainter: (spot, percent, barData, index) =>
                                        FlDotCirclePainter(radius: 2.0, gradient: LinearGradient(colors: [ const Color(0xFF3B82F6),  const Color(0xFF3B82F6)]), strokeWidth: 0),
                                  ),
                                  belowBarData: BarAreaData(show: false),
                                ),
                              if (zz1000Spots.length >= 2)
                                LineChartBarData(
                                  spots: zz1000Spots,
                                  isCurved: false,
                                  gradient: LinearGradient(colors: [ const Color(0xFFFF8C00),  const Color(0xFFFF8C00)]),
                                  barWidth: 2.0,
                                  dotData: FlDotData(
                                    show: true,
                                    getDotPainter: (spot, percent, barData, index) =>
                                        FlDotCirclePainter(radius: 2.0, gradient: LinearGradient(colors: [ const Color(0xFFFF8C00),  const Color(0xFFFF8C00)]), strokeWidth: 0),
                                  ),
                                  belowBarData: BarAreaData(show: false),
                                ),
                            ],
                            lineTouchData: LineTouchData(enabled: false),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                },
              ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        // 底部统计
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF151928) : const Color(0xFFF5F6FA),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              _buildTrendStatItem(Icons.trending_up_rounded, const Color(0xFF3B82F6), '当前收益率',
                  '${currentReturn >= 0 ? '+' : ''}${currentReturn.toStringAsFixed(2)}%',
                  currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                  labelFontSize: 11, valueFontSize: 14),
              _buildTrendStatItem(Icons.balance_rounded, const Color(0xFF8B5CF6), '总盈亏比',
                  winLossRatio > 0
                      ? '${currentReturn >= 0 ? '+' : '-'}${winLossRatio.toStringAsFixed(2)}'
                      : '--',
                  currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                  labelFontSize: 11, valueFontSize: 14),
              _buildTrendStatItem(Icons.speed_rounded, const Color(0xFFF59E0B), '日收益波动率',
                  '${volatility.toStringAsFixed(2)}%', const Color(0xFFF59E0B),
                  labelFontSize: 11, valueFontSize: 14),
              _buildTrendStatItem(Icons.trending_down_rounded, const Color(0xFF10B981), '最大回撤',
                  '-${maxDrawdownPercent.toStringAsFixed(2)}%', const Color(0xFF10B981),
                  labelFontSize: 11, valueFontSize: 14),
            ],
          ),
        ),
      ],
    );
  }

  // ===== 全屏柱状图：Y轴固定 + 横向滚动（无 Expanded 嵌套，靠显式宽度） =====
  Widget _buildFullScreenBarChartContent() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_history.isEmpty) return const Center(child: Text('暂无数据'));

    // ——— 数据准备（与 _buildDailyBarChart 一致）———
    var recent = [..._history]..sort((a, b) => a.date.compareTo(b.date));
    if (_barTimeRange == 3 && _barCustomStart != null && _barCustomEnd != null) {
      recent = _filterByDateRange(recent, _barCustomStart!, _barCustomEnd!);
    } else if (_barTimeRange != 4) {
      final daysMap = {0: 7, 1: 30, 2: 90};
      if (recent.length > daysMap[_barTimeRange]!) {
        recent = recent.sublist(recent.length - daysMap[_barTimeRange]!);
      }
    }

    final tradingRecordMap = <String, double>{};
    for (var tr in _tradingRecords) {
      // ★ 尚未到下一个交易日确认时间的记录按0计算
      tradingRecordMap[tr.date] = TradingDayUtils.shouldRecordShowZero(tr.date)
          ? 0.0
          : tr.avgChangePercent;
    }

    final dateLabels = <String>[];
    final barGroups = <BarChartGroupData>[];
    int upDays = 0, downDays = 0, flatDays = 0;
    for (int i = 0; i < recent.length; i++) {
      final record = recent[i];
      final avgChange = tradingRecordMap[record.date] ?? record.dailyAvgChange;
      final isUp = avgChange > 0;
      final isDown = avgChange < 0;
      if (isUp) upDays++; else if (isDown) downDays++; else flatDays++;
      dateLabels.add(record.date.substring(5));
      barGroups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            y: avgChange,
            color: isUp ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
            width: recent.length > 15 ? 10 : 14,
            borderRadius: isUp
                ? const BorderRadius.only(topLeft: Radius.circular(4), topRight: Radius.circular(4))
                : const BorderRadius.only(bottomLeft: Radius.circular(4), bottomRight: Radius.circular(4)),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: isUp
                  ? [const Color(0xFFFCA5A5), const Color(0xFFEF4444)]
                  : [const Color(0xFF86EFAC), const Color(0xFF22C55E)],
            ),
          ),
        ],
      ));
    }

    final allValues = recent.map((r) => tradingRecordMap[r.date] ?? r.dailyAvgChange).toList();
    double chartBarYMin, chartBarYMax, niceBarInterval;
    int barTickCount;
    {
      chartBarYMin = allValues.isEmpty ? -1.0 : (allValues.reduce(math.min) - 0.5).floorToDouble();
      chartBarYMax = allValues.isEmpty ? 1.0 : (allValues.reduce(math.max) + 0.5).ceilToDouble();
      niceBarInterval = math.max((chartBarYMax - chartBarYMin) / 5, 1);
      barTickCount = ((chartBarYMax - chartBarYMin) / niceBarInterval).ceil() + 1;
    }

    final labelColor = isDark ? const Color(0xFF8890A8) : const Color(0xFF8E8E93);
    final zeroLineColor = isDark ? const Color(0xFF2D3148) : const Color(0xFFE5E5EA);
    final gridColor = isDark ? const Color(0xFF232740) : const Color(0xFFEFF0F5);

    // ——— 全屏布局：标题 + 筛选 + 图表 ———
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题栏
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.bar_chart, color: Color(0xFFF59E0B), size: 18),
            ),
            const SizedBox(width: 8),
            Text('单日平均涨跌',
                style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 6),
        // 时间筛选
        _buildBarTimeFilterTabs(tabScale: 2.0),
        const SizedBox(height: 6),
        // 图表区（占满剩余高度）
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final perBarW = 28.0;
              final chartW = math.max(barGroups.length * perBarW, constraints.maxWidth);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Y轴 — 固定不动
                  SizedBox(
                    width: 52,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(barTickCount, (i) {
                        final value = chartBarYMax - (i * niceBarInterval);
                        final isZero = value.abs() < 0.01;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '${value >= 0 ? '+' : ''}${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}%',
                            style: TextStyle(
                              color: isZero
                                  ? (isDark ? const Color(0xFFC0C8D8) : const Color(0xFF555555))
                                  : labelColor,
                              fontSize: 13,
                              fontWeight: isZero ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 图表区 — 横向滚动
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: SizedBox(
                        width: chartW,
                        height: constraints.maxHeight,
                        child: BarChart(
                          BarChartData(
                            alignment: BarChartAlignment.spaceBetween,
                            gridData: FlGridData(
                              show: true, drawVerticalLine: false, horizontalInterval: niceBarInterval,
                              getDrawingHorizontalLine: (value) => FlLine(
                                color: value.abs() < 0.01 ? zeroLineColor : gridColor,
                                strokeWidth: value.abs() < 0.01 ? 1.0 : 0.5,
                                dashArray: value.abs() < 0.01 ? null : [4, 4],
                              ),
                            ),
                            titlesData: FlTitlesData(
                              leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true, interval: 1,
                                  getTitlesWidget: (value, meta) {
                                    final idx = value.toInt();
                                    if (idx < 0 || idx >= dateLabels.length) return const SizedBox();
                                    final step = barGroups.length > 15 ? 3 : (barGroups.length > 7 ? 2 : 1);
                                    if (idx % step != 0) return const SizedBox();
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(dateLabels[idx],
                                          style: TextStyle(color: labelColor, fontSize: 13)),
                                    );
                                  },
                                ),
                              ),
                              topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            ),
                            borderData: FlBorderData(show: false),
                            minY: chartBarYMin, maxY: chartBarYMax,
                            barGroups: barGroups,
                            barTouchData: BarTouchData(
                              touchTooltipData: BarTouchTooltipData(
                                tooltipBgColor: isDark ? const Color(0xFF1E2240) : const Color(0xFF333333),
                                tooltipRoundedRadius: 6, fitInsideHorizontally: true, fitInsideVertically: true,
                                tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                  final val = rod.toY;
                                  return BarTooltipItem(
                                    '${dateLabels[group.x]}\n${val >= 0 ? '+' : ''}${val.toStringAsFixed(2)}%',
                                    TextStyle(color: val >= 0 ? const Color(0xFFFF8A8A) : const Color(0xFF6FDFD6),
                                        fontWeight: FontWeight.w600, fontSize: 12, height: 1.3),
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
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        // 底部统计 — 上涨/下跌/平盘天数
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF151928) : const Color(0xFFF5F6FA),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(child: _buildDayStat('上涨天数', upDays.toString(), const Color(0xFFEF4444))),
              Container(width: 1, height: 16, color: colors.border),
              Expanded(child: _buildDayStat('下跌天数', downDays.toString(), const Color(0xFF22C55E))),
              Container(width: 1, height: 16, color: colors.border),
              Expanded(child: _buildDayStat('平盘天数', flatDays.toString(), Colors.grey)),
            ],
          ),
        ),
      ],
    );
  }

  // ========== 核心统计指标 - 复制竖屏样式按比例缩小 ==========
  Widget _buildCoreStats() {
    final colors = AppColors.of(context);
    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();

    double avgReturn = 0.0;
    if (_tradingRecords.isNotEmpty) {
      final stats = TradingStatistics.fromRecords(_tradingRecords);
      avgReturn = stats.dailyAvgReturn;
    }

    String displayDate = now.hour >= 20 ? today : _getYesterdayString();
    if (!_history.any((r) => r.date == displayDate)) {
      if (_history.isNotEmpty) displayDate = _history.first.date;
    }
    var activeRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    if (activeRecord.stocks.isEmpty && _history.isNotEmpty) activeRecord = _history.first;

    int? profitUpCount;
    int? profitDownCount;
    String profitText = '--';
    String dailyChange = '--';
    Color dailyChangeColor = Colors.red;

    if (activeRecord.stocks.isNotEmpty) {
      final timeInMinutes = now.hour * 60 + now.minute;
      // ★ 非交易日 → 0.00%
      final isNonTradingDay = !TradingDayUtils.isSecuritiesTradingDay(now);
      // ★ 非交易时段：15:05~09:30（即 < 09:30 或 > 15:05）
      final isNonTradingHours = timeInMinutes < (9 * 60 + 30) || timeInMinutes > (15 * 60 + 5);

      if (isNonTradingDay || (isNonTradingHours && !activeRecord.isSettled)) {
        profitUpCount = 0;
        profitDownCount = 0;
        profitText = '0.00%';
        dailyChange = '0.00%';
        dailyChangeColor = colors.textSecondary;
      } else {
        int upCount = 0, downCount = 0;
        double totalChange = 0;
        for (var stock in activeRecord.stocks) {
          final liveChange = _liveChangePercents[stock.code];
          final change = liveChange ?? stock.changePercent;
          if (change != 0 || activeRecord.isSettled) {
            totalChange += change;
            if (change > 0) upCount++;
            else if (change < 0) downCount++;
          }
        }
        profitUpCount = upCount;
        profitDownCount = downCount;
        dailyChange = '${totalChange >= 0 ? '+' : ''}${totalChange.toStringAsFixed(2)}%';
        dailyChangeColor = totalChange >= 0 ? Colors.red : Colors.green;
      }
    }

    // 复制竖屏容器样式，尺寸按比例缩小
    return Container(
      padding: EdgeInsets.fromLTRB(_s(8), _s(6), _s(8), _s(4)),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        // 无边框设计：用微弱阴影替代硬边框
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 1))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '核心统计指标',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: _fs(16),
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          SizedBox(height: _s(3)),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                // 盈亏分布
                _buildStatColumn(
                  icon: Icons.trending_up,
                  iconColor: colors.primary,
                  iconSize: _s(24),
                  label: '盈亏分布',
                  child: profitUpCount != null
                      ? RichText(
                          text: TextSpan(
                            style: TextStyle(fontSize: _fs(16), fontWeight: FontWeight.w800, height: 1.2),
                            children: [
                              TextSpan(text: '$profitUpCount涨', style: const TextStyle(color: Colors.red)),
                              TextSpan(text: ':', style: TextStyle(color: colors.textSecondary)),
                              TextSpan(text: '$profitDownCount跌', style: const TextStyle(color: Colors.green)),
                            ],
                          ),
                        )
                      : Text(profitText, style: TextStyle(color: colors.textSecondary, fontSize: _fs(16), fontWeight: FontWeight.w800)),
                ),
                // 当日总涨幅
                _buildStatColumn(
                  icon: Icons.percent,
                  iconColor: dailyChangeColor,
                  iconSize: _s(24),
                  label: '当日总涨幅',
                  child: Text(dailyChange, style: TextStyle(color: dailyChangeColor, fontSize: _fs(16), fontWeight: FontWeight.w800)),
                ),
                // 日平均收益
                _buildStatColumn(
                  icon: Icons.assessment,
                  iconColor: avgReturn >= 0 ? Colors.red : Colors.green,
                  iconSize: _s(24),
                  label: '日平均收益',
                  child: Text(
                    '${avgReturn >= 0 ? '+' : ''}${avgReturn.toStringAsFixed(2)}%',
                    style: TextStyle(color: avgReturn >= 0 ? Colors.red : Colors.green, fontSize: _fs(16), fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatColumn({
    required IconData icon,
    required Color iconColor,
    required double iconSize,
    required String label,
    required Widget child,
  }) {
    final colors = AppColors.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: iconColor, size: iconSize),
        SizedBox(height: _s(3)),
        Text(label, style: TextStyle(color: colors.textSecondary, fontSize: _fs(11), fontWeight: FontWeight.w500, height: 1.2)),
        SizedBox(height: _s(2)),
        child,
      ],
    );
  }

  // ========== 南北向资金流向 - 风格与核心统计一致 ==========
  Widget _buildCapitalFlow() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 北向：方案3 - 使用成交总额替代净流入
    // 交易所2024年8月起停止盘中实时披露北向净流入，但成交总额(buySellAmt)仍有值
    // 显示"北向成交 XXX.X亿"
    final northAvailable = _northAvailable;
    // 北向成交总额：蓝色主题显示（非红绿涨跌色）
    final northText = northAvailable && _northTotalAmount > 0
        ? '成交 ${_northTotalAmount.toStringAsFixed(1)}亿'
        : '暂无数据';
    final northColor = northAvailable && _northTotalAmount > 0
        ? const Color(0xFF3B82F6)  // 蓝色表示成交额
        : colors.textSecondary;

    // 南向：正常显示
    final southUp = _southNetFlow > 0.05;
    final southDown = _southNetFlow < -0.05;
    final southText = '${southUp ? '+' : (southDown ? '-' : '')}${_southNetFlow.abs().toStringAsFixed(1)}亿';
    final southColor = southUp ? Colors.red : (southDown ? Colors.green : Colors.grey);
    final southArrow = southUp ? '▲' : (southDown ? '▼' : '');
    final southTrading = _isHKTrading();

    // 北向背景色 - 蓝色主题（成交额）
    Color northBgColor;
    if (!northAvailable || _northTotalAmount <= 0) {
      northBgColor = isDark ? Colors.white.withOpacity(0.03) : Colors.black.withOpacity(0.02);
    } else {
      northBgColor = const Color(0xFF3B82F6).withOpacity(isDark ? 0.08 : 0.06);
    }

    return Container(
      padding: EdgeInsets.fromLTRB(_s(8), _s(6), _s(8), _s(4)),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        // 无边框设计：用微弱阴影替代硬边框
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 1))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '南北向资金流向',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: _fs(16),
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          SizedBox(height: _s(3)),
          Expanded(
            child: Row(
              children: [
                // 北向资金
                Expanded(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: _s(6), vertical: _s(4)),
                    decoration: BoxDecoration(
                      color: northBgColor,
                      borderRadius: BorderRadius.circular(6),
                      // 无边框设计：北向卡片用背景色自然区分
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '北向',
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: _fs(11),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        SizedBox(height: _s(2)),
                        Text(
                          northText,
                          style: TextStyle(
                            color: northColor,
                            fontSize: northAvailable && _northTotalAmount > 0 ? _fs(17) : _fs(14),
                            fontWeight: northAvailable && _northTotalAmount > 0 ? FontWeight.w800 : FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: _s(6)),
                const SizedBox(width: 6),
                // 南向资金 — 快闪入慢闪出呼吸边框
                Expanded(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _arrowPhase,
                    builder: (context, phase, _) {
                      // 快闪入慢闪出: 前20%周期急升，后80%周期缓降
                      // 形如: ▁▅███▆▅▄▃▂▁ (锐起缓落)
                      double heartbeat;
                      if (phase < 0.2) {
                        // 快闪入：0→0.2 映射到 0→1
                        heartbeat = phase / 0.2;
                      } else {
                        // 慢闪出：0.2→1.0 指数衰减 1→0
                        final t = (phase - 0.2) / 0.8;
                        heartbeat = math.pow(1 - t, 2.5).toDouble();
                      }
                      final bgAlpha = 0.014 + heartbeat * 0.14;           // 0.014↔0.154
                      final effectiveTrading = southTrading && southArrow.isNotEmpty;

                      // 无边框设计：南向卡片用呼吸背景色替代边框
                      final bgColor = effectiveTrading
                          ? southColor.withOpacity(bgAlpha)
                          : southColor.withOpacity(isDark ? 0.06 : 0.04);

                      return Container(
                        padding: EdgeInsets.symmetric(horizontal: _s(6), vertical: _s(4)),
                        decoration: BoxDecoration(
                          color: bgColor,
                          borderRadius: BorderRadius.circular(6),
                          // 无边框设计：南向卡片用呼吸背景色替代边框
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '南向',
                              style: TextStyle(
                                color: colors.textSecondary,
                                fontSize: _fs(11),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            SizedBox(height: _s(2)),
                            Text(
                              southText,
                              style: TextStyle(
                                color: southColor,
                                fontSize: _fs(17),
                                fontWeight: FontWeight.w800,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ========== 累计收益趋势 - 与竖屏完全一致的数据逻辑 ==========
  Widget _buildTrendChart() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_history.isEmpty) return _buildEmptyCard('累计收益趋势');

    // ★ 与竖屏一致：建立交易日记录映射，优先使用交易日记录的数据
    final tradingRecordMap = <String, double>{};
    for (var tr in _tradingRecords) {
      // ★ 尚未到下一个交易日确认时间的记录按0计算
      tradingRecordMap[tr.date] = TradingDayUtils.shouldRecordShowZero(tr.date)
          ? 0.0
          : tr.avgChangePercent;
    }

    // ★ 与竖屏一致：按日期正序排列
    var sorted = [..._history]
      ..sort((a, b) => a.date.compareTo(b.date));

    // ★ 与竖屏一致：根据时间范围筛选数据
    if (_trendTimeRange == 3 && _trendCustomStart != null && _trendCustomEnd != null) {
      sorted = _filterByDateRange(sorted, _trendCustomStart!, _trendCustomEnd!);
    } else if (_trendTimeRange == 4) {
      // 全部数据：不过滤
    } else {
      final daysMap = {0: 7, 1: 30, 2: 90};
      if (sorted.length > daysMap[_trendTimeRange]!) {
        sorted = sorted.sublist(sorted.length - daysMap[_trendTimeRange]!);
      }
    }

    // ★ 与竖屏一致：简单累计平均（固定投资，每天独立计算）
    const double initialCapital = 100000.0;
    final spots = <FlSpot>[];
    final dateLabels = <String>[];
    final dailyChanges = <double>[];
    double simpleCumulative = 0.0;
    double maxDrawdownPercent = 0.0;
    double peakCumulative = 0.0;

    for (int i = 0; i < sorted.length; i++) {
      // ★ 与竖屏一致：优先使用交易日记录的 avgChangePercent
      final dailyChangePercent = tradingRecordMap[sorted[i].date] ?? sorted[i].dailyAvgChange;
      dailyChanges.add(dailyChangePercent);
      simpleCumulative += dailyChangePercent;

      // 最大回撤：基于累计值的回落幅度
      if (simpleCumulative > peakCumulative) peakCumulative = simpleCumulative;
      final drawdownPct = peakCumulative - simpleCumulative;
      if (drawdownPct > maxDrawdownPercent) maxDrawdownPercent = drawdownPct;

      spots.add(FlSpot(i.toDouble(), simpleCumulative));
      dateLabels.add(sorted[i].date.substring(5));
    }

    // ★ 沪深300 T+1日涨跌幅数据 + Y轴范围（起始日2026-04-20）
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
    // ★ 中证1000 T+1日涨跌幅数据（与沪深300逻辑一致，橙色折线）
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
    double chartYMin, chartYMax, niceInterval;
    int tickCount;
    {
      final allYValues = [...spots.map((s) => s.y), ...hs300Spots.map((s) => s.y), ...zz1000Spots.map((s) => s.y)];
      chartYMin = allYValues.isEmpty ? -1.0 : (allYValues.reduce(math.min) - 1).floorToDouble();
      chartYMax = allYValues.isEmpty ? 1.0 : (allYValues.reduce(math.max) + 1).ceilToDouble();
      // 若范围太小，扩大至至少 ±5
      if (chartYMin > -5) chartYMin = -5;
      if (chartYMax < 5) chartYMax = 5;
      niceInterval = math.max((chartYMax - chartYMin) / 5, 1);
      tickCount = ((chartYMax - chartYMin) / niceInterval).ceil() + 1;
    }
    const zeroY = 0.0;

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
    // 中证1000当前收益率
    final zz1000CurrentReturn = zz1000Spots.isNotEmpty ? zz1000Spots.last.y : 0.0;

    // ★ 与竖屏一致：日收益波动率
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

    final labelColor = isDark ? const Color(0xFF8890A8) : const Color(0xFF8E8E93);
    final zeroLineColor = isDark ? const Color(0xFF2D3148) : const Color(0xFFE5E5EA);
    final gridColor = isDark ? const Color(0xFF232740) : const Color(0xFFEFF0F5);

    return Container(
      padding: EdgeInsets.fromLTRB(_s(3), _s(4), _s(3), _s(2)),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        // 无边框设计：保留微弱阴影营造悬浮感
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏 - 缩减
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(_s(4)),
                decoration: BoxDecoration(color: const Color(0xFF3B82F6).withOpacity(0.1), borderRadius: BorderRadius.circular(_s(6))),
                child: Icon(Icons.trending_up, color: const Color(0xFF3B82F6), size: _s(14)),
              ),
              SizedBox(width: _s(4)),
              Text('累计收益趋势',
                  style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700, fontSize: _fs(12), height: 1.2)),
              const Spacer(),
              // 左右数据列：IntrinsicHeight + stretch 保证等高，仅底部对齐
              IntrinsicHeight(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 蓝色+橙色：沪深300/中证1000底部紧凑对齐
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
                                Text('沪深300 ',
                                    style: TextStyle(color: const Color(0xFF3B82F6), fontWeight: FontWeight.w700, fontSize: _fs(10))),
                                Text('${hs300CurrentReturn >= 0 ? '+' : ''}${hs300CurrentReturn.toStringAsFixed(2)}%',
                                    style: TextStyle(
                                        color: hs300CurrentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                                        fontWeight: FontWeight.w800, fontSize: _fs(10))),
                              ],
                            ),
                          if (zz1000Spots.length >= 2)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('中证1000 ',
                                    style: TextStyle(color: const Color(0xFFFF8C00), fontWeight: FontWeight.w700, fontSize: _fs(10))),
                                Text('${zz1000CurrentReturn >= 0 ? '+' : ''}${zz1000CurrentReturn.toStringAsFixed(2)}%',
                                    style: TextStyle(
                                        color: zz1000CurrentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                                        fontWeight: FontWeight.w800, fontSize: _fs(10))),
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
                        Text('${currentReturn >= 0 ? '+' : ''}${currentReturn.toStringAsFixed(2)}%',
                            style: TextStyle(
                                color: currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                                fontWeight: FontWeight.w800, fontSize: _fs(16))),
                        Text('较上周 ${periodChange >= 0 ? '+' : ''}${periodChange.toStringAsFixed(2)}%',
                            style: TextStyle(color: colors.textSecondary, fontSize: _fs(9))),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: _s(2)),
          // 时间筛选
          _buildTrendTimeFilterTabs(),
          SizedBox(height: _s(2)),
          // 图表
          Expanded(
            child: Container(
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: isDark ? [const Color(0xFF0D1120), const Color(0xFF13182B)] : [const Color(0xFFF8F9FC), const Color(0xFFF0F1F5)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Y轴 - 刻度与LineChart精确对齐
                  SizedBox(
                    width: _s(38),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(tickCount, (i) {
                        final value = chartYMax - (i * niceInterval);
                        final isZero = (value - zeroY).abs() < 0.01;
                        return Padding(
                          padding: EdgeInsets.only(right: _s(6)),
                          child: Text('${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}%',
                              style: TextStyle(
                                color: isZero ? (isDark ? const Color(0xFFC0C8D8) : const Color(0xFF555555)) : labelColor,
                                fontSize: _fs(9), fontWeight: isZero ? FontWeight.w600 : FontWeight.w400,
                              )),
                        );
                      }),
                    ),
                  ),
                  SizedBox(width: _s(4)),
                  // 折线图 - 固定每点16px宽，确保不管数据量多少都同等间距（带点击提示）
                  Expanded(
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        const perPointWidth = 16.0;
                        final chartWidth = math.max(spots.length * perPointWidth, constraints.maxWidth + 1);
                        return Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (event) => _trendPointerDownPos = event.position,
                          onPointerUp: (event) {
                            if (_trendPointerDownPos != null &&
                                (event.position - _trendPointerDownPos!).distance < 15) {
                              _showTrendTooltip(ctx, event, spots, dateLabels, dailyChanges, isDark,
                                hs300Spots: hs300Spots, zz1000Spots: zz1000Spots);
                            }
                            _trendPointerDownPos = null;
                          },
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: chartWidth,
                              maxWidth: chartWidth,
                            ),
                            child: LineChart(LineChartData(
                          minX: 0,
                          maxX: math.max(0, (spots.length - 1).toDouble()),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true, interval: 1, reservedSize: _s(18),
                                getTitlesWidget: (value, meta) {
                                  final idx = value.toInt();
                                  if (idx < 0 || idx >= dateLabels.length) return const SizedBox();
                                  final step = spots.length > 20 ? 3 : (spots.length > 10 ? 2 : 1);
                                  if (idx % step != 0) return const SizedBox();
                                  return Padding(
                                    padding: EdgeInsets.only(top: _s(4)),
                                    child: Text(dateLabels[idx], style: TextStyle(color: labelColor, fontSize: _fs(9), fontWeight: FontWeight.w400)),
                                  );
                                },
                              ),
                            ),
                          ),
                          gridData: FlGridData(
                            show: true, drawVerticalLine: false, horizontalInterval: niceInterval,
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: (value - zeroY).abs() < 0.01 ? zeroLineColor : gridColor,
                              strokeWidth: (value - zeroY).abs() < 0.01 ? 1.0 : 0.5,
                              dashArray: [4, 4],
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                          minY: chartYMin, maxY: chartYMax,
                          lineBarsData: [
                            ..._buildSegmentedLineBars(spots, dailyChanges),
                            if (hs300Spots.length >= 2)
                              LineChartBarData(
                                spots: hs300Spots,
                                isCurved: false,
                                gradient: LinearGradient(colors: [ const Color(0xFF3B82F6),  const Color(0xFF3B82F6)]),
                                barWidth: 2.0,
                                dotData: FlDotData(
                                  show: true,
                                  getDotPainter: (spot, percent, barData, index) =>
                                      FlDotCirclePainter(radius: 2.0, gradient: LinearGradient(colors: [ const Color(0xFF3B82F6),  const Color(0xFF3B82F6)]), strokeWidth: 0),
                                ),
                                belowBarData: BarAreaData(show: false),
                              ),
                            if (zz1000Spots.length >= 2)
                              LineChartBarData(
                                spots: zz1000Spots,
                                isCurved: false,
                                gradient: LinearGradient(colors: [ const Color(0xFFFF8C00),  const Color(0xFFFF8C00)]),
                                barWidth: 2.0,
                                dotData: FlDotData(
                                  show: true,
                                  getDotPainter: (spot, percent, barData, index) =>
                                      FlDotCirclePainter(radius: 2.0, gradient: LinearGradient(colors: [ const Color(0xFFFF8C00),  const Color(0xFFFF8C00)]), strokeWidth: 0),
                                ),
                                belowBarData: BarAreaData(show: false),
                              ),
                          ],
                          lineTouchData: LineTouchData(enabled: false),
                        )),
                      ),
                    ),
                  );
                  },
                ),
              ),
                ],
              ),
            ),
          ),
          SizedBox(height: _s(2)),
          // 底部统计
          Container(
            padding: EdgeInsets.symmetric(vertical: _s(3), horizontal: _s(4)),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF151928) : const Color(0xFFF5F6FA),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                _buildTrendStatItem(Icons.trending_up_rounded, const Color(0xFF3B82F6), '当前收益率',
                    '${currentReturn >= 0 ? '+' : ''}${currentReturn.toStringAsFixed(2)}%',
                    currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E)),
                _buildTrendStatItem(Icons.balance_rounded, const Color(0xFF8B5CF6), '总盈亏比',
                    winLossRatio > 0
                        ? '${currentReturn >= 0 ? '+' : '-'}${winLossRatio.toStringAsFixed(2)}'
                        : '--',
                    currentReturn >= 0 ? const Color(0xFFEF4444) : const Color(0xFF22C55E)),
                _buildTrendStatItem(Icons.speed_rounded, const Color(0xFFF59E0B), '日收益波动率',
                    '${volatility.toStringAsFixed(2)}%', const Color(0xFFF59E0B)),
                _buildTrendStatItem(Icons.trending_down_rounded, const Color(0xFF10B981), '最大回撤',
                    '-${maxDrawdownPercent.toStringAsFixed(2)}%', const Color(0xFF10B981)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<LineChartBarData> _buildSegmentedLineBars(List<FlSpot> spots, List<double> dailyChanges) {
    const upColor = Color(0xFFF55555);
    const downColor = Color(0xFF3DC896);
    final result = <LineChartBarData>[];

    if (spots.length < 2) return result;

    for (int i = 0; i < spots.length - 1; i++) {
      final isUp = (i + 1) < dailyChanges.length && dailyChanges[i + 1] >= 0;
      final color = isUp ? upColor : downColor;

      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true, curveSmoothness: 0.3,
        gradient: LinearGradient(colors: [ Colors.transparent,  Colors.transparent]), barWidth: 0,
        dotData: FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [color.withOpacity(0.18), color.withOpacity(0.06), color.withOpacity(0.0)],
            stops: const [0.0, 0.4, 1.0],
          ),
          applyCutOffY: true,
        ),
      ));
      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true, curveSmoothness: 0.3,
        gradient: LinearGradient(colors: [ color.withOpacity(0.18),  color.withOpacity(0.18)]), barWidth: 6.0,
        dotData: FlDotData(show: false), belowBarData: BarAreaData(show: false),
      ));
      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true, curveSmoothness: 0.3,
        gradient: LinearGradient(colors: [ color.withOpacity(0.40),  color.withOpacity(0.40)]), barWidth: 3.0,
        dotData: FlDotData(show: false), belowBarData: BarAreaData(show: false),
      ));
      result.add(LineChartBarData(
        spots: [spots[i], spots[i + 1]],
        isCurved: true, curveSmoothness: 0.3,
        gradient: LinearGradient(colors: [ color,  color]), barWidth: 2.0,
        shadow: Shadow(color: color.withOpacity(0.5), blurRadius: 4, offset: const Offset(0, 1)),
        dotData: FlDotData(show: false), belowBarData: BarAreaData(show: false),
      ));
    }

    result.add(LineChartBarData(
      spots: spots, isCurved: false,
      gradient: LinearGradient(colors: [ Colors.transparent,  Colors.transparent]), barWidth: 0,
      dotData: FlDotData(
        show: true,
        getDotPainter: (spot, percent, barData, index) {
          final idx = spot.x.toInt();
          final isUp = idx < dailyChanges.length && dailyChanges[idx] >= 0;
          return FlDotCirclePainter(
            radius: 2.0, gradient: LinearGradient(colors: [ isUp ? upColor : downColor,  isUp ? upColor : downColor]),
            strokeWidth: 1.2, strokeColor: Colors.white,
          );
        },
      ),
      belowBarData: BarAreaData(show: false),
    ));

    return result;
  }

  Widget _buildTrendStatItem(IconData icon, Color iconColor, String label, String value, Color valueColor,
      {double? labelFontSize, double? valueFontSize}) {
    final colors = AppColors.of(context);
    final lfs = labelFontSize ?? _fs(7);
    final vfs = valueFontSize ?? _fs(9);
    return Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _s(1)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: _s(12), height: _s(12),
              decoration: BoxDecoration(color: iconColor.withOpacity(0.15), borderRadius: BorderRadius.circular(_s(3))),
              child: Icon(icon, color: iconColor, size: _s(7)),
            ),
            SizedBox(width: _s(2)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, softWrap: false, textAlign: TextAlign.center, style: TextStyle(color: colors.textSecondary, fontSize: lfs, fontWeight: FontWeight.w500)),
                  SizedBox(height: _s(1)),
                  Text(value, softWrap: false, textAlign: TextAlign.center, style: TextStyle(color: valueColor, fontWeight: FontWeight.w700, fontSize: vfs)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrendTimeFilterTabs({double tabScale = 1.0}) {
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
            margin: EdgeInsets.only(left: _s(6) * tabScale),
            padding: EdgeInsets.symmetric(horizontal: _s(8) * tabScale, vertical: _s(3) * tabScale),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF3B82F6) : colors.surface.withOpacity(0.5),
              borderRadius: BorderRadius.circular(10 * tabScale),
              // 无边框设计：未选中Tab用半透明背景暗示可点击
            ),
            child: Text(
              (isSelected && isCustom && _trendCustomStart != null && _trendCustomEnd != null)
                  ? '${_trendCustomStart!.month}/${_trendCustomStart!.day}-${_trendCustomEnd!.month}/${_trendCustomEnd!.day}'
                  : tab,
              style: TextStyle(
                  color: isSelected ? Colors.white : colors.textSecondary,
                  fontSize: _fs(9) * tabScale, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
          ),
        );
      }).toList(),
    );
  }

  // ========== 每日明细表 - 复制竖屏样式按比例缩小 ==========
  Widget _buildDailyDetailTable() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    final today = ExpertPerformanceService.getTodayString();

    String displayDate = now.hour >= 20 ? today : _getYesterdayString();
    if (!_history.any((r) => r.date == displayDate)) {
      if (_history.isNotEmpty) displayDate = _history.first.date;
    }
    var displayRecord = _history.firstWhere(
      (r) => r.date == displayDate,
      orElse: () => DailyExpertPerformance(date: '', stocks: []),
    );
    if (displayRecord.stocks.isEmpty && _history.isNotEmpty) displayRecord = _history.first;

    final isSettled = displayRecord.isSettled;
    final subtitle = isSettled ? '${displayRecord.date} (已结算)' : '${displayRecord.date} (待结算)';

    // 正常亮度配色
    final codeColor = isDark ? const Color(0xFF8E8E93) : const Color(0xFF666666);   // 标准灰色
    final nameColor = colors.textPrimary;   // 使用主题主色
    const profitRed = Color(0xFFFF3B30);    // 标准红
    const profitGreen = Color(0xFF34C759);  // 标准绿
    const pctAlpha = 1.0;                   // 正常透明度

    return Container(
      padding: EdgeInsets.fromLTRB(_s(8), _s(6), _s(8), _s(4)),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        // 无边框设计：用微弱阴影替代硬边框
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 1))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('每日明细表 ($subtitle)',
              style: TextStyle(color: colors.textPrimary, fontSize: _fs(20), fontWeight: FontWeight.w700, height: 1.2)),
          SizedBox(height: _s(3)),
          Expanded(
            child: ListView.builder(
              itemCount: displayRecord.stocks.length,
              itemBuilder: (context, i) {
                final stock = displayRecord.stocks[i];
                // ★ 尚未到下一个交易日确认时间 → 全部显示 0.00%
                final bool shouldZero = TradingDayUtils.shouldRecordShowZero(displayDate);
                final liveChange = _liveChangePercents[stock.code];
                final change = shouldZero ? 0.0 : (liveChange ?? stock.changePercent);
                final isUp = change > 0;
                final isDown = change < 0;
                final valueColor = isUp ? profitRed : (isDown ? profitGreen : colors.textSecondary);
                final pctColor = isUp
                    ? profitRed.withOpacity(pctAlpha)
                    : (isDown ? profitGreen.withOpacity(pctAlpha) : colors.textSecondary.withOpacity(pctAlpha));
                final valueText = '${isUp ? '+' : ''}${change.toStringAsFixed(2)}%';

                return Padding(
                  padding: EdgeInsets.symmetric(vertical: _s(3)),  // 行高增加12~15%
                  child: Row(
                    children: [
                      // 股票名称：Medium, 比代码亮, 字号不大
                      Expanded(
                        flex: 3,
                        child: Text(stock.name,
                            style: TextStyle(
                              color: nameColor,
                              fontSize: _fs(15),
                              fontWeight: FontWeight.w500,
                              fontFamily: 'SF Pro Text',
                            ),
                            overflow: TextOverflow.ellipsis),
                      ),
                      // 股票代码：Regular, 浅灰白, 缩小5~8%
                      Expanded(
                        flex: 2,
                        child: Text(stock.code,
                            style: TextStyle(
                              color: codeColor,
                              fontSize: _fs(14),
                              fontWeight: FontWeight.w400,
                              fontFamily: 'Roboto Mono',
                            ),
                            textAlign: TextAlign.center),
                      ),
                      // 盈亏百分比：SemiBold, 低饱和红绿, 比主数字小10%
                      Expanded(
                        flex: 2,
                        child: Text(valueText,
                            style: TextStyle(
                              color: pctColor,
                              fontSize: _fs(14),
                              fontWeight: FontWeight.w600,
                              fontFamily: 'DIN Alternate',
                            ),
                            textAlign: TextAlign.right),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ========== 单日平均涨跌 - 与竖屏完全一致的数据逻辑 ==========
  Widget _buildDailyBarChart() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_history.isEmpty) return _buildEmptyCard('单日平均涨跌');

    // ★ 与竖屏一致：取所有历史数据，按日期正序（左旧右新）
    var recent = [..._history]
      ..sort((a, b) => a.date.compareTo(b.date));

    // ★ 与竖屏一致：根据时间范围筛选数据
    if (_barTimeRange == 3 && _barCustomStart != null && _barCustomEnd != null) {
      recent = _filterByDateRange(recent, _barCustomStart!, _barCustomEnd!);
    } else if (_barTimeRange == 4) {
      // 全部数据：不过滤
    } else {
      final daysMap = {0: 7, 1: 30, 2: 90};
      if (recent.length > daysMap[_barTimeRange]!) {
        recent = recent.sublist(recent.length - daysMap[_barTimeRange]!);
      }
    }

    // ★ 与竖屏一致：建立交易日记录映射，优先使用交易日记录中的 avgChangePercent
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
      // ★ 与竖屏一致：优先使用交易日记录的 avgChangePercent，否则使用 ExpertPerformance 的 dailyAvgChange
      final avgChange = tradingRecordMap[record.date] ?? record.dailyAvgChange;
      final isUp = avgChange > 0;
      final isDown = avgChange < 0;
      final isFlat = avgChange == 0;

      if (isUp) upDays++;
      else if (isDown) downDays++;
      else flatDays++;

      dateLabels.add(record.date.substring(5));

      barGroups.add(BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            y: avgChange,
            color: isUp ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
            width: recent.length > 15 ? 6 : 10,
            borderRadius: isUp
                ? const BorderRadius.only(topLeft: Radius.circular(3), topRight: Radius.circular(3))
                : const BorderRadius.only(bottomLeft: Radius.circular(3), bottomRight: Radius.circular(3)),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: isUp
                  ? [const Color(0xFFFCA5A5), const Color(0xFFEF4444)]
                  : [const Color(0xFF86EFAC), const Color(0xFF22C55E)],
            ),
          ),
        ],
        showingTooltipIndicators: [],
      ));
    }

    // ★ 与竖屏一致：Y轴范围（使用交易日记录的数据计算）
    final allValues = recent.map((r) => tradingRecordMap[r.date] ?? r.dailyAvgChange).toList();
    double chartBarYMin, chartBarYMax, niceBarInterval;
    int barTickCount;
    {
      chartBarYMin = allValues.isEmpty ? -1.0 : (allValues.reduce(math.min) - 0.5).floorToDouble();
      chartBarYMax = allValues.isEmpty ? 1.0 : (allValues.reduce(math.max) + 0.5).ceilToDouble();
      niceBarInterval = math.max((chartBarYMax - chartBarYMin) / 5, 1);
      barTickCount = ((chartBarYMax - chartBarYMin) / niceBarInterval).ceil() + 1;
    }

    final labelColor = isDark ? const Color(0xFF8890A8) : const Color(0xFF8E8E93);
    final zeroLineColor = isDark ? const Color(0xFF2D3148) : const Color(0xFFE5E5EA);
    final gridColor = isDark ? const Color(0xFF232740) : const Color(0xFFEFF0F5);

    return Container(
      padding: EdgeInsets.fromLTRB(_s(3), _s(4), _s(3), _s(2)),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        // 无边框设计：保留微弱阴影营造悬浮感
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏 - 缩减
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(_s(4)),
                decoration: BoxDecoration(color: const Color(0xFFF59E0B).withOpacity(0.1), borderRadius: BorderRadius.circular(_s(6))),
                child: Icon(Icons.bar_chart, color: const Color(0xFFF59E0B), size: _s(14)),
              ),
              SizedBox(width: _s(4)),
              Text('单日平均涨跌',
                  style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700, fontSize: _fs(12), height: 1.2)),
            ],
          ),
          SizedBox(height: _s(2)),
          // 时间筛选
          _buildBarTimeFilterTabs(),
          SizedBox(height: _s(2)),
          // 柱状图
          Expanded(
            child: Container(
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: isDark ? [const Color(0xFF0D1120), const Color(0xFF13182B)] : [const Color(0xFFF8F9FC), const Color(0xFFF0F1F5)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Y轴 - 刻度与BarChart精确对齐
                  SizedBox(
                    width: _s(38),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(barTickCount, (i) {
                        final value = chartBarYMax - (i * niceBarInterval);
                        final isZero = value.abs() < 0.01;
                        return Padding(
                          padding: EdgeInsets.only(right: _s(6)),
                          child: Text('${value >= 0 ? '+' : ''}${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}%',
                              style: TextStyle(
                                color: isZero ? (isDark ? const Color(0xFFC0C8D8) : const Color(0xFF555555)) : labelColor,
                                fontSize: _fs(9), fontWeight: isZero ? FontWeight.w600 : FontWeight.w400,
                              )),
                        );
                      }),
                    ),
                  ),
                  SizedBox(width: _s(4)),
                  // 柱状图 - 固定每柱16px宽，确保总量再多也不压缩
                             Expanded(
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        const perBarWidth = 16.0;
                        final chartWidth = math.max(barGroups.length * perBarWidth, constraints.maxWidth + 1);
                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: chartWidth,
                              maxWidth: chartWidth,
                            ),
                            child: BarChart(BarChartData(
                          alignment: BarChartAlignment.spaceBetween,
                          gridData: FlGridData(
                            show: true, drawVerticalLine: false, horizontalInterval: niceBarInterval,
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: value.abs() < 0.01 ? zeroLineColor : gridColor,
                              strokeWidth: value.abs() < 0.01 ? 1.0 : 0.5,
                              dashArray: value.abs() < 0.01 ? null : [4, 4],
                            ),
                          ),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true, interval: 1,
                                getTitlesWidget: (value, meta) {
                                  final idx = value.toInt();
                                  if (idx < 0 || idx >= dateLabels.length) return const SizedBox();
                                  final step = barGroups.length > 15 ? 3 : (barGroups.length > 7 ? 2 : 1);
                                  if (idx % step != 0) return const SizedBox();
                                  return Padding(
                                    padding: EdgeInsets.only(top: _s(6)),
                                    child: Text(dateLabels[idx], style: TextStyle(color: labelColor, fontSize: _fs(9))),
                                  );
                                },
                              ),
                            ),
                            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          borderData: FlBorderData(show: false),
                          minY: chartBarYMin, maxY: chartBarYMax,
                          barGroups: barGroups,
                          barTouchData: BarTouchData(
                            touchTooltipData: BarTouchTooltipData(
                              tooltipBgColor: isDark ? const Color(0xFF1E2240) : const Color(0xFF333333),
                              tooltipRoundedRadius: 6, fitInsideHorizontally: true, fitInsideVertically: true,
                              tooltipPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                                final val = rod.toY;
                                return BarTooltipItem(
                                  '${dateLabels[group.x]}\n${val >= 0 ? '+' : ''}${val.toStringAsFixed(2)}%',
                                  TextStyle(color: val >= 0 ? const Color(0xFFFF8A8A) : const Color(0xFF6FDFD6),
                                      fontWeight: FontWeight.w600, fontSize: 11, height: 1.3),
                                );
                              },
                            ),
                          ),
                        )),
                      ),
                    );
                  },
                ),
                ),
                ],
              ),
            ),
          ),
          SizedBox(height: _s(2)),
          // 底部统计 - 缩减
          Container(
            padding: EdgeInsets.symmetric(vertical: _s(3), horizontal: _s(4)),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF151928) : const Color(0xFFF5F6FA),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(child: _buildDayStat('上涨天数', upDays.toString(), const Color(0xFFEF4444))),
                const SizedBox(width: 8),
                Expanded(child: _buildDayStat('下跌天数', downDays.toString(), const Color(0xFF22C55E))),
                const SizedBox(width: 8),
                Expanded(child: _buildDayStat('平盘天数', flatDays.toString(), Colors.grey[400]!)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBarTimeFilterTabs({double tabScale = 1.0}) {
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
            margin: EdgeInsets.only(left: _s(6) * tabScale),
            padding: EdgeInsets.symmetric(horizontal: _s(8) * tabScale, vertical: _s(3) * tabScale),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFFF59E0B) : colors.surface.withOpacity(0.5),
              borderRadius: BorderRadius.circular(10 * tabScale),
              // 无边框设计：未选中Tab用半透明背景暗示可点击
            ),
            child: Text(
              (isSelected && isCustom && _barCustomStart != null && _barCustomEnd != null)
                  ? '${_barCustomStart!.month}/${_barCustomStart!.day}-${_barCustomEnd!.month}/${_barCustomEnd!.day}'
                  : tab,
              style: TextStyle(
                  color: isSelected ? Colors.white : colors.textSecondary,
                  fontSize: _fs(9) * tabScale, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
          ),
        );
      }).toList(),
    );
  }

  /// 自定义日期范围选择器
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
                ),
          child: child!,
        );
      },
    );

    if (picked == null) return null;
    return {'start': picked.start, 'end': picked.end};
  }

  Widget _buildDayStat(String label, String value, Color color) {
    final colors = AppColors.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: _s(6), height: _s(6), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            SizedBox(width: _s(4)),
            Text(label, style: TextStyle(color: colors.textSecondary, fontSize: _fs(8), fontWeight: FontWeight.w500)),
          ],
        ),
        SizedBox(height: _s(1)),
        Text(value, style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700, fontSize: _fs(11))),
      ],
    );
  }

  // ========== 工具方法 ==========
  // ★ 与竖屏一致的日期范围过滤方法
  List<DailyExpertPerformance> _filterByDateRange(List<DailyExpertPerformance> sorted, DateTime start, DateTime end) {
    final startStr = '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    final endStr = '${end.year}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}';
    return sorted.where((r) => r.date.compareTo(startStr) >= 0 && r.date.compareTo(endStr) <= 0).toList();
  }

  List<TradingDayRecord> _getFilteredRecords(int timeRange, {DateTime? customStart, DateTime? customEnd}) {
    final now = DateTime.now();
    var records = List<TradingDayRecord>.from(_tradingRecords);
    switch (timeRange) {
      case 0:
        records = records.where((r) => DateTime.parse(r.date).isAfter(now.subtract(const Duration(days: 7)))).toList();
        break;
      case 1:
        records = records.where((r) => DateTime.parse(r.date).isAfter(now.subtract(const Duration(days: 30)))).toList();
        break;
      case 2:
        records = records.where((r) => DateTime.parse(r.date).isAfter(now.subtract(const Duration(days: 90)))).toList();
        break;
      case 3:
        // 自定义日期范围
        if (customStart != null && customEnd != null) {
          final startStr = '${customStart.year}-${customStart.month.toString().padLeft(2, '0')}-${customStart.day.toString().padLeft(2, '0')}';
          final endStr = '${customEnd.year}-${customEnd.month.toString().padLeft(2, '0')}-${customEnd.day.toString().padLeft(2, '0')}';
          records = records.where((r) => r.date.compareTo(startStr) >= 0 && r.date.compareTo(endStr) <= 0).toList();
        }
        break;
    }
    if (records.length > 30) records = records.sublist(0, 30);
    records.sort((a, b) => DateTime.parse(a.date).compareTo(DateTime.parse(b.date)));
    return records;
  }

  Widget _buildEmptyCard(String title) {
    final colors = AppColors.of(context);
    return Container(
      padding: EdgeInsets.all(_s(16)),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        // 无边框设计：空数据卡片无边框
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6, offset: const Offset(0, 1))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: colors.textPrimary, fontSize: _fs(17), fontWeight: FontWeight.w700)),
          const Expanded(child: Center(child: Text('暂无数据', style: TextStyle(color: Colors.grey)))),
        ],
      ),
    );
  }
}

/// 呼吸淡入淡出箭头：固定位置，透明度在 80%~100% 之间柔和波动
class _TrailArrowPainter extends CustomPainter {
  final ValueNotifier<double> animation;
  final String arrow;
  final Color color;
  final double fontSize;
  final double percentFontSize;
  final bool isUp;
  final double baseYOffset;

  _TrailArrowPainter({
    required this.animation,
    required this.arrow,
    required this.color,
    required this.fontSize,
    required this.percentFontSize,
    required this.isUp,
    this.baseYOffset = 0.0,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final v = animation.value;
    final textStyle = TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.1,
    );

    final measureTP = TextPainter(text: TextSpan(text: arrow, style: textStyle), textDirection: TextDirection.ltr)..layout();
    final th = measureTP.height;
    final pctH = percentFontSize * 1.1;
    final rawBaseY = isUp
        ? (size.height + pctH) / 2 - th
        : (size.height - pctH) / 2;
    final baseY = rawBaseY + baseYOffset;

    // 呼吸效果：sin 平滑波，透明度 40% ~ 100%
    final breath = math.sin(v * 2 * math.pi);  // -1 ~ 1
    final alpha = 0.70 + breath * 0.30;         // 40% ~ 100%

    _paintArrow(canvas, size, textStyle, baseY, alpha);
  }

  void _paintArrow(Canvas canvas, Size size, TextStyle style, double y, double alpha) {
    final span = TextSpan(text: arrow, style: style.copyWith(color: color.withOpacity(alpha)));
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, y));
  }

  @override
  bool shouldRepaint(_TrailArrowPainter old) {
    return old.arrow != arrow || old.color != color || old.fontSize != fontSize
        || old.percentFontSize != percentFontSize || old.isUp != isUp
        || old.baseYOffset != baseYOffset;
  }
}
