/// 笔记页抓取的原生通道（bead_native_fetch：HttpURLConnection/Conscrypt）
///
/// 背景（2026-11-05 模拟器+PC 双端实测）：小红书笔记页按 TLS 指纹分流——
/// Dart HttpClient（BoringSSL 极简 ClientHello）拿到的是 37KB 无数据壳页
/// （__INITIAL_STATE__ 存在但无 imageList），python/schannel/curl 拿到的
/// 是 81KB 全量 SSR 页。Android 侧改走 HttpURLConnection（Conscrypt 指纹，
/// 与 Java 生态一致）拿全量页；本文件在非 Android 平台返回 null，由调用方
/// 回退 Dart http（web 上会被 CORS 拦，见 xhs_link 错误文案）。
library;

import 'package:flutter/services.dart';

/// 原生 GET 结果；[body] 为解压后的文本
class NativeFetchResult {
  const NativeFetchResult({required this.status, required this.body});
  final int status;
  final String body;
}

/// 用 Android HttpURLConnection 抓取；通道不存在/失败返回 null（回退 Dart http）
Future<NativeFetchResult?> nativeHttpGet(
  String url, {
  String? userAgent,
  String? referer,
}) async {
  try {
    final res = await const MethodChannel('bead_native_fetch').invokeMethod<
        Map<Object?, Object?>>('get', {
      'url': url,
      if (userAgent != null) 'userAgent': userAgent,
      if (referer != null) 'referer': referer,
    });
    if (res == null) {
      return null;
    }
    return NativeFetchResult(
      status: (res['status'] as num?)?.toInt() ?? 0,
      body: res['body']?.toString() ?? '',
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// 预留：原生通道下二进制下载（当前图片 CDN 走 Dart http 已够用）
Future<Uint8List?> nativeHttpGetBytes(String url, {String? userAgent}) async {
  try {
    final bytes = await const MethodChannel('bead_native_fetch')
        .invokeMethod<Uint8List>('getBytes', {
      'url': url,
      if (userAgent != null) 'userAgent': userAgent,
    });
    return bytes;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
