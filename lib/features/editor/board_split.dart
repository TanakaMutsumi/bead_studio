import 'dart:ui' show Rect;

import '../../core/pattern_model.dart';

/// 分板模式纯函数（从编辑页抽出）：按底板边长把图案切块

/// 第 [index] 块板的格子范围（行优先编号，clamp 到图案边界）
Rect boardRectOf(PatternModel model, int boardSize, int index) {
  final across = (model.width / boardSize).ceil();
  final left = (index % across) * boardSize;
  final top = (index ~/ across) * boardSize;
  var right = left + boardSize;
  var bottom = top + boardSize;
  if (right > model.width) {
    right = model.width;
  }
  if (bottom > model.height) {
    bottom = model.height;
  }
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// 矩形范围内的用料统计（色 -> 颗数）
Map<int, int> boardCounts(PatternModel model, Rect r) {
  final counts = <int, int>{};
  for (var y = r.top.toInt(); y < r.bottom.toInt(); y++) {
    for (var x = r.left.toInt(); x < r.right.toInt(); x++) {
      final v = model.cell(x, y);
      if (v >= 0) {
        counts[v] = (counts[v] ?? 0) + 1;
      }
    }
  }
  return counts;
}
