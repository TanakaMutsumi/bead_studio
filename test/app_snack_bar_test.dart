import 'package:bead_studio/core/app_snack_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 顶部提示条行为：滑入显示 / 3 秒自动消失 / 连击顶替 / 不拦截点击
///
/// 注意：每条用例末尾必须显式 AppSnackBar.dismiss()——3 秒自动消失的
/// Timer 在用例结束时仍挂起会判失败，而 addTearDown 回调在本版
/// flutter_test 的挂起 Timer 检查之后才执行（实测救不了），只能测试体
/// 内同步取消。
void main() {
  Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SizedBox.expand()),
        ),
      );

  testWidgets('show 后顶部出现提示，3 秒后自动消失', (tester) async {
    await pumpHost(tester);
    AppSnackBar.show(tester.element(find.byType(Scaffold)), "提示内容");
    await tester.pump(); // 首帧（动画起点）
    await tester.pump(const Duration(milliseconds: 300)); // 滑入完成
    expect(find.text("提示内容"), findsOneWidget);

    await tester.pump(const Duration(seconds: 3)); // 到期自动移除
    await tester.pump();
    expect(find.text("提示内容"), findsNothing);
    AppSnackBar.dismiss();
  });

  testWidgets('连续 show 顶替旧提示，只显示最新一条', (tester) async {
    await pumpHost(tester);
    final ctx = tester.element(find.byType(Scaffold));
    AppSnackBar.show(ctx, "第一条");
    await tester.pump();
    AppSnackBar.show(ctx, "第二条");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text("第一条"), findsNothing);
    expect(find.text("第二条"), findsOneWidget);
    AppSnackBar.dismiss();
  });

  testWidgets('提示出现在屏幕上半区（AppBar 下缘），不在底部', (tester) async {
    await pumpHost(tester);
    AppSnackBar.show(tester.element(find.byType(Scaffold)), "顶部提示");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 测试画布 800×600 逻辑像素，提示条在 top=56（AppBar 下缘）附近
    final rect = tester.getRect(find.text("顶部提示"));
    expect(rect.center.dy, lessThan(300));
    AppSnackBar.dismiss();
  });

  testWidgets('提示条不拦截其覆盖区域的点击（IgnorePointer）', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tapped = true,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    final ctx = tester.element(find.byType(GestureDetector));
    AppSnackBar.show(ctx, "透明提示");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 点在提示文字正中：应穿透到底层 GestureDetector
    await tester.tap(find.text("透明提示"), warnIfMissed: false);
    expect(tapped, isTrue);
    AppSnackBar.dismiss();
  });
}
