// 放大/缩小锚点（ZoomControls.zoomAt）：有选框时以选框中心为焦点——
// 锚点的内容点在屏幕上的位置缩放前后保持不动
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/core/zoom_controls.dart';

TransformationController _ctrl(double s, double dx, double dy) {
  final m = Matrix4.identity();
  m.setEntry(0, 0, s);
  m.setEntry(1, 1, s);
  m.setEntry(0, 3, dx);
  m.setEntry(1, 3, dy);
  return TransformationController(m);
}

/// 内容点在屏幕上的位置（纯平移+等比缩放矩阵）
Offset _screenPoint(TransformationController c, Offset content) => Offset(
      c.value.storage[12] + c.value.storage[0] * content.dx,
      c.value.storage[13] + c.value.storage[0] * content.dy,
    );

void main() {
  const vp = Size(800, 600);

  test('以锚点放大：锚点（视口坐标）的屏幕位置不动', () {
    final ctrl = _ctrl(1, 0, 0);
    const anchor = Offset(200, 150);
    expect(
      ZoomControls.zoomAt(
        controller: ctrl,
        viewport: vp,
        content: vp,
        factor: 1.25,
        anchor: anchor,
      ),
      isTrue,
    );
    expect(_screenPoint(ctrl, anchor), anchor);
  });

  test('锚点放大后再缩小（无夹限介入）：回到原变换', () {
    final ctrl = _ctrl(1, 0, 0);
    const anchor = Offset(200, 150);
    ZoomControls.zoomAt(
      controller: ctrl,
      viewport: vp,
      content: vp,
      factor: 1.25,
      anchor: anchor,
    );
    ZoomControls.zoomAt(
      controller: ctrl,
      viewport: vp,
      content: vp,
      factor: 0.8,
      anchor: anchor,
    );
    // ×1.25 再 ×0.8 回到恒等，锚点自然不动
    expect(_screenPoint(ctrl, anchor), anchor);
    expect(ctrl.value.getMaxScaleOnAxis(), closeTo(1.0, 1e-9));
  });

  test('无锚点 / 锚点 null：以视口中心为焦点（原行为不变）', () {
    for (final anchor in [null, null]) {
      final ctrl = _ctrl(1, 0, 0);
      ZoomControls.zoomAt(
        controller: ctrl,
        viewport: vp,
        content: vp,
        factor: 1.25,
        anchor: anchor,
      );
      expect(
          _screenPoint(ctrl, vp.center(Offset.zero)), vp.center(Offset.zero));
    }
  });

  test('缩到下限（s=1）不再变化', () {
    final ctrl = _ctrl(1, 0, 0);
    expect(
      ZoomControls.zoomAt(
        controller: ctrl,
        viewport: vp,
        content: vp,
        factor: 0.8,
        anchor: const Offset(200, 150),
      ),
      isFalse,
    );
    expect(ctrl.value.getMaxScaleOnAxis(), 1.0);
  });
}
