/// 健壮图片解码：纯 Dart image 包优先，失败回退 Skia 引擎（dart:ui）
///
/// 背景：微信导出的 JPEG 常为渐进式编码、含 RST 重启标记等特殊变体，
/// 纯 Dart image 包对它们可能"返回 null"也可能"直接抛异常"
/// （如 ImageException: Unknown JPEG marker d1）——两种失败都要落入
/// Skia 回退（引擎自带的 libjpeg-turbo 全支持）。两条路都失败才抛
/// FormatException。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// 解码图片字节（支持 JPG/PNG/WebP/BMP/GIF 等）
///
/// 先走 image 包（纯 Dart、同步、无引擎依赖）；返回 null（不认识格式/编码）
/// 或抛异常（微信 JPEG 的 RST marker 触发 ImageException）时，都回退
/// ui.instantiateImageCodec 用 Skia 解，再转 image 包的 Image 结构。
Future<img.Image> decodeImageRobust(Uint8List bytes) async {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded != null) {
      return decoded;
    }
  } catch (_) {
    // image 包对特殊 JPEG 抛异常而非返回 null（如 Unknown JPEG marker d1），
    // 与返回 null 同等对待：落入下方 Skia 回退
  }

  // Skia 回退
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final rgba = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
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

/// 显示位图长边上限：模拟器 GLES 纹理上限常见 2048（GL_MAX_TEXTURE_SIZE），
/// 超限位图在 Impeller 下纹理创建残缺、只渲染出一条横带其余全白
/// （2026-08-25 实测 1200x2300 必现、1200x2000 正常）。预览显示宽最大
/// ~1056 逻辑像素，2048 已有两倍冗余；识别/裁剪不受此限幅影响。
const int kDisplayMaxEdge = 2048;

/// 解码并产出显示用重编码 JPEG（导入页/还原页预览共用）
///
/// 返回 (解码图, 显示 JPEG 字节)。显示层统一走重编码 + 长边限幅：
/// - 重编码：微信渐进式 JPEG 等特殊字节流统一转为规范基线 JPEG，
///   规避各渲染后端（Impeller/Skia）对边角字节流的解码差异；
/// - 限幅：任一边 > [kDisplayMaxEdge] 的位图可能超 GLES 纹理上限
///   （模拟器常见 2048），等比缩到限幅内再编码（显示框由 BoxFit.fill
///   拉伸，等比缩放无变形），同时把显示内存压在 ~16MB 内。
/// 识别/裁剪继续用 decoded 原始像素，不受重编码/限幅影响。
///
/// 注：2026-08-26 定案的"图片整片白屏"根因是 InteractiveViewer 被套在
/// SingleChildScrollView 的无界高度约束下（其变换矩阵算坏、child 整块
/// 不渲染），与图片字节/纹理上传无关——此前"Impeller 纹理上传静默失败"
/// 的推断已被二分实验推翻，勿再据此加兜底。
Future<(img.Image, Uint8List)> decodeForDisplay(Uint8List bytes) async {
  final decoded = await decodeImageRobust(bytes);
  final display = await compute(encodeDisplayJpg, decoded);
  return (decoded, display);
}

/// 重编码显示 JPEG（顶层函数供 compute 调用）
///
/// isolate 里跑：百万像素级缩放/编码同步执行会卡 UI 帧。
/// 用 JPEG 而非 PNG：同画质体积小一个量级，且 encodePng 的产物在
/// Impeller GLES 下纹理上传会静默失败（见 decodeForDisplay 注释）。
Uint8List encodeDisplayJpg(img.Image image) {
  var display = image;
  final longEdge = image.width >= image.height ? image.width : image.height;
  if (longEdge > kDisplayMaxEdge) {
    final scale = kDisplayMaxEdge / longEdge;
    display = img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
    );
  }
  return Uint8List.fromList(img.encodeJpg(display, quality: 92));
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
