/// 极智问答 v4.0 — 太空科技感·玻璃态·极简
///
/// 设计语言：深空背景 + 玻璃态卡片 + 发光边框 + 渐变按钮
/// 对标：Perplexity/Liner 的现代AI产品设计
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../models/chat_message.dart';
import '../models/ai_model_config.dart';
import '../services/ai_qa_service.dart';
import '../services/ai_model_service.dart';
import '../services/chat_history_service.dart';
import '../services/report_generator_service.dart';
import '../widgets/ai_chart_bubble.dart';
import 'ai_model_config_screen.dart';

class AIQAScreen extends StatefulWidget {
  const AIQAScreen({Key? key}) : super(key: key);
  @override
  State<AIQAScreen> createState() => _AIQAScreenState();
}

class _AIQAScreenState extends State<AIQAScreen> with TickerProviderStateMixin {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final AIQAService _qaService = AIQAService();
  final _focusNode = FocusNode();

  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  AIModelConfig? _activeModel;

  // 打字动画
  String _displayedText = '';
  int _charIndex = 0;
  Timer? _typeTimer;
  bool _isTyping = false;

  // 加载阶段
  int _loadingStage = 0;
  static const _stageLabels = ['理解意图', '获取数据', '生成回复'];

  // 空状态推荐
  static const _categorySuggestions = {
    '大盘行情': ['今日A股大盘走势如何？', '港股市场有什么机会？', '当前市场情绪怎么样？'],
    '个股诊断': ['茅台现在值得关注吗？', '宁德时代技术面分析', '比亚迪基本面怎么样？'],
    '板块分析': ['科技板块近期表现', '新能源还有机会吗？', '医药板块资金流向'],
    '投资策略': ['当前仓位配置建议', '短线选股策略推荐', '如何判断底部信号？'],
  };

  @override
  void initState() {
    super.initState();
    _loadActiveModel();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _typeTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadActiveModel() async {
    final model = await AIModelService.getActiveModel();
    if (mounted) setState(() => _activeModel = model);
  }

  // ============================================================
  // 发送消息
  // ============================================================

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    _controller.clear();
    _focusNode.unfocus();

    final userMsg = ChatMessage(
      id: const Uuid().v4().toString().substring(0, 8),
      content: text, isUser: true, time: DateTime.now(),
    );

    setState(() {
      _messages.add(userMsg);
      _isLoading = true;
      _loadingStage = 0;
      _isTyping = false;
    });
    _scrollToBottom();

    final response = await _qaService.askQuestion(text, contextHistory: _messages);
    if (!mounted) return;

    final followUps = _generateFollowUps(text, response);
    final dataSources = _extractDataSources(response);

    final aiMsg = ChatMessage(
      id: const Uuid().v4().toString().substring(0, 8),
      content: response, isUser: false, time: DateTime.now(),
      suggestedQuestions: followUps, dataSources: dataSources,
    );

    setState(() {
      _messages.add(aiMsg);
      _isLoading = false;
      _isTyping = true;
      _displayedText = '';
      _charIndex = 0;
    });

    _startTypingAnimation(response);
    await ChatHistoryService.saveMessage(text, response);
  }

