/// 量化引擎：把任意 RGB 像素映射到有限的珠子调色板
///
/// 转换风格（ConvertStyle）：
/// - blocks：色块统一（默认）——保边平滑 + 量化 + 近似色统一 + 孤立点清除，
///   相近颜色融合成整块，适合照片/插画。
/// - detail：仅量化，保留微小色差与细节（仍做近似色统一去重复色），适合线稿/像素画。
///
/// 背景：291 色 MARD 色卡里 174 色的最近邻 ΔE<8（近重复色密集），逐像素独立
/// 最近色量化必然在色块内产生椒盐状孤立色点；经典误差扩散抖动（FS/Atkinson/
/// 有序）实测孤立率反而比不抖更高（v0.2 前基线：52 板 16.9%→29.7%/21.2%/44.1%），
/// 已移除。
library;

import 'dart:math' as math;

import 'palette.dart';

/// 图片转换风格
enum ConvertStyle { blocks, detail }

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

/// Lab 色差（欧氏距离 = ΔE76）
double _de(List<double> a, List<double> b) {
  final dl = a[0] - b[0], da = a[1] - b[1], db = a[2] - b[2];
  return math.sqrt(dl * dl + da * da + db * db);
}

// ==================== 可调参数 ====================

/// 保边平滑：与邻格色差低于此值才互相融合（真实边缘 >14 不混合）
const _smoothGateDe = 14.0;

/// 保边平滑迭代次数
const _smoothPasses = 2;

/// 近似色统一：两调色板色 ΔE 低于此值视为视觉重复色，合并到高频者
const _unifyDe = 10.0;

/// 孤立点清除：小连通域与其周围主色 ΔE 低于此值才并入
/// （高于此值 = 高对比小细节如眼睛高光，保留）
///
/// 单颗连通域最可能是噪声，门槛放宽到 [_despeckleGateSingleDe]；
/// 2 颗以上更可能是刻意细节，用更保守的 [_despeckleGateDe]
const _despeckleGateDe = 25.0;
const _despeckleGateSingleDe = 35.0;

