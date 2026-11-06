/// 抖音无损原图通道：隐藏 WebView 加载 PC 笔记页，从 hydrate 后的
/// DOM 提取 `~tplv-dy-aweme-images:q75.jpeg` 签名 URL
///
/// 原理与全部实测结论见 docs/douyin_lossless_channel.md：
/// - detail JSON 的 `q75.jpeg` 档与作者上传原图**字节级相同**（md5 全等
///   实测），比 SSR q75.webp（PSNR ~35dB）高；
/// - detail API 在 WebView 里被页面加固层（Argus）扣住不放行（fetch/XHR
///   永久 pending，iframe 原生 fetch 无签名 403 "Uifid Not Found"）——
///   2026-11-07 模拟器实测；但页面 hydrate 会把整份 url_list（含
///   q75.jpeg 签名 URL）写进 DOM，无需任何请求即可提取；
/// - SSR 通道（douyin_link.dart）保持唯一兜底：本模块任何失败都应
///   **静默回退**，UI 与现状不劣化。
///
/// 用法：SSR 解析成功后，把 [DouyinDetailProbe] 挂到树里（失败/超时只回调
/// onDone，不带结果），成功则 onJpegs 给「对象 id → jpeg URL」映射，对齐键
/// 用 [douyinObjectIdOf]（dir 段跨通道不稳定，勿用 douyin_link 的 uriKey）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'douyin_link.dart';

/// WebView 必须伪装的桌面 UA（Android WebView 默认 UA 带 `; wv)` 会落
/// 移动端站——已死通道，只给 shrink:480 小图）
const kDouyinDesktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// detail JSON / hydrate DOM → {对象 id: 无损 jpeg URL}
///
/// 输入是 URL 列表（来自 detail JSON 的 url_list 或 DOM 提取），组内
/// （同对象 id）只收 jpeg 档；只有 webp 的组跳过（SSR 兜底同档，无增益）。
/// 空 → 抛 [DouyinLinkException]。
Map<String, String> mapJpegUrls(List<String> urls) {
  final out = <String, String>{};
  for (final u in urls) {
    if (!u.contains('~tplv-dy-aweme-images')) {
      continue; // 头像/贴纸/分享卡缩略图等
    }
    final oid = douyinObjectIdOf(u);
    if (oid.isEmpty || out.containsKey(oid)) {
      continue;
    }
    // 规格段：`objectId~tplv-dy-aweme-images:q75.jpeg?...`
    final spec = u.split('~').last.split('?').first;
    if (spec.contains('jpeg')) {
      out[oid] = u;
    }
  }
  if (out.isEmpty) {
    throw const DouyinLinkException('未找到 jpeg 档正文图');
  }
  return out;
}

/// DOM 提取 JS：outerHTML 里抓全部带签名的 aweme-images jpeg URL。
/// 结果 JSON 数组字符串（Android evaluateJavascript 不等 Promise，这里
/// 是同步表达式，直接返回）
const String _domExtractJs = '''
(() => {
  const h = document.documentElement.outerHTML
    .replace(/\\\\u([0-9a-fA-F]{4})/g, (m, x) => String.fromCharCode(parseInt(x, 16)))
    .replace(/&amp;/g, '&');
  const re = /https?:\\/\\/[^"'\\\\\\s<>]*douyinpic\\.com\\/[^"'\\\\\\s<>]*~tplv-dy-aweme-images[^"'\\\\\\s<>]*/g;
  const urls = [...new Set(h.match(re) || [])].filter(u => u.includes('jpeg'));
  return JSON.stringify(urls);
})()
''';

/// 隐藏 WebView：加载 PC 笔记页 → 等 hydrate → 从 DOM 提取 jpeg URL 回调
///
/// 挂载后自跑：成功 [onJpegs]（对象 id → jpeg URL，一次）→ [onDone]；
/// 任何失败/超时只 [onDone]（null，静默回退 SSR）。完成后即可卸载本组件。
class DouyinDetailProbe extends StatefulWidget {
  const DouyinDetailProbe({
    super.key,
    required this.noteId,
    required this.onJpegs,
    required this.onDone,
    this.timeout = const Duration(seconds: 55),
  });

