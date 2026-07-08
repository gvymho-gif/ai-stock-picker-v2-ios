/// 热点投资组合详情页
///
/// 展示单个虚拟投资组合的完整明细
/// 包含实时行情刷新、止盈止损状态、交易记录时间线

import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/hot_investment_model.dart';
import '../services/hot_investment_service.dart';
import '../services/local_data_service.dart';

class HotInvestmentDetailScreen extends StatefulWidget {
  final HotInvestmentService service;
  final String portfolioId;

  const HotInvestmentDetailScreen({
    Key? key,
    required this.service,
    required this.portfolioId,
  }) : super(key: key);

  @override
  State<HotInvestmentDetailScreen> createState() => _HotInvestmentDetailScreenState();
}

class _HotInvestmentDetailScreenState extends State<HotInvestmentDetailScreen> {
  final LocalDataService _api = LocalDataService();
  HotInvestmentPortfolio? _portfolio;
  Map<String, Map<String, dynamic>> _quotes = {};
  bool _loadingQuotes = false;
  bool _refreshing = false;   // 防止并发刷新
  DateTime? _lastRefreshTime; // 上次刷新时间
  Timer? _refreshTimer;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadPortfolio();
    _refreshQuotes();
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    widget.service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    _loadPortfolio();
  }

  void _loadPortfolio() {
    final p = widget.service.getPortfolio(widget.portfolioId);
    if (mounted && p != null) {
      setState(() => _portfolio = p);
    }
  }

  Future<void> _refreshQuotes() async {
    if (_portfolio == null || _refreshing) return;
    _refreshing = true;
    if (mounted) setState(() => _loadingQuotes = true);
    try {
      // 先尝试激活pending组合
      if (_portfolio!.status == PortfolioStatus.pending) {
        final activated = await widget.service.activatePendingPortfolio(_portfolio!);
        if (activated != null) {
          _portfolio = activated;
        }
      }
      // 获取实时行情 — 增量合并，保留旧数据避免网络波动闪烁
      final quotes = await widget.service.getPositionQuotes(_portfolio!.positions);
      if (mounted) {
        final updated = Map<String, Map<String, dynamic>>.from(_quotes);
        updated.addAll(quotes); // 只覆盖成功获取的，失败的保留旧行情
        setState(() { _quotes = updated; _lastRefreshTime = DateTime.now(); _loadingQuotes = false; });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingQuotes = false);
    }
    _refreshing = false;
  }

  void _startAutoRefresh() {
    // 延迟3秒后开始定时刷新，避免与初始刷新冲突
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
          if (mounted) _refreshQuotes();
        });
      }
    });
  }

  Future<void> _forceSettle() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('强制结算'),
        content: const Text('将以当前市价清仓所有持仓并结清该组合，确认操作？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认结算', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _checking = true);
    try {
      final updated = await widget.service.forceSettle(widget.portfolioId);
      if (mounted) setState(() { _portfolio = updated; _checking = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _checking = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('结算失败: $e')));
      }
    }
  }

  /// 确认删除组合
  Future<void> _confirmDelete() async {
    if (_portfolio == null) return;
    final colors = AppColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(children: [
          Icon(Icons.warning_amber, color: Colors.red, size: 22),
          const SizedBox(width: 8),
          Text('删除组合', style: AppText.h3.copyWith(color: colors.textPrimary)),
        ]),
        content: Text('该组合及所有持仓记录将被永久删除，不可恢复。',
          style: AppText.body2.copyWith(color: colors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认删除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await widget.service.deletePortfolio(widget.portfolioId);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    if (_portfolio == null) {
      return Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(title: const Text('加载中...')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final p = _portfolio!;
    final isSettled = p.status == PortfolioStatus.settled;

    // 计算总市值/浮动盈亏 — 增量合并后旧行情仍可用
    double totalMarketValue = 0;
    double floatingPnl = 0;
    for (final pos in p.positions) {
      if (pos.status == PositionStatus.holding && _quotes.containsKey(pos.stockCode)) {
        final q = _quotes[pos.stockCode]!;
        final price = (q['price'] as num?)?.toDouble() ?? 0;
        if (price > 0) {
          totalMarketValue += price * pos.shares;
          final priceDiff = price - pos.buyPrice;
          // 价格截断后相等但有涨跌幅时，用change_pct推算
          if (priceDiff.abs() < 0.001) {
            final changePct = (q['change_pct'] as num?)?.toDouble() ?? 0.0;
            floatingPnl += changePct / 100 * pos.investedAmount;
          } else {
            floatingPnl += priceDiff * pos.shares;
          }
        }
      }
    }

    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(p.name,
            style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800),
            overflow: TextOverflow.ellipsis,
          ),
          centerTitle: true,
          flexibleSpace: Container(
            decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
          ),
          actions: [
            if (!isSettled)
              IconButton(
                icon: _checking
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.sell, color: colors.warning),
                onPressed: _checking ? null : _forceSettle,
                tooltip: '强制结算',
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: _confirmDelete,
              tooltip: '删除组合',
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 顶部统计卡片
            _buildSummaryCard(p, totalMarketValue, floatingPnl, isSettled, colors),
            const SizedBox(height: AppSpacing.xl),

            // 状态标签
            if (isSettled)
              _buildSettledBanner(p, colors),

            // 关联热点新闻
            _buildNewsInfo(p, colors),
            const SizedBox(height: AppSpacing.lg),

            // 三只股票持仓明细卡片
            Text('持仓明细', style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpacing.md),

            ...List.generate(p.positions.length, (idx) {
              final pos = p.positions[idx];
              final quote = _quotes[pos.stockCode];
              return _buildPositionCard(pos, idx + 1, quote, colors);
            }),

            const SizedBox(height: AppSpacing.xxl),
          ]),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(HotInvestmentPortfolio p, double marketValue, double pnl, bool isSettled, AppColorScheme colors) {
    final totalPnl = isSettled ? p.totalReturn : pnl;
    final totalRate = p.totalInvested > 0 ? (totalPnl / p.totalInvested * 100) : 0.0;
    final isProfit = totalRate >= 0;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isSettled
            ? (isProfit ? [colors.up.withOpacity(0.15), colors.up.withOpacity(0.05)] : [colors.down.withOpacity(0.15), colors.down.withOpacity(0.05)])
            : [colors.primary.withOpacity(0.15), colors.primary.withOpacity(0.05)],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isSettled ? (isProfit ? colors.up.withOpacity(0.3) : colors.down.withOpacity(0.3)) : colors.primary.withOpacity(0.3),
        ),
      ),
      child: Column(children: [
        // 标题行
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isSettled ? (isProfit ? colors.up : colors.down) : colors.primary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(isSettled ? '已结清' : '运行中',
              style: AppText.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (p.newsRating != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: p.newsRating == 'S' ? Colors.red.withOpacity(0.15) : Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${p.newsRating}级',
                style: TextStyle(
                  color: p.newsRating == 'S' ? Colors.red : Colors.orange,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                )),
            ),
          // 实时刷新指示器
          if (!isSettled) ...[
            const Spacer(),
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                color: _refreshing ? Colors.orange : (_lastRefreshTime != null ? Colors.green : Colors.grey),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _refreshing ? '刷新中' : (_lastRefreshTime != null ? '实时' : '等待'),
              style: AppText.caption.copyWith(
                color: _refreshing ? Colors.orange : colors.textHint,
                fontSize: 10,
              ),
            ),
          ],
        ]),
        const SizedBox(height: AppSpacing.lg),

        // 数据行
        Row(children: [
          _buildSummaryItem('总投入', '¥${p.totalInvested.toStringAsFixed(0)}', colors.textSecondary, colors),
          _buildSummaryItem(
            isSettled ? '总回报' : '当前市值',
            isSettled ? '¥${p.totalReturn.toStringAsFixed(0)}' : '¥${marketValue.toStringAsFixed(0)}',
            colors.textSecondary, colors,
          ),
          _buildSummaryItem(
            isSettled ? '收益率' : '浮动盈亏',
            '${isProfit ? "▲" : "▼"}${totalPnl.abs().toStringAsFixed(0)}',
            isProfit ? colors.up : colors.down, colors,
          ),
        ]),
        const SizedBox(height: AppSpacing.md),
        Row(children: [
          _buildSummaryItem('持股数', '${p.positions.length}只', colors.textSecondary, colors),
          _buildSummaryItem(
            '持有中', '${p.positions.where((pos) => pos.status == PositionStatus.holding).length}只',
            colors.textSecondary, colors,
          ),
          _buildSummaryItem(
            '收益率', '${isProfit ? "▲" : "▼"}${totalRate.abs().toStringAsFixed(2)}%',
            isProfit ? colors.up : colors.down, colors,
          ),
        ]),
      ]),
    );
  }

  Widget _buildSummaryItem(String label, String value, Color valueColor, AppColorScheme colors) {
    return Expanded(
      child: Column(children: [
        Text(label, style: AppText.caption.copyWith(color: colors.textHint, fontSize: 11)),
        const SizedBox(height: 4),
        FittedBox(fit: BoxFit.scaleDown, child: Text(value,
          style: AppText.body1.copyWith(color: valueColor, fontWeight: FontWeight.w800))),
      ]),
    );
  }

  Widget _buildSettledBanner(HotInvestmentPortfolio p, AppColorScheme colors) {
    final rate = p.totalInvested > 0 ? (p.totalReturn / p.totalInvested * 100) : 0.0;
    final isProfit = rate >= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isProfit ? colors.up.withOpacity(0.1) : colors.down.withOpacity(0.1),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: isProfit ? colors.up.withOpacity(0.3) : colors.down.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(isProfit ? Icons.emoji_events : Icons.trending_down,
          color: isProfit ? colors.up : colors.down, size: 24),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isProfit ? '组合已盈利结算' : '组合已亏损结算',
              style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
            Text('结清时间: ${_formatDateTime(p.settledAt ?? p.createdAt)}',
              style: AppText.caption.copyWith(color: colors.textSecondary)),
          ]),
        ),
        Text('${isProfit ? "▲" : "▼"}${rate.abs().toStringAsFixed(2)}%',
          style: AppText.h2.copyWith(color: isProfit ? colors.up : colors.down, fontWeight: FontWeight.w900)),
      ]),
    );
  }

  Widget _buildNewsInfo(HotInvestmentPortfolio p, AppColorScheme colors) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.article, size: 16, color: colors.textHint),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('关联热点', style: AppText.caption.copyWith(color: colors.textHint)),
            const SizedBox(height: 2),
            Text(p.hotTrackTitle,
              style: AppText.body2.copyWith(color: colors.textPrimary)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildPositionCard(VirtualPosition pos, int rank, Map<String, dynamic>? quote, AppColorScheme colors) {
    final isUnfilled = pos.status == PositionStatus.unfilled;
    final isHolding = pos.status == PositionStatus.holding;
    final currentPrice = quote != null ? ((quote['price'] as num?)?.toDouble() ?? 0) : 0.0;
    // 区分"有行情数据"和"价格有效"，避免行情缺失时盈亏归零
    final hasQuoteData = quote != null;
    final hasValidPrice = isHolding && hasQuoteData && currentPrice > 0;

    // 日涨跌幅（相对昨收）— 有行情数据即可读取
    final dailyChangePct = hasQuoteData ? ((quote!['change_pct'] as num?)?.toDouble() ?? 0) : 0.0;

    double pnl = 0;
    double pnlRate = 0;
    if (pos.status != PositionStatus.holding && pos.status != PositionStatus.unfilled && pos.returnAmount != null) {
      pnl = pos.returnAmount!;
      pnlRate = pos.returnRate ?? 0;
    } else if (hasValidPrice) {
      final priceDiff = currentPrice - pos.buyPrice;
      // 价格截断后相等但有日涨跌幅时，用change_pct推算浮动盈亏
      if (priceDiff.abs() < 0.001 && dailyChangePct.abs() > 0.001) {
        pnl = dailyChangePct / 100 * pos.investedAmount;
        pnlRate = pos.investedAmount > 0 ? pnl / pos.investedAmount : 0.0;
      } else {
        pnl = priceDiff * pos.shares;
        pnlRate = pos.buyPrice > 0 ? priceDiff / pos.buyPrice : 0.0;
      }
    }

    final isProfit = pnl >= 0;
    // 价格是否变动（用于当前价颜色）
    final priceDiff = currentPrice - pos.buyPrice;
    final priceMoved = priceDiff.abs() > 0.001;
    final statusColor = _getStatusColor(pos.status, colors);
    final statusLabel = _getStatusLabel(pos.status);

    // 非 unfilled 状态下的详细内容
    final List<Widget> detailRows = [];
    if (!isUnfilled) {
        // 价格信息行
        detailRows.addAll([
          const SizedBox(height: AppSpacing.md),
          Row(children: [
            _buildPriceItem('建仓价', '¥${pos.buyPrice.toStringAsFixed(2)}', colors.textSecondary, colors),
            if (hasValidPrice)
              _buildPriceItem('当前价', '¥${currentPrice.toStringAsFixed(3)}',
                priceMoved ? (priceDiff > 0 ? colors.up : colors.down) : colors.textPrimary, colors)
            else if (pos.sellPrice != null)
              _buildPriceItem('卖出价', '¥${pos.sellPrice!.toStringAsFixed(2)}', colors.textPrimary, colors)
            else if (isHolding)
              _buildPriceItem('当前价', '获取中...', colors.textHint, colors),
            _buildPriceItem('数量', '${pos.shares}股', colors.textSecondary, colors),
          ]),
          // 日涨跌幅行（相对昨收）— 有行情数据就显示
          if (hasQuoteData && dailyChangePct != 0) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(children: [
              _buildPriceItem('日涨跌',
                '${dailyChangePct > 0 ? "▲" : "▼"}${dailyChangePct.abs().toStringAsFixed(2)}%',
                dailyChangePct > 0 ? colors.up : colors.down, colors),
              const Spacer(),
            ]),
          ],
          const SizedBox(height: AppSpacing.sm),

          // 投入/回报行
          Row(children: [
            _buildPriceItem('投入', '¥${pos.investedAmount.toStringAsFixed(0)}', colors.textSecondary, colors),
            if (isHolding && !hasValidPrice && pos.sellPrice == null)
              _buildPriceItem('浮动盈亏', '获取中...', colors.textHint, colors)
            else
              _buildPriceItem(
                isHolding ? '浮动盈亏' : '结算盈亏',
                '${isProfit ? "▲" : "▼"}¥${pnl.abs().toStringAsFixed(0)}',
                isProfit ? colors.up : colors.down,
                colors,
              ),
            if (isHolding && !hasValidPrice && pos.sellPrice == null)
              _buildPriceItem('回报率', '--', colors.textHint, colors)
            else
              _buildPriceItem(
                '回报率',
                '${isProfit ? "▲" : "▼"}${(pnlRate * 100).abs().toStringAsFixed(2)}%',
                isProfit ? colors.up : colors.down,
                colors,
              ),
          ]),
        ]);

      // 止损线
      if (isHolding) {
        detailRows.addAll([
          const SizedBox(height: AppSpacing.sm),
          Row(children: [
            Icon(Icons.shield, size: 12, color: colors.textHint),
            const SizedBox(width: 4),
            Text('止损线: ${(pos.stopLossPercent * 100).toStringAsFixed(1)}%  (¥${(pos.buyPrice * (1 - pos.stopLossPercent)).toStringAsFixed(2)})',
              style: AppText.caption.copyWith(color: colors.textHint)),
            const Spacer(),
            Text('止盈线: +10%  (¥${(pos.buyPrice * 1.10).toStringAsFixed(2)})',
              style: AppText.caption.copyWith(color: colors.textHint)),
          ]),
        ]);
      }
    } else {
      // 待激活提示
      detailRows.addAll([
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.08),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(children: [
            Icon(Icons.schedule, size: 14, color: Colors.orange),
            const SizedBox(width: 6),
            Text('等待交易日开盘后自动激活买入',
              style: TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.w500)),
          ]),
        ),
      ]);
    }

    // 时间信息（所有状态）
    detailRows.addAll([
      const SizedBox(height: AppSpacing.sm),
      Row(children: [
        Icon(Icons.access_time, size: 12, color: colors.textHint),
        const SizedBox(width: 4),
        Text('创建: ${_formatDateTime(pos.buyTime)}',
          style: AppText.caption.copyWith(color: colors.textHint)),
        if (pos.sellTime != null) ...[
          const SizedBox(width: AppSpacing.md),
          Text('清仓: ${_formatDateTime(pos.sellTime!)}',
            style: AppText.caption.copyWith(color: colors.textHint)),
        ],
      ]),
    ]);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.border),
        boxShadow: [BoxShadow(color: colors.primary.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 头部：排名 + 名称代码 + 状态
        Row(children: [
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(
              color: colors.hotInvestAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(child: Text('$rank',
              style: TextStyle(color: colors.hotInvestAccent, fontSize: 12, fontWeight: FontWeight.w800))),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pos.stockName,
                style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
              Text(pos.stockCode,
                style: AppText.caption.copyWith(color: colors.textHint)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(statusLabel,
              style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w700)),
          ),
        ]),
        ...detailRows,
      ]),
    );
  }

  Widget _buildPriceItem(String label, String value, Color valueColor, AppColorScheme colors) {
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppText.caption.copyWith(color: colors.textHint, fontSize: 10)),
        const SizedBox(height: 2),
        Text(value, style: AppText.caption.copyWith(color: valueColor, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Color _getStatusColor(PositionStatus status, AppColorScheme colors) {
    switch (status) {
      case PositionStatus.unfilled: return Colors.orange;
      case PositionStatus.holding: return colors.primary;
      case PositionStatus.stopProfit: return colors.up;
      case PositionStatus.stopLoss: return colors.down;
      case PositionStatus.timeLiquidated: return colors.textHint;
    }
  }

  String _getStatusLabel(PositionStatus status) {
    switch (status) {
      case PositionStatus.unfilled: return '待激活';
      case PositionStatus.holding: return '持仓中';
      case PositionStatus.stopProfit: return '止盈';
      case PositionStatus.stopLoss: return '止损';
      case PositionStatus.timeLiquidated: return '清仓';
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
