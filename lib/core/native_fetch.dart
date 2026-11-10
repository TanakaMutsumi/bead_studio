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

/// 通道存在但请求失败（DNS/超时/TLS 等网络层异常）。
/// 与「通道不存在」区分开：Android 上 Dart http 回退对按 TLS 指纹分流的
/// 站点必死（v.douyin.com 对 dart:io ClientHello 直接 400，2026-11-10
/// 实测），调用方应直接报网络错误而不是再等一轮 20s 超时。
class NativeFetchFailure implements Exception {
  final String detail;
  const NativeFetchFailure(this.detail);

  @override
  String toString() => 'NativeFetchFailure: $detail';
}

/// 用 Android HttpURLConnection 抓取。
/// 通道不存在（非 Android 平台）返回 null，由调用方回退 Dart http；
/// 通道存在但请求失败抛 [NativeFetchFailure]——回退无意义，调用方直接
/// 给用户网络错误提示。
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
  } on PlatformException catch (e) {
    throw NativeFetchFailure('${e.code}${e.message != null ? ': ${e.message}' : ''}');
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
