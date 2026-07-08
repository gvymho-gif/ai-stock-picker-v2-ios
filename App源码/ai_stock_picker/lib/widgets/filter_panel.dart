/// 筛选面板 - 年轻化设计
///
/// 深蓝紫渐变 + 玻璃态效果

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/filter_criteria.dart';
import '../services/foreign_holder_service.dart';

class FilterPanel extends StatefulWidget {
  final Function(FilterCriteria) onApply;
  final String initialMarket;

  const FilterPanel({Key? key, required this.onApply, this.initialMarket = 'A'}) : super(key: key);
  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  late String _market;
  RangeValues _peRange = const RangeValues(0, 100);
  RangeValues _pbRange = const RangeValues(0, 20);
  RangeValues _roeRange = const RangeValues(0, 50);
  RangeValues _revenueGrowthRange = const RangeValues(-50, 200);
  RangeValues _dividendYieldRange = const RangeValues(0, 10);
  String? _marketCapLevel;
  int? _minListingYears;
  RangeValues _turnoverRange = const RangeValues(0, 30);
  RangeValues _pctFrom52WeekHigh = const RangeValues(0, 100);
  RangeValues _changePctRange = const RangeValues(-10, 20);
  RangeValues _volumeRange = const RangeValues(0, 10000);

  bool _enablePe = false; bool _enablePb = false; bool _enableRoe = false;
  bool _enableRevenueGrowth = false; bool _enableDividendYield = false;
  bool _enableMarketCap = false; bool _enableTurnover = false;
  bool _enablePctFrom52WeekHigh = false; bool _enableChangePct = false;
  bool _enableVolume = false; bool _enableForeignHolder = false;

  ForeignHolderType? _foreignHolderType;
  RangeValues _foreignRatioRange = const RangeValues(0, 50);
  RangeValues _foreignChangeRange = const RangeValues(-50, 50);

