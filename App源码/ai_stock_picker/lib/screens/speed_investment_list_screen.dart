/// 极速投资列表页
///
/// T+1买入/T+2卖出，每交易日20:00自动选股

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../theme/app_theme.dart';
import '../theme/app_text.dart';
import '../services/speed_investment_service.dart';
import '../services/jianguoyun_service.dart';
import '../models/speed_investment_model.dart';
import '../utils/trading_day_utils.dart';
import '../widgets/investment_return_calendar_widget.dart';
import 'speed_investment_detail_screen.dart';

/// 获取组合显示日期
/// 业务规则：极速组合的"日期"显示**buyDate 的前一个交易日**（即实际选股创建日）。
/// 由于部分旧数据 createTime 被错误记录为 buyDate/卖出日，直接取 buyDate 上一交易日
/// 可以稳定还原用户感知的"选股日期"，并自动跳过周末/节假日。
String _portfolioDisplayDate(dynamic portfolio) {
  if (portfolio == null) return '?';
  final bd = portfolio.buyDate as DateTime;
  final prev = TradingDayUtils.getPreviousTradingDay(bd);
  return '${prev.month}/${prev.day}';
}

class SpeedInvestmentListScreen extends StatefulWidget {
  final SpeedInvestmentService service;

  const SpeedInvestmentListScreen({Key? key, required this.service}) : super(key: key);

  @override
  State<SpeedInvestmentListScreen> createState() => _SpeedInvestmentListScreenState();
}

class _SpeedInvestmentListScreenState extends State<SpeedInvestmentListScreen> {
  bool _uploading = false;
  bool _downloading = false;
  bool _jgyUploading = false;
  bool _jgyDownloading = false;
  bool _exporting = false;
  bool _importing = false;
  bool _creating = false;
  bool _activating = false;

