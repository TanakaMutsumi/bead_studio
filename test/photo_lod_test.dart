import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/core/zoom_controls.dart';

/// photoLodCropRect（放大后全分辨率裁片的源矩形）纯函数单测
void main() {
  // 统一几何：画布 1000×1000 逻辑（dpr=1 → 物理长边 1000），原图
  // 4000×4000，显示图长边 2048 → 阈值 = 2048/1000 = 2.048
  Rect? call(Matrix4 m) => photoLodCropRect(
        m: m,
        canvas: const Size(1000, 1000),
        srcW: 4000,
        srcH: 4000,
        dispLongPx: 2048,
        physLongPx: 1000,
      );

  test('未过显示图地平线（scale 2 < 2.048）返回 null', () {
    final m = Matrix4.identity()
      ..setEntry(0, 0, 2)
      ..setEntry(1, 1, 2);
    expect(call(m), isNull);
  });

  test('恒等（fit）返回 null', () {
    expect(call(Matrix4.identity()), isNull);
  });

  test('居中 4×：可见区+25% 边距 → 原图矩形', () {
    // 视口=画布盒：scale4 时可见 250×250，居中即画布 (375,375)-(625,625)
    final m = Matrix4.identity()
      ..setEntry(0, 0, 4)
      ..setEntry(1, 1, 4)
      ..setEntry(0, 3, -1500)
      ..setEntry(1, 3, -1500);
    final r = call(m)!;
    // 可见 (375..625) 外扩 62.5 → (312.5..687.5) → ×4000/1000
    expect(r.left, closeTo(1250, 0.5));
    expect(r.top, closeTo(1250, 0.5));
    expect(r.width, closeTo(1500, 0.5));
    expect(r.height, closeTo(1500, 0.5));
  });

  test('贴边可见区：外扩被画布夹住（不出负坐标）', () {
    // scale4 平移 0：可见 (0,0)-(250,250)，外扩夹到画布 (0,0)-(312.5,312.5)
    final m = Matrix4.identity()
      ..setEntry(0, 0, 4)
      ..setEntry(1, 1, 4);
    final r = call(m)!;
    expect(r.left, 0);
    expect(r.top, 0);
    expect(r.width, closeTo(1250, 0.5));
  });

  test('可见区过大时裁片长边收缩到 2048（中心不变）', () {
    // scale 2.2（刚过阈值）：可见 ~455 → 外扩 ~569 → 源 ~2274 > 2048
    final m = Matrix4.identity()
      ..setEntry(0, 0, 2.2)
      ..setEntry(1, 1, 2.2)
      ..setEntry(0, 3, -600)
      ..setEntry(1, 3, -600);
    final r = call(m)!;
    expect(math.max(r.width, r.height), lessThanOrEqualTo(2048.0 + 0.5));
    // 中心保持可见区中心：可见 (272.7..727.3) 外扩 → 中心 500 画布 = 2000 源
    expect(r.center.dx, closeTo(2000, 2));
    expect(r.center.dy, closeTo(2000, 2));
  });
}
