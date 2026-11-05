/// 健壮图片解码：Skia 引擎（dart:ui，libjpeg-turbo）优先，失败回退纯
/// Dart image 包
///
/// 背景（2026-09-14 口径反转，原为纯 Dart 优先）：image 包的 JPEG 解码器
/// 与 libjpeg-turbo 存在系统性像素差，直接影响游程法图例/主体检测——
/// - wx2：直接抛 ImageException: Unknown JPEG marker d3 解不了；
/// - wx5：浅色图例色片解码偏亮，右侧 x1118-1391 色片被判白丢失；
/// - u1：像素漂移使图例带边界移 2px，翻转薄带判定（<24px）触发上走
///   越界。三者换成 libjpeg-turbo 口径（PIL/Skia 同源）全部与真值吻合。
/// 引擎解码在 Flutter 运行时始终可用；无引擎环境（纯 Dart 测试/CLI）
/// instantiateImageCodec 抛异常，自动落回 image 包。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// 解码图片字节（支持 JPG/PNG/WebP/BMP/GIF 等）
///
/// 先走 ui.instantiateImageCodec 用 Skia（libjpeg-turbo）解，再转 image
/// 包的 Image 结构；引擎不可用或解码失败（含微信渐进式 JPEG 等边角字节
/// 流）时回退纯 Dart image 包。两条路都失败才抛 FormatException。
Future<img.Image> decodeImageRobust(Uint8List bytes) async {
  // Skia 优先（像素口径 = libjpeg-turbo，与调参基准 PIL 一致）
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final rgba = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (rgba == null) {
      throw StateError("Skia 解码返回空数据");
    }
    return await _fromRawRgba(rgba, frame.image.width, frame.image.height);
  } catch (_) {
    // 无引擎环境（纯 Dart 测试/CLI）或引擎解不了：落入下方纯 Dart 回退
  }

  // 纯 Dart image 包回退
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded != null) {
      return decoded;
    }
  } catch (e) {
    throw FormatException("无法解码图片（支持 JPG/PNG/WebP/BMP）: $e");
  }
  throw const FormatException("无法解码图片（支持 JPG/PNG/WebP/BMP）");
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
Future<(img.Image, Uint8List)> decodeForDisplay(
  Uint8List bytes, {
  int maxEdge = kDisplayMaxEdge,
}) async {
  final decoded = await decodeImageRobust(bytes);
  final display = await compute(encodeDisplayJpg, (decoded, maxEdge));
  return (decoded, display);
}

/// 重编码显示 JPEG（顶层函数供 compute 调用）
///
/// isolate 里跑：百万像素级缩放/编码同步执行会卡 UI 帧。
/// 用 JPEG 而非 PNG：同画质体积小一个量级，且 encodePng 的产物在
/// Impeller GLES 下纹理上传会静默失败（见 decodeForDisplay 注释）。
/// 缩小必须显式 average（盒式滤波）：copyResize 默认最近邻，降采样
/// 直接丢像素，高清原图（如小红书 5364px）缩到 2048 后细节大面积
/// 抹平，预览"明显发糊"（2026-11-05 模拟器实测，换 average 立清）。
Uint8List encodeDisplayJpg((img.Image, int) args) {
  final (image, maxEdge) = args;
  var display = image;
  final longEdge = image.width >= image.height ? image.width : image.height;
  if (longEdge > maxEdge) {
    final scale = maxEdge / longEdge;
    display = img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }
  return Uint8List.fromList(img.encodeJpg(display, quality: 92));
}

/// RGBA 原始字节 -> image 包 Image（拷贝进 ImageData）
///
/// 百万像素级逐像素 setPixelRgba 在主 isolate 同步跑实测冻结 ~0.4s
/// （2026-11-02 UI 线程探针 S1），入 compute；传 Uint8List 视图
/// （TypedData 可跨 isolate 直传）。web 上 compute 退化为同线程直跑，
/// 行为不变。
Future<img.Image> _fromRawRgba(ByteData rgba, int width, int height) {
  return compute(
    _pixelsFromRgba,
    _RawRgbaArgs(rgba.buffer.asUint8List(), width, height),
  );
}

class _RawRgbaArgs {
  final Uint8List rgba;
  final int width, height;
  const _RawRgbaArgs(this.rgba, this.width, this.height);
}

img.Image _pixelsFromRgba(_RawRgbaArgs a) {
  final out = img.Image(width: a.width, height: a.height);
  final data = a.rgba;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final i = (y * a.width + x) * 4;
      out.setPixelRgba(x, y, data[i], data[i + 1], data[i + 2], data[i + 3]);
    }
  }
  return out;
}
