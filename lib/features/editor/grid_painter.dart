/// 网格画布渲染器：格子填色 + 细网格线 + 每 10 格粗线
library;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/pattern_model.dart';

class GridPainter extends CustomPainter {
  final PatternModel model;
  final BeadPalette palette;
  final int? selectedColorIndex;

  ///< 当前绘画色（null = 未选色；仅参与重绘判定）
  final Rect? selectionRect;

  ///< 矩形选区（画布坐标，null = 无）
  final int? highlightIndex;

  ///< 拼装模式高亮色索引（null = 关闭；其余色降饱和显示）
  final Rect? boardRect;

  ///< 分板模式当前底板的格子范围（null = 关闭；板外格子大幅降透明）
  final Set<int>? placedCells;

  ///< 拼装已放格子（null = 关闭；半透明白罩 + 绿对勾）

  GridPainter({
    required this.model,
    required this.palette,
    required this.selectedColorIndex,
    this.selectionRect,
    this.highlightIndex,
    this.boardRect,
    this.placedCells,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 横纵分开算：画布尺寸由页面按图案宽高比适配（理论上相等，防比例
    // 失配时网格越界画布——底部横线被裁正是这么来的）
    final cellW = size.width / model.width;
    final cellH = size.height / model.height;
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
        var color = Color.fromARGB(255, c.r, c.g, c.b);
        // 拼装模式：非高亮色混入深灰降饱和，让目标色一眼可见
        if (highlightIndex != null && v != highlightIndex) {
          color = Color.lerp(
            color,
            const Color.fromARGB(255, 0x30, 0x30, 0x30),
            0.65,
          )!;
        }
        // 分板模式：当前底板外的格子大幅降透明
        final br = boardRect;
        final outsideBoard = br != null &&
            (x < br.left || x >= br.right || y < br.top || y >= br.bottom);
        if (outsideBoard) {
          color = color.withValues(alpha: 0.18);
        }
        gridPaint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(x * cellW, y * cellH, cellW, cellH),
          gridPaint,
        );
      }
    }

    // 网格线（每 10 格加粗，拼豆板数行习惯）
    for (var x = 0; x <= model.width; x++) {
      final p = (x * cellW);
      canvas.drawLine(
        Offset(p, 0),
        Offset(p, size.height),
        x % 10 == 0 ? majorLinePaint : linePaint,
      );
    }
    for (var y = 0; y <= model.height; y++) {
      final p = (y * cellH);
      canvas.drawLine(
        Offset(0, p),
        Offset(size.width, p),
        y % 10 == 0 ? majorLinePaint : linePaint,
      );
    }

    // 拼装已放格：半透明白罩（拼过的格视觉"消掉"）+ 绿对勾
    final placed = placedCells;
    if (placed != null && placed.isNotEmpty) {
      final veil = Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..style = PaintingStyle.fill;
      final check = Paint()
        ..color = const Color(0xFF2E7D32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      for (final i in placed) {
        if (i < 0 || i >= model.grid.length || model.grid[i] < 0) {
          continue; // 编辑后失效的进度索引跳过
        }
        final x = i % model.width, y = i ~/ model.width;
        final rect = Rect.fromLTWH(x * cellW, y * cellH, cellW, cellH);
        canvas.drawRect(rect, veil);
        final cx = rect.center.dx, cy = rect.center.dy;
        canvas.drawLine(
          Offset(cx - cellW * 0.22, cy),
          Offset(cx - cellW * 0.05, cy + cellH * 0.2),
          check,
        );
        canvas.drawLine(
          Offset(cx - cellW * 0.05, cy + cellH * 0.2),
          Offset(cx + cellW * 0.28, cy - cellH * 0.2),
          check,
        );
      }
    }

    // 矩形选区高亮
    final sel = selectionRect;
    if (sel != null) {
      final fill = Paint()
        ..color = Colors.blue.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      final border = Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRect(sel, fill);
      canvas.drawRect(sel, border);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) {
    return oldDelegate.model != model ||
        oldDelegate.selectedColorIndex != selectedColorIndex ||
        oldDelegate.palette != palette ||
        oldDelegate.selectionRect != selectionRect ||
        oldDelegate.highlightIndex != highlightIndex ||
        oldDelegate.boardRect != boardRect ||
        oldDelegate.placedCells != placedCells;
  }
}
