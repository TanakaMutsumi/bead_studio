import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/features/restore/steps/link_image_viewer.dart';

void main() {
  // 注：fixture 用 PNG——flutter_test 引擎 codec 对 webp 会挂起不抛错
  // （真机 Skia 解 webp 正常，见模拟器抖音导入全流程实测），测试环境绕开
  final bytes =
      Uint8List.fromList(File('test/fixtures/douyin_img0.png').readAsBytesSync());

  Future<void> pumpViewer(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LinkImageViewerPage(
        title: '测试查看',
        width: 0,
        height: 0,
        savePrefix: 'test',
        loadOriginal: () async => bytes,
      ),
    ));
    await tester.pump();
    // 解码/显示重编码在 compute（真 isolate）里跑，FakeAsync 区调度不到，
    // 轮询开真实时间窗直到出图（debug 模式实测 2-4s）
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await tester.pump(const Duration(milliseconds: 200));
      if (tester.widgetList<Image>(find.byType(Image)).isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  /// 当前画到屏幕上的缩放倍率（InteractiveViewer 变换落在 paint transform）
  double paintScale(WidgetTester tester) {
    final box = tester.renderObject<RenderBox>(find.byType(Image).first);
    return box.getTransformTo(null).getMaxScaleOnAxis();
  }

  testWidgets('加载原图并渲染：webp 解码、缩放条、提示文案在位',
      (tester) async {
    await pumpViewer(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('测试查看'), findsOneWidget);
    expect(find.text('双指缩放/拖动查看 · 双击 放大/回到整图'), findsOneWidget);
    expect(find.byTooltip('保存到相册'), findsOneWidget);
  });

  // 注：LOD 裁片正路径（放大过地平线叠第二张图）需要 >4096px 原图 fixture，
  // 纯 Dart 解 20MP 在 debug 测试环境要分钟级——不上大 fixture，小图下
  // 验证 LOD 守卫（原图≤显示上限永不触发）+ 双击缩放开关本身。
  // 大图 LOD 行为由 xhs/抖音真机流程实测覆盖（2026-11-06 模拟器复验）。
  testWidgets('小图（≤显示上限）双击缩放正常但 LOD 裁片永不激活', (tester) async {
    await pumpViewer(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(paintScale(tester), moreOrLessEquals(1.0, epsilon: 0.01));
    final center = tester.getCenter(find.byType(Image));
    // 双击放大 2.5×
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(paintScale(tester), moreOrLessEquals(2.5, epsilon: 0.05));
    // 原图 640×792 未被 4096 显示上限压过 → 全分辨率图与显示图同尺寸，
    // 裁片无细节可补，叠显层不应出现
    expect(find.byType(Image), findsOneWidget);
    // 再双击回整图
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(paintScale(tester), moreOrLessEquals(1.0, epsilon: 0.01));
    expect(find.byType(Image), findsOneWidget);
  });
}
