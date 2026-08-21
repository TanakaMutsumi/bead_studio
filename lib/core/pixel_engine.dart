/// 像素引擎：图片 -> 拼豆网格的完整转换管线
///
/// 流程：解码 -> 中心裁剪成正方形 -> 最近邻缩放到板尺寸 -> 量化
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'palette.dart';
import 'pattern_model.dart';
import 'quantizer.dart';

class PixelEngine {
  final BeadPalette palette;

  PixelEngine(this.palette);

  /// 图片字节 -> 拼豆图案
  ///
  /// [boardSize] 板边长（如 26/29/52/78）
  /// [dither] 是否开启 Floyd–Steinberg 抖动
  /// [sourceRect] 可选裁剪区域（像素坐标，null = 整图）
  PatternModel convert({
    required Uint8List bytes,
    required int boardSize,
    bool dither = false,
    img.Rect? sourceRect,
  }) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException("无法解码图片（支持 JPG/PNG/WebP/BMP）");
    }

    // 1. 裁剪（未指定则取中心最大正方形）
    final rect = sourceRect ?? _centerSquare(decoded);
    final cropped = img.copyCrop(decoded, x: rect.x, y: rect.y, width: rect.width, height: rect.height);

    // 2. 最近邻缩放到板尺寸（避免双线性糊边）
    final resized = img.copyResize(
      cropped,
      width: boardSize,
      height: boardSize,
      interpolation: img.Interpolation.nearest,
    );

    // 3. 拆通道
    final n = boardSize * boardSize;
    final pr = List<int>.filled(n, 0);
    final pg = List<int>.filled(n, 0);
    final pb = List<int>.filled(n, 0);
    for (var y = 0; y < boardSize; y++) {
      for (var x = 0; x < boardSize; x++) {
        final p = resized.getPixel(x, y);
        final i = y * boardSize + x;
        pr[i] = p.r.toInt();
        pg[i] = p.g.toInt();
        pb[i] = p.b.toInt();
      }
    }

    // 4. 量化
    final grid = Quantizer(palette).quantizePixels(
      pixelsR: pr,
      pixelsG: pg,
      pixelsB: pb,
      width: boardSize,
      height: boardSize,
      dither: dither,
    );

    return PatternModel(width: boardSize, height: boardSize, grid: grid, paletteIds: [for (final c in palette.colors) c.id]);
  }

  /// 取中心最大正方形
  img.Rect _centerSquare(img.Image image) {
    final side = image.width < image.height ? image.width : image.height;
    final x = (image.width - side) ~/ 2;
    final y = (image.height - side) ~/ 2;
    return img.Rect(x, y, x + side, y + side);
  }
}
