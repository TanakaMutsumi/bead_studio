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
/// boardHasBeadOutside（豆级出界判定，空白格出界不拦）/ boardPads
///（四侧实际悬挂余量，全在板内=0）/ 拖动手势全链（拖到出界极限 →
/// 底部提示 + 开始拼豆禁用；拖回板内恢复）/ 撤销重做（拖动出界→undo
/// 恢复→redo 再出界）/ dirty 三键退出 / 选中作品浮动变换工具条 /
/// 分割数「无」档
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

  group('boardPads 四侧实际悬挂量', () {
    test('全在板内 → 四侧 0（画布即板）', () {
      final w = PlacedWork(
        entry: entryOf(model(10, 8)),
        palette: const BeadPalette([]),
        ox: 5,
        oy: 5,
      );
      expect(boardPads([w], 52, 52), (0, 0, 0, 0));
    });

    test('左悬挂 k 格只有左余量（其余三侧 0）', () {
      final w = PlacedWork(
        entry: entryOf(model(10, 8)),
        palette: const BeadPalette([]),
        ox: -4,
        oy: 0,
      );
      expect(boardPads([w], 52, 52), (4, 0, 0, 0));
    });

    test('多件各侧取最大（旧对称半界法会四侧都留满）', () {
      final a = PlacedWork(
        entry: entryOf(model(10, 8)),
        palette: const BeadPalette([]),
        ox: -3,
        oy: 20,
      );
      final b = PlacedWork(
        entry: entryOf(model(6, 6)),
        palette: const BeadPalette([]),
        ox: 48,
        oy: -2,
      ); // 右缘 54 → 右出 2
      expect(boardPads([a, b], 52, 52), (3, 2, 2, 0));
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

      // 拖回板中心：位移恰 26 格（-13 → 13）。余量按实际悬挂算：拖出后
      // 左/上两侧各 13 格、右/下 0（全幅 65 格）。起手点取作品本体内——
      // 浮动变换工具条横在作品正下方，canvas.center 恰被它盖住会吞手势
      final cell = canvas.width / 65;
      final g2 = await tester.startGesture(
        canvas.topLeft + Offset(13 * cell, 13 * cell),
      );
      await tester.pump(const Duration(milliseconds: 120));
      await g2.moveBy(Offset(26 * cell, 26 * cell));
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

  group('选中作品浮动工具条（板设置页）', () {
    testWidgets('旋转/翻转四钮随选中出现，旋转产生历史可撤销', (tester) async {
      final e = entryOf(model(26, 26));
      await tester.pumpWidget(
        MaterialApp(home: BoardSetupPage(initial: e)),
      );
      await tester.pumpAndSettle();

      // initial 自带选中：浮动条四钮就位（AppBar 里不再有变换钮——
      // 全页 Icons.rotate_right 只此一处）
      expect(
        find.widgetWithIcon(IconButton, Icons.rotate_left),
        findsOneWidget,
      );
      expect(
        find.widgetWithIcon(IconButton, Icons.rotate_right),
        findsOneWidget,
      );
      expect(find.widgetWithIcon(IconButton, Icons.flip), findsNWidgets(2));
      IconButton undoBtn() => tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo));

      // 初始干净（载入即基线）：撤销置灰 → 旋转产生历史 → 撤销回到基线
      expect(undoBtn().onPressed, isNull);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.rotate_right));
      await tester.pumpAndSettle();
      expect(undoBtn().onPressed, isNotNull);
      undoBtn().onPressed!();
      await tester.pumpAndSettle();
      expect(undoBtn().onPressed, isNull);
    });

    testWidgets('点空白取消选中后浮动条消失', (tester) async {
      final e = entryOf(model(26, 26));
      await tester.pumpWidget(
        MaterialApp(home: BoardSetupPage(initial: e)),
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithIcon(IconButton, Icons.rotate_right),
        findsOneWidget,
      );

      // 点画布空白处（板角远离作品）：选中取消，浮动条随作品走也随选中消
      final canvas = tester.getRect(find.byType(InteractiveViewer).first);
      await tester.tapAt(Offset(canvas.right - 8, canvas.bottom - 8));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithIcon(IconButton, Icons.rotate_right),
        findsNothing,
      );
    });
  });

  group('分割数「无」档（板设置页）', () {
    testWidgets('选无：信息行无分割线、相位步进器禁用、撤销可回', (tester) async {
      final e = entryOf(model(26, 26));
      await tester.pumpWidget(
        MaterialApp(home: BoardSetupPage(initial: e)),
      );
      await tester.pumpAndSettle();

      // 打开分割数下拉（当前值文本「每5格」），选「无」
      await tester.tap(find.text("每5格").first);
      await tester.pumpAndSettle();
      await tester.tap(find.text("无").last);
      await tester.pumpAndSettle();

      // 信息行切换口径；相位步进器禁用（竖线/横线各两个方向钮）
      expect(find.textContaining("无分割线"), findsOneWidget);
      IconButton stepBtn(IconData i) =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, i));
      expect(stepBtn(Icons.chevron_left).onPressed, isNull);
      expect(stepBtn(Icons.chevron_right).onPressed, isNull);
      expect(stepBtn(Icons.expand_more).onPressed, isNull);
      expect(stepBtn(Icons.expand_less).onPressed, isNull);

      // 画布正常重绘（interval=0 除零守卫），撤销回到每5格
      IconButton undoBtn() =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo));
      expect(undoBtn().onPressed, isNotNull);
      undoBtn().onPressed!();
      await tester.pumpAndSettle();
      expect(find.textContaining("无分割线"), findsNothing);
      expect(find.text("每5格"), findsOneWidget);
    });
  });
}