  final String noteId;
  final void Function(Map<String, String> jpegs) onJpegs;
  final void Function() onDone;

  /// 总预算（含页面加载）；PC 页首开 ~8-12s + hydrate 忙主线程会拖慢
  /// evaluateJavascript（实测单次可 >5s），留足轮询窗口
  final Duration timeout;

  @override
  State<DouyinDetailProbe> createState() => _DouyinDetailProbeState();
}

class _DouyinDetailProbeState extends State<DouyinDetailProbe> {
  late final WebViewController _ctrl;
  var _finished = false;

  @override
  void initState() {
    super.initState();
    _ctrl =
        WebViewController()
          ..setUserAgent(kDouyinDesktopUa)
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..loadRequest(
            Uri.parse('https://www.douyin.com/note/${widget.noteId}'),
          );
    // 首帧挂载后再跑注入循环（controller 需已 attach 到 WebViewWidget）
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final deadline = DateTime.now().add(widget.timeout);
    try {
      // 阶段一：等页面真正渲染（PC 站重 JS；innerText>200 只代表壳，
      // hydrate 更晚）。就绪线：正文渲染出实质内容
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 3500));
        final shellLen = await _evalNum(
          'document.body ? document.body.innerText.length : 0',
        );
        if (shellLen < 200) {
          continue; // 壳页/未渲染
        }
        if (shellLen < 2000) {
          // 有壳但内容未铺开：给 hydrate 一点时间再进提取
          final urls = await _extract();
          if (urls.isNotEmpty) {
            return _success(urls);
          }
          continue;
        }
        break; // 正文铺开，进阶段二
      }
      // 阶段二：轮询 DOM 提取（hydrate 完成 url_list 全量入 DOM）
      while (DateTime.now().isBefore(deadline)) {
        final urls = await _extract();
        if (urls.isNotEmpty) {
          return _success(urls);
        }
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      }
    } on Exception {
      // 解析失败/JS 异常等：静默走兜底
    }
    if (mounted) {
      _finish(widget.onDone);
    }
  }

  /// 跑 DOM 提取 JS → jpeg URL 列表（异常/空 → 空表）。
  /// 页面 hydrate 期主线程忙，evaluate 可能排队很久，预算单独放宽
  Future<List<String>> _extract() async {
    String? raw;
    try {
      final res = await _ctrl
          .runJavaScriptReturningResult(_domExtractJs)
          .timeout(const Duration(seconds: 15));
      final r = res.toString();
      final decoded = jsonDecode(r);
      raw = decoded is String ? decoded : r;
    } on Exception {
      raw = null;
    }
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final obj = jsonDecode(raw);
      if (obj is List) {
        return obj.whereType<String>().toList(growable: false);
      }
    } on FormatException {
      // fallthrough
    }
    return const [];
  }

  void _success(List<String> urls) {
    final jpegs = mapJpegUrls(urls);
    if (!mounted) {
      return;
    }
    _finish(() {
      widget.onJpegs(jpegs);
      widget.onDone();
    });
  }

  /// 同步表达式求值 → 数值（异常/非数 → -1）
  Future<num> _evalNum(String js) async {
    try {
      final res = await _ctrl
          .runJavaScriptReturningResult(js)
          .timeout(const Duration(seconds: 5));
      return num.tryParse(res.toString()) ?? -1;
    } on Exception {
      return -1;
    }
  }

  void _finish(VoidCallback fn) {
    if (_finished) {
      return;
    }
    _finished = true;
    fn();
  }

  @override
  Widget build(BuildContext context) {
    // 视口必须 ≥1280 逻辑宽（窄视口会触发 PC 页降级）。OverflowBox 让
    // WebView 按桌面尺寸布局，外层 0.01 高 + ClipRect 保证不可见。
    return ClipRect(
      child: SizedBox(
        width: 1,
        height: 0.01,
        child: OverflowBox(
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: 0,
          maxHeight: double.infinity,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 1280,
            height: 800,
            child: WebViewWidget(controller: _ctrl),
          ),
        ),
      ),
    );
  }
}
