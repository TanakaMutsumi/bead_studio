/// 量化引擎：把任意 RGB 像素映射到有限的珠子调色板
///
/// 抖动核（DitherKernel）：
/// - none：每像素独立取最近色，色块干净但渐变断层
/// - floydSteinberg：7/16 3/16 5/16 1/16 误差扩散，渐变自然
/// - atkinson：6 邻域各 1/8，扩散更强、图案更亮更均匀
/// - ordered：4×4 Bayer 有序抖动，无误差累积、风格化网点
library;

import 'dart:math' as math;

import 'palette.dart';

/// 抖动核类型
enum DitherKernel { none, floydSteinberg, atkinson, ordered }

/// 把 RGB 转 CIE Lab（人眼感知较均匀的空间，匹配效果优于 RGB 距离）
List<double> _rgbToLab(int r, int g, int b) {
  // sRGB -> 线性化
  double f(num c) {
    final v = c / 255.0;
    return v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final lr = f(r), lg = f(g), lb = f(b);

  // 线性 RGB -> XYZ (D65)
  var x = lr * 0.4124 + lg * 0.3576 + lb * 0.1805;
  var y = lr * 0.2126 + lg * 0.7152 + lb * 0.0722;
  var z = lr * 0.0193 + lg * 0.1192 + lb * 0.9505;

  // 归一化到 D65 白点
  x /= 0.95047;
  z /= 1.08883;

  double pivot(double t) => t > 0.008856
      ? math.pow(t, 1.0 / 3.0).toDouble()
      : 7.787 * t + 16.0 / 116.0;

  final fx = pivot(x), fy = pivot(y), fz = pivot(z);

  return [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)];
}

/// 4×4 Bayer 阈值矩阵（值域 0..15）
const _bayer4 = [
  0, 8, 2, 10, //
  12, 4, 14, 6, //
  3, 11, 1, 9, //
  15, 7, 13, 5, //
];

/// 量化器
class Quantizer {
  final BeadPalette palette;
  late final List<List<double>> _labCache = [
    for (final c in palette.colors) _rgbToLab(c.r, c.g, c.b),
  ];

  Quantizer(this.palette);

  /// 单个 RGB 找最近调色板索引（Lab 距离）
  int nearestIndex(int r, int g, int b) =>
      _nearest(_rgbToLab(r, g, b), null).$1;

  /// 在候选索引子集内找最近色，返回 (索引, Lab 距离平方)（图纸还原限色识别用）
  ///
  /// [candidates] 为 null 时搜全表；调用方可用距离平方做空白判定
  (int, double) nearestWithin(int r, int g, int b, Set<int>? candidates) {
    return _nearest(_rgbToLab(r, g, b), candidates);
  }

  /// 在候选索引子集内找最近色（限制色数重量化用），candidates 为 null 时搜全表
  (int, double) _nearest(List<double> lab, Set<int>? candidates) {
    var best = -1;
    var bestDist = double.infinity;
    for (var i = 0; i < _labCache.length; i++) {
      if (candidates != null && !candidates.contains(i)) {
        continue;
      }
      final p = _labCache[i];
      final dl = lab[0] - p[0];
      final da = lab[1] - p[1];
      final db = lab[2] - p[2];
      final d = dl * dl + da * da + db * db;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best < 0 ? (0, bestDist) : (best, bestDist);
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
    DitherKernel kernel = DitherKernel.none,
  }) {
    final n = width * height;
    final result = List<int>.filled(n, 0);

    switch (kernel) {
      case DitherKernel.none:
      case DitherKernel.ordered:
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final i = y * width + x;
            if (kernel == DitherKernel.ordered) {
              // 有序抖动：按 Bayer 矩阵给像素加确定性偏移后再取最近色
              final t = (_bayer4[(y & 3) * 4 + (x & 3)] + 0.5) / 16.0 - 0.5;
              const spread = 48.0;
              result[i] = nearestIndex(
                (pixelsR[i] + t * spread).round().clamp(0, 255),
                (pixelsG[i] + t * spread).round().clamp(0, 255),
                (pixelsB[i] + t * spread).round().clamp(0, 255),
              );
            } else {
              result[i] = nearestIndex(pixelsR[i], pixelsG[i], pixelsB[i]);
            }
          }
        }
        return result;

      case DitherKernel.floydSteinberg:
      case DitherKernel.atkinson:
        return _diffuse(pixelsR, pixelsG, pixelsB, width, height, kernel);
    }
  }

  /// 误差扩散类抖动（FS / Atkinson）
  List<int> _diffuse(
    List<int> pixelsR,
    List<int> pixelsG,
    List<int> pixelsB,
    int width,
    int height,
    DitherKernel kernel,
  ) {
    final n = width * height;
    final result = List<int>.filled(n, 0);
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

        if (kernel == DitherKernel.floydSteinberg) {
          diffuse(1, 0, 7 / 16);
          diffuse(-1, 1, 3 / 16);
          diffuse(0, 1, 5 / 16);
          diffuse(1, 1, 1 / 16);
        } else {
          // Atkinson：6 邻域各 1/8（余下 1/4 误差丢弃，整体更亮更平滑）
          diffuse(1, 0, 1 / 8);
          diffuse(2, 0, 1 / 8);
          diffuse(-1, 1, 1 / 8);
          diffuse(0, 1, 1 / 8);
          diffuse(1, 1, 1 / 8);
          diffuse(0, 2, 1 / 8);
        }
      }
    }
    return result;
  }

  /// 限制色数：保留出现频率最高的 [n] 色，其余格映射到保留色中 Lab 最近者
  ///
  /// 返回新网格（不修改原网格）；空格(-1)不受影响
  List<int> limitColors(List<int> grid, int n) {
    // 1) 频率统计
    final freq = <int, int>{};
    for (final v in grid) {
      if (v >= 0) {
        freq[v] = (freq[v] ?? 0) + 1;
      }
    }
    if (n >= freq.length) {
      return List<int>.of(grid);
    }

    // 2) 保留 top-n（并列时索引小者优先，结果稳定）
    final sorted = freq.keys.toList()
      ..sort((a, b) {
        final d = freq[b]! - freq[a]!;
        return d != 0 ? d : a - b;
      });
    final keep = sorted.take(n).toSet();

    // 3) 其余色映射到保留色最近者（同色统一映射，缓存避免重复计算）
    final mapping = <int, int>{};
    for (final v in freq.keys.where((k) => !keep.contains(k))) {
      final c = palette.colors[v];
      mapping[v] = _nearest(_rgbToLab(c.r, c.g, c.b), keep).$1;
    }

    return [
      for (final v in grid) v < 0 ? v : (keep.contains(v) ? v : mapping[v]!),
    ];
  }
}
