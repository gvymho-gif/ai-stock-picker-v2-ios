/// 首页 - AI智能选股主界面
///
/// 年轻化设计：深蓝紫渐变 + 玉璃态效果
/// 搜索为主布局，支持板块浏览和专家选股入口
/// 智能规则引擎深度分析

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_theme.dart';
import '../services/local_data_service.dart';
import '../services/favorite_service.dart';
import '../models/favorite_stock.dart';
import '../models/favorite_category.dart';
import '../widgets/styles.dart';
import '../widgets/filter_panel.dart';
import '../models/filter_criteria.dart';
import 'sector_screen.dart';
import 'expert_screen.dart';
import 'filter_screen.dart';
import 'favorite_screen.dart';
import 'ai_qa_screen.dart';
import 'ai_model_config_screen.dart';
import 'settings_screen.dart';
import 'sector_stocks_screen.dart';
import 'stock_analysis_screen.dart';
import 'news_detail_screen.dart';
import '../widgets/investment_calendar_widget.dart';
import '../services/stock_deep_analysis_service.dart';
import '../services/ai_model_service.dart';
import '../services/news_service.dart';
import '../models/ai_model_config.dart';
import '../widgets/expert_performance_widget.dart';
import '../widgets/landscape_performance_grid.dart';
import '../widgets/hot_investment_card_widget.dart';
import '../widgets/lite_investment_card_widget.dart';
import '../widgets/speed_investment_card_widget.dart';
import '../services/hot_investment_service.dart';
import '../services/lite_investment_service.dart';
import 'hot_investment_list_screen.dart';
import 'lite_investment_list_screen.dart';
import 'speed_investment_list_screen.dart';
import '../services/speed_investment_service.dart';
import '../models/speed_investment_model.dart';
import 'portfolio_menu_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  final LocalDataService _api = LocalDataService();
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  late final AnimationController _titleFadeCtrl;

  // 双击退出
  DateTime? _lastBackPressed;

  bool _loading = false;
  Map<String, dynamic>? _res;
  String? _err;
  String _lastQuery = '';
  bool _autoRefresh = false;
  Map<String, List<Map<String, dynamic>>> _sectors = {};
  bool _sectorsLoading = true;
  bool _isFavorite = false;
  String? _favoriteCategory;
  AIModelConfig? _activeModel;
  List<AIModelConfig> _enabledModels = [];

  // 折叠状态：默认折叠
  bool _calendarExpanded = false;
  bool _sectorsExpanded = false;
  bool _newsExpanded = false;
  List<Map<String, dynamic>> _newsList = [];
  bool _newsLoading = false;
  bool _isLandscape = false;
  double? _hsDragStartX;  // 横屏右侧滑动起始X坐标
  int _hsSwipeCount = 0;   // 横屏左滑次数
  Timer? _hsSwipeTimer;    // 横屏左滑超时计时器
  int _vsSwipeCount = 0;   // 竖屏下拉次数
  Timer? _vsSwipeTimer;    // 竖屏下拉超时计时器
  double? _vsPointerDownY; // 竖屏下拉起始Y
  DateTime? _vsPointerDownTime; // 竖屏下拉起始时间
  bool _vsSwipeTriggered = false; // 本次触摸是否已触发计数

  // 热点投资服务
  final HotInvestmentService _hotInvestService = HotInvestmentService();
  // 轻量投资服务
  final LiteInvestmentService _liteInvestService = LiteInvestmentService();
  // 极速投资服务
  final SpeedInvestmentService _speedInvestService = SpeedInvestmentService();

  // 悬浮"问"按钮拖拽状态
  double _fabX = 0;  // X轴偏移
  double _fabY = 0;  // Y轴偏移
  bool _fabDragging = false;
  bool _isFabCollapsed = false;  // 是否已收缩到边缘
  int _fabEdge = 0;  // 0=无, 1=左, 2=右, 3=上, 4=下
  static const double _fabSize = 60;  // 加大尺寸
  static const double _collapsedSize = 22;  // 收起后显示尺寸（左右比例减半）
  static const double _edgeThreshold = 30;  // 吸附边缘阈值

  @override
  void initState() {
    super.initState();
    _titleFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    Future.delayed(const Duration(milliseconds: 850), () {
      if (mounted) _titleFadeCtrl.forward();
    });
    _loadFabPosition();
    _loadSectors();
    _loadActiveModel();
    _loadNews();
    _hotInvestService.load();
    _liteInvestService.load();
    _speedInvestService.init();
    // 开盘后自动激活pending组合
    _autoActivateHotInvestments();
    _autoActivateSpeedInvestments();
  }

  void _autoActivateHotInvestments() {
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      // 仅交易时段(09:30-15:05)自动检查，避免非交易时段误触发结算
      final now = DateTime.now();
      final minutes = now.hour * 60 + now.minute;
      if (minutes < 9 * 60 + 30 || minutes > 15 * 60 + 5) return;
      _hotInvestService.checkAllPortfolios();
      _liteInvestService.checkAllPortfolios();
    });
  }

  void _autoActivateSpeedInvestments() {
    Future.delayed(const Duration(seconds: 4), () async {
      if (!mounted) return;
      final now = DateTime.now();
      final minutes = now.hour * 60 + now.minute;
      if (minutes < 9 * 60 + 30 || minutes > 15 * 60 + 5) return;
      final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // 1. 激活buyDate=今天的pending组合
      final hasTodayPending = _speedInvestService.portfolios.any((p) {
        if (p.status != SpeedPortfolioStatus.pending) return false;
        final buyDateStr = '${p.buyDate.year}-${p.buyDate.month.toString().padLeft(2, '0')}-${p.buyDate.day.toString().padLeft(2, '0')}';
        return buyDateStr == todayStr;
      });
      if (hasTodayPending) {
        await _speedInvestService.tryAutoActivate();
      }

      // 2. 结算sellDate=今天的active组合
      final hasTodaySettleable = _speedInvestService.portfolios.any((p) {
        if (p.status != SpeedPortfolioStatus.active) return false;
        final sellDateStr = '${p.sellDate.year}-${p.sellDate.month.toString().padLeft(2, '0')}-${p.sellDate.day.toString().padLeft(2, '0')}';
        return sellDateStr == todayStr;
      });
      if (hasTodaySettleable) {
        await _speedInvestService.tryAutoSettle();
        if (mounted) setState(() {}); // 结算后刷新首页
      }
    });
  }

  @override
  void dispose() {
    _titleFadeCtrl.dispose();
    _vsSwipeTimer?.cancel();
    _hsSwipeTimer?.cancel();
    _speedInvestService.dispose();
    super.dispose();
  }

  /// 加载悬浮按钮位置（持久化）
  void _loadFabPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dx = prefs.getDouble('fab_offset_x') ?? 0;
      final dy = prefs.getDouble('fab_offset_y') ?? 0;
      final collapsed = prefs.getBool('fab_collapsed') ?? false;
      final edge = prefs.getInt('fab_edge') ?? 0;
      if (mounted) setState(() { _fabX = dx; _fabY = dy; _isFabCollapsed = collapsed; _fabEdge = edge; });
    } catch (_) {}
  }

  /// 保存悬浮按钮位置
  void _saveFabPosition(double dx, double dy) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('fab_offset_x', dx);
      await prefs.setDouble('fab_offset_y', dy);
      await prefs.setBool('fab_collapsed', _isFabCollapsed);
      await prefs.setInt('fab_edge', _fabEdge);
    } catch (_) {}
  }

  /// 构建可拖拽悬浮"问"按钮（支持任意位置吸附缩小/展开）
  Widget _buildDraggableFab(BuildContext context) {
    final colors = AppColors.of(context);
    final media = MediaQuery.of(context);
    final screenW = media.size.width;
    final screenH = media.size.height - media.padding.top - media.padding.bottom;
    final currentSize = _isFabCollapsed ? _collapsedSize : _fabSize;

    double posX = (screenW / 2) + _fabX - (currentSize / 2);
    double posY = (screenH / 2) + _fabY - (currentSize / 2);
    posX = posX.clamp(0, screenW - currentSize);
    posY = posY.clamp(0, screenH - currentSize);

    void _handleEdgeSnap() {
      final centerX = posX + currentSize / 2;
      final distLeft = centerX;
      final distRight = screenW - centerX;
      if (distLeft <= _edgeThreshold && !_isFabCollapsed) {
        setState(() { _isFabCollapsed = true; _fabEdge = 1; });
      } else if (distRight <= _edgeThreshold && !_isFabCollapsed) {
        setState(() { _isFabCollapsed = true; _fabEdge = 2; });
      } else if (distLeft >= _edgeThreshold && distRight >= _edgeThreshold && _isFabCollapsed) {
        setState(() { _isFabCollapsed = false; _fabEdge = 0; });
      }
      _saveFabPosition(_fabX, _fabY);
    }

    return Positioned(
      left: posX,
      top: posY,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _fabX += details.delta.dx;
            _fabY += details.delta.dy;
            _fabDragging = true;
            if (_isFabCollapsed) { _isFabCollapsed = false; _fabEdge = 0; }
          });
        },
        onPanEnd: (_) {
          setState(() => _fabDragging = false);
          _handleEdgeSnap();
        },
        onTap: () {
          if (_isFabCollapsed && !_fabDragging) {
            setState(() { _isFabCollapsed = false; _fabEdge = 0; });
            _saveFabPosition(_fabX, _fabY);
          } else if (!_fabDragging) {
            Navigator.push(context, _slideRoute(const AIQAScreen()));
          }
        },
        child: SizedBox(
          width: _isFabCollapsed ? _collapsedSize : _fabSize + 20,
          height: _isFabCollapsed ? _collapsedSize : _fabSize + 20,
          child: _isFabCollapsed ? _buildCollapsedFab(colors) : _buildExpandedFab(colors),
        ),
      ),
    );
  }

  /// 展开态 — 白天/黑夜双色
  Widget _buildExpandedFab(AppColorScheme colors) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 深色：标准紫  /  浅色：柔和浅紫，跟白底搭配
    final fabColors = isDark
        ? [colors.primary, colors.accent]
        : [const Color(0xFF9FA8DA), const Color(0xFFCE93D8)];
    return Container(
      width: _fabSize - 4,
      height: _fabSize - 4,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: fabColors,
        ),
        boxShadow: [
          BoxShadow(color: fabColors[0].withOpacity(isDark ? 0.35 : 0.18), blurRadius: 16, spreadRadius: 1, offset: const Offset(0, 4)),
          BoxShadow(color: fabColors[1].withOpacity(isDark ? 0.15 : 0.08), blurRadius: 30, spreadRadius: -2, offset: const Offset(0, 8)),
        ],
      ),
      child: Stack(alignment: Alignment.center, children: [
        // 顶部玻璃高光
        Positioned(
          top: 3, left: 8, right: 8,
          child: Container(
            height: _fabSize * 0.35,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Colors.white.withOpacity(0.22), Colors.white.withOpacity(0.0)],
              ),
            ),
          ),
        ),
        // 大脑图标 + Q&A
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.psychology, color: Colors.white, size: 26),
            const SizedBox(height: 1),
            Text('Q&A', style: TextStyle(
              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              decoration: TextDecoration.none,
            )),
          ],
        ),
      ]),
    );
  }

  /// 吸附态 — 缩小50% + 透明度50%，无呼吸灯，双色
  Widget _buildCollapsedFab(AppColorScheme colors) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fabColors = isDark
        ? [colors.primary, colors.accent]
        : [const Color(0xFF9FA8DA), const Color(0xFFCE93D8)];
    BorderRadius br;
    switch (_fabEdge) {
      case 1:
        br = const BorderRadius.only(topLeft: Radius.circular(4), topRight: Radius.circular(10), bottomLeft: Radius.circular(4), bottomRight: Radius.circular(10));
        break;
      case 2:
        br = const BorderRadius.only(topLeft: Radius.circular(10), topRight: Radius.circular(4), bottomLeft: Radius.circular(10), bottomRight: Radius.circular(4));
        break;
      default:
        br = BorderRadius.circular(10);
    }
    return Opacity(
      opacity: 0.5,
      child: Container(
        width: _collapsedSize, height: _collapsedSize,
        decoration: BoxDecoration(
          borderRadius: br,
          gradient: LinearGradient(colors: fabColors),
          boxShadow: [BoxShadow(color: fabColors[0].withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2))],
        ),
      ),
    );
  }

  // ============ 数据加载 ============

  void _loadSectors() async {
    try {
      final data = await _api.fetchHotSectors();
      if (mounted) setState(() { _sectors = data; _sectorsLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _sectorsLoading = false; });
    }
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    _lastQuery = q;
    setState(() { _loading = true; _err = null; _res = null; });
    try {
      final data = await _api.searchStock(q);
      if (mounted) {
        setState(() { _res = data; _loading = false; });
        _checkFavoriteStatus(q);
      }
    } catch (e) {
      if (mounted) setState(() { _err = e.toString().replaceAll('Exception: ', ''); _loading = false; });
    }
  }

  Future<void> _refreshOnce() async {
    if (_lastQuery.isEmpty) return;
    setState(() { _loading = true; });
    try {
      final data = await _api.searchStock(_lastQuery);
      if (mounted) setState(() { _res = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; });
    }
  }

  void _toggleAutoRefresh() {
    setState(() { _autoRefresh = !_autoRefresh; });
    if (_autoRefresh) _autoRefreshLoop();
  }

  void _autoRefreshLoop() async {
    while (_autoRefresh && _lastQuery.isNotEmpty && mounted) {
      await Future.delayed(const Duration(seconds: 8));
      if (!_autoRefresh || _lastQuery.isEmpty || !mounted) break;
      try {
        final data = await _api.searchStock(_lastQuery);
        if (mounted && _autoRefresh) setState(() { _res = data; });
      } catch (_) {}
    }
  }

  void _goBack() => setState(() { _res = null; _err = null; _isFavorite = false; });

  void _loadNews() async {
    setState(() => _newsLoading = true);
    try {
      final news = await NewsService.fetchLatestNews(pageSize: 10);
      if (mounted) setState(() { _newsList = news; _newsLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _newsLoading = false);
    }
  }

  void _loadActiveModel() async {
    final model = await AIModelService.getActiveModel();
    final models = await AIModelService.getEnabledModels();
    if (mounted) {
      setState(() {
        _activeModel = model;
        _enabledModels = models;
      });
    }
  }

  void _switchModel(AIModelConfig model) async {
    await AIModelService.setActiveModelId(model.id);
    setState(() => _activeModel = model);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到 ${model.name}')),
    );
  }

  void _showModelSwitcher() {
    final colors = AppColors.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.swap_horiz, color: colors.primary, size: 24),
                const SizedBox(width: 10),
                Text('切换AI模型', style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(context, _slideRoute(const AIModelConfigScreen())).then((_) => _loadActiveModel());
                  },
                  icon: Icon(Icons.settings, size: 16, color: colors.textSecondary),
                  label: Text('管理', style: AppText.caption.copyWith(color: colors.textSecondary)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('选择当前使用的AI模型', style: AppText.caption.copyWith(color: colors.textHint)),
            const SizedBox(height: AppSpacing.lg),
            if (_enabledModels.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    children: [
                      Icon(Icons.cloud_off, size: 48, color: colors.textHint),
                      const SizedBox(height: AppSpacing.md),
                      Text('暂无可用的AI模型', style: AppText.body2.copyWith(color: colors.textSecondary)),
                      const SizedBox(height: AppSpacing.sm),
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          Navigator.push(context, _slideRoute(const AIModelConfigScreen())).then((_) => _loadActiveModel());
                        },
                        icon: Icon(Icons.add, size: 18),
                        label: Text('添加模型', style: AppText.body2.copyWith(color: Colors.white)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colors.primary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...List.generate(_enabledModels.length, (index) {
                final model = _enabledModels[index];
                final isActive = model.id == _activeModel?.id;
                return Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => _switchModel(model),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: isActive ? colors.primaryContainer.withOpacity(0.3) : colors.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isActive ? colors.primary : colors.border,
                            width: isActive ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Text(
                                  model.name.substring(0, 1).toUpperCase(),
                                  style: AppText.h3.copyWith(color: colors.primary, fontWeight: FontWeight.w800),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(model.name, style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
                                      if (isActive) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: colors.primary,
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Text('当前', style: AppText.caption.copyWith(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text('${model.provider} · ${model.model}', style: AppText.caption.copyWith(color: colors.textHint), overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            if (!isActive)
                              Icon(Icons.radio_button_off, size: 20, color: colors.textHint)
                            else
                              Icon(Icons.check_circle, size: 20, color: colors.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }

  // ============ 收藏功能 ============

  Future<void> _checkFavoriteStatus(String symbol) async {
    final isFav = await FavoriteService.isFavorite(symbol);
    final category = await FavoriteService.getStockCategory(symbol);
    if (mounted) setState(() { _isFavorite = isFav; _favoriteCategory = category; });
  }

  Future<void> _toggleFavorite(Map<String, dynamic> stockData) async {
    if (_isFavorite) {
      await FavoriteService.removeStock(stockData['symbol'].toString());
      setState(() => _isFavorite = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已移除收藏')),
      );
    } else {
      _showAddFavoriteDialog(stockData);
    }
  }

  void _showAddFavoriteDialog(Map<String, dynamic> stockData) async {
    final colors = AppColors.of(context);
    final categories = await FavoriteService.getCategories();

    if (!mounted) return;

    if (categories.isEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.surface,
          title: Text('创建收藏分类', style: AppText.h3.copyWith(color: colors.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open, size: 48, color: colors.textHint),
              const SizedBox(height: AppSpacing.md),
              Text('还没有收藏分类', style: AppText.body2.copyWith(color: colors.textSecondary)),
              const SizedBox(height: AppSpacing.sm),
              Text('请先创建一个分类', style: AppText.caption.copyWith(color: colors.textHint)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final name = await _showNewCategoryDialog();
                if (name != null && mounted) {
                  final id = const Uuid().v4().toString().substring(0, 8);
                  final success = await FavoriteService.addCategory(
                    FavoriteCategory(id: id, name: name!, createdAt: DateTime.now()),
                  );
                  if (success && mounted) {
                    _showAddFavoriteDialog(stockData);
                  }
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
              child: Text('创建分类', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        ),
      );
      return;
    }

    String? selectedCategory = categories.first.id;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: colors.surface,
            title: Text('添加到收藏', style: AppText.h3.copyWith(color: colors.textPrimary)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('选择分类', style: AppText.caption.copyWith(color: colors.textHint)),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    ...categories.map((category) {
                      final isSelected = selectedCategory == category.id;
                      return GestureDetector(
                        onTap: () => setDialogState(() => selectedCategory = category.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                          decoration: BoxDecoration(
                            color: isSelected ? colors.primaryContainer : colors.surfaceVariant,
                            borderRadius: BorderRadius.circular(AppRadius.full),
                            border: Border.all(
                              color: isSelected ? colors.primary : colors.border,
                            ),
                          ),
                          child: Text(category.name,
                            style: AppText.caption.copyWith(
                              color: isSelected ? colors.primary : colors.textSecondary,
                              fontWeight: FontWeight.w600,
                            )),
                        ),
                      );
                    }).toList(),
                    GestureDetector(
                      onTap: () async {
                        final name = await _showNewCategoryDialog();
                        if (name != null) {
                          final id = const Uuid().v4().toString().substring(0, 8);
                          final success = await FavoriteService.addCategory(
                            FavoriteCategory(id: id, name: name!, createdAt: DateTime.now()),
                          );
                          if (success && mounted) {
                            Navigator.pop(ctx);
                            _showAddFavoriteDialog(stockData);
                          }
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: colors.surfaceVariant,
                          borderRadius: BorderRadius.circular(AppRadius.full),
                          border: Border.all(color: colors.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 16, color: colors.primary),
                            const SizedBox(width: 4),
                            Text('新建', style: AppText.caption.copyWith(color: colors.primary, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (selectedCategory == null) return;
                  final stock = FavoriteStock(
                    id: const Uuid().v4().toString().substring(0, 8),
                    category: selectedCategory!,
                    symbol: stockData['symbol'].toString(),
                    name: stockData['name'].toString(),
                    market: stockData['market']?.toString() ?? 'A',
                    price: _d(stockData['price']),
                    changePct: _d(stockData['change_pct']),
                    addedAt: DateTime.now(),
                  );
                  final success = await FavoriteService.addStock(stock);
                  if (success) {
                    Navigator.pop(ctx);
                    if (mounted) {
                      setState(() {
                        _isFavorite = true;
                        _favoriteCategory = selectedCategory;
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已添加到收藏')),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
                child: Text('确定', style: AppText.body2.copyWith(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<String?> _showNewCategoryDialog() async {
    final colors = AppColors.of(context);
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text('新建分类', style: AppText.h3.copyWith(color: colors.textPrimary)),
        content: TextField(
          controller: controller,
          style: AppText.body1.copyWith(color: colors.textPrimary),
          decoration: InputDecoration(
            hintText: '分类名称',
            hintStyle: AppText.body2.copyWith(color: colors.textHint),
            filled: true,
            fillColor: colors.surfaceVariant,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) Navigator.pop(ctx, name);
            },
            style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
            child: Text('确定', style: AppText.body2.copyWith(color: Colors.white)),
          ),
        ],
      ),
    );
  }


  // ============ 导航 ============

  void _openFilter() {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => FilterPanel(onApply: _applyFilter),
    );
  }

  void _applyFilter(FilterCriteria criteria) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => FilterScreen(criteria: criteria))).then((result) {
      if (result != null && result is String && result.isNotEmpty) { _ctrl.text = result; _search(); }
    });
  }

  void _onSectorTap(Map<String, dynamic> sector) {
    final name = sector['name']?.toString() ?? '';
    final code = sector['code']?.toString() ?? '';
    final market = sector['market']?.toString() ?? 'A';
    // 所有板块/指数都进入SectorScreen显示成分股
    Navigator.push(context, _slideRoute(SectorScreen(sectorName: name, sectorCode: code, market: market, api: _api)));
  }

  void _onExpertTap() {
    Navigator.push(context, _slideRoute(ExpertScreen(api: _api)));
  }

  void _onPortfolioTap() {
    Navigator.push(context, _slideRoute(PortfolioMenuScreen(
      hotService: _hotInvestService,
      liteService: _liteInvestService,
      speedService: _speedInvestService,
    )));
  }

  /// 统一的右滑进入路由
  PageRouteBuilder _slideRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        const begin = Offset(1.0, 0.0);
        const end = Offset.zero;
        const curve = Curves.easeOutCubic;
        var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
        return SlideTransition(position: animation.drive(tween), child: child);
      },
      transitionDuration: const Duration(milliseconds: 350),
    );
  }

  // ============ 构建UI ============

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 最外层 Listener — 兜底捕获所有 pointer 事件，不受 Scaffold 内部手势竞技影响
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        // 只在竖屏 + 触摸点在顶部30%区域内才开始追踪
        if (_isLandscape) return;
        final screenH = MediaQuery.of(context).size.height;
        if (event.position.dy > screenH * 0.30) return;
        _vsPointerDownY = event.position.dy;
        _vsPointerDownTime = DateTime.now();
        _vsSwipeTriggered = false;
      },
      onPointerMove: (event) {
        if (_isLandscape || _vsSwipeTriggered) return;
        if (_vsPointerDownY == null || _vsPointerDownTime == null) return;
        final dy = event.position.dy - _vsPointerDownY!;
        final dt = DateTime.now().difference(_vsPointerDownTime!).inMilliseconds;
        if (dy > 60 && dt < 400) {
          _vsSwipeTriggered = true;
          _vsSwipeCount++;
          _vsSwipeTimer?.cancel();
          _vsSwipeTimer = Timer(const Duration(milliseconds: 900), () {
            _vsSwipeCount = 0;
          });
          if (_vsSwipeCount >= 2) {
            _vsSwipeCount = 0;
            _vsSwipeTimer?.cancel();
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
            setState(() => _isLandscape = true);
          }
        }
      },
      onPointerUp: (_) {
        _vsPointerDownY = null;
      },
      onPointerCancel: (_) {
        _vsPointerDownY = null;
      },
      child: WillPopScope(
      onWillPop: () async {
        final now = DateTime.now();
        if (_lastBackPressed == null || now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
          _lastBackPressed = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('再按一次退出程序'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return false;
        }
        return true;
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors.backgroundGradient,
          ),
        ),
        child: Stack(
          children: [
            Scaffold(
              backgroundColor: Colors.transparent,
              appBar: _isLandscape ? null : _buildAppBar(),
              body: _isLandscape
                  ? GestureDetector(
                      // 横屏：从右侧向左滑两次返回竖屏
                      onHorizontalDragStart: (details) {
                        _hsDragStartX = details.globalPosition.dx;
                      },
                      onHorizontalDragEnd: (details) {
                        final screenWidth = MediaQuery.of(context).size.width;
                        // 必须从屏幕右40%区域发起、且向左滑动
                        if (_hsDragStartX != null &&
                            _hsDragStartX! > screenWidth * 0.6 &&
                            details.velocity.pixelsPerSecond.dx < -600) {
                          _hsSwipeCount++;
                          _hsSwipeTimer?.cancel();
                          _hsSwipeTimer = Timer(const Duration(milliseconds: 800), () {
                            _hsSwipeCount = 0;
                          });
                          if (_hsSwipeCount >= 2) {
                            _hsSwipeCount = 0;
                            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                            SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
                            setState(() => _isLandscape = false);
                          }
                        }
                        _hsDragStartX = null;
                      },
                      child: const LandscapePerformanceGrid(),
                    )
                  : Column(
                children: [
                  _buildSearchBar(),
                  Expanded(
                    child: _loading
                        ? _buildLoadingView()
                        : (_err != null ? _buildErrorView() : (_res != null ? _buildResultView() : _buildHomeView())),
                  ),
                  _buildDisclaimer(),
                ],
              ),
            ),
            // 可拖拽悬浮"问"按钮（横屏隐藏）
            if (!_isLandscape) _buildDraggableFab(context),
          ],
        ),
      ),
    ),
    );
  }


  // ============ AppBar ============

  PreferredSizeWidget _buildAppBar() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AppBar(
      leading: _res != null
        ? IconButton(icon: Icon(Icons.arrow_back_ios_new, size: 22, color: colors.textPrimary), onPressed: _goBack)
        : IconButton(
            icon: Icon(Icons.star_border_outlined, color: colors.primary),
            onPressed: () => Navigator.push(context, _slideRoute(const FavoriteScreen())),
          ),
      actions: _res != null ? [
        IconButton(
          icon: Icon(_autoRefresh ? Icons.pause_circle : Icons.autorenew,
            color: _autoRefresh ? colors.primary : colors.textSecondary),
          onPressed: _toggleAutoRefresh,
        ),
        IconButton(icon: Icon(Icons.refresh, color: colors.textPrimary), onPressed: _refreshOnce),
      ] : [
        IconButton(
          icon: Icon(Icons.settings_outlined, size: 22, color: colors.textPrimary),
          onPressed: () => Navigator.push(context, _slideRoute(const SettingsScreen())),
        ),
      ],
      title: AnimatedBuilder(
        animation: _titleFadeCtrl,
        builder: (context, child) {
          final v = _titleFadeCtrl.value;
          final titleText = _res != null ? '分析结果' : '蓝图极智';
          // 左右拉开：scaleX 从 0 → 1，中心锚点
          final scaleX = Curves.easeOutBack.transform(v);
          // 整体透明度
          final opacity = Curves.easeOutQuart.transform((v / 0.3).clamp(0.0, 1.0));

          return Opacity(
            opacity: opacity,
            child: Transform(
              transform: Matrix4.identity()..scale(scaleX, 1.0, 1.0),
              alignment: Alignment.center,
              child: Text(
                titleText,
                style: AppText.h2.copyWith(
                    color: colors.textPrimary, fontWeight: FontWeight.w800),
              ),
            ),
          );
        },
      ),
      centerTitle: true,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors.backgroundGradient),
        ),
      ),
    );
  }

  // ============ 搜索栏 ============

  Widget _buildSearchBar() {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors.backgroundGradient),
        boxShadow: [BoxShadow(color: colors.primary.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, 4))],
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            // 筛选按钮
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.full),
                onTap: _openFilter,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Icon(Icons.tune, color: colors.primary, size: 22),
                ),
              ),
            ),
            // 输入框
            Expanded(
              child: TextField(
                controller: _ctrl,
                style: AppText.body1.copyWith(color: colors.textPrimary),
                decoration: InputDecoration(
                  hintText: '搜索代码 / 名称',
                  hintStyle: AppText.body2.copyWith(color: colors.textHint),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
              ),
            ),
            // 搜索按钮
            Container(
              margin: const EdgeInsets.all(AppSpacing.xs),
              child: Material(
                color: colors.primary,
                borderRadius: BorderRadius.circular(AppRadius.full),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  onTap: _search,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.search, color: Colors.white, size: 20),
                        const SizedBox(width: AppSpacing.xs),
                        Text('搜索', style: AppText.body2.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============ 空状态首页 ============

  Widget _buildHomeView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: AppSpacing.lg, right: AppSpacing.lg, bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 投资月历 - 可折叠
          _buildCollapsibleSection(
            title: '📅 A股板块趋势月历',
            isExpanded: _calendarExpanded,
            onTap: () => setState(() => _calendarExpanded = !_calendarExpanded),
            child: InvestmentCalendarWidget(api: _api),
          ),
          const SizedBox(height: AppSpacing.xl),

          // 热门板块 - 可折叠
          _buildCollapsibleSection(
            title: '🔥 热门板块',
            isExpanded: _sectorsExpanded,
            onTap: () {
              setState(() => _sectorsExpanded = !_sectorsExpanded);
            },
            onRefresh: _loadSectors,
            children: _buildSectorGrid(),
          ),
          const SizedBox(height: AppSpacing.xl),

          // 专家选股入口
          _buildExpertEntry(),
          const SizedBox(height: AppSpacing.xl),

          // 投资组合入口（二级菜单）
          _buildPortfolioEntry(),
          const SizedBox(height: AppSpacing.xl),

          // 实时资讯
          _buildCollapsibleSection(
            title: '📰 实时资讯',
            isExpanded: _newsExpanded,
            onTap: () => setState(() => _newsExpanded = !_newsExpanded),
            onRefresh: _loadNews,
            child: _buildNewsWidget(),
          ),
          const SizedBox(height: AppSpacing.xl),

          // 收益统计
          ExpertPerformanceWidget(),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  /// 可折叠区块组件（弹性动画风格）
  Widget _buildCollapsibleSection({
    required String title,
    required bool isExpanded,
    required VoidCallback onTap,
    VoidCallback? onRefresh,
    Widget? child,
    List<Widget>? children,
  }) {
    final colors = AppColors.of(context);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题栏（点击展开/折叠）
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              children: [
                // 展开/折叠图标
                AnimatedRotation(
                  turns: isExpanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                
                // 标题
                Text(
                  title,
                  style: AppText.h3.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                
                const Spacer(),
                
                // 刷新按钮（可选）
                if (onRefresh != null && isExpanded)
                  GestureDetector(
                    onTap: onRefresh,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh, size: 14, color: colors.primary),
                          const SizedBox(width: 4),
                          Text(
                            '刷新',
                            style: AppText.caption.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                
                // 展开/折叠状态提示
                Container(
                  margin: const EdgeInsets.only(left: AppSpacing.sm),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
                  decoration: BoxDecoration(
                    color: isExpanded
                      ? colors.primary.withOpacity(0.1)
                      : colors.surfaceVariant,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    isExpanded ? '收起' : '展开',
                    style: AppText.caption.copyWith(
                      color: isExpanded ? colors.primary : colors.textHint,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // 内容区域（普通展开动画）
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity, height: 0),
          secondChild: Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children ?? [child ?? const SizedBox()],
            ),
          ),
          crossFadeState: isExpanded
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
          firstCurve: Curves.easeInOut,
          secondCurve: Curves.easeInOut,
          sizeCurve: Curves.easeInOut,
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title, {VoidCallback? onRefresh}) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        children: [
          Text(title, style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (onRefresh != null)
            GestureDetector(
              onTap: onRefresh,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh, size: 14, color: colors.primary),
                    const SizedBox(width: AppSpacing.xs),
                    Text('刷新', style: AppText.hint.copyWith(color: colors.primary, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildSectorGrid() {
    final colors = AppColors.of(context);
    final markets = ['A股', '港股', '美股'];
    final marketColors = [AppColors.up, AppColors.warning, AppColors.primary];
    final icons = [Icons.show_chart, Icons.trending_up, Icons.public];

    return markets.asMap().entries.map((entry) {
      final idx = entry.key;
      final market = entry.value;
      final marketSectors = _sectors[market] ?? [];

      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [marketColors[idx].withOpacity(0.2), marketColors[idx].withOpacity(0.05)]),
                    borderRadius: BorderRadius.circular(AppRadius.full),
                    border: Border.all(color: marketColors[idx].withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icons[idx], size: 14, color: marketColors[idx]),
                      const SizedBox(width: AppSpacing.xs),
                      Text(market, style: AppText.caption.copyWith(color: marketColors[idx], fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _sectorsLoading
            ? SizedBox(height: 60, child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(colors.primary)))))
            : Row(
                children: List.generate(4, (i) {
                  if (i >= marketSectors.length) return Expanded(child: _buildSectorCell(null));
                  return Expanded(child: _buildSectorCell(marketSectors[i]));
                }),
              ),
        ],
      );
    }).toList();
  }

  Widget _buildSectorCell(Map<String, dynamic>? sector) {
    final colors = AppColors.of(context);
    if (sector == null) {
      return Container(
        margin: const EdgeInsets.all(AppSpacing.xs),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface.withOpacity(0.5),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: colors.border.withOpacity(0.5)),
        ),
        child: Column(children: [
          Text('--', style: AppText.caption.copyWith(color: colors.textHint)),
          const SizedBox(height: AppSpacing.xs),
          Text('--', style: AppText.caption.copyWith(color: colors.textHint, fontWeight: FontWeight.w600)),
        ]),
      );
    }

    final name = sector['name']?.toString() ?? '';
    final chg = sector['change_pct'] as double? ?? 0.0;
    final isUp = chg >= 0;
    final chgColor = isUp ? AppColors.up : AppColors.down;

    return GestureDetector(
      onTap: () => _onSectorTap(sector),
      child: Container(
        margin: const EdgeInsets.all(AppSpacing.xs),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: chgColor.withOpacity(0.2)),
        boxShadow: [BoxShadow(color: chgColor.withOpacity(0.06), blurRadius: 8)],
      ),
      child: Column(children: [
          Text(name, style: AppText.caption.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis, maxLines: 1),
          const SizedBox(height: AppSpacing.xs),
          Text('${isUp ? "+" : ""}${chg.toStringAsFixed(2)}%',
            style: AppText.caption.copyWith(color: chgColor, fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }

  Widget _buildExpertEntry() {
    final colors = AppColors.of(context);
    return GestureDetector(
      onTap: _onExpertTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [colors.expertEntryStart, colors.expertEntryEnd]),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: colors.primary.withOpacity(0.4)),
          boxShadow: AppShadow.glow,
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.primaryGradient),
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: AppShadow.button,
            ),
            child: const Icon(Icons.auto_awesome, color: Colors.white, size: 24),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('专家选股', style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
              const SizedBox(height: AppSpacing.xs),
              Text('五大策略 · 智能驱动 · 实时选股',
                style: AppText.caption.copyWith(color: colors.primaryLight)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.primaryGradient),
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: const Icon(Icons.arrow_forward, color: Colors.white, size: 18),
          ),
        ]),
      ),
    );
  }

  Widget _buildPortfolioEntry() {
    final colors = AppColors.of(context);
    final hotCount = _hotInvestService.portfolios.length;
    final liteCount = _liteInvestService.portfolios.length;
    final speedCount = _speedInvestService.portfolios.length;
    final totalCount = hotCount + liteCount + speedCount;

    final bool isDark = colors.textPrimary == Colors.white;

    // ── 紫金财富方案 ──
    // 深色模式
    const Color darkIconBgStart = Color(0xFFC8A15A);
    const Color darkIconBgEnd   = Color(0xFF9F7D3A);
    const Color darkBorder      = Color(0xFFB9975B);
    const Color darkButtonBg    = Color(0xFFD4B06A);
    const Color darkSubtitle    = Color(0xFFD4B06A);

    // 浅色模式 — 边框色加深以增强可见度
    const Color lightIconBgStart = Color(0xFFF9E3B4);
    const Color lightIconBgEnd   = Color(0xFFE7C98A);
    const Color lightBorder      = Color(0xFFD9AD5E);
    const Color lightButtonBg    = Color(0xFFD9AD5E);
    const Color lightSubtitle    = Color(0xFFB8862B);

    final iconBgStart = isDark ? darkIconBgStart : lightIconBgStart;
    final iconBgEnd   = isDark ? darkIconBgEnd   : lightIconBgEnd;
    final borderColor = isDark ? darkBorder      : lightBorder;
    final buttonBg    = isDark ? darkButtonBg    : lightButtonBg;
    final subtitleClr = isDark ? darkSubtitle    : lightSubtitle;

    return GestureDetector(
      onTap: _onPortfolioTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [colors.portfolioEntryStart, colors.portfolioEntryEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: borderColor.withOpacity(isDark ? 0.70 : 0.65), width: 1),
          boxShadow: [
            BoxShadow(
              color: borderColor.withOpacity(isDark ? 0.25 : 0.15),
              blurRadius: 20,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Row(children: [
          // 左侧 icon — 香槟金渐变背景
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [iconBgStart, iconBgEnd]),
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: [
                BoxShadow(
                  color: iconBgEnd.withOpacity(isDark ? 0.3 : 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(Icons.trending_up,
              color: isDark ? const Color(0xFF2A2318) : const Color(0xFF4A3728),
              size: 24),
          ),
          const SizedBox(width: AppSpacing.lg),
          // 中间文字
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('投资组合',
                style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
              const SizedBox(height: AppSpacing.xs),
              Text('热点 · 轻量 · 极速  |  多维策略',
                style: AppText.caption.copyWith(color: subtitleClr)),
            ]),
          ),
          // 右侧按钮 — 磨砂香槟金
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: buttonBg.withOpacity(isDark ? 0.85 : 0.90),
              borderRadius: BorderRadius.circular(AppRadius.full),
              boxShadow: [
                BoxShadow(
                  color: buttonBg.withOpacity(isDark ? 0.15 : 0.10),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(Icons.arrow_forward,
              color: isDark ? const Color(0xFF2A2318) : const Color(0xFF4A3728),
              size: 18),
          ),
        ]),
      ),
    );
  }

  /// 实时资讯列表
  Widget _buildNewsWidget() {
    final colors = AppColors.of(context);

    if (_newsLoading) {
      return SizedBox(
        height: 120,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(colors.primary)),
          ),
        ),
      );
    }

    if (_newsList.isEmpty) {
      return SizedBox(
        height: 80,
        child: Center(
          child: Text('暂无资讯', style: AppText.body2.copyWith(color: colors.textHint)),
        ),
      );
    }

    return Column(
      children: _newsList.asMap().entries.map((entry) {
        final index = entry.key;
        final news = entry.value;
        final title = news['title']?.toString() ?? '';
        final time = news['time']?.toString() ?? '';
        final formattedTime = NewsService.formatTime(time);

        return GestureDetector(
          onTap: () => _openNewsDetail(news),
          child: Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: colors.border.withOpacity(0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 编号（统一紫色风格）
                Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.only(top: 2, right: AppSpacing.sm),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [colors.primary.withOpacity(0.8), colors.primary.withOpacity(0.4)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: AppText.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                // 标题和时间
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppText.body2.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: [
                          Icon(Icons.access_time, size: 12, color: colors.textHint),
                          const SizedBox(width: 4),
                          Text(
                            formattedTime,
                            style: AppText.caption.copyWith(color: colors.textHint, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // 箭头
                Container(
                  margin: const EdgeInsets.only(left: AppSpacing.sm, top: 4),
                  child: Icon(Icons.chevron_right, size: 18, color: colors.textHint),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  void _openNewsDetail(Map<String, dynamic> news) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NewsDetailScreen(news: news)),
    );
  }

  // 快捷搜索已删除，替换为实时资讯模块

  // ============ 加载/错误 ============

  Widget _buildLoadingView() {
    final colors = AppColors.of(context);
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
        child: Column(children: [
          CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(colors.primary)),
          const SizedBox(height: AppSpacing.lg),
          Text('正在获取数据...', style: AppText.body2.copyWith(color: colors.textSecondary)),
        ]),
      ),
    ]));
  }

  Widget _buildErrorView() {
    final colors = AppColors.of(context);
    return Center(child: Padding(padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xl),
        decoration: BoxDecoration(
          color: colors.surface, borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: colors.error.withOpacity(0.3)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(color: colors.error.withOpacity(0.15), shape: BoxShape.circle),
            child: Icon(Icons.error_outline, size: 40, color: colors.error),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(_err ?? '未知错误', style: AppText.body2.copyWith(color: colors.textSecondary), textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.xl),
          Container(
            decoration: BoxDecoration(gradient: const LinearGradient(colors: AppColors.primaryGradient), borderRadius: BorderRadius.circular(AppRadius.full), boxShadow: AppShadow.button),
            child: ElevatedButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新搜索'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.transparent, elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.full))),
            ),
          ),
        ]),
      ),
    ));
  }

  // ============ 搜索结果页 ============

  Widget _buildResultView() {
    final r = _res!;
    final isFund = r['fund_type'] == 'fund';
    final ai = r['ai_analysis'] as Map<String, dynamic>? ?? {};
    final analysis = r['analysis'] as Map<String, dynamic>? ?? {};
    final action = ai['action'] ?? 'hold';
    final score = _d(ai['score']);
    final cp = _d(r['change_pct']);

    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(children: [
        _buildPriceHeader(r, isFund, ai, action, score, cp),
        const SizedBox(height: AppSpacing.md),
        _buildAiSummaryCard(ai, score),
        const SizedBox(height: AppSpacing.md),
        ..._buildAnalysisModules(analysis),
        const SizedBox(height: AppSpacing.sm),
        if (analysis['company_profile'] != null)
          _buildAnalysisCard(analysis['company_profile'] as Map<String, dynamic>),
        const SizedBox(height: AppSpacing.sm),
        _buildRiskCard(ai),
        const SizedBox(height: AppSpacing.xxl),
      ]),
    );
  }

  List<Widget> _buildAnalysisModules(Map<String, dynamic> analysis) {
    const keys = ['price', 'volume', 'volatility', 'trend', 'bid_ask',
                   'valuation', 'momentum', 'support_resistance', 'capital_flow',
                   'pre_market', 'ai_detailed'];
    return keys.where((k) => analysis[k] != null)
      .map((k) => Padding(padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: _buildAnalysisCard(analysis[k] as Map<String, dynamic>))).toList();
  }

  // ============ 价格头部 ============

  Widget _buildPriceHeader(Map<String, dynamic> r, bool isFund, Map<String, dynamic> ai, String action, double score, double cp) {
    final colors = AppColors.of(context);
    final pc = getPriceColor(cp);
    final ac = ActionStyle.getColor(action);
    final market = r['market']?.toString() ?? '';
    final isHK = market == 'HK';
    final isUS = market == 'US';
    
    // 根据市场选择货币符号和价格精度
    String currencySymbol;
    int pricePrecision;
    if (isFund) {
      currencySymbol = '净值';
      pricePrecision = 4;
    } else if (isHK) {
      currencySymbol = 'HK\$';
      pricePrecision = 3;
    } else if (isUS) {
      currencySymbol = '\$';
      pricePrecision = 2;
    } else {
      currencySymbol = '¥';
      pricePrecision = 2;
    }
    final priceStr = _d(r['price']).toStringAsFixed(pricePrecision);
    final changeAmt = _d(r['change_amt']);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [colors.priceHeaderStart, colors.priceHeaderEnd]),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: pc.withOpacity(0.3)),
        boxShadow: [BoxShadow(color: pc.withOpacity(0.1), blurRadius: 20)],
      ),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 第一行：名称 + 操作标签
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r['name'] ?? '', style: AppText.h1.copyWith(color: colors.textPrimary)),
            const SizedBox(height: AppSpacing.xs),
            Row(children: [
              Text(r['symbol'] ?? '', style: AppText.caption.copyWith(color: colors.textHint)),
              if (market.isNotEmpty) ...[
                const SizedBox(width: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [colors.primary.withOpacity(0.2), colors.accent.withOpacity(0.1)]),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(market, style: AppText.hint.copyWith(color: colors.primaryLight, fontWeight: FontWeight.w700)),
                ),
              ],
            ],),
          ])),
          IconButton(
            icon: Icon(_isFavorite ? Icons.star : Icons.star_border,
              color: _isFavorite ? AppColors.warning : colors.textSecondary),
            onPressed: () => _toggleFavorite(r),
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl, vertical: AppSpacing.md),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [ac.withOpacity(0.3), ac.withOpacity(0.1)]),
              borderRadius: BorderRadius.circular(AppRadius.full),
              border: Border.all(color: ac.withOpacity(0.4)),
            ),
            child: Text(ActionStyle.getLabel(action), style: AppText.h3.copyWith(color: ac, fontWeight: FontWeight.w900)),
          ),
        ]),
        const SizedBox(height: AppSpacing.xl),

        // 第二行：价格
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$currencySymbol$priceStr',
            style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: pc, letterSpacing: -1)),
          const SizedBox(width: AppSpacing.md),
          Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${cp >= 0 ? "+" : ""}${cp.toStringAsFixed(2)}%', style: AppText.h2.copyWith(color: pc, fontWeight: FontWeight.w700)),
            if (changeAmt != 0) Text('${changeAmt >= 0 ? "+" : ""}${changeAmt.toStringAsFixed(isHK || isUS ? 3 : 2)}',
              style: AppText.caption.copyWith(color: pc)),
          ])),
          const Spacer(),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('AI评分', style: AppText.hint.copyWith(color: colors.textHint)),
            Text('${(score * 100).toStringAsFixed(0)}',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: getScoreColor(score))),
          ]),
        ]),
        const SizedBox(height: AppSpacing.xl),

        // 第三行：关键指标
        Wrap(spacing: AppSpacing.lg, runSpacing: AppSpacing.sm, children: [
          _miniInfo('开盘', _fmtPriceByMarket(r['open'], market)),
          _miniInfo('最高', _fmtPriceByMarket(r['high'], market)),
          _miniInfo('最低', _fmtPriceByMarket(r['low'], market)),
          _miniInfo('昨收', _fmtPriceByMarket(r['prev_close'], market)),
          if (r['volume'] != null && !isFund) _miniInfo('量', _fmtVol(_safeInt(r['volume']))),
          if (r['amount'] != null) _miniInfo('额', _fmtAmt(_safeDouble(r['amount']))),
          if (r['market_cap_display'] != null) _miniInfo('市值', r['market_cap_display'].toString()),
          if (r['pe_ratio'] != null) _miniInfo('PE', r['pe_ratio'].toString()),
          if (r['turnover_rate'] != null) _miniInfo('换手', '${r['turnover_rate']}%'),
          _miniInfo('股息', r['dividend_yield'] != null ? '${r['dividend_yield']}%' : '0%'),
        ]),
      ]),
    );
  }

  // ============ AI综合评分卡 ============

  Widget _buildAiSummaryCard(Map<String, dynamic> ai, double score) {
    final colors = AppColors.of(context);
    final detail = ai['detail'] as Map<String, dynamic>? ?? {};
    final reason = ai['reason'] ?? '';
    final wr = _d(ai['short_term_win_rate']);
    final trend = ai['trend'] ?? 'neutral';

    return Container(
      decoration: BoxDecoration(
        color: colors.surface, borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.primary.withOpacity(0.2)),
        boxShadow: AppShadow.card,
      ),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.primaryGradient),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text('极智分析', style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: AppSpacing.xl),

        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _circleIndicator('综合评分', '${(score * 100).toStringAsFixed(0)}', getScoreColor(score)),
          _circleIndicator('短线胜率', '${(wr * 100).toStringAsFixed(0)}%', colors.primary),
          _circleIndicator('趋势', TrendStyle.getLabel(trend), TrendStyle.getColor(trend)),
        ]),
        const SizedBox(height: AppSpacing.xl),

        if (detail.isNotEmpty) ...[
          _scoreBar('基本面', _d(detail['fundamental_score'])),
          const SizedBox(height: AppSpacing.sm),
          _scoreBar('技术面', _d(detail['technical_score'])),
          const SizedBox(height: AppSpacing.sm),
          _scoreBar('资金面', _d(detail['capital_score'])),
          const SizedBox(height: AppSpacing.sm),
          _scoreBar('动量面', _d(detail['momentum_score'])),
          const SizedBox(height: AppSpacing.lg),
        ],

        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: colors.primaryContainer, borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lightbulb, size: 18, color: colors.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(reason, style: AppText.body2.copyWith(color: colors.textSecondary, height: 1.5))),
          ]),
        ),
      ]),
    );
  }

  // ============ 通用分析卡片 ============

  Widget _buildAnalysisCard(Map<String, dynamic> a) {
    return _ExpandableCard(
      title: a['title'] ?? '', icon: _analysisIcon(a['icon'] ?? ''),
      sentiment: a['sentiment'] ?? '', score: _d(a['score']),
      items: (a['items'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v.toString())),
      advice: a['advice'] ?? '', extraNote: a['extra_note'] ?? '',
      stockData: _res, moduleKey: a['icon'] ?? '',
    );
  }

  // ============ 风险卡片 ============

  Widget _buildRiskCard(Map<String, dynamic> ai) {
    final colors = AppColors.of(context);
    final risks = (ai['risk'] ?? ['市场系统性风险不可忽视']) as List;
    return Container(
      decoration: BoxDecoration(
        color: colors.riskCardBg, borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.warning.withOpacity(0.3)),
      ),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(color: AppColors.warning.withOpacity(0.15), borderRadius: BorderRadius.circular(AppRadius.sm)),
            child: Icon(Icons.warning_amber, color: AppColors.warning, size: 18),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text('风险提示', style: AppText.h2.copyWith(color: colors.textPrimary)),
        ]),
        const SizedBox(height: AppSpacing.md),
        ...risks.map((x) => Padding(padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(margin: const EdgeInsets.only(top: 6), width: 6, height: 6,
              decoration: BoxDecoration(color: AppColors.warning, shape: BoxShape.circle)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(x.toString(), style: AppText.body2.copyWith(color: colors.textSecondary, height: 1.5))),
          ]),
        )),
      ]),
    );
  }

  // ============ 小组件 ============

  Widget _miniInfo(String label, String value) {
    final colors = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.hint.copyWith(color: colors.textHint)),
      const SizedBox(height: AppSpacing.xs),
      Text(value, style: AppText.caption.copyWith(color: colors.textSecondary, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _circleIndicator(String label, String val, Color c) {
    final colors = AppColors.of(context);
    return Column(children: [
      Container(
        width: 68, height: 68,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [c.withOpacity(0.3), c.withOpacity(0.1)]),
          border: Border.all(color: c.withOpacity(0.6), width: 2.5),
        ),
        child: Center(child: FittedBox(child: Text(val, style: AppText.body1.copyWith(color: c, fontWeight: FontWeight.w800)))),
      ),
      const SizedBox(height: AppSpacing.xs),
      Text(label, style: AppText.hint.copyWith(color: colors.textHint)),
    ]);
  }

  Widget _scoreBar(String label, double v) {
    final colors = AppColors.of(context);
    v = v.clamp(0.0, 1.0);
    return Row(children: [
      SizedBox(width: 52, child: Text(label, style: AppText.caption.copyWith(color: colors.textSecondary))),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.full),
          child: LinearProgressIndicator(
            value: v, backgroundColor: colors.surfaceVariant, minHeight: 8,
            valueColor: AlwaysStoppedAnimation(getScoreColor(v)),
          ),
        ),
      ),
      const SizedBox(width: AppSpacing.sm),
      SizedBox(width: 40, child: Text('${(v * 100).toStringAsFixed(0)}%',
        style: AppText.caption.copyWith(color: getScoreColor(v), fontWeight: FontWeight.w700))),
    ]);
  }

  Widget _buildDisclaimer() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(color: AppColors.warning.withOpacity(0.06)),
      child: Row(children: [
        Icon(Icons.shield_outlined, size: 14, color: AppColors.warning),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text('本工具仅供参考，不构成投资建议。投资有风险，入市需谨慎。',
          style: AppText.hint.copyWith(color: AppColors.warning.withOpacity(0.8)))),
      ]),
    );
  }

  // ============ 工具方法 ============

  IconData _analysisIcon(String type) {
    switch (type) {
      case 'price': return Icons.attach_money;
      case 'volume': return Icons.bar_chart;
      case 'volatility': return Icons.show_chart;
      case 'bid_ask': return Icons.swap_vert;
      case 'trend': return Icons.trending_up;
      case 'valuation': return Icons.assessment;
      case 'momentum': return Icons.speed;
      case 'support': return Icons.vertical_align_center;
      case 'schedule': return Icons.schedule;
      case 'capital_flow': return Icons.account_balance;
      case 'psychology': return Icons.psychology;
      default: return Icons.analytics;
    }
  }

  double _d(v) { if (v == null) return 0.0; if (v is double) return v; if (v is int) return v.toDouble(); return double.tryParse(v.toString()) ?? 0.0; }
  int _safeInt(v) { if (v == null) return 0; if (v is int) return v; if (v is double) return v.toInt(); return 0; }
  double _safeDouble(v) { if (v == null) return 0.0; if (v is double) return v; if (v is int) return v.toDouble(); return 0.0; }
  String _fmtVal(v) => v == null ? '--' : (v is double ? v.toStringAsFixed(2) : v.toString());

  // 根据市场类型格式化价格
  String _fmtPriceByMarket(dynamic v, String market) {
    if (v == null) return '--';
    final d = _safeDouble(v);
    if (d == 0 && v.toString() != '0') return v.toString();
    if (market == 'HK') return d.toStringAsFixed(3);
    if (market == 'US') return d.toStringAsFixed(2);
    return d.toStringAsFixed(2);
  }
  String _fmtVol(int v) { if (v <= 0) return '--'; if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万手'; return '$v手'; }
  String _fmtAmt(double v) { if (v <= 0) return '--'; if (v >= 1e8) return '${(v / 1e8).toStringAsFixed(1)}亿'; if (v >= 1e4) return '${(v / 1e4).toStringAsFixed(0)}万'; return v.toStringAsFixed(0); }
}