  void _startTypingAnimation(String fullText) {
    _typeTimer?.cancel();
    _charIndex = 0;
    _typeTimer = Timer.periodic(const Duration(milliseconds: 18), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_charIndex < fullText.length) {
        final step = fullText.length > 500 ? 6 : (fullText.length > 200 ? 4 : 2);
        _charIndex += step;
        if (_charIndex > fullText.length) _charIndex = fullText.length;
        setState(() => _displayedText = fullText.substring(0, _charIndex));
      } else {
        setState(() { _displayedText = fullText; _isTyping = false; });
        t.cancel();
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut,
        );
      }
    });
  }

  void _quickAsk(String q) { _controller.text = q; _sendMessage(); }

  // ============================================================
  // Build
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF8F9FC),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(child: _messages.isEmpty ? _buildEmptyState() : _buildChatList()),
          _buildInputBar(),
        ],
      ),
    );
  }

  // ============================================================
  // AppBar — 极简
  // ============================================================

  PreferredSizeWidget _buildAppBar() {
    final colors = AppColors.of(context);
    return AppBar(
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new, size: 18, color: colors.textPrimary),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlowIcon(icon: Icons.auto_awesome, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Text('极智问答', style: TextStyle(
            color: colors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          )),
        ],
      ),
      centerTitle: true,
      actions: [
        // 模型名称（无边框）
        GestureDetector(
          onTap: _activeModel != null ? () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const AIModelConfigScreen()));
            _loadActiveModel();
          } : null,
          child: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 5, height: 5,
                  decoration: BoxDecoration(
                    color: _activeModel != null ? const Color(0xFF34C759) : colors.textDisabled,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _activeModel?.name ?? '未配置',
                  style: TextStyle(
                    color: _activeModel != null ? colors.textSecondary : colors.textDisabled,
                    fontSize: 11, fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_messages.isNotEmpty)
          IconButton(
            icon: Icon(Icons.delete_outline, size: 18, color: colors.textHint),
            onPressed: _clearChat,
          ),
      ],
      flexibleSpace: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? Colors.black : const Color(0xFFF8F9FC),
        ),
      ),
      elevation: 0,
      scrolledUnderElevation: 1,
    );
  }

  // ============================================================
  // 空状态 — 中心AI圆环 + 快捷提问
  // ============================================================

  Widget _buildEmptyState() {
    final colors = AppColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 48),
          // AI 发光圆环
          _buildAIGlowOrb(colors),
          const SizedBox(height: 32),
          Text('有什么可以帮你分析？',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 0.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          Text('基于实时数据的智能投研助手',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textHint, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 32),
          // 分类卡片
          ..._categorySuggestions.entries.map((e) => _buildCategoryCard(e.key, e.value, colors)),
          const SizedBox(height: 16),
          // 历史入口
          _buildHistoryEntry(colors),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  /// AI 发光圆环
  Widget _buildAIGlowOrb(AppColorScheme colors) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 100, height: 100,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 外层光晕
          _PulsingRing(delay: 0, size: 100, color: colors.primary.withOpacity(0.08)),
          _PulsingRing(delay: 500, size: 88, color: colors.primary.withOpacity(0.12)),
          _PulsingRing(delay: 1000, size: 76, color: colors.accent.withOpacity(0.1)),
          // Logo 圆形裁剪 — 深色用黑底/白天用白底
          ClipOval(
            child: Image.asset(
              isDark ? 'assets/logo.jpg' : 'assets/logo_white_bg.png',
              width: 68,
              height: 68,
              fit: BoxFit.contain,
            ),
          ),
        ],
      ),
    );
  }

  /// 分类卡片
  Widget _buildCategoryCard(String title, List<String> questions, AppColorScheme colors) {
    final icons = {
      '大盘行情': Icons.trending_up,
      '个股诊断': Icons.analytics_outlined,
      '板块分析': Icons.grid_view_rounded,
      '投资策略': Icons.lightbulb_outline,
    };
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? colors.surface.withOpacity(0.5) : colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [colors.primary.withOpacity(0.2), colors.accent.withOpacity(0.15)]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icons[title] ?? Icons.help_outline, size: 14, color: colors.primary),
            ),
            const SizedBox(width: 10),
            Text(title, style: TextStyle(
              color: colors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          ...questions.map((q) => GestureDetector(
            onTap: _activeModel != null ? () => _quickAsk(q) : null,
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: colors.surfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.border.withOpacity(0.2)),
              ),
              child: Row(children: [
                Expanded(child: Text(q, style: TextStyle(
                  color: _activeModel != null ? colors.textSecondary : colors.textDisabled,
                  fontSize: 13, fontWeight: FontWeight.w500))),
                Icon(Icons.chevron_right, size: 14,
                  color: _activeModel != null ? colors.textHint : colors.textDisabled),
              ]),
            ),
          )),
        ],
      ),
    );
  }

  /// 历史入口
  Widget _buildHistoryEntry(AppColorScheme colors) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: ChatHistoryService.getHistory(),
      builder: (ctx, snap) {
        final h = snap.data ?? [];
        if (h.isEmpty) return const SizedBox.shrink();
        return GestureDetector(
          onTap: _showHistory,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              color: colors.surface.withOpacity(0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.border.withOpacity(0.3)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.history, size: 15, color: colors.primary),
              const SizedBox(width: 8),
              Text('历史对话 (${h.length}条)', style: TextStyle(
                color: colors.primary, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              Icon(Icons.arrow_forward_ios, size: 10, color: colors.primary.withOpacity(0.5)),
            ]),
          ),
        );
      },
    );
  }

  // ============================================================
  // 对话列表
  // ============================================================

  Widget _buildChatList() {
    final colors = AppColors.of(context);
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
      itemCount: _messages.length + (_isLoading ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == _messages.length && _isLoading) return _buildLoadingBubble();
        final msg = _messages[i];
        final isLastAI = !msg.isUser && i == _messages.length - 1 && !_isLoading;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildMessageBubble(msg, isTyping: isLastAI && _isTyping),
          if (isLastAI && !_isTyping && msg.suggestedQuestions != null && msg.suggestedQuestions!.isNotEmpty)
            _buildFollowUpChips(msg.suggestedQuestions!),
        ]);
      },
    );
  }

  // ============================================================
  // 消息气泡
  // ============================================================

  Widget _buildMessageBubble(ChatMessage msg, {bool isTyping = false}) {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (msg.isUser) return _buildUserBubble(msg, colors);
    return _buildAIBubble(msg, colors, isDark, isTyping);
  }

  Widget _buildUserBubble(ChatMessage msg, AppColorScheme colors) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [colors.primary, colors.accent],
              ),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18), topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18), bottomRight: Radius.circular(5),
              ),
              boxShadow: [
                BoxShadow(color: colors.primary.withOpacity(0.25), blurRadius: 12, offset: const Offset(0, 4)),
              ],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              SelectableText(msg.content, style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.55)),
              const SizedBox(height: 3),
              Text(
                '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}',
                style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 10),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildAIBubble(ChatMessage msg, AppColorScheme colors, bool isDark, bool isTyping) {
    final displayContent = isTyping ? _displayedText : msg.content;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // AI头像
        Container(
          width: 32, height: 32, margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [colors.primary.withOpacity(0.2), colors.accent.withOpacity(0.15)]),
            border: Border.all(color: colors.primary.withOpacity(0.3), width: 1),
          ),
          child: const Center(child: Text('AI', style: TextStyle(
            color: Color(0xFFA78BFA), fontSize: 11, fontWeight: FontWeight.w800))),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text('极智分析', style: TextStyle(
                color: colors.primaryLight, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                color: isDark ? colors.surface.withOpacity(0.4) : colors.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(5), topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16),
                ),
                border: Border.all(color: colors.primary.withOpacity(0.1)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (msg.isChartMessage && msg.chartData != null)
                  AIChartBubble(chartData: msg.chartData!, colors: colors),
                // 内容
                SelectableText(displayContent,
                  style: TextStyle(color: colors.textPrimary, fontSize: 14.5, height: 1.7)),
                if (isTyping)
                  Container(width: 2, height: 16, margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [colors.primary, colors.accent]),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                // 底部栏：时间 + 数据来源
                const SizedBox(height: 8),
                Row(children: [
                  Text(
                    '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(color: colors.textHint, fontSize: 10)),
                  const Spacer(),
                  if (msg.dataSources != null)
                    ...msg.dataSources!.take(3).map((s) => Container(
                      margin: const EdgeInsets.only(left: 5),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(s, style: TextStyle(color: colors.primary, fontSize: 9, fontWeight: FontWeight.w500)),
                    )),
                ]),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  // ============================================================
  // 追问Chips
  // ============================================================

  Widget _buildFollowUpChips(List<String> questions) {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 42, bottom: 14, top: 2),
      child: Wrap(spacing: 7, runSpacing: 7, children: questions.map((q) {
        return GestureDetector(
          onTap: _isLoading ? null : () => _quickAsk(q),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withOpacity(0.3),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.primary.withOpacity(0.15)),
            ),
            child: Text(q, style: TextStyle(
              color: colors.primaryLight, fontSize: 12.5, fontWeight: FontWeight.w500)),
          ),
        );
      }).toList()),
    );
  }

  // ============================================================
  // 加载气泡
  // ============================================================

  Widget _buildLoadingBubble() {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 32, height: 32, margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [colors.primary.withOpacity(0.2), colors.accent.withOpacity(0.15)]),
            border: Border.all(color: colors.primary.withOpacity(0.3)),
          ),
          child: const Center(child: _ThinkingIndicator()),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: colors.surface.withOpacity(0.4),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(5), topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16), bottomRight: Radius.circular(16),
            ),
            border: Border.all(color: colors.primary.withOpacity(0.1)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RichText(text: TextSpan(
              style: TextStyle(color: colors.textSecondary, fontSize: 13.5),
              children: [
                TextSpan(
                  text: _stageLabels[_loadingStage],
                  style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600),
                ),
                TextSpan(text: '中...'),
              ],
            )),
            const SizedBox(height: 10),
            SizedBox(
              width: 80, height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (_loadingStage + 1) / 3,
                  backgroundColor: colors.border.withOpacity(0.3),
                  valueColor: AlwaysStoppedAnimation(colors.primary),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  // ============================================================
  // 输入栏
  // ============================================================

  Widget _buildInputBar() {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasText = _controller.text.isNotEmpty;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.black : const Color(0xFFF8F9FC),
        border: Border(top: BorderSide(color: colors.border.withOpacity(0.2))),
      ),
      child: SafeArea(
        top: false, bottom: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: colors.surface.withOpacity(0.5),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _focusNode.hasFocus
                    ? colors.primary.withOpacity(0.4)
                    : colors.border.withOpacity(0.3),
                  width: _focusNode.hasFocus ? 1.5 : 1,
                ),
                boxShadow: _focusNode.hasFocus ? [
                  BoxShadow(color: colors.primary.withOpacity(0.1), blurRadius: 12, spreadRadius: -2),
                ] : null,
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                style: TextStyle(color: colors.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: _activeModel != null ? '输入股票名称或问题...' : '请先配置AI模型',
                  hintStyle: TextStyle(color: colors.textHint, fontSize: 14),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(18, 13, 8, 13),
                  isDense: true,
                  suffixIcon: hasText ? IconButton(
                    icon: Icon(Icons.close, size: 16, color: colors.textHint),
                    onPressed: () { _controller.clear(); setState(() {}); },
                  ) : null,
                ),
                textInputAction: TextInputAction.newline,
                maxLines: 4, minLines: 1,
                enabled: _activeModel != null && !_isLoading,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 发送按钮
          GestureDetector(
            onTap: (_isLoading || _activeModel == null) ? null : _sendMessage,
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: (_isLoading || _activeModel == null)
                  ? LinearGradient(colors: [colors.textDisabled, colors.textDisabled])
                  : LinearGradient(colors: [colors.primary, colors.accent]),
                boxShadow: (_isLoading || _activeModel == null) ? null : [
                  BoxShadow(color: colors.primary.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 4)),
                ],
              ),
              child: _isLoading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                : const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 22),
            ),
          ),
        ]),
      ),
    );
  }

  // ============================================================
  // 历史记录
  // ============================================================

  void _showHistory() async {
    final colors = AppColors.of(context);
    final history = await ChatHistoryService.getHistory();

    if (!mounted) return;
    if (history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无历史记录'), behavior: SnackBarBehavior.floating));
      return;
    }

    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65, minChildSize: 0.4, maxChildSize: 0.9, expand: false,
        builder: (ctx, sc) => Column(children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Row(children: [
              Icon(Icons.history, color: colors.primary, size: 20),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('历史对话', style: TextStyle(color: colors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700)),
                Text('点击条目继续对话', style: TextStyle(color: colors.textHint, fontSize: 12)),
              ]),
              const Spacer(),
              Text('${history.length}条', style: TextStyle(color: colors.textHint, fontSize: 12)),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              controller: sc, padding: const EdgeInsets.all(16),
              itemCount: history.length,
              itemBuilder: (ctx, i) {
                final item = history[history.length - 1 - i];
                final time = DateTime.tryParse(item['time'] ?? '') ?? DateTime.now();
                return _buildHistoryItem(
                  question: item['question'] ?? '', answer: item['answer'] ?? '',
                  time: time, colors: colors,
                  onTap: () {
                    Navigator.pop(ctx);
                    _loadHistoryItem(item['question'] ?? '', item['answer'] ?? '');
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  void _loadHistoryItem(String question, String answer) {
    final userMsg = ChatMessage(
      id: const Uuid().v4().toString().substring(0, 8),
      content: question, isUser: true, time: DateTime.now(),
    );
    final aiMsg = ChatMessage(
      id: const Uuid().v4().toString().substring(0, 8),
      content: answer, isUser: false, time: DateTime.now(),
      suggestedQuestions: _generateFollowUps(question, answer),
      dataSources: _extractDataSources(answer),
    );
    setState(() => _messages.addAll([userMsg, aiMsg]));
    _scrollToBottom();
  }

  Widget _buildHistoryItem({
    required String question, required String answer,
    required DateTime time, required AppColorScheme colors,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? colors.surface.withOpacity(0.5) : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border.withOpacity(0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(4)),
              child: Text(
                '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                style: TextStyle(color: colors.primary, fontSize: 10, fontWeight: FontWeight.w600)),
            ),
            const Spacer(),
            Icon(Icons.chat_bubble_outline, size: 14, color: colors.primary.withOpacity(0.6)),
            const SizedBox(width: 3),
            Text('继续对话', style: TextStyle(color: colors.primary, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 8),
          Text(question, style: TextStyle(color: colors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(answer, style: TextStyle(color: colors.textSecondary, fontSize: 12, height: 1.4), maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }

  // ============================================================
  // 清空
  // ============================================================

  void _clearChat() {
    if (_messages.isEmpty) return;
    final colors = AppColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('清空对话', style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w700)),
        content: Text('确定清空当前对话吗？历史记录将被保留。', style: TextStyle(color: colors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: colors.textSecondary))),
          ElevatedButton(
            onPressed: () { Navigator.pop(ctx); setState(() => _messages.clear()); },
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.error,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('清空', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 分享报告
  // ============================================================

  void _shareReport(String content) {
    final report = ReportGeneratorService().generateStockReport(
      stockName: '分析结果', stockCode: '', aiAnalysis: content);
    final colors = AppColors.of(context);
    showModalBottomSheet(
      context: context, backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(padding: const EdgeInsets.all(20), child: Column(
          mainAxisSize: MainAxisSize.min, children: [
          Container(width: 36, height: 4,
            decoration: BoxDecoration(color: colors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          Text('分析报告', style: TextStyle(color: colors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          Container(
            constraints: const BoxConstraints(maxHeight: 300), padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: colors.surfaceVariant, borderRadius: BorderRadius.circular(8)),
            child: SingleChildScrollView(
              child: SelectableText(report, style: TextStyle(color: colors.textPrimary, fontSize: 12, height: 1.5))),
          ),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx),
            icon: const Icon(Icons.copy, size: 16),
            label: Text('复制报告', style: const TextStyle(color: Colors.white, fontSize: 14)),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.primary, padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          )),
        ])),
      ),
    );
  }

  // ============================================================
  // 追问生成 & 数据来源提取（保持原有逻辑）
  // ============================================================

  List<String> _generateFollowUps(String question, String response) {
    final sugs = <String>[];
    final combined = '$question $response';

    if (combined.contains('茅台') || combined.contains('宁德') || combined.contains('比亚迪') || combined.contains('招商')) {
      sugs.add('技术面信号怎么看？支撑位和压力位在哪？');
      sugs.add('当前适合什么操作策略？');
      sugs.add('同行业有没有更好的标的？');
    } else if (combined.contains('大盘') || combined.contains('走势') || combined.contains('指数')) {
      sugs.add('哪些板块今日表现最强？');
      sugs.add('短期仓位建议是什么？');
      sugs.add('北向资金流向如何？');
    } else if (combined.contains('板块') || combined.contains('行业') || combined.contains('科技') || combined.contains('医药') || combined.contains('能源')) {
      sugs.add('板块内龙头股有哪些？');
      sugs.add('该板块后续走势预判？');
      sugs.add('资金流入持续性能判断吗？');
    } else if (combined.contains('策略') || combined.contains('仓位') || combined.contains('配置')) {
      sugs.add('具体持仓比例建议？');
      sugs.add('风险控制要点是什么？');
      sugs.add('中期调仓时机判断？');
    } else {
      sugs.add('技术面怎么看？');
      sugs.add('当前适合什么操作？');
      sugs.add('相关风险提示是什么？');
    }
    return sugs.take(3).toList();
  }

  List<String> _extractDataSources(String response) {
    final sources = <String>[];
    final r = response;

    if (r.contains('MACD') || r.contains('RSI') || r.contains('KDJ') || r.contains('均线') || r.contains('布林')) {
      sources.add('技术分析');
    }
    if (r.contains('PE') || r.contains('PB') || r.contains('ROE') || r.contains('盈利') || r.contains('营收')) {
      sources.add('基本面');
    }
    if (r.contains('北向') || r.contains('资金') || r.contains('主力') || r.contains('流入') || r.contains('流出')) {
      sources.add('资金流向');
    }
    if (r.contains('财报') || r.contains('年报') || r.contains('季报') || r.contains('净利润')) {
      sources.add('财报数据');
    }
    if (r.contains('市盈') || r.contains('估值') || r.contains('低估') || r.contains('高估')) {
      sources.add('估值分析');
    }
    if (r.contains('支撑位') || r.contains('压力位') || r.contains('趋势') || r.contains('突破')) {
      sources.add('技术信号');
    }
    if (sources.isEmpty) sources.add('AI分析');
    return sources.take(3).toList();
  }
}

// ============================================================
// 辅助组件
// ============================================================

/// 发光图标
class _GlowIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  const _GlowIcon({required this.icon, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 12, height: size + 12,
      child: Stack(alignment: Alignment.center, children: [
        Container(
          width: size + 8, height: size + 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color.withOpacity(0.2), Colors.transparent]),
          ),
        ),
        Icon(icon, size: size, color: color),
      ]),
    );
  }
}

/// 脉冲光环
class _PulsingRing extends StatefulWidget {
  final int delay;
  final double size;
  final Color color;
  const _PulsingRing({required this.delay, required this.size, required this.color});

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 2000), vsync: this);
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Container(
        width: widget.size, height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: widget.color.withOpacity(0.3 + 0.7 * _ctrl.value),
            width: 1.5,
          ),
        ),
      ),
    );
  }
}

/// 思考中指示器（三个轨道点）
class _ThinkingIndicator extends StatefulWidget {
  const _ThinkingIndicator();
  @override
  State<_ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<_ThinkingIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 1200), vsync: this)..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16, height: 4,
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        _dot(0.0),
        _dot(0.33),
        _dot(0.66),
      ]),
    );
  }

  Widget _dot(double offset) {
    final v = ((_ctrl.value + offset) % 1.0);
    final opacity = 0.3 + 0.7 * (1.0 - (v - 0.5).abs() * 2.0);
    return Container(
      width: 3, height: 3,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFA78BFA).withOpacity(opacity),
      ),
    );
  }
}
