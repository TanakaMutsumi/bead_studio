/// 量化引擎：把任意 RGB 像素映射到有限的珠子调色板
///
/// 两种模式：
/// - 最近邻（无抖动）：每像素独立取 Lab 空间最近色，色块干净但渐变区会有断层
/// - Floyd–Steinberg 抖动：误差扩散，渐变过渡自然，远看更接近原图
library;

import 'dart:math' as math;

import 'palette.dart';

/// 把 RGB 转 CIE Lab（人眼感知较均匀的空间，匹配效果优于 RGB 距离）
List<double> _rgbToLab(int r, int g, int b) {
  // sRGB -> 线性化
  double f(num c) {
    final v = c / 255.0;
    return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final lr = f(r), lg = f(g), lb = f(b);

  // 线性 RGB -> XYZ (D65)
  var x = lr * 0.4124 + lg * 0.3576 + lb * 0.1805;
  var y = lr * 0.2126 + lg * 0.7152 + lb * 0.0722;
  var z = lr * 0.0193 + lg * 0.1192 + lb * 0.9505;

  // 归一化到 D65 白点
  x /= 0.95047;
  z /= 1.08883;

  double pivot(double t) => t > 0.008856 ? math.pow(t, 1.0 / 3.0).toDouble() : 7.787 * t + 16.0 / 116.0;

  final fx = pivot(x), fy = pivot(y), fz = pivot(z);

  return [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)];
}

/// 预计算的调色板 Lab 表
class _PaletteLab {
  final List<List<double>> labs;

  _PaletteLab(BeadPalette palette)
      : labs = [
          for (final c in palette.colors) _rgbToLab(c.r, c.g, c.b),
        ];
}

/// 量化器
class Quantizer {
  final BeadPalette palette;
  late final _PaletteLab _labCache = _PaletteLab(palette);

  Quantizer(this.palette);

  /// 单个 RGB 找最近调色板索引（Lab 距离）
  int nearestIndex(int r, int g, int b) {
    final lab = _rgbToLab(r, g, b);
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < _labCache.labs.length; i++) {
      final p = _labCache.labs[i];
      final dl = lab[0] - p[0];
      final da = lab[1] - p[1];
      final db = lab[2] - p[2];
      final d = dl * dl + da * da + db * db;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// 整图量化（调用方保证 img 尺寸已是目标网格尺寸）
  ///
  /// 返回扁平网格（行优先），值为调色板索引
  List<int> quantizePixels({
    required List<int> pixelsR,
    required List<int> pixelsG,
    required List<int> pixelsB,
    required int width,
    required int height,
    bool dither = false,
  }) {
    final n = width * height;
    final result = List<int>.filled(n, 0);

    if (!dither) {
      for (var i = 0; i < n; i++) {
        result[i] = nearestIndex(pixelsR[i], pixelsG[i], pixelsB[i]);
      }
      return result;
    }

    // Floyd–Steinberg：对 RGB 通道各自扩散误差
    final er = List<double>.filled(n, 0);
    final eg = List<double>.filled(n, 0);
    final eb = List<double>.filled(n, 0);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final sr = (pixelsR[i] + er[i]).round().clamp(0, 255);
        final sg = (pixelsG[i] + eg[i]).round().clamp(0, 255);
        final sb = (pixelsB[i] + eb[i]).round().clamp(0, 255);

        final idx = nearestIndex(sr, sg, sb);
        result[i] = idx;

        final c = palette.colors[idx];
        final dr = sr - c.r.toDouble();
        final dg = sg - c.g.toDouble();
        final db = sb - c.b.toDouble();

        void diffuse(int dx, int dy, double w) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= width || ny >= height) {
            return;
          }
          final j = ny * width + nx;
          er[j] += dr * w;
          eg[j] += dg * w;
          eb[j] += db * w;
        }

        diffuse(1, 0, 7 / 16);
        diffuse(-1, 1, 3 / 16);
        diffuse(0, 1, 5 / 16);
        diffuse(1, 1, 1 / 16);
      }
    }
    return result;
  }
}
