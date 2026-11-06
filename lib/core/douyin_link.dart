/// 抖音分享链接 → 图文作品图片解析（免登录，2026-11-06 实测定稿）
///
/// 链路（配方深挖过程见 .test/douyin_*.py 与测试结论）：
/// 1. 分享文本里的 `v.douyin.com/xxx` 短链 302 → `iesdouyin.com/share/note/{id}/`。
///    全程爬虫 UA（Baiduspider）——普通手机 UA 只返回 JS 壳页，且该壳页的
///    客户端数据加载已死（真浏览器打开也报「抱歉出错了」）；
/// 2. 爬虫 UA 直接拿到 SSR 页，正文图在 JSON-LD `@type=article` 的 image 数组：
///    `douyinpic` 域名 + `~tplv-dy-aweme-images:q75.webp` 签名 URL
///    （同图多 CDN 镜像，按对象 uri 去重）；
/// 3. 签名 URL 不校验 UA/Cookie（约 30 天时效），任意客户端直接下载。
///
/// 画质结论（noop 原图当 ground truth 实测）：分辨率＝作者上传尺寸不缩水，
/// 损伤在 q75 webp 再压缩（PSNR ~35dB）；平坦色块色偏 mean 0.6 级，远小于
/// 拼豆调板色间距，对还原识别零风险。更优的 q75.jpeg 档（+2dB）只在浏览器
/// 页面内 fetch 的 detail JSON 里出现，免浏览器通道拿不到——不追。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'native_fetch.dart';

/// 解析失败的业务异常（消息可直接给用户看）
class DouyinLinkException implements Exception {
  final String message;
  const DouyinLinkException(this.message);

  @override
  String toString() => message;
}

/// 作品里的一张图
class DouyinNoteImage {
  const DouyinNoteImage({required this.url, required this.uriKey});

  /// 签名 q75 webp URL（缩略图展示与导入下载同源同档）
  final String url;

  /// CDN 对象 uri（路径 `~` 前段）——多镜像去重键
  final String uriKey;
}

/// 图文作品
class DouyinNote {
  const DouyinNote({required this.title, required this.images});
  final String title;
  final List<DouyinNoteImage> images;
}

/// 爬虫 UA：SSR 的钥匙（普通 UA 只给数据加载已死的 JS 壳页）
const _spider =
    'Mozilla/5.0 (compatible; Baiduspider/2.0; '
    '+http://www.baidu.com/search/spider.html)';

const _mobile =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    'Chrome/120.0.0.0 Mobile Safari/537.36';

/// URL 合法字符白名单（与 xhs_link 同款思路）：紧贴中文/emoji 不会吞链接
const _urlChars = r"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+";

// 注：Dart raw 字符串不做字符串插值（$_urlChars 会成字面量），此处用
// 非 raw 字符串 + 双反斜杠转义，保插值（2026-11-06 模拟器实测踩坑）
final _reShort = RegExp('(?:https?://)?v\\.douyin\\.com/$_urlChars');
final _reDirect = RegExp(
  '(?:https?://)?(?:www\\.)?(?:iesdouyin\\.com/share|douyin\\.com)'
  '/(?:note|video|post|slides)/$_urlChars',
);

/// 从任意分享文本中提取抖音链接（直链优先），没有则返回 null
String? extractDouyinLink(String text) {
  final direct = _reDirect.firstMatch(text);
  if (direct != null) {
    return direct.group(0)!;
  }
  final short = _reShort.firstMatch(text);
  if (short != null) {
    return short.group(0)!;
  }
  return null;
}

/// 直链里的作品 id 与类型（如 `share/note/123…` → `(note, 123…)`）
(String, String)? _idOf(String link) {
  final m = RegExp(
    r'/(?:share/)?(note|video|post|slides)/(\d{15,20})',
  ).firstMatch(link);
  if (m == null) {
    return null;
  }
  return (m.group(1)!, m.group(2)!);
}

