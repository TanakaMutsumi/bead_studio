/// 豆板画布渲染器：板底格 + 相位加粗框线 + 作品叠加（偏移摆放）+ 拼装标记
library;

import 'package:flutter/material.dart';

import '../../core/board_config.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';

class BoardPainter extends CustomPainter {
  final BoardConfig board;

  ///< 板配置（尺寸/加粗间隔/相位/作品偏移全在里面）
  final PatternModel model;

  ///< 叠加的作品
  final BeadPalette palette;
  final int? highlightIndex;

  ///< 拼装高亮色索引（null = 关闭；其余色降饱和显示）
  final Set<int>? placedCells;

  ///< 拼装已放格（作品格扁平索引；null = 关闭）
  final bool showWorkBorder;

  ///< 画作品边界蓝框（豆板配置页提示摆放范围；拼豆页关闭）

  BoardPainter({
    required this.board,
    required this.model,
    required this.palette,
    this.highlightIndex,
    this.placedCells,
    this.showWorkBorder = false,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / board.w;
    final cellH = size.height / board.h;

    // 板底
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFAFAFA),
    );

    // 作品格（板外格不画：cell() 越界已挡，但 ox/oy 保证在板内，此处直接映射）
    final gridPaint = Paint()..style = PaintingStyle.fill;
    for (var y = 0; y < model.height; y++) {
      for (var x = 0; x < model.width; x++) {
        final v = model.grid[y * model.width + x];
        if (v < 0 || v >= palette.colors.length) {
          continue;
        }
        final c = palette.colors[v];
        var color = Color.fromARGB(255, c.r, c.g, c.b);
        if (highlightIndex != null && v != highlightIndex) {
          color = Color.lerp(
            color,
            const Color.fromARGB(255, 0x30, 0x30, 0x30),
            0.65,
          )!;
        }
        gridPaint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(
            (board.ox + x) * cellW,
            (board.oy + y) * cellH,
            cellW,
            cellH,
          ),
          gridPaint,
        );
      }
    }

    // 格线：细线全长；(x+phaseX)%interval==0 的竖线 / (y+phaseY)%interval==0 的横线加粗
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = Colors.black12;
    final majorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.black54;
    final iv = board.interval;
    for (var x = 0; x <= board.w; x++) {
      final p = x * cellW;
      canvas.drawLine(
        Offset(p, 0),
        Offset(p, size.height),
        ((x + board.phaseX) % iv == 0) ? majorPaint : linePaint,
      );
    }
    for (var y = 0; y <= board.h; y++) {
      final p = y * cellH;
      canvas.drawLine(
        Offset(0, p),
        Offset(size.width, p),
        ((y + board.phaseY) % iv == 0) ? majorPaint : linePaint,
      );
    }

    // 拼装已放格：半透明白罩 + 绿对勾（EditorPage 拼装标记同款观感）
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
          continue;
        }
        final x = i % model.width, y = i ~/ model.width;
        final rect = Rect.fromLTWH(
          (board.ox + x) * cellW,
          (board.oy + y) * cellH,
          cellW,
          cellH,
        );
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

    // 作品边界蓝框（豆板配置页）
    if (showWorkBorder) {
      final border = Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRect(
        Rect.fromLTWH(
          board.ox * cellW,
          board.oy * cellH,
          model.width * cellW,
          model.height * cellH,
        ),
        border,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) {
    return oldDelegate.board != board ||
        oldDelegate.model != model ||
        oldDelegate.palette != palette ||
        oldDelegate.highlightIndex != highlightIndex ||
        oldDelegate.placedCells != placedCells ||
        oldDelegate.showWorkBorder != showWorkBorder;
  }
}
