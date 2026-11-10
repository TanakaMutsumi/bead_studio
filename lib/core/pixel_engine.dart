/// 像素引擎：图片 -> 拼豆网格的完整转换管线
///
/// 流程：解码 -> 中心裁剪成正方形 -> 最近邻缩放到板尺寸 -> 量化
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'decode_image.dart';
import 'palette.dart';
import 'pattern_model.dart';
import 'quantizer.dart';

/// 源图裁剪区域（像素坐标）——image 4.x 无 Rect 公共类，自定义轻量版
class SourceRect {
  final int x, y, width, height;
  const SourceRect(this.x, this.y, this.width, this.height);
}

class PixelEngine {
  final BeadPalette palette;

  PixelEngine(this.palette);

  /// 图片字节 -> 拼豆图案
  ///
  /// [boardSize] 板边长（如 26/29/52/78）
  /// [style] 转换风格（blocks = 色块统一，detail = 保留细节）
  /// [sourceRect] 可选裁剪区域（像素坐标，null = 取中心最大正方形）
  ///
  /// 解码走 decodeImageRobust（Skia 优先 + image 包回退，像素口径=libjpeg-turbo）
  Future<PatternModel> convert({
    required Uint8List bytes,
    required int boardSize,
    ConvertStyle style = ConvertStyle.blocks,
    SourceRect? sourceRect,
  }) async {
    final decoded = await decodeImageRobust(bytes);

    // 1. 裁剪（未指定则取中心最大正方形）
    final rect = sourceRect ?? _centerSquare(decoded);
    final cropped = img.copyCrop(
      decoded,
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    );

    // 2. 盒式均值缩放到板尺寸：每格取源区域平均色，从源头抑制
    // 采样噪声（最近邻采样在大比例缩小时把单像素噪声直接带进网格）
    final resized = img.copyResize(
      cropped,
      width: boardSize,
      height: boardSize,
      interpolation: img.Interpolation.average,
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
      style: style,
    );

    return PatternModel(
      width: boardSize,
      height: boardSize,
      grid: grid,
      paletteIds: [for (final c in palette.colors) c.id],
    );
  }

  /// 取中心最大正方形
  SourceRect _centerSquare(img.Image image) {
    final side = image.width < image.height ? image.width : image.height;
    final x = (image.width - side) ~/ 2;
    final y = (image.height - side) ~/ 2;
    return SourceRect(x, y, side, side);
  }
}
