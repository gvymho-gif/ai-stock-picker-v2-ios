/// 本地数据服务 - APP直接调用新浪财经/天天基金API
/// 通过Platform Channel调用Java原生GBK解码器(100%准确)
///
/// v7.0: 新增资金流向(东方财富) + 实时刷新支持
/// v8.0: 集成Yahoo Finance为港股/美股补充财务数据
///
/// 数据源:
/// - A股/港股/美股: 新浪财经 (GBK编码 → Java原生解码)
/// - 港股/美股财务: Yahoo Finance (PE/PB/ROE/EPS/股息率等)
/// - A股资金流向: 东方财富 (UTF-8 JSON)
/// - 基金: 天天基金 (UTF-8 JSON)

import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'yahoo_finance_service.dart';
import '../models/investment_calendar.dart';
import 'gbk_decoder.dart';

class LocalDataService {
  static const int _timeoutSeconds = 15;
  static final http.Client _client = http.Client();

  // Platform Channel - Java原生GBK解码
  static const MethodChannel _codecChannel = MethodChannel('com.aistockpicker/codec');
  static bool _channelReady = true;

  // Yahoo Finance 服务 - 港股/美股财务数据补充
  static final YahooFinanceService _yahooService = YahooFinanceService();

  // 行政区划代码 → 省份/城市名称映射（用于EastMoney F10 API返回的SSFDDM字段）
  static const Map<String, String> _provinceMap = {
    '110000': '北京', '120000': '天津', '130000': '河北', '140000': '山西',
    '150000': '内蒙古', '210000': '辽宁', '220000': '吉林', '230000': '黑龙江',
    '310000': '上海', '320000': '江苏', '330000': '浙江', '340000': '安徽',
    '350000': '福建', '360000': '江西', '370000': '山东', '410000': '河南',
    '420000': '湖北', '430000': '湖南', '440000': '广东', '450000': '广西',
    '460000': '海南', '500000': '重庆', '510000': '四川', '520000': '贵州',
    '530000': '云南', '540000': '西藏', '610000': '陕西', '620000': '甘肃',
    '630000': '青海', '640000': '宁夏', '650000': '新疆', '710000': '台湾',
    '810000': '香港', '820000': '澳门',
    '440100': '广州', '440300': '深圳', '440400': '珠海',
    '320100': '南京', '320500': '苏州', '330100': '杭州', '330200': '宁波',
    '370200': '青岛', '370100': '济南', '350200': '厦门', '350100': '福州',
    '420100': '武汉', '430100': '长沙', '510100': '成都', '500100': '重庆',
    '210100': '沈阳', '210200': '大连', '610100': '西安', '410100': '郑州',
    '310100': '上海', '110100': '北京', '120100': '天津',
  };

  /// 将行政区划代码转换为省份/城市名称
  static String _resolveProvince(String code) {
    if (code.isEmpty) return '';
    // 精确匹配
    if (_provinceMap.containsKey(code)) return _provinceMap[code]!;
    // 取前4位匹配（地级市级别）
    if (code.length >= 4) {
      final prefix4 = code.substring(0, 4);
      if (_provinceMap.containsKey(prefix4)) return _provinceMap[prefix4]!;
    }
    // 取前2位匹配（省级）
    if (code.length >= 2) {
      final prefix2 = '${code.substring(0, 2)}0000';
      if (_provinceMap.containsKey(prefix2)) return _provinceMap[prefix2]!;
    }
    return code; // 无法匹配则返回原值
  }

  // ============================================================
  // 核心: 搜索证券/基金
  // ============================================================

  Future<Map<String, dynamic>> searchStock(String query) async {
    if (query.trim().isEmpty) throw Exception('请输入股票/基金代码或名称');
    final q = query.trim();

    // 判断是否为明确的代码格式（6位数字A股/带后缀的代码）
    // 4-5位纯数字不确定市场，需要走智能解析（可能是港股0700或A股/基金代码）
    final isCodeQuery = RegExp(r'^\d{6}(\.(SS|SZ|BJ))?$').hasMatch(q)
        || RegExp(r'^\d{1,5}\.HK$').hasMatch(q.toUpperCase())
        || RegExp(r'^\d{6}\.OF$').hasMatch(q.toUpperCase())
        || RegExp(r'^[A-Za-z]{1,6}$').hasMatch(q);

    String resolvedQuery = q;
    if (!isCodeQuery) {
      // 非纯数字代码 → 用新浪suggest API解析为标准代码
      final resolved = await _resolveNameToCode(q);
      if (resolved != null) {
        resolvedQuery = resolved;
      } else {
        // 新浪搜索无结果 → 尝试Yahoo Finance搜索（对港股/美股更友好）
        final yahooResolved = await _resolveNameToCodeYahoo(q);
        if (yahooResolved != null) {
          resolvedQuery = yahooResolved;
        }
      }
    }

    final parsed = _normalizeSymbol(resolvedQuery);
    final symbol = parsed['normalized'] as String;
    final market = parsed['market'] as String;
    final stype = parsed['type'] as String;

    Map<String, dynamic>? data;
    try {
      data = await _fetchRealTimeData(symbol, market, stype);
    } on TimeoutException { throw Exception('请求超时，请检查网络连接'); }
    catch (e) { if (e is Exception) rethrow; throw Exception('网络错误: $e'); }

    if (data == null) throw Exception('未找到 \'$q\' 的数据。\n支持: A股代码/名称、港股(0700.HK)、美股代码/名称、基金(000001.OF)');

    // 获取机构/基金持仓数据（仅A股）
    Map<String, dynamic>? holderData;
    Map<String, dynamic>? companyProfileData;
    List<Map<String, String>> companyHistory = [];
    
    if (market == 'A') {
      // 并发获取持仓数据和财务数据 — 子请求失败不影响主价格数据
      try {
        final results = await Future.wait([
          _fetchHolderData(symbol),
          _fetchFinancialDataWithRetry(symbol),
        ]);
        holderData = results[0] as Map<String, dynamic>?;
        final finData = results[1] as Map<String, dynamic>?;

        // 补全ROE/EPS/营收增速等财务数据（腾讯API不提供这些字段）
        if (finData != null) {
          if (data['roe'] == null && finData['roe'] != null) data['roe'] = finData['roe'];
          if (data['pb_ratio'] == null && finData['bps'] != null) {
            final price = _safeDouble(data['price']);
            final bps = _safeDouble(finData['bps']);
            if (price > 0 && bps > 0) data['pb_ratio'] = _round(price / bps, 2);
          }
          if (data['eps'] == null && finData['eps'] != null) data['eps'] = finData['eps'];
          if (data['revenue_growth'] == null && finData['revenue_growth'] != null) data['revenue_growth'] = finData['revenue_growth'];
        }
      } catch (_) { /* 辅助数据获取失败不影响主流程 */ }
      
      // 单独获取股息率（东方财富分红融资API）
      try {
        if (data['dividend_yield'] == null) {
          final curPrice = _safeDouble(data['price']);
          final divData = await _fetchDividendYield(symbol, curPrice);
          if (divData != null) data['dividend_yield'] = divData;
        }
      } catch (_) { /* 股息率获取失败不影响主流程 */ }
      
      // 获取企业真实信息
      try {
        companyProfileData = await _fetchCompanyProfileData(symbol);
      } catch (_) { /* 企业信息获取失败不影响主流程 */ }
      try {
        companyHistory = await _fetchCompanyHistory(symbol);
      } catch (_) { /* 企业历史获取失败不影响主流程 */ }
    }

    // 港股/美股: 使用Yahoo Finance补充财务数据
    if (market == 'HK' || market == 'US') {
      try {
        final yahooData = await _yahooService.fetchQuoteSummary(symbol);
        if (yahooData != null) {
          // 补充腾讯API缺失的字段
          if (data['pb_ratio'] == null && yahooData['pb_ratio'] != null && yahooData['pb_ratio'] > 0) {
            data['pb_ratio'] = yahooData['pb_ratio'];
          }
          if (data['roe'] == null && yahooData['roe'] != null) {
            data['roe'] = yahooData['roe'];
          }
          if (data['eps'] == null && yahooData['eps'] != null) {
            data['eps'] = yahooData['eps'];
          }
          if (data['revenue_growth'] == null && yahooData['revenue_growth'] != null) {
            data['revenue_growth'] = yahooData['revenue_growth'];
          }
          if (data['dividend_yield'] == null && yahooData['dividend_yield'] != null) {
            data['dividend_yield'] = yahooData['dividend_yield'];
          }
          // 补充行业和板块信息
          if (yahooData['industry'] != null) data['industry'] = yahooData['industry'];
          if (yahooData['sector'] != null) data['sector'] = yahooData['sector'];
          if (yahooData['description'] != null) data['description'] = yahooData['description'];
          if (yahooData['beta'] != null) data['beta'] = yahooData['beta'];
          // 补充公司基本信息
          if (yahooData['employees'] != null) data['employees'] = yahooData['employees'];
          if (yahooData['country'] != null) data['country'] = yahooData['country'];
          if (yahooData['city'] != null) data['city'] = yahooData['city'];
          if (yahooData['website'] != null) data['website'] = yahooData['website'];
          // 补充利润率数据
          if (yahooData['gross_margin'] != null) data['gross_margin'] = yahooData['gross_margin'];
          if (yahooData['operating_margin'] != null) data['operating_margin'] = yahooData['operating_margin'];
          if (yahooData['net_margin'] != null) data['net_margin'] = yahooData['net_margin'];
          // 补充52周高低（如果腾讯API未返回）
          if (data['week52_high'] == null && yahooData['week52_high'] != null) {
            data['week52_high'] = yahooData['week52_high'];
          }
          if (data['week52_low'] == null && yahooData['week52_low'] != null) {
            data['week52_low'] = yahooData['week52_low'];
          }
          // 补充市值（如果腾讯API未返回）
          if (data['market_cap'] == null && yahooData['market_cap'] != null) {
            data['market_cap'] = yahooData['market_cap'];
          }
          // 如果腾讯没有返回名称，使用Yahoo的名称
          if (data['name'] == null || data['name'] == symbol || data['name'].toString().isEmpty) {
            data['name'] = yahooData['name'] ?? data['name'];
          }
        }
      } catch (_) {
        // Yahoo API失败不影响主流程
      }

      // 为港股/美股构建企业简介数据（从Yahoo Finance提取）
      if (companyProfileData == null) {
        final yahooDesc = data['description']?.toString() ?? '';
        final yahooIndustry = data['industry']?.toString() ?? '';
        final yahooSector = data['sector']?.toString() ?? '';
        final yahooEmployees = data['employees']?.toString() ?? '';
        final yahooCountry = data['country']?.toString() ?? '';
        final yahooCity = data['city']?.toString() ?? '';
        final yahooWebsite = data['website']?.toString() ?? '';
        if (yahooDesc.isNotEmpty || yahooIndustry.isNotEmpty) {
          companyProfileData = {
            if (yahooDesc.isNotEmpty) 'company_desc': yahooDesc,
            if (yahooIndustry.isNotEmpty) 'industry': yahooIndustry,
            if (yahooSector.isNotEmpty) 'sector': yahooSector,
            if (yahooEmployees.isNotEmpty && yahooEmployees != 'null') 'employees': yahooEmployees,
            if (yahooCountry.isNotEmpty) 'country': yahooCountry,
            if (yahooCity.isNotEmpty) 'city': yahooCity,
            if (yahooWebsite.isNotEmpty) 'website': yahooWebsite,
          };
        }
      }
    }

    // 生成所有指标分析
    final priceAnalysis = _analyzePrice(data);
    final volumeAnalysis = _analyzeVolume(data);
    final volatilityAnalysis = _analyzeVolatility(data);
    final bidAskAnalysis = _analyzeBidAsk(data);
    final trendAnalysis = _analyzeTrend(data);
    final valuationAnalysis = _analyzeValuation(data);
    final momentumAnalysis = _analyzeMomentum(data);
    final supportResistance = _analyzeSupportResistance(data);
    final capitalFlowAnalysis = _analyzeCapitalFlow(data, holderData);
    // 暗盘数据（集合竞价+盘后数据，仅A股）
    final preMarketAnalysis = market == 'A' ? await _analyzePreMarket(data) : null;

    // 汇总所有模块数据（供极智深度分析使用）
    final allModules = <String, Map<String, dynamic>>{
      'price': priceAnalysis,
      'volume': volumeAnalysis,
      'volatility': volatilityAnalysis,
      'bid_ask': bidAskAnalysis,
      'trend': trendAnalysis,
      'valuation': valuationAnalysis,
      'momentum': momentumAnalysis,
      'support_resistance': supportResistance,
      'capital_flow': capitalFlowAnalysis,
      if (preMarketAnalysis != null) 'pre_market': preMarketAnalysis,
    };

    // 综合四层评分
    final fs = _fundamentalScore(data);
    final ts = _technicalScore(data);
    final cs = _capitalFlowScore(data);
    final ms = _momentumScore(data);
    final ai = _aiDecision(data, fs, ts, cs, ms);

    // 本地AI分析由UI层异步触发，不在此同步调用（避免搜索变慢）

    final mc = _safeDouble(data['market_cap']);
    String mcd = 'N/A';
    if (mc >= 1e12) mcd = '${(mc / 1e12).toStringAsFixed(1)}万亿';
    else if (mc >= 1e8) mcd = '${(mc / 1e8).toStringAsFixed(1)}亿';
    else if (mc > 0) mcd = mc.toStringAsFixed(0);

    final extra = <String, dynamic>{};
    if (data['type'] == 'fund') {
      extra['fund_type'] = 'fund';
      if (data['nav'] != null) extra['nav'] = data['nav'];
      if (data['estimated_nav'] != null) extra['estimated_nav'] = data['estimated_nav'];
    }

    return {
      'symbol': symbol,
      'name': data['name'] ?? symbol,
      'market': market,
      'price': data['price'],
      'change_pct': data['change_pct'] ?? 0,
      'open': data['open'],
      'prev_close': data['prev_close'],
      'high': data['high'],
      'low': data['low'],
      'volume': data['volume'],
      'amount': data['amount'],
      'turnover_rate': data['turnover_rate'],
      'market_cap': mc,
      'market_cap_display': mcd,
      'pe_ratio': data['pe_ratio'],
      'pb_ratio': data['pb_ratio'],
      'roe': data['roe'],
      'revenue_growth': data['revenue_growth'],
      'eps': data['eps'],
      'dividend_yield': data['dividend_yield'],
      'week52_high': data['week52_high'],
      'week52_low': data['week52_low'],
      // Yahoo Finance 补充字段（港股/美股）
      'industry': data['industry'],
      'sector': data['sector'],
      'description': data['description'],
      'beta': data['beta'],
      'gross_margin': data['gross_margin'],
      'operating_margin': data['operating_margin'],
      'net_margin': data['net_margin'],
      'bid1': data['bid1'], 'bid1_vol': data['bid1_vol'],
      'bid2': data['bid2'], 'bid2_vol': data['bid2_vol'],
      'bid3': data['bid3'], 'bid3_vol': data['bid3_vol'],
      'bid4': data['bid4'], 'bid4_vol': data['bid4_vol'],
      'bid5': data['bid5'], 'bid5_vol': data['bid5_vol'],
      'ask1': data['ask1'], 'ask1_vol': data['ask1_vol'],
      'ask2': data['ask2'], 'ask2_vol': data['ask2_vol'],
      'ask3': data['ask3'], 'ask3_vol': data['ask3_vol'],
      'ask4': data['ask4'], 'ask4_vol': data['ask4_vol'],
      'ask5': data['ask5'], 'ask5_vol': data['ask5_vol'],
      'date': data['date'],
      'time': data['time'],
      // 每项指标的独立AI分析
      'analysis': {
        'price': priceAnalysis,
        'volume': volumeAnalysis,
        'volatility': volatilityAnalysis,
        'bid_ask': bidAskAnalysis,
        'trend': trendAnalysis,
        'valuation': valuationAnalysis,
        'momentum': momentumAnalysis,
        'support_resistance': supportResistance,
        'capital_flow': capitalFlowAnalysis,
        if (preMarketAnalysis != null) 'pre_market': preMarketAnalysis,
        'ai_detailed': await _generateAIDetailed(data, ai, allModules),
        'company_profile': _generateCompanyProfile(data, companyProfileData, companyHistory),
      },
      'ai_analysis': ai,
      'data_source': data['source'] ?? 'unknown',
      'disclaimer': '本工具仅供参考，不构成投资建议。投资有风险，入市需谨慎。',
      // 异步获取新闻的占位符（UI层调用fetchStockNews获取实际数据）
      'has_news_api': true,
      ...extra
    };
  }

  // ============================================================
  // 代码解析
  // ============================================================
  static Map<String, String> _normalizeSymbol(String q) {
    q = q.trim().toUpperCase();
    if (q.contains('.SS')) return {'raw': q, 'normalized': q, 'market': 'A', 'type': 'stock'};
    if (q.contains('.SZ')) return {'raw': q, 'normalized': q, 'market': 'A', 'type': 'stock'};
    if (q.contains('.BJ')) return {'raw': q, 'normalized': q, 'market': 'A', 'type': 'stock'};
    if (q.contains('.HK')) {
      final c = q.split('.').first;
      return {'raw': q, 'normalized': '$c.HK', 'market': 'HK', 'type': 'stock'};
    }
    if (q.contains('.OF')) {
      final c = q.split('.').first;
      return {'raw': q, 'normalized': '$c.OF', 'market': 'CN', 'type': 'fund'};
    }
    if (RegExp(r'^\d{6}$').hasMatch(q)) {
      final p = q.substring(0, 3);
      // 沪市：600/601/603/605/688(科创板)/900(B股)
      if (['600', '601', '603', '605', '688', '900'].contains(p))
        return {'raw': q, 'normalized': '$q.SS', 'market': 'A', 'type': 'stock'};
      // 深市：000/001/002/003/300(创业板)/301(创业板)
      else if (['000', '001', '002', '003', '300', '301'].contains(p))
        return {'raw': q, 'normalized': '$q.SZ', 'market': 'A', 'type': 'stock'};
      // 北交所：8开头(82/83/87/88等) 或 4开头(43等)
      else if (p.startsWith('8') || p.startsWith('4'))
        return {'raw': q, 'normalized': '$q.BJ', 'market': 'A', 'type': 'stock'};
      else
        return {'raw': q, 'normalized': '$q.OF', 'market': 'CN', 'type': 'fund'};
    }
    if (RegExp(r'^[A-Z]{1,6}$').hasMatch(q)) return {'raw': q, 'normalized': q, 'market': 'US', 'type': 'stock'};
    if (q.contains('HK')) {
      final c = q.replaceAll('.HK', '').replaceAll('HK', '');
      return {'raw': q, 'normalized': '$c.HK', 'market': 'HK', 'type': 'stock'};
    }
    return {'raw': q, 'normalized': q, 'market': 'UNKNOWN', 'type': 'unknown'};
  }

