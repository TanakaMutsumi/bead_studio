/// 预览渲染器：2D 圆豆成品片 + 3D 圆豆场景（旋转矩阵透视投影 + 深度排序 + 三点光照）
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/pattern_model.dart';

/// 3D 场景中的一颗豆（居中世界坐标 + 颜色）
class _SceneBead {
  final double x;
  final double y;
  final Color color;
  const _SceneBead(this.x, this.y, this.color);
}

/// 2D 圆豆成品片：每颗豆画豆体 + 边缘暗环 + 左上高光，空格画板钉
class BeadFlatPainter extends CustomPainter {
  final PatternModel model;
  final BeadPalette palette;

  BeadFlatPainter({required this.model, required this.palette, super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide / math.max(model.width, model.height);
    final dx0 = (size.width - cell * model.width) / 2;
    final dy0 = (size.height - cell * model.height) / 2;
    final beadR = cell * 0.44;
    final boardPaint = Paint()..color = const Color.fromARGB(255, 238, 238, 235);
    final beadPaint = Paint()..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, cell * 0.05)
      ..color = Colors.black26;
    final glossPaint = Paint()..style = PaintingStyle.fill;

    canvas.drawRect(Offset.zero & size, boardPaint);
    for (var y = 0; y < model.height; y++) {
      for (var x = 0; x < model.width; x++) {
        final cx = dx0 + (x + 0.5) * cell;
        final cy = dy0 + (y + 0.5) * cell;
        final v = model.cell(x, y);
        final c = v >= 0 && v < palette.colors.length ? palette.colors[v] : null;
        if (c == null) {
          // 空格：板面钉点
          boardPaint.color = const Color.fromARGB(255, 213, 213, 210);
          canvas.drawCircle(Offset(cx, cy), cell * 0.09, boardPaint);
          boardPaint.color = const Color.fromARGB(255, 238, 238, 235);
          continue;
        }
        final center = Offset(cx, cy);
        beadPaint.color = Color.fromARGB(255, c.r, c.g, c.b);
        canvas.drawCircle(center, beadR, beadPaint);
        canvas.drawCircle(center, beadR, edgePaint);
        if (cell >= 7) {
          glossPaint.color = Colors.white.withValues(alpha: 0.42);
          canvas.drawCircle(Offset(cx - beadR * 0.34, cy - beadR * 0.34), beadR * 0.3, glossPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant BeadFlatPainter oldDelegate) {
    return oldDelegate.model != model || oldDelegate.palette != palette;
  }
}

/// 3D 圆豆场景：yaw/pitch 旋转 + 透视投影 + 深度排序 + 漫反射/高光
class BeadScenePainter extends CustomPainter {
  final PatternModel model;
  final BeadPalette palette;
  final double yaw; ///< 水平旋转角（弧度）
  final double pitch; ///< 俯仰角（弧度，正 = 从上往下看）
  final double zoom; ///< 缩放（0.45-3.5）
  final double brightness; ///< 亮度系数（0.6-1.4）
  final bool ironed; ///< true = 熨烫压扁（次轴压缩 + 弱高光）

  BeadScenePainter({
    required this.model,
    required this.palette,
    required this.yaw,
    required this.pitch,
    this.zoom = 1,
    this.brightness = 1,
    this.ironed = false,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final beads = _collectBeads();
    if (beads.isEmpty) {
      return;
    }
    final n = beads.length;

    // 相机：38° 视场角，距离随图案跨度自适应
    final tanHalf = math.tan(19 * math.pi / 180);
    final span = math.max(model.width, model.height).toDouble();
    final dist = span * 0.5 / tanHalf * 1.18 * zoom;
    final focal = 1 / tanHalf;
    final unit = size.shortestSide / span * 1.6;

    final cosY = math.cos(yaw), sinY = math.sin(yaw);
    final cosP = math.cos(pitch), sinP = math.sin(pitch);
    // 板法线 (0,0,1) 旋转后：朝向相机的分量决定椭圆次轴
    final nz = cosY * cosP;

    // 投影 + 深度收集
    final projected = <(double sx, double sy, double depth, double scale, Color color)>[];
    for (final b in beads) {
      // 绕 Y（yaw）：z=0 平面内旋转
      final rx = b.x * cosY;
      final rz1 = -b.x * sinY;
      // 绕 X（pitch）
      final ry2 = b.y * cosP - rz1 * sinP;
      final rz2 = b.y * sinP + rz1 * cosP;
      final viewZ = dist + rz2;
      final s = focal / viewZ;
      projected.add((size.width / 2 + rx * s * unit, size.height / 2 - ry2 * s * unit, rz2, s, b.color));
    }
    // 远的先画（painter's algorithm）
    projected.sort((a, b) => a.$3.compareTo(b.$3));

    final paint = Paint()..style = PaintingStyle.fill;
    final gloss = Paint()..style = PaintingStyle.fill;

    // 光照：主光方向(-0.46,0.68,0.56)，法线用板面法线近似（每豆一致，批量算一次）
    const ldx = -0.46, ldy = 0.68, ldz = 0.56;
    final lnorm = math.sqrt(ldx * ldx + ldy * ldy + ldz * ldz);
    final nx2 = sinY, ny2 = -cosY * sinP, nzl2 = cosY * cosP;
    final diffuse = math.max(0.0, (nx2 * ldx + ny2 * ldy + nzl2 * ldz) / lnorm);
    final lit = 0.42 + 0.58 * diffuse;
    final squash = ironed ? 0.62 : 1.0;
    final drawGloss = n <= 4200;
    for (final p in projected) {
      final k = p.$4 * unit * 0.5; // 该豆的投影半径
      final brx = math.max(k, 1.0);
      final bry = math.max(k * nz.abs() * squash, 0.7);
      final base = p.$5;
      paint.color = Color.fromARGB(
        255,
        _clamp255(base.r * lit * brightness),
        _clamp255(base.g * lit * brightness),
        _clamp255(base.b * lit * brightness),
      );
      canvas.drawOval(Rect.fromCenter(center: Offset(p.$1, p.$2), width: brx * 2, height: bry * 2), paint);
      if (drawGloss) {
        gloss.color = Colors.white.withValues(alpha: (0.16 + 0.42 * diffuse).clamp(0.0, 1.0));
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(p.$1 - brx * 0.3, p.$2 - bry * 0.32),
            width: brx * 0.62,
            height: bry * 0.5,
          ),
          gloss,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant BeadScenePainter oldDelegate) {
    return oldDelegate.yaw != yaw ||
        oldDelegate.pitch != pitch ||
        oldDelegate.zoom != zoom ||
        oldDelegate.brightness != brightness ||
        oldDelegate.ironed != ironed ||
        oldDelegate.model != model ||
        oldDelegate.palette != palette;
  }

  /// 收集非空格豆（居中坐标，y 轴向上）
  List<_SceneBead> _collectBeads() {
    var minX = model.width, maxX = -1, minY = model.height, maxY = -1;
    for (var y = 0; y < model.height; y++) {
      for (var x = 0; x < model.width; x++) {
        if (model.cell(x, y) >= 0) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < minX) {
      return const [];
    }
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    final result = <_SceneBead>[];
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final v = model.cell(x, y);
        if (v < 0 || v >= palette.colors.length) {
          continue;
        }
        final c = palette.colors[v];
        result.add(_SceneBead(x - cx, cy - y, Color.fromARGB(255, c.r, c.g, c.b)));
      }
    }
    return result;
  }

  static int _clamp255(double v) => v.clamp(0, 255).round();
}