// ============ 可展开分析卡片 ============

class _ExpandableCard extends StatefulWidget {
  final String title; final IconData icon; final String sentiment;
  final double score; final Map<String, String> items;
  final String advice; final String extraNote;
  final Map<String, dynamic>? stockData;
  final String moduleKey;

  const _ExpandableCard({
    required this.title, required this.icon, required this.sentiment,
    required this.score, required this.items, required this.advice, required this.extraNote,
    this.stockData, this.moduleKey = '',
  });
  @override
  State<_ExpandableCard> createState() => _ExpandableCardState();
}

class _ExpandableCardState extends State<_ExpandableCard> with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _controller;
  late Animation<double> _rotation;

  // 云端AI分析相关状态
  bool _isLoadingAI = false;
  String? _cloudAIAdvice;
  Map<String, dynamic>? _cloudAIResult;
  final StockDeepAnalysisService _aiService = StockDeepAnalysisService();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 300), vsync: this);
    _rotation = Tween<double>(begin: 0, end: 0.5).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  // 判断是否为极智深度分析模块
  bool get _isDeepAnalysisModule => widget.moduleKey == 'psychology' || widget.title == '极智深度分析';

  // 是否已有云端AI结果
  bool get _hasCloudAIResult => _cloudAIResult?['is_cloud_ai'] == true;

  // 展开时触发云端AI分析
  void _onExpandChanged(bool expanded) {
    setState(() => _expanded = expanded);
    if (expanded) {
      _controller.forward();
      if (_isDeepAnalysisModule && !_hasCloudAIResult && widget.stockData != null && _cloudAIResult == null) {
        _fetchCloudAIAnalysis();
      }
    } else {
      _controller.reverse();
    }
  }

  // 调用云端AI进行深度分析
  Future<void> _fetchCloudAIAnalysis() async {
    if (_isLoadingAI || widget.stockData == null) return;
    setState(() => _isLoadingAI = true);
    try {
      final result = await _aiService.analyzeStock(widget.stockData!);
      if (mounted) {
        setState(() {
          _cloudAIResult = result;
          _cloudAIAdvice = result['advice'] as String?;
          _isLoadingAI = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingAI = false;
          _cloudAIAdvice = '极智云端分析暂时不可用';
        });
      }
    }
  }

  String get _displayAdvice => _cloudAIAdvice ?? widget.advice;
  Map<String, String> get _displayItems {
    if (_cloudAIResult != null) {
      final items = _cloudAIResult!['items'] as Map<String, dynamic>? ?? {};
      return items.map((k, v) => MapEntry(k, v.toString()));
    }
    return widget.items;
  }
  double get _displayScore => (_cloudAIResult?['score'] as num?)?.toDouble() ?? widget.score;
  String get _displaySentiment => _cloudAIResult?['sentiment'] as String? ?? widget.sentiment;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final scoreColor = AppColors.getScoreColor(_displayScore);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: _expanded ? colors.primary.withOpacity(0.4) : colors.border.withOpacity(0.5)),
        boxShadow: _expanded ? AppShadow.card : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () => _onExpandChanged(!_expanded),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [scoreColor.withOpacity(0.2), scoreColor.withOpacity(0.05)]),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(widget.icon, color: scoreColor, size: 18),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(widget.title,
                  style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                  decoration: BoxDecoration(
                    color: scoreColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(_displaySentiment, style: AppText.caption.copyWith(color: scoreColor, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('${(_displayScore * 100).toStringAsFixed(0)}',
                  style: AppText.h2.copyWith(color: scoreColor, fontWeight: FontWeight.w800)),
                RotationTransition(
                  turns: _rotation,
                  child: Icon(Icons.expand_more, color: colors.textSecondary),
                ),
              ]),
              if (_expanded) ...[
                const SizedBox(height: AppSpacing.lg),
                const Divider(color: AppColors.divider, height: 1),
                const SizedBox(height: AppSpacing.lg),
                if (_isDeepAnalysisModule && _isLoadingAI) ...[
                  Center(child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Column(children: [
                      SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3, valueColor: AlwaysStoppedAnimation(colors.primary))),
                      const SizedBox(height: AppSpacing.md),
                      Text('极智云端分析中...', style: AppText.body2.copyWith(color: colors.textSecondary)),
                    ]),
                  )),
                ] else ...[
                  if (_displayItems.isNotEmpty) ...[
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: _displayItems.entries.map((e) => SizedBox(
                        width: (MediaQuery.of(context).size.width - AppSpacing.xl * 2 - AppSpacing.sm) / 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.key, style: AppText.caption.copyWith(color: colors.textHint, fontSize: 11)),
                            const SizedBox(height: 2),
                            Text(e.value, style: AppText.body2.copyWith(
                              color: _itemValueColor(e.key, e.value, colors),
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            )),
                          ],
                        ),
                      )).toList(),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.xs),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: AppColors.primaryGradient),
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                          ),
                          child: const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text('极智解读', style: AppText.caption.copyWith(color: colors.primary, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        if (_isDeepAnalysisModule && _hasCloudAIResult)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: AppColors.success.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.cloud_done, size: 12, color: AppColors.success),
                              const SizedBox(width: 4),
                              Text('云端AI', style: AppText.caption.copyWith(color: AppColors.success, fontSize: 10)),
                            ]),
                          ),
                      ]),
                      const SizedBox(height: AppSpacing.sm),
                      // 使用可滚动容器包裹长文本，设置最大高度防止溢出
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 500),
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          child: SelectableText(_displayAdvice, style: AppText.body2.copyWith(color: colors.textSecondary, height: 1.6)),
                        ),
                      ),
                      if (widget.extraNote.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(widget.extraNote, style: AppText.caption.copyWith(color: colors.textHint, height: 1.5)),
                      ],
                      if (_isDeepAnalysisModule && !_hasCloudAIResult && !_isLoadingAI && _cloudAIResult == null) ...[
                        const SizedBox(height: AppSpacing.md),
                        InkWell(
                          onTap: _fetchCloudAIAnalysis,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: AppColors.primaryGradient),
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.cloud_sync, size: 14, color: Colors.white),
                              const SizedBox(width: 6),
                              Text('调用云端AI深度分析', style: AppText.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        ),
                      ],
                    ]),
                  ),
                ],
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Color _itemValueColor(String key, String value, AppColorScheme colors) {
    if (key == 'ROE' || key == '营收增速' || key == '毛利率') {
      final v = double.tryParse(value.replaceAll(RegExp(r'[+%倍]'), '')) ?? 0;
      if (v > 0) return AppColors.up;
      if (v < 0) return AppColors.down;
    }
    if (key == 'PE') {
      final v = double.tryParse(value.replaceAll(RegExp(r'[倍]'), '')) ?? 0;
      if (v > 0 && v < 15) return AppColors.up;
      if (v > 40) return AppColors.down;
    }
    return colors.textSecondary;
  }
}

// ============================================================
// 悬浮按钮 — 动画组件
// ============================================================