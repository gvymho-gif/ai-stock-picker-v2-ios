/// 收藏页面 - 股票收藏分类管理
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_spacing.dart';
import '../models/favorite_category.dart';
import '../models/favorite_stock.dart';
import '../services/favorite_service.dart';
import '../services/local_data_service.dart';

class FavoriteScreen extends StatefulWidget {
  const FavoriteScreen({Key? key}) : super(key: key);

  @override
  State<FavoriteScreen> createState() => _FavoriteScreenState();
}

class _FavoriteScreenState extends State<FavoriteScreen> {
  final LocalDataService _api = LocalDataService();

  List<FavoriteCategory> _categories = [];
  List<FavoriteStock> _stocks = [];
  String? _selectedCategoryId;
  bool _loading = true;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    
    // 加载分类
    final categories = await FavoriteService.getCategories();
    if (!mounted) return;
    
    // 确定选中的分类
    String? categoryId;
    if (categories.isNotEmpty) {
      // 如果之前有选中的分类且该分类仍存在，保持选择
      if (_selectedCategoryId != null && categories.any((c) => c.id == _selectedCategoryId)) {
        categoryId = _selectedCategoryId;
      } else {
        // 否则选择第一个分类
        categoryId = categories.first.id;
      }
    }
    
    // 加载该分类下的股票
    List<FavoriteStock> stocks = [];
    if (categoryId != null) {
      stocks = await FavoriteService.getStocksByCategory(categoryId);
      // 刷新股票价格
      await _refreshStockPrices(stocks);
      // 重新获取更新后的股票列表
      stocks = await FavoriteService.getStocksByCategory(categoryId);
    }
    
    if (!mounted) return;
    