  /// 新浪suggest API: 用名称/拼音搜索 → 返回标准代码 (如 "600519.SS")
  /// 支持中文(贵州茅台)、拼音(maotai)、英文(Apple)、简拼(gzmt)
  /// 返回null表示未找到
  Future<String?> _resolveNameToCode(String query) async {
    try {
      final resp = await _client.get(
        Uri.parse('https://suggest3.sinajs.cn/suggest/type=&key=${Uri.encodeComponent(query)}&name=suggestdata'),
        headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 12)', 'Referer': 'https://finance.sina.com.cn'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) return null;
      final text = await _decodeGbk(resp.bodyBytes);
      if (text.isEmpty) return null;

      // 格式: var suggestdata="名称,类型,代码,完整代码,名称,...;名称,类型,代码,..."
      final match = RegExp(r'="([^"]*)"').firstMatch(text);
      if (match == null) return null;
      final content = match.group(1);
      if (content == null || content.isEmpty) return null;

      final entries = content.split(';');
      // 优先级: A股(11/12) > 港股(31) > 美股(41) > 基金(21/201)
      // 类型代码: 11=沪A股, 12=深A股, 31=港股, 41=美股, 21/201=基金
      final priorityTypes = ['11', '12', '31', '41', '21', '201'];

      for (final typeCode in priorityTypes) {
        for (final entry in entries) {
          final fields = entry.split(',');
          if (fields.length < 4) continue;
          final entryType = fields[1]; // 类型代码
          if (entryType != typeCode) continue;

          final code = fields[2];       // 代码 (如 600519)
          final fullCode = fields[3];   // 完整代码 (如 sh600519)

          // 转换为标准格式（根据完整代码前缀判断市场，而不是类型代码）
          if (entryType == '11' || entryType == '12') {
            // A股：根据完整代码前缀判断沪市/深市/北交所
            if (fullCode.startsWith('sh')) {
              return '${code}.SS';
            } else if (fullCode.startsWith('sz')) {
              return '${code}.SZ';
            } else if (fullCode.startsWith('bj')) {
              return '${code}.BJ';
            } else {
              // 兜底：根据代码首位判断
              if (code.startsWith('6')) return '${code}.SS';
              if (code.startsWith('0') || code.startsWith('3')) return '${code}.SZ';
              if (code.startsWith('8') || code.startsWith('4')) return '${code}.BJ';
              return '${code}.SS';
            }
          } else if (entryType == '31') {
            // 港股: 00700 → 00700.HK
            return '${code}.HK';
          } else if (entryType == '41') {
            // 美股: aapl → AAPL
            return code.toUpperCase();
          } else if (entryType == '21' || entryType == '201') {
            // 基金: of519677 → 519677.OF
            final fundCode = code.startsWith('of') ? code.substring(2) : code;
            return '$fundCode.OF';
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // Yahoo Finance 搜索（港股/美股增强）
  // ============================================================

  /// 使用 Yahoo Finance 搜索港股/美股
  /// 返回搜索结果列表，每项包含 symbol/name/exchange/market
  Future<List<Map<String, dynamic>>> searchStocksYahoo(String query, {String? market}) async {
    return _yahooService.searchStocks(query, market: market);
  }

  /// 使用 Yahoo Finance 解析名称到代码（新浪搜索无结果时的备选方案）
  Future<String?> _resolveNameToCodeYahoo(String query, {String? preferredMarket}) async {
    try {
      final results = await _yahooService.searchStocks(query, market: preferredMarket);
      if (results.isEmpty) return null;

      // 优先选择匹配市场的结果
      if (preferredMarket != null) {
        final matched = results.where((r) => r['market'] == preferredMarket).toList();
        if (matched.isNotEmpty) return matched[0]['symbol'] as String;
      }

      // 返回第一个结果
      return results[0]['symbol'] as String;
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // 数据获取 + GBK解码
  // ============================================================

  Future<Map<String, dynamic>?> _fetchRealTimeData(String symbol, String market, String stype) async {
    if (stype == 'fund') return _fetchFund(symbol);
    if (market == 'A') return _fetchAStockSina(symbol);
    if (market == 'HK') return _fetchHKStockSina(symbol);
    if (market == 'US') return _fetchUSStockSina(symbol);
    return null;
  }

  /// 轻量行情查询 — 仅返回价格/涨跌幅等核心字段，不触发AI分析/财务数据
  /// 用于持仓快照刷新，避免 searchStock 的完整流程导致超时或异常
  /// 主用腾讯API，失败时回退新浪API
  Future<Map<String, dynamic>?> fetchQuickQuote(String code) async {
    try {
      final parsed = _normalizeSymbol(code.trim());
      final symbol = parsed['normalized'] as String;
      final market = parsed['market'] as String;
      final stype = (parsed['type'] ?? 'stock') as String;

      final data = await _fetchRealTimeData(symbol, market, stype);
      if (data != null && _safeDouble(data['price']) > 0) {
        return {
          'symbol': symbol,
          'name': data['name'] ?? symbol,
          'price': data['price'],
          'change_pct': data['change_pct'] ?? 0,
          'open': data['open'],
          'prev_close': data['prev_close'],
          'high': data['high'],
          'low': data['low'],
          'volume': data['volume'],
          'amount': data['amount'],
          'turnover_rate': data['turnover_rate'],
          'market_cap': data['market_cap'],
        };
      }

      // 腾讯API失败 → 尝试新浪实时行情API回退
      if (market == 'A') {
        final sinaData = await _fetchSinaRealtimeQuote(symbol);
        if (sinaData != null) return sinaData;
      }
    } catch (_) {}
    return null;
  }

  /// 新浪实时行情API备用 — 当腾讯API失败时使用
  /// 格式: hq_str_sh600460="士兰微,35.37,32.15,32.91,..."
  Future<Map<String, dynamic>?> _fetchSinaRealtimeQuote(String symbol) async {
    try {
      final parts = symbol.split('.');
      final code = parts[0];
      final exch = parts.length > 1 ? parts[1] : 'SS';
      final sinaPrefix = exch == 'SS' ? 'sh' : exch == 'BJ' ? 'bj' : 'sz';
      final sinaCode = '$sinaPrefix$code';

      final resp = await _client.get(
        Uri.parse('https://hq.sinajs.cn/list=$sinaCode'),
        headers: {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://finance.sina.com.cn'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200) return null;
      final text = await _decodeGbk(resp.bodyBytes);
      if (text.isEmpty) return null;

      final match = RegExp(r'="([^"]*)"').firstMatch(text);
      if (match == null) return null;
      final content = match.group(1);
      if (content == null || content.isEmpty) return null;

      final f = content.split(',');
      if (f.length < 32) return null;

      final name = f[0].trim();
      final open = _safeDouble(f[1]);
      final prevClose = _safeDouble(f[2]);
      final price = _safeDouble(f[3]);
      final high = _safeDouble(f[4]);
      final low = _safeDouble(f[5]);
      final volume = _safeDouble(f[8]);
      final amount = _safeDouble(f[9]);

      if (price <= 0) return null;

      final changePct = prevClose > 0 ? (price - prevClose) / prevClose * 100 : 0.0;

      return {
        'symbol': symbol,
        'name': name,
        'price': _round(price, 2),
        'change_pct': _round(changePct, 2),
        'open': _round(open, 2),
        'prev_close': _round(prevClose, 2),
        'high': _round(high, 2),
        'low': _round(low, 2),
        'volume': _safeInt(volume),
        'amount': amount,
        'turnover_rate': null,
        'market_cap': null,
      };
    } catch (_) {
      return null;
    }
  }

  /// 腾讯行情API - A股
  /// 字段索引(0-based): 1=名称,2=代码,3=现价,4=昨收,5=今开,
  /// 31=涨跌额,32=涨跌幅,33=最高,34=最低,
  /// 36=成交量(手),37=成交额(万),38=换手率%,39=PE市盈率,
  /// 44=总市值(亿),45=流通市值(亿),46=PB市净率,
  /// 48=52周最高价,49=52周最低价
  Future<Map<String, dynamic>?> _fetchAStockSina(String symbol) async {
    final parts = symbol.split('.');
    final code = parts[0];
    final exch = parts.length > 1 ? parts[1] : 'SS';
    final qqCode = exch == 'SS' ? 'sh$code' : exch == 'BJ' ? 'bj$code' : 'sz$code';

    try {
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$qqCode'),
        headers: {'User-Agent': 'Mozilla/5.0'}
      ).timeout(const Duration(seconds: _timeoutSeconds));

      if (resp.statusCode != 200) return null;
      final text = await _decodeGbk(resp.bodyBytes);
      if (text.isEmpty) return null;

      final match = RegExp(r'="([^"]*)"').firstMatch(text);
      if (match == null) return null;
      final g1 = match.group(1);
      if (g1 == null || g1.isEmpty) return null;
      final f = g1.split('~');
      if (f.length < 50) return null;

      final cur = _safeDouble(f[3]);
      final prevClose = _safeDouble(f[4]);
      if (cur <= 0) return null;

      // 买一到买五 (腾讯: f[9]=买一价,f[10]=买一量, ...)
      return {
        'symbol': symbol, 'name': f[1].trim(), 'price': _round(cur, 2),
        'open': _round(_safeDouble(f[5]), 2), 'prev_close': _round(prevClose, 2),
        'high': _round(_safeDouble(f[33]), 2), 'low': _round(_safeDouble(f[34]), 2),
        'change_pct': _round(_safeDouble(f[32]), 2),
        'change_amt': _round(_safeDouble(f[31]), 2),
        'volume': _safeInt(_safeDouble(f[36])), 'amount': _safeDouble(f[37]) * 10000,
        'turnover_rate': _safeDouble(f[38]) > 0 ? _round(_safeDouble(f[38]), 2) : null,
        'bid1': _safeDouble(f[9]), 'bid1_vol': _safeInt(_safeDouble(f[10])),
        'bid2': _safeDouble(f[11]), 'bid2_vol': _safeInt(_safeDouble(f[12])),
        'bid3': _safeDouble(f[13]), 'bid3_vol': _safeInt(_safeDouble(f[14])),
        'bid4': _safeDouble(f[15]), 'bid4_vol': _safeInt(_safeDouble(f[16])),
        'bid5': _safeDouble(f[17]), 'bid5_vol': _safeInt(_safeDouble(f[18])),
        'ask1': _safeDouble(f[19]), 'ask1_vol': _safeInt(_safeDouble(f[20])),
        'ask2': _safeDouble(f[21]), 'ask2_vol': _safeInt(_safeDouble(f[22])),
        'ask3': _safeDouble(f[23]), 'ask3_vol': _safeInt(_safeDouble(f[24])),
        'ask4': _safeDouble(f[25]), 'ask4_vol': _safeInt(_safeDouble(f[26])),
        'ask5': _safeDouble(f[27]), 'ask5_vol': _safeInt(_safeDouble(f[28])),
        'date': f.length > 30 ? f[30].substring(0, 8) : '', 'time': f.length > 30 ? f[30].substring(8) : '',
        'market_cap': _safeDouble(f[44]) * 1e8,
        'pe_ratio': _safeDouble(f[39]) > 0 ? _round(_safeDouble(f[39]), 2) : null,
        'pb_ratio': _safeDouble(f[46]) > 0 ? _round(_safeDouble(f[46]), 2) : null,  // f[46]=PB市净率
        'roe': null, 'revenue_growth': null, 'eps': null,
        'dividend_yield': null,  // 由_fetchDividendYield计算
        'week52_high': _safeDouble(f[48]) > 0 ? _round(_safeDouble(f[48]), 2) : null,  // f[48]=52周最高价
        'week52_low': _safeDouble(f[49]) > 0 ? _round(_safeDouble(f[49]), 2) : null,    // f[49]=52周最低价
        'source': 'qq_a'
      };
    } catch (_) { return null; }
  }

  /// 腾讯行情API - 港股
  /// 字段(实测00700): f[1]=名称, f[2]=代码, f[4]=现价, f[5]=昨收, f[6]=今开,
  /// f[7]=成交量(股), f[31]=日期时间, f[32]=涨跌额, f[33]=涨跌幅,
  /// f[34]=最高, f[35]=最低, f[37]=成交量(股), f[38]=成交额,
  /// f[40]=PE, f[44]=总市值(亿), f[49]=52周高, f[50]=52周低
  Future<Map<String, dynamic>?> _fetchHKStockSina(String symbol) async {
    // 港股代码-中文名称映射表 (扩展到200只热门股)
    final hkStockNames = <String, String>{
      // 科技互联网
      '00700': '腾讯控股', '09988': '阿里巴巴', '09618': '京东集团', '03690': '美团', '01810': '小米集团',
      '09999': '网易', '09888': '百度集团', '02498': '快手', '09992': '泡泡玛特', '09961': '携程集团',
      '02015': '理想汽车', '09868': '小鹏汽车', '09866': '蔚来', '01161': '中通快递', '02608': '金山软件',
      '03888': '金山云', '00268': '金蝶国际', '06060': '众安在线', '01833': '平安好医生', '02382': '舜宇光学',
      '01357': '美图公司', '02018': '瑞声科技', '00772': '阅文集团', '03013': 'KEEP', '09626': '哔哩哔哩',
      // 金融银行
      '01299': '友邦保险', '02318': '中国平安', '03988': '中国银行', '00939': '建设银行', '01288': '农业银行',
      '02628': '中国人寿', '01398': '工商银行', '03968': '招商银行', '00005': '汇丰控股', '02388': '中银香港',
      '01141': '恒生银行', '02601': '中国太保', '01238': '广发证券', '06030': '中信证券', '06837': '海通证券',
      '03908': '中金公司', '06886': '港交所', '01658': '邮储银行', '01988': '民生银行', '03328': '交通银行',
      // 地产基建
      '00001': '长和', '00006': '电能实业', '00011': '恒生银行', '00016': '新鸿基地产', '00017': '新世界发展',
      '00083': '信和置业', '00101': '恒隆地产', '00123': '越秀地产', '00688': '中国海外', '01109': '华润置地',
      '02007': '碧桂园', '01918': '融创中国', '02669': '中海物业', '03333': '中国恒大', '00817': '中国建筑国际',
      '01776': '天虹纺织', '01234': '亚太地产', '02868': '首创置业', '00207': '侨鑫集团', '00059': '天伦燃气',
      // 消费医药
      '01698': '华润啤酒', '00187': '京城机电', '02423': '达利食品', '02313': '申洲国际', '02269': '药明生物',
      '02359': '药明康德', '01093': '石药集团', '02202': '万科企业', '01359': '信达生物', '01812': '晨鸣纸业',
      '01177': '中国黄金', '01203': '晨鸣纸业', '00832': '中建投', '00124': '越秀交通', '01157': '中联重科',
      // 能源资源
      '00941': '中国移动', '00857': '中国石油', '00883': '中国海洋石油', '01898': '中煤能源', '03883': '中海油田',
      '01088': '中国神华', '00386': '中国石油化工', '00669': '中国电信', '00762': '中国联通', '00902': '华能国际',
      '00916': '龙源电力', '00991': '大唐发电', '00836': '华润电力', '00635': '中化化肥', '00358': '江西铜业',
      // 汽车制造
      '02333': '长城汽车', '01788': '国泰航空', '02633': '海尔智家', '00669': '创科实业', '01919': '中远海控',
      '02319': '蒙牛乳业', '00293': '国泰航空', '00388': '港交所', '01816': '中广核电力', '01055': '中国南方航空',
      // 其他热门
      '09922': '康方生物', '03888': '金山云', '09961': '携程集团', '09992': '泡泡玛特', '02015': '理想汽车',
      '06060': '众安在线', '01833': '平安好医生', '02382': '舜宇光学', '09626': '哔哩哔哩', '03692': '联想集团',
      '00241': '阿里健康', '03969': '中国燃气', '01024': '快手', '09868': '小鹏汽车', '09866': '蔚来',
      '06618': '京东健康', '09961': '携程', '02096': '复星医药', '01011': '中粮控股', '00868': '信义玻璃',
    };
    final rawCode = symbol.replaceAll('.HK', '');
    final numPart = int.tryParse(rawCode) ?? 0;
    final code = numPart.toString().padLeft(5, '0');
    try {
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=r_hk$code'),
        headers: {'User-Agent': 'Mozilla/5.0'}
      ).timeout(const Duration(seconds: _timeoutSeconds));
      if (resp.statusCode != 200) return null;
      final text = await _decodeGbk(resp.bodyBytes);
      if (text.isEmpty) return null;

      final match = RegExp(r'="([^"]*)"').firstMatch(text);
      if (match == null) return null;
      final g1 = match.group(1);
      if (g1 == null || g1.isEmpty) return null;
      final f = g1.split('~');
      if (f.length < 51) return null;

      final cur = _safeDouble(f[4]);
      if (cur <= 0) return null;
      final prevClose = _safeDouble(f[5]);
      // 优先使用中文映射表，避免显示数字或代码
      final name = hkStockNames[code] ?? f[1].trim();
      
      // 手动计算涨跌幅（更准确）
      final changePct = prevClose > 0 ? _round((cur - prevClose) / prevClose * 100, 2) : 0.0;
      final changeAmt = _round(cur - prevClose, 3);

      return {
        'symbol': symbol, 'name': name, 'price': _round(cur, 3),
        'open': _round(_safeDouble(f[6]), 3), 'prev_close': _round(prevClose, 3),
        'high': _round(_safeDouble(f[34]), 3), 'low': _round(_safeDouble(f[35]), 3),
        'change_pct': changePct,
        'change_amt': changeAmt,
        'volume': _safeInt(_safeDouble(f[37])),
        'amount': _safeDouble(f[38]),
        'turnover_rate': null,  // 港股无直接换手率字段
        'bid1': null, 'bid1_vol': null, 'bid2': null, 'bid2_vol': null,
        'bid3': null, 'bid3_vol': null, 'bid4': null, 'bid4_vol': null,
        'bid5': null, 'bid5_vol': null,
        'ask1': null, 'ask1_vol': null, 'ask2': null, 'ask2_vol': null,
        'ask3': null, 'ask3_vol': null, 'ask4': null, 'ask4_vol': null,
        'ask5': null, 'ask5_vol': null,
        'date': f.length > 31 ? f[31].split(' ')[0].replaceAll('/', '') : '', 'time': f.length > 31 ? (f[31].contains(' ') ? f[31].split(' ')[1] : '') : '',
        'market_cap': _safeDouble(f[44]) * 1e8,
        'pe_ratio': _safeDouble(f[40]) > 0 ? _round(_safeDouble(f[40]), 2) : null,
        'pb_ratio': null, 'roe': null, 'revenue_growth': null, 'eps': null,
        'dividend_yield': _safeDouble(f[46]) > 0 ? _round(_safeDouble(f[46]), 2) : null,  // f[46]=股息率%
        'week52_high': _safeDouble(f[49]) > 0 ? _round(_safeDouble(f[49]), 3) : null,
        'week52_low': _safeDouble(f[50]) > 0 ? _round(_safeDouble(f[50]), 3) : null,
        'source': 'qq_hk'
      };
    } catch (_) { return null; }
  }

  /// 腾讯行情API - 美股
  /// 字段(实测AAPL): f[1]=名称, f[3]=现价, f[4]=昨收, f[5]=今开,
  /// f[31]=日期时间, f[32]=涨跌额, f[33]=涨跌幅, f[34]=最高, f[35]=最低,
  /// f[37]=成交量, f[38]=成交额, f[40]=PE, f[45]=总市值(亿),
  /// f[49]=52周高, f[50]=52周低
  Future<Map<String, dynamic>?> _fetchUSStockSina(String symbol) async {
    // 美股代码-中文名称映射表 (扩展到200只热门股)
    final usStockNames = <String, String>{
      // 科技巨头
      'AAPL': '苹果公司', 'MSFT': '微软', 'NVDA': '英伟达', 'GOOG': '谷歌', 'GOOGL': '谷歌A',
      'AMZN': '亚马逊', 'META': 'Meta', 'TSLA': '特斯拉', 'AVGO': '博通', 'CRM': '赛富时',
      'AMD': '超微半导体', 'NFLX': '奈飞', 'ADBE': 'Adobe', 'INTC': '英特尔', 'PYPL': 'PayPal',
      // 半导体
      'QCOM': '高通', 'TXN': '德州仪器', 'MU': '美光科技', 'AMAT': '应用材料', 'LRCX': '拉姆研究',
      'KLAC': '科磊', 'MRVL': '迈威尔', 'ON': '安森美', 'SWKS': '思佳讯', 'MPWR': 'Monolithic Power',
      'SNPS': '新思科技', 'CDNS': '铿腾电子', 'ENTG': 'Entegris', 'TER': '泰瑞达', 'ACLX': 'Axcelis',
      'COHR': '相干公司', 'ASML': '阿斯麦', 'ARM': 'ARM控股', 'MCHP': '微芯科技', 'NXPI': '恩智浦',
      // 互联网/软件
      'UBER': 'Uber', 'ABNB': '爱彼迎', 'SNOW': 'Snowflake', 'PLTR': 'Palantir', 'CRWD': 'CrowdStrike',
      'DDOG': 'Datadog', 'ZS': 'Zscaler', 'NET': 'Cloudflare', 'MDB': 'MongoDB', 'TTD': 'The Trade Desk',
      'SHOP': 'Shopify', 'SQ': 'Block', 'COIN': 'Coinbase', 'ROKU': 'Roku', 'SPOT': 'Spotify',
      'PINS': 'Pinterest', 'SNAP': 'Snap', 'RBLX': 'Roblox', 'ZI': 'ZoomInfo', 'DOCU': 'DocuSign',
      // 金融
      'V': 'Visa', 'MA': '万事达', 'JPM': '摩根大通', 'BAC': '美国银行', 'WFC': '富国银行',
      'GS': '高盛', 'MS': '摩根士丹利', 'BLK': '贝莱德', 'SCHW': '嘉信理财', 'C': '花旗集团',
      'AXP': '美国运通', 'USB': '合众银行', 'PNC': 'PNC金融', 'COF': 'Capital One', 'BK': '纽约梅隆',
      'CB': 'Chubb', 'AIG': 'AIG', 'MET': '大都会人寿', 'PRU': '保德信金融', 'ALL': '好事达',
      // 医疗健康
      'UNH': '联合健康', 'LLY': '礼来', 'JNJ': '强生', 'PFE': '辉瑞', 'MRK': '默克',
      'ABBV': '艾伯维', 'MRNA': 'Moderna', 'AMGN': '安进', 'GILD': '吉利德', 'BIIB': '渤健',
      'REGN': '再生元', 'VRTX': '福泰制药', 'ISRG': '直觉外科', 'TMO': '赛默飞', 'ABT': '雅培',
      'DHR': '丹纳赫', 'SYK': '史赛克', 'BSX': '波士顿科学', 'EW': '爱德华兹', 'ZBH': '捷迈邦美',
      // 消费品牌
      'WMT': '沃尔玛', 'COST': '开市客', 'PG': '宝洁', 'KO': '可口可乐', 'PEP': '百事可乐',
      'MCD': '麦当劳', 'SBUX': '星巴克', 'NKE': '耐克', 'HD': '家得宝', 'TGT': '塔吉特',
      'LOW': '劳氏', 'CVS': 'CVS健康', 'EL': '雅诗兰黛', 'CL': '高露洁', 'KMB': '金佰利',
      'GIS': '通用磨坊', 'CLX': '高乐氏', 'MDLZ': '亿滋国际', 'HSY': '好时', 'STZ': '星座品牌',
      // 能源
      'XOM': '埃克森美孚', 'CVX': '雪佛龙', 'COP': '康菲石油', 'SLB': '斯伦贝谢', 'EOG': 'EOG能源',
      'OXY': '西方石油', 'MPC': '马拉松石油', 'VLO': '瓦莱罗', 'WMB': '威廉姆斯', 'OKE': 'ONEOK',
      // 工业
      'CAT': '卡特彼勒', 'BA': '波音', 'GE': '通用电气', 'HON': '霍尼韦尔', 'UNP': '联合太平洋',
      'UPS': 'UPS', 'RTX': '雷神技术', 'LMT': '洛克希德', 'DE': '迪尔', 'MMM': '3M',
      'EMR': '艾默生电气', 'ETN': '伊顿', 'CMI': '康明斯', 'PH': '帕克汉尼汾', 'ITW': '伊利诺伊工具',
      // 通信媒体
      'CMCSA': '康卡斯特', 'VZ': '威瑞森', 'T': 'AT&T', 'TMUS': 'T-Mobile', 'DIS': '迪士尼',
      'WBD': '华纳兄弟', 'PARA': '派拉蒙',
      // 中概股
      'BABA': '阿里巴巴', 'JD': '京东', 'PDD': '拼多多', 'BILI': '哔哩哔哩', 'NTES': '网易',
      'TME': '腾讯音乐', 'BIDU': '百度', 'NIO': '蔚来', 'XPEV': '小鹏汽车', 'LI': '理想汽车',
      'FUTU': '富途', 'TIGR': '老虎证券', 'YMM': '满帮集团', 'DIDI': '滴滴', 'ZLAB': '再鼎医药',
      'BZ': 'Kanzhun', 'TAL': '好未来', 'EDU': '新东方', 'VIPS': '唯品会', 'IQ': '爱奇艺',
      // 其他热门
      'IBM': 'IBM', 'TRV': '旅行者保险', 'DOW': '陶氏化学', 'PM': '菲利普莫里斯', 'MO': '奥驰亚',
      'BRK-B': '伯克希尔B', 'BRK.A': '伯克希尔A', 'LULU': 'Lululemon', 'ROST': '罗斯百货',
      'DLTR': 'Dollar Tree', 'BKNG': 'Booking', 'MAR': '万豪', 'HLT': '希尔顿',
      'RCL': '皇家加勒比', 'CCL': '嘉年华', 'NCLH': '诺唯真', 'UAL': '联合航空',
      'DAL': '达美航空', 'AAL': '美国航空', 'LUV': '西南航空', 'FDX': '联邦快递', 'NVO': '诺和诺德',
    };
    final code = symbol.toUpperCase();
    try {
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=us$code'),
        headers: {'User-Agent': 'Mozilla/5.0'}
      ).timeout(const Duration(seconds: _timeoutSeconds));
      if (resp.statusCode != 200) return null;
      final text = await _decodeGbk(resp.bodyBytes);
      if (text.isEmpty) return null;

      final match = RegExp(r'="([^"]*)"').firstMatch(text);
      if (match == null) return null;
      final g1 = match.group(1);
      if (g1 == null || g1.isEmpty) return null;
      final f = g1.split('~');
      if (f.length < 51) return null;

      final cur = _safeDouble(f[3]);
      if (cur <= 0) return null;
      // 优先使用中文映射表，避免显示数字或代码
      final name = usStockNames[code] ?? f[1].trim();
      final prevClose = _safeDouble(f[4]);
      
      // 手动计算涨跌幅（更准确）
      final changePct = prevClose > 0 ? _round((cur - prevClose) / prevClose * 100, 2) : 0.0;
      final changeAmt = _round(cur - prevClose, 2);

      return {
        'symbol': symbol, 'name': name, 'price': _round(cur, 2),
        'open': _round(_safeDouble(f[5]), 2), 'prev_close': _round(prevClose, 2),
        'high': _round(_safeDouble(f[34]), 2), 'low': _round(_safeDouble(f[35]), 2),
        'change_pct': changePct,
        'change_amt': changeAmt,
        'volume': _safeInt(_safeDouble(f[37])),
        'amount': _safeDouble(f[38]),
        'market_cap': _safeDouble(f[45]) * 1e8,
        'pe_ratio': _safeDouble(f[40]) > 0 ? _round(_safeDouble(f[40]), 2) : null,
        'pb_ratio': null, 'roe': null, 'revenue_growth': null,
        'eps': null,
        'dividend_yield': null,  // 由Yahoo Finance补充
        'turnover_rate': null,  // 美股无直接换手率字段
        'bid1': null, 'bid1_vol': null, 'bid2': null, 'bid2_vol': null,
        'bid3': null, 'bid3_vol': null, 'bid4': null, 'bid4_vol': null,
        'bid5': null, 'bid5_vol': null,
        'ask1': null, 'ask1_vol': null, 'ask2': null, 'ask2_vol': null,
        'ask3': null, 'ask3_vol': null, 'ask4': null, 'ask4_vol': null,
        'ask5': null, 'ask5_vol': null,
        'date': f.length > 31 ? f[31].split(' ')[0].replaceAll('-', '') : '', 'time': f.length > 31 ? (f[31].contains(' ') ? f[31].split(' ')[1] : '') : '',
        'week52_high': _safeDouble(f[49]) > 0 ? _round(_safeDouble(f[49]), 2) : null,
        'week52_low': _safeDouble(f[50]) > 0 ? _round(_safeDouble(f[50]), 2) : null,
        'source': 'qq_us'
      };
    } catch (_) { return null; }
  }

  /// 基金 (UTF-8)
  Future<Map<String, dynamic>?> _fetchFund(String symbol) async {
    final code = symbol.replaceAll('.OF', '');
    try {
      final resp = await _client.get(
        Uri.parse('http://fundgz.1234567.com.cn/js/$code.js')
      ).timeout(const Duration(seconds: _timeoutSeconds));
      if (resp.statusCode != 200) return null;

      final match = RegExp(r'jsonpgz\((.*?)\)').firstMatch(resp.body);
      if (match == null) return null;
      final g1 = match.group(1);
      if (g1 == null) return null;
      final raw = json.decode(g1);
      final d = raw is Map<String, dynamic> ? raw : <String, dynamic>{};

      final dwjz = _safeDouble(d['dwjz']);
      final gsz = _safeDouble(d['gsz']);
      final gszzl = _safeDouble(d['gszzl']);
      final price = gsz > 0 ? gsz : dwjz;
      if (price <= 0) return null;

      return {
        'symbol': symbol, 'name': d['name'] ?? '基金$code',
        'price': _round(price, 4), 'change_pct': _round(gszzl, 2),
        'open': null, 'prev_close': dwjz > 0 ? _round(dwjz, 4) : null,
        'high': null, 'low': null, 'change_amt': null,
        'volume': 0, 'amount': 0,
        'market_cap': 0, 'pe_ratio': null, 'pb_ratio': null,
        'roe': null, 'revenue_growth': null, 'eps': null,
        'dividend_yield': null, 'turnover_rate': null,
        'week52_high': null, 'week52_low': null,
        'bid1': null, 'bid1_vol': null, 'bid2': null, 'bid2_vol': null,
        'bid3': null, 'bid3_vol': null, 'bid4': null, 'bid4_vol': null,
        'bid5': null, 'bid5_vol': null,
        'ask1': null, 'ask1_vol': null, 'ask2': null, 'ask2_vol': null,
        'ask3': null, 'ask3_vol': null, 'ask4': null, 'ask4_vol': null,
        'ask5': null, 'ask5_vol': null,
        'date': d['gztime'] ?? '', 'time': '',
        'source': 'fund_eastmoney', 'type': 'fund',
        'nav': dwjz, 'estimated_nav': gsz
      };
    } catch (_) { return null; }
  }

  // ============================================================
  // 机构/基金持仓 - 东方财富F10接口 (仅A股)
  // ============================================================

  /// 获取十大流通股东 + 基金持仓 + 机构持仓数据
  Future<Map<String, dynamic>?> _fetchHolderData(String symbol) async {
    final parts = symbol.split('.');
    final code = parts[0];
    final exch = parts.length > 1 ? parts[1] : 'SS';
    final prefix = exch == 'SS' ? 'SH' : 'SZ';
    final f10Code = '$prefix$code';

    try {
      final resp = await _client.get(
        Uri.parse('https://emweb.securities.eastmoney.com/PC_HSF10/ShareholderResearch/PageAjax?code=$f10Code'),
        headers: {'Referer': 'https://emweb.securities.eastmoney.com', 'User-Agent': 'Mozilla/5.0 (Linux; Android 12)'}
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200 || resp.body.isEmpty) return null;
      final raw = json.decode(resp.body);
      if (raw is! Map<String, dynamic>) return null;

      // 解析十大流通股东
      final topHolders = <Map<String, dynamic>>[];
      final sdltgd = raw['sdltgd'];
      if (sdltgd is List) {
        for (final h in sdltgd.take(10)) {
          if (h is Map<String, dynamic>) {
            topHolders.add({
              'name': h['HOLDER_NAME'] ?? '',
              'type': h['HOLDER_TYPE'] ?? '',
              'hold_num': _safeDouble(h['HOLD_NUM']),
              'hold_pct': _safeDouble(h['FREE_HOLDNUM_RATIO']),
              'change_pct': _safeDouble(h['CHANGE_RATIO']),
              'date': (h['END_DATE'] ?? '').toString().substring(0, 10),
            });
          }
        }
      }

      // 解析基金持仓
      final fundHolders = <Map<String, dynamic>>[];
      final jjcg = raw['jjcg'];
      if (jjcg is List) {
        for (final h in jjcg.take(10)) {
          if (h is Map<String, dynamic>) {
            fundHolders.add({
              'name': h['HOLDER_NAME'] ?? '',
              'code': h['FUND_CODE'] ?? '',
              'shares': _safeDouble(h['FREE_SHARES']),
              'pct': _safeDouble(h['FREESHARES_RATIO']),
              'netval_pct': _safeDouble(h['NETVALUE_RATIO']),
              'date': (h['REPORT_DATE'] ?? '').toString().substring(0, 10),
            });
          }
        }
      }

      // 解析机构汇总
      final jgcc = raw['jgcc'];
      Map<String, dynamic>? instSummary;
      if (jgcc is List && jgcc.isNotEmpty && jgcc[0] is Map<String, dynamic>) {
        final j = jgcc[0];
        instSummary = {
          'org_num': _safeDouble(j['TOTAL_ORG_NUM']),
          'total_shares': _safeDouble(j['TOTAL_FREE_SHARES']),
          'total_pct': _safeDouble(j['TOTAL_SHARES_RATIO']),
          'date': (j['REPORT_DATE'] ?? '').toString().substring(0, 10),
        };
      }

      // 解析历史增减持变动（sdgdcgbd）
      final changeHistory = <Map<String, dynamic>>[];
      final sdgdcgbd = raw['sdgdcgbd'];
      if (sdgdcgbd is List) {
        for (final h in sdgdcgbd) {
          if (h is Map<String, dynamic>) {
            changeHistory.add({
              'name': h['HOLDER_NAME'] ?? '',
              'date': (h['END_DATE'] ?? '').toString().substring(0, 10),
              'hold_num': _safeDouble(h['HOLD_NUM']),
              'hold_pct': _safeDouble(h['HOLD_NUM_RATIO']),
              'change_num': _safeDouble(h['HOLD_CHANGE']),
              'change_pct': _safeDouble(h['CHANGE_RATIO']),
              'reason': h['CHANGE_REASON'] ?? '',
            });
          }
        }
      }

      if (topHolders.isEmpty && fundHolders.isEmpty) return null;

      return {
        'top_holders': topHolders,
        'fund_holders': fundHolders,
        'inst_summary': instSummary,
        'change_history': changeHistory,
      };
    } catch (_) { return null; }
  }

  /// 带重试的财务数据获取（最多2次，超时12秒）
  /// 解决设备上偶尔超时导致ROE等关键字段缺失的问题
  Future<Map<String, dynamic>?> _fetchFinancialDataWithRetry(String symbol) async {
    // 第一次尝试
    var result = await _fetchFinancialData(symbol);
    if (result != null && result['roe'] != null) return result;
    
    // ROE为空时重试一次（可能是临时网络波动）
    print('财务数据首次获取ROE为空，重试中... symbol=$symbol');
    await Future.delayed(const Duration(milliseconds: 500));
    result = await _fetchFinancialData(symbol);
    if (result != null) {
      print('财务数据重试成功: roe=${result['roe']}, revenue_growth=${result['revenue_growth']}');
    } else {
      print('财务数据重试仍失败: symbol=$symbol');
    }
    return result;
  }

  /// 获取A股财务指标(ROE/PB/EPS/营收增速/股息率) - 东方财富F10数据
  Future<Map<String, dynamic>?> _fetchFinancialData(String symbol) async {
    final parts = symbol.split('.');
    final code = parts[0];
    final exch = parts.length > 1 ? parts[1] : 'SS';
    final prefix = exch == 'SS' ? 'SH' : 'SZ';
    final f10Code = '$prefix$code';

    try {
      final resp = await _client.get(
        Uri.parse('https://datacenter.eastmoney.com/securities/api/data/get?type=RPT_F10_FINANCE_MAINFINADATA&sty=SECURITY_CODE,ROEJQ,BPS,EPSJB,TOTALOPERATEREVETZ,PARENTNETPROFITTZ,XSMLL,ZCFZL&filter=(SECURITY_CODE=%22$code%22)&p=1&ps=1&sr=-1&st=REPORT_DATE&source=HSF10&client=PC'),
        headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 12)'}
      ).timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200 || resp.body.isEmpty) return null;
      final raw = json.decode(resp.body);
      if (raw is! Map<String, dynamic>) return null;
      if (raw['success'] != true) return null;

      final result = raw['result'];
      if (result is! Map<String, dynamic>) return null;
      final data = result['data'];
      if (data is! List || data.isEmpty) return null;

      final item = data[0] as Map<String, dynamic>;

      // ROEJQ: 加权ROE(%), BPS: 每股净资产(元), EPSJB: 基本每股收益
      // TOTALOPERATEREVETZ: 营收同比增速(%), PARENTNETPROFITTZ: 净利润增速(%)
      // XSMLL: 销售毛利率(%), ZCFZL: 资产负债率(%)
      final roeJq = _safeDouble(item['ROEJQ']);
      final bps = _safeDouble(item['BPS']);
      final epsJb = _safeDouble(item['EPSJB']);
      final revGrowth = _safeDouble(item['TOTALOPERATEREVETZ']);
      final netProfitGrowth = _safeDouble(item['PARENTNETPROFITTZ']);
      final grossMargin = _safeDouble(item['XSMLL']);
      final debtRatio = _safeDouble(item['ZCFZL']);

      // 所有百分比字段保持原始百分比值（如15.23表示15.23%）
      // BPS是每股净资产，不是PB；PB需要从价格/BPS计算，但此处无价格，留给调用方补全
      // 注意：该API不支持股息率(GXDLL)字段，股息率需通过其他API获取
      return {
        'roe': roeJq != 0 ? roeJq : null,  // 百分比(如32.53或-5.12)，0可能是无数据
        'bps': bps > 0 ? bps : null,       // 每股净资产(元)
        'eps': epsJb != 0 ? epsJb : null,
        'revenue_growth': revGrowth != 0 ? revGrowth : null,  // 百分比
        'net_profit_growth': netProfitGrowth != 0 ? netProfitGrowth : null,  // 百分比
        'gross_margin': grossMargin != 0 ? grossMargin : null,  // 百分比
        'debt_ratio': debtRatio != 0 ? debtRatio : null,  // 百分比
      };
    } catch (_) { return null; }
  }

  /// 获取A股最新股息率（百分比，如3.5表示3.5%）
  /// 使用东方财富分红融资API，汇总最近12个月每股派息 / 当前股价
  Future<double?> _fetchDividendYield(String symbol, double currentPrice) async {
    if (currentPrice <= 0) return null;
    final parts = symbol.split('.');
    final code = parts[0];
    final market = symbol.contains('.SS') ? 'SH' : 'SZ';
    try {
      final resp = await _client.get(
        Uri.parse('https://emweb.securities.eastmoney.com/PC_HSF10/BonusFinancing/PageAjax?code=$market$code'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 12)',
          'Referer': 'https://emweb.securities.eastmoney.com/',
        }
      ).timeout(const Duration(seconds: 5));

      if (resp.statusCode != 200 || resp.body.isEmpty) return null;
      final raw = json.decode(resp.body);
      if (raw is! Map<String, dynamic>) return null;

      final fhyx = raw['fhyx'];
      if (fhyx is! List || fhyx.isEmpty) return null;

      // 汇总最近12个月的每股派息
      final now = DateTime.now();
      final oneYearAgo = now.subtract(const Duration(days: 365));
      double totalDps = 0;

      for (final item in fhyx) {
        if (item is! Map<String, dynamic>) continue;
        final profile = item['IMPL_PLAN_PROFILE']?.toString() ?? '';
        final noticeDateStr = item['NOTICE_DATE']?.toString() ?? '';
        final progress = item['ASSIGN_PROGRESS']?.toString() ?? '';

        // 只统计"实施方案"的分红
        if (!progress.contains('实施')) continue;

        // 解析日期
        DateTime? noticeDate;
        try {
          noticeDate = DateTime.parse(noticeDateStr.substring(0, 10));
        } catch (_) { continue; }

        if (noticeDate.isBefore(oneYearAgo)) break; // 按日期倒序，超过一年就停

        // 解析"10派X元"格式
        final match = RegExp(r'10派([\d.]+)元').firstMatch(profile);
        if (match != null) {
          totalDps += _safeDouble(match.group(1)) / 10; // 转换为每股派息
        }
      }

      if (totalDps <= 0) return null;

      // 股息率 = 每股年派息 / 当前股价 × 100
      final dividendYield = totalDps / currentPrice * 100;
      return _round(dividendYield, 2);
    } catch (_) { return null; }
  }

  /// 获取A股企业真实信息（公司概况）
  /// 使用东方财富F10公司概况接口
  Future<Map<String, dynamic>?> _fetchCompanyProfileData(String symbol) async {
    final parts = symbol.split('.');
    final code = parts[0];
    final exch = parts.length > 1 ? parts[1] : 'SS';
    final prefix = exch == 'SS' ? 'SH' : 'SZ';
    final f10Code = '$prefix$code';

    try {
      final resp = await _client.get(
        Uri.parse('https://emweb.eastmoney.com/PC_HSF10/CompanySurvey/PageAjax?code=$f10Code'),
        headers: {'Referer': 'https://emweb.eastmoney.com', 'User-Agent': 'Mozilla/5.0 (Linux; Android 12)'}
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200 || resp.body.isEmpty) return null;
      final raw = json.decode(resp.body);
      if (raw is! Map<String, dynamic>) return null;

      final result = <String, dynamic>{};

      // 新版API: jbzl (基本资料) 包含公司概况核心字段
      if (raw['jbzl'] is List && (raw['jbzl'] as List).isNotEmpty) {
        final jbzl = (raw['jbzl'] as List)[0] as Map<String, dynamic>?;
        if (jbzl != null) {
          result['company_desc'] = jbzl['ORG_PROFILE']?.toString() ?? '';
          result['legal_representative'] = jbzl['LEGAL_PERSON']?.toString() ?? '';
          if (jbzl['REG_CAPITAL'] != null) {
            final cap = double.tryParse(jbzl['REG_CAPITAL'].toString()) ?? 0;
            result['registered_capital'] = cap > 0 ? '${(cap / 10000).toStringAsFixed(2)}万元' : '';
          }
          final empRaw = jbzl['EMP_NUM']?.toString() ?? '';
          result['employees'] = empRaw.isNotEmpty && empRaw != 'null' ? empRaw : '';
          result['province'] = jbzl['PROVINCE']?.toString() ?? '';
          result['business_scope'] = jbzl['BUSINESS_SCOPE']?.toString() ?? '';
          // 行业: 优先 EM2016(申万), 其次 INDUSTRYCSRC1(证监会)
          final emIndustry = jbzl['EM2016']?.toString() ?? '';
          result['industry'] = emIndustry.isNotEmpty ? emIndustry : (jbzl['INDUSTRYCSRC1']?.toString() ?? '');
          result['website'] = jbzl['ORG_WEB']?.toString() ?? '';
          result['address'] = jbzl['ADDRESS']?.toString() ?? '';
          // 主营及产品
          final scope = jbzl['BUSINESS_SCOPE']?.toString() ?? '';
          if (scope.isNotEmpty) {
            result['main_business'] = scope.length > 150 ? '${scope.substring(0, 150)}...' : scope;
          }
          // 高管
          if ((jbzl['PRESIDENT']?.toString() ?? '').isNotEmpty) {
            result['president'] = jbzl['PRESIDENT']?.toString();
          }
          if ((jbzl['CHAIRMAN']?.toString() ?? '').isNotEmpty) {
            result['chairman'] = jbzl['CHAIRMAN']?.toString();
          }
        }
      }

      // 旧版字段兼容（仍可能出现在某些个股中）
      if (result['company_desc'].toString().isEmpty && raw['gsjj'] is List && (raw['gsjj'] as List).isNotEmpty) {
        final gsjj = (raw['gsjj'] as List)[0] as Map<String, dynamic>?;
        if (gsjj != null) {
          result['company_desc'] = gsjj['GSJJ']?.toString() ?? '';
          result['found_date'] = gsjj['CLSJRQ']?.toString().substring(0, 10) ?? '';
          result['legal_representative'] ??= gsjj['FRDB']?.toString() ?? '';
          result['registered_capital'] ??= gsjj['ZCZB']?.toString() ?? '';
          result['employees'] ??= gsjj['RGXYRS']?.toString() ?? '';
          result['province'] ??= _resolveProvince(gsjj['SSFDDM']?.toString() ?? '');
        }
      }
      if (result['business_scope'].toString().isEmpty && raw['jyfw'] is List && (raw['jyfw'] as List).isNotEmpty) {
        final jyfwItem = (raw['jyfw'] as List)[0];
        if (jyfwItem is Map) {
          result['business_scope'] = (jyfwItem['JYFW'] as String?) ?? '';
        }
      }
      if (raw['zqyw'] is List && (raw['zqyw'] as List).isNotEmpty) {
        final zqyw = (raw['zqyw'] as List)[0] as Map<String, dynamic>?;
        if (zqyw != null) {
          result['main_business'] = zqyw['ZYGC']?.toString() ?? '';
          result['main_product'] = zqyw['ZYCP']?.toString() ?? '';
        }
      }
      if (result['industry'].toString().isEmpty && raw['sshy'] is List && (raw['sshy'] as List).isNotEmpty) {
        final sshyItem = (raw['sshy'] as List)[0];
        if (sshyItem is Map) {
          result['industry'] = (sshyItem['HYMC'] as String?) ?? '';
        }
      }

      // 成立日期 (新版在 fxxg[0].FOUND_DATE)
      if (raw['fxxg'] is List && (raw['fxxg'] as List).isNotEmpty) {
        final fxxg = (raw['fxxg'] as List)[0] as Map<String, dynamic>?;
        if (fxxg != null) {
          final fd = fxxg['FOUND_DATE']?.toString() ?? '';
          result['found_date'] = fd.isNotEmpty ? fd.substring(0, 10) : '';
        }
      }

      return result.isNotEmpty ? result : null;
    } catch (e) {
      return null;
    }
  }

  /// 获取企业发展历程信息
  Future<List<Map<String, String>>> _fetchCompanyHistory(String symbol) async {
    final parts = symbol.split('.');
    final code = parts[0];
    final exch = parts.length > 1 ? parts[1] : 'SS';
    final prefix = exch == 'SS' ? 'SH' : 'SZ';
    final f10Code = '$prefix$code';

    try {
      final resp = await _client.get(
        Uri.parse('https://emweb.eastmoney.com/PC_HSF10/HistoryDevelopment/PageAjax?code=$f10Code'),
        headers: {'Referer': 'https://emweb.eastmoney.com', 'User-Agent': 'Mozilla/5.0 (Linux; Android 12)'}
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode != 200 || resp.body.isEmpty) return [];
      final raw = json.decode(resp.body);
      if (raw is! Map<String, dynamic>) return [];

      final history = <Map<String, String>>[];
      final fzls = raw['fzls'];
      if (fzls is List) {
        for (final item in fzls.take(10)) {
          if (item is Map<String, dynamic>) {
            history.add({
              'date': item['FZRQ']?.toString().substring(0, 10) ?? '',
              'event': item['FZNR']?.toString() ?? '',
            });
          }
        }
      }
      return history;
    } catch (_) { return []; }
  }

  // ============================================================
  // 证券资讯新闻 (东方财富)
  // ============================================================

  /// 获取个股相关资讯新闻
  Future<List<Map<String, String>>> fetchStockNews(String symbol, {int count = 8}) async {
    try {
      final code = symbol.split('.')[0];
      // 构建mTypeAndCode格式: 1.XXXX(沪市) 或 0.XXXX(深市/北交所)
      String mTypeAndCode;
      if (code.startsWith('6')) {
        mTypeAndCode = '1.$code';
      } else {
        mTypeAndCode = '0.$code';
      }
      final resp = await _client.get(
        Uri.parse('https://np-listapi.eastmoney.com/comm/wap/getListInfo?client=web&pageSize=$count&type=1&mTypeAndCode=$mTypeAndCode'),
        headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 12)', 'Referer': 'https://so.eastmoney.com/'},
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200 || resp.body.isEmpty) return [];
      final raw = json.decode(resp.body);
      if (raw is! Map<String, dynamic>) return [];
      final data = raw['data'];
      if (data is! Map<String, dynamic>) return [];
      final list = data['list'];
      if (list is! List) return [];

      final news = <Map<String, String>>[];
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final title = (item['Art_Title'] ?? '').toString();
        final source = (item['Art_MediaName'] ?? '').toString();
        final date = (item['Art_ShowTime'] ?? '').toString();
        final url = (item['Art_Url'] ?? '').toString();
        if (title.isNotEmpty) {
          news.add({
            'title': title,
            'content': '',
            'date': date,
            'source': source,
          });
        }
        if (news.length >= count) break;
      }
      return news;
    } catch (_) { return []; }
  }

  // ============================================================
  // 热门板块数据 (A股/港股/美股)
  // ============================================================

  /// 获取3个市场各4个热门板块
  Future<Map<String, List<Map<String, dynamic>>>> fetchHotSectors() async {
    final result = <String, List<Map<String, dynamic>>>{};
    result['A股'] = await _fetchAShareSectors();
    result['港股'] = await _fetchHKSectors();
    result['美股'] = await _fetchUSSectors();
    return result;
  }

  Future<List<Map<String, dynamic>>> _fetchAShareSectors() async {
    // A股4大核心指数：上证指数、深证成指、创业板指、科创50
    // 使用腾讯行情API (qt.gtimg.cn) 获取实时涨跌幅
    final indexCodes = ['sh000001', 'sz399001', 'sz399006', 'sh000688'];
    final indexNames = ['上证指数', '深证成指', '创业板指', '科创50'];
    final codesStr = indexCodes.join(',');
    try {
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$codesStr'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return _defaultASectors();
      final text = await _decodeGbk(resp.bodyBytes);
      final result = <Map<String, dynamic>>[];
      final lines = text.split(';');
      for (int i = 0; i < indexCodes.length; i++) {
        var found = false;
        for (final line in lines) {
          if (line.contains('${indexCodes[i]}=')) {
            final match = RegExp(r'="([^"]*)"').firstMatch(line);
            if (match != null) {
              final val = match.group(1).toString();
              if (val.isEmpty) break;
              final f = val.split('~');
              // f[3]=当前价, f[4]=昨收, f[31]=涨跌额, f[32]=涨跌幅%
              if (f.length > 32) {
                final price = _safeDouble(f[3]);
                final prevClose = _safeDouble(f[4]);
                // 优先使用API返回的涨跌幅百分比(f[32])，否则自己计算
                var chgPct = _safeDouble(f[32]);
                if (chgPct == 0 && price > 0 && prevClose > 0) {
                  chgPct = ((price - prevClose) / prevClose) * 100;
                }
                result.add({'name': indexNames[i], 'change_pct': chgPct, 'code': indexCodes[i], 'market': 'A', 'price': price});
                found = true;
              }
            }
            break;
          }
        }
        if (!found) {
          result.add({'name': indexNames[i], 'change_pct': 0.0, 'code': indexCodes[i], 'market': 'A', 'price': 0.0});
        }
      }
      return result;
    } catch (_) { return _defaultASectors(); }
  }

  List<Map<String, dynamic>> _defaultASectors() {
    return [
      {'name': '上证指数', 'change_pct': 0.0, 'code': 'sh000001', 'market': 'A', 'price': 0.0},
      {'name': '深证成指', 'change_pct': 0.0, 'code': 'sz399001', 'market': 'A', 'price': 0.0},
      {'name': '创业板指', 'change_pct': 0.0, 'code': 'sz399006', 'market': 'A', 'price': 0.0},
      {'name': '科创50', 'change_pct': 0.0, 'code': 'sh000688', 'market': 'A', 'price': 0.0},
    ];
  }

  Future<List<Map<String, dynamic>>> _fetchHKSectors() async {
    final hkCodes = ['r_hkHSI', 'r_hkHSTECH', 'r_hkHSCEI', 'r_hkHSMPI'];
    final hkNames = ['恒生指数', '恒生科技', '恒生国企', '恒生地产'];
    // 板块详情代码用rt_前缀（与_fetchHKSectorStocks的Map key一致）
    final hkSectorCodes = ['rt_hkHSI', 'rt_hkHSTECH', 'rt_hkHSCEI', 'rt_hkHSMPI'];
    try {
      final codes = hkCodes.join(',');
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$codes'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return _defaultHKSectors();
      final text = await _decodeGbk(resp.bodyBytes);
      final result = <Map<String, dynamic>>[];
      final lines = text.split(';');
      for (int i = 0; i < hkCodes.length; i++) {
        var found = false;
        for (final line in lines) {
          if (line.contains('${hkCodes[i]}=')) {
            final match = RegExp(r'="([^"]*)"').firstMatch(line);
            if (match != null) {
              final val = match.group(1).toString();
              if (val.isEmpty) break;
              final f = val.split('~');
              if (f.length > 32) {
                // 直接使用预定义的中文名称，避免显示API返回的数字或代码
                final name = hkNames[i];
                final price = _safeDouble(f[4]);
                final chg = _safeDouble(f[32]);
                result.add({'name': name, 'change_pct': chg, 'code': hkSectorCodes[i], 'market': 'HK', 'price': price});
                found = true;
              }
            }
            break;
          }
        }
        if (!found) {
          result.add({'name': hkNames[i], 'change_pct': 0.0, 'code': hkSectorCodes[i], 'market': 'HK', 'price': 0.0});
        }
      }
      if (result.isEmpty) return _defaultHKSectors();
      return result;
    } catch (_) { return _defaultHKSectors(); }
  }

  List<Map<String, dynamic>> _defaultHKSectors() {
    return [
      {'name': '恒生指数', 'change_pct': 0.0, 'code': 'rt_hkHSI', 'market': 'HK', 'price': 0.0},
      {'name': '恒生科技', 'change_pct': 0.0, 'code': 'rt_hkHSTECH', 'market': 'HK', 'price': 0.0},
      {'name': '恒生国企', 'change_pct': 0.0, 'code': 'rt_hkHSCEI', 'market': 'HK', 'price': 0.0},
      {'name': '恒生地产', 'change_pct': 0.0, 'code': 'rt_hkHSMPI', 'market': 'HK', 'price': 0.0},
    ];
  }

  Future<List<Map<String, dynamic>>> _fetchUSSectors() async {
    final usCodes = ['usIXIC', 'usDJI', 'usSPY', 'usSOXX'];
    final usNames = ['纳斯达克', '道琼斯', '标普500', '费城半导体'];
    try {
      final codes = usCodes.join(',');
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$codes'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return _defaultUSSectors();
      final text = await _decodeGbk(resp.bodyBytes);
      final result = <Map<String, dynamic>>[];
      final lines = text.split(';');
      for (int i = 0; i < usCodes.length; i++) {
        var found = false;
        for (final line in lines) {
          if (line.contains('${usCodes[i]}=')) {
            final match = RegExp(r'="([^"]*)"').firstMatch(line);
            if (match != null) {
              final val = match.group(1).toString();
              if (val.isEmpty) break;
              final f = val.split('~');
              if (f.length > 32) {
                // 直接使用预定义的中文名称，避免显示API返回的数字或代码
                final name = usNames[i];
                final price = _safeDouble(f[4]);
                final chg = _safeDouble(f[32]);
                result.add({'name': name, 'change_pct': chg, 'code': usCodes[i], 'market': 'US', 'price': price});
                found = true;
              }
            }
            break;
          }
        }
        if (!found) {
          result.add({'name': usNames[i], 'change_pct': 0.0, 'code': usCodes[i], 'market': 'US', 'price': 0.0});
        }
      }
      if (result.isEmpty) return _defaultUSSectors();
      return result;
    } catch (_) { return _defaultUSSectors(); }
  }

  List<Map<String, dynamic>> _defaultUSSectors() {
    return [
      {'name': '纳斯达克', 'change_pct': 0.0, 'code': 'usIXIC', 'market': 'US'},
      {'name': '道琼斯', 'change_pct': 0.0, 'code': 'usDJI', 'market': 'US'},
      {'name': '标普500', 'change_pct': 0.0, 'code': 'usSPY', 'market': 'US'},
      {'name': '费城半导体', 'change_pct': 0.0, 'code': 'usSOXX', 'market': 'US'},
    ];
  }

  // ============================================================
  // 市场指数滚动栏 — 8组16个指数
  // ============================================================

  /// 获取市场指数对列表（滚动栏用）
  /// 返回8个IndexPair，每个包含左右两个指数
  /// ★ 全部8组数据均通过腾讯API(qt.gtimg.cn)获取，纯国内通道，无境外依赖
  Future<List<Map<String, dynamic>>> fetchMarketIndexPairs() async {
    final allCodes = [
      'sh000001,sz399001',
      'sz399006,sh000688',
      'r_hkHSI,r_hkHSTECH',
      'r_hkHSCEI,r_hkHSMPI',
      'usIXIC,usSPY',
      'usDJI,usSOXX',
      'hf_GC,hf_CL',            // 纽约黄金 + 纽约原油
      'whUSDX,whUSDCNY',         // 美元指数 + 美元人民币汇率（腾讯外汇wh代码）
    ];
    final allNames = [
      ['上证指数', '深证成指'],
      ['创业板指', '科创50'],
      ['恒生指数', '恒生科技'],
      ['恒生国企', '恒生地产'],
      ['纳斯达克', '标普500'],
      ['道琼斯', '费城半导体'],
      ['黄金指数', '原油指数'],
      ['美元指数', '人民币汇率'],
    ];

    final result = <Map<String, dynamic>>[];

    try {
      // 合并所有腾讯代码一次请求
      final codesStr = allCodes.join(',');
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$codesStr'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        final text = await _decodeGbk(resp.bodyBytes);
        final lines = text.split(';');

        for (int i = 0; i < allCodes.length; i++) {
          final pairCodes = allCodes[i].split(',');
          final pairNames = allNames[i];
          final left = _parseIndexLine(lines, pairCodes[0], pairNames[0]);
          final right = _parseIndexLine(lines, pairCodes[1], pairNames[1]);
          result.add({
            'leftName': left['name'],
            'leftCode': left['code'],
            'leftPrice': left['price'],
            'leftChangePct': left['changePct'],
            'rightName': right['name'],
            'rightCode': right['code'],
            'rightPrice': right['price'],
            'rightChangePct': right['changePct'],
          });
        }
      }
    } catch (_) {
      // 腾讯API失败时用默认值
      for (int i = 0; i < allCodes.length; i++) {
        final pairCodes = allCodes[i].split(',');
        final pairNames = allNames[i];
        result.add({
          'leftName': pairNames[0], 'leftCode': pairCodes[0],
          'leftPrice': 0.0, 'leftChangePct': 0.0,
          'rightName': pairNames[1], 'rightCode': pairCodes[1],
          'rightPrice': 0.0, 'rightChangePct': 0.0,
        });
      }
    }

    return result;
  }