  @override
  void initState() { super.initState(); _market = widget.initialMarket; }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      child: Column(children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          width: 40, height: 4,
          decoration: BoxDecoration(color: colors.border, borderRadius: BorderRadius.circular(2)),
        ),
        _buildHeader(),
        _buildMarketTabs(),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: AppSpacing.lg),
            _buildQuickTemplates(),
            const SizedBox(height: AppSpacing.xl),
            _buildValuationSection(),
            const SizedBox(height: AppSpacing.lg),
            if (_market == 'A') ...[_buildProfitSection(), const SizedBox(height: AppSpacing.lg)],
            _buildScaleSection(),
            const SizedBox(height: AppSpacing.lg),
            _buildTechnicalSection(),
            const SizedBox(height: AppSpacing.lg),
            if (_market == 'A') ...[_buildForeignHolderSection(), const SizedBox(height: AppSpacing.lg)],
            const SizedBox(height: 60),
          ]),
        )),
        _buildBottomButtons(),
      ]),
    );
  }

  Widget _buildHeader() {
    final colors = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(children: [
        Text('股票筛选', style: AppText.h2.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w800)),
        const Spacer(),
        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ]),
    );
  }

  Widget _buildMarketTabs() {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      decoration: BoxDecoration(color: colors.surfaceVariant, borderRadius: BorderRadius.circular(AppRadius.full)),
      child: Row(children: ['A股', '港股', '美股'].map((m) {
        final marketCode = m == 'A股' ? 'A' : (m == '港股' ? 'HK' : 'US');
        final isSelected = _market == marketCode;
        return Expanded(
          child: GestureDetector(
            onTap: () { if (_market != marketCode) setState(() { _market = marketCode; _resetFilters(); }); },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              decoration: BoxDecoration(
                gradient: isSelected ? const LinearGradient(colors: AppColors.primaryGradient) : null,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              alignment: Alignment.center,
              child: Text(m, style: AppText.body2.copyWith(
                color: isSelected ? Colors.white : colors.textSecondary, fontWeight: FontWeight.w600)),
            ),
          ),
        );
      }).toList()),
    );
  }

  Widget _buildQuickTemplates() {
    final colors = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('快捷模板', style: AppText.body2.copyWith(color: colors.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: AppSpacing.md),
      Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm,
        children: FilterTemplates.all.map((t) => GestureDetector(
          onTap: () => _applyTemplate(t),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: colors.surface, borderRadius: BorderRadius.circular(AppRadius.full),
              border: Border.all(color: colors.border),
            ),
            child: Text(t.name, style: AppText.caption.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600)),
          ),
        )).toList(),
      ),
    ]);
  }

  Widget _buildValuationSection() {
    return _buildSection('估值筛选', [
      _buildRangeFilter('PE市盈率', _peRange, 0, 100, _enablePe, (v) => setState(() => _enablePe = v), (v) => setState(() => _peRange = v), 20, '倍'),
      const SizedBox(height: AppSpacing.md),
      _buildRangeFilter('PB市净率', _pbRange, 0, 20, _enablePb, (v) => setState(() => _enablePb = v), (v) => setState(() => _pbRange = v), 20, '倍'),
    ]);
  }

  Widget _buildProfitSection() {
    return _buildSection('盈利筛选', [
      _buildRangeFilter('ROE', _roeRange, 0, 50, _enableRoe, (v) => setState(() => _enableRoe = v), (v) => setState(() => _roeRange = v), 10, '%'),
      const SizedBox(height: AppSpacing.md),
      _buildRangeFilter('营收增速', _revenueGrowthRange, -50, 200, _enableRevenueGrowth, (v) => setState(() => _enableRevenueGrowth = v), (v) => setState(() => _revenueGrowthRange = v), 25, '%'),
      const SizedBox(height: AppSpacing.md),
      _buildRangeFilter('股息率', _dividendYieldRange, 0, 10, _enableDividendYield, (v) => setState(() => _enableDividendYield = v), (v) => setState(() => _dividendYieldRange = v), 10, '%'),
    ]);
  }

  Widget _buildScaleSection() {
    final colors = AppColors.of(context);
    return _buildSection('规模筛选', [
      Row(children: [
        Text('市值', style: AppText.body2.copyWith(color: colors.textPrimary)),
        const SizedBox(width: AppSpacing.lg),
        Expanded(child: Row(children: [
          _buildChip('小盘', 'small'), const SizedBox(width: AppSpacing.sm),
          _buildChip('中盘', 'mid'), const SizedBox(width: AppSpacing.sm),
          _buildChip('大盘', 'large'), const SizedBox(width: AppSpacing.sm),
          _buildChip('不限', null),
        ])),
      ]),
      const SizedBox(height: AppSpacing.md),
      Row(children: [
        Text('上市', style: AppText.body2.copyWith(color: colors.textPrimary)),
        const SizedBox(width: AppSpacing.lg),
        _buildYearChip('>1年', 1), const SizedBox(width: AppSpacing.sm),
        _buildYearChip('>3年', 3), const SizedBox(width: AppSpacing.sm),
        _buildYearChip('不限', null),
      ]),
    ]);
  }

  Widget _buildChip(String label, String? level) {
    final colors = AppColors.of(context);
    final isSelected = _marketCapLevel == level;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _marketCapLevel = level),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            gradient: isSelected ? const LinearGradient(colors: AppColors.primaryGradient) : null,
            color: isSelected ? null : colors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          alignment: Alignment.center,
          child: Text(label, style: AppText.hint.copyWith(color: isSelected ? Colors.white : colors.textSecondary)),
        ),
      ),
    );
  }

  Widget _buildYearChip(String label, int? years) {
    final colors = AppColors.of(context);
    final isSelected = _minListingYears == years;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _minListingYears = years),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            gradient: isSelected ? const LinearGradient(colors: AppColors.primaryGradient) : null,
            color: isSelected ? null : colors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          alignment: Alignment.center,
          child: Text(label, style: AppText.hint.copyWith(color: isSelected ? Colors.white : colors.textSecondary)),
        ),
      ),
    );
  }

  Widget _buildTechnicalSection() {
    return _buildSection('技术面', [
      _buildRangeFilter('换手率', _turnoverRange, 0, 30, _enableTurnover, (v) => setState(() => _enableTurnover = v), (v) => setState(() => _turnoverRange = v), 30, '%'),
      const SizedBox(height: AppSpacing.md),
      _buildRangeFilter('距52周高', _pctFrom52WeekHigh, 0, 100, _enablePctFrom52WeekHigh, (v) => setState(() => _enablePctFrom52WeekHigh = v), (v) => setState(() => _pctFrom52WeekHigh = v), 10, '%'),
      const SizedBox(height: AppSpacing.md),
      _buildRangeFilter('涨跌幅', _changePctRange, -10, 20, _enableChangePct, (v) => setState(() => _enableChangePct = v), (v) => setState(() => _changePctRange = v), 30, '%'),
      const SizedBox(height: AppSpacing.md),
      _buildRangeFilter('成交量', _volumeRange, 0, 10000, _enableVolume, (v) => setState(() => _enableVolume = v), (v) => setState(() => _volumeRange = v), 20, '万手'),
    ]);
  }

  Widget _buildForeignHolderSection() {
    final colors = AppColors.of(context);
    return _buildSection('外资持股', [
      Row(children: [
        SizedBox(width: 24, height: 24, child: Checkbox(value: _enableForeignHolder,
          onChanged: (v) => setState(() => _enableForeignHolder = v ?? false),
          activeColor: colors.primary, checkColor: Colors.white)),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text('外资持有', style: AppText.body2.copyWith(color: colors.textPrimary))),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          decoration: BoxDecoration(color: colors.primary.withOpacity(0.15), borderRadius: BorderRadius.circular(AppRadius.sm)),
          child: Text('实时', style: AppText.hint.copyWith(color: colors.primary, fontWeight: FontWeight.w600)),
        ),
      ]),
      if (_enableForeignHolder) ...[
        const SizedBox(height: AppSpacing.md),
        _buildRangeFilter('持股比例', _foreignRatioRange, 0, 50, true, null, (v) => setState(() => _foreignRatioRange = v), 25, '%'),
        const SizedBox(height: AppSpacing.md),
        _buildRangeFilter('持股变动', _foreignChangeRange, -50, 50, true, null, (v) => setState(() => _foreignChangeRange = v), 50, '%'),
      ],
    ]);
  }

  Widget _buildSection(String title, List<Widget> children) {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface, borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.border.withOpacity(0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: AppText.body1.copyWith(color: colors.textPrimary, fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.lg),
        ...children,
      ]),
    );
  }

  Widget _buildRangeFilter(String title, RangeValues range, double min, double max, bool enabled,
    ValueChanged<bool>? onEnabledChanged, ValueChanged<RangeValues> onChanged, int divisions, String unit) {
    final colors = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (onEnabledChanged != null) ...[
          SizedBox(width: 24, height: 24, child: Checkbox(
            value: enabled, onChanged: (v) => onEnabledChanged(v ?? false),
            activeColor: colors.primary, checkColor: Colors.white)),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(child: Text(title, style: AppText.body2.copyWith(
          color: enabled ? colors.textPrimary : colors.textSecondary))),
        Text('${range.start.toInt()} - ${range.end.toInt()}$unit',
          style: AppText.caption.copyWith(color: enabled ? colors.primary : colors.textSecondary, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: AppSpacing.sm),
      RangeSlider(
        values: range, min: min, max: max, divisions: divisions,
        activeColor: enabled ? colors.primary : colors.border,
        inactiveColor: colors.surfaceVariant,
        onChanged: enabled ? onChanged : null,
      ),
    ]);
  }

  Widget _buildBottomButtons() {
    final colors = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
      decoration: BoxDecoration(color: colors.background, border: Border(top: BorderSide(color: colors.border))),
      child: Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _resetFilters,
            style: OutlinedButton.styleFrom(
              primary: colors.textSecondary, side: BorderSide(color: colors.border),
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.full)),
            ),
            child: const Text('重置'),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          flex: 2,
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: AppColors.primaryGradient),
              borderRadius: BorderRadius.circular(AppRadius.full),
              boxShadow: AppShadow.button,
            ),
            child: ElevatedButton(
              onPressed: _applyFilters,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent, elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.full)),
              ),
              child: Text('开始筛选', style: AppText.button.copyWith(color: Colors.white)),
            ),
          ),
        ),
      ]),
    );
  }

  void _applyTemplate(FilterTemplate template) {
    final criteria = template.getCriteria();
    setState(() {
      _market = criteria.market;
      if (criteria.peRange != null) { _enablePe = true; _peRange = criteria.peRange!; }
      if (criteria.pbRange != null) { _enablePb = true; _pbRange = criteria.pbRange!; }
      if (criteria.roeRange != null) { _enableRoe = true; _roeRange = criteria.roeRange!; }
    });
  }

  void _resetFilters() {
    setState(() {
      _enablePe = false; _enablePb = false; _enableRoe = false;
      _enableRevenueGrowth = false; _enableDividendYield = false;
      _enableTurnover = false; _enablePctFrom52WeekHigh = false;
      _enableChangePct = false; _enableVolume = false; _enableForeignHolder = false;
      _marketCapLevel = null; _minListingYears = null;
    });
  }

  void _applyFilters() {
    final criteria = FilterCriteria(
      market: _market,
      peRange: _enablePe ? _peRange : null,
      pbRange: _enablePb ? _pbRange : null,
      roeRange: _enableRoe ? _roeRange : null,
      revenueGrowthRange: _enableRevenueGrowth ? _revenueGrowthRange : null,
      dividendYieldRange: _enableDividendYield ? _dividendYieldRange : null,
      marketCapLevel: _marketCapLevel,
      minListingYears: _minListingYears,
      turnoverRange: _enableTurnover ? _turnoverRange : null,
      pctFrom52WeekHigh: _enablePctFrom52WeekHigh ? _pctFrom52WeekHigh : null,
      changePctRange: _enableChangePct ? _changePctRange : null,
      volumeRange: _enableVolume ? _volumeRange : null,
    );
    Navigator.of(context).pop();
    Future.microtask(() => widget.onApply(criteria));
  }
}
