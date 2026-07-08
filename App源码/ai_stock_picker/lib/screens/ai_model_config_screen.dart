/// AI模型配置页面 - 管理AI模型API配置
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_spacing.dart';
import '../models/ai_model_config.dart';
import '../models/ai_model_preset.dart';
import '../services/ai_model_service.dart';

class AIModelConfigScreen extends StatefulWidget {
  const AIModelConfigScreen({Key? key}) : super(key: key);

  @override
  State<AIModelConfigScreen> createState() => _AIModelConfigScreenState();
}

class _AIModelConfigScreenState extends State<AIModelConfigScreen> {
  List<AIModelConfig> _models = [];
  String? _activeModelId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final models = await AIModelService.getModels();
    final activeId = await AIModelService.getActiveModelId();
    if (mounted) {
      setState(() {
        _models = models;
        _activeModelId = activeId;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
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
        appBar: _buildAppBar(),
        body: _loading ? _buildLoading() : _buildBody(),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _showAddModelDialog(),
          icon: const Icon(Icons.add, color: Colors.white),
          label: Text('添加模型', style: AppText.body2.copyWith(color: Colors.white)),
          backgroundColor: colors.primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final colors = AppColors.of(context);
    return AppBar(
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new, size: 22, color: colors.textPrimary),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text('AI 模型配置', style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
      centerTitle: true,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors.backgroundGradient),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    final colors = AppColors.of(context);
    return Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(colors.primary)));
  }

  Widget _buildBody() {
    if (_models.isEmpty) {
      return _buildEmptyState();
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: _models.length,
      itemBuilder: (ctx, index) {
        final model = _models[index];
        final isActive = model.id == _activeModelId;
        return _buildModelCard(model, isActive);
      },
    );
  }

