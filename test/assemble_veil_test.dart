import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bead_studio/core/board_config.dart';
import 'package:bead_studio/core/draft_store.dart';
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/pattern_model.dart';
import 'package:bead_studio/features/board/board_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 已放豆压暗层级（2026-11-13 用户两次定稿：压暗不要提亮，白罩已废）：
/// 选色中——选中色已放豆轻压暗（lerp _dimGray 0.35）+ 鲜艳绿勾、非选中
/// 色已放豆深压暗（0.75）+ 暗一档绿勾（两档勾亮度不足都向白提亮保证比
/// 豆亮）；未选色但有进度时，已放豆向中性灰 _idleGray 混 0.4 退后、
/// 对勾同步混灰、未放豆保持原色醒目。画布 CustomPaint 不进语义树，用
/// RepaintBoundary 出图逐格验色
void main() {
  const e11 = Color(0xFFF7DAD4);

  ///< E11=(247,218,212) 浅粉
  const c16 = Color(0xFF1858A2);

  ///< C16=(24,88,162) 深蓝
  testWidgets('选中色已放=轻压暗+鲜艳绿勾；非选中已放=深压暗+暗绿勾；未选色已放退后', (tester) async {
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

    // —— 无选中（有进度）：**已放**格向中灰退后（对勾同步灰）、
    // **未放**豆保持原色醒目（2026-11-12 用户反转定稿：任务视角）
    final e11Dim = await cellColor(100, 100); // 已放 E11：退后
    expect(e11Dim, isNot(e11));
    expect(e11Dim.red, lessThan(e11.red)); // 浅色向中灰下沉
    expect(e11Dim.blue, lessThan(e11.blue));
    expect(await cellColor(300, 100), e11); // 未放 E11：原色
    final c16Dim = await cellColor(100, 300); // 已放 C16：退后
    expect(c16Dim, isNot(c16));
    expect(c16Dim.red, greaterThan(c16.red)); // 深色向中灰抬升
    expect(await cellColor(300, 300), c16); // 未放 C16（格 4）：原色

    // —— 选中 E11（压暗层级定稿）：已放 E11 **轻压暗**（lerp _dimGray
    //    0.35——三通道下沉，白罩提亮方案两度被否），未放 E11 仍原色；
    //    非选中色（C16 已放格）深压暗 0.75，两级拉开
    setOuter(() => hi = "E11");
    await tester.pumpAndSettle();
    final dimSel = await cellColor(100, 100);
    expect(dimSel, isNot(e11));
    expect(dimSel.red, lessThan(e11.red)); // 压暗 = 三通道都向 _dimGray 沉
    expect(dimSel.green, lessThan(e11.green));
    expect(dimSel.blue, lessThan(e11.blue));
    expect(await cellColor(300, 100), e11); // 未放 E11：原色不变
    final dimmed = await cellColor(100, 300); // 已放 C16（非选中色）
    expect(dimmed.red, greaterThan(c16.red)); // 深色向压暗基色抬升（≠原色）
    // 选中色已放压暗幅度 0.35 < 非选中 0.75：E11 两态亮度差可辨
    //（浅色豆 0.35 档 ≈ (180,164,166)，明显浅于 0.75 档的深灰区）
    expect(dimSel.red, greaterThan(150));

    // —— 对勾层级（定稿）：选中色已放 = 鲜艳绿（浅底上 _checkOver 向
    //    白提亮一档保证比豆亮）；非选中色已放 = 暗一档绿（深底无需提亮）
    final d = await tester.runAsync<ByteData?>(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 1.0);
      return img.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    expect(d, isNotNull);
    final b = d!.buffer.asUint8List();
    int countNear(Rect r, Color c, int tol) {
      var n = 0;
      for (var y = r.top.toInt(); y < r.bottom; y++) {
        for (var x = r.left.toInt(); x < r.right; x++) {
          final o = (y * 600 + x) * 4;
          if ((b[o] - c.red).abs() <= tol &&
              (b[o + 1] - c.green).abs() <= tol &&
              (b[o + 2] - c.blue).abs() <= tol) {
            n++;
          }
        }
      }
      return n;
    }

    // vivid(76,175,80) luma 0.33 < 浅粉压暗底(180,164,166) luma 0.39 →
    // _checkOver 提亮一步 ≈ lerp(白,0.35) = (139,203,141)
    const vividLift = Color.fromARGB(255, 139, 203, 141);
    const darkGreen = Color.fromARGB(255, 46, 125, 50);
    final eCell = const Rect.fromLTWH(30, 60, 150, 120); // 已放 E11 格
    final cCell = const Rect.fromLTWH(30, 260, 150, 120); // 已放 C16 格
    expect(countNear(eCell, vividLift, 14), greaterThan(0),
        reason: "选中色已放勾=提亮鲜艳绿");
    expect(countNear(eCell, darkGreen, 10), equals(0),
        reason: "选中色已放勾不出暗绿");
    expect(countNear(cCell, darkGreen, 12), greaterThan(0),
        reason: "非选中色已放勾=暗绿（深底无需提亮）");
    expect(countNear(cCell, vividLift, 10), equals(0),
        reason: "非选中色已放勾不出提亮绿");
  });

  ///< 单件口径范围外作品（dimScope）：未选色时整件略灰——含已放格与
  ///< 对勾（2026-11-12 用户反馈：未放退后上线后范围内/外都按进度退后，
  ///< 「当前拼哪件」的区分没了）。范围内保持已放原色+鲜绿勾
  testWidgets('单件口径：范围外作品未选色时整件略灰（含已放格与对勾）', (tester) async {
    tester.view.physicalSize = const Size(600, 460);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 板 6×2：左半 A（范围内），右半 B（范围外 dimScope）。各 3×2
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: boundaryKey,
            child: Center(
              child: SizedBox(
                width: 600,
                height: 400,
                child: CustomPaint(
                  painter: BoardPainter(
                    board: const BoardConfig(w: 6, h: 2),
                    showLabels: false,
                    items: [
                      BoardPaintItem(
                        model: model,
                        palette: palette,
                        ox: 0,
                        oy: 0,
                        placedCells: const {0, 3},
                      ),
                      BoardPaintItem(
                        model: model,
                        palette: palette,
                        ox: 3,
                        oy: 0,
                        placedCells: const {0, 3},
                        dimScope: true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Color? sample(ByteData? d, int x, int y) {
      if (d == null) return null;
      final b = d.buffer.asUint8List();
      final o = (y * 600 + x) * 4;
      return Color.fromARGB(255, b[o], b[o + 1], b[o + 2]);
    }

    final d = await tester.runAsync<ByteData?>(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 1.0);
      return img.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    expect(d, isNotNull);

    // 格 100px 宽 200px 高：A 在 x0-300，B 在 x300-600
    //（2026-11-12 反转定稿：已放退后+灰勾，未放原色醒目）
    // A 已放 E11 (0,0)：退后；A 未放 E11：原色
    final aPlaced = sample(d, 50, 100)!;
    expect(aPlaced, isNot(e11));
    expect(aPlaced.red, lessThan(e11.red)); // 浅色向中灰下沉
    expect(sample(d, 250, 100), e11); // A 未放 E11：原色
    // A 已放 C16：深色向中灰抬升 ≠ 原色；A 未放 C16：原色
    final aPlacedDark = sample(d, 50, 300)!;
    expect(aPlacedDark, isNot(c16));
    expect(aPlacedDark.red, greaterThan(c16.red));

    ///< A 未放 C16 = 扁平格 4（板列 1 下排）；列 2 下排是空格勿取
    expect(sample(d, 150, 300), c16);
    // B（范围外 dimScope）整件略灰：已放与未放同值（均 0.4 中灰），
    // 与 A 已放退后同款观感
    expect(sample(d, 350, 100), aPlaced);
    expect(sample(d, 550, 100), aPlaced);

    // 对勾：未选色时已放对勾统一混灰（lerp 0.45 → ~(87,135,101)），
    // A/B 都不出鲜绿
    int countNear(ByteData? dd, Rect r, Color c, int tol) {
      final b = dd!.buffer.asUint8List();
      var n = 0;
      for (var y = r.top.toInt(); y < r.bottom; y++) {
        for (var x = r.left.toInt(); x < r.right; x++) {
          final o = (y * 600 + x) * 4;
          if ((b[o] - c.red).abs() <= tol &&
              (b[o + 1] - c.green).abs() <= tol &&
              (b[o + 2] - c.blue).abs() <= tol) {
            n++;
          }
        }
      }
      return n;
    }

    const vivid = Color.fromARGB(255, 46, 125, 50);
    const muted = Color.fromARGB(255, 87, 135, 101);
    final aCell = const Rect.fromLTWH(20, 80, 60, 140); // A 已放格内域
    final bCell = const Rect.fromLTWH(320, 80, 60, 140); // B 已放格内域
    expect(countNear(d, aCell, muted, 12), greaterThan(0), reason: "A 对勾混灰");
    expect(countNear(d, aCell, vivid, 8), equals(0), reason: "A 不出鲜绿");
    expect(countNear(d, bCell, muted, 12), greaterThan(0), reason: "B 对勾混灰");
    expect(countNear(d, bCell, vivid, 8), equals(0), reason: "B 不出鲜绿");
  });

  ///< 圈选待确认 overlay 自适应（2026-11-12 用户反馈：C16 类蓝豆上
  ///< 蓝框看不见）：蓝/琥珀两候选按 WCAG 对比度对底色取高——浅底
  ///<（E11 粉）保持蓝框，蓝豆（C16）换琥珀框
  testWidgets('圈选 overlay：蓝豆换琥珀框、浅色豆保持蓝框', (tester) async {
    tester.view.physicalSize = const Size(600, 460);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
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

                        ///< pending：格 0=E11（浅粉），格 3=C16（深蓝）
                        pendingCells: const {0, 3},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final d = await tester.runAsync<ByteData?>(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 1.0);
      return img.toByteData(format: ui.ImageByteFormat.rawRgba);
    });
    expect(d, isNotNull);
    final b = d!.buffer.asUint8List();

    ///< 框色常量须与 painter 一致
    const blueRing = Color.fromARGB(255, 21, 101, 192);
    const amberRing = Color.fromARGB(255, 245, 124, 0);
    int countNear(Rect r, Color c, int tol) {
      var n = 0;
      for (var y = r.top.toInt(); y < r.bottom; y++) {
        for (var x = r.left.toInt(); x < r.right; x++) {
          final o = (y * 600 + x) * 4;
          if ((b[o] - c.red).abs() <= tol &&
              (b[o + 1] - c.green).abs() <= tol &&
              (b[o + 2] - c.blue).abs() <= tol) {
            n++;
          }
        }
      }
      return n;
    }

    ///< 板内容因 Center 下移 30px：格 0 = E11 区 y30-230（浅底 → 蓝框）；
    ///格 3 = C16 区 y230-430（蓝底 → 琥珀框）。环画在格边内 ~0-3px，
    ///板外框黑线会把贴边像素混暗（探针实测 x=1 环色被混 ~10-20%），
    ///取左边条带 x1-3 + 宽容差
    final e0 = Rect.fromLTWH(1, 50, 3, 150);
    final c3 = Rect.fromLTWH(1, 250, 3, 150);
    expect(countNear(e0, blueRing, 55), greaterThan(0), reason: "E11 上蓝框");
    expect(countNear(e0, amberRing, 30), equals(0), reason: "E11 上不出琥珀");
    expect(countNear(c3, amberRing, 55), greaterThan(0), reason: "C16 上琥珀框");
    expect(countNear(c3, blueRing, 30), equals(0), reason: "C16 上不出蓝框");
  });
}
