import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/legend_ocr.dart';
import '../../core/pattern_model.dart';

/// 四角双线性插值：单位网格坐标 (u,v)∈[0,1]² -> 平面坐标
///
/// q 为四角 [左上, 右上, 右下, 左下]（对应单位坐标 (0,0)(1,0)(1,1)(0,1)）。
/// 四角对齐模式的核心几何：用户把 4 个角点拖到图案网格的四个角，
/// 识别采样与网格覆盖层的全部交点都经此映射反求，两处坐标同源。
Offset bilinearQuad(List<Offset> q, double u, double v) {
  final a = (1 - u) * (1 - v);
  final b = u * (1 - v);
  final c = u * v;
  final d = (1 - u) * v;
  return Offset(
    a * q[0].dx + b * q[1].dx + c * q[2].dx + d * q[3].dx,
    a * q[0].dy + b * q[1].dy + c * q[2].dy + d * q[3].dy,
  );
}

/// 选区绘制：外部半透明遮罩 + 蓝色边框
class SelPainter extends CustomPainter {
  final Rect rect;

  SelPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final mask = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // 框外略暗遮罩：整图挖掉选区（difference 两个独立 path，不能用
    // addPath 叠进同一个 path——nonzero 填充规则下重叠区 winding=2 仍
    // 被填充，遮罩会盖住选区内部，框内外无明暗区分）
    final outer = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final inner = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      mask,
    );
    canvas.drawRect(rect, border);
    // 8 个编辑把手（四角+四边中点）：白底橙圈，可拖动扩大缩小选区
    final handlePts = [
      rect.topLeft,
      Offset(rect.center.dx, rect.top),
      rect.topRight,
      Offset(rect.left, rect.center.dy),
      Offset(rect.right, rect.center.dy),
      rect.bottomLeft,
      Offset(rect.center.dx, rect.bottom),
      rect.bottomRight,
    ];
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final p in handlePts) {
      canvas.drawCircle(p, 6, fill);
      canvas.drawCircle(p, 6, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant SelPainter oldDelegate) =>
      oldDelegate.rect != rect;
}

/// 【临时调试】OCR 元素叠加层：绿框=色号、蓝框=颗数、红线=配对连线
///
/// 画布尺寸与放大图 1:1（外层 SizedBox 定死 imgW×imgH），元素框直接绘制。
/// 正式版随调试功能一起移除。
class OcrDebugPainter extends CustomPainter {
  final List<OcrElem> elems;

  final List<LegendBar> bars;

  ///< 检测到的色条（橙色框，颜色融合调试用）
  OcrDebugPainter(this.elems, [this.bars = const []]);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final codeP = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final numP = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final lineP = Paint()
      ..color = Colors.red
      ..strokeWidth = 2;
    final barP = Paint()
      ..color = Colors.deepOrange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final b in bars) {
      canvas.drawRect(b.rect, barP);
    }
    for (final e in elems) {
      if (e.rect.width <= 0 || e.rect.height <= 0) {
        continue; // 几何框退化的元素画不了框
      }
      canvas.drawRect(e.rect, e.code != null ? codeP : numP);
      final other = e.pairedWith;
      if (e.code != null && other != null && other.rect.width > 0) {
        canvas.drawLine(e.rect.center, other.rect.center, lineP);
      }
    }
  }

  @override
  bool shouldRepaint(covariant OcrDebugPainter oldDelegate) => true;
}

/// 网格覆盖层：把识别网格线画在图上，肉眼核对是否压住真实格线
class GridOverlayPainter extends CustomPainter {
  final int cols;
  final int rows;
  final double originDx;

  ///< 第一根竖线 x（显示坐标）
  final double originDy;

  ///< 第一根横线 y（显示坐标）
  final double pitchDx;

  ///< 横向格距（显示坐标）
  final double pitchDy;

  ///< 纵向格距（显示坐标）

