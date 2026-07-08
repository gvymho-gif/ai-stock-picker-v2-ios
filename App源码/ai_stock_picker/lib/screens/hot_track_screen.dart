/// 热点追踪页面 - AI决策引擎
///
/// 东方财富新闻 → 关键词初筛 → AI大脑定性 → 标的锁定 → 量化参数
/// v2.1 排版升级：更专业的新闻呈现 + 更清晰的层级结构

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/hot_track_model.dart';
import '../services/hot_track_service.dart';
import '../services/local_data_service.dart';
import '../services/news_service.dart';
import 'stock_analysis_screen.dart';
import '../services/hot_investment_service.dart';
import '../services/lite_investment_service.dart';
import 'hot_investment_detail_screen.dart';
import 'lite_investment_detail_screen.dart';

class HotTrackScreen extends StatefulWidget {
  final LocalDataService api;
  const HotTrackScreen({Key? key, required this.api}) : super(key: key);

  @override
  State<HotTrackScreen> createState() => _HotTrackScreenState();
}

class _HotTrackScreenState extends State<HotTrackScreen> {
  final HotTrackService _service = HotTrackService();
  final HotInvestmentService _investService = HotInvestmentService();

  bool _scanning = false;
  bool _analyzing = false;
  bool _enriching = false;
  String? _error;

  List<Map<String, dynamic>> _filteredNews = [];
  List<HotTrackResult> _results = [];

  @override
  void initState() {
    super.initState();
    _startFullScan();
    _investService.load();
  }

