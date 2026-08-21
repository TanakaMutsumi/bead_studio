/// 网格画布渲染器：格子填色 + 细网格线 + 每 10 格粗线
library;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/pattern_model.dart';

class GridPainter extends CustomPainter {
  final PatternModel model;
  final BeadPalette palette;
  final int selectedColorIndex; ///< 当前选中色（画布上描高亮框提示）

  GridPainter({
    required this.model,
    required this.palette,
    required this.selectedColorIndex,
    Listenable? repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / model.width;
    final gridPaint = Paint()..style = PaintingStyle.fill;
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = Colors.black26;
    final majorLinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.black54;

    for (var y = 0; y < model.height; y++) {
      for (var x = 0; x < model.width; x++) {
        final v = model.grid[y * model.width + x];
        if (v < 0) {
          continue; // 空格留白
        }
        final c = v < palette.colors.length ? palette.colors[v] : null;
        if (c == null) {
          continue;
        }
        gridPaint.color = Color.fromARGB(255, c.r, c.g, c.b);
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), gridPaint);
      }
    }

    // 网格线（每 10 格加粗，拼豆板数行习惯）
    for (var x = 0; x <= model.width; x++) {
      final p = (x * cell);
      canvas.drawLine(Offset(p, 0), Offset(p, size.height), x % 10 == 0 ? majorLinePaint : linePaint);
    }
    for (var y = 0; y <= model.height; y++) {
      final p = (y * cell);
      canvas.drawLine(Offset(0, p), Offset(size.width, p), y % 10 == 0 ? majorLinePaint : linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) {
    return oldDelegate.model != model ||
        oldDelegate.selectedColorIndex != selectedColorIndex ||
        oldDelegate.palette != palette;
  }
}