/// 解析分享文本 → 作品（标题 + 全部正文图）
///
/// 抛 [DouyinLinkException]（消息面向用户），网络等底层异常原样上抛。
Future<DouyinNote> fetchDouyinNote(String shareText, {http.Client? client}) async {
  final link = extractDouyinLink(shareText);
  if (link == null) {
    throw const DouyinLinkException('未识别到抖音链接，请粘贴完整分享文案');
  }
  // 直链规范化到 share 页（结构已验证）；短链交给重定向落过去
  final pageUrl = () {
    final id = _idOf(link);
    if (id != null) {
      return 'https://www.iesdouyin.com/share/${id.$1}/${id.$2}/';
    }
    return link.startsWith('http') ? link : 'https://$link';
  }();
  final c = client ?? http.Client();
  try {
    var status = 0;
    var body = '';
    // Android 优先原生通道：跨主机跳转逐跳手动跟随且全程保爬虫 UA
    final native = await nativeHttpGet(pageUrl, userAgent: _spider);
    if (native != null) {
      status = native.status;
      body = native.body;
    } else {
      final resp = await c.get(Uri.parse(pageUrl), headers: {
        'User-Agent': _spider,
      }).timeout(const Duration(seconds: 20));
      status = resp.statusCode;
      body = resp.body;
    }
    if (status != 200) {
      throw DouyinLinkException('抖音返回 $status，链接可能已失效');
    }
    final note = _parseNote(body);
    if (note == null) {
      throw const DouyinLinkException(
        '没有解析到图片：可能是视频作品、链接已失效或页面结构变化',
      );
    }
    return note;
  } finally {
    if (client == null) {
      c.close();
    }
  }
}

/// 供测试/调试：直接解析 SSR HTML（不联网）
DouyinNote? parseDouyinNoteHtmlForTest(String html) => _parseNote(html);

/// SSR 页 → 标题 + 正文图列表；结构对不上返回 null
DouyinNote? _parseNote(String html) {
  var title = '';
  final urls = <String>[];
  // 1) JSON-LD article 块（结构化、干净）
  for (final m in RegExp(
    r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>',
    dotAll: true,
  ).allMatches(html)) {
    final Object? obj;
    try {
      obj = jsonDecode(m.group(1)!.trim());
    } on FormatException {
      continue;
    }
    if (obj is! Map || obj['@type'] != 'article') {
      continue;
    }
    final t = obj['headline'];
    if (t is String && t.isNotEmpty && title.isEmpty) {
      title = t;
    }
    final imgs = obj['image'];
    if (imgs is List) {
      for (final e in imgs) {
        final u = switch (e) {
          String() => e,
          Map() => (e['url'] ?? e['contentUrl'])?.toString(),
          _ => null,
        };
        if (u != null && u.isNotEmpty) {
          urls.add(u);
        }
      }
    }
  }
  // 2) 兜底：正文全文正则抓（防 JSON-LD 结构调整）
  if (urls.isEmpty) {
    for (final m in RegExp(
      r'''https://[^"\s\\]*douyinpic[^"\s\\]*~tplv-dy-aweme-images[^"\s\\]*''',
    ).allMatches(html)) {
      urls.add(
        m.group(0)!
            .replaceAll('\\u0026', '&')
            .replaceAll('&amp;', '&'),
      );
    }
  }
  // 只留正文图规格，按对象 uri 去重（同图多 CDN 镜像），保序
  final images = <DouyinNoteImage>[];
  final seen = <String>{};
  for (final u in urls) {
    if (!u.contains('~tplv-dy-aweme-images')) {
      continue; // 头像/贴纸/分享卡缩略图等
    }
    final uri = Uri.tryParse(u);
    if (uri == null || uri.pathSegments.isEmpty) {
      continue;
    }
    final last = uri.pathSegments.last.split('~').first;
    final key = '${uri.pathSegments.elementAt(
      uri.pathSegments.length - 2,
    )}/$last';
    if (seen.add(key)) {
      images.add(DouyinNoteImage(url: u, uriKey: key));
    }
  }
  if (images.isEmpty) {
    return null;
  }
  if (title.length > 40) {
    title = '${title.substring(0, 40)}…';
  }
  return DouyinNote(title: title, images: images);
}

/// 下载图片：签名 URL 不挑客户端，校验魔数确保是图片字节
Future<Uint8List> downloadDouyinImage(
  DouyinNoteImage image, {
  http.Client? client,
}) async {
  const magics = [
    [0x89, 0x50, 0x4E, 0x47], // PNG
    [0xFF, 0xD8, 0xFF], // JPEG
    [0x52, 0x49, 0x46, 0x46], // RIFF (WEBP)
    [0x47, 0x49, 0x46, 0x38], // GIF
  ];
  final c = client ?? http.Client();
  try {
    final resp = await c
        .get(Uri.parse(image.url), headers: {'User-Agent': _mobile})
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
      throw DouyinLinkException(
        '图片下载失败（HTTP ${resp.statusCode}），请重试或重新解析链接',
      );
    }
    final bytes = resp.bodyBytes;
    final head = bytes.take(4).toList();
    final ok = magics.any(
      (m) => m.length <= head.length && _startsWith(head, m),
    );
    if (!ok) {
      throw const DouyinLinkException('返回内容不是图片，链接可能已过期');
    }
    return bytes;
  } finally {
    if (client == null) {
      c.close();
    }
  }
}

bool _startsWith(List<int> data, List<int> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}