  SpeedInvestmentService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _service.init();
    // 自动检查并创建今日组合（若在交易日前夜20:00后）
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) _autoCreateIfNeeded();
    });
    // 自动激活pending组合（T日09:30后按实际价买入）
    // 在交易时段每30秒重试，直到所有pending都被激活
    _startAutoActivateRetry();
    // 自动结算sellDate=今天的active组合（T+1日09:30卖出）
    _startAutoSettleRetry();
  }

  Timer? _activateRetryTimer;
  Timer? _settleRetryTimer;

  void _startAutoActivateRetry() {
    _activateRetryTimer?.cancel();
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      final now = DateTime.now();
      final minutes = now.hour * 60 + now.minute;
      // 交易时段 09:30~15:05 才尝试激活
      if (minutes >= 9 * 60 + 30 && minutes <= 15 * 60 + 5) {
        // 校验：只激活buyDate=今天的pending组合
        final today = DateTime(now.year, now.month, now.day);
        final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
        final hasTodayPending = _service.portfolios.any((p) {
          if (p.status != SpeedPortfolioStatus.pending) return false;
          final buyDateStr = '${p.buyDate.year}-${p.buyDate.month.toString().padLeft(2, '0')}-${p.buyDate.day.toString().padLeft(2, '0')}';
          return buyDateStr == todayStr;
        });
        if (!hasTodayPending) return; // 没有今天该激活的，不浪费请求

        _tryActivate().then((_) {
          if (!mounted) return;
          final stillPending = _service.portfolios.any((p) {
            if (p.status != SpeedPortfolioStatus.pending) return false;
            final buyDateStr = '${p.buyDate.year}-${p.buyDate.month.toString().padLeft(2, '0')}-${p.buyDate.day.toString().padLeft(2, '0')}';
            return buyDateStr == todayStr;
          });
          if (stillPending) {
            _activateRetryTimer = Timer(const Duration(seconds: 30), () {
              if (mounted) _startAutoActivateRetry();
            });
          }
        });
      }
    });
  }

  /// T+2结算轮询：交易时段内检查sellDate=今天的active组合，自动卖出结算
  void _startAutoSettleRetry() {
    _settleRetryTimer?.cancel();
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      final now = DateTime.now();
      final minutes = now.hour * 60 + now.minute;
      if (minutes >= 9 * 60 + 30 && minutes <= 15 * 60 + 5) {
        final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final hasTodaySettleable = _service.portfolios.any((p) {
          if (p.status != SpeedPortfolioStatus.active) return false;
          final sellDateStr = '${p.sellDate.year}-${p.sellDate.month.toString().padLeft(2, '0')}-${p.sellDate.day.toString().padLeft(2, '0')}';
          return sellDateStr == todayStr;
        });
        if (!hasTodaySettleable) return;

        _trySettle().then((_) {
          if (!mounted) return;
          // 检查是否还有未结算的
          final stillSettleable = _service.portfolios.any((p) {
            if (p.status != SpeedPortfolioStatus.active) return false;
            final sellDateStr = '${p.sellDate.year}-${p.sellDate.month.toString().padLeft(2, '0')}-${p.sellDate.day.toString().padLeft(2, '0')}';
            return sellDateStr == todayStr;
          });
          if (stillSettleable) {
            _settleRetryTimer = Timer(const Duration(seconds: 60), () {
              if (mounted) _startAutoSettleRetry();
            });
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _activateRetryTimer?.cancel();
    _settleRetryTimer?.cancel();
    super.dispose();
  }

  Future<void> _tryActivate() async {
    final pending = _service.portfolios.where((p) => p.status == SpeedPortfolioStatus.pending).toList();
    if (pending.isEmpty) return;
    debugPrint('[极速投资] 尝试激活${pending.length}个待买入组合');
    final count = await _service.tryAutoActivate();
    if (mounted && count > 0) setState(() {});
  }

  /// 手动触发买入（不校验buyDate，直接激活所有pending组合）
  Future<void> _manualActivate() async {
    setState(() => _activating = true);
    try {
      final pending = _service.portfolios.where((p) => p.status == SpeedPortfolioStatus.pending).toList();
      if (pending.isEmpty) return;
      debugPrint('[极速投资] 手动激活${pending.length}个组合');
      final count = await _service.activateAllPending();
      if (mounted) {
        if (count > 0) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✅ 成功买入 $count 个组合'),
            behavior: SnackBarBehavior.floating,
          ));
          setState(() {});
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('❌ 买入失败：无法获取行情数据'),
            behavior: SnackBarBehavior.floating,
          ));
        }
      }
    } finally {
      if (mounted) setState(() => _activating = false);
    }
  }

  Future<void> _trySettle() async {
    final todayStr = '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}';
    final settleable = _service.portfolios.where((p) {
      if (p.status != SpeedPortfolioStatus.active) return false;
      final sellDateStr = '${p.sellDate.year}-${p.sellDate.month.toString().padLeft(2, '0')}-${p.sellDate.day.toString().padLeft(2, '0')}';
      return sellDateStr == todayStr;
    }).toList();
    if (settleable.isEmpty) return;
    debugPrint('[极速投资] 尝试结算${settleable.length}个待卖出组合');
    final count = await _service.tryAutoSettle();
    if (mounted && count > 0) setState(() {});
  }

  Future<void> _autoCreateIfNeeded() async {
    // 业务规范：每个交易日20:00自动选股（为下一个交易日准备组合）
    // 条件：明天是交易日（选股必须在交易日前一天晚上20:00后进行）
    // 同时也覆盖"今天非交易日+明天是交易日"的周末/假期过渡场景
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));
    final tomorrowDate = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    if (!TradingDayUtils.isSecuritiesTradingDay(tomorrowDate)) return;

    // 时间窗口：20:00之后才允许自动选股（避免盘中误触发）
    final minutes = now.hour * 60 + now.minute;
    if (minutes < 20 * 60) return;

    // 检查是否已有为明天准备的组合（避免重复）
    final tomorrowStr = '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    final hasForTomorrow = _service.portfolios.any((p) {
      final pBuyDate = p.buyDate;
      final pBuyStr = '${pBuyDate.year}-${pBuyDate.month.toString().padLeft(2, '0')}-${pBuyDate.day.toString().padLeft(2, '0')}';
      return pBuyStr == tomorrowStr && p.status != SpeedPortfolioStatus.settled;
    });
    if (hasForTomorrow) return;

    debugPrint('[极速投资] 自动创建组合（明天交易日${tomorrowStr}）');
    await _service.createDailyPortfolio();
    if (mounted) setState(() {});
  }
  // ========== 云端备份 ==========

  Future<void> _uploadToCloud() async {
    setState(() => _uploading = true);
    try {
      final result = await _service.uploadToCloud();
      if (mounted) _showResult(result['ok'] == true, result['error']?.toString() ?? '', '上传');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _downloadFromCloud() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _confirmDialog('确认下载', '云端数据将覆盖本地极速投资数据，是否继续？'),
    );
    if (confirmed != true) return;
    setState(() => _downloading = true);
    try {
      final result = await _service.downloadFromCloud();
      if (mounted) {
        _showResult(result['ok'] == true, result['error']?.toString() ?? '', '下载');
        if (result['ok'] == true) setState(() {});
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // ========== 坚果云 ==========

  Future<void> _uploadToJianguoyun() async {
    setState(() => _jgyUploading = true);
    try {
      final result = await _service.uploadToJianguoyun();
      if (mounted) _showResult(result['ok'] == true, result['error']?.toString() ?? '', '坚果云上传');
    } finally {
      if (mounted) setState(() => _jgyUploading = false);
    }
  }

  Future<void> _downloadFromJianguoyun() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _confirmDialog('确认下载', '坚果云数据将覆盖本地极速投资数据，是否继续？'),
    );
    if (confirmed != true) return;
    setState(() => _jgyDownloading = true);
    try {
      final result = await _service.downloadFromJianguoyun();
      if (mounted) {
        _showResult(result['ok'] == true, result['error']?.toString() ?? '', '坚果云下载');
        if (result['ok'] == true) setState(() {});
      }
    } finally {
      if (mounted) setState(() => _jgyDownloading = false);
    }
  }

  // ========== 本地备份 ==========

  Future<void> _exportToLocal() async {
    setState(() => _exporting = true);
    try {
      final jsonStr = _service.exportToLocalJson();
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
            width: double.maxFinite, height: 300,
            child: SingleChildScrollView(
              child: SelectableText(jsonStr, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFCCCCCC))),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('关闭', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _importFromLocal() async {
    final colors = AppColors.of(context);
    final controller = TextEditingController();
    final jsonStr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(children: [
          Icon(Icons.file_upload, color: colors.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(child: Text('导入本地备份', style: AppText.h3.copyWith(color: colors.textPrimary))),
        ]),
        content: SizedBox(
          width: double.maxFinite, height: 300,
          child: TextField(
            controller: controller,
            maxLines: null, expands: true,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFCCCCCC)),
            decoration: InputDecoration(
              hintText: '粘贴JSON备份数据...',
              hintStyle: TextStyle(color: colors.textHint, fontSize: 11),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: colors.border)),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
            child: const Text('确认导入', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (jsonStr == null || jsonStr.isEmpty) return;
    setState(() => _importing = true);
    try {
      final result = await _service.importFromLocalJson(jsonStr);
      if (mounted) {
        _showResult(result['ok'] == true, result['error']?.toString() ?? '', '导入');
        if (result['ok'] == true) setState(() {});
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  // ========== 选股 ==========

  Future<void> _createPortfolio() async {
    setState(() => _creating = true);
    try {
      final portfolio = await _service.createDailyPortfolio();
      if (mounted) {
        if (portfolio != null) {
          _showResult(true, '', '选股');
          setState(() {});
        } else {
          _showResult(false, '选股失败：明天不是交易日或已过选股时间（需在交易日前夜20:00后选股）', '选股');
        }
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// 确认删除组合
  Future<void> _confirmDelete(SpeedPortfolio p) async {
    final statusLabel = p.status == SpeedPortfolioStatus.pending ? '待买入'
        : p.status == SpeedPortfolioStatus.active ? '持仓中'
        : '已结算';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.of(context).surface,
        title: Text('确认删除', style: AppText.h3.copyWith(color: AppColors.of(context).textPrimary)),
        content: Text('确定要删除"极速组合 ${_portfolioDisplayDate(p)}"（$statusLabel）吗？\n此操作不可撤销。', style: AppText.body2.copyWith(color: AppColors.of(context).textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: AppText.body2.copyWith(color: AppColors.of(context).textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.deletePortfolio(p.id);
      if (mounted) setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ 组合已删除'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _showResult(bool ok, String error, String action) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '✅ $action成功' : '❌ $action失败: $error'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Widget _confirmDialog(String title, String content) {
    final c = AppColors.of(context);
    return AlertDialog(
      backgroundColor: c.surface,
      title: Text(title, style: AppText.h3.copyWith(color: c.textPrimary)),
      content: Text(content, style: AppText.body2.copyWith(color: c.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text('取消', style: AppText.body2.copyWith(color: c.textSecondary))),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: c.hotInvestAccent),
          child: const Text('确认', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final pending = _service.portfolios.where((p) => p.status == SpeedPortfolioStatus.pending).toList();
    final active = _service.portfolios.where((p) => p.status == SpeedPortfolioStatus.active).toList();
    final settled = _service.portfolios.where((p) => p.status == SpeedPortfolioStatus.settled).toList();

    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 20), onPressed: () => Navigator.pop(context)),
          title: Text('极速投资', style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
          centerTitle: true,
          flexibleSpace: Container(decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient))),
          actions: [
            Row(
              children: [
                IconButton(
                  icon: _jgyUploading ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.cloud_sync, color: Colors.amber.shade700),
                  iconSize: 14, constraints: const BoxConstraints(minWidth: 28, minHeight: 28), padding: EdgeInsets.zero,
                  onPressed: _jgyUploading ? null : _uploadToJianguoyun,
                  tooltip: '上传到坚果云',
                ),
                IconButton(
                  icon: _jgyDownloading ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.cloud_done, color: Colors.amber.shade700),
                  iconSize: 14, constraints: const BoxConstraints(minWidth: 28, minHeight: 28), padding: EdgeInsets.zero,
                  onPressed: _jgyDownloading ? null : _downloadFromJianguoyun,
                  tooltip: '从坚果云下载',
                ),
                IconButton(
                  icon: _exporting ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.file_download, color: colors.primary),
                  iconSize: 14, constraints: const BoxConstraints(minWidth: 28, minHeight: 28), padding: EdgeInsets.zero,
                  onPressed: _exporting ? null : _exportToLocal,
                  tooltip: '导出本地备份',
                ),
                IconButton(
                  icon: _importing ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.file_upload, color: colors.primary),
                  iconSize: 14, constraints: const BoxConstraints(minWidth: 28, minHeight: 28), padding: EdgeInsets.zero,
                  onPressed: _importing ? null : _importFromLocal,
                  tooltip: '导入本地备份',
                ),
              ],
            ),
          ],
        ),
        body: Column(children: [
          // 非交易日提示（顶部细条）
          if (!TradingDayUtils.isSecuritiesTradingDay(DateTime.now()))
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              color: Colors.orange.withOpacity(0.1),
              child: Row(children: [
                const Icon(Icons.info_outline, color: Colors.orange, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text('今日非交易日，交易日前夜 20:00 后可一键选股',
                    style: TextStyle(color: Colors.orange.shade700, fontSize: 11))),
              ]),
            ),
          Expanded(
            child: _service.portfolios.isEmpty
              ? _buildEmptyState(colors)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // 待激活组合
                    if (pending.isNotEmpty) ...[
                      _buildSectionHeader('待激活', pending.length, colors),
                      const SizedBox(height: AppSpacing.md),
                      // 手动买入按钮
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _activating ? null : _manualActivate,
                            style: ElevatedButton.styleFrom(
                              primary: colors.speedInvestAccent,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                            ),
                            icon: _activating
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.flash_on, color: Colors.white, size: 18),
                            label: Text(_activating ? '买入中...' : '立即买入', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                          ),
                        ),
                      ),
                      ...pending.map((p) => _buildSpeedCard(p, colors)),
                      const SizedBox(height: AppSpacing.xl),
                    ],
                    // 运行中组合
                    if (active.isNotEmpty) ...[
                      _buildSectionHeader('运行中', active.length, colors),
                      const SizedBox(height: AppSpacing.md),
                      ...active.map((p) => _buildSpeedCard(p, colors)),
                      const SizedBox(height: AppSpacing.xl),
                    ],
                    // 已结清组合
                    if (settled.isNotEmpty) ...[
                      _buildCollapsibleSettledSection(settled, colors),
                    ],
                  ]),
                ),
          ),
          // 收益日历（复用通用组件）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: InvestmentReturnCalendarWidget(speedService: _service),
          ),
          const SizedBox(height: AppSpacing.lg),
        ]),
      ),
    );
  }

  Widget _buildEmptyState(AppColorScheme colors) {
    return const SizedBox();
  }

  Widget _buildSectionHeader(String title, int count, AppColorScheme colors) {
    return Row(children: [
      Container(
        width: 4, height: 18,
        decoration: BoxDecoration(
          color: colors.speedInvestAccent,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: AppSpacing.sm),
      Text(title, style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
      const SizedBox(width: AppSpacing.sm),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: colors.speedInvestAccent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('$count',
          style: AppText.caption.copyWith(color: colors.speedInvestAccent, fontWeight: FontWeight.w800)),
      ),
    ]);
  }

  Widget _buildSpeedCard(SpeedPortfolio p, AppColorScheme colors) {
    final isPending = p.status == SpeedPortfolioStatus.pending;
    final isActive  = p.status == SpeedPortfolioStatus.active;
    final statusText = isPending ? '待买入'
        : isActive  ? '持仓中'
        : '已结算';
    final statusColor = isPending ? Colors.orange
        : isActive  ? Colors.blue
        : Colors.green;
    final avgRet = p.status == SpeedPortfolioStatus.settled ? p.avgSettledReturn : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        elevation: 1,
        shadowColor: colors.primary.withOpacity(0.08),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => SpeedInvestmentDetailScreen(portfolio: p, service: _service),
            )).then((_) => setState(() {}));
          },
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.speed, color: colors.speedInvestAccent, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('极速组合 ${_portfolioDisplayDate(p)}',
                    style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: statusColor.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                  child: Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.w700, fontSize: 10)),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _confirmDelete(p),
                  child: Icon(Icons.delete_outline, color: colors.textHint, size: 16),
                ),
              ]),
              const SizedBox(height: AppSpacing.sm),
              if (p.status == SpeedPortfolioStatus.settled) ...[
                const SizedBox(height: 4),
                Text('平均结算: ${avgRet >= 0 ? "+" : ""}${avgRet.toStringAsFixed(2)}%',
                  style: TextStyle(color: avgRet >= 0 ? Colors.red : Colors.green, fontWeight: FontWeight.w700, fontSize: 12)),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  bool _settledExpanded = false;
  
  Widget _buildCollapsibleSettledSection(List<SpeedPortfolio> settled, AppColorScheme colors) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => setState(() => _settledExpanded = !_settledExpanded),
        child: _buildSectionHeader('已结清', settled.length, colors),
      ),
      if (_settledExpanded) ...[
        const SizedBox(height: AppSpacing.md),
        ...settled.map((p) => _buildSpeedCard(p, colors)),
      ],
    ]);
  }

  Widget _loader() => const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));

}
