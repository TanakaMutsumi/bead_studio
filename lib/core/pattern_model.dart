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