  /// 完整扫描流程：拉新闻 → 初筛 → AI分析 → 行情增强
  Future<void> _startFullScan() async {
    setState(() {
      _scanning = true;
      _analyzing = false;
      _enriching = false;
      _error = null;
      _results = [];
      _filteredNews = [];
    });

    try {
      // 第一步：拉取+初筛
      final news = await _service.fetchAndFilterNews();
      if (!mounted) return;

      if (news.isEmpty) {
        setState(() {
          _scanning = false;
          _error = '当前没有检测到突发热点新闻，请稍后再试';
        });
        return;
      }

      setState(() {
        _filteredNews = news;
        _scanning = false;
        _analyzing = true;
      });

      // 第二步：逐条AI分析（最多取前5条热点新闻）
      final toAnalyze = news.take(5).toList();
      final results = <HotTrackResult>[];

      for (int i = 0; i < toAnalyze.length; i++) {
        if (!mounted) return;

        final newsItem = toAnalyze[i];
        final result = await _service.analyzeNews(newsItem);

        // 第三步：行情数据增强
        if (result.targets.isNotEmpty) {
          await _service.enrichTargetsWithQuotes(result.targets);
        }

        results.add(result);

        if (mounted) {
          setState(() {
            _results = List.from(results);
          });
        }
      }

      if (mounted) {
        setState(() {
          _analyzing = false;
          _enriching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _analyzing = false;
          _enriching = false;
          _error = '热点追踪出错：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text('热点追踪', style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
          centerTitle: true,
          flexibleSpace: Container(
            decoration: BoxDecoration(gradient: LinearGradient(colors: colors.backgroundGradient)),
          ),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _startFullScan),
          ],
        ),
        body: _buildBody(colors),
      ),
    );
  }

  Widget _buildBody(AppColorScheme colors) {
    if (_scanning) return _buildScanningView(colors);
    if (_error != null) return _buildErrorView(colors);
    if (_results.isEmpty && _analyzing) return _buildAnalyzingView(colors);

    return RefreshIndicator(
      onRefresh: _startFullScan,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          // 顶部状态提示
          _buildStatusBanner(colors),
          const SizedBox(height: AppSpacing.lg),

          // AI分析结果列表
          ..._results.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: _buildResultCard(r, colors),
          )),

          // 分析中提示
          if (_analyzing) ...[
            Center(child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(children: [
                SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(colors.primary)),
                ),
                const SizedBox(height: 8),
                Text('AI决策引擎分析中...', style: AppText.caption.copyWith(color: colors.textHint)),
              ]),
            )),
          ],
        ],
      ),
    );
  }

  /// 扫描中视图
  Widget _buildScanningView(AppColorScheme colors) {
    return Center(child: Container(
      margin: const EdgeInsets.all(AppSpacing.xxl),
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.orange, Colors.red]),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: const Icon(Icons.local_fire_department, color: Colors.white, size: 40),
        ),
        const SizedBox(height: AppSpacing.lg),
        CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(Colors.orange)),
        const SizedBox(height: AppSpacing.lg),
        Text('正在扫描突发热点新闻...', style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.sm),
        Text('东方财富实时资讯 → 关键词初筛 → AI决策引擎', style: AppText.caption.copyWith(color: colors.textHint)),
      ]),
    ));
  }

  /// AI分析中视图
  Widget _buildAnalyzingView(AppColorScheme colors) {
    return Center(child: Container(
      margin: const EdgeInsets.all(AppSpacing.xxl),
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 48, height: 48,
          child: CircularProgressIndicator(strokeWidth: 3, valueColor: AlwaysStoppedAnimation(colors.primary)),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('AI决策引擎分析中', style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
        const SizedBox(height: AppSpacing.sm),
        Text('验真定性 → 逻辑链推演 → 标的锁定 → 参数生成', style: AppText.caption.copyWith(color: colors.textHint)),
      ]),
    ));
  }

  /// 错误视图
  Widget _buildErrorView(AppColorScheme colors) {
    return Center(child: Container(
      margin: const EdgeInsets.all(AppSpacing.xxl),
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.error.withOpacity(0.3)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline, size: 48, color: colors.error),
        const SizedBox(height: AppSpacing.md),
        Text('热点追踪失败', style: AppText.h3.copyWith(color: colors.textPrimary)),
        const SizedBox(height: AppSpacing.sm),
        Text(_error ?? '', style: AppText.body2.copyWith(color: colors.textSecondary), textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.lg),
        ElevatedButton.icon(onPressed: _startFullScan, icon: const Icon(Icons.refresh, size: 18), label: const Text('重新扫描')),
      ]),
    ));
  }

  /// 状态横幅
  Widget _buildStatusBanner(AppColorScheme colors) {
    final hasGO = _results.any((r) => r.actionSignal == ActionSignal.go);
    final totalNews = _filteredNews.length;
    final analyzed = _results.length;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          (hasGO ? Colors.red : Colors.orange).withOpacity(0.15),
          (hasGO ? Colors.red : Colors.orange).withOpacity(0.03),
        ]),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: (hasGO ? Colors.red : Colors.orange).withOpacity(0.3)),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.orange, Colors.red]),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: const Icon(Icons.local_fire_department, color: Colors.white, size: 18),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            hasGO ? '🔥 检测到可狙击热点！' : '📊 热点扫描报告',
            style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            '初筛$totalNews条突发新闻 · 极智已分析$analyzed条${hasGO ? " · 发现GO信号" : ""}',
            style: AppText.caption.copyWith(color: colors.textHint),
          ),
        ])),
      ]),
    );
  }

  // ================================================================
  // ★ 核心卡片 - 重新设计的专业排版
  // ================================================================

  /// 单条AI决策结果卡片
  Widget _buildResultCard(HotTrackResult result, AppColorScheme colors) {
    final isGO = result.actionSignal == ActionSignal.go;
    final isREJECT = result.actionSignal == ActionSignal.reject;
    final isWAIT = result.actionSignal == ActionSignal.wait;
    final signalColor = isGO ? Colors.red : (isREJECT ? Colors.grey : Colors.orange);
    final ratingColor = _getRatingColor(result.newsRating);

    return Container(
      decoration: BoxDecoration(
        color: colors.glassCard,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: signalColor.withOpacity(0.25)),
        boxShadow: AppShadow.card,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── 1. 决策信号头部（新闻标题区） ──
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左侧信号色条
              Container(
                width: 4,
                decoration: BoxDecoration(
                  color: signalColor,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(AppRadius.lg),
                    bottomLeft: Radius.circular(AppRadius.lg),
                  ),
                ),
              ),
              // 新闻内容
              Expanded(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [signalColor.withOpacity(0.08), signalColor.withOpacity(0.01)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // 信号 + 评级 + 时间 一行
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // 信号标签
                        _buildSignalBadge(result.signalLabel, signalColor),
                        const SizedBox(width: 8),
                        // 评级标签
                        _buildRatingBadge(result.ratingLabel, ratingColor),
                        const Spacer(),
                        // 新闻时间
                        if (result.newsTime.isNotEmpty)
                          Text(NewsService.formatTime(result.newsTime),
                            style: TextStyle(
                              color: colors.textHint,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            )),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // 新闻标题 - 加大字号和行高
                    Text(result.newsTitle,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.55,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          ),
        ),

        // ── 2. 核心逻辑区（独立展示） ──
        if (result.coreLogic.isNotEmpty && result.coreLogic != '未识别')
          _buildCoreLogicSection(result.coreLogic, signalColor, colors),

        // ── 3. REJECT 时简化显示 ──
        if (isREJECT) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
            child: Row(children: [
              Icon(Icons.block, color: Colors.grey, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text('极智判定无爆炒价值，已下达熔断指令',
                style: AppText.body2.copyWith(color: colors.textSecondary))),
            ]),
          ),
        ],

        // ── 4. 核心标的池 ──
        if (!isREJECT && result.targets.isNotEmpty) ...[
          _buildSectionDivider(colors),
          _buildTargetsSection(result.targets, colors),
        ],

        // ── 5. 执行参数面板 ──
        if (isGO && result.executionParams != null) ...[
          _buildSectionDivider(colors),
          _buildExecutionPanel(result.executionParams!, colors),
        ],

        // ── 6. 一键买入操作栏（仅S/A级GO信号且标的≥3只）──
        if (isGO && result.isActionable && result.targets.length >= 3) ...[
          _buildSectionDivider(colors),
          _buildOneClickBuyButton(result, colors),
        ],
      ]),
    );
  }

  /// 信号标签（胶囊式）
  Widget _buildSignalBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.5), width: 1),
      ),
      child: Text(label,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.5,
          height: 1.2,
        )),
    );
  }

  /// 评级标签（渐变胶囊）
  Widget _buildRatingBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [color, color.withOpacity(0.7)]),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w900,
          height: 1.2,
        )),
    );
  }

  /// 核心逻辑区块 - 带引号装饰
  Widget _buildCoreLogicSection(String logic, Color signalColor, AppColorScheme colors) {
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: signalColor.withOpacity(0.04),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: signalColor.withOpacity(0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 引号装饰
          Text('❝',
            style: TextStyle(
              color: signalColor.withOpacity(0.35),
              fontSize: 20,
              height: 1.0,
            )),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('核心逻辑',
                  style: TextStyle(
                    color: signalColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                    height: 1.2,
                  )),
                const SizedBox(height: 4),
                Text(logic,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.6,
                    letterSpacing: 0.15,
                  )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 区块分割线
  Widget _buildSectionDivider(AppColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 2),
      child: Divider(
        color: colors.glassBorder,
        thickness: 0.5,
        height: 1,
      ),
    );
  }

  /// 核心标的池区块
  Widget _buildTargetsSection(List<TargetStock> targets, AppColorScheme colors) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 区块标题
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(Icons.gps_fixed, size: 13, color: Colors.red),
          ),
          const SizedBox(width: 6),
          Text('核心标的池', style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            height: 1.3,
          )),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('${targets.length}只', style: TextStyle(
              color: Colors.red,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              height: 1.3,
            )),
          ),
        ]),
      ),
      // 标的卡片
      ...targets.asMap().entries.map((entry) {
        final idx = entry.key;
        final target = entry.value;
        return _buildTargetCard(target, idx + 1, colors);
      }),
    ]);
  }

  /// 标的股票卡片 - 升级版
  Widget _buildTargetCard(TargetStock target, int rank, AppColorScheme colors) {
    final hasQuote = target.price != null && target.price! > 0;
    final chg = target.changePct ?? 0;
    final isUp = chg >= 0;
    final chgColor = isUp ? colors.up : colors.down;

    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => StockAnalysisScreen(symbol: target.code),
        ));
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(AppSpacing.lg, 4, AppSpacing.lg, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceVariant.withOpacity(0.3),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: colors.glassBorder.withOpacity(0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 排名序号
            Container(
              width: 26, height: 26,
              decoration: BoxDecoration(
                gradient: rank <= 3
                    ? LinearGradient(colors: [Colors.red.shade400, Colors.orange.shade400])
                    : null,
                color: rank > 3 ? colors.surfaceVariant : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(child: Text('$rank',
                style: TextStyle(
                  color: rank <= 3 ? Colors.white : colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ))),
            ),
            const SizedBox(width: 10),
            // 股票信息
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // 名称 + 代码
              Row(children: [
                Text(target.name, style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                )),
                const SizedBox(width: 5),
                Text(target.code, style: TextStyle(
                  color: colors.textHint,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                )),
              ]),
              const SizedBox(height: 3),
              // 选股理由
              Text(target.reason,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  height: 1.45,
                  letterSpacing: 0.1,
                ),
                maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 5),
              // 标签行
              Row(children: [
                if (target.marketCap > 0)
                  _buildTag('流通${target.marketCap.toStringAsFixed(0)}亿', Colors.blue),
                if (hasQuote) ...[
                  const SizedBox(width: 6),
                  _buildTag(
                    '${target.price!.toStringAsFixed(2)} ${isUp ? "+" : ""}${chg.toStringAsFixed(2)}%',
                    chgColor,
                  ),
                ],
              ]),
            ])),
            // 箭头
            Icon(Icons.chevron_right, color: colors.textHint, size: 18),
          ],
        ),
      ),
    );
  }

  /// 小标签组件
  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        height: 1.3,
      )),
    );
  }

  /// 执行参数面板 - 表格化
  Widget _buildExecutionPanel(ExecutionParams params, AppColorScheme colors) {
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Colors.red.withOpacity(0.06), Colors.orange.withOpacity(0.02)]),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.red.withOpacity(0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 标题行
        Row(children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(Icons.tune, size: 13, color: Colors.red),
          ),
          const SizedBox(width: 6),
          Text('量化执行参数', style: TextStyle(
            color: colors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            height: 1.3,
          )),
        ]),
        const SizedBox(height: 10),
        // 参数表格
        _buildParamRow('竞价量倍率', '≥${params.minBidVolumeMultiplier.toStringAsFixed(2)}倍', colors),
        _buildParamRow('开盘涨幅区间', params.openingRange, colors),
        _buildParamRow('触发动作', params.triggerAction, colors),
        _buildParamRow('硬止损', params.hardStopLoss, colors),
      ]),
    );
  }

  /// 参数行 - 左标签右值
  Widget _buildParamRow(String label, String value, AppColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(width: 76, child: Text(label, style: TextStyle(
          color: colors.textHint,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          height: 1.3,
        ))),
        Expanded(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: colors.surfaceVariant.withOpacity(0.4),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(value, style: TextStyle(
            color: colors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.3,
          )),
        )),
      ]),
    );
  }

  /// 评级颜色
  Color _getRatingColor(NewsRating rating) {
    switch (rating) {
      case NewsRating.s: return Colors.red;
      case NewsRating.a: return Colors.orange;
      case NewsRating.b: return Colors.blue;
      case NewsRating.c: return Colors.grey;
    }
  }

  /// 一键买入按钮
  Widget _buildOneClickBuyButton(HotTrackResult result, AppColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
      child: Column(children: [
        // 双按钮：热点投资 + 轻量投资
        Row(children: [
          // 热点投资按钮（橙黄色）
          Expanded(
            child: SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () => _onOneClickBuy(result, isLite: false),
                icon: const Icon(Icons.whatshot, color: Colors.white, size: 18),
                label: Text('热点·¥30K',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.hotInvestAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                  shadowColor: colors.hotInvestAccent.withOpacity(0.4),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 轻量投资按钮（青色）
          Expanded(
            child: SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () => _onOneClickBuy(result, isLite: true),
                icon: const Icon(Icons.analytics_outlined, color: Colors.white, size: 18),
                label: Text('轻量·¥3.3K',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.liteInvestAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                  shadowColor: colors.liteInvestAccent.withOpacity(0.4),
                ),
              ),
            ),
          ),
        ]),

        // 标的预览
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 6, runSpacing: 4,
          children: result.targets.take(3).map((t) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${t.name}(${t.code})',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                )),
            );
          }).toList(),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('热点:每只上限¥30,000 | 轻量:每只上限¥3,333',
          style: TextStyle(color: colors.textHint, fontSize: 10)),
      ]),
    );
  }

  /// 执行一键买入
  Future<void> _onOneClickBuy(HotTrackResult result, {bool isLite = false}) async {
    final investService = isLite ? LiteInvestmentService() : HotInvestmentService();
    final investLabel = isLite ? '轻量投资' : '热点投资';
    final investLimit = isLite ? '¥3,333' : '¥30,000';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AppColors.of(context);
        return AlertDialog(
          backgroundColor: c.surface,
          title: Row(children: [
            Icon(isLite ? Icons.analytics_outlined : Icons.whatshot, color: isLite ? c.liteInvestAccent : c.hotInvestAccent, size: 24),
            const SizedBox(width: 8),
            Text('确认$investLabel建仓', style: AppText.h3.copyWith(color: c.textPrimary)),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.newsTitle, style: AppText.body2.copyWith(color: c.textSecondary)),
              const SizedBox(height: AppSpacing.md),
              Text('将以当前实时价格买入以下3只股票：', style: AppText.caption.copyWith(color: c.textHint)),
              const SizedBox(height: AppSpacing.sm),
              ...result.targets.take(3).map((t) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Icon(Icons.circle, size: 6, color: c.primary),
                  const SizedBox(width: 6),
                  Text('${t.name}(${t.code})', style: AppText.body2.copyWith(color: c.textPrimary)),
                ]),
              )),
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: c.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.info_outline, size: 14, color: c.textSecondary),
                    const SizedBox(width: 4),
                    Text('持仓规则', style: AppText.caption.copyWith(color: c.textPrimary, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 4),
                  Text('• 每只股票最多 $investLimit\n• 止盈: +10%\n• 止损: ${result.executionParams?.hardStopLoss ?? "硬止损线"}\n• 最长持有: 5个交易日',
                    style: AppText.caption.copyWith(color: c.textSecondary)),
                ]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: AppText.body2.copyWith(color: c.textSecondary)),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('确认买入'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isLite ? c.liteInvestAccent : c.hotInvestAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    // 执行买入
    try {
      final portfolio = await investService.createPortfolioFromHotTrack(result: result);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$investLabel建仓成功！${portfolio.positions.length}只股票已买入'),
          backgroundColor: isLite ? AppColors.of(context).liteInvestAccent : AppColors.of(context).hotInvestAccent,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '查看',
            textColor: Colors.white,
            onPressed: () {
              Navigator.push(
                context,
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) =>
                    isLite
                      ? LiteInvestmentDetailScreen(service: LiteInvestmentService(), portfolioId: portfolio.id)
                      : HotInvestmentDetailScreen(service: _investService, portfolioId: portfolio.id),
                  transitionsBuilder: (context, animation, secondaryAnimation, child) {
                    const begin = Offset(1.0, 0.0);
                    const end = Offset.zero;
                    const curve = Curves.easeOutCubic;
                    var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                    return SlideTransition(position: animation.drive(tween), child: child);
                  },
                  transitionDuration: const Duration(milliseconds: 350),
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('建仓失败: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
