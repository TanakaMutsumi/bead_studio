import 'dart:io';

import 'package:bead_studio/core/app_snack_bar.dart';
import 'package:bead_studio/core/board_config.dart';
import 'package:bead_studio/core/draft_store.dart';
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/pattern_model.dart';
import 'package:bead_studio/features/board/assemble_page.dart';
import 'package:bead_studio/features/board/placed_work.dart';
import 'package:bead_studio/features/restore/restore_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 拼豆色条排序：orderAssembleColors（完成色垫后 + 四模式段内排序）/
/// legendSortFromName（存档名兼容）/ 整页交互（初始沿用作品 meta.sortMode、
/// 菜单切换、双击整色完成后排到条尾）
void main() {
  // 三色网格（3×2）：A1×2、A2×1、A10×3——A10 故意取双位数，
  // 字典序 A1<A10<A2 而色号自然序 A1<A2<A10，专验 code 模式不按字符串排
  const palette = BeadPalette([
    BeadColor("A1", "红", 0xFFCC2222),
    BeadColor("A2", "蓝", 0xFF2222CC),
    BeadColor("A10", "绿", 0xFF22AA22),
  ]);
  // 色号自然序：A1=0、A2=1、A10=2（查不到的垫大值）
  int codeOf(String id) => switch (id) {
        "A1" => 0,
        "A2" => 1,
        "A10" => 2,
        _ => 1 << 30,
      };

  group('orderAssembleColors', () {
    // 颗数：A1=2、A2=1、A10=3；A2 已拼完（剩余 0）
    final totals = {"A1": 2, "A2": 1, "A10": 3};
    final remainDoneA2 = {"A1": 2, "A2": 0, "A10": 3};
    final ids = totals.keys.toList();

    test('多→少：颗数降序，完成色整段垫后', () {
      expect(
        orderAssembleColors(
            ids, totals, remainDoneA2, LegendSort.countDesc, codeOf),
        ["A10", "A1", "A2"],
      );
    });

    test('少→多：颗数升序，完成色仍垫后', () {
      expect(
        orderAssembleColors(
            ids, totals, remainDoneA2, LegendSort.countAsc, codeOf),
        ["A1", "A10", "A2"],
      );
    });

    test('色号序：调色板自然序（A10 排 A2 后，不按字典序），完成色垫后', () {
      expect(
        orderAssembleColors(ids, totals, remainDoneA2, LegendSort.code, codeOf),
        ["A1", "A10", "A2"],
      );
    });

    test('位置序：段内保持传入序（首现序）不动', () {
      // 传入序故意与其它模式都不同：A2、A10、A1、A3
      final t = {"A2": 1, "A10": 3, "A1": 2, "A3": 2};
      final r = {"A2": 0, "A10": 3, "A1": 0, "A3": 2};
      expect(
        orderAssembleColors(t.keys.toList(), t, r, LegendSort.position, codeOf),
        // A2/A1 完成（保持传入相对序 A2 在 A1 前），A10/A3 未完
        ["A10", "A3", "A2", "A1"],
      );
    });

    test('颗数并列按色号自然序破平', () {
      final t = {"A10": 2, "A1": 2, "A2": 2};
      final r = {"A10": 2, "A1": 2, "A2": 2};
      expect(
        orderAssembleColors(
            t.keys.toList(), t, r, LegendSort.countDesc, codeOf),
        ["A1", "A2", "A10"],
      );
    });

    test('全部完成：全段都在后（顺序仍按模式）', () {
      final r = {"A1": 0, "A2": 0, "A10": 0};
      expect(
        orderAssembleColors(ids, totals, r, LegendSort.countDesc, codeOf),
        ["A10", "A1", "A2"],
      );
    });
  });

  group('legendSortFromName', () {
    test('四模式名 <-> 枚举', () {
      expect(legendSortFromName("code"), LegendSort.code);
      expect(legendSortFromName("countDesc"), LegendSort.countDesc);
      expect(legendSortFromName("countAsc"), LegendSort.countAsc);
      expect(legendSortFromName("position"), LegendSort.position);
    });
    test('旧档 reading = 位置序；null/未知名回 null（调用方给默认）', () {
      expect(legendSortFromName("reading"), LegendSort.position);
      expect(legendSortFromName(null), isNull);
      expect(legendSortFromName("bogus"), isNull);
    });
  });

  group('拼豆页色条交互', () {
    Future<void> pumpPage(WidgetTester tester, {String? sortMode}) async {
      // 手机逻辑宽（默认 800 比真机宽，摘要行加了排序钮后窄屏溢出
      // 在默认画布上验不出来；溢出会以 RenderFlex 异常使用例失败）
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = PatternModel(
        width: 3,
        height: 2,
        grid: [0, 0, 1, 2, 2, 2],
        paletteIds: [for (final c in palette.colors) c.id],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AssemblePage(
            works: [
              PlacedWork(
                entry: WorkEntry(
                  file: File("fake.json"),
                  name: "测试",
                  folder: "",
                  updatedAt: DateTime.now(),
                  model: model,
                  sortMode: sortMode,
                ),
                palette: palette,
              ),
            ],
            board: const BoardConfig(w: 3, h: 2),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 色条从左到右的色号序（画布是 CustomPaint 不进 widget 树，
    // 色号文本只会命中色条条目）
    List<String> chipOrder(WidgetTester tester) {
      const ids = ["A1", "A2", "A10"];
      final dx = {
        for (final id in ids) id: tester.getTopLeft(find.text(id)).dx,
      };
      return [...ids]..sort((a, b) => dx[a]!.compareTo(dx[b]!));
    }

    testWidgets('初始沿用作品 meta.sortMode（多→少），切换色号序生效', (tester) async {
      await pumpPage(tester, sortMode: "countDesc");
      // 多→少：A10(3) A1(2) A2(1)；排序下拉标签同步显示当前模式
      expect(find.text("多→少"), findsOneWidget);
      expect(chipOrder(tester), ["A10", "A1", "A2"]);

      await tester.tap(find.text("多→少"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("色号序").last);
      await tester.pumpAndSettle();
      // 色号自然序：A1 A2 A10（A10 双位数不按字典序插到 A2 前）
      expect(chipOrder(tester), ["A1", "A2", "A10"]);
    });

    testWidgets('双击整色完成 -> 剩余清零并排到条尾（色号序下）', (tester) async {
      await pumpPage(tester, sortMode: "code");
      expect(chipOrder(tester), ["A1", "A2", "A10"]);

      // 双击 A2（范围内仅 1 颗）= 整色标记已放
      await tester.tap(find.text("A2"));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text("A2"));
      await tester.pumpAndSettle();
      expect(find.text("0/1"), findsOneWidget);
      // A2 完成垫后：A1 A10 | A2
      expect(chipOrder(tester), ["A1", "A10", "A2"]);
      // 双击触发的顶部提示带 3 秒自动消失 Timer，用例末尾须显式收掉
      //（挂起 Timer 判失败，见 app_snack_bar_test 头注释）
      AppSnackBar.dismiss();
    });

    testWidgets('meta.sortMode 为空/旧名也有合理初始（reading=位置序）', (tester) async {
      await pumpPage(tester, sortMode: "reading");
      // 位置序 = 网格扫描首现序：A1(格0) A2(格2) A10(格3)
      expect(find.text("位置序"), findsOneWidget);
      expect(chipOrder(tester), ["A1", "A2", "A10"]);
    });

    testWidgets('切换排列模式文案定宽，按钮自身宽度不变（2026-11-11）', (tester) async {
      await pumpPage(tester);
      final dx0 = tester.getTopLeft(find.text("只显示色号")).dx;

      ///< 「只显示色号」(5字) -> 「横向排列」(4字)：按钮内文本按最宽候选
      ///< 定宽居中，按钮自身宽度不变 -> 左缘 dx 不动（2026-11-12 色号序
      ///< 已移到底部色条行，顶部只剩分组后的两个文字钮）
      await tester.tap(find.text("只显示色号"));
      await tester.pumpAndSettle();
      expect(find.text("横向排列"), findsOneWidget);
      expect(tester.getTopLeft(find.text("横向排列")).dx, dx0);

      await tester.tap(find.text("横向排列"));
      await tester.pumpAndSettle();
      expect(find.text("竖向排列"), findsOneWidget);
      expect(tester.getTopLeft(find.text("竖向排列")).dx, dx0);
    });

    testWidgets('选中色号出现取消选色钮，点击清空选中（批量行槽位恒占，画布不动）', (tester) async {
      await pumpPage(tester);
      expect(find.text("取消选色"), findsNothing);

      // 单击芯片选色（注册了双击，单击延迟一拍——过双击窗口后生效）
      await tester.tap(find.text("A2"));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text("取消选色"), findsOneWidget);

      await tester.tap(find.text("取消选色"));
      await tester.pumpAndSettle();
      expect(find.text("取消选色"), findsNothing);
    });

    ///< 批量行槽位恒占位（2026-11-12 用户反馈：选色后批量行出现把画布
    ///< 顶起 ~40px 突然缩移）：空槽 <-> 批量行 <-> 确认条三态切换，
    ///< 画布（InteractiveViewer）矩形全程不变
    testWidgets('批量行出现/消失/换确认条，画布尺寸全程不变（2026-11-12）', (tester) async {
      await pumpPage(tester);
      final r0 = tester.getRect(find.byType(InteractiveViewer).first);

      // 选色 -> 批量行出现
      await tester.tap(find.text("A10"));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text("取消选色"), findsOneWidget);
      expect(tester.getRect(find.byType(InteractiveViewer).first), r0);

      // 长按圈选 -> 确认条替换批量行
      final rect = r0;
      final g = await tester.startGesture(
        Offset(rect.left + 0.5 * rect.width / 3,
            rect.top + 1.5 * rect.height / 2),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 1 颗「"), findsOneWidget);
      expect(tester.getRect(find.byType(InteractiveViewer).first), r0);

      // 确认 -> 批量行回来；取消选色 -> 空槽
      await tester.tap(find.text("设为已完成"));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(InteractiveViewer).first), r0);
      await tester.tap(find.text("取消选色"));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(InteractiveViewer).first), r0);

      // snackbar 3 秒自动消失 Timer 收尾（挂起 Timer 判失败）
      AppSnackBar.dismiss();
    });

    testWidgets('圈选核对态：单击/长按可追加圈选，再点已圈格移出（2026-11-12）', (tester) async {
      await pumpPage(tester);
      // 选 A10（格 (0,1)(1,1)(2,1) 共 3 颗）
      await tester.tap(find.text("A10"));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      Offset cellCenter(int x, int y) {
        final rect = tester.getRect(find.byType(InteractiveViewer).first);
        return Offset(
          rect.left + (x + 0.5) * rect.width / 3,
          rect.top + (y + 0.5) * rect.height / 2,
        );
      }

      // 长按 0.5s（系统长按时限）原地起手松手，进入核对态：确认条就位、
      ///< 不再弹窗（2026-11-12 需求）。（不滑动——对角线路径可能路过
      ///< (1,1) 的 A10 格使计数不确定，追加路径由后面的单击/长按覆盖）
      final g = await tester.startGesture(cellCenter(0, 1));
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pumpAndSettle();
      // snackbar 也含「已圈选 1 颗」，确认条用「」限定、消失断言用其独有文案
      expect(find.textContaining("已圈选 1 颗「A10」"), findsOneWidget);
      expect(find.text("设为已完成"), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing); // 弹窗已废

      // 核对态单击追加：点 (1,1) A10 未放格 -> 圈选 2 颗
      await tester.tapAt(cellCenter(1, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 2 颗「A10」"), findsOneWidget);
      expect(find.text("已放 0/6 · 0%"), findsOneWidget); // 不落已放

      // 核对态长按追加：长按 (2,1) 松手 -> 3 颗
      final g2 = await tester.startGesture(cellCenter(2, 1));
      await tester.pump(const Duration(milliseconds: 600));
      await g2.up();
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 3 颗「A10」"), findsOneWidget);

      // 单击已圈格 -> 移出（3 -> 2）
      await tester.tapAt(cellCenter(2, 1));
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 2 颗「A10」"), findsOneWidget);

      // 点非选中色格（A1）不追加也不移出
      await tester.tapAt(cellCenter(0, 0));
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 2 颗「A10」"), findsOneWidget);

      // 核对态屏蔽换色：点色条不生效（仍处 A10 核对态）
      await tester.tap(find.text("A1"));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 2 颗「A10」"), findsOneWidget);

      await tester.tap(find.text("设为已完成"));
      await tester.pumpAndSettle();
      expect(find.text("已放 2/6 · 33%"), findsOneWidget);
      expect(find.textContaining("可拖动缩放核对"), findsNothing); // 确认条撤下

      // 手势/snackbar 等 Timer 收尾（挂起 Timer 判失败）
      AppSnackBar.dismiss();
    });

    testWidgets('圈选核对态点取消 -> 追加的也一并清空、不落账（进度不动）', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text("A10"));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(InteractiveViewer).first);
      final g = await tester.startGesture(
        Offset(rect.left + 0.5 * rect.width / 3,
            rect.top + 1.5 * rect.height / 2),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 1 颗「A10」"), findsOneWidget);
      // 单击追加第二颗再取消：全清
      await tester.tapAt(Offset(
          rect.left + 1.5 * rect.width / 3, rect.top + 1.5 * rect.height / 2));
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 2 颗「A10」"), findsOneWidget);
      await tester.tap(find.text("取消").last);
      await tester.pumpAndSettle();
      expect(find.text("已放 0/6 · 0%"), findsOneWidget);
      expect(find.textContaining("可拖动缩放核对"), findsNothing);
      AppSnackBar.dismiss();
    });
  });

  group('拼豆进度数值与范围', () {
    /// 两件作品：work0 = 3×2（A1×2 A2×1 A10×3，共 6 颗），work1 = 2×1
    ///（B1×2）；板 4×3。全部方案进度 = 两件合并，单件方案只算所选作品
    Future<void> pumpTwoWorks(WidgetTester tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const palette1 = BeadPalette([
        BeadColor("A1", "红", 0xFFCC2222),
        BeadColor("A2", "蓝", 0xFF2222CC),
        BeadColor("A10", "绿", 0xFF22AA22),
      ]);
      const palette2 = BeadPalette([BeadColor("B1", "黑", 0xFF111111)]);
      WorkEntry entry(String name, PatternModel model) => WorkEntry(
            file: File("fake_$name.json"),
            name: name,
            folder: "",
            updatedAt: DateTime.now(),
            model: model,
          );
      await tester.pumpWidget(
        MaterialApp(
          home: AssemblePage(
            works: [
              PlacedWork(
                entry: entry(
                  "w0",
                  PatternModel(
                    width: 3,
                    height: 2,
                    grid: [0, 0, 1, 2, 2, 2],
                    paletteIds: [for (final c in palette1.colors) c.id],
                  ),
                ),
                palette: palette1,
              ),
              PlacedWork(
                entry: entry(
                  "w1",
                  PatternModel(
                    width: 2,
                    height: 1,
                    grid: [0, 0],
                    paletteIds: [for (final c in palette2.colors) c.id],
                  ),
                ),
                palette: palette2,
                oy: 2,
              ),
            ],
            board: const BoardConfig(w: 4, h: 3),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('进度行显示 已放/总数/百分比，且随单件/全部切换口径', (tester) async {
      await pumpTwoWorks(tester);
      expect(find.text("已放 0/8 · 0%"), findsOneWidget);

      // 切到单件作品（默认选 work0 = 6 颗）：进度只算它
      await tester.tap(find.text("单件作品"));
      await tester.pumpAndSettle();
      expect(find.text("已放 0/6 · 0%"), findsOneWidget);

      // 双击 A2 完成该色（scope=work0，A2 仅 1 颗）-> 1/6 = 17%
      await tester.tap(find.text("A2"));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text("A2"));
      await tester.pumpAndSettle();
      expect(find.text("已放 1/6 · 17%"), findsOneWidget);

      // 切回全部作品：两件合并 1/8 = 13%
      await tester.tap(find.text("全部作品"));
      await tester.pumpAndSettle();
      expect(find.text("已放 1/8 · 13%"), findsOneWidget);
      AppSnackBar.dismiss();
    });

    testWidgets('圈选核对态：作品切换下拉整钮禁用，点不开菜单（2026-11-12）', (tester) async {
      await pumpTwoWorks(tester);
      await tester.tap(find.text("单件作品"));
      await tester.pumpAndSettle();
      await tester.tap(find.text("A2"));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // 下拉可用（未进核对态）
      final popup = find.byType(PopupMenuButton<int>);
      expect(popup, findsOneWidget);
      expect(
        tester.widget<PopupMenuButton<int>>(popup).enabled,
        isTrue,
      );

      // 长按 A2 格（板 4×3，A2 在 w0 的 (2,0)）进入核对态
      final rect = tester.getRect(find.byType(InteractiveViewer).first);
      final g = await tester.startGesture(
        Offset(
            rect.left + 2.5 * rect.width / 4, rect.top + 0.5 * rect.height / 3),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.textContaining("已圈选 1 颗「"), findsOneWidget);

      // 整钮禁用 + 点了也不弹菜单（2026-11-12 用户反馈：只挡 onSelected
      // 菜单照样弹出）
      expect(tester.widget<PopupMenuButton<int>>(popup).enabled, isFalse);
      await tester.tap(popup);
      await tester.pumpAndSettle();
      expect(find.text("w1"), findsNothing); // 菜单没开（w1 只在菜单里）
      expect(find.text("w0"), findsOneWidget); // 下拉标签仍是当前作品
      AppSnackBar.dismiss();
    });
  });
}
