import 'dart:ui' as ui;

import 'package:bead_studio/core/board_config.dart';
import 'package:bead_studio/core/draft_store.dart';
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/pattern_model.dart';
import 'package:bead_studio/features/board/board_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 已放格白罩（2026-11-11 需求 9）：白罩只施加于「选中色的已放格」——
/// 其余情况（未选色 / 非选中色的已放格）已放格保持原豆色 + 绿对勾。
/// 画布 CustomPaint 不进语义树，用 RepaintBoundary 出图逐格验色
void main() {
  const e11 = Color(0xFFF7DAD4);

  ///< E11=(247,218,212) 浅粉
  const c16 = Color(0xFF1858A2);

  ///< C16=(24,88,162) 深蓝
  testWidgets('白罩仅覆盖选中色的已放格；未选色时已放格保持原色', (tester) async {
    tester.view.physicalSize = const Size(600, 460);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 3×2：上排 E11×3，下排 C16×2 + 空格。已放：E11@(0,0)、C16@(0,1)
    const palette = BeadPalette([
      BeadColor("E11", "粉", 0xFFF7DAD4),
      BeadColor("C16", "蓝", 0xFF1858A2),
    ]);
    final model = PatternModel(
      width: 3,
      height: 2,
      grid: [0, 0, 0, 1, 1, -1],
      paletteIds: [for (final c in palette.colors) c.id],
    );
    final boundaryKey = GlobalKey();
    String? hi;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return Scaffold(
              body: RepaintBoundary(
                key: boundaryKey,
                child: Center(
                  child: SizedBox(
                    width: 600,
                    height: 400,
                    child: CustomPaint(
                      painter: BoardPainter(
                        board: const BoardConfig(w: 3, h: 2),
                        showLabels: false,
                        items: [
                          BoardPaintItem(
                            model: model,
                            palette: palette,
                            ox: 0,
                            oy: 0,
                            highlightId: hi,
                            placedCells: const {0, 3},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<Color> cellColor(int cx, int cy) async {
      // toImage/toByteData 是真异步（引擎侧光栅化），FakeAsync 测试环境里
      // 必须 runAsync 放行事件循环，否则 await 永远挂起
      return tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final img = await boundary.toImage(pixelRatio: 1.0);
        // 600×400 板铺满：格 200×200，取格中心
        final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final o = (cy * 600 + cx) * 4;
        final b = d!.buffer.asUint8List();
        return Color.fromARGB(
          255,
          b[o],
          b[o + 1],
          b[o + 2],
        );
      }).then<Color>((c) => c!);
    }

    // —— 无选中：已放格与未放格同为原色（白罩不生效）
    expect(await cellColor(100, 100), e11); // 已放 E11：原色
    expect(await cellColor(300, 100), e11); // 未放 E11：原色
    expect(await cellColor(100, 300), c16); // 已放 C16：原色

    // —— 选中 E11：已放 E11 变浅（白罩），未放 E11 仍原色；
    //    非选中色（C16 已放格）整体压暗、对勾仍在
    setOuter(() => hi = "E11");
    await tester.pumpAndSettle();
    final veiled = await cellColor(100, 100);
    expect(veiled, isNot(e11));
    expect(veiled.red, greaterThan(e11.red)); // 白罩 = 三通道都向白靠
    expect(veiled.green, greaterThan(e11.green));
    expect(veiled.blue, greaterThan(e11.blue));
    expect(await cellColor(300, 100), e11); // 未放 E11：原色不变
    final dimmed = await cellColor(100, 300); // 已放 C16（非选中色）
    expect(dimmed.red, greaterThan(c16.red)); // 深色向压暗基色抬升（≠原色）
  });
}
