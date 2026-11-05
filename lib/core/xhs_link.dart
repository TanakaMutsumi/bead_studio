/// 小红书分享链接 → 笔记图片（含免登录原图）解析
///
/// 链路（2026-11-05 实测定稿，配方破解自开源 XHS-Downloader）：
/// 1. 手机 UA 请求分享链（xhslink 短链 301 到 discovery/item/{id}?xsec_token=…），
///    未登录可拿到 SSR 渲染的完整页面；
/// 2. 解析 window.__INITIAL_STATE__（undefined→null、new Map([])→[] 后 JSON），
///    手机版路径 noteData.data.noteData（PC 版 note.noteDetailMap 兜底）；
/// 3. imageList 每项 infoList 里有各分辨率签名 URL（H5_DTL=1080jpg 等），
///    签名与 `!后缀` 绑死、改后缀即 403、有时效；
/// 4. 原图配方：签名 URL 去掉 `协议+域名+时间戳+md5签名` 两段路径、砍掉
///    `!变换` 后缀，其余路径段原样保留（有的图带 notes_pre_post/ 前缀，丢了
///    就 404——实测裸 fileId 全 403/404 的根因），拼到图片镜像域名
///    sns-img-bd/qc/hw.xhscdn.com 上——该 CDN 不校验 UA/Cookie/Referer，
///    返回上传原始文件（实测 6400×6400 PNG）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'native_fetch.dart';

/// 解析失败的业务异常（消息可直接给用户看）
class XhsLinkException implements Exception {
  final String message;
  const XhsLinkException(this.message);

  @override
  String toString() => message;
}

/// 笔记里的一张图
class XhsNoteImage {
  const XhsNoteImage({
    required this.width,
    required this.height,
    required this.thumbUrl,
    required this.originalPath,
  });

  /// 页面元数据里的原始尺寸（0 表示缺失）
  final int width;
  final int height;

  /// 签名缩略图 URL（1080 级，有时效，仅本次会话内用于缩略图展示）
  final String thumbUrl;

  /// 原图在镜像 CDN 上的对象路径（如 `notes_pre_post/1040g…`），永不过期
  final String originalPath;

  String get originalUrl => 'https://$kOriginalHost/$originalPath';
}

/// 笔记
class XhsNote {
  const XhsNote({required this.title, required this.images});
  final String title;
  final List<XhsNoteImage> images;
}

/// 原图镜像域名（三域名互为备份，逐个降级）
const kOriginalHosts = [
  'sns-img-bd.xhscdn.com',
  'sns-img-qc.xhscdn.com',
  'sns-img-hw.xhscdn.com',
];
final kOriginalHost = kOriginalHosts.first;

const _ua =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    'Chrome/120.0.0.0 Mobile Safari/537.36';

/// URL 合法字符白名单（RFC3986 保留+未保留字符）：链接若紧贴中文/emoji
/// （转发改版无空格分隔）不会被吞进 URL——排除法正则做不到这点
const _urlChars = r"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+";

final _reShort = RegExp(
  r'(?:https?://)?xhslink\.(?:com|cn)/' + _urlChars,
);
final _reDirect = RegExp(
  r'(?:https?://)?www\.xiaohongshu\.com/(?:explore|discovery/item)/' +
      _urlChars,
);