  GridOverlayPainter({
    required this.cols,
    required this.rows,
    required this.originDx,
    required this.originDy,
    required this.pitchDx,
    required this.pitchDy,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i <= cols; i++) {
      final x = originDx + i * pitchDx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var i = 0; i <= rows; i++) {
      final y = originDy + i * pitchDy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant GridOverlayPainter oldDelegate) =>
      oldDelegate.cols != cols ||
      oldDelegate.rows != rows ||
      oldDelegate.originDx != originDx ||
      oldDelegate.originDy != originDy ||
      oldDelegate.pitchDx != pitchDx ||
      oldDelegate.pitchDy != pitchDy;
}

/// 四角对齐覆盖层：双线性网格线 + 四角大把手（显示坐标）
///
/// 网格交点全部经 [bilinearQuad] 反求——与识别采样同源，
/// 蓝线压住哪格，识别就采哪格（所见即所采）。
class CornerGridPainter extends CustomPainter {
  final List<Offset> pts;

  ///< 四角（显示坐标）：左上/右上/右下/左下
  final int cols;
  final int rows;

  CornerGridPainter(
      {required this.pts, required this.cols, required this.rows});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final line = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    // 竖线：每条经 rows+1 个交点折线连接（双线性下相邻交点连线即格线）
    for (var i = 0; i <= cols; i++) {
      final u = i / cols;
      final start = bilinearQuad(pts, u, 0);
      final path = Path()..moveTo(start.dx, start.dy);
      for (var j = 1; j <= rows; j++) {
        final p = bilinearQuad(pts, u, j / rows);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, line);
    }
    // 横线
    for (var j = 0; j <= rows; j++) {
      final v = j / rows;
      final path = Path();
      final start = bilinearQuad(pts, 0, v);
      path.moveTo(start.dx, start.dy);
      for (var i = 1; i <= cols; i++) {
        final p = bilinearQuad(pts, i / cols, v);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, line);
    }
    // 四角大把手：白底橙圈（比选区把手大，透视拖拽目标）
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = const Color(0xFF7B1FA2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final p in pts) {
      canvas.drawCircle(p, 10, fill);
      canvas.drawCircle(p, 10, stroke);
    }
    // 四边形轮廓
    final outline = Paint()
      ..color = const Color(0xFF7B1FA2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final quad = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();
    canvas.drawPath(quad, outline);
  }

  @override
  bool shouldRepaint(covariant CornerGridPainter oldDelegate) =>
      oldDelegate.pts != pts ||
      oldDelegate.cols != cols ||
      oldDelegate.rows != rows;
}

/// 九宫格标定覆盖层：3×3 标定框（细线）+ 全图同相位虚线延伸格 +
/// 左上/右下双缩放把手（仅「② 九宫格对齐」步使用；框选主体步的
/// 选区内格线见 FrameGridPainter）
///
/// 识别切分的格距与格线相位全部由这个框导出（格距 = 边长/3，锚点 =
/// 左上角即第一根格线交点）。虚线延伸格从锚点按格距铺满全图、与九宫格
/// 同相位——比对齐不必只盯着 9 格：外围任何一格的虚线压住图纸格线即
/// 对齐成功。线宽/把手尺寸按当前视图缩放补偿（除以 scale）：放大后
/// 视觉尺寸恒定，粗线不糊掉格线、大把手不遮挡内容不误触。
class MiniGridPainter extends CustomPainter {
  final Rect grid;

  ///< 3×3 框（显示坐标）
  final double scale;

  ///< 当前视图缩放倍数（InteractiveViewer 矩阵，尺寸补偿用）

