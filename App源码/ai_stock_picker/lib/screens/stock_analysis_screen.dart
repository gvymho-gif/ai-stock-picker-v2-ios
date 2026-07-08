/// 个股分析页面 - 简洁版
///
/// 接受股票数据并显示分析结果
/// 正确的导航栈: SectorStocksScreen -> StockAnalysisScreen -> 返回上一页

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../services/local_data_service.dart';
import 'stock_analysis_content.dart'; // 分离的分析内容组件

class StockAnalysisScreen extends StatefulWidget {
  final Map<String, dynamic>? stockData;
  final String? symbol;

  const StockAnalysisScreen({
    Key? key,
    this.stockData,
    this.symbol,
  }) : super(key: key);

  @override
  State<StockAnalysisScreen> createState() => _StockAnalysisScreenState();
}

class _StockAnalysisScreenState extends State<StockAnalysisScreen> {
  final LocalDataService _api = LocalDataService();
  final ScrollController _scrollCtrl = ScrollController();

  bool _loading = false;
  Map<String, dynamic>? _res;
  String? _err;
  String? _lastQuery;

  @override
  void initState() {
    super.initState();
    if (widget.stockData != null) {
      _res = widget.stockData;
    } else if (widget.symbol != null) {
      _search(widget.symbol!);
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _search([String? query]) async {
    final q = query ?? widget.symbol ?? '';
    if (q.isEmpty) return;
    _lastQuery = q;
    setState(() { _loading = true; _err = null; _res = null; });
    try {
      final data = await _api.searchStock(q);
      if (mounted) setState(() { _res = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _err = e.toString().replaceAll('Exception: ', ''); _loading = false; });
    }
  }

  Future<void> _refreshOnce() async {
    if (_lastQuery == null || _lastQuery!.isEmpty) return;
    setState(() { _loading = true; });
    try {
      final data = await _api.searchStock(_lastQuery!);
      if (mounted) setState(() { _res = data; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _buildAppBar(colors),
        body: Column(
          children: [
            Expanded(
              child: _loading
                  ? _buildLoadingView(colors)
                  : (_err != null ? _buildErrorView(colors) : (_res != null ? _buildResultView() : _buildEmptyView(colors))),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(AppColorScheme colors) {
    return AppBar(
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new, size: 20, color: colors.textPrimary),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        _res?['name'] ?? '个股分析',
        style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800),
      ),
      centerTitle: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      actions: _res != null
          ? [
              IconButton(
                icon: Icon(Icons.refresh, color: colors.textPrimary),
                onPressed: _refreshOnce,
              ),
            ]
          : null,
      flexibleSpace: Container(
        decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
      ),
    );
  }

  Widget _buildLoadingView(AppColorScheme colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(colors.primary)),
          const SizedBox(height: AppSpacing.lg),
          Text('正在获取数据...', style: AppText.body2.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildErrorView(AppColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: colors.error.withOpacity(0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(color: colors.error.withOpacity(0.15), shape: BoxShape.circle),
                child: Icon(Icons.error_outline, size: 40, color: colors.error),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(_err ?? '未知错误', style: AppText.body2.copyWith(color: colors.textSecondary), textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.xl),
              ElevatedButton.icon(
                onPressed: () => _search(_lastQuery),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新获取'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.full)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyView(AppColorScheme colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: colors.textHint),
          const SizedBox(height: AppSpacing.lg),
          Text('暂无数据', style: AppText.h3.copyWith(color: colors.textPrimary)),
          const SizedBox(height: AppSpacing.sm),
          Text('请传入股票代码或数据', style: AppText.caption.copyWith(color: colors.textHint)),
        ],
      ),
    );
  }

  Widget _buildResultView() {
    if (_res == null) return _buildEmptyView(AppColors.of(context));
    
    return StockAnalysisContent(
      stockData: _res!,
      onRefresh: _refreshOnce,
      scrollController: _scrollCtrl,
    );
  }
}
