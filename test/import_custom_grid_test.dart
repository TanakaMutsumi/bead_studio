/// 图片转换页：自定义格子数（预设 + 无上限宽×高对话框）UI 行为
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/features/import/import_page.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    // 页面是 ListView：预览区 AspectRatio(1) 在默认 800×600 视口就占满
    // 高度，格子数段在屏外不会被构建——拉高视口让全表单可见
    tester.view.physicalSize = const Size(412, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: ImportPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('默认 52×52 预设选中，信息行显示颗数', (tester) async {
    await pumpPage(tester);
    expect(find.text("52×52"), findsOneWidget);
    expect(find.text("52×52 = 2704 颗"), findsOneWidget);
  });

  testWidgets('预设切换到 29×29 更新信息行', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text("29×29"));
    await tester.pumpAndSettle();
    expect(find.text("29×29 = 841 颗"), findsOneWidget);
  });

  testWidgets('自定义对话框输入 111×77 生效', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text("自定义"));
    await tester.pumpAndSettle();
    expect(find.text("自定义格子数"), findsOneWidget);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), "111");
    await tester.pump();
    await tester.enterText(fields.at(1), "77");
    await tester.pump();

    // 对话框底部实时提示
    expect(find.text("111×77 = 8547 颗"), findsOneWidget);

    await tester.tap(find.text("确定"));
    await tester.pumpAndSettle();
    expect(find.text("111×77 = 8547 颗"), findsOneWidget);
    // 预设四档都不再选中 -> 自定义段高亮（信息行已切换为自定义值）
    expect(find.text("52×52 = 2704 颗"), findsNothing);
  });

  testWidgets('超大格（500×500）提示耗时，不设上限', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text("自定义"));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), "500");
    await tester.pump();
    await tester.enterText(fields.at(1), "500");
    await tester.pump();
    expect(
      find.text("500×500 = 250000 颗 · 格子很多，转换耗时较长"),
      findsOneWidget,
    );
    await tester.tap(find.text("确定"));
    await tester.pumpAndSettle();
    expect(find.textContaining("250000 颗"), findsOneWidget);
  });

  testWidgets('非法输入（空/0）确定被拦截', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text("自定义"));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), "30");
    await tester.pump();
    await tester.enterText(fields.at(1), "0");
    await tester.pump();
    await tester.tap(find.text("确定"));
    await tester.pump();
    // 对话框仍在（未通过校验）+ 拦截提示弹出（对话框 hint 与 SnackBar 同文案
    // 各一处），页面信息行未变
    expect(find.text("自定义格子数"), findsOneWidget);
    expect(find.text("宽和高都要 ≥1"), findsWidgets);
    expect(find.text("52×52 = 2704 颗"), findsOneWidget);
    // 排干 SnackBar 3s 定时器
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('取消保留原值', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text("自定义"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("取消"));
    await tester.pumpAndSettle();
    expect(find.text("52×52 = 2704 颗"), findsOneWidget);
  });
}
