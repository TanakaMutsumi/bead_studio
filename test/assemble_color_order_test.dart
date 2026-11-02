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
        orderAssembleColors(ids, totals, remainDoneA2, LegendSort.countDesc, codeOf),
        ["A10", "A1", "A2"],
      );
    });

    test('少→多：颗数升序，完成色仍垫后', () {
      expect(
        orderAssembleColors(ids, totals, remainDoneA2, LegendSort.countAsc, codeOf),
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
        orderAssembleColors(
          t.keys.toList(), t, r, LegendSort.position, codeOf),
        // A2/A1 完成（保持传入相对序 A2 在 A1 前），A10/A3 未完
        ["A10", "A3", "A2", "A1"],
      );
    });

    test('颗数并列按色号自然序破平', () {
      final t = {"A10": 2, "A1": 2, "A2": 2};
      final r = {"A10": 2, "A1": 2, "A2": 2};
      expect(
        orderAssembleColors(t.keys.toList(), t, r, LegendSort.countDesc, codeOf),
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
  });
}
