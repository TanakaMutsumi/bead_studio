/// 保存图片到系统相册（Pictures/bead_studio）
///
/// Android 走 MainActivity 里的 `bead_gallery_save` MethodChannel
/// （Q+ 用 MediaStore 免权限；Q 以下 legacy 公共目录尽力而为）。
/// 其余平台（web/桌面）当前不支持，抛异常由调用方提示。
library;

import 'package:flutter/services.dart';

/// 按魔数判断 MIME（下载的原图可能是 PNG/JPEG/WEBP）
String _sniffMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
      bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'application/octet-stream';
}

/// 保存到相册，成功返回系统相册里的显示名
Future<String> saveImageToGallery(Uint8List bytes, {String? namePrefix}) async {
  final mime = _sniffMime(bytes);
  final ext = switch (mime) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    _ => 'bin',
  };
  final now = DateTime.now();
  final stamp =
      '${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}'
      '${_two(now.minute)}${_two(now.second)}';
  final display = '${namePrefix ?? 'bead'}_$stamp.$ext';
  try {
    final saved = await const MethodChannel('bead_gallery_save').invokeMethod<
        String>('saveImage', {
      'bytes': bytes,
      'displayName': display,
      'mimeType': mime,
    });
    return saved ?? display;
  } on PlatformException catch (e) {
    throw Exception('保存失败: ${e.message ?? e.code}');
  } on MissingPluginException {
    throw Exception('当前平台不支持保存到相册');
  }
}

String _two(int v) => v.toString().padLeft(2, '0');
