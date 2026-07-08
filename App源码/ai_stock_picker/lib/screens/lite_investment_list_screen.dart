/// 轻量投资组合列表页
///
/// 展示所有运行中的虚拟投资组合和已结清历史记录

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/hot_investment_model.dart';
import '../services/lite_investment_service.dart';
import '../services/local_data_service.dart';
import '../services/jianguoyun_service.dart';
import 'lite_investment_detail_screen.dart';
import 'expert_screen.dart';
import '../widgets/investment_return_calendar_widget.dart';
import 'settlement_history_screen.dart';

class LiteInvestmentListScreen extends StatefulWidget {
  final LiteInvestmentService service;

  const LiteInvestmentListScreen({Key? key, required this.service}) : super(key: key);

  @override
  State<LiteInvestmentListScreen> createState() => _LiteInvestmentListScreenState();
}

class _LiteInvestmentListScreenState extends State<LiteInvestmentListScreen> {
  final LocalDataService _api = LocalDataService();
  bool _checking = false;
  bool _uploading = false;
  bool _downloading = false;
  bool _exporting = false;
  bool _importing = false;
  bool _jgyUploading = false;
  bool _jgyDownloading = false;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onDataChanged);
    // 进入列表页自动检查并激活pending组合
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _checkAll();
    });
  }

  @override
  void dispose() {
    widget.service.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) setState(() {});
  }

  /// 手动触发止盈止损检查
  Future<void> _checkAll() async {
    setState(() => _checking = true);
    try {
      await widget.service.checkAllPortfolios();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查失败: $e')),
        );
      }
    }
    if (mounted) setState(() => _checking = false);
  }

  /// ☁️ 上传到云端
  Future<void> _uploadToCloud() async {
    setState(() => _uploading = true);
    try {
      final result = await widget.service.uploadToCloud();
      if (mounted) {
        if (result['ok'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('☁️ 云端上传成功'), behavior: SnackBarBehavior.floating),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('上传失败: ${result['error']}'), behavior: SnackBarBehavior.floating),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传异常: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 📥 从云端下载
  Future<void> _downloadFromCloud() async {
    // 确认对话框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(context);
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text('确认下载', style: AppText.h3.copyWith(color: c.textPrimary)),
          content: Text('云端数据将覆盖本地所有轻量投资组合（各¥3,333上限），是否继续？',
            style: AppText.body2.copyWith(color: c.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: AppText.body2.copyWith(color: c.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: c.hotInvestAccent),
              child: const Text('确认下载', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    setState(() => _downloading = true);
    try {
      final result = await widget.service.downloadFromCloud();
      if (mounted) {
        if (result['ok'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('📥 云端下载成功（${result['count']}个组合）'), behavior: SnackBarBehavior.floating),
          );
          setState(() {}); // 刷新UI
        } else {
          final errMsg = result['error']?.toString() ?? '未知错误';
          debugPrint('[轻量投资UI] 下载失败: $errMsg');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('下载失败: $errMsg'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载异常: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// 💾 导出到本地（显示JSON文本，用户可复制保存到文件）
  Future<void> _exportToLocal() async {
    setState(() => _exporting = true);
    try {
      final jsonStr = widget.service.exportToLocalJson();
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
                jsonStr,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFCCCCCC)),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('📋 已复制到剪贴板，可粘贴到文本文件保存'), behavior: SnackBarBehavior.floating),
                );
              },
              child: Text('关闭', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 📂 从本地导入（弹出文本框，用户粘贴JSON后导入）
  Future<void> _importFromLocal() async {
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
            Text('粘贴之前导出的 JSON 备份内容，\n将覆盖当前所有组合及归档数据。',
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
      final count = await widget.service.importFromLocalJson(jsonStr);
      if (mounted) {
        if (count != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('📂 导入成功（$count 个组合）'), behavior: SnackBarBehavior.floating),
          );
          setState(() {}); // 刷新UI
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('导入失败：数据格式不正确'), behavior: SnackBarBehavior.floating),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入异常: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 🥜 上传到坚果云
  Future<void> _uploadToJianguoyun() async {
    if (!await JianguoyunService.isConfigured()) {
      if (mounted) _showSnackBar('请先在设置中配置坚果云应用名称和应用密码');
      return;
    }
    setState(() => _jgyUploading = true);
    try {
      final result = await widget.service.uploadToJianguoyun();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result['ok'] == true ? '🥜 坚果云上传成功' : '上传失败: ${result['error']}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _jgyUploading = false);
    }
  }

  /// 📥 从坚果云下载
  Future<void> _downloadFromJianguoyun() async {
    if (!await JianguoyunService.isConfigured()) {
      if (mounted) _showSnackBar('请先在设置中配置坚果云应用名称和应用密码');
      return;
    }
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) {
      final c = AppColors.of(context);
      return AlertDialog(
        backgroundColor: c.surface,
        title: Text('确认下载', style: AppText.h3.copyWith(color: c.textPrimary)),
        content: Text('坚果云数据将覆盖本地所有组合，是否继续？', style: AppText.body2.copyWith(color: c.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: AppText.body2.copyWith(color: c.textSecondary))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: c.hotInvestAccent), child: const Text('确认下载', style: TextStyle(color: Colors.white))),
        ],
      );
    });
    if (confirmed != true) return;
    setState(() => _jgyDownloading = true);
    try {
      final result = await widget.service.downloadFromJianguoyun();
      if (mounted) {
        if (result['ok'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🥜 坚果云下载成功（${result['count']}个组合）'), behavior: SnackBarBehavior.floating));
          setState(() {});
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败: ${result['error']}'), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 5)));
        }
      }
    } finally {
      if (mounted) setState(() => _jgyDownloading = false);
    }
  }

  void _showSnackBar(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final holding = widget.service.holdingPortfolios;
    final settled = widget.service.settledPortfolios;

    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text('轻量投资',
            style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
          centerTitle: true,
          flexibleSpace: Container(
            decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
          ),
          actions: [
            IconButton(
              icon: _jgyUploading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.cloud_sync, color: Colors.amber.shade700),
              iconSize: 14,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: _jgyUploading ? null : _uploadToJianguoyun,
              tooltip: '上传到坚果云',
            ),
            IconButton(
              icon: _jgyDownloading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.cloud_done, color: Colors.amber.shade700),
              iconSize: 14,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: _jgyDownloading ? null : _downloadFromJianguoyun,
              tooltip: '从坚果云下载',
            ),
            IconButton(
              icon: _exporting
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.file_download, color: colors.primary),
              iconSize: 14,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: _exporting ? null : _exportToLocal,
              tooltip: '导出本地备份',
            ),
            IconButton(
              icon: _importing
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.file_upload, color: colors.primary),
              iconSize: 14,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: _importing ? null : _importFromLocal,
              tooltip: '导入本地备份',
            ),
            IconButton(
              icon: _checking
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.refresh, color: colors.primary),
              iconSize: 14,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              onPressed: _checking ? null : _checkAll,
              tooltip: '检查止盈止损',
            ),
          ],
        ),
        body: Column(children: [
          // ★ 已结算记录入口 Banner
          _buildSettlementHistoryBanner(colors),
          Expanded(
            child: holding.isEmpty && settled.isEmpty
              ? _buildEmptyState(colors)
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // 运行中的组合
                    if (holding.isNotEmpty) ...[
                      _buildSectionHeader('运行中', holding.length, colors),
                      const SizedBox(height: AppSpacing.md),
                      ...holding.map((p) => _buildPortfolioCard(p, colors)),
                      const SizedBox(height: AppSpacing.xl),
                    ],

                    // 已结清组合
                    if (settled.isNotEmpty) ...[
                      _buildCollapsibleSettledSection(settled, colors),
                    ],
                  ]),
                ),
          ),
          // 投资收益日历（底部固定）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: InvestmentReturnCalendarWidget(hotService: widget.service),
          ),
          const SizedBox(height: AppSpacing.lg),
        ]),
      ),
    );
  }

  Widget _buildEmptyState(AppColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.whatshot, size: 64, color: colors.textHint.withOpacity(0.4)),
          const SizedBox(height: AppSpacing.lg),
          Text('还没有虚拟投资组合',
            style: AppText.h3.copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          Text('进入专家选股 → 热点追踪\n对S/A级热点一键建仓',
            textAlign: TextAlign.center,
            style: AppText.body2.copyWith(color: colors.textHint)),
          const SizedBox(height: AppSpacing.xl),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                _slideRoute(ExpertScreen(api: _api)),
              ).then((_) => setState(() {}));
            },
            icon: const Icon(Icons.rocket_launch, size: 18),
            label: const Text('去热点追踪'),
            style: ElevatedButton.styleFrom(
              primary: colors.hotInvestAccent,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
      ),
    );
  }

  /// 已结算记录入口 Banner（轻量投资配色）
  Widget _buildSettlementHistoryBanner(AppColorScheme colors) {
    final archive = widget.service.calendarArchive;
    final portfolioNames = archive.map((e) => e['portfolioName'] as String? ?? '').toSet();
    final groupCount = portfolioNames.where((n) => n.isNotEmpty).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      child: Material(
        color: archive.isNotEmpty ? colors.liteInvestAccent.withOpacity(0.08) : colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => SettlementHistoryScreen(
                service: widget.service,
                moduleTitle: '轻量投资',
                accentColor: colors.liteInvestAccent,
                accentGradient: colors.liteInvestGradient,
              ),
            )).then((_) => setState(() {}));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            child: Row(children: [
              Icon(Icons.history, size: 16,
                color: archive.isNotEmpty ? colors.liteInvestAccent : colors.textHint),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  archive.isNotEmpty
                      ? '已结算记录 · $groupCount 组'
                      : '已结算记录（暂无）',
                  style: AppText.body2.copyWith(
                    color: archive.isNotEmpty ? colors.liteInvestAccent : colors.textHint,
                    fontWeight: archive.isNotEmpty ? FontWeight.w700 : FontWeight.normal,
                    fontSize: 12,
                  ),
                ),
              ),
              if (archive.isNotEmpty) ...[
                Text('查看详情 ›',
                  style: AppText.caption.copyWith(
                    color: colors.liteInvestAccent,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  )),
              ] else ...[
                Text('止盈/止损后自动归档',
                  style: AppText.caption.copyWith(color: colors.textHint, fontSize: 10)),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count, AppColorScheme colors) {
    return Row(children: [
      Container(
        width: 4, height: 18,
        decoration: BoxDecoration(
          color: colors.liteInvestAccent,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: AppSpacing.sm),
      Text(title, style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
      const SizedBox(width: AppSpacing.sm),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: colors.liteInvestAccent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('$count',
          style: AppText.caption.copyWith(
            color: colors.liteInvestAccent,
            fontWeight: FontWeight.w800,
          )),
      ),
    ]);
  }

  Widget _buildPortfolioCard(HotInvestmentPortfolio portfolio, AppColorScheme colors) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        elevation: 1,
        shadowColor: colors.primary.withOpacity(0.08),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () => _openDetail(portfolio),
          onLongPress: () => _confirmDelete(portfolio),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // 名称行
              Row(children: [
                Icon(Icons.bar_chart, color: colors.liteInvestAccent, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(portfolio.name,
                    style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (portfolio.newsRating != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: portfolio.newsRating == 'S'
                        ? Colors.red.withOpacity(0.15)
                        : Colors.teal.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(portfolio.newsRating!,
                      style: TextStyle(
                        color: portfolio.newsRating == 'S' ? Colors.red : Colors.teal,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      )),
                  ),
                if (portfolio.status == PortfolioStatus.pending)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.teal.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('待激活',
                      style: TextStyle(color: Colors.teal, fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                // 删除按钮
                const SizedBox(width: AppSpacing.sm),
                GestureDetector(
                  onTap: () => _confirmDelete(portfolio),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: colors.surfaceVariant,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(Icons.delete_outline, size: 16, color: colors.textHint),
                  ),
                ),
              ]),
              const SizedBox(height: AppSpacing.sm),

              // 新闻标题
              Text(portfolio.hotTrackTitle,
                style: AppText.caption.copyWith(color: colors.textSecondary),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.md),

              // 持仓股票标签
              Wrap(
                spacing: 6, runSpacing: 4,
                children: portfolio.positions.map((pos) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: colors.surfaceVariant,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('${pos.stockName}(${pos.stockCode})',
                      style: AppText.caption.copyWith(
                        color: colors.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      )),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppSpacing.md),

              // 底栏统计
              Row(children: [
                _buildStatItem('总投入', '¥${portfolio.totalInvested.toStringAsFixed(0)}', colors),
                const SizedBox(width: AppSpacing.lg),
                _buildStatItem('持有', '${portfolio.holdingCount}/${portfolio.positions.length}只', colors),
                const Spacer(),
                Icon(Icons.chevron_right, color: colors.textHint, size: 20),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, AppColorScheme colors) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: AppText.caption.copyWith(color: colors.textHint, fontSize: 11)),
      const SizedBox(height: 2),
      Text(value, style: AppText.body2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _buildCollapsibleSettledSection(List<HotInvestmentPortfolio> settled, AppColorScheme colors) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildSectionHeader('已结清', settled.length, colors),
      const SizedBox(height: AppSpacing.md),
      ...settled.map((p) {
        final rate = p.totalInvested > 0 ? (p.totalReturn / p.totalInvested * 100) : 0.0;
        final isProfit = rate >= 0;
        return Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Material(
            color: colors.surfaceVariant.withOpacity(0.6),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => _openDetail(p),
              onLongPress: () => _confirmDelete(p),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name,
                        style: AppText.body2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text('${p.positions.length}只 · ${p.settledAt != null ? _formatDate(p.settledAt!) : ""}',
                        style: AppText.caption.copyWith(color: colors.textHint)),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${isProfit ? "▲" : "▼"}${rate.abs().toStringAsFixed(2)}%',
                      style: AppText.body1.copyWith(
                        color: isProfit ? colors.up : colors.down,
                        fontWeight: FontWeight.w800,
                      )),
                    Text('¥${p.totalReturn.toStringAsFixed(0)}',
                      style: AppText.caption.copyWith(
                        color: isProfit ? colors.up : colors.down,
                      )),
                  ]),
                  const SizedBox(width: AppSpacing.sm),
                  GestureDetector(
                    onTap: () => _confirmDelete(p),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.delete_outline, size: 16, color: colors.textHint),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      }),
    ]);
  }

  void _openDetail(HotInvestmentPortfolio portfolio) {
    Navigator.push(
      context,
      _slideRoute(LiteInvestmentDetailScreen(
        service: widget.service,
        portfolioId: portfolio.id,
      )),
    );
  }

  /// 确认删除组合
  Future<void> _confirmDelete(HotInvestmentPortfolio portfolio) async {
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(portfolio.name, style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            Text('该组合及所有持仓记录将被永久删除，不可恢复。',
              style: AppText.body2.copyWith(color: colors.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确认删除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.service.deletePortfolio(portfolio.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

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

  String _formatDate(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