  Widget _buildEmptyState() {
    final colors = AppColors.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 64, color: colors.textHint),
          const SizedBox(height: AppSpacing.xl),
          Text('暂无AI模型配置', style: AppText.h3.copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          Text('点击下方按钮快速添加AI模型', style: AppText.caption.copyWith(color: colors.textHint)),
          const SizedBox(height: AppSpacing.xl),
          ElevatedButton.icon(
            onPressed: () => _showAddModelDialog(),
            icon: const Icon(Icons.add, size: 18),
            label: Text('添加模型', style: AppText.body2.copyWith(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.primary,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelCard(AIModelConfig model, bool isActive) {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isActive ? colors.primary : colors.border,
          width: isActive ? 2 : 1,
        ),
        boxShadow: isActive
            ? [BoxShadow(color: colors.shadowPurple, blurRadius: 12, offset: const Offset(0, 4))]
            : null,
      ),
      child: Column(
        children: [
          // 顶部激活状态
          if (isActive)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: AppColors.primaryGradient),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, size: 14, color: Colors.white),
                    const SizedBox(width: 6),
                    Text('当前激活', style: AppText.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          // 内容区域
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(model.name, style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
                          Text(model.provider, style: AppText.caption.copyWith(color: colors.textHint)),
                        ],
                      ),
                    ),
                    Switch(
                      value: model.isEnabled,
                      onChanged: (val) => _toggleModel(model),
                      activeColor: colors.primary,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow('模型', model.model),
                      const SizedBox(height: 6),
                      _buildInfoRow('Base URL', model.baseUrl),
                      const SizedBox(height: 6),
                      _buildInfoRow('API Key', _maskApiKey(model.apiKey)),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    if (!isActive)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _activateModel(model),
                          icon: Icon(Icons.power_settings_new, size: 16, color: colors.primary),
                          label: Text('激活', style: AppText.body2.copyWith(color: colors.primary, fontWeight: FontWeight.w600)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: colors.border),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    if (!isActive) const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _editModel(model),
                        icon: Icon(Icons.edit, size: 16, color: colors.textSecondary),
                        label: Text('编辑', style: AppText.body2.copyWith(color: colors.textSecondary, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: colors.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _deleteModel(model),
                        icon: Icon(Icons.delete_outline, size: 16, color: colors.error),
                        label: Text('删除', style: AppText.body2.copyWith(color: colors.error, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Theme.of(context).brightness == Brightness.light ? colors.border : colors.error),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    final colors = AppColors.of(context);
    return Row(
      children: [
        Text('$label: ', style: AppText.caption.copyWith(color: colors.textHint)),
        Expanded(
          child: Text(value, style: AppText.caption.copyWith(color: colors.textSecondary, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  String _maskApiKey(String apiKey) {
    if (apiKey.length <= 8) return apiKey;
    return '${apiKey.substring(0, 4)}...${apiKey.substring(apiKey.length - 4)}';
  }

  void _toggleModel(AIModelConfig model) async {
    final updatedModel = model.copyWith(isEnabled: !model.isEnabled);
    await AIModelService.updateModel(updatedModel);
    _loadData();
  }

  void _activateModel(AIModelConfig model) async {
    if (!model.isEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先启用该模型')),
      );
      return;
    }
    await AIModelService.setActiveModelId(model.id);
    _loadData();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已激活 ${model.name}')),
    );
  }

  void _deleteModel(AIModelConfig model) {
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text('删除模型', style: AppText.h3.copyWith(color: colors.textPrimary)),
          content: Text('确定要删除"${model.name}"吗？', style: AppText.body2.copyWith(color: colors.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await AIModelService.deleteModel(model.id);
                _loadData();
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.error),
              child: Text('删除', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showAddModelDialog() {
    // 先显示预设模板选择
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.of(context).surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              // 顶部拖动指示条
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textHint.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 顶部标题栏
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_awesome, color: colors.primary, size: 24),
                        const SizedBox(width: 10),
                        Text('快速添加AI模型', style: AppText.h3.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('选择预设模板，只需填入API Key即可使用', style: AppText.caption.copyWith(color: colors.textHint)),
                  ],
                ),
              ),
              // 预设模型列表（可滚动）
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
                  child: Column(
                    children: [
                      ...AIModelPreset.presets.map((preset) => _buildPresetItem(preset)),
                      const SizedBox(height: AppSpacing.md),
                      // 自定义添加按钮
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showModelDialog(null);
                          },
                          icon: Icon(Icons.edit_note, color: colors.textSecondary, size: 20),
                          label: Text('自定义模型配置', style: AppText.body2.copyWith(color: colors.textSecondary)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: colors.border),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 构建预设模板选项
  Widget _buildPresetItem(AIModelPreset preset) {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.pop(context);
            _showModelDialogWithPreset(preset);
          },
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              children: [
                // 图标
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(preset.icon, style: const TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 14),
                // 模型信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(preset.name, style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('${preset.provider} · ${preset.model}', style: AppText.caption.copyWith(color: colors.textHint), overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                // 箭头
                Icon(Icons.arrow_forward_ios, size: 14, color: colors.textHint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 使用预设模板打开配置对话框（只需填 API Key）
  void _showModelDialogWithPreset(AIModelPreset preset) {
    final apiKeyController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Row(
            children: [
              Text(preset.icon, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('添加 ${preset.name}', style: AppText.h3.copyWith(color: colors.textPrimary)),
                    Text('${preset.provider}', style: AppText.caption.copyWith(color: colors.textHint)),
                  ],
                ),
              ),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 预设信息展示
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.border),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow('模型', preset.model),
                      const SizedBox(height: 4),
                      _buildInfoRow('Base URL', preset.baseUrl),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // API Key 输入框（唯一需要填写的内容）
                Text('API Key', style: AppText.caption.copyWith(color: colors.textHint)),
                const SizedBox(height: 6),
                TextField(
                  controller: apiKeyController,
                  obscureText: true,
                  style: AppText.body1.copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    hintText: '请输入您的 ${preset.provider} API Key',
                    hintStyle: AppText.body2.copyWith(color: colors.textHint),
                    filled: true,
                    fillColor: colors.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    isDense: true,
                    prefixIcon: Icon(Icons.key, size: 18, color: colors.primary),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '💡 API Key 将安全保存在本地设备中',
                  style: AppText.caption.copyWith(color: colors.textHint, fontSize: 11),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                final apiKey = apiKeyController.text.trim();
                if (apiKey.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入API Key')),
                  );
                  return;
                }

                final config = AIModelConfig(
                  id: const Uuid().v4().toString().substring(0, 8),
                  name: preset.name,
                  provider: preset.provider,
                  apiKey: apiKey,
                  baseUrl: preset.baseUrl,
                  model: preset.model,
                  isEnabled: true,
                  createdAt: DateTime.now(),
                );

                await AIModelService.addModel(config);
                // 如果是第一个模型，自动激活
                final models = await AIModelService.getModels();
                if (models.length == 1) {
                  await AIModelService.setActiveModelId(config.id);
                }

                Navigator.pop(ctx);
                _loadData();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${preset.name} 添加成功！')),
                );
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
              child: Text('添加', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _editModel(AIModelConfig model) {
    _showModelDialog(model);
  }

  void _showModelDialog(AIModelConfig? existingModel) {
    final nameController = TextEditingController(text: existingModel?.name ?? '');
    final providerController = TextEditingController(text: existingModel?.provider ?? '');
    final apiKeyController = TextEditingController(text: existingModel?.apiKey ?? '');
    final baseUrlController = TextEditingController(text: existingModel?.baseUrl ?? 'https://api.openai.com/v1');
    final modelController = TextEditingController(text: existingModel?.model ?? 'gpt-3.5-turbo');

    showDialog(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text(existingModel == null ? '自定义AI模型' : '编辑AI模型', style: AppText.h3.copyWith(color: colors.textPrimary)),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTextField('模型名称', nameController, '如：GLM-4'),
                const SizedBox(height: 12),
                _buildTextField('提供商', providerController, '如：智谱AI'),
                const SizedBox(height: 12),
                _buildTextField('API Key', apiKeyController, '请输入API Key', obscure: true),
                const SizedBox(height: 12),
                _buildTextField('Base URL', baseUrlController, 'https://open.bigmodel.cn/api/paas/v4'),
                const SizedBox(height: 12),
                _buildTextField('模型名称', modelController, 'glm-4-flash'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final provider = providerController.text.trim();
                final apiKey = apiKeyController.text.trim();
                final baseUrl = baseUrlController.text.trim();
                final model = modelController.text.trim();

                if (name.isEmpty || apiKey.isEmpty || baseUrl.isEmpty || model.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请填写所有必填项')),
                  );
                  return;
                }

                final config = AIModelConfig(
                  id: existingModel?.id ?? const Uuid().v4().toString().substring(0, 8),
                  name: name,
                  provider: provider,
                  apiKey: apiKey,
                  baseUrl: baseUrl,
                  model: model,
                  isEnabled: existingModel?.isEnabled ?? true,
                  createdAt: existingModel?.createdAt ?? DateTime.now(),
                );

                if (existingModel == null) {
                  await AIModelService.addModel(config);
                } else {
                  await AIModelService.updateModel(config);
                }

                Navigator.pop(ctx);
                _loadData();
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
              child: Text('保存', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, String hint, {bool obscure = false}) {
    final colors = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.caption.copyWith(color: colors.textHint)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: AppText.body1.copyWith(color: colors.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: AppText.body2.copyWith(color: colors.textHint),
            filled: true,
            fillColor: colors.surfaceVariant,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
        ),
      ],
    );
  }
}