    setState(() {
      _categories = categories;
      _selectedCategoryId = categoryId;
      _stocks = stocks;
      _loading = false;
      _initialized = true;
    });
  }

  /// 刷新股票价格
  Future<void> _refreshStockPrices(List<FavoriteStock> stocks) async {
    for (final stock in stocks) {
      try {
        final data = await _api.searchStock(stock.symbol);
        final cp = _safeDouble(data['change_pct']);
        final price = _safeDouble(data['price']);
        await FavoriteService.updateStock(stock.copyWith(price: price, changePct: cp));
      } catch (_) {}
    }
  }

  double _safeDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
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
        appBar: _buildAppBar(colors),
        body: _loading && !_initialized ? _buildLoading(colors) : _buildBody(colors),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(AppColorScheme colors) {
    return AppBar(
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new, size: 22, color: colors.textPrimary),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text('我的收藏', style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
      centerTitle: true,
      actions: [
        IconButton(
          icon: Icon(Icons.refresh, color: colors.textSecondary),
          onPressed: _loadData,
        ),
        IconButton(
          icon: Icon(Icons.add_circle_outline, color: colors.primary),
          onPressed: _showAddCategoryDialog,
        ),
      ],
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: colors.backgroundGradient),
        ),
      ),
    );
  }

  Widget _buildLoading(AppColorScheme colors) {
    return Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation(colors.primary)));
  }

  Widget _buildBody(AppColorScheme colors) {
    if (_categories.isEmpty) {
      return _buildEmptyCategories(colors);
    }
    return Column(
      children: [
        _buildCategoryTabs(colors),
        const SizedBox(height: AppSpacing.md),
        Expanded(child: _selectedCategoryId == null ? _buildSelectCategory(colors) : (_stocks.isEmpty ? _buildEmpty(colors) : _buildStockList(colors))),
      ],
    );
  }

  Widget _buildCategoryTabs(AppColorScheme colors) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        itemBuilder: (ctx, index) {
          final category = _categories[index];
          final isSelected = category.id == _selectedCategoryId;
          return GestureDetector(
            onTap: () => _selectCategory(category.id),
            onLongPress: () => _showCategoryMenu(category),
            child: Container(
              margin: EdgeInsets.only(right: index < _categories.length - 1 ? AppSpacing.sm : 0),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isSelected ? colors.primaryGradient : [Colors.transparent, Colors.transparent],
                ),
                color: !isSelected ? colors.surface : null,
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(
                  color: isSelected ? colors.primary : colors.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(category.name,
                    style: AppText.body2.copyWith(
                      color: isSelected ? Colors.white : colors.textSecondary,
                      fontWeight: FontWeight.w600,
                    )),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.close, size: 16, color: isSelected ? Colors.white70 : colors.textHint),
                    onPressed: () => _showCategoryMenu(category),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _selectCategory(String categoryId) async {
    if (_selectedCategoryId == categoryId) return;
    
    setState(() {
      _selectedCategoryId = categoryId;
      _loading = true;
    });
    
    // 加载该分类下的股票
    final stocks = await FavoriteService.getStocksByCategory(categoryId);
    await _refreshStockPrices(stocks);
    final updatedStocks = await FavoriteService.getStocksByCategory(categoryId);
    
    if (!mounted) return;
    
    setState(() {
      _stocks = updatedStocks;
      _loading = false;
    });
  }

  Widget _buildStockList(AppColorScheme colors) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: _stocks.length,
      itemBuilder: (ctx, index) {
        final stock = _stocks[index];
        return _buildStockCard(stock, colors);
      },
    );
  }

  Widget _buildStockCard(FavoriteStock stock, AppColorScheme colors) {
    final priceColor = colors.getPriceColor(stock.changePct);
    return GestureDetector(
      onTap: () => _goToStockDetail(stock),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(stock.name,
                        style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
                      const SizedBox(width: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
                        decoration: BoxDecoration(
                          color: colors.surfaceVariant,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(stock.market,
                          style: AppText.hint.copyWith(color: colors.primary, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(stock.symbol, style: AppText.caption.copyWith(color: colors.textHint)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(stock.price.toStringAsFixed(2),
                  style: AppText.h2.copyWith(color: priceColor, fontWeight: FontWeight.w800)),
                Text('${stock.changePct >= 0 ? "+" : ""}${stock.changePct.toStringAsFixed(2)}%',
                  style: AppText.caption.copyWith(color: priceColor, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(width: AppSpacing.sm),
            IconButton(
              icon: Icon(Icons.delete_outline, color: colors.textHint),
              onPressed: () => _confirmRemoveStock(stock),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(AppColorScheme colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.star_outline, size: 48, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('暂无收藏股票', style: AppText.h3.copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          Text('去首页搜索股票并添加收藏', style: AppText.caption.copyWith(color: colors.textHint)),
        ],
      ),
    );
  }

  Widget _buildEmptyCategories(AppColorScheme colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.folder_open, size: 48, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('还没有收藏分类', style: AppText.h3.copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          Text('点击右上角 ➕ 创建第一个分类', style: AppText.caption.copyWith(color: colors.textHint)),
        ],
      ),
    );
  }

  Widget _buildSelectCategory(AppColorScheme colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.category, size: 48, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('选择一个分类', style: AppText.h3.copyWith(color: colors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          Text('点击上方的分类标签查看收藏', style: AppText.caption.copyWith(color: colors.textHint)),
        ],
      ),
    );
  }

  void _showCategoryMenu(FavoriteCategory category) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.edit, color: colors.primary),
                  title: Text('重命名分类', style: AppText.body2.copyWith(color: colors.textPrimary)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showRenameCategoryDialog(category);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete, color: colors.error),
                  title: Text('删除分类', style: AppText.body2.copyWith(color: colors.textPrimary)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _confirmDeleteCategory(category);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAddCategoryDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
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
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                final rng = Random();
                final id = List.generate(8, (_) => rng.nextInt(16).toRadixString(16)).join();
                final category = FavoriteCategory(
                  id: id,
                  name: name,
                  createdAt: DateTime.now(),
                );
                final success = await FavoriteService.addCategory(category);
                if (success) {
                  Navigator.pop(ctx);
                  _loadData();
                } else {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('分类名称已存在')),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
              child: Text('确定', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showRenameCategoryDialog(FavoriteCategory category) {
    final controller = TextEditingController(text: category.name);
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text('重命名分类', style: AppText.h3.copyWith(color: colors.textPrimary)),
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
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                final success = await FavoriteService.renameCategory(category.id, name);
                if (success) {
                  Navigator.pop(ctx);
                  _loadData();
                } else {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('重命名失败')),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.primary),
              child: Text('确定', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _confirmDeleteCategory(FavoriteCategory category) {
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text('删除分类', style: AppText.h3.copyWith(color: colors.textPrimary)),
          content: Text('确定要删除"${category.name}"吗？该分类下的股票也将被删除。', style: AppText.body2.copyWith(color: colors.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                final success = await FavoriteService.deleteCategory(category.id);
                if (success) {
                  Navigator.pop(ctx);
                  if (_selectedCategoryId == category.id) {
                    setState(() => _selectedCategoryId = null);
                  }
                  _loadData();
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.error),
              child: Text('删除', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _confirmRemoveStock(FavoriteStock stock) {
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text('移除收藏', style: AppText.h3.copyWith(color: colors.textPrimary)),
          content: Text('确定要移除"${stock.name}(${stock.symbol})"吗？', style: AppText.body2.copyWith(color: colors.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: AppText.body2.copyWith(color: colors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                final success = await FavoriteService.removeStock(stock.symbol);
                if (success) {
                  Navigator.pop(ctx);
                  _loadData();
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: colors.error),
              child: Text('移除', style: AppText.body2.copyWith(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _goToStockDetail(FavoriteStock stock) {
    Navigator.pop(context, stock.symbol);
  }
}
