/// 健壮图片解码：纯 Dart image 包优先，失败回退 Skia 引擎（dart:ui）
///
/// 背景：微信导出的 JPEG 常为渐进式编码等特殊变体，纯 Dart image 包报
/// "unknown jpeg marker" 解不出来；Skia（引擎自带的 libjpeg-turk）全支持。
/// 两条路都失败才抛 FormatException。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// 解码图片字节（支持 JPG/PNG/WebP/BMP/GIF 等）
///
/// 先走 image 包（纯 Dart、同步、无引擎依赖）；返回 null（不认识格式/编码）
/// 时回退 ui.instantiateImageCodec 用 Skia 解，再转 image 包的 Image 结构。
Future<img.Image> decodeImageRobust(Uint8List bytes) async {
  final decoded = img.decodeImage(bytes);
  if (decoded != null) {
    return decoded;
  }

  // Skia 回退
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final rgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) {
      throw const FormatException("Skia 解码返回空数据");
    }
    return _fromRawRgba(rgba, frame.image.width, frame.image.height);
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException("无法解码图片（支持 JPG/PNG/WebP/BMP）: $e");
  }
}

/// RGBA 原始字节 -> image 包 Image（拷贝进 ImageData）
img.Image _fromRawRgba(ByteData rgba, int width, int height) {
  final out = img.Image(width: width, height: height);
  final data = rgba.buffer.asUint8List();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      out.setPixelRgba(x, y, data[i], data[i + 1], data[i + 2], data[i + 3]);
    }
  }
  return out;
}