  /// 解析单个指数行（兼容 ~ 分隔的股票格式 和 , 分隔的期货格式）
  Map<String, dynamic> _parseIndexLine(List<String> lines, String code, String fallbackName) {
    try {
      for (final line in lines) {
        if (line.contains('$code=')) {
          final match = RegExp(r'="([^"]*)"').firstMatch(line);
          if (match != null) {
            final val = match.group(1).toString();
            if (val.isEmpty) break;

            // 检测分隔符：股票用~，期货用,
            final useComma = val.contains(',') && !val.contains('~');
            final f = useComma ? val.split(',') : val.split('~');

            if (useComma) {
              // 期货格式（逗号分隔）：f[0]=当前价, f[1]=涨跌额/涨跌幅
              // 实测 hf_GC: 4565.87,0.74,4569.40,4570.10,4627.10,4519.50,04:59:58,4532.40,4527.60,...
              if (f.length >= 8) {
                final price = _safeDouble(f[0]);
                final prevClose = _safeDouble(f[7]);
                final chgPct = (price > 0 && prevClose > 0)
                    ? ((price - prevClose) / prevClose) * 100
                    : _safeDouble(f[1]); // f[1]可能是涨跌幅
                return {
                  'name': fallbackName, 'code': code,
                  'price': price, 'changePct': chgPct,
                };
              } else if (f.length >= 2) {
                return {
                  'name': fallbackName, 'code': code,
                  'price': _safeDouble(f[0]),
                  'changePct': _safeDouble(f[1]),
                };
              }
            } else {
              // 股票/指数/外汇格式（~分隔）
              // ★ 外汇wh格式（whUSDX/whUSDCNY）：约22个字段，f[3]=价格, f[13]=涨跌幅%
              //   股票格式：>32个字段，f[4]=价格, f[32]=涨跌幅%
              if (f.length > 32) {
                // 标准股票/指数格式
                final price = _safeDouble(f.length > 4 ? f[4] : f[3]);
                final chgPct = _safeDouble(f.length > 32 ? f[32] : '0');
                return {
                  'name': fallbackName, 'code': code,
                  'price': price, 'changePct': chgPct,
                };
              } else if (f.length >= 14 && f[0] == '310') {
                // 外汇wh格式：f[0]=310(市场代码), f[3]=当前价, f[13]=涨跌幅%
                return {
                  'name': fallbackName, 'code': code,
                  'price': _safeDouble(f[3]),
                  'changePct': _safeDouble(f[13]),
                };
              } else if (f.length > 3) {
                // 其他短格式fallback
                return {
                  'name': fallbackName, 'code': code,
                  'price': _safeDouble(f[3]),
                  'changePct': f.length > 4 ? _safeDouble(f[4]) : 0.0,
                };
              }
            }
          }
          break;
        }
      }
    } catch (_) {}
    return {
      'name': fallbackName, 'code': code,
      'price': 0.0, 'changePct': 0.0,
    };
  }

  /// 默认市场指数对（离线/失败时使用）
  List<Map<String, dynamic>> _defaultMarketIndexPairs() {
    return [
      {'leftName': '上证指数', 'leftCode': 'sh000001', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '深证成指', 'rightCode': 'sz399001', 'rightPrice': 0.0, 'rightChangePct': 0.0},
      {'leftName': '创业板指', 'leftCode': 'sz399006', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '科创50', 'rightCode': 'sh000688', 'rightPrice': 0.0, 'rightChangePct': 0.0},
      {'leftName': '恒生指数', 'leftCode': 'r_hkHSI', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '恒生科技', 'rightCode': 'r_hkHSTECH', 'rightPrice': 0.0, 'rightChangePct': 0.0},
      {'leftName': '恒生国企', 'leftCode': 'r_hkHSCEI', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '恒生地产', 'rightCode': 'r_hkHSMPI', 'rightPrice': 0.0, 'rightChangePct': 0.0},
      {'leftName': '纳斯达克', 'leftCode': 'usIXIC', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '标普500', 'rightCode': 'usSPY', 'rightPrice': 0.0, 'rightChangePct': 0.0},
      {'leftName': '道琼斯', 'leftCode': 'usDJI', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '费城半导体', 'rightCode': 'usSOXX', 'rightPrice': 0.0, 'rightChangePct': 0.0},
      {'leftName': '黄金指数', 'leftCode': 'hf_GC', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '原油指数', 'rightCode': 'hf_CL', 'rightPrice': 0.0, 'rightChangePct': 0.0},
      {'leftName': '美元指数', 'leftCode': 'whUSDX', 'leftPrice': 0.0, 'leftChangePct': 0.0,
       'rightName': '人民币汇率', 'rightCode': 'whUSDCNY', 'rightPrice': 0.0, 'rightChangePct': 0.0},
    ];
  }

  // ============================================================
  // 指数成分股
  // ============================================================

  /// 获取A股指数成分股列表
  /// 指数代码: sh000001(上证), sz399001(深成指), sz399006(创业板), sh000688(科创50)
  /// 使用东方财富API获取指数成分股 + 腾讯API获取实时行情
  Future<Map<String, dynamic>> getIndexStocks(String indexCode, {int limit = 50}) async {
    try {
      // 使用东方财富API获取指数成分股代码
      final stockCodes = await _fetchIndexComponentCodes(indexCode);
      if (stockCodes.isEmpty) {
        return {'stocks': [], 'total': 0, 'error': '未获取到成分股'};
      }

      // 使用腾讯API批量获取实时行情
      final stocks = await _fetchStocksByCodes(stockCodes, limit: limit);
      
      // 按涨跌幅排序
      stocks.sort((a, b) {
        final changeA = _safeDouble(b['change_pct']);
        final changeB = _safeDouble(a['change_pct']);
        return changeA.compareTo(changeB);
      });

      return {'stocks': stocks, 'total': stocks.length};
    } catch (e) {
      return {'stocks': [], 'total': 0, 'error': e.toString()};
    }
  }

