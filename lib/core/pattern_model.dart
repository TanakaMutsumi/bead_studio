/// 图案数据模型：网格 + 调色板 id 映射 + 草稿序列化 + PNG 导出
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'palette.dart';

class PatternModel {
  final int width;

  ///< 网格列数
  final int height;

  ///< 网格行数
  final List<int> grid;

  ///< 扁平网格（行优先），值 = 调色板索引，-1 = 空格
  final List<String> paletteIds;

  ///< 生成时的调色板 id 顺序（草稿兼容）

  PatternModel({
    required this.width,
    required this.height,
    required this.grid,
    required this.paletteIds,
  });

  int get cellCount => width * height;

  /// 读格（越界返回 -1）
  int cell(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      return -1;
    }
    return grid[y * width + x];
  }

  /// 写格
  void setCell(int x, int y, int paletteIndex) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      return;
    }
    grid[y * width + x] = paletteIndex;
  }

  /// 油漆桶：从 (x,y) 出发把连通的同色区替换为 [target]，返回受影响格数
  int floodFill(int x, int y, int target) {
    final start = cell(x, y);
    if (start == target) {
      return 0;
    }
    var count = 0;
    final stack = <int>[y * width + x];
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      if (grid[i] != start) {
        continue;
      }
      grid[i] = target;
      count++;
      final cx = i % width, cy = i ~/ width;
      if (cx > 0) {
        stack.add(i - 1);
      }
      if (cx < width - 1) {
        stack.add(i + 1);
      }
      if (cy > 0) {
        stack.add(i - width);
      }
      if (cy < height - 1) {
        stack.add(i + width);
      }
    }
    return count;
  }

  /// 用料统计：调色板索引 -> 数量（仅统计非空格）
  Map<int, int> countByColor() {
    final counts = <int, int>{};
    for (final v in grid) {
      if (v >= 0) {
        counts[v] = (counts[v] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// 网格深拷贝（撤销栈用）
  List<int> copyGrid() => List<int>.of(grid);

  Map<String, dynamic> toJson() => {
    "version": 1,
    "width": width,
    "height": height,
    "grid": grid,
    "paletteIds": paletteIds,
  };

  factory PatternModel.fromJson(Map<String, dynamic> json) {
    return PatternModel(
      width: json["width"] as int,
      height: json["height"] as int,
      grid: (json["grid"] as List).cast<int>(),
      paletteIds: (json["paletteIds"] as List).cast<String>(),
    );
  }

  /// 导出 PNG：每格纯色块 + 细网格线 + 每 10 格粗线（拼易看行习惯）
  ///
  /// [cellPixels] 每格像素边长；[palette] 当前调色板
  Uint8List exportPng({int cellPixels = 16, BeadPalette? palette}) {
    final out = img.Image(
      width: width * cellPixels,
      height: height * cellPixels,
    );
    img.fillRect(
      out,
      x1: 0,
      y1: 0,
      x2: out.width - 1,
      y2: out.height - 1,
      color: img.ColorRgb8(255, 255, 255),
    );

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final v = grid[y * width + x];
        if (v < 0) {
          continue;
        }
        final c = palette != null && v < palette.colors.length
            ? palette.colors[v]
            : null;
        final color = c != null
            ? img.ColorRgb8(c.r, c.g, c.b)
            : img.ColorRgb8(220, 220, 220);
        img.fillRect(
          out,
          x1: x * cellPixels,
          y1: y * cellPixels,
          x2: (x + 1) * cellPixels - 1,
          y2: (y + 1) * cellPixels - 1,
          color: color,
        );
      }
    }

    // 细网格线
    for (var x = 0; x <= width; x++) {
      final major = x % 10 == 0;
      img.drawLine(
        out,
        x1: x * cellPixels,
        y1: 0,
        x2: x * cellPixels,
        y2: out.height - 1,
        color: major
            ? img.ColorRgb8(120, 120, 120)
            : img.ColorRgb8(200, 200, 200),
      );
    }
    for (var y = 0; y <= height; y++) {
      final major = y % 10 == 0;
      img.drawLine(
        out,
        x1: 0,
        y1: y * cellPixels,
        x2: out.width - 1,
        y2: y * cellPixels,
        color: major
            ? img.ColorRgb8(120, 120, 120)
            : img.ColorRgb8(200, 200, 200),
      );
    }

    return img.encodePng(out);
  }
}

/// 图案变换：左右/上下翻转 + 顺时针 90° 步数（先翻转后旋转）
///
/// 持久化保存原坐标系（作品文件不感知变换）；豆板会话与作品 meta.board
/// 记 rot/flipH/flipV 三参，进板时 applyTo 生成变换后快照供渲染/交互，
/// 保存进度时经 inverse 逆映射回原坐标（板设置/拼豆页共用）
class PatternTransform {
  final int rot;

  ///< 顺时针 90° 步数（0-3）
  final bool flipH;

  ///< 左右翻转（先于旋转执行）
  final bool flipV;

  ///< 上下翻转（先于旋转执行）

  const PatternTransform({this.rot = 0, this.flipH = false, this.flipV = false});

  bool get isIdentity => rot == 0 && !flipH && !flipV;

  /// 变换后网格尺寸（rot 为奇数时宽高互换）
  (int, int) sizeOf(int w, int h) => rot.isOdd ? (h, w) : (w, h);

  /// 原坐标 -> 变换后坐标（先翻转后顺时针旋转 rot×90°）
  (int, int) forward(int w, int h, int x, int y) {
    final x1 = flipH ? w - 1 - x : x;
    final y1 = flipV ? h - 1 - y : y;
    return switch (rot) {
      1 => (h - 1 - y1, x1),
      2 => (w - 1 - x1, h - 1 - y1),
      3 => (y1, w - 1 - x1),
      _ => (x1, y1),
    };
  }

  /// 变换后坐标 -> 原坐标（forward 的逆映射：先逆旋转后逆翻转）
  (int, int) inverse(int w, int h, int X, int Y) {
    final (x1, y1) = switch (rot) {
      1 => (Y, h - 1 - X),
      2 => (w - 1 - X, h - 1 - Y),
      3 => (w - 1 - Y, X),
      _ => (X, Y),
    };
    return (flipH ? w - 1 - x1 : x1, flipV ? h - 1 - y1 : y1);
  }

  /// 生成变换后模型（identity 零拷贝返回原模型）
  PatternModel applyTo(PatternModel m) {
    if (isIdentity) {
      return m;
    }
    final (w2, h2) = sizeOf(m.width, m.height);
    final grid = List<int>.filled(w2 * h2, -1);
    for (var y = 0; y < m.height; y++) {
      for (var x = 0; x < m.width; x++) {
        final (X, Y) = forward(m.width, m.height, x, y);
        grid[Y * w2 + X] = m.grid[y * m.width + x];
      }
    }
    return PatternModel(width: w2, height: h2, grid: grid, paletteIds: m.paletteIds);
  }
}
