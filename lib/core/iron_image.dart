/// 熨烫模拟：圆豆网格 -> 熔融成片效果的离屏合成（image 包，纯 Dart）
///
/// 物理直觉：熨斗加热后豆子软化，颜色向间隙流淌并互相融合，
/// 冷却后形成一体成片——用「铺豆色圆点 -> 高斯模糊扩散 -> 中心二次叠色」三步模拟。
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'palette.dart';
import 'pattern_model.dart';

class IronSimulator {
  /// 熨烫后的成片图（豆色已融合，间隙被熔料填充）
  ///
  /// [cellPixels] 每格像素边长（8-16 即可，太大合成变慢）
  static img.Image render(PatternModel model, BeadPalette palette, {int cellPixels = 12}) {
    final w = model.width * cellPixels;
    final h = model.height * cellPixels;
    var canvas = img.Image(width: w, height: h);
    img.fillRect(canvas, x1: 0, y1: 0, x2: w - 1, y2: h - 1, color: img.ColorRgb8(244, 243, 240));

    // 1. 铺豆色圆点（模拟豆子受热前的形状）
    final beadRadius = (cellPixels * 0.48).round();
    _stampBeads(canvas, model, palette, beadRadius, cellPixels);

    // 2. 高斯模糊 = 热熔扩散（颜色向间隙流淌）
    canvas = img.gaussianBlur(canvas, radius: (cellPixels * 0.38).round().clamp(1, 8));

    // 3. 中心二次叠色（熔融后豆心颜色仍最浓，恢复主体浓度）
    _stampBeads(canvas, model, palette, (beadRadius * 0.92).round(), cellPixels);

    return canvas;
  }

  /// 未熨烫的成品片（圆豆阵列 + 板底 + 钉点，可导出的展示图）
  static img.Image renderFlat(PatternModel model, BeadPalette palette, {int cellPixels = 12}) {
    final w = model.width * cellPixels;
    final h = model.height * cellPixels;
    final canvas = img.Image(width: w, height: h);
    img.fillRect(canvas, x1: 0, y1: 0, x2: w - 1, y2: h - 1, color: img.ColorRgb8(238, 238, 235));

    final beadRadius = (cellPixels * 0.45).round();
    final dotRadius = (cellPixels * 0.09).ceil().clamp(1, 3);

    for (var y = 0; y < model.height; y++) {
      for (var x = 0; x < model.width; x++) {
        final cx = x * cellPixels + cellPixels ~/ 2;
        final cy = y * cellPixels + cellPixels ~/ 2;
        final v = model.cell(x, y);
        final c = v >= 0 && v < palette.colors.length ? palette.colors[v] : null;
        if (c == null) {
          // 空格：画板面钉点
          _fillCircle(canvas, cx, cy, dotRadius, 210, 210, 208);
          continue;
        }
        _fillCircle(canvas, cx, cy, beadRadius, c.r, c.g, c.b);
        // 左上高光点（圆豆的塑料反光）
        if (cellPixels >= 10) {
          final hx = cx - beadRadius ~/ 3;
          final hy = cy - beadRadius ~/ 3;
          final hr = (beadRadius * 0.3).round().clamp(1, beadRadius);
          _blendCircle(canvas, hx, hy, hr, 255, 255, 255, 110);
        }
      }
    }
    return canvas;
  }

  /// 编码 PNG
  static Uint8List encode(img.Image image) => img.encodePng(image);

  /// 按图案尺寸自适应格边长（大图降采样保证合成速度）
  static int cellPixelsFor(int width) {
    if (width <= 32) {
      return 16;
    }
    if (width <= 52) {
      return 12;
    }
    return 8;
  }

  /// 铺一层豆色圆点
  static void _stampBeads(img.Image canvas, PatternModel model, BeadPalette palette, int radius, int cellPixels) {
    if (radius <= 0) {
      return;
    }
    for (var y = 0; y < model.height; y++) {
      for (var x = 0; x < model.width; x++) {
        final v = model.cell(x, y);
        if (v < 0 || v >= palette.colors.length) {
          continue;
        }
        final c = palette.colors[v];
        _fillCircle(canvas, x * cellPixels + cellPixels ~/ 2, y * cellPixels + cellPixels ~/ 2, radius, c.r, c.g, c.b);
      }
    }
  }

  /// 实心圆（无抗锯齿，速度优先；模糊步骤会柔化边缘）
  static void _fillCircle(img.Image image, int cx, int cy, int r, int red, int green, int blue) {
    final r2 = r * r;
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy <= r2) {
          image.setPixelRgba(cx + dx, cy + dy, red, green, blue, 255);
        }
      }
    }
  }

  /// 半透明圆（alpha 混合，画高光用）
  static void _blendCircle(img.Image image, int cx, int cy, int r, int red, int green, int blue, int alpha) {
    final r2 = r * r;
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy > r2) {
          continue;
        }
        final px = image.getPixel(cx + dx, cy + dy);
        final nr = (px.r.toInt() * (255 - alpha) + red * alpha) ~/ 255;
        final ng = (px.g.toInt() * (255 - alpha) + green * alpha) ~/ 255;
        final nb = (px.b.toInt() * (255 - alpha) + blue * alpha) ~/ 255;
        image.setPixelRgba(cx + dx, cy + dy, nr, ng, nb, 255);
      }
    }
  }
}
