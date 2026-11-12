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
///（拖到出界极限 → 底部提示 + 开始拼豆禁用；拖回板内恢复）
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
}
