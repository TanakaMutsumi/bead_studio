import 'dart:io';

import 'package:bead_studio/core/draft_store.dart';
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/pattern_model.dart';
import 'package:bead_studio/features/board/board_setup_page.dart';
import 'package:bead_studio/features/board/board_stats.dart';
import 'package:bead_studio/features/board/placed_work.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 豆板摆放：clampTo 出界半界（宽/高最多移出二分之一）/
/// boardHasBeadOutside（豆级出界判定，空白格出界不拦）/ 拖动手势全链
///（拖到出界极限 → 底部提示 + 开始拼豆禁用；拖回板内恢复）/
/// 撤销重做（拖动出界→undo 恢复→redo 再出界）/ dirty 三键退出
void main() {
  PatternModel model(int w, int h, {int blankLeft = 0}) => PatternModel(
        width: w,
        height: h,
        grid: [
          for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++) (x < blankLeft || y == -1) ? -1 : 0,
        ],
        paletteIds: const ["A1"],
      );

  WorkEntry entryOf(PatternModel m) => WorkEntry(
        file: File("fake.json"),
        name: "t",
        folder: "",
        updatedAt: DateTime(2026, 1, 1),
        model: m,
      );

  group('clampTo 半界（宽/高最多移出二分之一）', () {
    test('偶数宽：左右各最多 floor(W/2) 格', () {
      final w = PlacedWork(
          entry: entryOf(model(10, 8)), palette: const BeadPalette([]));
      w.ox = -999;
      w.oy = 0;
      w.clampTo(52, 52);
      expect(w.ox, -5);
      w.ox = 999;
      w.clampTo(52, 52);
      expect(w.ox, 47); // 上限 = bw-(W+1)~/2 = 47，右缘 57 出 5
    });

    test('奇数宽：左右对称各 floor(W/2) 格', () {
      final w = PlacedWork(
          entry: entryOf(model(11, 8)), palette: const BeadPalette([]));
      w.ox = -999;
      w.clampTo(52, 52);
      expect(w.ox, -5);
      w.ox = 999;
      w.clampTo(52, 52);
      expect(w.ox, 46); // 52-(11+1)~/2 = 46，右缘 57 同样出 5
    });

    test('超板作品同样半界（可整体悬挂只留一半）', () {
      final w = PlacedWork(
          entry: entryOf(model(60, 8)), palette: const BeadPalette([]));
      w.ox = -999;
      w.clampTo(52, 52);
      expect(w.ox, -30);
      w.ox = 999;
      w.clampTo(52, 52);
      expect(w.ox, 22); // 52-30
    });

    test('单格作品不能出界（floor(1/2)=0）', () {
      final w = PlacedWork(
          entry: entryOf(model(1, 1)), palette: const BeadPalette([]));
      w.ox = -5;
      w.oy = -5;
      w.clampTo(52, 52);
      expect(w.ox, 0);
      expect(w.oy, 0);
    });

    test('板内偏移不受影响', () {
      final w = PlacedWork(
          entry: entryOf(model(10, 8)), palette: const BeadPalette([]));
      w.ox = 20;
      w.oy = 30;
      w.clampTo(52, 52);
      expect(w.ox, 20);
      expect(w.oy, 30);
    });
  });

  group('boardHasBeadOutside 豆级出界', () {
    test('非空白格出板 → true', () {
      final w = PlacedWork(
        entry: entryOf(model(3, 3)),
        palette: const BeadPalette([]),
        ox: -1,
      );
      expect(boardHasBeadOutside([w], 52, 52), isTrue);
    });

    test('出板的全是空白格 → false', () {
      final w = PlacedWork(
        entry: entryOf(model(3, 3, blankLeft: 1)), // 左列空白
        palette: const BeadPalette([]),
        ox: -1,
      );
      expect(boardHasBeadOutside([w], 52, 52), isFalse);
    });

    test('右/下出界同样判定', () {
      final w = PlacedWork(
        entry: entryOf(model(3, 3)),
        palette: const BeadPalette([]),
        ox: 51,
      );
      expect(boardHasBeadOutside([w], 52, 52), isTrue);
      final h = PlacedWork(
        entry: entryOf(model(3, 3)),
        palette: const BeadPalette([]),
        oy: 51,
      );
      expect(boardHasBeadOutside([h], 52, 52), isTrue);
    });

    test('完全在板内 → false（含贴边）', () {
      final w = PlacedWork(
        entry: entryOf(model(52, 52)),
        palette: const BeadPalette([]),
      );
      expect(boardHasBeadOutside([w], 52, 52), isFalse);
    });
  });

  group('拖动手势全链（板设置页）', () {
    testWidgets('拖到出界极限提示并禁用开始，拖回板内恢复', (tester) async {
      // 26×26 全豆作品（52 板上初始居中 ox=13）
      final e = entryOf(model(26, 26));
      await tester.pumpWidget(
        MaterialApp(home: BoardSetupPage(initial: e)),
      );
      await tester.pumpAndSettle();

      // 初始在板内：无出界提示，开始拼豆可用
      expect(find.textContaining("豆子超出豆板"), findsNothing);
      final startBtn = find.widgetWithText(FilledButton, "开始拼豆");
      FilledButton btn() => tester.widget<FilledButton>(startBtn);
      expect(btn().onPressed, isNotNull);

      // 单指拖动选中作品（initial 自带 _selected=0）：往左上大位移，
      // clamp 到 -W/2 = -13（上下左右全出界极限）
      final canvas = tester.getRect(find.byType(InteractiveViewer).first);
      final g = await tester.startGesture(canvas.center);
      await tester.pump(const Duration(milliseconds: 120));
      await g.moveBy(const Offset(-3000, -3000));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();

      // 出界（非空白格出板）→ 底部提示 + 开始禁用
      expect(find.textContaining("豆子超出豆板"), findsOneWidget);
      expect(btn().onPressed, isNull);

      // 拖回板中心：位移恰 26 格（-13 → 13）。画布含板外余量（26 宽作品
      // → 两侧各 (26+1)~/2=13 格，全幅 52+26=78 格）
      final cellX = canvas.width / (52 + 2 * ((26 + 1) ~/ 2));
      final cellY = canvas.height / (52 + 2 * ((26 + 1) ~/ 2));
      final g2 = await tester.startGesture(canvas.center);
      await tester.pump(const Duration(milliseconds: 120));
      await g2.moveBy(Offset(26 * cellX, 26 * cellY));
      await tester.pump();
      await g2.up();
      await tester.pumpAndSettle();

      expect(find.textContaining("豆子超出豆板"), findsNothing);
      expect(btn().onPressed, isNotNull);
    });
  });

  group('撤销/重做（板设置页）', () {
    testWidgets('拖动出界 → 撤销恢复板内 → 重做再次出界', (tester) async {
      final e = entryOf(model(26, 26));
      await tester.pumpWidget(
        MaterialApp(home: BoardSetupPage(initial: e)),
      );
      await tester.pumpAndSettle();

      // byTooltip 命中的是 RawTooltip 壳，按图标找 IconButton 本体
      IconButton undoBtn() =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo));
      IconButton redoBtn() =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.redo));

      // 初始无历史：撤销/重做都置灰
      expect(undoBtn().onPressed, isNull);
      expect(redoBtn().onPressed, isNull);

      // 拖到出界极限（同前测：clamp 到 -13 全出界）
      final canvas = tester.getRect(find.byType(InteractiveViewer).first);
      final g = await tester.startGesture(canvas.center);
      await tester.pump(const Duration(milliseconds: 120));
      await g.moveBy(const Offset(-3000, -3000));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(find.textContaining("豆子超出豆板"), findsOneWidget);

      // 拖动产生历史：撤销可按、重做仍置灰
      expect(undoBtn().onPressed, isNotNull);
      expect(redoBtn().onPressed, isNull);

      // 撤销：回到拖动前（板内居中），出界提示消失
      undoBtn().onPressed!();
      await tester.pumpAndSettle();
      expect(find.textContaining("豆子超出豆板"), findsNothing);
      expect(redoBtn().onPressed, isNotNull);

      // 重做：再次出界
      redoBtn().onPressed!();
      await tester.pumpAndSettle();
      expect(find.textContaining("豆子超出豆板"), findsOneWidget);
    });

    testWidgets('改动后 back 弹三键保存确认；撤销回已存态直接退出', (tester) async {
      final e = entryOf(model(26, 26));
      // 垫引导页再 push：根路由的 popDisposition 恒 bubble（back 关App
      // 语义），压栈后 PopScope 拦截/放行才有观测点
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.push(
                    ctx,
                    MaterialPageRoute(
                      builder: (_) => BoardSetupPage(initial: e),
                    ),
                  ),
                  child: const Text("open"),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();

      // 干净板（进页即基线）back：不弹框直接退出
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BoardSetupPage), findsNothing);

      // 重进 → 拖动改坐标 → dirty
      await tester.tap(find.text("open"));
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byType(InteractiveViewer).first);
      final g = await tester.startGesture(canvas.center);
      await tester.pump(const Duration(milliseconds: 120));
      await g.moveBy(const Offset(-3000, -3000));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();

      // back：弹「保存豆板？」三键（是/否/取消）
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text("保存豆板？"), findsOneWidget);

      // 取消：留在本页
      await tester.tap(find.text("取消"));
      await tester.pumpAndSettle();
      expect(find.byType(BoardSetupPage), findsOneWidget);
      expect(find.text("保存豆板？"), findsNothing);

      // 撤销回到进页基线（clean）→ back 直接退出，不再弹
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
          .onPressed!();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BoardSetupPage), findsNothing);
    });
  });
}
