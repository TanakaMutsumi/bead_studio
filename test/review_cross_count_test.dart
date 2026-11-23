// 复核截图墙「每行列数」切换回归：自定义列数（7）曾触发
// InheritedElement.debugDeactivated 断言（framework.dart:6281
// dependents.isEmpty）整页 ErrorWidget。此测试最小复现该交互链：
// 筛选色 → 弹菜单 → 自定义… → 输入 7 → 确定
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/pattern_model.dart';
import 'package:bead_studio/features/restore/restore_types.dart';
import 'package:bead_studio/features/restore/steps/review_step.dart';

Future<ui.Image> _uiImage(int w, int h) {
  final c = Completer<ui.Image>();
  final src = img.Image(width: w, height: h);
  img.fill(src, color: img.ColorRgb8(200, 30, 30));
  final bytes = Uint8List.fromList(img.encodePng(src));
  ui.instantiateImageCodec(bytes).then((codec) async {
    final f = await codec.getNextFrame();
    c.complete(f.image);
  });
  return c.future;
}

void main() {
  // ui.Image 解码是真异步 IO，须在 FakeAsync 之外完成（testWidgets 内
  // await 真异步会永久挂起）
  late ui.Image src;
  setUpAll(() async {
    src = await _uiImage(200, 160);
  });

  testWidgets('自定义每行列数 7 不崩溃且墙按 7 列重建', (tester) async {
    const palette = BeadPalette([
      BeadColor("A1", "红", 0xCC2222),
      BeadColor("B2", "蓝", 0x2244CC),
      BeadColor("C3", "黄", 0xEEDD22),
    ]);
    // 10x8 网格：A1/B2 交替 + 若干空白
    final grid = <int>[];
    for (var i = 0; i < 80; i++) {
      grid.add(i % 7 == 3 ? -1 : i % 2);
    }
    final model = PatternModel(
      width: 10,
      height: 8,
      grid: grid,
      paletteIds: const ["A1", "B2"],
    );
    final legend = [LegendEntry(0), LegendEntry(1)];
    final rects = List.generate(
      80,
      (i) => Rect.fromLTWH((i % 10) * 20.0, (i ~/ 10) * 20.0, 20, 20),
    );
    var crossCount = 6;
    late StateSetter setHost;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setHost = setState;
              return ReviewStep(
                zoomStrip: (ctrl, size, {maxScale = 12, viewport, selection}) =>
                    const SizedBox(width: 40, height: 20),
                model: model,
                palette: palette,
                legend: legend,
                legendSort: LegendSort.code,
                cellRects: rects,
                cellScores: List.filled(80, 1.0),
                cellSrc: src,
                image: img.Image(width: 200, height: 160),
                reviewColor: 0,
                crossCount: crossCount,
                onCrossCountChange: (v) => setHost(() => crossCount = v),
                picked: const {},
                reviewCtrl: TransformationController(),
                reviewCanvasSize: () => const Size(200, 160),
                onCanvasSize: (_) {},
                onChipTap: (_) {},
                onTogglePick: (_) {},
                onPickCells: (_, __) {},
                onSelectAll: () {},
                onInvertPick: () {},
                onClearPicked: () {},
                onReassign: () {},
                hasClassifyTarget: true,
                onSave: () {},
                onOpenEditor: () {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 打开每行列数菜单 → 自定义…
    await tester.tap(find.text("每行6格"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("自定义…"));
    await tester.pumpAndSettle();

    // 输入 7 → 确定
    await tester.enterText(find.byType(TextField), "7");
    await tester.tap(find.text("确定"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text("每行7格"), findsOneWidget);

    // 快捷项切换（6）也应正常
    await tester.tap(find.text("每行7格"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("每行 6 格"));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text("每行6格"), findsOneWidget);
  });
}