/// 孤立点清除的最大连通域尺寸，随板尺寸放大（26/29→2，52→3，78→4）
int _maxSpeckSize(int boardSize) => 1 + (boardSize - 1) ~/ 20;

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
    ConvertStyle style = ConvertStyle.blocks,
  }) {
    if (style == ConvertStyle.blocks) {
      // 色块统一：先保边平滑把块内近色融合，再量化
      _smoothPlanes(pixelsR, pixelsG, pixelsB, width, height);
    }

    final n = width * height;
    final result = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      result[i] = nearestIndex(pixelsR[i], pixelsG[i], pixelsB[i]);
    }

    // 近似色统一（两种风格都做：视觉重复色并存只添乱）
    var grid = unifyNearColors(result);

    if (style == ConvertStyle.blocks) {
      // 孤立点清除：消灭残余的小色斑
      grid = despeckle(grid, width, height, _maxSpeckSize(width));
    }
    return grid;
  }

  /// 保边平滑（原地修改）：把与 8 邻域 ΔE≤[_smoothGateDe] 的近色加权融合
  ///
  /// 中心格权重 2、每个近色邻格权重 1，迭代 [_smoothPasses] 轮；
  /// 色差大于门槛的邻格视为真实边缘不参与，边缘不糊
  void _smoothPlanes(
    List<int> pixelsR,
    List<int> pixelsG,
    List<int> pixelsB,
    int width,
    int height,
  ) {
    final n = width * height;
    var r = [for (final v in pixelsR) v.toDouble()];
    var g = [for (final v in pixelsG) v.toDouble()];
    var b = [for (final v in pixelsB) v.toDouble()];

    for (var pass = 0; pass < _smoothPasses; pass++) {
      final lab = [
        for (var i = 0; i < n; i++) _rgbToLab(r[i].round(), g[i].round(), b[i].round()),
      ];
      final nr = List<double>.filled(n, 0);
      final ng = List<double>.filled(n, 0);
      final nb = List<double>.filled(n, 0);

      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = y * width + x;
          var wsum = 2.0;
          var sr = 2.0 * r[i], sg = 2.0 * g[i], sb = 2.0 * b[i];
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              if (dx == 0 && dy == 0) continue;
              final nx = x + dx, ny = y + dy;
              if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
              final j = ny * width + nx;
              if (_de(lab[i], lab[j]) > _smoothGateDe) continue;
              wsum += 1;
              sr += r[j];
              sg += g[j];
              sb += b[j];
            }
          }
          nr[i] = sr / wsum;
          ng[i] = sg / wsum;
          nb[i] = sb / wsum;
        }
      }
      r = nr;
      g = ng;
      b = nb;
    }

    for (var i = 0; i < n; i++) {
      pixelsR[i] = r[i].round().clamp(0, 255);
      pixelsG[i] = g[i].round().clamp(0, 255);
      pixelsB[i] = b[i].round().clamp(0, 255);
    }
  }

  /// 近似色统一：ΔE<[_unifyDe] 的调色板色互为视觉重复色，
  /// 全部并入本图中使用频率更高的那一方（传递链解析到最终代表色）
  ///
  /// 返回新网格（不修改入参）；空格(-1)不受影响
  List<int> unifyNearColors(List<int> grid) {
    // 1) 频率统计
    final freq = <int, int>{};
    for (final v in grid) {
      if (v >= 0) freq[v] = (freq[v] ?? 0) + 1;
    }
    if (freq.length < 2) return List<int>.of(grid);

    // 2) 低频 -> 高频映射（按频率升序处理，目标必已定稿，无环）
    final byUsageAsc = freq.keys.toList()
      ..sort((a, b) {
        final d = freq[a]! - freq[b]!;
        return d != 0 ? d : a - b;
      });
    final mapping = <int, int>{};
    for (final v in byUsageAsc) {
      var best = -1;
      var bestDe = _unifyDe;
      for (final e in byUsageAsc) {
        if (freq[e]! <= freq[v]!) continue; // 只并入更高频者
        final de = _de(_labCache[v], _labCache[e]);
        if (de < bestDe) {
          bestDe = de;
          best = e;
        }
      }
      // 传递链：目标的映射已定稿（其频率更高、处理更早）
      mapping[v] = best < 0 ? v : (mapping[best] ?? best);
    }

    // 3) 应用
    return [for (final v in grid) v < 0 ? v : (mapping[v] ?? v)];
  }

  /// 孤立点清除：尺寸 ≤[maxSize] 的同色连通域（8 邻接），若环带近色并票后
  /// 有过半阵营且连通域色与该阵营代表色 ΔE≤[_despeckleGateDe]（单颗放宽到
  /// [_despeckleGateSingleDe]），整块并入阵营；高对比小细节（眼睛高光）与
  /// 真实边缘格（环带两阵营色差大、无多数）被保留
  ///
  /// 返回新网格（不修改入参）
  List<int> despeckle(List<int> grid, int width, int height, int maxSize) {
    final n = grid.length;
    final compId = List<int>.filled(n, -1);
    final compCells = <List<int>>[];
    final compColor = <int>[];

    // 1) 连通域标记（8 邻接同索引）
    for (var i = 0; i < n; i++) {
      if (compId[i] >= 0 || grid[i] < 0) continue;
      final id = compCells.length;
      final cells = <int>[i];
      compId[i] = id;
      var head = 0;
      while (head < cells.length) {
        final cur = cells[head++];
        final cx = cur % width, cy = cur ~/ width;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = cx + dx, ny = cy + dy;
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
            final j = ny * width + nx;
            if (compId[j] >= 0 || grid[j] != grid[i]) continue;
            compId[j] = id;
            cells.add(j);
          }
        }
      }
      compCells.add(cells);
      compColor.add(grid[i]);
    }

    // 2) 小连通域并入环带主色
    final out = List<int>.of(grid);
    final ringVotes = <int, int>{};
    for (var id = 0; id < compCells.length; id++) {
      final cells = compCells[id];
      if (cells.length > maxSize) continue;

      ringVotes.clear();
      var ringSize = 0;
      for (final c in cells) {
        final cx = c % width, cy = c ~/ width;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = cx + dx, ny = cy + dy;
            if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
            final j = ny * width + nx;
            if (compId[j] == id || grid[j] < 0) continue;
            ringVotes[grid[j]] = (ringVotes[grid[j]] ?? 0) + 1;
            ringSize++;
          }
        }
      }
      if (ringVotes.isEmpty) continue;

      // 环带近色并票：ΔE≤15 的环带色算同一阵营再计多数。
      // 渐变过渡带的孤立点（环带是两三种近似色、票数互相分裂）由此可清；
      // 真实边缘（环带两阵营色差大，如描边两侧的背景色/头发色）仍无多数，保留
      final entries = ringVotes.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final groups = <List<int>>[];
      final groupVotes = <int>[];
      for (final e in entries) {
        var placed = false;
        for (var gi = 0; gi < groups.length; gi++) {
          if (_de(_labCache[groups[gi].first], _labCache[e.key]) <= 15) {
            groups[gi].add(e.key);
            groupVotes[gi] += e.value;
            placed = true;
            break;
          }
        }
        if (!placed) {
          groups.add([e.key]);
          groupVotes.add(e.value);
        }
      }
      var bestG = 0;
      for (var gi = 1; gi < groups.length; gi++) {
        if (groupVotes[gi] > groupVotes[bestG]) bestG = gi;
      }
      if (groupVotes[bestG] * 2 <= ringSize) continue;

      // 并入阵营中与连通域色最近的成员（渐变方向自然）
      final dom = _nearest(
        _labCache[compColor[id]],
        groups[bestG].toSet(),
      ).$1;

      final gate =
          cells.length == 1 ? _despeckleGateSingleDe : _despeckleGateDe;
      if (_de(_labCache[compColor[id]], _labCache[dom]) <= gate) {
        for (final c in cells) {
          out[c] = dom;
        }
      }
    }
    return out;
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