  /// 通过东方财富API获取指数成分股代码
  Future<List<String>> _fetchIndexComponentCodes(String indexCode) async {
    try {
      // 东方财富指数成分股API
      // secid格式: 1.000001(上证) 0.399001(深成指) 0.399006(创业板) 1.000688(科创50)
      String secid;
      switch (indexCode) {
        case 'sh000001': secid = '1.000001'; break;
        case 'sz399001': secid = '0.399001'; break;
        case 'sz399006': secid = '0.399006'; break;
        case 'sh000688': secid = '1.000688'; break;
        default: return [];
      }

      final url = 'https://push2.eastmoney.com/api/qt/clist/get?pn=1&pz=50&po=1&np=1&fltt=2&invt=2&fid=f3&fs=b:$secid+f:!50&fields=f12,f13';
      final resp = await _client.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) return [];

      final data = json.decode(resp.body);
      final diff = data['data']?['diff'] as List<dynamic>? ?? [];
      
      final codes = <String>[];
      for (final item in diff) {
        if (item == null) continue;
        final code = item['f12']?.toString() ?? '';
        if (code.isNotEmpty && code.length == 6) {
          codes.add(code);
        }
      }
      return codes;
    } catch (_) {
      return [];
    }
  }

  // ============================================================
  // 投资月历 - 获取板块股票
  // ============================================================

  /// 获取投资月历板块对应的股票列表
  /// 直接使用预设股票代码批量获取实时行情（最可靠方案）
  Future<Map<String, dynamic>> getSectorStocks({
    required String sectorName,
    required String keywords,
    required List<String> stockCodes,
    int limit = 50,
  }) async {
    try {
      // 1. 直接用预设代码获取实时行情（每个板块预设25只）
      final stocks = await _fetchStocksByCodes(stockCodes, limit: stockCodes.length);
      
      // 2. 按涨跌幅排序（从高到低）
      stocks.sort((a, b) {
        final changeA = _safeDouble(b['change_pct']);
        final changeB = _safeDouble(a['change_pct']);
        return changeA.compareTo(changeB);
      });

      return {
        'stocks': stocks.take(limit).toList(),
        'total': stocks.length,
      };
    } catch (e) {
      return {'stocks': [], 'total': 0, 'error': e.toString()};
    }
  }

  /// 通过关键词搜索A股代码列表（备用）
  Future<List<String>> _searchStockCodesByKeyword(String keyword) async {
    if (keyword.isEmpty) return [];
    
    final codes = <String>[];
    
    try {
      final resp = await _client.get(
        Uri.parse('https://suggest3.sinajs.cn/suggest/type=11&key=${Uri.encodeComponent(keyword)}'),
        headers: {
          'Referer': 'https://finance.sina.com.cn',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        },
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return codes;
      
      final text = await _decodeGbk(resp.bodyBytes);
      
      final match = RegExp(r'"([^"]+)"').firstMatch(text);
      if (match == null) return codes;
      
      final entries = match.group(1)!.split(';');
      
      for (final entry in entries) {
        final parts = entry.split(',');
        if (parts.length >= 3) {
          final type = parts[0];
          final symbol = parts[2];
          
          if ((type == '11' || type == '12') && symbol.length == 6 && 
              (symbol.startsWith('6') || symbol.startsWith('0') || symbol.startsWith('3') || symbol.startsWith('8') || symbol.startsWith('4'))) {
            codes.add(symbol);
          }
        }
      }
    } catch (_) {}
    
    return codes;
  }

  /// 批量获取投资月历所有板块的股票数据（优化版）
  /// 返回 Map<板块名称, 统计数据>
  Future<Map<String, Map<String, dynamic>>> fetchAllCalendarSectors() async {
    final result = <String, Map<String, dynamic>>{};
    
    // 收集所有板块的股票代码（去重）
    final allCodes = <String>{};
    final sectorCodesMap = <String, List<String>>{};
    
    for (final monthData in InvestmentCalendarData.calendarData) {
      for (final sector in monthData.sectors) {
        sectorCodesMap[sector.name] = sector.stockCodes;
        allCodes.addAll(sector.stockCodes);
      }
    }
    
    // 批量获取所有股票的实时行情（去重后的）
    final allStocksData = <String, Map<String, dynamic>>{};
    final codesList = allCodes.toList();
    
    // 分批并发请求（每批20只，共600只需要30批，改为每批50只）
    const batchSize = 50;
    final futures = <Future<void>>[];
    
    for (int i = 0; i < codesList.length; i += batchSize) {
      final end = (i + batchSize > codesList.length) ? codesList.length : i + batchSize;
      final batch = codesList.sublist(i, end);
      
      futures.add(() async {
        final stocks = await _fetchStocksByCodesFast(batch);
        for (final stock in stocks) {
          final symbol = stock['symbol'] as String?;
          if (symbol != null) {
            // 提取纯代码用于匹配
            final pureCode = symbol.split('.').first;
            allStocksData[pureCode] = stock;
          }
        }
      }());
    }
    
    // 等待所有请求完成
    await Future.wait(futures);
    
    // 获取月涨幅数据（东方财富阶段涨幅API）
    final monthChangeMap = await fetchMonthChangePct(codesList);

    // 计算每个板块的统计数据
    for (final monthData in InvestmentCalendarData.calendarData) {
      for (final sector in monthData.sectors) {
        final sectorStocks = <Map<String, dynamic>>[];
        double totalChange = 0;
        double totalMonthChange = 0;
        int upCount = 0;
        int downCount = 0;
        int flatCount = 0;
        int validCount = 0;
        int validMonthCount = 0;
        
        for (final code in sector.stockCodes) {
          final stockData = allStocksData[code];
          if (stockData != null) {
            sectorStocks.add(stockData);
            final change = _safeDouble(stockData['change_pct']);
            totalChange += change;
            validCount++;
            if (change > 0.01) {
              upCount++;
            } else if (change < -0.01) {
              downCount++;
            } else {
              flatCount++;
            }
          }
          // 累加月涨幅
          final mChange = monthChangeMap[code];
          if (mChange != null) {
            totalMonthChange += mChange;
            validMonthCount++;
          }
        }
        
        result[sector.name] = {
          'avgChange': validCount > 0 ? totalChange / validCount : 0.0,
          'avgMonthChange': validMonthCount > 0 ? totalMonthChange / validMonthCount : 0.0,
          'upCount': upCount,
          'downCount': downCount,
          'flatCount': flatCount,
          'total': sector.stockCodes.length,
          'validCount': validCount,
          'stocks': sectorStocks,
          'displayName': sector.displayName,
        };
      }
    }
    
    return result;
  }

  /// 获取股票月涨幅（本月累计涨跌幅）
  /// 使用腾讯财经API的f[63]字段直接获取月涨幅%
  /// 替代原先的东方财富K线API（push2his.eastmoney.com从sandbox不可达）
  Future<Map<String, double>> fetchMonthChangePct(List<String> codes) async {
    final result = <String, double>{};
    if (codes.isEmpty) return result;

    // 将纯6位代码转为腾讯API格式
    final tencentCodes = codes.map((code) {
      final pureCode = code.split('.').first;
      if (pureCode.length == 6) {
        if (pureCode.startsWith('6')) return 'sh$pureCode';
        if (pureCode.startsWith('0') || pureCode.startsWith('3')) return 'sz$pureCode';
        if (pureCode.startsWith('8') || pureCode.startsWith('4')) return 'bj$pureCode';
      }
      return pureCode.toLowerCase();
    }).toList();

    // 分批请求（每批50只）
    const batchSize = 50;
    for (int i = 0; i < tencentCodes.length; i += batchSize) {
      final end = (i + batchSize > tencentCodes.length) ? tencentCodes.length : i + batchSize;
      final batch = tencentCodes.sublist(i, end);
      final query = batch.join(',');

      try {
        final resp = await _client.get(
          Uri.parse('https://qt.gtimg.cn/q=$query'),
          headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
        ).timeout(const Duration(seconds: 10));

        if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) continue;

        final text = await _decodeGbk(resp.bodyBytes);
        final lines = text.split(';');

        for (final line in lines) {
          if (line.trim().isEmpty) continue;

          final lineMatch = RegExp(r'v_([a-z]+)(\d{6})="([^"]*)"').firstMatch(line);
          if (lineMatch != null) {
            final codeNum = lineMatch.group(2) ?? '';
            final data = lineMatch.group(3) ?? '';
            if (data.isEmpty) continue;

            final f = data.split('~');
            if (f.length > 63) {
              final monthChange = _safeDouble(f[63]);
              if (monthChange != 0) {
                result[codeNum] = _round(monthChange, 2);
              }
            }
          }
        }
      } catch (_) {
        // 静默失败，继续下一批
      }
    }

    return result;
  }

  /// 快速获取股票数据（用于批量获取，不限制数量）
  Future<List<Map<String, dynamic>>> _fetchStocksByCodesFast(List<String> codes) async {
    if (codes.isEmpty) return [];
    
    final result = <Map<String, dynamic>>[];
    
    // 转换为腾讯API格式
    final tencentCodes = codes.map((code) {
      if (code.endsWith('.SS')) return 'sh${code.replaceAll('.SS', '')}';
      if (code.endsWith('.SZ')) return 'sz${code.replaceAll('.SZ', '')}';
      if (code.endsWith('.BJ')) return 'bj${code.replaceAll('.BJ', '')}';
      if (code.length == 6) {
        if (code.startsWith('6')) return 'sh$code';
        if (code.startsWith('0') || code.startsWith('3')) return 'sz$code';
        if (code.startsWith('8') || code.startsWith('4')) return 'bj$code';
      }
      return code.toLowerCase();
    }).toList();

    try {
      final query = tencentCodes.join(',');
      
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$query'),
        headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return result;
      
      final text = await _decodeGbk(resp.bodyBytes);
      
      // 解析响应，支持两种格式：v_sh600519=... 或 sh600519=...
      final lines = text.split(';');
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        
        var lineMatch = RegExp(r'v_([a-z]+)(\d{6})="([^"]*)"').firstMatch(line);
        if (lineMatch == null) {
          lineMatch = RegExp(r'([a-z]+)(\d{6})="([^"]*)"').firstMatch(line);
        }
        
        if (lineMatch != null) {
          final market = lineMatch.group(1);
          final codeNum = lineMatch.group(2);
          final data = lineMatch.group(3);
          
          if (data == null || data.isEmpty) continue;
          
          final f = data.split('~');
          if (f.length > 35) {
            final symbol = '$codeNum.${market?.toUpperCase() == 'SH' ? 'SS' : market?.toUpperCase()}';
            
            result.add({
              'symbol': symbol,
              'name': f[1],
              'price': _safeDouble(f[3]),
              'change_pct': _safeDouble(f[32]),
              'change_amt': _safeDouble(f[31]),
              'volume': _safeInt(f[36]),
              'market_cap': _safeDouble(f[44]),
              'high': _safeDouble(f[33]),
              'low': _safeDouble(f[34]),
              'open': _safeDouble(f[5]),
              'prev_close': _safeDouble(f[4]),
              // f[63]=月涨幅%  f[62]=周涨幅%  f[64]=季涨幅%
              'month_change_pct': f.length > 63 ? _safeDouble(f[63]) : 0.0,
            });
          }
        }
      }
    } catch (e) {
      // 静默失败
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> _fetchStocksByCodes(List<String> codes, {int limit = 20}) async {
    if (codes.isEmpty) return [];
    
    final result = <Map<String, dynamic>>[];
    
    // 转换为腾讯API格式: 600519.SS -> sh600519, 000001.SZ -> sz000001
    final tencentCodes = codes.take(limit).map((code) {
      if (code.endsWith('.SS')) return 'sh${code.replaceAll('.SS', '')}';
      if (code.endsWith('.SZ')) return 'sz${code.replaceAll('.SZ', '')}';
      if (code.endsWith('.BJ')) return 'bj${code.replaceAll('.BJ', '')}';
      // 纯数字代码判断
      if (code.length == 6) {
        if (code.startsWith('6')) return 'sh$code';
        if (code.startsWith('0') || code.startsWith('3')) return 'sz$code';
        if (code.startsWith('8') || code.startsWith('4')) return 'bj$code';
      }
      return code.toLowerCase();
    }).toList();

    try {
      // 腾讯API每次最多支持60个代码，这里分批次
      for (int i = 0; i < tencentCodes.length; i += 20) {
        final batch = tencentCodes.sublist(i, min(i + 20, tencentCodes.length));
        final query = batch.join(',');
        
        final resp = await _client.get(
          Uri.parse('https://qt.gtimg.cn/q=$query'),
          headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
        ).timeout(const Duration(seconds: 10));

        if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) continue;
        
        // 腾讯API使用GBK编码
        final text = await _decodeGbk(resp.bodyBytes);
        
        // 解析响应，格式: v_sh600519="1~贵州茅台~600519~..." 或 sh600519="..."
        final lines = text.split(';');
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          
          // 尝试两种格式：v_sh600519=... 或 sh600519=...
          var lineMatch = RegExp(r'v_([a-z]+)(\d{6})="([^"]*)"').firstMatch(line);
          if (lineMatch == null) {
            lineMatch = RegExp(r'([a-z]+)(\d{6})="([^"]*)"').firstMatch(line);
          }
          
          if (lineMatch != null) {
            final market = lineMatch.group(1); // sh, sz, bj
            final codeNum = lineMatch.group(2); // 600519
            final data = lineMatch.group(3); // 数据部分
            
            if (data == null || data.isEmpty) continue;
            
            final f = data.split('~');
            if (f.length > 35) {
              // 转换为标准格式
              final symbol = '$codeNum.${market?.toUpperCase() == 'SH' ? 'SS' : market?.toUpperCase()}';
              
              result.add({
                'symbol': symbol,
                'name': f[1],                    // 股票名称
                'price': _safeDouble(f[3]),      // 当前价格
                'change_pct': _safeDouble(f[32]), // 涨跌幅%
                'change_amt': _safeDouble(f[31]), // 涨跌额
                'volume': _safeInt(f[36]),       // 成交量(手)
                'market_cap': _safeDouble(f[44]), // 市值
                'high': _safeDouble(f[33]),      // 最高价
                'low': _safeDouble(f[34]),       // 最低价
                'open': _safeDouble(f[5]),       // 开盘价
                'prev_close': _safeDouble(f[4]), // 昨收
                // f[63]=月涨幅%  f[62]=周涨幅%  f[64]=季涨幅%
                'month_change_pct': f.length > 63 ? _safeDouble(f[63]) : 0.0,
              });
            }
          }
        }
      }
    } catch (e) {
      print('_fetchStocksByCodes error: $e');
    }
    return result;
  }

  /// 获取板块内前20个股
  Future<List<Map<String, dynamic>>> fetchSectorStocks(String sectorCode, String market) async {
    // 指数代码 -> 预设成分股代码 + 腾讯API获取实时行情
    if (market == 'A') {
      final componentCodes = _indexToComponentCodes(sectorCode);
      if (componentCodes.isNotEmpty) {
        final stocks = await _fetchStocksByCodes(componentCodes, limit: 50);
        // 按涨跌幅排序
        stocks.sort((a, b) {
          final changeA = _safeDouble(b['change_pct']);
          final changeB = _safeDouble(a['change_pct']);
          return changeA.compareTo(changeB);
        });
        return stocks;
      }
      return _fetchASectorStocks(sectorCode);
    }
    if (market == 'HK') return _fetchHKSectorStocks(sectorCode);
    return _fetchUSSectorStocks(sectorCode);
  }

  /// 指数代码 -> 成分股代码列表映射（按权重/市值排序的前50只）
  static const Map<String, List<String>> _indexComponentCodes = {
    'sh000001': [ // 上证指数 - 沪市主板权重股（60/601/603/605开头）
      '600519','601398','601857','600036','601288','601318','600900','601088',
      '601628','600276','600309','600887','601012','600000','601166','601899',
      '600028','601668','601939','601328','600030','600048','601601','601186',
      '600585','601989','600031','600016','601818','600919','601211','601688',
      '600941','601225','600809','601056','600690','600018','601138','600104',
      '601669','601088','600196','601236','600346','601689','603259','601985',
      '600438','601009',
    ],
    'sz399001': [ // 深证成指 - 深市权重股（000/001/002开头）
      '000858','000333','002594','000725','000001','002415','000568','002142',
      '000002','002352','000063','002230','000538','002271','000661','002311',
      '002460','002475','002001','002007','002024','002120','002236','000425',
      '002241','002304','000768','002179','000895','002493','002916','000617',
      '002555','000338','002466','002709','000596','002032','000625','002470',
      '000100','002129','002371','002607','000786','002153','002049','000301',
      '002008','000977',
    ],
    'sz399006': [ // 创业板指 - 创业板权重股（300开头）
      '300750','300059','300760','300124','300274','300122','300015','300014',
      '300033','300408','300347','300896','300999','300413','300003','300285',
      '300073','300316','300751','300724','300763','300820','300601','300433',
      '300498','300136','300142','300207','300308','300009','300252','300088',
      '300070','300113','300383','300146','300344','300450','300454','300496',
      '300502','300529','300602','300628','300661','300682','300699','300725',
      '300782','300850',
    ],
    'sh000688': [ // 科创50 - 科创板权重股（688开头）
      '688981','688041','688012','688008','688036','688599','688111','688169',
      '688271','688396','688063','688561','688180','688303','688114','688019',
      '688202','688223','688363','688009','688126','688005','688185','688256',
      '688200','688066','688002','688088','688099','688122','688187','688188',
      '688220','688256','688317','688330','688333','688345','688368','688392',
      '688422','688433','688466','688506','688516','688521','688536','688551',
      '688566','688568',
    ],
  };

  /// 指数代码 -> 成分股代码列表
  static List<String> _indexToComponentCodes(String indexCode) {
    return _indexComponentCodes[indexCode] ?? [];
  }

  Future<List<Map<String, dynamic>>> _fetchASectorStocks(String node, {int num = 20}) async {
    try {
      final resp = await _client.get(
        Uri.parse('https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/Market_Center.getHQNodeData?page=1&num=$num&sort=changepercent&asc=0&node=$node'),
        headers: {'Referer': 'https://finance.sina.com.cn', 'User-Agent': 'Mozilla/5.0 (Linux; Android 12)'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.body.isEmpty) return [];
      final data = json.decode(resp.body) as List;
      return data.map((s) {
        final sm = s as Map<String, dynamic>;
        final sym = sm['symbol']?.toString() ?? '';
        final code = sym.replaceAll('sh', '').replaceAll('sz', '');
        final prefix = sym.startsWith('sh') ? 'SH' : 'SZ';
        return {
          'rank': 0,
          'name': sm['name']?.toString() ?? '',
          'code': '$code.$prefix',
          'raw_code': sym,
          'price': _safeDouble(sm['trade']),
          'change_pct': _safeDouble(sm['changepercent']),
          'volume': _safeDouble(sm['volume']),
        };
      }).toList();
    } catch (_) { return []; }
  }

  Future<List<Map<String, dynamic>>> _fetchHKSectorStocks(String sectorCode) async {
    // 港股代码-中文名称映射表 (扩展到200只热门股)
    final hkStockNames = <String, String>{
      // 科技互联网
      '00700': '腾讯控股', '09988': '阿里巴巴', '09618': '京东集团', '03690': '美团', '01810': '小米集团',
      '09999': '网易', '09888': '百度集团', '02498': '快手', '09992': '泡泡玛特', '09961': '携程集团',
      '02015': '理想汽车', '09868': '小鹏汽车', '09866': '蔚来', '01161': '中通快递', '02608': '金山软件',
      '03888': '金山云', '00268': '金蝶国际', '06060': '众安在线', '01833': '平安好医生', '02382': '舜宇光学',
      '01357': '美图公司', '02018': '瑞声科技', '00772': '阅文集团', '03013': 'KEEP', '09626': '哔哩哔哩',
      // 金融银行
      '01299': '友邦保险', '02318': '中国平安', '03988': '中国银行', '00939': '建设银行', '01288': '农业银行',
      '02628': '中国人寿', '01398': '工商银行', '03968': '招商银行', '00005': '汇丰控股', '02388': '中银香港',
      '01141': '恒生银行', '02601': '中国太保', '01238': '广发证券', '06030': '中信证券', '06837': '海通证券',
      '03908': '中金公司', '06886': '港交所', '01658': '邮储银行', '01988': '民生银行', '03328': '交通银行',
      // 地产基建
      '00001': '长和', '00006': '电能实业', '00016': '新鸿基地产', '00017': '新世界发展', '00083': '信和置业',
      '00101': '恒隆地产', '00123': '越秀地产', '00688': '中国海外', '01109': '华润置地', '02007': '碧桂园',
      '01918': '融创中国', '02669': '中海物业', '03333': '中国恒大', '00817': '中国建筑国际', '01776': '天虹纺织',
      '01234': '亚太地产', '02868': '首创置业', '00207': '侨鑫集团', '00059': '天伦燃气',
      // 消费医药
      '01698': '华润啤酒', '02423': '达利食品', '02313': '申洲国际', '02269': '药明生物', '02359': '药明康德',
      '01093': '石药集团', '02202': '万科企业', '01359': '信达生物', '01177': '中国黄金', '01203': '晨鸣纸业',
      '00832': '中建投', '00124': '越秀交通', '01157': '中联重科',
      // 能源资源
      '00941': '中国移动', '00857': '中国石油', '00883': '中国海洋石油', '01898': '中煤能源', '03883': '中海油田',
      '01088': '中国神华', '00386': '中国石油化工', '00669': '中国电信', '00762': '中国联通',
      // 其他热门
      '09922': '康方生物', '03692': '联想集团', '00241': '阿里健康', '03969': '中国燃气', '01024': '快手',
      '06618': '京东健康', '02096': '复星医药', '01011': '中粮控股', '00868': '信义玻璃',
    };
    // 根据板块代码选择对应行业个股 (扩展到40只)
    final hkSectorStocks = <String, List<String>>{
      'rt_hkHSI': ['00700','01299','00941','03988','00005','02318','01288','00001','00939','02388','09988','09618','03690','01810','02015','02628','02313','02269','09888','01161','09999','09961','09992','06030','01141','01698','03968','01398','02608','02498','03888','00268','02382','01833','01109','00688','01088','00883','00857','01898'],
      'rt_hkHSTECH': ['00700','09988','09618','03690','01810','09888','02015','09961','02608','02382','02269','01161','02498','06060','03888','00268','02018','01357','09999','09992','09868','09866','03013','00772','09626','00241','06618','01833','02096','03888','03692','00268','01357','02382','01810','02359','09922','01093','02202','02608'],
      'rt_hkHSCEI': ['00941','00700','02318','03690','09988','09618','01810','00005','01299','03988','01288','02313','02628','00939','02269','02015','09888','01141','02382','02388','03968','01398','03908','06030','06886','01658','01988','03328','01238','06837','02601','01177','01088','00883','00857','01898','03969','03692','03883','00241'],
      'rt_hkHSMPI': ['01109','01234','01776','00688','02007','01238','02868','02669','00817','01177','03883','01203','00832','02423','00083','00123','00059','00124','01157','01918','03333','03883','00207','00006','00016','00017','00101','03969','00868','01011','02096','02313','01698','02423','01109','00688','00001','00005','00941','01898'],
    };
    final list = hkSectorStocks[sectorCode] ?? hkSectorStocks['rt_hkHSTECH']!;
    try {
      final qqCodes = list.map((c) => 'r_hk${c}').join(',');
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$qqCodes'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return [];
      final text = await _decodeGbk(resp.bodyBytes);
      final result = <Map<String, dynamic>>[];
      int rank = 1;
      final lines = text.split(';');
      for (final code in list) {
        var found = false;
        for (final line in lines) {
          if (line.contains('r_hk${code}=')) {
            final match = RegExp(r'="([^"]*)"').firstMatch(line);
            if (match != null) {
              final val = match.group(1).toString();
              if (val.isEmpty) break;
              final f = val.split('~');
              if (f.length > 32) {
                // 优先使用中文映射表，避免显示数字或代码
                final name = hkStockNames[code] ?? (f[2].isNotEmpty ? f[2] : code);
                final price = _safeDouble(f[4]);
                final chg = _safeDouble(f[32]);
                result.add({
                  'rank': rank++,
                  'name': name,
                  'code': '$code.HK',
                  'raw_code': code,
                  'price': price,
                  'change_pct': chg,
                });
                found = true;
              }
            }
            break;
          }
        }
        if (!found && rank <= 20) {
          final name = hkStockNames[code] ?? '--';
          result.add({'rank': rank++, 'name': name, 'code': '$code.HK', 'raw_code': code, 'price': 0.0, 'change_pct': 0.0});
        }
      }
      return result;
    } catch (_) { return []; }
  }

  Future<List<Map<String, dynamic>>> _fetchUSSectorStocks(String sectorCode) async {
    // 美股代码-中文名称映射表 (扩展到200只热门股)
    final usStockNames = <String, String>{
      // 科技巨头
      'AAPL': '苹果公司', 'MSFT': '微软', 'NVDA': '英伟达', 'GOOG': '谷歌', 'GOOGL': '谷歌A',
      'AMZN': '亚马逊', 'META': 'Meta', 'TSLA': '特斯拉', 'AVGO': '博通', 'CRM': '赛富时',
      'AMD': '超微半导体', 'NFLX': '奈飞', 'ADBE': 'Adobe', 'INTC': '英特尔', 'PYPL': 'PayPal',
      // 半导体
      'QCOM': '高通', 'TXN': '德州仪器', 'MU': '美光科技', 'AMAT': '应用材料', 'LRCX': '拉姆研究',
      'KLAC': '科磊', 'MRVL': '迈威尔', 'ON': '安森美', 'SWKS': '思佳讯', 'MPWR': 'Monolithic Power',
      'SNPS': '新思科技', 'CDNS': '铿腾电子', 'ENTG': 'Entegris', 'TER': '泰瑞达', 'ACLX': 'Axcelis',
      'COHR': '相干公司', 'ASML': '阿斯麦', 'ARM': 'ARM控股', 'MCHP': '微芯科技', 'NXPI': '恩智浦',
      // 互联网/软件
      'UBER': 'Uber', 'ABNB': '爱彼迎', 'SNOW': 'Snowflake', 'PLTR': 'Palantir', 'CRWD': 'CrowdStrike',
      'DDOG': 'Datadog', 'ZS': 'Zscaler', 'NET': 'Cloudflare', 'MDB': 'MongoDB', 'TTD': 'The Trade Desk',
      'SHOP': 'Shopify', 'SQ': 'Block', 'COIN': 'Coinbase', 'ROKU': 'Roku', 'SPOT': 'Spotify',
      'PINS': 'Pinterest', 'SNAP': 'Snap', 'RBLX': 'Roblox', 'ZI': 'ZoomInfo', 'DOCU': 'DocuSign',
      // 金融
      'V': 'Visa', 'MA': '万事达', 'JPM': '摩根大通', 'BAC': '美国银行', 'WFC': '富国银行',
      'GS': '高盛', 'MS': '摩根士丹利', 'BLK': '贝莱德', 'SCHW': '嘉信理财', 'C': '花旗集团',
      'AXP': '美国运通', 'USB': '合众银行', 'PNC': 'PNC金融', 'COF': 'Capital One', 'BK': '纽约梅隆',
      'CB': 'Chubb', 'AIG': 'AIG', 'MET': '大都会人寿', 'PRU': '保德信金融', 'ALL': '好事达',
      // 医疗健康
      'UNH': '联合健康', 'LLY': '礼来', 'JNJ': '强生', 'PFE': '辉瑞', 'MRK': '默克',
      'ABBV': '艾伯维', 'MRNA': 'Moderna', 'AMGN': '安进', 'GILD': '吉利德', 'BIIB': '渤健',
      'REGN': '再生元', 'VRTX': '福泰制药', 'ISRG': '直觉外科', 'TMO': '赛默飞', 'ABT': '雅培',
      'DHR': '丹纳赫', 'SYK': '史赛克', 'BSX': '波士顿科学', 'EW': '爱德华兹', 'ZBH': '捷迈邦美',
      // 消费品牌
      'WMT': '沃尔玛', 'COST': '开市客', 'PG': '宝洁', 'KO': '可口可乐', 'PEP': '百事可乐',
      'MCD': '麦当劳', 'SBUX': '星巴克', 'NKE': '耐克', 'HD': '家得宝', 'TGT': '塔吉特',
      'LOW': '劳氏', 'CVS': 'CVS健康', 'EL': '雅诗兰黛', 'CL': '高露洁', 'KMB': '金佰利',
      'GIS': '通用磨坊', 'CLX': '高乐氏', 'MDLZ': '亿滋国际', 'HSY': '好时', 'STZ': '星座品牌',
      // 能源
      'XOM': '埃克森美孚', 'CVX': '雪佛龙', 'COP': '康菲石油', 'SLB': '斯伦贝谢', 'EOG': 'EOG能源',
      'OXY': '西方石油', 'MPC': '马拉松石油', 'VLO': '瓦莱罗', 'WMB': '威廉姆斯', 'OKE': 'ONEOK',
      // 工业
      'CAT': '卡特彼勒', 'BA': '波音', 'GE': '通用电气', 'HON': '霍尼韦尔', 'UNP': '联合太平洋',
      'UPS': 'UPS', 'RTX': '雷神技术', 'LMT': '洛克希德', 'DE': '迪尔', 'MMM': '3M',
      'EMR': '艾默生电气', 'ETN': '伊顿', 'CMI': '康明斯', 'PH': '帕克汉尼汾', 'ITW': '伊利诺伊工具',
      // 通信媒体
      'CMCSA': '康卡斯特', 'VZ': '威瑞森', 'T': 'AT&T', 'TMUS': 'T-Mobile', 'DIS': '迪士尼',
      'WBD': '华纳兄弟', 'PARA': '派拉蒙',
      // 中概股
      'BABA': '阿里巴巴', 'JD': '京东', 'PDD': '拼多多', 'BILI': '哔哩哔哩', 'NTES': '网易',
      'TME': '腾讯音乐', 'BIDU': '百度', 'NIO': '蔚来', 'XPEV': '小鹏汽车', 'LI': '理想汽车',
      'FUTU': '富途', 'TIGR': '老虎证券', 'YMM': '满帮集团', 'DIDI': '滴滴', 'ZLAB': '再鼎医药',
      'BZ': 'Kanzhun', 'TAL': '好未来', 'EDU': '新东方', 'VIPS': '唯品会', 'IQ': '爱奇艺',
      // 其他热门
      'IBM': 'IBM', 'TRV': '旅行者保险', 'DOW': '陶氏化学', 'PM': '菲利普莫里斯', 'MO': '奥驰亚',
      'BRK-B': '伯克希尔B', 'LULU': 'Lululemon', 'ROST': '罗斯百货', 'DLTR': 'Dollar Tree',
      'BKNG': 'Booking', 'MAR': '万豪', 'HLT': '希尔顿', 'RCL': '皇家加勒比', 'CCL': '嘉年华',
      'NCLH': '诺唯真', 'UAL': '联合航空', 'DAL': '达美航空', 'AAL': '美国航空', 'LUV': '西南航空',
      'FDX': '联邦快递', 'NVO': '诺和诺德',
    };
    final usSectorStocks = <String, List<String>>{
      'usIXIC': ['AAPL','MSFT','NVDA','GOOG','GOOGL','AMZN','META','TSLA','AVGO','CRM','AMD','NFLX','ADBE','INTC','PYPL','CMCSA','PEP','COST','TXN','QCOM','BKNG','UBER','ABNB','SNOW','PLTR','CRWD','DDOG','ZS','NET','MDB','SHOP','SQ','COIN','ROKU','SPOT','PINS','SNAP','RBLX','ASML','ARM'],
      'usDJI': ['AAPL','MSFT','UNH','V','JPM','WMT','PG','HD','CVX','MRK','KO','AXP','AMGN','MCD','CAT','IBM','TRV','VZ','BA','DOW','GS','BLK','SCHW','USB','PNC','AMAT','HON','MMM','RTX','LMT','DE','GE','UPS','UNP','CMI','ETN','EMR','PH','ITW','CRM'],
      'usSPY': ['AAPL','MSFT','NVDA','AMZN','GOOG','GOOGL','META','UNH','XOM','JPM','V','LLY','AVGO','PG','MA','COST','HD','ABBV','MRK','PEP','BAC','WMT','CVX','KO','TMO','ABT','DHR','ACGL','SYK','NEE','PM','MO','TGT','LOW','MDLZ','CL','KMB','GIS','EL','HSY','NKE','SBUX','MCD','DIS','NFLX','ADBE','INTC','QCOM','PYPL','CRM'],
      'usSOXX': ['NVDA','AVGO','AMD','INTC','TXN','QCOM','MU','AMAT','LRCX','KLAC','MRVL','ON','SWKS','MPWR','SNPS','CDNS','ENTG','TER','ACLX','COHR','ASML','ARM','MCHP','NXPI','CRWD','ZS','NET','PLTR','SNOW','MDB','ADSK','ANET','FFIV','STX','WDC','KEYS','EXEL','ALGN','FORM','POWI','XLNX'],
    };
    final list = usSectorStocks[sectorCode] ?? usSectorStocks['usIXIC']!;
    try {
      final qqCodes = list.map((c) => 'us${c}').join(',');
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$qqCodes'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return [];
      final text = await _decodeGbk(resp.bodyBytes);
      final result = <Map<String, dynamic>>[];
      int rank = 1;
      final lines = text.split(';');
      for (final code in list) {
        var found = false;
        for (final line in lines) {
          if (line.contains('us${code}=')) {
            final match = RegExp(r'="([^"]*)"').firstMatch(line);
            if (match != null) {
              final val = match.group(1).toString();
              if (val.isEmpty) break;
              final f = val.split('~');
              if (f.length > 32) {
                // 优先使用中文映射表，避免显示数字或代码
                final name = usStockNames[code] ?? (f[2].isNotEmpty ? f[2] : code);
                final price = _safeDouble(f[4]);
                final chg = _safeDouble(f[32]);
                result.add({
                  'rank': rank++,
                  'name': name,
                  'code': '$code.US',
                  'raw_code': code,
                  'price': price,
                  'change_pct': chg,
                });
                found = true;
              }
            }
            break;
          }
        }
        if (!found && rank <= 20) {
          final name = usStockNames[code] ?? '--';
          result.add({'rank': rank++, 'name': name, 'code': '$code.US', 'raw_code': code, 'price': 0.0, 'change_pct': 0.0});
        }
      }
      return result;
    } catch (_) { return []; }
  }

  /// 公开的GBK解码方法（供其他服务调用）
  static Future<String> decodeGbk(List<int> bytes) async => _decodeGbk(bytes);

  static Future<String> _decodeGbk(List<int> bytes) async {
    if (bytes.isEmpty) return '';
    try {
      if (_channelReady) {
        final result = await _codecChannel.invokeMethod<String>('decodeGbk', {'bytes': bytes});
        if (result != null && result.isNotEmpty) return result;
      }
    } catch (_) { _channelReady = false; }
    return GbkDecoder.decode(bytes);
  }

  // ============================================================
  // 八大维度指标分析 - 每项都有独立的AI解读
  // ============================================================

  /// 1. 价格分析
  static Map<String, dynamic> _analyzePrice(Map<String, dynamic> d) {
    final cur = _safeDouble(d['price']);
    final open = _safeDouble(d['open']);
    final prevClose = _safeDouble(d['prev_close']);
    final high = _safeDouble(d['high']);
    final low = _safeDouble(d['low']);
    final cp = _safeDouble(d['change_pct']);

    String sentiment, advice;
    double score;
    if (cp > 3) { sentiment = '强势'; score = 0.85; advice = '股价大幅上涨，短线动能强劲。注意追高风险，建议回踩均线再考虑入场。'; }
    else if (cp > 1) { sentiment = '偏多'; score = 0.65; advice = '股价温和上涨，市场情绪偏乐观。可关注成交量是否配合，量价齐升则趋势更可靠。'; }
    else if (cp > -1) { sentiment = '震荡'; score = 0.50; advice = '股价窄幅波动，多空分歧不大。建议观望等待方向明确，或以网格交易策略应对。'; }
    else if (cp > -3) { sentiment = '偏空'; score = 0.35; advice = '股价下跌，短线偏弱。若在支撑位附近止跌可关注反弹机会，否则建议离场观望。'; }
    else { sentiment = '弱势'; score = 0.15; advice = '股价大幅下跌，市场恐慌情绪较重。不建议抄底，等待放量止跌信号再考虑。'; }

    // 日内振幅
    final range = prevClose > 0 ? (high - low) / prevClose * 100 : 0.0;
    String rangeNote;
    if (range > 5) rangeNote = '日内振幅${_round(range, 1)}%，波动剧烈，短线风险较大';
    else if (range > 2) rangeNote = '日内振幅${_round(range, 1)}%，波动适中，适合波段操作';
    else rangeNote = '日内振幅${_round(range, 1)}%，波动较小，适合持有等待';

    // 开盘vs收盘方向
    String openNote = '';
    if (open > 0 && cur > 0) {
      if (cur > open) openNote = '低开高走，多方占优，盘中表现强势';
      else if (cur < open) openNote = '高开低走，空方施压，盘中表现偏弱';
      else openNote = '开盘价与现价接近，盘中多空均衡';
    }

    return {
      'title': '价格分析',
      'icon': 'price',
      'score': _round(score, 3),
      'sentiment': sentiment,
      'items': {
        '当前价': _fmtPrice(cur),
        '涨跌幅': '${cp >= 0 ? '+' : ''}${_round(cp, 2)}%',
        '涨跌额': '${_safeDouble(d['change_amt']) >= 0 ? '+' : ''}${_fmtPrice(_safeDouble(d['change_amt']))}',
        '开盘价': _fmtPrice(open),
        '昨收价': _fmtPrice(prevClose),
        '最高价': _fmtPrice(high),
        '最低价': _fmtPrice(low),
        '日内振幅': '${_round(range, 2)}%',
      },
      'advice': advice,
      'extra_note': '$rangeNote。$openNote',
    };
  }

  /// 2. 成交量分析
  static Map<String, dynamic> _analyzeVolume(Map<String, dynamic> d) {
    final vol = _safeInt(d['volume']);
    final amount = _safeDouble(d['amount']);
    final cp = _safeDouble(d['change_pct']);

    String sentiment, advice;
    double score;
    if (vol > 0 && cp > 1) { sentiment = '放量上涨'; score = 0.75; advice = '成交量配合上涨，量价齐升是健康的多头信号，说明资金积极入场，短期趋势有望延续。'; }
    else if (vol > 0 && cp < -1) { sentiment = '放量下跌'; score = 0.25; advice = '放量下跌表明抛压沉重，资金在主动撤离。短期不建议接飞刀，等缩量企稳再考虑。'; }
    else if (vol == 0) { sentiment = '无成交'; score = 0.40; advice = '暂无成交数据，可能非交易时段或数据延迟。'; }
    else { sentiment = '缩量整理'; score = 0.50; advice = '成交量一般，市场观望情绪浓厚。缩量整理往往是方向选择的前兆，需等待放量突破信号。'; }

    String amountNote = '';
    if (amount >= 1e8) amountNote = '成交额${_round(amount / 1e8, 1)}亿元，流动性充足';
    else if (amount >= 1e4) amountNote = '成交额${_round(amount / 1e4, 0)}万元';
    else if (amount > 0) amountNote = '成交额较小';

    return {
      'title': '成交量分析',
      'icon': 'volume',
      'score': _round(score, 3),
      'sentiment': sentiment,
      'items': {
        '成交量': _fmtVol(vol),
        '成交额': amount >= 1e8 ? '${_round(amount / 1e8, 1)}亿' : (amount >= 1e4 ? '${_round(amount / 1e4, 0)}万' : _round(amount, 0).toString()),
        '换手率': d['turnover_rate'] != null ? '${_safeDouble(d['turnover_rate'])}%' : '暂无',
      },
      'advice': advice,
      'extra_note': amountNote,
    };
  }

  /// 3. 波动率分析
  static Map<String, dynamic> _analyzeVolatility(Map<String, dynamic> d) {
    final high = _safeDouble(d['high']);
    final low = _safeDouble(d['low']);
    final prevClose = _safeDouble(d['prev_close']);
    final cp = _safeDouble(d['change_pct']);

    final range = prevClose > 0 ? (high - low) / prevClose * 100 : 0.0;
    double score;
    String level, advice;
    if (range > 5) { level = '高波动'; score = 0.30; advice = '日内波动超过5%，市场分歧较大，短线风险显著。高波动适合有经验的交易者做日内波段，但不适合保守型投资者。建议严格设置止损。'; }
    else if (range > 3) { level = '中等波动'; score = 0.55; advice = '日内波动适中，市场参与度尚可。中波动环境适合趋势跟踪策略，可关注均线支撑和压力位突破。'; }
    else if (range > 1) { level = '低波动'; score = 0.65; advice = '日内波动较小，市场处于蓄势状态。低波动后往往伴随方向性突破，可设置提醒关注突破信号。'; }
    else { level = '极低波动'; score = 0.50; advice = '波动率极低，市场几无交易热情。通常预示着即将出现较大行情，但方向不明，建议耐心等待。'; }

    // 52周高低
    final w52h = _safeDouble(d['week52_high']);
    final w52l = _safeDouble(d['week52_low']);
    String w52Note = '';
    if (w52h > 0 && w52l > 0) {
      final cur = _safeDouble(d['price']);
      final posFromLow = (cur - w52l) / (w52h - w52l) * 100;
      w52Note = '当前价格处于52周区间${_round(posFromLow, 0)}%位置（低${_fmtPrice(w52l)}-高${_fmtPrice(w52h)}）';
    }

    return {
      'title': '波动率分析',
      'icon': 'volatility',
      'score': _round(score, 3),
      'sentiment': level,
      'items': {
        '日内振幅': '${_round(range, 2)}%',
        '日内波幅': '${_fmtPrice(high - low)}',
        '波动等级': level,
        if (w52h > 0) '52周最高': _fmtPrice(w52h),
        if (w52l > 0) '52周最低': _fmtPrice(w52l),
      },
      'advice': advice,
      'extra_note': w52Note,
    };
  }

  /// 4. 买卖盘分析
  static Map<String, dynamic> _analyzeBidAsk(Map<String, dynamic> d) {
    final bid1 = _safeDouble(d['bid1']);
    final bid1Vol = _safeInt(d['bid1_vol']);
    final ask1 = _safeDouble(d['ask1']);
    final ask1Vol = _safeInt(d['ask1_vol']);

    double score = 0.50;
    String sentiment = '均衡', advice = '买卖盘数据暂不完整，无法判断短期供需格局。';

    if (bid1 > 0 && ask1 > 0) {
      final spread = ask1 - bid1;
      final bidStrength = bid1Vol;
      final askStrength = ask1Vol;
      final ratio = askStrength > 0 ? bidStrength / askStrength : 1.0;

      if (ratio > 2.0) { sentiment = '买盘强势'; score = 0.75; advice = '买一挂单远大于卖一，买方意愿强烈，短期价格有支撑。但需警惕大单撤单的假象。'; }
      else if (ratio > 1.2) { sentiment = '买盘偏强'; score = 0.62; advice = '买盘略强于卖盘，短期价格下方支撑较好。可关注是否持续有买盘增仓。'; }
      else if (ratio > 0.8) { sentiment = '买卖均衡'; score = 0.50; advice = '买卖盘力量接近，短期价格或将维持窄幅震荡。等待一方力量突破后方向更明确。'; }
      else if (ratio > 0.5) { sentiment = '卖盘偏强'; score = 0.38; advice = '卖盘压力略大，上方抛压明显。短期若无利好刺激，价格上行空间受限。'; }
      else { sentiment = '卖盘强势'; score = 0.25; advice = '卖一挂单远大于买一，抛压沉重，短期价格承压。建议等待卖压消化后再考虑。'; }

      // 价差分析
      final spreadPct = bid1 > 0 ? spread / bid1 * 100 : 0.0;
      String spreadNote;
      if (spreadPct > 0.5) spreadNote = '买卖价差${_round(spreadPct, 2)}%，流动性一般，大单交易需注意冲击成本';
      else if (spreadPct > 0.1) spreadNote = '买卖价差${_round(spreadPct, 2)}%，流动性较好，交易成本可控';
      else spreadNote = '买卖价差极小，流动性优秀，适合短线交易';

      return {
        'title': '买卖盘分析',
        'icon': 'bid_ask',
        'score': _round(score, 3),
        'sentiment': sentiment,
        'items': {
          '买一价/量': '${_fmtPrice(bid1)} / ${_fmtVol(bid1Vol)}',
          '买二价/量': d['bid2'] != null ? '${_fmtPrice(_safeDouble(d['bid2']))} / ${_fmtVol(_safeInt(d['bid2_vol']))}' : '--',
          '买三价/量': d['bid3'] != null ? '${_fmtPrice(_safeDouble(d['bid3']))} / ${_fmtVol(_safeInt(d['bid3_vol']))}' : '--',
          '卖一价/量': '${_fmtPrice(ask1)} / ${_fmtVol(ask1Vol)}',
          '卖二价/量': d['ask2'] != null ? '${_fmtPrice(_safeDouble(d['ask2']))} / ${_fmtVol(_safeInt(d['ask2_vol']))}' : '--',
          '卖三价/量': d['ask3'] != null ? '${_fmtPrice(_safeDouble(d['ask3']))} / ${_fmtVol(_safeInt(d['ask3_vol']))}' : '--',
          '买卖比': _round(ratio, 2).toString(),
          '价差': '${_fmtPrice(spread)} (${_round(spreadPct, 2)}%)',
        },
        'advice': advice,
        'extra_note': spreadNote,
      };
    }

    return {
      'title': '买卖盘分析',
      'icon': 'bid_ask',
      'score': _round(score, 3),
      'sentiment': sentiment,
      'items': {'数据': '该市场暂不提供五档行情'},
      'advice': advice,
      'extra_note': '',
    };
  }

  /// 5. 趋势分析 - 增强版（多维度综合判断）
  static Map<String, dynamic> _analyzeTrend(Map<String, dynamic> d) {
    final cp = _safeDouble(d['change_pct']);
    final cur = _safeDouble(d['price']);
    final open = _safeDouble(d['open']);
    final prevClose = _safeDouble(d['prev_close']);
    final high = _safeDouble(d['high']);
    final low = _safeDouble(d['low']);
    final vol = _safeInt(d['volume']);
    final avgVol = _safeInt(d['avg_volume']); // 5日均量（如有）

    // === 多维度趋势判断 ===
    
    // 1. 日内走势形态
    String intradayPattern = '';
    double intradayScore = 0.50;
    if (open > 0 && prevClose > 0) {
      final gapPct = (open - prevClose) / prevClose * 100;
      final closeVsOpen = (cur - open) / open * 100;
      
      if (gapPct > 1 && closeVsOpen > 0) {
        intradayPattern = '跳空高开后持续上攻，多头强势';
        intradayScore = 0.85;
      } else if (gapPct > 1 && closeVsOpen < 0) {
        intradayPattern = '跳空高开后回落，多头受阻';
        intradayScore = 0.45;
      } else if (gapPct < -1 && closeVsOpen > 0) {
        intradayPattern = '跳空低开后反弹，空头衰竭';
        intradayScore = 0.70;
      } else if (gapPct < -1 && closeVsOpen < 0) {
        intradayPattern = '跳空低开后继续下探，空头强势';
        intradayScore = 0.20;
      } else if (closeVsOpen > 1) {
        intradayPattern = '平开后强势上扬，盘中多头主导';
        intradayScore = 0.75;
      } else if (closeVsOpen < -1) {
        intradayPattern = '平开后走弱，盘中空头主导';
        intradayScore = 0.30;
      } else {
        intradayPattern = '日内震荡运行，方向不明';
        intradayScore = 0.50;
      }
    }

    // 2. 收盘位置分析（收盘价在日内区间的位置）
    double closePosition = 0.50;
    String closeNote = '';
    if (high > low && high > 0) {
      closePosition = (cur - low) / (high - low);
      if (closePosition > 0.85) {
        closeNote = '收盘接近日内高点，多头占据优势';
        closePosition = 0.85;
      } else if (closePosition > 0.65) {
        closeNote = '收盘偏上，多头占优';
      } else if (closePosition < 0.15) {
        closeNote = '收盘接近日内低点，空头占据优势';
        closePosition = 0.15;
      } else if (closePosition < 0.35) {
        closeNote = '收盘偏下，空头占优';
      } else {
        closeNote = '收盘居中，多空拉锯';
      }
    }

    // 3. 量价配合度
    String volumeNote = '';
    double volumeScore = 0.50;
    if (vol > 0) {
      final volRatio = avgVol > 0 ? vol / avgVol : 1.0;
      
      if (cp > 2 && volRatio > 1.5) {
        volumeNote = '放量上涨，资金积极入场，趋势可信度高';
        volumeScore = 0.85;
      } else if (cp > 1 && volRatio > 1.2) {
        volumeNote = '量增价涨，多头有序进攻';
        volumeScore = 0.70;
      } else if (cp > 0 && volRatio < 0.8) {
        volumeNote = '缩量上涨，上涨动能不足，警惕虚假突破';
        volumeScore = 0.40;
      } else if (cp < -2 && volRatio > 1.5) {
        volumeNote = '放量下跌，恐慌抛售，趋势转弱明显';
        volumeScore = 0.20;
      } else if (cp < -1 && volRatio > 1.2) {
        volumeNote = '量增价跌，空头有序撤退';
        volumeScore = 0.35;
      } else if (cp < 0 && volRatio < 0.8) {
        volumeNote = '缩量下跌，抛压减轻，可能接近底部';
        volumeScore = 0.55;
      } else {
        volumeNote = '量价配合一般，趋势待确认';
        volumeScore = 0.50;
      }
    }

    // 4. K线形态分析
    String klineNote = '';
    double klineScore = 0.50;
    if (open > 0 && cur > 0 && high > low) {
      final body = (cur - open).abs();
      final range = high - low;
      final upperShadow = cur > open ? high - cur : high - open;
      final lowerShadow = cur > open ? open - low : cur - low;
      
      if (range > 0) {
        final bodyRatio = body / range;
        
        // 大阳线
        if (cur > open && bodyRatio > 0.7 && upperShadow / range < 0.1) {
          klineNote = '光头大阳线，多头绝对强势，短期有望继续上攻';
          klineScore = 0.90;
        }
        // 大阴线
        else if (cur < open && bodyRatio > 0.7 && lowerShadow / range < 0.1) {
          klineNote = '光头大阴线，空头绝对强势，短期风险较大';
          klineScore = 0.15;
        }
        // 长上影阳线
        else if (cur > open && upperShadow / range > 0.3) {
          klineNote = '长上影阳线，冲高受阻，上方抛压较重';
          klineScore = 0.45;
        }
        // 长下影阴线
        else if (cur < open && lowerShadow / range > 0.3) {
          klineNote = '长下影阴线，探底回升，下方有支撑';
          klineScore = 0.60;
        }
        // 十字星
        else if (bodyRatio < 0.1) {
          klineNote = '十字星形态，多空平衡，需关注次日方向选择';
          klineScore = 0.50;
        }
        // 普通阳线
        else if (cur > open) {
          klineNote = '普通阳线，多头小幅占优';
          klineScore = 0.65;
        }
        // 普通阴线
        else {
          klineNote = '普通阴线，空头小幅占优';
          klineScore = 0.40;
        }
      }
    }

    // === 综合趋势评分 ===
    final trendScore = (intradayScore * 0.30 + closePosition * 0.25 + volumeScore * 0.25 + klineScore * 0.20);
    
    String trend, advice;
    if (trendScore > 0.75) {
      trend = '强势上升';
      advice = '多头趋势明确，各项指标均支持上涨。建议顺势持有，可沿5日均线追踪趋势。若连续3天收盘创新高则趋势进一步确认。';
    } else if (trendScore > 0.60) {
      trend = '偏强运行';
      advice = '短期偏多运行，整体趋势向好。建议关注关键支撑位，跌破则需警惕趋势转折。';
    } else if (trendScore > 0.45) {
      trend = '震荡整理';
      advice = '多空拉锯，方向不明。可在支撑压力区间内高抛低吸，等待突破方向确认。';
    } else if (trendScore > 0.30) {
      trend = '偏弱运行';
      advice = '短期偏弱，空头占优。建议关注下方支撑是否有效，破位需及时止损。';
    } else {
      trend = '弱势下跌';
      advice = '空头趋势明显，不建议逆势操作。等待放量止跌、K线转强信号后再考虑入场。';
    }

    return {
      'title': '趋势分析',
      'icon': 'trend',
      'score': _round(trendScore, 3),
      'sentiment': trend,
      'items': {
        '综合趋势': trend,
        '日内走势': intradayPattern.isNotEmpty ? intradayPattern : '数据不足',
        '收盘位置': closeNote.isNotEmpty ? closeNote : '数据不足',
        '量价配合': volumeNote.isNotEmpty ? volumeNote : '数据不足',
        'K线形态': klineNote.isNotEmpty ? klineNote : '数据不足',
        '趋势强度': trendScore > 0.7 ? '强' : (trendScore > 0.5 ? '中' : '弱'),
      },
      'advice': advice,
      'extra_note': '趋势分析基于日内数据综合判断，历史连续性需多日数据确认。',
    };
  }

  /// 6. 估值分析 - 增强版（多指标综合估值）
  static Map<String, dynamic> _analyzeValuation(Map<String, dynamic> d) {
    final pe = _safeDouble(d['pe_ratio']);
    final pb = _safeDouble(d['pb_ratio']);
    final eps = _safeDouble(d['eps']);
    final roe = _safeDouble(d['roe']);
    final dy = _safeDouble(d['dividend_yield']);
    final mc = _safeDouble(d['market_cap']);
    final revGrowth = _safeDouble(d['revenue_growth']);
    final symbol = d['symbol']?.toString() ?? '';

    // === 多指标综合估值 ===

    // 1. PE估值评分（行业基准对比）
    double peScore = 0.50;
    String peNote = '';
    if (pe > 0) {
      // 根据行业特征调整PE阈值
      bool isBank = symbol.startsWith('601') || symbol.startsWith('6000');
      bool isTech = symbol.startsWith('688') || symbol.startsWith('300');
      
      double lowPE, midPE, highPE;
      if (isBank) { lowPE = 6; midPE = 10; highPE = 15; }
      else if (isTech) { lowPE = 25; midPE = 40; highPE = 60; }
      else { lowPE = 10; midPE = 20; highPE = 35; }
      
      if (pe < lowPE) { peScore = 0.85; peNote = 'PE仅${_round(pe, 1)}倍，显著低于行业均值，可能存在价值洼地'; }
      else if (pe < midPE) { peScore = 0.70; peNote = 'PE为${_round(pe, 1)}倍，处于合理偏低区间'; }
      else if (pe < highPE) { peScore = 0.55; peNote = 'PE为${_round(pe, 1)}倍，处于合理区间'; }
      else if (pe < highPE * 1.5) { peScore = 0.35; peNote = 'PE达${_round(pe, 1)}倍，估值偏高，需高增长支撑'; }
      else { peScore = 0.20; peNote = 'PE高达${_round(pe, 1)}倍，估值明显偏高，风险较大'; }
    }

    // 2. PB估值评分
    double pbScore = 0.50;
    String pbNote = '';
    if (pb > 0) {
      if (pb < 0.8) { pbScore = 0.90; pbNote = 'PB仅${_round(pb, 1)}倍，破净状态，安全边际较高'; }
      else if (pb < 1.0) { pbScore = 0.80; pbNote = 'PB为${_round(pb, 1)}倍，接近破净，估值底部区域'; }
      else if (pb < 2.0) { pbScore = 0.65; pbNote = 'PB为${_round(pb, 1)}倍，估值合理偏低'; }
      else if (pb < 4.0) { pbScore = 0.50; pbNote = 'PB为${_round(pb, 1)}倍，估值处于中等水平'; }
      else if (pb < 8.0) { pbScore = 0.35; pbNote = 'PB为${_round(pb, 1)}倍，估值偏高'; }
      else { pbScore = 0.20; pbNote = 'PB达${_round(pb, 1)}倍，估值过高，需警惕泡沫风险'; }
    }

    // 3. ROE质量评分
    double roeScore = 0.50;
    String roeNote = '';
    if (roe > 0) {
      if (roe > 20) { roeScore = 0.90; roeNote = 'ROE高达${_round(roe, 1)}%，盈利能力极强，属于优质资产'; }
      else if (roe > 15) { roeScore = 0.80; roeNote = 'ROE为${_round(roe, 1)}%，盈利能力优秀'; }
      else if (roe > 10) { roeScore = 0.65; roeNote = 'ROE为${_round(roe, 1)}%，盈利能力良好'; }
      else if (roe > 5) { roeScore = 0.50; roeNote = 'ROE为${_round(roe, 1)}%，盈利能力一般'; }
      else { roeScore = 0.30; roeNote = 'ROE仅${_round(roe, 1)}%，盈利能力偏弱'; }
    }

    // 4. PEG概念（PE/营收增速）
    double pegScore = 0.50;
    String pegNote = '';
    if (pe > 0 && revGrowth != 0) {
      final peg = revGrowth > 0 ? pe / revGrowth : double.infinity;
      if (revGrowth <= 0) {
        pegNote = '营收负增长，PEG无意义，需关注基本面';
        pegScore = 0.25;
      } else if (peg < 0.8) {
        pegNote = 'PEG=${_round(peg, 1)}，明显低估，增速远超估值';
        pegScore = 0.85;
      } else if (peg < 1.2) {
        pegNote = 'PEG=${_round(peg, 1)}，估值与增速匹配';
        pegScore = 0.65;
      } else if (peg < 2.0) {
        pegNote = 'PEG=${_round(peg, 1)}，估值略高于增速';
        pegScore = 0.45;
      } else {
        pegNote = 'PEG=${_round(peg, 1)}，估值远超增速，存在泡沫';
        pegScore = 0.25;
      }
    }

    // 5. 股息率评分
    double dyScore = 0.50;
    String dyNote = '';
    if (dy > 0) {
      if (dy > 5) { dyScore = 0.85; dyNote = '股息率${_round(dy, 2)}%，高股息特征明显，安全边际较高'; }
      else if (dy > 3) { dyScore = 0.70; dyNote = '股息率${_round(dy, 2)}%，分红收益可观'; }
      else if (dy > 1) { dyScore = 0.55; dyNote = '股息率${_round(dy, 2)}%，有一定分红回报'; }
      else { dyScore = 0.40; dyNote = '股息率${_round(dy, 2)}%，分红较少，偏成长型'; }
    }

    // === 综合估值评分（加权） ===
    int validMetrics = 0;
    double totalScore = 0;
    if (pe > 0) { totalScore += peScore * 0.25; validMetrics++; }
    if (pb > 0) { totalScore += pbScore * 0.20; validMetrics++; }
    if (roe > 0) { totalScore += roeScore * 0.25; validMetrics++; }
    if (revGrowth != 0) { totalScore += pegScore * 0.15; validMetrics++; }
    if (dy > 0) { totalScore += dyScore * 0.15; validMetrics++; }
    
    // 如果只有PE数据，使用PE评分
    final finalScore = validMetrics > 0 ? totalScore / (validMetrics * 0.2) : 0.50;
    final clampedScore = finalScore.clamp(0.10, 0.95);

    String sentiment, advice;
    if (clampedScore > 0.75) {
      sentiment = '明显低估';
      advice = '多维度估值指标均显示低估：$peNote。$pbNote。当前价位具有较高安全边际，适合价值投资者关注。';
    } else if (clampedScore > 0.60) {
      sentiment = '合理偏低';
      advice = '估值处于合理偏低区间：$peNote。$roeNote。若基本面稳健，当前价位具有投资价值。';
    } else if (clampedScore > 0.45) {
      sentiment = '估值合理';
      advice = '估值处于合理区间：$peNote。$pegNote。需关注未来业绩增速能否支撑当前估值。';
    } else if (clampedScore > 0.30) {
      sentiment = '估值偏高';
      advice = '估值偏高：$peNote。$pegNote。高估值需要高增长来支撑，若增速放缓则存在回调风险。';
    } else {
      sentiment = '明显高估';
      advice = '估值明显偏高：$peNote。除非有爆发性增长预期，否则当前价位风险较大，追高需极其谨慎。';
    }

    final items = <String, String>{};
    if (pe > 0) items['市盈率(PE)'] = '${_round(pe, 1)}倍';
    if (pb > 0) items['市净率(PB)'] = '${_round(pb, 1)}倍';
    if (eps > 0) items['每股收益(EPS)'] = _fmtPrice(eps);
    if (roe != 0) items['净资产收益率(ROE)'] = '${roe > 0 ? "+" : ""}${_round(roe, 1)}%';
    if (revGrowth != 0) items['营收增速'] = '${revGrowth > 0 ? "+" : ""}${_round(revGrowth, 1)}%';
    if (dy > 0) items['股息率'] = '${_round(dy, 2)}%';
    if (pe > 0 && revGrowth > 0) items['PEG'] = _round(pe / revGrowth, 1).toString();
    if (mc > 0) {
      if (mc >= 1e12) items['总市值'] = '${_round(mc / 1e12, 1)}万亿';
      else if (mc >= 1e8) items['总市值'] = '${_round(mc / 1e8, 1)}亿';
    }
    if (items.isEmpty) items['数据'] = '该市场暂不提供估值数据';

    // 估值补充说明
    final extraParts = <String>[];
    if (pe > 0 && eps > 0) extraParts.add('按当前EPS ${_fmtPrice(eps)}计算，回本周期约${_round(pe, 0)}年');
    if (dy > 0) extraParts.add('股息率${_round(dy, 2)}%提供分红安全垫');
    if (pb > 0 && pb < 1) extraParts.add('破净状态，每股净资产高于股价');
    String extraNote = extraParts.join('；');

    return {
      'title': '估值分析',
      'icon': 'valuation',
      'score': _round(clampedScore, 3),
      'sentiment': sentiment,
      'items': items,
      'advice': advice,
      'extra_note': extraNote,
    };
  }

  /// 7. 动量分析 - 增强版（真实动量指标）
  static Map<String, dynamic> _analyzeMomentum(Map<String, dynamic> d) {
    final cp = _safeDouble(d['change_pct']);
    final cur = _safeDouble(d['price']);
    final open = _safeDouble(d['open']);
    final high = _safeDouble(d['high']);
    final low = _safeDouble(d['low']);
    final vol = _safeInt(d['volume']);
    final turnoverRate = _safeDouble(d['turnover_rate']);

    // === 真实动量指标计算 ===
    
    // 1. 涨跌幅度分级
    String amplitudeLevel;
    double amplitudeScore;
    if (cp > 5) { amplitudeLevel = '暴涨'; amplitudeScore = 0.95; }
    else if (cp > 3) { amplitudeLevel = '大涨'; amplitudeScore = 0.80; }
    else if (cp > 1.5) { amplitudeLevel = '上涨'; amplitudeScore = 0.70; }
    else if (cp > 0.5) { amplitudeLevel = '微涨'; amplitudeScore = 0.60; }
    else if (cp > -0.5) { amplitudeLevel = '横盘'; amplitudeScore = 0.50; }
    else if (cp > -1.5) { amplitudeLevel = '微跌'; amplitudeScore = 0.40; }
    else if (cp > -3) { amplitudeLevel = '下跌'; amplitudeScore = 0.30; }
    else if (cp > -5) { amplitudeLevel = '大跌'; amplitudeScore = 0.20; }
    else { amplitudeLevel = '暴跌'; amplitudeScore = 0.10; }

    // 2. 日内振幅分析
    double rangePct = 0;
    String rangeNote = '';
    double rangeScore = 0.50;
    if (low > 0 && high > 0) {
      rangePct = (high - low) / low * 100;
      
      if (rangePct > 8) {
        rangeNote = '振幅极大，多空激烈博弈';
        rangeScore = 0.70; // 大振幅可能是底部反转信号
      } else if (rangePct > 5) {
        rangeNote = '振幅较大，市场活跃度高';
        rangeScore = 0.60;
      } else if (rangePct > 3) {
        rangeNote = '振幅适中，运行平稳';
        rangeScore = 0.50;
      } else {
        rangeNote = '振幅较小，观望情绪浓';
        rangeScore = 0.45;
      }
    }

    // 3. 振幅效率（涨跌幅占振幅比例）- 判断多空实力
    String efficiencyNote = '';
    double efficiencyScore = 0.50;
    if (rangePct > 0.5) {
      final efficiency = cp.abs() / rangePct; // 涨跌幅/振幅
      final direction = cp >= 0 ? 1 : -1;
      
      if (efficiency > 0.7) {
        efficiencyNote = direction > 0 ? '单边上涨，多头完全主导' : '单边下跌，空头完全主导';
        efficiencyScore = direction > 0 ? 0.85 : 0.15;
      } else if (efficiency > 0.4) {
        efficiencyNote = direction > 0 ? '偏多运行，多方占优' : '偏空运行，空方占优';
        efficiencyScore = direction > 0 ? 0.70 : 0.30;
      } else {
        efficiencyNote = '多空拉锯，方向不明';
        efficiencyScore = 0.50;
      }
    }

    // 4. 换手率配合（高换手+大涨=资金追捧）
    String turnoverNote = '';
    double turnoverScore = 0.50;
    if (turnoverRate > 0) {
      if (cp > 2 && turnoverRate > 10) {
        turnoverNote = '高换手大涨，资金追捧意愿强烈';
        turnoverScore = 0.90;
      } else if (cp > 1 && turnoverRate > 5) {
        turnoverNote = '换手活跃配合上涨，资金持续流入';
        turnoverScore = 0.75;
      } else if (cp < -2 && turnoverRate > 10) {
        turnoverNote = '高换手大跌，恐慌出逃明显';
        turnoverScore = 0.15;
      } else if (cp < -1 && turnoverRate > 5) {
        turnoverNote = '换手活跃配合下跌，资金流出';
        turnoverScore = 0.30;
      } else if (turnoverRate > 15) {
        turnoverNote = '换手率极高，分歧加大，警惕变盘';
        turnoverScore = 0.40;
      } else if (turnoverRate < 1) {
        turnoverNote = '换手率极低，交投冷清';
        turnoverScore = 0.45;
      } else {
        turnoverNote = '换手正常，市场运行平稳';
        turnoverScore = 0.50;
      }
    }

    // 5. 突破强度判断（收盘价相对日内高点）
    String breakoutNote = '';
    double breakoutScore = 0.50;
    if (high > 0 && cur > 0) {
      final distToHigh = (high - cur) / high * 100;
      
      if (distToHigh < 0.3) {
        breakoutNote = '收盘接近日高，日内强势收盘';
        breakoutScore = 0.85;
      } else if (distToHigh < 1) {
        breakoutNote = '收盘位置偏高，多头延续性较好';
        breakoutScore = 0.70;
      } else if (distToHigh > 3) {
        breakoutNote = '收盘远离日高，上冲受阻明显';
        breakoutScore = 0.35;
      }
    }

    // === 综合动量评分 ===
    final momentumScore = (amplitudeScore * 0.30 + rangeScore * 0.15 + efficiencyScore * 0.25 + turnoverScore * 0.20 + breakoutScore * 0.10);
    
    String sentiment, advice;
    if (momentumScore > 0.75) {
      sentiment = '动量强势';
      advice = '多头上攻动能充足，各项指标均支持上涨延续。建议顺势持有，可设置动态止盈保护利润。若后续量能配合，有望继续上攻。';
    } else if (momentumScore > 0.60) {
      sentiment = '动量偏强';
      advice = '上涨动能尚存，但部分指标显示可能面临压力。建议关注关键阻力位表现，突破可继续持有，受阻则减仓观望。';
    } else if (momentumScore > 0.45) {
      sentiment = '动量中性';
      advice = '多空力量均衡，动量方向不明。适合观望等待方向确认，或在小范围内高抛低吸。';
    } else if (momentumScore > 0.30) {
      sentiment = '动量偏弱';
      advice = '下行压力较大，短期可能继续走弱。建议关注支撑位表现，若有效支撑可考虑轻仓布局，破位则及时止损。';
    } else {
      sentiment = '动量弱势';
      advice = '空头动能强劲，短期风险较大。不建议逆势抄底，等待止跌信号（如缩量企稳、长下影线）出现再考虑。';
    }

    return {
      'title': '动量分析',
      'icon': 'momentum',
      'score': _round(momentumScore, 3),
      'sentiment': sentiment,
      'items': {
        '涨跌幅度': '$amplitudeLevel (${cp >= 0 ? "+" : ""}${_round(cp, 2)}%)',
        '日内振幅': rangePct > 0 ? '${_round(rangePct, 2)}%' : '--',
        '振幅效率': efficiencyNote.isNotEmpty ? efficiencyNote : '--',
        '换手配合': turnoverNote.isNotEmpty ? turnoverNote : '--',
        '收盘强度': breakoutNote.isNotEmpty ? breakoutNote : '--',
        '动量强度': momentumScore > 0.7 ? '强' : (momentumScore > 0.5 ? '中' : '弱'),
      },
      'advice': advice,
      'extra_note': '动量分析基于日内数据实时计算，建议结合多日数据判断趋势连续性。',
    };
  }

  /// 8. 支撑压力分析
  static Map<String, dynamic> _analyzeSupportResistance(Map<String, dynamic> d) {
    final cur = _safeDouble(d['price']);
    final high = _safeDouble(d['high']);
    final low = _safeDouble(d['low']);
    final prevClose = _safeDouble(d['prev_close']);
    final w52h = _safeDouble(d['week52_high']);
    final w52l = _safeDouble(d['week52_low']);

    // 简易支撑/压力位计算
    final pivot = prevClose > 0 ? (high + low + prevClose) / 3 : cur;
    final r1 = 2 * pivot - low;  // 第一压力位
    final s1 = 2 * pivot - high;  // 第一支撑位
    final r2 = pivot + (high - low);  // 第二压力位
    final s2 = pivot - (high - low);  // 第二支撑位

    String sentiment, advice;
    double score;
    final distToR1 = r1 > 0 ? (r1 - cur) / cur * 100 : 0;
    final distToS1 = s1 > 0 ? (cur - s1) / cur * 100 : 0;

    if (distToR1 < 0.5) { sentiment = '接近压力'; score = 0.40; advice = '价格接近第一压力位${_fmtPrice(r1)}，上方阻力较大。若不能有效突破，可能回落考验支撑。建议在压力位附近减仓或设置止盈。'; }
    else if (distToS1 < 0.5) { sentiment = '接近支撑'; score = 0.60; advice = '价格接近第一支撑位${_fmtPrice(s1)}，若有效支撑则可能反弹。可在支撑位附近轻仓试多，跌破则严格止损。'; }
    else { sentiment = '区间运行'; score = 0.50; advice = '价格在支撑${_fmtPrice(s1)}与压力${_fmtPrice(r1)}之间运行，短期可在此区间高抛低吸，等待方向突破。'; }

    return {
      'title': '支撑压力分析',
      'icon': 'support',
      'score': _round(score, 3),
      'sentiment': sentiment,
      'items': {
        '枢轴点': _fmtPrice(pivot),
        '第一压力位': _fmtPrice(r1),
        '第二压力位': _fmtPrice(r2),
        '第一支撑位': _fmtPrice(s1),
        '第二支撑位': _fmtPrice(s2),
        if (w52h > 0) '52周高点压力': _fmtPrice(w52h),
        if (w52l > 0) '52周低点支撑': _fmtPrice(w52l),
      },
      'advice': advice,
      'extra_note': '以上支撑压力位基于Pivot Point方法计算，仅供参考。实际走势受多重因素影响。',
    };
  }

  /// 9. 机构/游资/基金持仓分析
  static Map<String, dynamic> _analyzeCapitalFlow(Map<String, dynamic> d, Map<String, dynamic>? holderData) {
    if (holderData == null) {
      return {
        'title': '机构与资金持仓分析',
        'icon': 'capital_flow',
        'score': 0.50,
        'sentiment': '数据暂无',
        'items': {'提示': '该市场暂不支持持仓数据查询'},
        'advice': '当前仅A股支持机构/基金持仓数据查询。港股和美股的机构持仓信息可通过SEC EDGAR或港交所披露易获取，建议前往官方渠道查询。',
        'extra_note': '数据来源限制',
      };
    }

    final topHolders = (holderData['top_holders'] as List?) ?? [];
    final fundHolders = (holderData['fund_holders'] as List?) ?? [];
    final instSummary = holderData['inst_summary'] as Map<String, dynamic>?;
    final changeHistory = (holderData['change_history'] as List?) ?? [];

    // 按股东名分组历史变动记录
    final historyByName = <String, List<Map<String, dynamic>>>{};
    for (final ch in changeHistory) {
      final cm = ch as Map<String, dynamic>;
      final n = cm['name']?.toString() ?? '';
      if (!historyByName.containsKey(n)) historyByName[n] = [];
      final list = historyByName[n];
      if (list != null) list.add(cm);
    }

    // 分析十大股东中的机构类型分布
    int institutionCount = 0;
    int fundCount = 0;
    int corpCount = 0;
    int qfiiCount = 0;
    final holderDetails = <String>[];
    for (final h in topHolders) {
      final hm = h as Map<String, dynamic>;
      final name = hm['name']?.toString() ?? '';
      final type = hm['type']?.toString() ?? '';
      final holdPct = _safeDouble(hm['hold_pct']);
      final changePct = _safeDouble(hm['change_pct']);

      // 分类
      if (type.contains('基金') || type.contains('保险') || type.contains('社保')) { institutionCount++; fundCount++; }
      else if (type.contains('QFII') || name.contains('香港中央') || name.contains('香港结算')) { qfiiCount++; institutionCount++; }
      else if (type.contains('公司') || type.contains('集团') || type.contains('企业')) { corpCount++; }
      else { institutionCount++; }

      // 增减方向（带百分比和持股数）
      String dir;
      if (changePct > 0.01) dir = '↑增持+${changePct.toStringAsFixed(2)}%';
      else if (changePct < -0.01) dir = '↓减持${changePct.toStringAsFixed(2)}%';
      else dir = '→不变';

      final holdNum = _safeDouble(hm['hold_num']);
      String numStr;
      if (holdNum >= 100000000) numStr = '${(holdNum / 100000000).toStringAsFixed(2)}亿股';
      else if (holdNum >= 10000) numStr = '${(holdNum / 10000).toStringAsFixed(0)}万股';
      else if (holdNum > 0) numStr = '${holdNum.toInt()}股';
      else numStr = '-';

      // 拼接股东基础信息
      String detail = '$name\n类型:$type 持股:$numStr 占比:${holdPct.toStringAsFixed(2)}%\n$dir';

      // 追加历史增减持记录（最多3次）
      final history = historyByName[name] ?? [];
      if (history.isNotEmpty) {
        detail += '\n─── 历史变动 ───';
        for (final rec in history.take(3)) {
          final date = rec['date']?.toString() ?? '';
          final chgNum = _safeDouble(rec['change_num']);
          final chgPct = _safeDouble(rec['change_pct']);
          final reason = rec['reason']?.toString() ?? '';

          String chgNumStr;
          if (chgNum.abs() >= 100000000) chgNumStr = '${(chgNum / 100000000).toStringAsFixed(2)}亿';
          else if (chgNum.abs() >= 10000) chgNumStr = '${(chgNum / 10000).toStringAsFixed(0)}万';
          else if (chgNum.abs() > 0) chgNumStr = '${chgNum.toInt()}';
          else chgNumStr = '0';

          String dirH;
          if (chgPct > 0.01) dirH = '↑增持';
          else if (chgPct < -0.01) dirH = '↓减持';
          else dirH = '→不变';

          String reasonStr = reason.isNotEmpty ? '($reason)' : '';
          detail += '\n$date $dirH ${chgNumStr}股 ${chgPct >= 0 ? "+" : ""}${chgPct.toStringAsFixed(2)}% $reasonStr';
        }
      }

      holderDetails.add(detail);
    }

    // 基金持仓详情
    final fundDetails = <String>[];
    for (final h in fundHolders) {
      final hm = h as Map<String, dynamic>;
      final name = hm['name']?.toString() ?? '';
      final code = hm['code']?.toString() ?? '';
      final shares = _safeDouble(hm['shares']);
      final netvalPct = _safeDouble(hm['netval_pct']);
      String shareStr;
      if (shares >= 10000) shareStr = '${(shares / 10000).toStringAsFixed(0)}万股';
      else if (shares > 0) shareStr = '${shares.toInt()}股';
      else shareStr = '-';
      final label = code.isNotEmpty ? '$name($code)' : name;
      fundDetails.add('$label\n持股:$shareStr 占净值:${netvalPct.toStringAsFixed(2)}%');
    }

    // 评分逻辑
    double score = 0.50;
    String sentiment;

    // 机构占比越高越正面
    final instHoldPct = topHolders.fold<double>(0, (sum, h) {
      final hm = h as Map<String, dynamic>;
      final type = hm['type']?.toString() ?? '';
      if (type.contains('基金') || type.contains('保险') || type.contains('社保') || type.contains('QFII') || type.contains('证券'))
        return sum + _safeDouble(hm['hold_pct']);
      return sum;
    });

    // 增持减持倾向
    int buyCount = 0, sellCount = 0;
    for (final h in topHolders) {
      final hm = h as Map<String, dynamic>;
      final cp = _safeDouble(hm['change_pct']);
      if (cp > 0.01) buyCount++;
      else if (cp < -0.01) sellCount++;
    }

    if (buyCount > sellCount + 2) { score = 0.75; sentiment = '机构增持为主'; }
    else if (buyCount > sellCount) { score = 0.62; sentiment = '机构偏多'; }
    else if (sellCount > buyCount + 2) { score = 0.30; sentiment = '机构减持为主'; }
    else if (sellCount > buyCount) { score = 0.40; sentiment = '机构偏空'; }
    else { score = 0.50; sentiment = '机构持仓稳定'; }

    // AI解读
    String advice = '';
    if (qfiiCount > 0) {
      advice += '外资机构(QFII/港股通)持股中，${qfiiCount}家外资位列前十，说明国际资本看好该股。';
    }
    if (fundCount > 0) {
      advice += '公募/社保基金${fundCount}家持仓，属于机构抱团股，稳定性较好。';
    }
    if (buyCount > sellCount) {
      advice += '十大流通股东中${buyCount}家增持、${sellCount}家减持，机构整体偏向加仓，中长期信号偏积极。';
    } else if (sellCount > buyCount) {
      advice += '十大流通股东中${sellCount}家减持、${buyCount}家增持，机构有减持倾向，需关注减持是否持续。';
    } else {
      advice += '十大流通股东变动不大，机构持仓稳定，筹码结构变化不明显。';
    }

    // 基金持仓分析
    if (fundHolders.isNotEmpty) {
      advice += ' 基金持仓方面，最近一季共${fundHolders.length}只基金持有该股。';
      final bigFund = fundHolders.where((h) => _safeDouble((h as Map)['netval_pct']) > 5).length;
      if (bigFund > 0) advice += '其中${bigFund}只基金持仓占净值超5%，表明基金经理对该股有较高信心。';
    }

    // 构建items
    final items = <String, String>{};
    items['机构类型分布'] = '机构${institutionCount}家 / 企业${corpCount}家 / 外资${qfiiCount}家';
    if (instSummary != null) {
      items['机构持仓家数'] = '${_safeDouble(instSummary['org_num']).toInt()}家';
      items['机构合计持股占比'] = '${(_safeDouble(instSummary['total_pct']) * 100).toStringAsFixed(2)}%';
      items['机构持仓报告期'] = instSummary['date']?.toString() ?? '';
    }

    // 股东详情（逐条）
    for (int i = 0; i < holderDetails.length; i++) {
      items['股东${i + 1}'] = holderDetails[i];
    }
    for (int i = 0; i < fundDetails.length; i++) {
      items['基金${i + 1}'] = fundDetails[i];
    }

    // 报告期
    String reportDate = '';
    if (topHolders.isNotEmpty) {
      reportDate = (topHolders[0] as Map<String, dynamic>)['date']?.toString() ?? '';
    }

    return {
      'title': '机构与资金持仓分析',
      'icon': 'capital_flow',
      'score': _round(score, 3),
      'sentiment': sentiment,
      'items': items,
      'advice': advice,
      'extra_note': '数据来源：东方财富F10，十大流通股东报告期：$reportDate（季报更新）。基金持仓为最近一季披露数据。',
    };
  }

  // ============================================================
  // 四层评分引擎
  // ============================================================

  static double _fundamentalScore(Map<String, dynamic> d) {
    double s = 0.50;
    final roe = d['roe'];
    // roe为百分比值(如15.23表示15.23%)
    if (roe != null) { final r = _safeDouble(roe); if (r > 20) s += 0.15; else if (r > 10) s += 0.08; else if (r < 0) s -= 0.10; }
    final rg = d['revenue_growth'];
    // revenue_growth为百分比值
    if (rg != null) { final r = _safeDouble(rg); if (r > 20) s += 0.12; else if (r > 10) s += 0.06; else if (r < -10) s -= 0.08; }
    final pe = d['pe_ratio'];
    if (pe != null) { final p = _safeDouble(pe); if (p > 5 && p < 20) s += 0.10; else if (p >= 40) s -= 0.08; }
    final eps = d['eps'];
    if (eps != null) { if (_safeDouble(eps) > 0) s += 0.03; else s -= 0.05; }
    final dy = d['dividend_yield'];
    // dividend_yield是百分比值(如3.5表示3.5%)，与ROE/营收增速等格式一致
    if (dy != null && _safeDouble(dy) > 3.5) s += 0.05;
    return s.clamp(0.0, 1.0);
  }

  static double _technicalScore(Map<String, dynamic> d) {
    double s = 0.40;
    final cp = _safeDouble(d['change_pct']);
    final vol = _safeInt(d['volume']);
    if (cp > 1.5) s += 0.20;
    else if (cp > 0.5) s += 0.10;
    else if (cp < -1.5) s -= 0.10;
    else if (cp < -0.5) s -= 0.05;
    if (vol > 0 && cp > 0) s += 0.10;
    if (vol > 0 && cp < -1) s -= 0.08;
    return s.clamp(0.0, 1.0);
  }

  static double _capitalFlowScore(Map<String, dynamic> d) {
    double s = 0.50;
    final vol = _safeInt(d['volume']);
    final cp = _safeDouble(d['change_pct']);
    if (vol > 0 && cp > 1) s += 0.15;
    else if (vol > 0 && cp < -1) s -= 0.10;
    return s.clamp(0.0, 1.0);
  }

  static double _momentumScore(Map<String, dynamic> d) {
    double s = 0.50;
    final cp = _safeDouble(d['change_pct']);
    if (cp > 3) s = 0.80;
    else if (cp > 1) s = 0.65;
    else if (cp > 0) s = 0.55;
    else if (cp > -1) s = 0.45;
    else if (cp > -3) s = 0.30;
    else s = 0.20;
    return s;
  }

  // ============================================================
  // AI详细分析模块 - 买入/观望/回避的详细理由
  // ============================================================

  // ============================================================
  // 暗盘(集合竞价)分析 - 开盘前/收盘后
  // ============================================================

  /// 获取集合竞价数据并生成分析（东方财富trends2 API）
  Future<Map<String, dynamic>?> _analyzePreMarket(Map<String, dynamic> d) async {
    try {
      final symbol = d['symbol']?.toString() ?? '';
      final code = symbol.split('.')[0];
      final exch = symbol.split('.').length > 1 ? symbol.split('.')[1] : 'SS';
      final secid = exch == 'SS' ? '1.$code' : '0.$code';

      final resp = await _client.get(
        Uri.parse('https://push2.eastmoney.com/api/qt/stock/trends2/get?fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&ndays=1&iscr=1&iscca=0&secid=$secid'),
        headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 12)'}
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode != 200 || resp.body.isEmpty) return null;
      final raw = json.decode(resp.body);
      if (raw is! Map<String, dynamic>) return null;
      final rc = raw['rc'];
      if (rc != 0) return null;

      final data = raw['data'];
      if (data is! Map<String, dynamic>) return null;

      final preClose = _safeDouble(data['preClose']);
      final trends = data['trends'];
      if (trends is! List || trends.isEmpty) return null;

      // 解析盘前竞价(9:15-9:25)和收盘竞价(14:57-15:00)数据
      double? preOpenPrice;  // 集合竞价开盘价
      double? preOpenVol;    // 集合竞价成交量
      double? preOpenAmt;    // 集合竞价成交额
      double? closeAuctionPrice;  // 收盘竞价价格
      double? closeAuctionVol;    // 收盘竞价成交量
      double? closeAuctionAmt;    // 收盘竞价成交额
      double? preHighPrice;  // 盘前最高价
      double? preLowPrice;   // 盘前最低价

      for (final t in trends) {
        if (t is! String) continue;
        final parts = t.split(',');
        if (parts.length < 8) continue;
        final time = parts[0];
        final price = _safeDouble(parts[2]); // 收盘价
        final vol = _safeDouble(parts[5]);   // 成交量
        final amt = _safeDouble(parts[6]);   // 成交额

        // 盘前竞价: 9:15-9:25
        if (time.contains('09:1') || time.contains('09:2')) {
          if (time.contains('09:2')) {
            // 9:25之后的记录包含撮合结果
            preOpenPrice ??= price;
            preOpenVol = (preOpenVol ?? 0) + vol;
            preOpenAmt = (preOpenAmt ?? 0) + amt;
          }
          if (preHighPrice == null || price > preHighPrice) preHighPrice = price;
          if (preLowPrice == null || (price > 0 && price < (preLowPrice ?? 999999))) preLowPrice = price;
        }
        // 收盘竞价: 14:57-15:00
        if (time.contains('14:5') || time.contains('15:00')) {
          closeAuctionPrice = price;
          closeAuctionVol = (closeAuctionVol ?? 0) + vol;
          closeAuctionAmt = (closeAuctionAmt ?? 0) + amt;
        }
      }

      if (preOpenPrice == null && closeAuctionPrice == null) return null;

      // 构建分析
      final name = d['name']?.toString() ?? '该股';
      final items = <String, String>{};
      String sentiment;
      double score;
      String advice;

      if (preOpenPrice != null) {
        final preChg = preClose > 0 ? (preOpenPrice - preClose) / preClose * 100 : 0.0;
        items['盘前竞价价格'] = '${preOpenPrice.toStringAsFixed(2)}元';
        items['竞价涨跌幅'] = '${preChg.toStringAsFixed(2)}%';
        if (preOpenVol != null && preOpenVol > 0) {
          items['竞价成交量'] = '${(preOpenVol / 100).toStringAsFixed(0)}手';
          items['竞价成交额'] = _fmtAmt(preOpenAmt ?? 0);
        }
        if (preHighPrice != null && preLowPrice != null && preLowPrice > 0) {
          items['竞价波动区间'] = '${preLowPrice.toStringAsFixed(2)} - ${preHighPrice.toStringAsFixed(2)}元';
        }
      }

      if (closeAuctionPrice != null) {
        final curPrice = _safeDouble(d['price']);
        final closeChg = curPrice > 0 ? (closeAuctionPrice - curPrice) / curPrice * 100 : 0.0;
        items['收盘竞价价格'] = '${closeAuctionPrice.toStringAsFixed(2)}元';
        if (closeChg.abs() > 0.01) {
          items['收盘竞价偏移'] = '${closeChg.toStringAsFixed(2)}%';
        }
        if (closeAuctionVol != null && closeAuctionVol > 0) {
          items['收盘竞价量'] = '${(closeAuctionVol / 100).toStringAsFixed(0)}手';
          items['收盘竞价额'] = _fmtAmt(closeAuctionAmt ?? 0);
        }
      }

      // 判断情绪和评分
      if (preOpenPrice != null && preClose > 0) {
        final preChg = (preOpenPrice - preClose) / preClose * 100;
        if (preChg > 2) { sentiment = '竞价强势'; score = 0.75; }
        else if (preChg > 0.5) { sentiment = '竞价偏多'; score = 0.62; }
        else if (preChg > -0.5) { sentiment = '竞价中性'; score = 0.50; }
        else if (preChg > -2) { sentiment = '竞价偏空'; score = 0.38; }
        else { sentiment = '竞价弱势'; score = 0.25; }
      } else {
        sentiment = '数据不足'; score = 0.50;
      }

      // 生成解读
      advice = _generatePreMarketAdvice(name, preOpenPrice, preClose, preOpenVol, closeAuctionPrice, closeAuctionVol);

      return {
        'title': '暗盘数据(集合竞价)',
        'icon': 'schedule',
        'score': score,
        'sentiment': sentiment,
        'items': items,
        'advice': advice,
        'extra_note': '数据来源：东方财富集合竞价，含9:15-9:25开盘竞价及14:57-15:00收盘竞价',
      };
    } catch (_) { return null; }
  }

  /// 生成暗盘解读
  static String _generatePreMarketAdvice(String name, double? prePrice, double preClose, double? preVol, double? closePrice, double? closeVol) {
    final buf = StringBuffer();
    if (prePrice != null && preClose > 0) {
      final chg = (prePrice - preClose) / preClose * 100;
      buf.write('【开盘竞价】$name集合竞价${chg >= 0 ? "高开" : "低开"}${chg.abs().toStringAsFixed(2)}%，');
      if (chg > 2) {
        buf.write('竞价大幅高开，市场情绪积极。');
        if (preVol != null && preVol > 0) {
          buf.write('竞价成交${(preVol / 100).toStringAsFixed(0)}手，${preVol / 100 > 5000 ? "量能充沛，关注开盘后能否维持" : "量能一般，需盘中确认"}。');
        }
        buf.write('高开个股需注意：若开盘后快速回落则高开低走概率大，建议观察前30分钟走势再决策。');
      } else if (chg > 0) {
        buf.write('温和高开，市场情绪偏积极。');
        if (preVol != null && preVol > 0) {
          buf.write('竞价量${(preVol / 100).toStringAsFixed(0)}手，');
        }
        buf.write('若开盘后量价齐升则短线偏强，冲高回落则注意风险。');
      } else if (chg > -1) {
        buf.write('基本平开，多空分歧不大。竞价阶段的买卖力量相对均衡，');
        buf.write('开盘后方向需观察盘中量能变化。');
      } else {
        buf.write('低开${chg.abs().toStringAsFixed(2)}%，短线情绪偏弱。');
        buf.write('低开后若快速回补则洗盘概率大，若持续走弱则注意止损。');
      }
    }
    if (closePrice != null && closeVol != null && closeVol > 0) {
      buf.write(' 【收盘竞价】收盘集合竞价成交${(closeVol / 100).toStringAsFixed(0)}手，');
      buf.write(closeVol / 100 > 3000 ? '尾盘集中成交较大，可能有机构调仓行为。' : '尾盘竞价量正常。');
    }
    if (buf.isEmpty) buf.write('暂无集合竞价数据。非交易时段无法获取实时竞价信息。');
    return buf.toString();
  }

  static String _fmtAmt(double amt) {
    if (amt >= 1e8) return '${(amt / 1e8).toStringAsFixed(2)}亿';
    if (amt >= 1e4) return '${(amt / 1e4).toStringAsFixed(2)}万';
    return '${amt.toStringAsFixed(0)}元';
  }

  /// 极智深度分析 - 汇总所有模块数据，两大方向投资建议
  /// 已接入AI模型 - 若AI调用失败则回退至规则分析
  static Future<Map<String, dynamic>> _generateAIDetailed(
    Map<String, dynamic> d,
    Map<String, dynamic> ai,
    Map<String, Map<String, dynamic>> allModules,
  ) async {
    final action = ai['action'] ?? 'hold';
    final score = _safeDouble(ai['score']);
    final name = d['name']?.toString() ?? '该股';
    final market = d['market']?.toString() ?? '';

    // ---- 汇总所有模块数据 ----
    final cp = _safeDouble(d['change_pct']);
    final price = _safeDouble(d['price']);
    final pe = _safeDouble(d['pe_ratio']);
    final pb = _safeDouble(d['pb_ratio']);
    final roe = _safeDouble(d['roe']);  // 百分比值
    final eps = _safeDouble(d['eps']);
    final revGrowth = _safeDouble(d['revenue_growth']);  // 百分比值
    final divYield = _safeDouble(d['dividend_yield']);
    final turnoverRate = _safeDouble(d['turnover_rate']);
    final week52High = _safeDouble(d['week52_high']);
    final week52Low = _safeDouble(d['week52_low']);
    final high = _safeDouble(d['high']);
    final low = _safeDouble(d['low']);
    final prevClose = _safeDouble(d['prev_close']);
    final amount = _safeDouble(d['amount']);
    final vol = _safeInt(d['volume']);

    // 从各模块提取评分和情绪
    final mScore = <String, double>{};
    final mSent = <String, String>{};
    final mItems = <String, Map<String, dynamic>>{};
    for (final e in allModules.entries) {
      mScore[e.key] = _safeDouble(e.value['score']);
      mSent[e.key] = e.value['sentiment']?.toString() ?? '中性';
      final raw = e.value['items'];
      if (raw is Map<String, dynamic>) mItems[e.key] = raw;
      else if (raw is Map) mItems[e.key] = Map<String, dynamic>.from(raw);
    }

    // 加权综合评分
    double composite = (mScore['price'] ?? 0.5) * 0.15
                     + (mScore['volume'] ?? 0.5) * 0.12
                     + (mScore['trend'] ?? 0.5) * 0.18
                     + (mScore['momentum'] ?? 0.5) * 0.15
                     + (mScore['valuation'] ?? 0.5) * 0.15
                     + (mScore['capital_flow'] ?? 0.5) * 0.10
                     + (mScore['bid_ask'] ?? 0.5) * 0.05
                     + (mScore['volatility'] ?? 0.5) * 0.05
                     + (mScore['support_resistance'] ?? 0.5) * 0.05;
    if (mScore['pre_market'] != null) {
      composite = composite * 0.90 + mScore['pre_market']! * 0.10;
    }
    composite = composite.clamp(0.0, 1.0);

    // 判断是否值得买入持有
    final isWorthBuying = action == 'buy' || (action == 'hold' && composite >= 0.50);

    // ---- 构建实时数据汇总（只展示各模块原始数据，不展示评分）----
    final dataSummary = StringBuffer();
    dataSummary.write('■ 各模块实时最新数据：\n');

    // 1. 价格模块
    final priceItems = mItems['price'] ?? {};
    dataSummary.write('【价格】');
    if (priceItems.isNotEmpty) {
      dataSummary.write(priceItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    } else {
      dataSummary.write('现价${_fmtPrice(price)}元 涨跌${cp >= 0 ? "+" : ""}${cp.toStringAsFixed(2)}%');
    }
    dataSummary.write('\n');

    // 2. 量能模块
    final volumeItems = mItems['volume'] ?? {};
    dataSummary.write('【量能】');
    if (volumeItems.isNotEmpty) {
      dataSummary.write(volumeItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    } else {
      if (amount > 0) dataSummary.write('成交额${amount >= 1e8 ? '${(amount / 1e8).toStringAsFixed(1)}亿' : '${(amount / 1e4).toStringAsFixed(0)}万'}');
      if (turnoverRate > 0) dataSummary.write(' 换手${turnoverRate.toStringAsFixed(1)}%');
    }
    dataSummary.write('\n');

    // 3. 波动模块
    final volatilityItems = mItems['volatility'] ?? {};
    dataSummary.write('【波动】');
    if (volatilityItems.isNotEmpty) {
      dataSummary.write(volatilityItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    } else {
      if (high > 0 && low > 0) dataSummary.write('日内${_fmtPrice(low)}-${_fmtPrice(high)}');
    }
    dataSummary.write('\n');

    // 4. 趋势模块
    final trendItems = mItems['trend'] ?? {};
    dataSummary.write('【趋势】');
    if (trendItems.isNotEmpty) {
      dataSummary.write(trendItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    }
    dataSummary.write('\n');

    // 5. 盘口模块
    final bidAskItems = mItems['bid_ask'] ?? {};
    dataSummary.write('【盘口】');
    if (bidAskItems.isNotEmpty) {
      dataSummary.write(bidAskItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    }
    dataSummary.write('\n');

    // 6. 估值模块
    final valuationItems = mItems['valuation'] ?? {};
    dataSummary.write('【估值】');
    if (valuationItems.isNotEmpty) {
      dataSummary.write(valuationItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    } else {
      if (pe > 0) dataSummary.write('PE${pe.toStringAsFixed(1)}倍');
      if (pb > 0) dataSummary.write(' PB${pb.toStringAsFixed(1)}倍');
      if (roe > 0) dataSummary.write(' ROE${roe.toStringAsFixed(1)}%');
      if (eps > 0) dataSummary.write(' EPS${eps.toStringAsFixed(2)}元');
      if (revGrowth != 0) dataSummary.write(' 营收增速${revGrowth.toStringAsFixed(1)}%');
    }
    dataSummary.write('\n');

    // 7. 动量模块
    final momentumItems = mItems['momentum'] ?? {};
    dataSummary.write('【动量】');
    if (momentumItems.isNotEmpty) {
      dataSummary.write(momentumItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    }
    dataSummary.write('\n');

    // 8. 支撑压力模块
    final srItems = mItems['support_resistance'] ?? {};
    dataSummary.write('【支撑压力】');
    if (srItems.isNotEmpty) {
      dataSummary.write(srItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    }
    dataSummary.write('\n');

    // 9. 资金流模块
    final capitalItems = mItems['capital_flow'] ?? {};
    dataSummary.write('【资金流】');
    if (capitalItems.isNotEmpty) {
      dataSummary.write(capitalItems.entries.map((e) => '${e.key}${e.value}').join('、'));
    }
    dataSummary.write('\n');

    // 10. 暗盘模块
    if (mItems['pre_market'] != null) {
      final preMarketItems = mItems['pre_market']!;
      dataSummary.write('【暗盘/竞价】');
      dataSummary.write(preMarketItems.entries.map((e) => '${e.key}${e.value}').join('、'));
      dataSummary.write('\n');
    }

    final advice = StringBuffer();

    if (isWorthBuying) {
      // ============ 方向一：值得买入持有 ============
      advice.write('【方向一：值得买入持有】');
      advice.write('\n\n综合评分${(composite * 100).toStringAsFixed(0)}/100，$name具备投资价值。');

      // ---- 买入核心理由 ----
      advice.write('\n\n■ 买入核心理由：');
      final buyReasons = <String>[];
      if (mScore['trend'] != null && mScore['trend']! >= 0.60) buyReasons.add('趋势信号"${mSent['trend']}"，方向明确');
      if (mScore['momentum'] != null && mScore['momentum']! >= 0.55) buyReasons.add('动量"${mSent['momentum']}"，上行动能充足');
      if (roe > 15) buyReasons.add('ROE ${roe.toStringAsFixed(1)}%，盈利能力优秀');
      else if (roe > 8) buyReasons.add('ROE ${roe.toStringAsFixed(1)}%，盈利能力尚可');
      if (pe > 0 && pe < 20) buyReasons.add('PE ${pe.toStringAsFixed(1)}倍，估值具吸引力');
      if (revGrowth > 10) buyReasons.add('营收增速${revGrowth.toStringAsFixed(1)}%，成长性好');
      if (mScore['valuation'] != null && mScore['valuation']! >= 0.60) buyReasons.add('估值"${mSent['valuation']}"，安全边际充足');
      if (mScore['capital_flow'] != null && mScore['capital_flow']! >= 0.60) buyReasons.add('资金面"${mSent['capital_flow']}"，主力积极');
      if (week52High > 0 && week52Low > 0 && price > 0) {
        final pos = (price - week52Low) / (week52High - week52Low) * 100;
        if (pos < 40) buyReasons.add('股价处于52周${pos.toStringAsFixed(0)}%低位，反弹空间大');
      }
      if (buyReasons.isEmpty) buyReasons.add('多维度指标综合偏多，具备关注价值');
      for (int i = 0; i < buyReasons.length; i++) {
        advice.write('\n  ${i + 1}. ${buyReasons[i]}');
      }

      // ---- 1. 现在持有怎么办 ----
      advice.write('\n\n■ 1. 现在持有怎么办：');
      if (cp > 3) {
        advice.write('\n  已持仓者：今日涨${cp.toStringAsFixed(1)}%，短线获利丰厚。建议设置移动止盈（以今日开盘价${_fmtPrice(_safeDouble(d['open']))}为基准，回落2%减仓一半，回落4%清仓）。若后续放量创新高则继续持有，缩量滞涨则逐步止盈离场。');
      } else if (cp > 0) {
        advice.write('\n  已持仓者：当前小幅上涨${cp.toStringAsFixed(1)}%，趋势尚可。建议继续持有，止损设在支撑位下方${_fmtPrice(prevClose > 0 ? prevClose * 0.96 : price * 0.96)}。关注量能是否持续配合，放量上涨安心持有，缩量横盘则观望。');
      } else {
        advice.write('\n  已持仓者：当前小幅下跌${cp.abs().toStringAsFixed(1)}%，若未破关键支撑位可继续持有。止损设在第一支撑位下方2%处。若跌破支撑位则果断减仓至30%以下，不抱侥幸心理。');
      }
      advice.write('\n  原因：趋势"${mSent['trend']}"，动量"${mSent['momentum']}"，整体仍具备持有价值。');

      // ---- 2. 短期几天短炒建议 ----
      advice.write('\n\n■ 2. 短期T+1~T+5短炒建议：');
      if (mScore['momentum'] != null && mScore['momentum']! >= 0.60 && turnoverRate > 2) {
        advice.write('\n  短线可参与。入场时机：若明日开盘后前30分钟量价齐升（成交额放大1.5倍以上），可在${_fmtPrice(price * 1.005)}附近轻仓试多，仓位控制在总资金20%以内。');
        advice.write('\n  目标收益：+3%至+5%，持有2-3个交易日。');
        advice.write('\n  止损红线：买入价-3%无条件离场，不犹豫。');
        if (high > 0) advice.write('\n  压力位参考：${_fmtPrice(high)}，突破则加仓至30%。');
      } else if (cp > 1 && turnoverRate > 1) {
        advice.write('\n  短线谨慎参与。建议等回踩确认支撑后再入场，入场价参考${_fmtPrice(price * 0.98)}附近。仓位15%，目标+3%止盈，-2.5%止损。');
      } else {
        advice.write('\n  当前不适合短线操作。量能${mSent['volume']}、动量${mSent['momentum']}信号不明确，短线胜率偏低。建议等待放量突破信号出现后再考虑。');
      }
      advice.write('\n  原因：动量"${mSent['momentum']}"，量能"${mSent['volume']}"，换手率${turnoverRate.toStringAsFixed(1)}%。');

      // ---- 3. 中期3-6个月建议 ----
      advice.write('\n\n■ 3. 中期3-6个月建议：');
      final midReasons = <String>[];
      if (roe > 12) midReasons.add('ROE ${roe.toStringAsFixed(1)}%表明盈利能力稳健');
      if (revGrowth > 5) midReasons.add('营收增速${revGrowth.toStringAsFixed(1)}%，成长性有支撑');
      if (pe > 0 && pe < 25) midReasons.add('PE ${pe.toStringAsFixed(1)}倍估值合理偏低');
      if (midReasons.isEmpty) midReasons.add('基本面中等，需跟踪季度业绩');
      advice.write('\n  ${midReasons.join('；')}。');
      if (composite >= 0.60) {
        advice.write('\n  中期建议逢低分批建仓，首次买入20%，每下跌3%加仓10%，总仓位不超过50%。中期目标价${_fmtPrice(price * 1.15)}（+15%），止损设在${_fmtPrice(price * 0.90)}（-10%）。持有期间关注每季度财报，ROE持续>10%且营收正增长则继续持有。');
      } else {
        advice.write('\n  中期建议先建观察仓10%，待趋势"${mSent['trend']}"转强后加仓至30%。中期目标+10%，止损-8%。需密切关注下季度财报数据是否改善。');
      }
      advice.write('\n  原因：估值"${mSent['valuation']}"，趋势"${mSent['trend']}"，基本面数据支撑中期持有。');

      // ---- 4. 长期1年以上建议 ----
      advice.write('\n\n■ 4. 长期1年以上建议：');
      if (roe > 15 && revGrowth > 5 && pe > 0 && pe < 30) {
        advice.write('\n  长期看好。$name具备持续盈利能力(ROE ${roe.toStringAsFixed(1)}%)和成长性(营收增速${revGrowth.toStringAsFixed(1)}%)，估值合理(PE ${pe.toStringAsFixed(1)}倍)，适合长期定投或分批买入。');
        advice.write('\n  策略：每月定投或每跌5%加仓，持有1年以上，享受企业成长+分红收益。');
        if (divYield > 2) advice.write('\n  额外收益：股息率${divYield.toStringAsFixed(1)}%，每年提供稳定现金流。');
      } else if (roe > 8) {
        advice.write('\n  长期中性偏正。盈利能力尚可(ROE ${roe.toStringAsFixed(1)}%)，但成长性${revGrowth > 5 ? "尚可" : "偏弱"}。建议作为卫星仓位配置，不超过总仓位20%。长期持有需跟踪ROE是否稳定在10%以上。');
      } else {
        advice.write('\n  长期暂不建议重仓。ROE ${roe.toStringAsFixed(1)}%偏低，盈利能力待验证。若未来2个季度ROE回升至10%以上再考虑加仓。当前可少量配置(5-10%)作为观察。');
      }
      advice.write('\n  原因：ROE ${roe.toStringAsFixed(1)}%，PE ${pe > 0 ? pe.toStringAsFixed(1) : "N/A"}倍，EPS ${eps > 0 ? eps.toStringAsFixed(2) : "N/A"}元，营收增速${revGrowth != 0 ? revGrowth.toStringAsFixed(1) + "%" : "N/A"}。');

    } else {
      // ============ 方向二：不值得购买 ============
      advice.write('【方向二：暂不建议买入】');
      advice.write('\n\n综合评分${(composite * 100).toStringAsFixed(0)}/100，$name当前不宜介入。');

      // ---- 不值得购买的原因 ----
      advice.write('\n\n■ 不建议买入的原因：');
      final avoidReasons = <String>[];
      if (mScore['trend'] != null && mScore['trend']! < 0.40) avoidReasons.add('趋势"${mSent['trend']}"，短期方向偏空');
      if (mScore['momentum'] != null && mScore['momentum']! < 0.40) avoidReasons.add('动量"${mSent['momentum']}"，下行压力明显');
      if (pe > 50) avoidReasons.add('PE高达${pe.toStringAsFixed(1)}倍，估值严重偏高');
      if (roe > 0 && roe < 5) avoidReasons.add('ROE仅${roe.toStringAsFixed(1)}%，盈利能力堪忧');
      if (revGrowth < 0) avoidReasons.add('营收下滑${revGrowth.abs().toStringAsFixed(1)}%，经营恶化');
      if (eps <= 0) avoidReasons.add('每股收益为负，公司处于亏损状态');
      if (cp < -3) avoidReasons.add('今日跌${cp.abs().toStringAsFixed(1)}%，短期走势疲弱');
      if (mScore['capital_flow'] != null && mScore['capital_flow']! < 0.40) avoidReasons.add('资金面"${mSent['capital_flow']}"，主力在离场');
      if (mScore['valuation'] != null && mScore['valuation']! < 0.40) avoidReasons.add('估值"${mSent['valuation']}"，缺乏安全边际');
      if (week52Low > 0 && price > 0 && price < week52Low * 1.1) avoidReasons.add('股价接近52周新低，弱势明显');
      if (turnoverRate > 15) avoidReasons.add('换手率${turnoverRate.toStringAsFixed(1)}%过高，需警惕主力出货');
      if (avoidReasons.isEmpty) avoidReasons.add('多维度指标综合偏空，上行机会有限');
      for (int i = 0; i < avoidReasons.length; i++) {
        advice.write('\n  ${i + 1}. ${avoidReasons[i]}');
      }

      // ---- 如果已持有的应对 ----
      advice.write('\n\n■ 如果已持有：');
      if (cp < -3) {
        advice.write('\n  建议立即减仓至20%以下，止损离场为主。破位下跌不宜抱有幻想，保住本金比什么都重要。等待止跌企稳信号（连续3日不再创新低+缩量）后再考虑是否回补。');
      } else {
        advice.write('\n  建议减仓至30%以下观望。若后续跌破关键支撑位，则清仓离场。反弹至压力位附近可再减仓。空仓者不宜抄底接飞刀。');
      }

      // ---- 什么时候可以重新关注 ----
      advice.write('\n\n■ 何时重新关注：');
      advice.write('\n  需等待以下信号出现后方可重新考虑：');
      advice.write('\n  1. 趋势转强：连续3日收盘价上移+成交量放大');
      if (roe > 0 && roe < 8) advice.write('\n  2. 基本面改善：ROE回升至8%以上或季度营收转正增长');
      advice.write('\n  3. 量价配合：放量突破近期高点，资金面转正');
      advice.write('\n  4. 估值回归：PE回落至合理区间（<25倍）');
      advice.write('\n  以上条件满足2条以上时，可轻仓试多。');
    }

    // 风险提示（无论哪个方向都要加）
    advice.write('\n\n■ 风险提示：');
    final risks = <String>[];
    if (pe > 40) risks.add('估值偏高(PE ${pe.toStringAsFixed(1)}倍)存在回调风险');
    if (mScore['volatility'] != null && mScore['volatility']! <= 0.35) risks.add('高波动环境下止损止盈需严格');
    if (mScore['capital_flow'] != null && mScore['capital_flow']! < 0.40) risks.add('资金面偏弱，主力可能在离场');
    if (cp < -3) risks.add('短期跌幅较大，可能继续下行');
    if (mScore['momentum'] != null && mScore['momentum']! < 0.30) risks.add('动量向下，不宜逆势操作');
    if (market == 'HK' || market == 'US') risks.add('${market == "HK" ? "港股" : "美股"}受外部市场影响大，注意汇率和隔夜风险');
    if (risks.isEmpty) risks.add('市场系统性风险不可忽视');
    risks.add('本分析基于规则引擎+多模块数据综合研判，不构成投资建议');
    for (int i = 0; i < risks.length && i < 5; i++) {
      advice.write('\n  • ${risks[i]}');
    }

    // 截断
    String adviceStr = advice.toString();
    if (adviceStr.length > 1500) {
      adviceStr = adviceStr.substring(0, 1497) + '...';
    }

    // === 极智深度分析：纯规则模板结果 ===
    // AI调用在UI层展开卡片时触发，这里不调用AI
    String sentiment;
    double sentimentScore;
    if (isWorthBuying) {
      sentiment = composite >= 0.60 ? '建议买入持有' : '谨慎关注';
      sentimentScore = composite;
    } else {
      sentiment = '暂不建议买入';
      sentimentScore = composite;
    }

    final result = {
      'title': '极智深度分析',
      'icon': 'psychology',
      'sentiment': sentiment,
      'score': _round(sentimentScore, 3),
      'items': {
        '投资方向': isWorthBuying ? '值得买入持有' : '暂不建议买入',
        '综合评分': '${(composite * 100).toStringAsFixed(0)}/100',
        if (isWorthBuying) '操作建议': '详见4大方向分析' else '回避原因': '详见下方分析',
      },
      'advice': adviceStr,
      'extra_note': '本分析汇总价格/量能/趋势/动量/估值/资金/盘口/波动/支撑压力${mScore["pre_market"] != null ? "/暗盘" : ""}共${mScore["pre_market"] != null ? "10" : "9"}大模块实时数据综合研判',
    };

    return result;
  }

  // ============================================================
  // 企业简介模块 - 详细企业介绍（使用真实API数据）
  // ============================================================

  static Map<String, dynamic> _generateCompanyProfile(
    Map<String, dynamic> d,
    Map<String, dynamic>? companyData,
    List<Map<String, String>> historyData,
  ) {
    final name = d['name']?.toString() ?? '该公司';
    final market = d['market']?.toString() ?? '';
    final symbol = d['symbol']?.toString() ?? '';
    final pe = _safeDouble(d['pe_ratio']);
    final pb = _safeDouble(d['pb_ratio']);
    final roe = _safeDouble(d['roe']);
    final revGrowth = _safeDouble(d['revenue_growth']);
    final eps = _safeDouble(d['eps']);
    final divYield = _safeDouble(d['dividend_yield']);
    final mc = d['market_cap_display']?.toString() ?? '';
    // 新增财务数据
    final grossMargin = _safeDouble(d['gross_margin']);
    final netMargin = _safeDouble(d['net_margin']);
    // 企业基本信息
    final foundDate = companyData?['found_date']?.toString() ?? '';
    final legalRep = companyData?['legal_representative']?.toString() ?? '';
    final province = companyData?['province']?.toString() ?? '';
    final regCap = companyData?['registered_capital']?.toString() ?? '';
    final employeeCount = companyData?['employees']?.toString() ?? '';
    final companyCountry = companyData?['country']?.toString() ?? '';
    final companyCity = companyData?['city']?.toString() ?? '';
    final companyWebsite = companyData?['website']?.toString() ?? '';

    // 优先使用API返回的行业信息
    final apiIndustry = companyData?['industry']?.toString() ?? '';
    String industry = apiIndustry.isNotEmpty ? apiIndustry : _identifyIndustry(symbol, name);

    // 构建详细的企业介绍
    final buffer = StringBuffer();

    // === 一、企业概况 ===
    buffer.writeln('【一、企业概况】');
    final companyDesc = companyData?['company_desc']?.toString() ?? '';
    if (companyDesc.isNotEmpty && companyDesc.length > 20) {
      // 使用真实公司简介
      final desc = companyDesc.length > 600 ? '${companyDesc.substring(0, 600)}...' : companyDesc;
      buffer.writeln('$name$desc');
    } else if (companyDesc.isNotEmpty && companyDesc.length <= 20) {
      // 太短的desc（可能是Yahoo简介摘要），显示规则引擎
      buffer.writeln(_generateDetailedBusinessDesc(name, industry, market, symbol));
    } else {
      // 无真实数据，回退到规则引擎
      buffer.writeln(_generateDetailedBusinessDesc(name, industry, market, symbol));
    }

    // 补充结构化基本信息（独立于上面放出来，始终展示）
    final infoLines = <String>[];
    if (foundDate.isNotEmpty) infoLines.add('成立日期：$foundDate');
    if (legalRep.isNotEmpty) infoLines.add('法定代表人：$legalRep');
    if (regCap.isNotEmpty) infoLines.add('注册资本：$regCap');
    if (employeeCount.isNotEmpty && employeeCount != '0' && employeeCount != 'null') {
      infoLines.add('员工人数：${_formatEmployeeCount(employeeCount)}');
    }
    // 地区：优先province，其次city+country
    if (province.isNotEmpty) {
      infoLines.add('所在地区：$province');
    } else {
      final loc = [if (companyCity.isNotEmpty) companyCity, if (companyCountry.isNotEmpty) companyCountry].join('，');
      if (loc.isNotEmpty) infoLines.add('所在地区：$loc');
    }
    if (companyWebsite.isNotEmpty) infoLines.add('公司官网：$companyWebsite');
    if (infoLines.isNotEmpty) {
      buffer.writeln();
      for (final line in infoLines) {
        buffer.writeln('• $line');
      }
    }
    buffer.writeln();

    // === 二、主营业务 ===
    buffer.writeln('【二、主营业务】');
    final mainBusiness = companyData?['main_business']?.toString() ?? '';
    final mainProduct = companyData?['main_product']?.toString() ?? '';
    final businessScope = companyData?['business_scope']?.toString() ?? '';
    if (mainBusiness.isNotEmpty || mainProduct.isNotEmpty) {
      if (mainBusiness.isNotEmpty) {
        buffer.writeln('主营业务：$mainBusiness');
      }
      if (mainProduct.isNotEmpty) {
        buffer.writeln('主营产品：$mainProduct');
      }
      if (businessScope.isNotEmpty && businessScope.length < 500) {
        buffer.writeln('经营范围：${businessScope.length > 200 ? businessScope.substring(0, 200) + '...' : businessScope}');
      }
    } else {
      buffer.writeln(_generateMainBusiness(name, industry, market));
    }
    buffer.writeln();

    // === 三、所属行业分析 ===
    buffer.writeln('【三、所属行业分析】');
    buffer.writeln(_generateIndustryAnalysis(industry, market));
    buffer.writeln();

    // === 四、发展历程 ===
    buffer.writeln('【四、发展历程】');
    if (historyData.isNotEmpty) {
      for (final h in historyData.take(12)) {
        final date = h['date'] ?? '';
        final event = h['event'] ?? '';
        if (date.isNotEmpty && event.isNotEmpty) {
          buffer.writeln('• $date：$event');
        }
      }
    } else {
      buffer.writeln(_generateHistoricalMilestones(name, industry));
    }
    buffer.writeln();

    // === 五、财务概况 ===
    buffer.writeln('【五、财务概况】');
    buffer.writeln(_generateFinancialSummary(pe, pb, roe, revGrowth, eps, divYield, mc, grossMargin, netMargin));
    buffer.writeln();

    // === 六、投资价值总结 ===
    buffer.writeln('【六、投资价值总结】');
    buffer.writeln(_generateInvestmentSummary(industry, roe, revGrowth, pe, divYield, grossMargin));

    String fullProfile = buffer.toString();

    // 评分逻辑增强
    double score;
    String sentiment;
    int scorePoints = 0;
    if (roe > 15) { scorePoints += 2; }
    else if (roe > 8) { scorePoints += 1; }
    else if (roe < 0) { scorePoints -= 1; }
    if (revGrowth > 15) { scorePoints += 2; }
    else if (revGrowth > 5) { scorePoints += 1; }
    else if (revGrowth < 0) { scorePoints -= 1; }
    if (grossMargin > 40) { scorePoints += 1; }
    else if (grossMargin > 0 && grossMargin < 15) { scorePoints -= 1; }
    if (pe > 0 && pe < 15) { scorePoints += 1; }
    else if (pe > 50) { scorePoints -= 1; }
    if (divYield > 3) { scorePoints += 1; }

    if (scorePoints >= 4) { score = 0.80; sentiment = '前景看好'; }
    else if (scorePoints >= 2) { score = 0.60; sentiment = '前景平稳'; }
    else if (scorePoints >= 0) { score = 0.45; sentiment = '前景观望'; }
    else { score = 0.30; sentiment = '前景承压'; }

    // 构建 items 展示字典（丰富版）
    final items = <String, String>{};
    items['所属行业'] = industry;
    if (mc.isNotEmpty) items['市值'] = mc;
    if (foundDate.isNotEmpty) items['成立日期'] = foundDate;
    if (province.isNotEmpty) {
      items['所在地区'] = province;
    } else if (companyCity.isNotEmpty) {
      items['所在地区'] = companyCity;
    }
    if (employeeCount.isNotEmpty && employeeCount != '0' && employeeCount != 'null') {
      items['员工人数'] = _formatEmployeeCount(employeeCount);
    }
    if (roe != 0) items['ROE'] = '${roe > 0 ? "+" : ""}${roe.toStringAsFixed(1)}%';
    if (revGrowth != 0) items['营收增速'] = '${revGrowth > 0 ? "+" : ""}${revGrowth.toStringAsFixed(1)}%';
    if (pe > 0) items['PE'] = '${pe.toStringAsFixed(1)}倍';
    if (grossMargin != 0) items['毛利率'] = '${grossMargin.toStringAsFixed(1)}%';

    return {
      'title': '企业简介',
      'icon': 'valuation',
      'sentiment': sentiment,
      'score': score,
      'items': items,
      'advice': fullProfile,
      'extra_note': '',
    };
  }

  /// 格式化员工数量显示
  static String _formatEmployeeCount(String raw) {
    final n = double.tryParse(raw) ?? 0;
    if (n <= 0) return raw;
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return raw;
  }

  /// 生成详细的企业业务描述
  static String _generateDetailedBusinessDesc(String name, String industry, String market, String symbol) {
    final buf = StringBuffer();
    buf.write('$name');

    if (industry == '银行业') {
      buf.write('是中国银行业的重要金融机构，主要从事吸收公众存款、发放各类贷款、办理国内外结算等核心银行业务。');
      buf.write('作为金融体系的重要组成部分，该行在支持实体经济发展、服务居民金融需求方面发挥着关键作用。');
      buf.write('业务网络覆盖全国主要城市，拥有完善的线上线下服务体系，为客户提供全方位的金融解决方案。');
    } else if (industry == '证券业') {
      buf.write('是经中国证监会批准设立的综合性证券公司，主要业务涵盖证券经纪、投资银行、资产管理、自营投资等领域。');
      buf.write('公司拥有专业的投研团队和完善的风控体系，为企业客户提供IPO、再融资、并购重组等资本市场服务。');
      buf.write('在财富管理领域，为个人和机构投资者提供多元化的投资理财产品和服务。');
    } else if (industry == '保险业') {
      buf.write('是中国保险行业的重要企业，主营业务涵盖人寿保险、财产保险、健康保险及再保险等多个领域。');
      buf.write('公司以保费收入为主要收入来源，通过专业化的投资运营实现保险资金的保值增值。');
      buf.write('在风险管理和理赔服务方面积累了丰富经验，为社会经济发展提供重要的风险保障功能。');
    } else if (industry == '互联网科技') {
      buf.write('是一家领先的互联网科技企业，业务覆盖社交网络、电子商务、在线娱乐、云计算、人工智能等前沿领域。');
      buf.write('公司依托强大的技术研发能力和海量用户资源，构建了完整的数字生态系统。');
      buf.write('在移动互联网时代持续创新，不断拓展新的业务增长点，是全球数字经济的重要参与者。');
    } else if (industry == '医药生物') {
      buf.write('是一家专注于医药生物领域的高科技企业，主要从事创新药物研发、仿制药生产及医疗器械制造。');
      buf.write('公司拥有完善的研发体系和生产平台，致力于解决重大疾病领域的临床需求。');
      buf.write('在药物创新和产业化方面持续投入，多款产品已获得国内外监管机构批准上市。');
    } else if (industry == '石油石化') {
      buf.write('是中国石油石化行业的龙头企业，业务覆盖油气勘探开采、石油炼化、化工生产及成品油销售等全产业链。');
      buf.write('公司拥有丰富的油气资源和先进的炼化装置，是国内重要的能源供应商。');
      buf.write('在保障国家能源安全、推动绿色低碳转型方面承担着重要责任。');
    } else if (industry == '电力能源') {
      buf.write('是电力能源行业的重要企业，主要从事电力生产、输送及综合能源服务。');
      buf.write('公司运营多个大型发电项目，涵盖火电、水电、新能源等多种电源类型。');
      buf.write('在能源结构转型背景下，积极发展清洁能源业务，为社会经济发展提供稳定的电力保障。');
    } else if (industry == '房地产') {
      buf.write('是一家房地产开发企业，主营住宅地产、商业地产的开发销售及物业管理服务。');
      buf.write('公司在多个核心城市拥有土地储备和开发项目，具备较强的产品设计和项目运营能力。');
      buf.write('在行业调整期积极优化债务结构，探索新的发展模式，努力实现稳健经营。');
    } else if (industry == '科创板') {
      buf.write('是科创板上市企业，聚焦硬科技领域，具备较强的研发创新能力和技术壁垒。');
      buf.write('公司在核心技术领域持续突破，产品和技术处于行业领先地位。');
      buf.write('作为科技创新的代表，享受资本市场对科创企业的政策支持，发展前景广阔。');
    } else if (industry == '创业板') {
      buf.write('是创业板上市企业，以创新驱动发展，业务模式灵活，成长性较高。');
      buf.write('公司在细分市场具有竞争优势，持续加大研发投入和市场拓展力度。');
      buf.write('受益于国家对创新型企业的支持政策，未来发展空间值得期待。');
    } else if (industry == '科技巨头') {
      buf.write('是全球科技行业的领军企业，业务横跨硬件制造、软件开发、云计算服务、人工智能等核心领域。');
      buf.write('公司拥有世界领先的技术实力和品牌影响力，产品服务全球数亿用户。');
      buf.write('在数字经济时代持续引领技术创新，是推动全球科技进步的重要力量。');
    } else if (market == 'HK') {
      buf.write('是港股上市企业，业务覆盖多元化领域，依托中国内地和香港双重市场优势发展。');
      buf.write('公司具备国际化的视野和管理经验，在亚太地区拥有广泛的业务布局。');
    } else if (market == 'US') {
      buf.write('是在美股上市的企业，拥有全球化的业务布局和资本市场影响力。');
      buf.write('公司产品和服务覆盖多个国家和地区，在国际市场具有竞争优势。');
    } else {
      buf.write('是一家A股上市企业，在所属领域具备一定的市场地位和竞争力。');
      buf.write('公司持续推进业务发展和管理优化，努力为股东创造长期价值。');
    }
    return buf.toString();
  }

  /// 生成主营业务详情
  static String _generateMainBusiness(String name, String industry, String market) {
    if (industry == '银行业') {
      return '• 公司存款业务：吸收企业存款、个人储蓄存款，提供多样化的存款产品\n'
           '• 贷款业务：发放企业贷款、个人住房贷款、消费贷款等各类信贷产品\n'
           '• 中间业务：理财销售、银行卡服务、支付结算、代销基金保险等\n'
           '• 投资业务：债券投资、同业拆借、外汇交易等金融市场业务';
    } else if (industry == '证券业') {
      return '• 经纪业务：为投资者提供股票、债券、基金等证券交易服务\n'
           '• 投行业务：企业IPO、再融资、并购重组等资本市场服务\n'
           '• 资管业务：集合资产管理计划、定向资产管理等\n'
           '• 自营业务：权益投资、固定收益投资、衍生品交易等';
    } else if (industry == '保险业') {
      return '• 人寿保险：定期寿险、终身寿险、年金保险等产品\n'
           '• 财产保险：车险、企财险、责任险等财产保障产品\n'
           '• 健康保险：医疗险、重疾险等健康保障产品\n'
           '• 投资管理：保险资金的投资运营与保值增值';
    } else if (industry == '互联网科技') {
      return '• 社交与通讯：即时通讯、社交网络平台运营\n'
           '• 数字内容：游戏、视频、音乐等数字娱乐产品\n'
           '• 电子商务：在线零售、支付服务、物流配送\n'
           '• 企业服务：云计算、人工智能、企业软件解决方案';
    } else if (industry == '医药生物') {
      return '• 创新药研发：针对肿瘤、心脑血管等重大疾病的创新药物\n'
           '• 仿制药生产：高质量仿制药的研发与生产\n'
           '• 医疗器械：诊断设备、治疗设备等医疗器械产品\n'
           '• CDMO服务：为其他药企提供研发和生产外包服务';
    } else if (industry == '石油石化') {
      return '• 勘探开采：国内外油气资源的勘探与开采\n'
           '• 炼油化工：原油炼制、石化产品生产\n'
           '• 成品油销售：加油站网络、批发零售业务\n'
           '• 化工新材料：高端化工材料的研发与生产';
    } else if (industry == '电力能源') {
      return '• 发电业务：火电、水电、风电、光伏等电源生产\n'
           '• 输配电：电网建设与运营、电力输送服务\n'
           '• 综合能源：分布式能源、储能、节能服务等\n'
           '• 新能源开发：风电、光伏等清洁能源项目投资运营';
    } else if (industry == '房地产') {
      return '• 住宅开发：商品房、保障房等住宅项目开发\n'
           '• 商业地产：写字楼、购物中心等商业物业\n'
           '• 物业管理：住宅及商业物业的运营管理服务\n'
           '• 城市更新：旧城改造、城市更新项目';
    } else if (industry == '科创板' || industry == '创业板') {
      return '• 核心技术产品：拥有自主知识产权的核心产品\n'
           '• 研发服务：技术开发、技术转让、技术咨询\n'
           '• 解决方案：为行业客户提供综合解决方案\n'
           '• 新兴业务：持续拓展新的业务领域和市场';
    } else if (industry == '科技巨头') {
      return '• 硬件产品：消费电子、智能设备等硬件产品\n'
           '• 软件服务：操作系统、应用软件、云服务等\n'
           '• 平台业务：搜索引擎、社交平台、电商平台等\n'
           '• 新兴技术：人工智能、自动驾驶、元宇宙等前沿领域';
    }
    return '• 主营业务：公司核心业务领域的研发、生产与服务\n'
         '• 配套业务：与主营业务相关的配套产品和服务\n'
         '• 新兴业务：积极拓展的新业务领域';
  }

  /// 生成行业分析
  static String _generateIndustryAnalysis(String industry, String market) {
    if (['银行业', '证券业', '保险业'].contains(industry)) {
      return '【行业特点】金融行业是现代经济的核心，具有高杠杆、强监管、周期性的特点。行业进入壁垒高，护城河深。\n\n'
           '【发展趋势】金融科技快速发展，数字化转型加速；监管趋严，合规要求提高；利率市场化持续推进，息差承压。\n\n'
           '【竞争格局】行业集中度较高，头部机构优势明显；差异化竞争成为关键，综合金融服务能力日益重要。';
    } else if (['互联网科技', '科技巨头'].contains(industry)) {
      return '【行业特点】科技行业属于高成长高波动行业，技术迭代快，赢家通吃效应明显，估值偏高但增长空间大。\n\n'
           '【发展趋势】人工智能、云计算、大数据等技术快速发展；监管加强，数据安全与隐私保护受到重视；元宇宙、Web3等新概念涌现。\n\n'
           '【竞争格局】全球科技巨头竞争激烈，中国企业加速出海；创新驱动增长，技术壁垒是核心竞争力。';
    } else if (['医药生物', '医药健康'].contains(industry)) {
      return '【行业特点】医药行业属于防御性成长行业，受政策影响大但需求刚性，研发驱动型具备长期价值。\n\n'
           '【发展趋势】人口老龄化推动需求增长；创新药成为发展重点，仿制药集采常态化；医疗器械国产替代加速。\n\n'
           '【竞争格局】创新药企与仿制药企分化明显；研发实力和管线深度决定企业价值；国际化成为重要方向。';
    } else if (['石油石化', '能源业'].contains(industry)) {
      return '【行业特点】能源行业属于强周期行业，业绩与国际大宗商品价格高度相关，现金流充沛但增长有限。\n\n'
           '【发展趋势】全球能源转型加速，碳中和目标推动清洁能源发展；传统油气企业加速布局新能源业务。\n\n'
           '【竞争格局】国内市场由几大央企主导，国际市场参与全球竞争；成本控制和资源储备是核心竞争力。';
    } else if (industry == '电力能源') {
      return '【行业特点】公用事业行业属于防御性行业，现金流稳定可预测，适合追求稳健收益的投资者。\n\n'
           '【发展趋势】能源结构转型，新能源装机占比持续提升；电力市场化改革深化，电价机制逐步完善。\n\n'
           '【竞争格局】发电侧竞争加剧，新能源项目开发活跃；电网企业垄断经营，盈利模式稳定。';
    } else if (industry == '房地产') {
      return '【行业特点】房地产行业属于强周期高杠杆行业，政策敏感度极高，当前处于行业深度调整期。\n\n'
           '【发展趋势】"房住不炒"定位不变，因城施策持续优化；保障性住房建设加速，城市更新成为新方向。\n\n'
           '【竞争格局】行业出清加速，优质房企市占率提升；稳健经营、财务健康的房企更具生存优势。';
    } else if (industry == '科创板') {
      return '【行业特点】硬科技行业属于高风险高回报类型，研发投入大，商业化不确定性高，但突破后弹性极大。\n\n'
           '【发展趋势】国家大力支持科技创新，科创板制度不断完善；关键核心技术攻关成为重点。\n\n'
           '【竞争格局】各细分领域竞争激烈，技术领先者享有估值溢价；人才和研发投入是核心竞争力。';
    } else if (industry == '创业板') {
      return '【行业特点】成长型行业以创新和扩张为特征，波动较大但成长空间可观。\n\n'
           '【发展趋势】产业升级和消费升级带来新机遇；专精特新企业发展受到政策支持。\n\n'
           '【竞争格局】细分市场龙头优势明显；差异化竞争和持续创新是关键。';
    }
    return '【行业特点】该行业具有独特的市场特征和发展规律，需关注行业周期和政策变化。\n\n'
         '【发展趋势】行业正处于转型升级阶段，新技术、新模式不断涌现。\n\n'
         '【竞争格局】市场竞争格局持续演变，具备核心竞争力的企业更具发展优势。';
  }

  /// 生成历史里程碑
  static String _generateHistoricalMilestones(String name, String industry) {
    if (industry == '银行业') {
      return '• 股份制改革：完成股份制改造，建立现代企业制度\n'
           '• 上市历程：在A股/港股成功上市，成为公众公司\n'
           '• 战略转型：推进零售银行转型，发展金融科技\n'
           '• 风险管理：建立完善的风险管理体系，资产质量保持稳定\n'
           '• 社会责任：积极履行社会责任，支持实体经济发展';
    } else if (industry == '证券业') {
      return '• 设立发展：经监管部门批准设立，逐步发展壮大\n'
           '• 业务拓展：取得多项业务资格，完善综合金融服务能力\n'
           '• 合规建设：建立健全合规管理体系，持续规范运营\n'
           '• 科技创新：加大金融科技投入，提升服务效率\n'
           '• 品牌建设：打造专业投研团队，树立行业口碑';
    } else if (industry == '互联网科技') {
      return '• 创业起步：在互联网发展浪潮中创立，找准市场定位\n'
           '• 产品创新：推出标志性产品，获得用户广泛认可\n'
           '• 快速成长：用户规模快速增长，市场份额持续扩大\n'
           '• 生态构建：构建完整的业务生态系统，形成协同效应\n'
           '• 国际化：积极拓展海外市场，提升国际影响力';
    } else if (industry == '医药生物') {
      return '• 研发突破：关键药物获得临床批准或上市许可\n'
           '• 生产建设：建成符合GMP标准的现代化生产基地\n'
           '• 产品上市：核心产品成功上市并获得市场认可\n'
           '• 国际合作：与国际药企建立合作关系，拓展海外市场\n'
           '• 技术创新：获得重要专利授权，建立技术壁垒';
    } else if (industry == '科创板' || industry == '创业板') {
      return '• 技术突破：在核心技术领域取得重要突破\n'
           '• 产品研发：推出具有竞争力的核心产品\n'
           '• 市场拓展：成功开拓重要市场或客户群体\n'
           '• 资本助力：获得风险投资或成功上市，获得发展资金\n'
           '• 荣誉认可：获得行业奖项或资质认证，提升品牌影响力';
    }
    return '• 创立发展：企业创立并逐步发展壮大\n'
         '• 业务拓展：持续拓展核心业务领域\n'
         '• 战略升级：推进战略转型和业务创新\n'
         '• 品牌建设：提升品牌影响力和市场地位\n'
         '• 社会贡献：积极履行社会责任，创造社会价值';
  }

  /// 生成财务概况
  static String _generateFinancialSummary(double pe, double pb, double roe, double revGrowth, double eps, double divYield, String mc, double grossMargin, double netMargin) {
    final parts = <String>[];
    if (mc.isNotEmpty) parts.add('市值$mc');
    if (pe > 0) parts.add('PE为${pe.toStringAsFixed(1)}倍');
    if (pb > 0) parts.add('PB为${pb.toStringAsFixed(2)}倍');
    if (roe != 0) parts.add('ROE为${roe > 0 ? "" : "负"}${roe.abs().toStringAsFixed(1)}%');
    if (revGrowth != 0) {
      parts.add('营收增速${revGrowth > 0 ? "+" : ""}${revGrowth.toStringAsFixed(1)}%');
    }
    if (grossMargin != 0) parts.add('毛利率${grossMargin.toStringAsFixed(1)}%');
    if (netMargin != 0) parts.add('净利率${netMargin.toStringAsFixed(1)}%');
    if (eps > 0) parts.add('EPS为${eps.toStringAsFixed(2)}元');
    if (divYield > 0) parts.add('股息率${divYield.toStringAsFixed(2)}%');

    if (parts.isEmpty) return '财务数据暂不完整，建议关注公司定期报告。';

    final buf = StringBuffer();
    buf.writeln('截至最新披露数据：${parts.join('，')}。');
    buf.writeln();

    // 加入简单解读
    final interpretations = <String>[];
    if (roe > 15) {
      interpretations.add('ROE高于15%，盈利能力强，资本运用效率优秀');
    } else if (roe > 8) {
      interpretations.add('ROE处于合理水平，盈利能力稳健');
    } else if (roe > 0 && roe <= 8) {
      interpretations.add('ROE偏低，盈利能力有待提升');
    }
    if (grossMargin > 50) {
      interpretations.add('毛利率超过50%，产品或服务具备较强定价权');
    } else if (grossMargin > 30) {
      interpretations.add('毛利率处于合理区间，行业竞争力稳定');
    }
    if (revGrowth > 15) {
      interpretations.add('营收增速较快，处于高速成长期');
    } else if (revGrowth < 0) {
      interpretations.add('营收出现下滑，需关注业务增长压力');
    }
    if (pe > 0 && pe < 15) {
      interpretations.add('PE估值较低，具备一定安全边际');
    } else if (pe > 40) {
      interpretations.add('PE估值偏高，市场给予了较高成长预期');
    }
    if (interpretations.isNotEmpty) {
      for (final i in interpretations) {
        buf.writeln('• $i');
      }
    }

    return buf.toString();
  }

  /// 生成投资价值总结
  static String _generateInvestmentSummary(String industry, double roe, double revGrowth, double pe, double divYield, double grossMargin) {
    final highlights = <String>[];
    final risks = <String>[];

    // 投资亮点
    if (roe > 15) {
      highlights.add('ROE较高，盈利能力强');
    } else if (roe > 10) {
      highlights.add('ROE处于合理水平，盈利能力稳定');
    } else if (roe > 0 && roe <= 10) {
      highlights.add('ROE中等，盈利能力尚可');
    }
    if (revGrowth > 15) {
      highlights.add('营收增速较快，成长性突出');
    } else if (revGrowth > 5) {
      highlights.add('营收保持增长，业务发展稳健');
    }
    if (grossMargin > 50) {
      highlights.add('毛利率高，具备较强定价权或护城河');
    } else if (grossMargin > 30) {
      highlights.add('毛利率良好，行业竞争地位稳固');
    }
    if (divYield > 3) {
      highlights.add('股息率较高，适合稳健投资者');
    }
    if (pe > 0 && pe < 15) {
      highlights.add('估值偏低，安全边际较高');
    }

    // 风险提示
    if (['银行业', '证券业', '保险业'].contains(industry)) {
      risks.add('宏观经济波动影响');
      risks.add('监管政策变化风险');
    } else if (['互联网科技', '科技巨头'].contains(industry)) {
      risks.add('技术迭代风险');
      risks.add('监管合规风险');
    } else if (['医药生物', '医药健康'].contains(industry)) {
      risks.add('研发失败风险');
      risks.add('集采降价风险');
    } else if (industry == '房地产') {
      risks.add('政策调控风险');
      risks.add('行业下行风险');
    } else {
      risks.add('行业周期风险');
      risks.add('市场竞争风险');
    }

    final buffer = StringBuffer();
    if (highlights.isNotEmpty) {
      buffer.writeln('投资亮点：' + highlights.join('；'));
    } else {
      buffer.writeln('投资亮点：公司在其所属领域具备一定竞争优势。');
    }
    buffer.writeln();
    if (risks.isNotEmpty) {
      buffer.writeln('风险提示：' + risks.join('；') + '。投资需谨慎，建议综合考虑个人风险承受能力。');
    }
    return buffer.toString();
  }

  /// 识别行业
  static String _identifyIndustry(String symbol, String name) {
    // A股按代码段识别
    final code = symbol.replaceAll('.SS', '').replaceAll('.SZ', '').replaceAll('.HK', '');
    final codeNum = int.tryParse(code) ?? 0;

    // A股行业识别
    if (codeNum >= 600000 && codeNum <= 600999) {
      if (name.contains('银行')) return '银行业';
      if (name.contains('证券') || name.contains('券商')) return '证券业';
      if (name.contains('保险')) return '保险业';
      return '沪市主板';
    }
    if (codeNum >= 601000 && codeNum <= 601999) {
      if (name.contains('银行')) return '银行业';
      if (name.contains('保险')) return '保险业';
      if (name.contains('石油') || name.contains('石化')) return '石油石化';
      if (name.contains('电力') || name.contains('能源')) return '电力能源';
      return '大型央企';
    }
    if (codeNum >= 603000 && codeNum <= 603999) return '沪市主板';
    if (codeNum >= 688000) return '科创板';
    if (codeNum >= 300000 && codeNum <= 301999) return '创业板';
    if (codeNum >= 002000 && codeNum <= 002999) return '中小板';
    if (codeNum >= 000001 && codeNum <= 000999) return '深市主板';

    // 港股
    if (symbol.contains('.HK')) {
      if (name.contains('银行')) return '银行业';
      if (name.contains('保险')) return '保险业';
      if (name.contains('地产') || name.contains('置业')) return '房地产';
      if (name.contains('科技') || name.contains('网络') || name.contains('互联')) return '互联网科技';
      if (name.contains('医药') || name.contains('生物')) return '医药生物';
      return '港股综合';
    }

    // 美股
    if (['AAPL', 'MSFT', 'GOOG', 'META', 'AMZN', 'NVDA', 'TSLA'].contains(code)) return '科技巨头';
    if (['JPM', 'BAC', 'GS', 'MS'].contains(code)) return '金融业';
    if (['JNJ', 'PFE', 'UNH', 'MRK'].contains(code)) return '医药健康';
    if (['XOM', 'CVX', 'COP'].contains(code)) return '能源业';
    if (code.isNotEmpty && code.length <= 5) return '美股上市企业';

    return '综合行业';
  }

  /// 生成业务描述
  static String _generateBusinessDesc(String name, String industry, String market, String symbol) {
    final buf = StringBuffer();
    buf.write('$name');

    if (industry == '银行业') {
      buf.write('是一家银行业金融机构，主要业务包括吸收公众存款、发放贷款、办理结算等传统银行业务，同时拓展理财、投行、信用卡等中间业务');
    } else if (industry == '证券业') {
      buf.write('是证券行业企业，核心业务涵盖证券经纪、投资银行、资产管理、自营交易等，受益于资本市场活跃度');
    } else if (industry == '保险业') {
      buf.write('是保险行业企业，主营人寿保险、财产保险或再保险业务，以保费收入为核心，投资收益为重要利润来源');
    } else if (industry == '互联网科技') {
      buf.write('是一家互联网科技企业，业务涵盖社交、电商、游戏、云计算、人工智能等领域，以技术创新和用户流量为驱动力');
    } else if (industry == '医药生物') {
      buf.write('是一家医药生物企业，从事创新药研发、仿制药生产或医疗器械制造，研发投入是核心竞争力');
    } else if (industry == '石油石化') {
      buf.write('是石油石化行业龙头，业务覆盖上游勘探开采、中游炼化、下游成品油销售，受国际油价影响显著');
    } else if (industry == '电力能源') {
      buf.write('是电力能源企业，主要从事发电、输配电及能源服务，以稳健现金流为特征');
    } else if (industry == '房地产') {
      buf.write('是房地产开发企业，主营住宅及商业地产开发销售，受政策调控和市场周期影响较大');
    } else if (industry == '科创板') {
      buf.write('是科创板上市企业，聚焦硬科技领域，具备较强的研发属性和创新基因');
    } else if (industry == '创业板') {
      buf.write('是创业板上市企业，以成长型创新企业为主，业务模式灵活，成长性较高');
    } else if (industry == '科技巨头') {
      buf.write('是全球科技行业巨头，业务横跨硬件、软件、云计算、人工智能等核心领域，拥有庞大的用户生态和技术壁垒');
    } else if (industry == '金融业') {
      buf.write('是金融行业企业，业务涵盖银行、资管、交易服务等，是金融体系的重要参与者');
    } else if (industry == '医药健康') {
      buf.write('是全球医药健康行业企业，从事创新药、医疗器械或健康服务，受益于人口老龄化趋势');
    } else if (industry == '能源业') {
      buf.write('是能源行业企业，主要从事油气勘探开采及能源化工，业绩与大宗商品价格高度相关');
    } else if (market == 'HK') {
      buf.write('是港股上市企业，业务覆盖多元化领域，依托中国内地和香港双重市场优势');
    } else if (market == 'US') {
      buf.write('是在美股上市的企业，拥有全球化的业务布局和资本市场影响力');
    } else {
      buf.write('是一家A股上市企业，在所属领域具备一定的市场地位和竞争力');
    }
    return buf.toString();
  }

  /// 生成盈利模式
  static String _generateProfitModel(String name, String industry, double roe, double revGrowth, double eps) {
    final buf = StringBuffer();

    if (industry == '银行业') {
      buf.write('以存贷利差为核心收入来源，净息差和资产质量决定盈利水平，中间业务（理财、托管、投行）贡献增量收入');
    } else if (industry == '证券业') {
      buf.write('以交易佣金、两融利息、投行承销费和自营投资收益为主要收入，业绩高度依赖市场行情');
    } else if (industry == '保险业') {
      buf.write('以保费收入为基座，通过利差（投资收益-资金成本）和死差（实际赔付低于预期）实现盈利');
    } else if (industry == '互联网科技') {
      buf.write('以广告、增值服务、云计算和金融科技为主要变现路径，规模效应显著，边际成本递减');
    } else if (industry == '医药生物') {
      buf.write('以药品销售为核心，创新药享受高毛利专利保护期，仿制药靠规模和成本优势竞争，研发管线决定长期价值');
    } else if (industry == '石油石化') {
      buf.write('以油气开采和炼化为利润基石，上游环节随油价波动，中下游环节赚取加工价差');
    } else if (industry == '电力能源') {
      buf.write('以发电量和上网电价为核心收入，成本端受燃料价格影响，利润相对稳定可预测');
    } else if (industry == '房地产') {
      buf.write('以房屋销售为主营收，土地储备和开发能力是核心资产，预售制带来现金流前置');
    } else if (industry == '科技巨头') {
      buf.write('以硬件销售、软件订阅、广告投放、云服务等多引擎驱动，生态锁定效应构筑高壁垒，毛利率显著高于传统行业');
    } else {
      buf.write('以产品销售和服务收入为核心，毛利率和运营效率决定最终盈利水平');
    }

    // roe为百分比值(如15.23表示15.23%)
    if (roe > 20) buf.write('。当前ROE达${roe.toStringAsFixed(1)}%，资本回报率优异');
    else if (roe > 10) buf.write('。ROE为${roe.toStringAsFixed(1)}%，资本效率良好');
    else if (roe > 0) buf.write('。ROE仅${roe.toStringAsFixed(1)}%，资本效率有待提升');

    // revGrowth为百分比值
    if (revGrowth > 15) buf.write('；营收高速增长${revGrowth.toStringAsFixed(1)}%，处于扩张期');
    else if (revGrowth > 5) buf.write('；营收稳健增长${revGrowth.toStringAsFixed(1)}%');

    return buf.toString();
  }

  /// 生成行业类型
  static String _generateIndustryType(String industry, String market) {
    if (['银行业', '证券业', '保险业', '金融业'].contains(industry)) return '金融行业，属于强周期性行业，受宏观经济和监管政策影响显著，行业进入壁垒高，护城河深';
    if (['互联网科技', '科技巨头'].contains(industry)) return '科技行业，属于高成长高波动行业，技术迭代快，赢家通吃效应明显，估值偏高但增长空间大';
    if (['医药生物', '医药健康'].contains(industry)) return '医药健康行业，属于防御性成长行业，受政策影响大但需求刚性，研发驱动型具备长期价值';
    if (['石油石化', '能源业'].contains(industry)) return '能源行业，属于强周期行业，业绩与国际大宗商品价格高度相关，现金流充沛但增长有限';
    if (['电力能源'].contains(industry)) return '公用事业行业，属于防御性行业，现金流稳定可预测，适合追求稳健收益的投资者';
    if (['房地产'].contains(industry)) return '房地产行业，属于强周期高杠杆行业，政策敏感度极高，当前处于行业深度调整期';
    if (['科创板'].contains(industry)) return '硬科技行业，属于高风险高回报类型，研发投入大，商业化不确定性高，但突破后弹性极大';
    if (['创业板'].contains(industry)) return '成长型行业，以创新和扩张为特征，波动较大但成长空间可观';
    return '综合型行业，业务多元，需结合具体细分领域评估';
  }

  /// 生成前景判断
  static String _generateOutlook(String industry, double roe, double revGrowth, double pe, double divYield, double cp) {
    final buf = StringBuffer();

    if (roe > 15 && revGrowth > 10) {
      buf.write('该企业盈利能力出色且增长强劲，处于行业有利位置，长期前景积极。若能持续保持创新和执行力，有望进一步扩大市场份额');
    } else if (roe > 10 && revGrowth > 0) {
      buf.write('该企业基本面稳健，盈利能力尚可，增长动力温和。行业竞争格局中等，需关注其能否在细分领域建立差异化优势');
    } else if (roe > 0 && revGrowth < 0) {
      buf.write('该企业虽然仍在盈利，但营收出现下滑，需警惕经营拐点。行业可能面临结构性调整，企业需加快转型或降本增效');
    } else {
      buf.write('该企业当前经营状况偏弱，盈利能力不足，需密切观察行业景气度是否回暖及企业自身的改革成效');
    }

    if (pe > 0 && pe < 15) buf.write('。当前PE仅${pe.toStringAsFixed(1)}倍，估值处于较低水平，安全边际较高');
    else if (pe > 30 && pe < 100) buf.write('。PE达${pe.toStringAsFixed(1)}倍，估值偏高，需以成长性来消化');
    if (divYield > 3) buf.write('。股息率${divYield.toStringAsFixed(1)}%，为投资者提供较好的现金回报');

    return buf.toString();
  }

  /// 综合决策 - 增强版（五维度加权评分）
  static Map<String, dynamic> _aiDecision(Map<String, dynamic> d, double fs, double ts, double cs, double ms) {
    final cp = _safeDouble(d['change_pct']);
    final pe = _safeDouble(d['pe_ratio']);
    final pb = _safeDouble(d['pb_ratio']);
    final roe = _safeDouble(d['roe']);
    final vol = _safeInt(d['volume']);
    final turnoverRate = _safeDouble(d['turnover_rate']);

    // === 五维度评分 ===
    
    // 1. 估值面评分（权重25%）
    double valScore = 0.50;
    if (pe > 0 && pe < 15) valScore = 0.80;
    else if (pe > 0 && pe < 25) valScore = 0.60;
    else if (pe > 0 && pe < 40) valScore = 0.45;
    else if (pe > 0) valScore = 0.25;
    // ROE加成
    if (roe > 15) valScore = (valScore + 0.15).clamp(0.0, 1.0);
    else if (roe > 10) valScore = (valScore + 0.08).clamp(0.0, 1.0);
    // PB安全边际
    if (pb > 0 && pb < 1) valScore = (valScore + 0.10).clamp(0.0, 1.0);

    // 2. 技术面评分（权重25%）
    double techScore = ts;

    // 3. 资金面评分（权重25%）
    double capScore = cs;
    // 换手率修正
    if (turnoverRate > 10 && cp > 2) capScore = (capScore + 0.10).clamp(0.0, 1.0);
    else if (turnoverRate > 10 && cp < -2) capScore = (capScore - 0.10).clamp(0.0, 1.0);

    // 4. 风险面评分（权重15%）
    double riskScore = 0.50;
    // 波动率风险
    if (cp.abs() > 5) riskScore -= 0.20;
    else if (cp.abs() > 3) riskScore -= 0.10;
    // PE偏离风险
    if (pe > 60) riskScore -= 0.15;
    else if (pe > 40) riskScore -= 0.08;
    // 高换手率风险
    if (turnoverRate > 15) riskScore -= 0.10;
    // 负增长风险
    final revGrowth = _safeDouble(d['revenue_growth']);
    if (revGrowth < -10) riskScore -= 0.15;
    else if (revGrowth < 0) riskScore -= 0.08;
    riskScore = riskScore.clamp(0.10, 0.90);

    // 5. 成长面评分（权重10%）
    double growthScore = 0.50;
    if (revGrowth > 30) growthScore = 0.90;
    else if (revGrowth > 15) growthScore = 0.75;
    else if (revGrowth > 5) growthScore = 0.60;
    else if (revGrowth > 0) growthScore = 0.50;
    else if (revGrowth > -10) growthScore = 0.35;
    else growthScore = 0.20;

    // === 综合评分 ===
    final sc = valScore * 0.25 + techScore * 0.25 + capScore * 0.25 + riskScore * 0.15 + growthScore * 0.10;

    String act, tr;
    if (sc >= 0.65) { act = 'buy'; tr = 'bullish'; }
    else if (sc >= 0.50) { act = 'hold'; tr = 'neutral'; }
    else if (sc >= 0.35) { act = 'hold'; tr = 'cautious'; }
    else { act = 'avoid'; tr = 'bearish'; }

    double wr = (sc * 0.85 + 0.10).clamp(0.10, 0.95);

    // === 详细理由生成 ===
    final rs = <String>[];
    
    // 估值面
    if (valScore > 0.70) rs.add('估值面：PE=${_round(pe, 1)}倍，估值合理偏低');
    else if (valScore > 0.50) rs.add('估值面：估值处于合理区间');
    else if (valScore < 0.35) rs.add('估值面：估值偏高，安全边际不足');
    
    // 技术面
    if (techScore > 0.65) rs.add('技术面：趋势偏多，K线形态向好');
    else if (techScore < 0.35) rs.add('技术面：趋势偏空，短期承压');
    
    // 资金面
    if (capScore > 0.65) rs.add('资金面：资金流入明显，机构关注度较高');
    else if (capScore < 0.35) rs.add('资金面：资金流出，市场情绪偏弱');
    
    // 风险面
    if (riskScore < 0.35) rs.add('风险面：短期波动风险较大');
    
    // 成长面
    if (growthScore > 0.70) rs.add('成长面：营收增速${_round(revGrowth, 1)}%，成长性突出');
    else if (growthScore < 0.35) rs.add('成长面：营收负增长，基本面承压');
    
    // ROE亮点
    if (roe > 15) rs.add('ROE=${_round(roe, 1)}%，盈利能力优秀');
    
    // 股息率
    final dy = _safeDouble(d['dividend_yield']);
    if (dy > 3) rs.add('股息率${_round(dy, 2)}%，分红收益可观');
    
    if (rs.isEmpty) rs.add('综合评估中性，建议观望');

    // === 风险提示 ===
    final rk = <String>[];
    if (cp.abs() > 5) rk.add('短期波动剧烈，注意控制仓位');
    if (pe > 50) rk.add('PE偏高，存在估值回调风险');
    if (pb > 0 && pb < 1) rk.add('PB破净，需排除业绩持续下滑风险');
    if (turnoverRate > 15) rk.add('换手率极高，短期分歧加大');
    if (revGrowth < 0) rk.add('营收负增长，基本面承压');
    rk.add('市场系统性风险不可忽视');
    rk.add('以上分析基于规则引擎，不构成投资建议');

    return {
      'score': _round(sc, 3),
      'short_term_win_rate': _round(wr, 3),
      'trend': tr,
      'action': act,
      'reason': rs.join('；'),
      'risk': rk,
      'detail': {
        'valuation_score': _round(valScore, 3),
        'technical_score': _round(techScore, 3),
        'capital_score': _round(capScore, 3),
        'risk_score': _round(riskScore, 3),
        'growth_score': _round(growthScore, 3),
        'fundamental_score': _round(fs, 3),
        'momentum_score': _round(ms, 3),
      },
      'ai_source': 'rule_engine_v7'
    };
  }

  // ============================================================
  // 工具方法
  // ============================================================
  static double _safeDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v.replaceAll(',', '')) ?? 0.0;
    return 0.0;
  }

  static int _safeInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static double _round(double v, int p) {
    final m = pow(10, p).toDouble();
    return (v * m).roundToDouble() / m;
  }

  static String _fmtPrice(double v) {
    if (v == 0) return '--';
    return v.toStringAsFixed(2);
  }

  static String _fmtVol(int v) {
    if (v <= 0) return '--';
    if (v >= 10000) return '${_round(v / 10000, 1)}万手';
    return '$v手';
  }

  /// 获取股票实时价格（给专家选股收益统计模块使用）
  /// [code] 股票代码，格式：000001.SZ 或 600000.SS
  Future<double> getPrice(String code) async {
    try {
      final parts = code.split('.');
      final symbol = parts[0];
      final exch = parts.length > 1 ? parts[1] : 'SS';
      
    // 构造新浪API所需的代码格式
    // 兼容 .SH/.SS/.SZ/.BJ 以及纯数字等多种格式
    String qqCode;
    if (exch == 'SS' || exch == 'SH') {
      qqCode = 'sh$symbol';
    } else if (exch == 'BJ') {
      qqCode = 'bj$symbol';
    } else if (exch == 'SZ') {
      qqCode = 'sz$symbol';
    } else {
      // 兜底：6开头=沪市，0/3开头=深市
      if (symbol.startsWith('6')) {
        qqCode = 'sh$symbol';
      } else {
        qqCode = 'sz$symbol';
      }
    }
      
      final resp = await _client.get(
        Uri.parse('https://qt.gtimg.cn/q=$qqCode'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 10));
      
      if (resp.statusCode != 200) return 0.0;
      
      final text = await _decodeGbk(resp.bodyBytes);
      if (text.isEmpty) return 0.0;
      
      final match = RegExp(r'="([^"]*)"').firstMatch(text);
      if (match == null) return 0.0;
      
      final g1 = match.group(1);
      if (g1 == null || g1.isEmpty) return 0.0;
      
      final f = g1.split('~');
      if (f.length < 50) return 0.0;
      
      final price = _safeDouble(f[3]);
      return price;
    } catch (e) {
      print('获取 $code 价格失败: $e');
      return 0.0;
    }
  }
  
  static String _fmtAmtSigned(double v) {
    if (v == 0) return '0';
    final sign = v > 0 ? '+' : '';
    if (v.abs() >= 1e8) return '$sign${_round(v / 1e8, 2)}亿';
    if (v.abs() >= 1e4) return '$sign${_round(v / 1e4, 1)}万';
    return '$sign${_round(v, 0)}';
  }
}