/// 从任意分享文本中提取小红书链接（短链或笔记直链），没有则返回 null
String? extractXhsLink(String text) {
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

/// 解析分享文本 → 笔记（标题 + 全部图片的缩略图/原图地址）
///
/// 抛 [XhsLinkException]（消息面向用户），网络等底层异常原样上抛。
Future<XhsNote> fetchXhsNote(String shareText, {http.Client? client}) async {
  final link = extractXhsLink(shareText);
  if (link == null) {
    throw const XhsLinkException('未识别到小红书链接，请粘贴完整分享文案');
  }
  final c = client ?? http.Client();
  final url = Uri.parse(link.startsWith('http') ? link : 'https://$link');
  try {
    // 笔记页按 TLS 指纹分流：Android 优先走原生 HttpURLConnection
    // （Conscrypt，拿全量 SSR 页）；Dart http（BoringSSL）只拿得到无数据
    // 壳页，作为非 Android 回退（web 上会被 CORS 拦）
    var status = 0;
    var body = '';
    final native = await nativeHttpGet(
      url.toString(),
      userAgent: _ua,
      referer: 'https://www.xiaohongshu.com/',
    );
    if (native != null) {
      status = native.status;
      body = native.body;
    } else {
      final resp = await c.get(url, headers: {
        'User-Agent': _ua,
        'Referer': 'https://www.xiaohongshu.com/',
      }).timeout(const Duration(seconds: 20));
      status = resp.statusCode;
      body = resp.body;
    }
    if (status != 200) {
      throw XhsLinkException('小红书返回 $status，链接可能已失效');
    }
    // 风控页标记只认 xhs_sec_server：不能测 'sec_'——正常链接的
    // xsec_token 就含该子串，必误报（2026-11-05 模拟器实测踩坑）
    if (body.contains('xhs_sec_server')) {
      throw const XhsLinkException('链接触发风控，请在小红书 App 重新分享后再试');
    }
    final note = _parseNote(body);
    if (note == null) {
      throw const XhsLinkException(
        '页面里没有解析到图片：链接可能已失效或笔记被删除',
      );
    }
    return note;
  } finally {
    if (client == null) {
      c.close();
    }
  }
}

/// 供测试/调试：直接解析笔记 SSR HTML（不联网）
@visibleForTesting
XhsNote? parseXhsNoteHtmlForTest(String html) => _parseNote(html);

/// 从笔记 SSR HTML 提取标题与图片列表；结构对不上返回 null
XhsNote? _parseNote(String html) {
  final state = _parseInitialState(html);
  if (state == null) {
    return null;
  }
  // 手机版 SSR 路径优先，PC 版 noteDetailMap 兜底（XHS-Downloader 同款双路径）
  Map<String, Object?>? note;
  final noteData = _mapAt(state, ['noteData', 'data', 'noteData']);
  if (noteData != null) {
    note = noteData;
  } else {
    final detailMap = _mapAt(state, ['note', 'noteDetailMap']);
    if (detailMap != null && detailMap.isNotEmpty) {
      final first = detailMap.values.first;
      if (first is Map) {
        note = _mapAt(first.cast<String, Object?>(), ['note']);
      }
    }
  }
  if (note == null) {
    return null;
  }
  if (note['type'] == 'video') {
    throw const XhsLinkException('这是视频笔记，暂只支持图文/图集');
  }
  final rawList = note['imageList'];
  if (rawList is! List || rawList.isEmpty) {
    return null;
  }
  final images = <XhsNoteImage>[];
  for (final raw in rawList) {
    if (raw is! Map) {
      continue;
    }
    final item = raw.cast<String, Object?>();
    final img = _buildImage(item);
    if (img != null) {
      images.add(img);
    }
  }
  if (images.isEmpty) {
    return null;
  }
  final title = (note['title'] ?? note['desc'] ?? '').toString();
  return XhsNote(
    title: title.length > 40 ? '${title.substring(0, 40)}…' : title,
    images: images,
  );
}

/// 解析 window.__INITIAL_STATE__（含 undefined/Map 字面量清洗），失败返回 null
Map<String, Object?>? _parseInitialState(String html) {
  final m = RegExp(
    r'window\.__INITIAL_STATE__\s*=\s*(.+?)</script>',
    dotAll: true,
  ).firstMatch(html);
  if (m == null) {
    return null;
  }
  var raw = m.group(1)!.trim();
  if (raw.endsWith(';')) {
    raw = raw.substring(0, raw.length - 1);
  }
  // XHS-Downloader 同款清洗：Map/Set 字面量 + 冒号后 undefined；
  // 全局 undefined 替换有误伤字符串内容的风险，作为兜底第二次尝试
  for (final cleaned in [
    raw
        .replaceAll('new Map([])', '[]')
        .replaceAll('new Set([])', '[]')
        .replaceAll(':undefined', ':null'),
    raw.replaceAll('undefined', 'null'),
  ]) {
    try {
      final obj = jsonDecode(cleaned);
      if (obj is Map) {
        return obj.cast<String, Object?>();
      }
      return null;
    } on FormatException {
      continue;
    }
  }
  return null;
}

Map<String, Object?>? _mapAt(Map<String, Object?> root, List<String> keys) {
  Object? cur = root;
  for (final k in keys) {
    if (cur is! Map) {
      return null;
    }
    cur = cur[k];
  }
  return cur is Map ? cur.cast<String, Object?>() : null;
}

/// 从 imageList 单项构造：缩略图取签名 URL（H5_DTL 1080 优先），原图取对象路径
XhsNoteImage? _buildImage(Map<String, Object?> item) {
  String? signed;
  // 场景优先级：H5_DTL(1080) > WB_DFT(PC 大图) > urlDefault/url > 任意场景
  final infoList = item['infoList'];
  final scenes = <String, String>{};
  if (infoList is List) {
    for (final e in infoList) {
      if (e is Map) {
        final scene = e['imageScene']?.toString();
        final url = e['url']?.toString();
        if (scene != null && url != null && url.isNotEmpty) {
          scenes[scene] = url;
        }
      }
    }
  }
  signed = scenes['H5_DTL'] ??
      scenes['WB_DFT'] ??
      item['urlDefault']?.toString() ??
      item['url']?.toString() ??
      (scenes.isEmpty ? null : scenes.values.first);
  if (signed == null || signed.isEmpty) {
    return null;
  }
  final thumb = _forceHttps(signed);
  final path = _originalPath(thumb);
  if (path == null || path.isEmpty) {
    return null;
  }
  return XhsNoteImage(
    width: (item['width'] as num?)?.toInt() ?? 0,
    height: (item['height'] as num?)?.toInt() ?? 0,
    thumbUrl: thumb,
    originalPath: path,
  );
}

String _forceHttps(String url) =>
    url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

/// 签名 URL → 镜像 CDN 对象路径：
/// `https://sns-webpic-qc.xhscdn.com/{时间戳}/{md5}/{…路径}/{fileId}!{变换}`
/// 砍掉前两段（纯数字时间戳、32 位十六进制签名）和 `!` 变换，其余原样保留。
/// 老图可能没有前两段（直连 fileId），按启发式逐段判别，避免误删真实路径。
String? _originalPath(String signedUrl) {
  final uri = Uri.tryParse(signedUrl);
  if (uri == null || !uri.pathSegments.isNotEmpty) {
    return null;
  }
  final segs = List<String>.from(uri.pathSegments);
  // 去掉最后一段的 !变换 后缀
  final last = segs.removeLast();
  segs.add(last.split('!').first);
  // 跳过签名头（时间戳段：≥8 位纯数字；签名段：32 位十六进制）
  var start = 0;
  if (segs.isNotEmpty && RegExp(r'^\d{8,}$').hasMatch(segs[0])) {
    start = 1;
  }
  if (segs.length > start &&
      RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(segs[start])) {
    start += 1;
  }
  return segs.skip(start).where((s) => s.isNotEmpty).join('/');
}

/// 下载原图：三镜像域名逐个降级，校验魔数确保是图片字节
Future<Uint8List> downloadXhsOriginal(
  XhsNoteImage image, {
  http.Client? client,
  void Function(String host)? onTryHost,
}) async {
  const magics = [
    [0x89, 0x50, 0x4E, 0x47], // PNG
    [0xFF, 0xD8, 0xFF], // JPEG
    [0x52, 0x49, 0x46, 0x46], // RIFF (WEBP)
    [0x47, 0x49, 0x46, 0x38], // GIF
  ];
  Object? lastError;
  final c = client ?? http.Client();
  try {
    for (final host in kOriginalHosts) {
      if (onTryHost != null) {
        onTryHost(host);
      }
      try {
        final resp = await c
            .get(
              Uri.parse('https://$host/${image.originalPath}'),
              headers: {'User-Agent': _ua},
            )
            .timeout(const Duration(seconds: 60));
        if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
          lastError = 'HTTP ${resp.statusCode}';
          continue;
        }
        final bytes = resp.bodyBytes;
        final head = bytes.take(4).toList();
        final isImage = magics.any(
          (m) => m.length <= head.length &&
              _startsWith(head, m),
        );
        if (!isImage) {
          lastError = '返回内容不是图片';
          continue;
        }
        return bytes;
      } catch (e) {
        lastError = e;
      }
    }
  } finally {
    if (client == null) {
      c.close();
    }
  }
  throw XhsLinkException('原图下载失败（$lastError），请稍后重试');
}

bool _startsWith(List<int> data, List<int> prefix) {
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}
