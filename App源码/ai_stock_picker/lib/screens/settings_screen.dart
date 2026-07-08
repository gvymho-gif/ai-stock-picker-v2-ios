/// 设置页面
///
/// 提供主题切换、AI模型配置等功能

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../main.dart' show ThemeInheritedWidget;
import '../services/theme_service.dart';
import '../services/ai_model_service.dart';
import '../services/server_config_service.dart';
import '../services/portfolio_sync_service.dart';
import '../services/backup_service.dart';
import '../services/jianguoyun_service.dart';
import '../services/expert_performance_service.dart';
import '../services/trading_day_cloud_service.dart';
import '../services/speed_investment_service.dart';
import '../services/hot_investment_service.dart';
import '../services/lite_investment_service.dart';
import '../models/trading_day_record.dart';
import 'ai_model_config_screen.dart';
import 'trading_day_records_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _activeModelName = '未配置';
  bool _batchUploading = false;
  bool _batchDownloading = false;
  String _serverUrl = '';
  String _serverToken = '';
  bool _serverConfigured = false;
  bool _syncing = false;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _loadActiveModel();
    _loadServerConfig();
  }

  void _loadServerConfig() async {
    final url = await ServerConfigService.getServerUrl();
    final token = await ServerConfigService.getToken();
    if (mounted) {
      setState(() {
        _serverUrl = url;
        _serverToken = token;
        _serverConfigured = url.isNotEmpty && token.isNotEmpty;
      });
    }
  }

  void _loadActiveModel() async {
    final model = await AIModelService.getActiveModel();
    if (mounted) {
      setState(() {
        _activeModelName = model?.name ?? '未配置';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeService = ThemeInheritedWidget.of(context);
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors.backgroundGradient,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back_ios,
              color: colors.textPrimary,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            '设置',
            style: AppText.h2.copyWith(color: colors.textPrimary),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // AI模型设置卡片
            _buildSettingsCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'AI模型',
                      style: AppText.body1.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _buildSettingItem(
                    context,
                    icon: Icons.smart_toy_outlined,
                    title: 'AI模型配置',
                    subtitle: '当前模型：$_activeModelName',
                    colors: colors,
                    showArrow: true,
                    onTap: () {
                      Navigator.push(
                        context,
                        PageRouteBuilder(
                          pageBuilder: (_, __, ___) => const AIModelConfigScreen(),
                          transitionsBuilder: (_, anim, __, child) =>
                              SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(1, 0),
                                  end: Offset.zero,
                                ).animate(anim),
                                child: child,
                              ),
                        ),
                      ).then((_) => _loadActiveModel());
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 选股服务器设置卡片
            _buildSettingsCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '选股服务器',
                      style: AppText.body1.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _buildSettingItem(
                    context,
                    icon: Icons.dns_outlined,
                    title: '服务器地址',
                    subtitle: _serverUrl.isNotEmpty
                        ? _serverUrl
                        : '未配置（请填写百度云服务器地址）',
                    colors: colors,
                    showArrow: true,
                    onTap: () => _showServerUrlDialog(context, colors),
                  ),
                  _buildDivider(colors),
                  _buildSettingItem(
                    context,
                    icon: Icons.vpn_key_outlined,
                    title: '认证Token',
                    subtitle: _serverToken.isNotEmpty
                        ? '已配置 (${_serverToken.length}位)'
                        : '未配置',
                    colors: colors,
                    showArrow: true,
                    onTap: () => _showServerTokenDialog(context, colors),
                  ),
                  _buildDivider(colors),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Icon(
                          _serverConfigured ? Icons.check_circle : Icons.warning_amber_rounded,
                          size: 16,
                          color: _serverConfigured ? colors.up : colors.warning,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _serverConfigured ? '服务器已就绪，选股策略安全托管' : '配置后选股逻辑将运行在您的服务器',
                          style: AppText.caption.copyWith(
                            color: _serverConfigured ? colors.up : colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _buildDivider(colors),
                  _buildSettingItem(
                    context,
                    icon: Icons.sync,
                    title: '同步投资组合到服务器',
                    subtitle: _syncing ? '正在同步...' : '上传持仓数据到云端',
                    colors: colors,
                    showArrow: true,
                    onTap: _syncing ? null : _syncPortfolios,
                  ),
                  _buildSettingItem(
                    context,
                    icon: Icons.cloud_download,
                    title: '从服务器恢复投资组合',
                    subtitle: _restoring ? '正在恢复...' : '下载云端数据到本设备',
                    colors: colors,
                    showArrow: true,
                    onTap: _restoring ? null : _restorePortfolios,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 风格切换卡片
            _buildSettingsCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '外观设置',
                      style: AppText.body1.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _ThemeSwitchTile(
                    themeService: themeService,
                    colors: colors,
                    isDark: isDark,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Gitee 备份设置卡片
            _buildSettingsCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '云备份（Gitee）',
                      style: AppText.body1.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _GiteeTokenTile(colors: colors),
                  _buildDivider(colors),
                  _buildSettingItem(
                    context,
                    icon: Icons.help_outline,
                    title: '获取 Gitee Token 帮助',
                    subtitle: '点击查看如何生成 Gitee 私人令牌',
                    colors: colors,
                    showArrow: true,
                    onTap: () => _showGiteeHelp(context, colors),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 坚果云 WebDAV 备份设置卡片
            _buildSettingsCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '云备份（坚果云 WebDAV）',
                      style: AppText.body1.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _JianguoyunTile(colors: colors),
                  _buildDivider(colors),
                  // 一键上传/下载全部
                  _buildSettingItem(
                    context,
                    icon: _batchUploading
                        ? Icons.cloud_sync
                        : (_batchDownloading ? Icons.cloud_download : Icons.cloud_done_outlined),
                    title: '一键备份全部',
                    subtitle: _batchUploading
                        ? '正在上传 收益统计/极速投资/热点投资/轻量投资...'
                        : (_batchDownloading
                            ? '正在下载全部模块...'
                            : '一键上传或下载全部4个模块到坚果云'),
                    colors: colors,
                    onTap: _batchUploading || _batchDownloading ? null : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildBatchButton(
                            colors: colors,
                            label: '⬆️ 一键上传',
                            isLoading: _batchUploading,
                            isDisabled: _batchDownloading,
                            onPressed: _batchUploadAll,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildBatchButton(
                            colors: colors,
                            label: '⬇️ 一键下载',
                            isLoading: _batchDownloading,
                            isDisabled: _batchUploading,
                            onPressed: _batchDownloadAll,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildDivider(colors),
                  _buildSettingItem(
                    context,
                    icon: Icons.help_outline,
                    title: '如何获取坚果云应用密码',
                    subtitle: '坚果云 → 账户信息 → 安全选项 → 添加应用密码',
                    colors: colors,
                    showArrow: true,
                    onTap: () => _showJianguoyunHelp(context, colors),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 数据管理卡片
            _buildSettingsCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '数据管理',
                      style: AppText.body1.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _buildSettingItem(
                    context,
                    icon: Icons.table_chart_outlined,
                    title: '交易日记录',
                    subtitle: '查看和管理每日选股收益记录',
                    colors: colors,
                    showArrow: true,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TradingDayRecordsScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 关于卡片
            _buildSettingsCard(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '关于',
                      style: AppText.body1.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _buildSettingItem(
                    context,
                    icon: Icons.info_outline,
                    title: '版本信息',
                    subtitle: '蓝图极智 v1.0',
                    colors: colors,
                  ),
                  _buildDivider(colors),
                  _buildSettingItem(
                    context,
                    icon: Icons.code,
                    title: '技术支持',
                    subtitle: 'Flutter 3.0.0 + Dart 2.17.0',
                    colors: colors,
                    showArrow: false,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // 底部说明
            Center(
              child: Text(
                '更多功能开发中，敬请期待',
                style: AppText.caption.copyWith(color: colors.textHint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ================================================================
  // 坚果云一键上传/下载全部
  // ================================================================

  /// 一键上传全部 4 个模块到坚果云
  Future<void> _batchUploadAll() async {
    final configured = await JianguoyunService.isConfigured();
    if (!configured) {
      if (mounted) _showSnackBar('请先在下方配置坚果云应用名称和应用密码');
      return;
    }
    setState(() => _batchUploading = true);
    final results = <String, bool>{};
    try {
      // 1. 收益统计
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
        final r = await JianguoyunService.upload('收益统计', json);
        results['收益统计'] = r['ok'] == true;
      } catch (e) { results['收益统计'] = false; }

      // 2. 极速投资
      SpeedInvestmentService? speedService;
      try {
        speedService = SpeedInvestmentService();
        await speedService.init();
        final r = await speedService.uploadToJianguoyun();
        results['极速投资'] = r['ok'] == true;
      } catch (e) { results['极速投资'] = false; }
      speedService?.dispose();

      // 3. 热点投资
      try {
        final hotService = HotInvestmentService();
        await hotService.load();
        final r = await hotService.uploadToJianguoyun();
        results['热点投资'] = r['ok'] == true;
      } catch (e) { results['热点投资'] = false; }

      // 4. 轻量投资
      try {
        final liteService = LiteInvestmentService();
        await liteService.load();
        final r = await liteService.uploadToJianguoyun();
        results['轻量投资'] = r['ok'] == true;
      } catch (e) { results['轻量投资'] = false; }

      if (mounted) {
        final ok = results.values.where((v) => v).length;
        final fail = results.entries.where((e) => !e.value).map((e) => e.key);
        if (fail.isEmpty) {
          _showSnackBar('🥜 全部上传成功（4/4）');
        } else {
          final failedNames = fail.join('、');
          _showSnackBar('🥜 上传完成 $ok/4，失败: $failedNames');
        }
      }
    } finally {
      if (mounted) setState(() => _batchUploading = false);
    }
  }

  /// 一键从坚果云下载全部 4 个模块
  Future<void> _batchDownloadAll() async {
    final configured = await JianguoyunService.isConfigured();
    if (!configured) {
      if (mounted) _showSnackBar('请先在下方配置坚果云应用名称和应用密码');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认一键下载全部'),
        content: const Text('坚果云数据将覆盖本地所有数据（收益统计、极速投资、热点投资、轻量投资），是否继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认下载')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _batchDownloading = true);
    final results = <String, bool>{};
    final errors = <String, String>{};
    try {
      // 1. 收益统计
      try {
        final r = await JianguoyunService.downloadWithDetails('收益统计');
        final content = r['content'] as String?;
        if (r['ok'] == true && content != null && content.isNotEmpty) {
          final data = jsonDecode(content);
          if (data['tradingDayRecords'] is List) {
            final records = (data['tradingDayRecords'] as List)
                .map((j) => TradingDayRecord.fromJson(j as Map<String, dynamic>))
                .toList();
            await TradingDayCloudService.saveRecordsLocally(records);
          }
          await ExpertPerformanceService.restoreFromBackupJson(content);
          results['收益统计'] = true;
        } else {
          results['收益统计'] = false;
          errors['收益统计'] = r['error'] ?? '云端无数据';
          debugPrint('[坚果云下载] 收益统计失败: ${r['error']}, HTTP ${r['statusCode']}');
        }
      } catch (e) {
        results['收益统计'] = false;
        errors['收益统计'] = '异常: $e';
        debugPrint('[坚果云下载] 收益统计异常: $e');
      }

      // 2. 极速投资
      SpeedInvestmentService? speedService;
      try {
        speedService = SpeedInvestmentService();
        await speedService.init();
        final r = await speedService.downloadFromJianguoyun();
        if (r['ok'] == true) {
          results['极速投资'] = true;
        } else {
          results['极速投资'] = false;
          errors['极速投资'] = r['error'] ?? '云端无数据';
        }
      } catch (e) {
        results['极速投资'] = false;
        errors['极速投资'] = '异常: $e';
      }
      speedService?.dispose();

      // 3. 热点投资
      try {
        final hotService = HotInvestmentService();
        await hotService.load();
        final r = await hotService.downloadFromJianguoyun();
        if (r['ok'] == true) {
          results['热点投资'] = true;
        } else {
          results['热点投资'] = false;
          errors['热点投资'] = r['error'] ?? '云端无数据';
          debugPrint('[坚果云下载] 热点投资失败: ${r['error']}');
        }
      } catch (e) {
        results['热点投资'] = false;
        errors['热点投资'] = '异常: $e';
        debugPrint('[坚果云下载] 热点投资异常: $e');
      }

      // 4. 轻量投资
      try {
        final liteService = LiteInvestmentService();
        await liteService.load();
        final r = await liteService.downloadFromJianguoyun();
        if (r['ok'] == true) {
          results['轻量投资'] = true;
        } else {
          results['轻量投资'] = false;
          errors['轻量投资'] = r['error'] ?? '云端无数据';
          debugPrint('[坚果云下载] 轻量投资失败: ${r['error']}');
        }
      } catch (e) {
        results['轻量投资'] = false;
        errors['轻量投资'] = '异常: $e';
      }

      if (mounted) {
        final ok = results.values.where((v) => v).length;
        final failedEntries = results.entries.where((e) => !e.value);
        if (failedEntries.isEmpty) {
          _showSnackBar('🥜 全部下载成功（4/4）');
        } else {
          // ★ 显示每个失败模块的具体错误信息
          final failDetails = failedEntries.map((e) {
            final err = errors[e.key] ?? '未知错误';
            return '${e.key}: $err';
          }).join('\n');
          _showResultDialog('坚果云下载结果', '✅ 成功: $ok/4\n\n❌ 失败:\n$failDetails');
        }
      }
    } finally {
      if (mounted) setState(() => _batchDownloading = false);
    }
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// 显示详细结果对话框
  void _showResultDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
        ],
      ),
    );
  }

  Widget _buildSettingsCard(BuildContext context, {required Widget child}) {
    final colors = AppColors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.border.withOpacity(0.5)),
        boxShadow: [
          BoxShadow(
            color: colors.shadowDark,
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildSettingItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required AppColorScheme colors,
    bool showArrow = false,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(
                icon,
                color: colors.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.body1.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppText.caption.copyWith(color: colors.textHint),
                  ),
                ],
              ),
            ),
            if (showArrow)
              Icon(
                Icons.arrow_forward_ios,
                color: colors.textHint,
                size: 16,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchButton({
    required AppColorScheme colors,
    required String label,
    required bool isLoading,
    required bool isDisabled,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 40,
      child: ElevatedButton(
        onPressed: isLoading || isDisabled ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.primary.withOpacity(0.1),
          foregroundColor: colors.primary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            side: BorderSide(color: colors.primary.withOpacity(0.3)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        ),
        child: isLoading
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildDivider(AppColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(left: 68),
      child: Divider(
        color: colors.divider,
        height: 1,
      ),
    );
  }

  // ============================================================
  // 服务器配置对话框
  // ============================================================

  void _showServerUrlDialog(BuildContext context, AppColorScheme colors) {
    final controller = TextEditingController(text: _serverUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text('服务器地址', style: TextStyle(color: colors.textPrimary)),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'http://你的服务器IP:8000',
            hintStyle: TextStyle(color: colors.textHint),
            border: OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: colors.primary),
            ),
          ),
          style: TextStyle(color: colors.textPrimary),
          keyboardType: TextInputType.url,
          autocorrect: false,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: colors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              await ServerConfigService.saveServerUrl(controller.text.trim());
              Navigator.pop(ctx);
              _loadServerConfig();
            },
            child: Text('保存', style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  void _showServerTokenDialog(BuildContext context, AppColorScheme colors) {
    final controller = TextEditingController(text: _serverToken);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text('认证Token', style: TextStyle(color: colors.textPrimary)),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: '后端设置的 AUTH_TOKEN',
            hintStyle: TextStyle(color: colors.textHint),
            border: OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: colors.primary),
            ),
          ),
          style: TextStyle(color: colors.textPrimary),
          obscureText: true,
          autocorrect: false,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消', style: TextStyle(color: colors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              await ServerConfigService.saveToken(controller.text.trim());
              Navigator.pop(ctx);
              _loadServerConfig();
            },
            child: Text('保存', style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _syncPortfolios() async {
    setState(() => _syncing = true);
    try {
      final results = await PortfolioSyncService.syncAll();
      if (mounted) {
        final msg = results.entries.map((e) => '${e.key}: ${e.value}').join('\n');
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('同步结果'),
            content: Text(msg.isNotEmpty ? msg : '暂无投资组合数据'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('同步失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _restorePortfolios() async {
    setState(() => _restoring = true);
    try {
      final results = await PortfolioSyncService.restoreAll();
      if (mounted) {
        final msg = results.entries.map((e) => '${e.key}: ${e.value}').join('\n');
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('恢复结果'),
            content: Text(msg.isNotEmpty ? msg : '服务器无投资组合数据'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }
}

/// 主题切换组件
class _ThemeSwitchTile extends StatelessWidget {
  final ThemeService themeService;
  final AppColorScheme colors;
  final bool isDark;

  const _ThemeSwitchTile({
    Key? key,
    required this.themeService,
    required this.colors,
    required this.isDark,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          // 主题预览
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // 深色模式预览
                Expanded(
                  child: _ThemePreviewCard(
                    title: '夜晚模式',
                    icon: Icons.dark_mode,
                    isSelected: isDark,
                    colors: colors,
                    onTap: () => themeService.setThemeMode(ThemeMode.dark),
                    previewColors: [
                      const Color(0xFF0A0A14),
                      const Color(0xFF1A1B3A),
                    ],
                    textColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                // 浅色模式预览
                Expanded(
                  child: _ThemePreviewCard(
                    title: '白天模式',
                    icon: Icons.light_mode,
                    isSelected: !isDark,
                    colors: colors,
                    onTap: () => themeService.setThemeMode(ThemeMode.light),
                    previewColors: [
                      const Color(0xFFFFFFFF),
                      const Color(0xFFF0F0F5),
                    ],
                    textColor: const Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
          ),
          // 当前状态
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isDark ? Icons.dark_mode : Icons.light_mode,
                  color: colors.primary,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '当前：${isDark ? '夜晚模式' : '白天模式'}',
                  style: AppText.body2.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 主题预览卡片
class _ThemePreviewCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final AppColorScheme colors;
  final VoidCallback onTap;
  final List<Color> previewColors;
  final Color textColor;

  const _ThemePreviewCard({
    Key? key,
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.colors,
    required this.onTap,
    required this.previewColors,
    required this.textColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: previewColors,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isSelected ? colors.primary : colors.border,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: colors.primary.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected
                  ? colors.primary
                  : textColor.withOpacity(0.7),
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: AppText.caption.copyWith(
                color: textColor,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            if (isSelected) ...[
              const SizedBox(height: 4),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Gitee Token 输入组件
class _GiteeTokenTile extends StatefulWidget {
  final AppColorScheme colors;
  const _GiteeTokenTile({Key? key, required this.colors}) : super(key: key);
  @override
  State<_GiteeTokenTile> createState() => _GiteeTokenTileState();
}

class _GiteeTokenTileState extends State<_GiteeTokenTile> {
  final _ctrl = TextEditingController();
  bool _saving = false;
  bool _isExpanded = false; // 是否展开输入框
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  void _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('gitee_token') ?? '';
    if (mounted) _ctrl.text = token;
    setState(() => _status = token.isNotEmpty ? '已配置' : '未配置');
  }

  void _toggleExpand() {
    setState(() => _isExpanded = !_isExpanded);
  }

  void _save() async {
    // 收起键盘
    FocusManager.instance.primaryFocus?.unfocus();

    if (_ctrl.text.isEmpty) {
      setState(() => _status = '请输入Token');
      return;
    }
    setState(() {
      _saving = true;
      _status = '验证中...';
    });
    try {
      final ok = await BackupService.saveGiteeToken(_ctrl.text.trim());
      if (mounted) {
        setState(() {
          _saving = false;
          _status = ok ? '✓ 已保存' : '⚠ 验证失败';
          _isExpanded = false; // 保存后收起输入框
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? 'Gitee Token 已保存，验证通过' : 'Token 已保存但验证失败，请检查是否正确'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _status = '保存失败: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 收起状态：显示点击展开的按钮
        if (!_isExpanded)
          InkWell(
            onTap: _toggleExpand,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: widget.colors.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    _status == '已配置' ? Icons.check_circle : Icons.key,
                    color: _status == '已配置' ? Colors.green : Colors.grey,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _status == '已配置' ? 'Gitee Token 已配置 (点击修改)' : '点击配置 Gitee Token',
                      style: AppText.body2.copyWith(
                        color: widget.colors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: widget.colors.textHint,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        
        // 展开状态：显示输入框和保存按钮
        if (_isExpanded) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Gitee 私人令牌',
                    hintText: '粘贴你的Token',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: _toggleExpand,
                          icon: const Icon(Icons.close, color: Colors.grey),
                          tooltip: '取消',
                        ),
                        IconButton(
                          onPressed: _save,
                          icon: const Icon(Icons.save, color: Colors.green),
                          tooltip: '保存',
                        ),
                      ],
                    ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '状态：$_status',
            style: AppText.caption.copyWith(color: widget.colors.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// 显示 Gitee Token 获取帮助
void _showGiteeHelp(BuildContext context, AppColorScheme colors) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('获取 Gitee 私人令牌', style: AppText.h3),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('1. 打开 https://gitee.com', style: AppText.body1),
            const SizedBox(height: 8),
            Text('2. 登录后点击右上角头像 → 设置', style: AppText.body1),
            const SizedBox(height: 8),
            Text('3. 左侧菜单选"私人令牌"', style: AppText.body1),
            const SizedBox(height: 8),
            Text('4. 点击"生成新令牌"', style: AppText.body1),
            const SizedBox(height: 8),
            Text('5. 权限勾选：projects + contents', style: AppText.body1),
            const SizedBox(height: 8),
            Text('6. 提交后会显示 Token，立即复制！', style: AppText.body1.copyWith(color: Colors.red)),
            const SizedBox(height: 12),
            Text('仓库名：ai-stock-picker-backup（自动创建）', style: AppText.body1.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 坚果云 应用名称+应用密码 输入组件
class _JianguoyunTile extends StatefulWidget {
  final AppColorScheme colors;
  const _JianguoyunTile({Key? key, required this.colors}) : super(key: key);
  @override
  State<_JianguoyunTile> createState() => _JianguoyunTileState();
}

class _JianguoyunTileState extends State<_JianguoyunTile> {
  final _nameCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _saving = false;
  bool _isExpanded = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _loadConfig() async {
    final name = await JianguoyunService.getAppName() ?? '';
    final pwd = await JianguoyunService.getAppPassword() ?? '';
    if (mounted) {
      _nameCtrl.text = name;
      _pwdCtrl.text = pwd;
      setState(() => _status = (name.isNotEmpty && pwd.isNotEmpty) ? '已配置' : '未配置');
    }
  }

  void _toggleExpand() => setState(() => _isExpanded = !_isExpanded);

  void _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final name = _nameCtrl.text.trim();
    final pwd = _pwdCtrl.text.trim();
    if (name.isEmpty || pwd.isEmpty) {
      setState(() => _status = '请填写完整');
      return;
    }
    setState(() { _saving = true; _status = '验证中...'; });
    try {
      final ok = await JianguoyunService.testCredentials(name, pwd);
      if (ok) {
        await JianguoyunService.saveCredentials(name, pwd);
        setState(() { _saving = false; _status = '✓ 已保存'; _isExpanded = false; });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('坚果云凭据已验证并保存'), duration: Duration(seconds: 3)),
          );
        }
      } else {
        // 验证失败也保存（可能是网络问题），让用户自行测试
        await JianguoyunService.saveCredentials(name, pwd);
        setState(() { _saving = false; _status = '⚠ 已保存（验证超时）'; _isExpanded = false; });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('凭据已保存但验证超时，可稍后重试'), duration: Duration(seconds: 3)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _saving = false; _status = '保存失败: $e'; });
      }
    }
  }

  void _clear() async {
    await JianguoyunService.clearCredentials();
    _nameCtrl.clear();
    _pwdCtrl.clear();
    setState(() => _status = '未配置');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_isExpanded)
          InkWell(
            onTap: _toggleExpand,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              decoration: BoxDecoration(
                border: Border.all(color: widget.colors.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(
                  _status == '已配置' ? Icons.check_circle : Icons.cloud_outlined,
                  color: _status == '已配置' ? Colors.green : Colors.grey, size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  _status == '已配置' ? '坚果云已配置 (点击修改)' : '点击配置坚果云应用名称和密码',
                  style: AppText.body2.copyWith(color: widget.colors.textSecondary),
                )),
                Icon(Icons.chevron_right, color: widget.colors.textHint, size: 20),
              ]),
            ),
          ),
        if (_isExpanded) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Column(children: [
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '应用名称',
                  hintText: '坚果云第三方应用名称',
                  border: OutlineInputBorder(), isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pwdCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '应用密码',
                  hintText: '坚果云生成的第三方应用密码',
                  border: OutlineInputBorder(), isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (_status.startsWith('已配置'))
                  TextButton.icon(
                    onPressed: _clear,
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                    label: const Text('清除', style: TextStyle(color: Colors.red)),
                  ),
                const Spacer(),
                TextButton(onPressed: _toggleExpand, child: const Text('取消')),
                const SizedBox(width: 8),
                _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : ElevatedButton(onPressed: _save, child: const Text('验证并保存')),
              ]),
              const SizedBox(height: 4),
              Text('状态：$_status', style: AppText.caption.copyWith(color: widget.colors.textSecondary)),
            ]),
          ),
        ],
      ],
    );
  }
}

/// 显示坚果云帮助
void _showJianguoyunHelp(BuildContext context, AppColorScheme colors) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('获取坚果云应用密码', style: AppText.h3),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('1. 登录 https://www.jianguoyun.com', style: AppText.body1),
          const SizedBox(height: 8),
          Text('2. 点击右上角头像 → 账户信息', style: AppText.body1),
          const SizedBox(height: 8),
          Text('3. 选择"安全选项"标签页', style: AppText.body1),
          const SizedBox(height: 8),
          Text('4. 在"第三方应用管理"处点击"添加应用"', style: AppText.body1),
          const SizedBox(height: 8),
          Text('5. 输入应用名称（任意，如"蓝图极智"），生成密码', style: AppText.body1),
          const SizedBox(height: 8),
          Text('6. 复制生成的"应用名称"和"应用密码"粘贴到上方', style: AppText.body1.copyWith(color: Colors.red)),
          const SizedBox(height: 12),
          Text('备份文件保存在：坚果云/蓝图极智AI选股/ 目录下', style: AppText.body1.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了')),
      ],
    ),
  );
}
