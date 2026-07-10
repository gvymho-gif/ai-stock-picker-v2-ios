import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// AI回复中的内嵌图表气泡 — 支持K线迷你图和技术指标图
class AIChartBubble extends StatelessWidget {
  final Map<String, dynamic> chartData;
  final AppColorScheme colors;
  final VoidCallback? onTap;

  const AIChartBubble({
    Key? key,
    required this.chartData,
    required this.colors,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final type = chartData['type'] as String? ?? 'kline';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTitle(),
            const SizedBox(height: 6),
            SizedBox(
              height: type == 'indicators' ? 120 : 100,
              child: type == 'indicators' ? _buildIndicatorChart() : _buildKlineChart(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitle() {
    final title = chartData['title'] as String? ?? '走势图';
    return Row(
      children: [
        Icon(Icons.show_chart, size: 14, color: colors.primary),
        const SizedBox(width: 4),
        Text(title, style: AppText.caption.copyWith(color: colors.primary, fontWeight: FontWeight.w700)),
        const Spacer(),
        Icon(Icons.open_in_full, size: 12, color: colors.textHint),
      ],
    );
  }

  Widget _buildKlineChart() {
    final klines = chartData['klines'] as List? ?? [];
    if (klines.isEmpty) return const Center(child: Text('数据加载中...'));

    final closes = <double>[];
    for (final k in klines) {
      if (k is Map) closes.add((k['close'] as num?)?.toDouble() ?? 0);
    }
    if (closes.isEmpty) return const SizedBox();

    final minY = closes.reduce((a, b) => a < b ? a : b) * 0.99;
    final maxY = closes.reduce((a, b) => a > b ? a : b) * 1.01;

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawHorizontalLine: true,
          drawVerticalLine: false,
          horizontalInterval: (maxY - minY) / 3,
          getDrawingHorizontalLine: (value) => FlLine(
            color: colors.border,
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 42,
            getTitlesWidget: (v, meta) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(v.toStringAsFixed(1), style: TextStyle(fontSize: 9, color: colors.textHint)),
            ),
          )),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: List.generate(closes.length, (i) => FlSpot(i.toDouble(), closes[i])),
            isCurved: true,
            curveSmoothness: 0.2,
            gradient: LinearGradient(colors: [ closes.last >= closes.first ? colors.up : colors.down,  closes.last >= closes.first ? colors.up : colors.down]),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(colors: [ (closes.last >= closes.first ? colors.up : colors.down).withOpacity(0.1),  (closes.last >= closes.first ? colors.up : colors.down).withOpacity(0.1)]),
            ),
          ),
        ],
        lineTouchData: LineTouchData(enabled: false),
      ),
    );
  }

  Widget _buildIndicatorChart() {
    final indicators = chartData['indicators'] as Map<String, List<double>>? ?? {};
    if (indicators.isEmpty) return const SizedBox();

    final colors_list = [colors.primary, colors.up, colors.down, Colors.orange, Colors.cyan];
    final barGroups = <LineChartBarData>[];
    var idx = 0;

    indicators.forEach((name, values) {
      if (values.isNotEmpty) {
        barGroups.add(LineChartBarData(
          spots: List.generate(values.length, (i) => FlSpot(i.toDouble(), values[i])),
          isCurved: true,
          gradient: LinearGradient(colors: [ colors_list[idx % colors_list.length],  colors_list[idx % colors_list.length]]),
          barWidth: 1.5,
          dotData: FlDotData(show: false),
          preventCurveOverShooting: true,
        ));
        idx++;
      }
    });

    if (barGroups.isEmpty) return const SizedBox();

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawHorizontalLine: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(color: colors.border, strokeWidth: 0.5),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 36, getTitlesWidget: (v, meta) => Text(v.toStringAsFixed(0), style: TextStyle(fontSize: 9, color: colors.textHint)))),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: barGroups,
        lineTouchData: LineTouchData(enabled: false),
      ),
    );
  }
}