  MiniGridPainter({required this.grid, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final pitchDx = grid.width / 3;
    final pitchDy = grid.height / 3;
    if (pitchDx < 2 || pitchDy < 2) {
      return;
    }
    // 全图同相位虚线格：x/y 起点取锚点对格距取模（与九宫格共用原点），
    // 段长 = 格距/3、空隙 = 格距/6（视觉密度随格距自适应），全部收进
    // 一个 Path 一次 stroke。alpha/线宽加强（用户实测原 0.35/0.8 在
    // 彩色图纸上几乎看不见，对齐无从核对）
    final dashP = Paint()
      ..color = const Color(0xFFE65100).withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / scale;
    final path = Path();
    var x0 = grid.left % pitchDx;
    if (x0 < 0) {
      x0 += pitchDx;
    }
    final dashY = pitchDy / 3;
    final stepY = dashY + pitchDy / 6;
    for (var x = x0; x <= size.width; x += pitchDx) {
      for (var y = 0.0; y < size.height;) {
        path.moveTo(x, y);
        path.lineTo(x, math.min(y + dashY, size.height));
        y += stepY;
      }
    }
    var y0 = grid.top % pitchDy;
    if (y0 < 0) {
      y0 += pitchDy;
    }
    final dashX = pitchDx / 3;
    final stepX = dashX + pitchDx / 6;
    for (var y = y0; y <= size.height; y += pitchDy) {
      for (var x = 0.0; x < size.width;) {
        path.moveTo(x, y);
        path.lineTo(math.min(x + dashX, size.width), y);
        x += stepX;
      }
    }
    canvas.drawPath(path, dashP);
    // 3×3 实线框（细）：粗线在格距 ~22 显示px 时占格边 9%，压住图纸
    // 格线没法比对是否重叠（用户实测反馈），细到 1.4/scale 视觉恒定
    final outline = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 / scale;
    canvas.drawRect(grid, outline);
    // 内部十字线：2 竖 + 2 横（1/3、2/3 处）
    final inner = Paint()
      ..color = const Color(0xFFE65100).withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9 / scale;
    for (var i = 1; i <= 2; i++) {
      final x = grid.left + grid.width * i / 3;
      canvas.drawLine(Offset(x, grid.top), Offset(x, grid.bottom), inner);
      final y = grid.top + grid.height * i / 3;
      canvas.drawLine(Offset(grid.left, y), Offset(grid.right, y), inner);
    }
    // 左上/右下双缩放把手：拖右下=左上角（锚点）不动调格距；拖左上=
    // 右下角不动。白底橙圈，半径随缩放补偿（放大后不会变巨误触）
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 / scale;
    for (final handle in [grid.topLeft, grid.bottomRight]) {
      canvas.drawCircle(handle, 8 / scale, fill);
      canvas.drawCircle(handle, 8 / scale, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant MiniGridPainter oldDelegate) =>
      oldDelegate.grid != grid || oldDelegate.scale != scale;
}

/// 框选主体覆盖层：选区内格线（相位锚定九宫格锚点，选区四边已吸附
/// 格线——所见格数 = 识别切分格数）+ 选区上缘行列数徽标（拖框/缩放
/// 实时跟手，格数超识别范围 4-400 转红提醒）
///
/// 九宫格标定只负责定格距与相位（对齐步完成），本层不再全图画虚线
/// 格——框外区域保持干净，格线只铺在选区内。徽标/字号按当前视图缩放
/// 补偿（除以 scale）：放大后视觉尺寸恒定。
class FrameGridPainter extends CustomPainter {
  final Rect sel;

  ///< 选区（显示坐标，四边已吸附格线）
  final double pitchDx;

  ///< 横向格距（显示坐标）
  final double pitchDy;

  ///< 纵向格距（显示坐标）
  final double scale;

  ///< 当前视图缩放倍数（尺寸补偿用）

  FrameGridPainter({
    required this.sel,
    required this.pitchDx,
    required this.pitchDy,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    if (pitchDx < 2 || pitchDy < 2) {
      return;
    }
    final cols = (sel.width / pitchDx).round();
    final rows = (sel.height / pitchDy).round();
    // 选区内格线：选区四边本身就是格线（吸附），从左上铺 cols+1 竖线、
    // rows+1 横线（计数循环防浮点漂移多画/漏画边缘线）
    final line = Paint()
      ..color = const Color(0xFFE65100).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 / scale;
    final path = Path();
    for (var i = 0; i <= cols; i++) {
      final x = sel.left + i * pitchDx;
      path.moveTo(x, sel.top);
      path.lineTo(x, sel.bottom);
    }
    for (var j = 0; j <= rows; j++) {
      final y = sel.top + j * pitchDy;
      path.moveTo(sel.left, y);
      path.lineTo(sel.right, y);
    }
    canvas.drawPath(path, line);
    // 行列数徽标：选区上缘外居中，出屏（框贴画布顶）收进框内；格数超
    // 识别范围转红（底部引导文案同时说明原因）
    final outOfRange = cols < 4 || rows < 4 || cols > 400 || rows > 400;
    final tp = TextPainter(
      text: TextSpan(
        text: "$rows行 × $cols列",
        style: TextStyle(
          color: Colors.white,
          fontSize: 12 / scale,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final padH = 8 / scale;
    final padV = 4 / scale;
    final bw = tp.width + padH * 2;
    final bh = tp.height + padV * 2;
    final bx = (sel.center.dx - bw / 2)
        .clamp(0.0, math.max(0.0, size.width - bw))
        .toDouble();
    final gap = 6 / scale;
    final by = sel.top - bh - gap >= 0
        ? sel.top - bh - gap
        : math.min(sel.top + gap, math.max(0.0, size.height - bh));
    final badge = RRect.fromRectAndRadius(
      Rect.fromLTWH(bx, by, bw, bh),
      Radius.circular(bh / 2),
    );
    canvas.drawRRect(
      badge,
      Paint()
        ..color =
            outOfRange ? const Color(0xFFC62828) : const Color(0xFFE65100),
    );
    tp.paint(canvas, Offset(bx + padH, by + padV));
  }

  @override
  bool shouldRepaint(covariant FrameGridPainter oldDelegate) =>
      oldDelegate.sel != sel ||
      oldDelegate.pitchDx != pitchDx ||
      oldDelegate.pitchDy != pitchDy ||
      oldDelegate.scale != scale;
}

/// 空白复核：空白格铺淡红色
class BlankMarksPainter extends CustomPainter {
  final PatternModel model;

  BlankMarksPainter({required this.model});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / model.width;
    final paint = Paint()..color = Colors.red.withValues(alpha: 0.18);
    for (var i = 0; i < model.grid.length; i++) {
      if (model.grid[i] >= 0) {
        continue;
      }
      final x = i % model.width, y = i ~/ model.width;
      canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
    }
  }

  @override
  bool shouldRepaint(covariant BlankMarksPainter oldDelegate) =>
      oldDelegate.model != model;
}

/// 选中格标记：蓝色覆盖 + 右上角对勾
class ReviewMarksPainter extends CustomPainter {
  final PatternModel model;
  final Set<int> picked;

  ReviewMarksPainter({required this.model, required this.picked});

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / model.width;
    final cellH = size.height / model.height;
    final fill = Paint()..color = Colors.blue.withValues(alpha: 0.3);
    final border = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final check = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final i in picked) {
      final x = i % model.width, y = i ~/ model.width;
      final rect = Rect.fromLTWH(x * cellW, y * cellH, cellW, cellH);
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, border);
      final cx = rect.center.dx, cy = rect.center.dy;
      final s = cellW < cellH ? cellW : cellH;
      canvas.drawLine(
        Offset(cx - s * 0.2, cy),
        Offset(cx - s * 0.05, cy + s * 0.18),
        check,
      );
      canvas.drawLine(
        Offset(cx - s * 0.05, cy + s * 0.18),
        Offset(cx + s * 0.25, cy - s * 0.18),
        check,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ReviewMarksPainter oldDelegate) =>
      oldDelegate.picked != picked;
}

/// 复核截图墙的格子截图：从限幅显示版 ui.Image 按 srcRect 取格绘制
class CellThumbPainter extends CustomPainter {
  final ui.Image src;

  ///< 限幅显示版图（_displayBytes 解码）
  final Rect srcRect;

  ///< 取材区（src 坐标，已 intersect 源界）

  CellThumbPainter({required this.src, required this.srcRect});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      src,
      srcRect,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant CellThumbPainter oldDelegate) =>
      oldDelegate.src != src || oldDelegate.srcRect != srcRect;
}
