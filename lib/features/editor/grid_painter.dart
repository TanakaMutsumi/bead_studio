/// 网格画布渲染器：格子填色 + 细网格线 + 每 10 格粗线
library;

import 'dart:math' as math;

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

  ///< 高亮色索引（复核页复核色同款：null = 关闭；其余色降饱和显示）
  final bool showGrid;

  ///< 画网格线（细线+每10格加粗）。编辑/复核画布开；缩略图关——
  ///< 小尺寸下格线密成噪点遮图案（2026-11-12 需求：作品原图缩略图去格线）
  final bool outline;

  ///< 画浅黑外框（缩略图配 showGrid:false 用：格线去掉后以一圈
  ///< black38 细框交代图案边界）。底色本就不画（空格透明），缩略图
  ///< 即「纯色块 + 浅黑框 + 透明底」

  GridPainter({
    required this.model,
    required this.palette,
    required this.selectedColorIndex,
    this.selectionRect,
    this.highlightIndex,
    this.showGrid = true,
    this.outline = false,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // contain 自适应：画布与图案宽高比失配时（缩略图统一方形盒）按短边
    // 缩放并居中——各作品无论纵横比都缩到同一视觉尺寸，浅黑外框随之
    // 大小一致（2026-11-12 需求：自适应缩放到统一效果）。画布比例匹配
    //（编辑/复核画布按图案宽高比适配）时偏移为零，行为与旧版全同
    final cellW = size.width / model.width;
    final cellH = size.height / model.height;
    final cell = math.min(cellW, cellH);
    final offX = (size.width - model.width * cell) / 2;
    final offY = (size.height - model.height * cell) / 2;
    final patW = model.width * cell;
    final patH = model.height * cell;
    canvas.save();
    canvas.translate(offX, offY);

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
        // 高亮聚焦：非高亮色混入深灰降饱和，让目标色一眼可见
        if (highlightIndex != null && v != highlightIndex) {
          color = Color.lerp(
            color,
            const Color.fromARGB(255, 0x30, 0x30, 0x30),
            0.65,
          )!;
        }
        gridPaint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          gridPaint,
        );
      }
    }

    // 网格线（每 10 格加粗，拼豆板数行习惯）；缩略图不画（见 showGrid 注释）
    if (showGrid) {
      for (var x = 0; x <= model.width; x++) {
        final p = (x * cell);
        canvas.drawLine(
          Offset(p, 0),
          Offset(p, patH),
          x % 10 == 0 ? majorLinePaint : linePaint,
        );
      }
      for (var y = 0; y <= model.height; y++) {
        final p = (y * cell);
        canvas.drawLine(
          Offset(0, p),
          Offset(patW, p),
          y % 10 == 0 ? majorLinePaint : linePaint,
        );
      }
    } else if (outline) {
      // 缩略图外框：去格线后用一圈浅黑细框交代图案边界（贴图案实际
      // 矩形，contain 缩放下各作品框大小统一）
      canvas.drawRect(
        Offset.zero & Size(patW, patH),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = Colors.black38,
      );
    }

    // 矩形选区高亮（编辑画布 contain 偏移为零，仍是画布坐标原义）
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) {
    return oldDelegate.model != model ||
        oldDelegate.selectedColorIndex != selectedColorIndex ||
        oldDelegate.palette != palette ||
        oldDelegate.selectionRect != selectionRect ||
        oldDelegate.highlightIndex != highlightIndex ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.outline != outline;
  }
}
