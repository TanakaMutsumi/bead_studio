// 平板 / 宽屏适配（2026-11-22 用户反馈：平板上界面与手机不一样）
//
// 三档窗口各测一遍：手机竖屏（原布局，逐像素不变）/ 平板竖屏 / 平板横屏。
// - 手机档断言的是**改动前布局的几何定义**（数值 = 原公式的结果），锁定不回归；
// - 平板档断言的是新布局的关键约束（限宽、分栏、图整幅可见）；
// - 任何布局溢出（RenderFlex overflowed）都会让对应用例直接失败，这是兜底。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/pattern_model.dart';
import 'package:bead_studio/core/responsive.dart';
import 'package:bead_studio/features/editor/editor_bars.dart';
import 'package:bead_studio/features/editor/editor_page.dart';
import 'package:bead_studio/features/editor/grid_painter.dart';
import 'package:bead_studio/features/home/home_page.dart';
import 'package:bead_studio/features/import/import_page.dart';
import 'package:bead_studio/features/inventory/inventory_page.dart';
import 'package:bead_studio/features/restore/restore_page.dart';
import 'package:bead_studio/features/restore/restore_types.dart';
import 'package:bead_studio/features/restore/steps/align_step.dart';
import 'package:bead_studio/features/restore/steps/frame_step.dart';
import 'package:bead_studio/features/restore/steps/legend_step.dart';
import 'package:bead_studio/features/restore/steps/pick_step.dart';
import 'package:bead_studio/features/stats/stats_page.dart';
import 'package:bead_studio/main.dart';

/// 窗口档位（逻辑像素；DPR 取 1，物理尺寸 = 逻辑尺寸）
const _phone = Size(393, 851); // 1080×2340@440 的竖屏手机
const _tabletPortrait = Size(800, 1280); // 1600×2560@320 的平板竖屏
const _tabletLandscape = Size(1280, 800); // 2560×1600@320 的平板横屏
const _phoneLandscape = Size(851, 393); // 手机横屏：宽够展开档、高不够

/// 放下右侧面板所需的最小窗口宽（面板 360 + 分隔线 1 + 主区 340）
const _twoPaneMin = kSidePanelWidth + 1 + kSidePanelRest;

const _stageKey = ValueKey("stub-stage");
const _zoomKey = ValueKey("stub-zoom");

Future<void> _window(WidgetTester tester, Size logical) async {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 测试壳：与 main.dart 同一套主题（色板 / M3 / 字体）。字体用 App 打包的
/// NotoSansSC——测试环境默认的 Ahem 每个字符都是等宽方块，比真实字体宽得多，
/// 按 360dp 手机内容宽排的控件行（步长 chips 等）会假溢出
Widget _app({required Widget home}) => MaterialApp(
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4FA8E8),
        useMaterial3: true,
        brightness: Brightness.light,
        fontFamily: "NotoSansSC",
      ),
      home: home,
    );

/// 载入 App 打包的中文字体（setUpAll 用）
Future<void> _loadFonts() async {
  final regular = FontLoader("NotoSansSC")
    ..addFont(rootBundle.load("assets/fonts/NotoSansSC-Regular.otf"));
  await regular.load();
  final bold = FontLoader("NotoSansSC")
    ..addFont(rootBundle.load("assets/fonts/NotoSansSC-Bold.otf"));
  await bold.load();
}

final _palette = BeadPalette(const [
  BeadColor("A1", "米白", 0xFFF5F0E0),
  BeadColor("C16", "蓝", 0xFF1A4FA0),
]);

final _model = PatternModel(
  width: 8,
  height: 8,
  grid: List.generate(64, (i) => (i ~/ 8 + i) % 2),
  paletteIds: const ["A1", "C16"],
);

/// 合成测试图：竖版（144×210），白底 + 色块 + 底部图例带
Uint8List _samplePng() {
  final im = img.Image(width: 144, height: 210);
  img.fill(im, color: img.ColorRgb8(255, 255, 255));
  img.fillRect(
    im,
    x1: 20,
    y1: 20,
    x2: 124,
    y2: 170,
    color: img.ColorRgb8(26, 79, 160),
  );
  img.fillRect(
    im,
    x1: 40,
    y1: 40,
    x2: 70,
    y2: 70,
    color: img.ColorRgb8(245, 240, 224),
  );
  for (var i = 0; i < 6; i++) {
    img.fillRect(
      im,
      x1: 10 + i * 22,
      y1: 185,
      x2: 24 + i * 22,
      y2: 199,
      color: img.ColorRgb8(200 - i * 20, 90, 60),
    );
  }
  return Uint8List.fromList(img.encodePng(im));
}

/// 载图并等自动预框结束（解码 + isolate 检测都走真实异步）
Future<void> _loadImage(WidgetTester tester) async {
  final png = _samplePng();
  await tester.runAsync(() async {
    tester.widget<PickStep>(find.byType(PickStep)).onLinkBytes(png);
    for (var i = 0; i < 800; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
      if (find.byType(LegendStep).evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        return;
      }
    }
  });
  await tester.pumpAndSettle();
}

/// 编辑器里用选区工具在画布上拖出一个选区，返回选区悬浮条的矩形
Future<Rect> _dragSelection(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.crop_free)); // 选区工具
  await tester.pumpAndSettle();
  final canvas = tester.getRect(
    find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is GridPainter,
    ),
  );
  final c = canvas.center;
  await tester.dragFrom(
    Offset(c.dx - canvas.width * 0.3, c.dy - canvas.height * 0.3),
    Offset(canvas.width * 0.6, canvas.height * 0.6),
  );
  await tester.pumpAndSettle();
  expect(find.byType(EditorSelectionBar), findsOneWidget);
  return tester.getRect(find.byType(EditorSelectionBar));
}

void main() {
  setUpAll(_loadFonts);

  // ============================ 断点 ============================

  group('断点', () {
    test('手机竖屏/横屏、平板竖屏都不展开；平板横屏展开', () {
      expect(isExpandedSize(_phone), isFalse);
      expect(isExpandedSize(_phoneLandscape), isFalse); // 宽够、高不够
      expect(isExpandedSize(_tabletPortrait), isFalse); // 右侧面板会挤没图区
      expect(isExpandedSize(_tabletLandscape), isTrue);
    });

    test('中等档：600 宽起（平板竖屏、手机横屏都算）', () {
      expect(const Size(599, 900).width >= kMediumWidth, isFalse);
      expect(const Size(600, 900).width >= kMediumWidth, isTrue);
      expect(_phoneLandscape.width >= kMediumWidth, isTrue);
      expect(_phone.width >= kMediumWidth, isFalse);
    });

    test('右侧面板：窗口窄到主区不足 340 就不放（面板宽度不收窄）', () {
      expect(fitsSidePanel(600), isFalse);
      expect(fitsSidePanel(_twoPaneMin - 1), isFalse);
      expect(fitsSidePanel(_twoPaneMin), isTrue);
      expect(fitsSidePanel(_tabletPortrait.width), isTrue);
      expect(fitsSidePanel(_phone.width), isFalse);
    });
  });

  // ======================= 图区显示尺寸 =======================

  group('图区显示尺寸 restoreDisplaySize', () {
    test('手机竖屏：可用宽 = 窗口宽 - 24（原公式不变）', () {
      const top = 24.0; // 状态栏
      final s = restoreDisplaySize(
        window: _phone,
        topPadding: top,
        bottomInset: 0,
        imageWidth: 1440,
        imageHeight: 2100,
      );
      expect(s.width, closeTo(393 - 24, 1e-9));
      expect(s.height, closeTo((393 - 24) * 2100 / 1440, 1e-9));
    });

    test('平板竖屏：仍是紧凑档公式', () {
      final s = restoreDisplaySize(
        window: _tabletPortrait,
        topPadding: 24,
        bottomInset: 0,
        imageWidth: 1440,
        imageHeight: 2100,
      );
      expect(s.width, closeTo(800 - 24, 1e-9));
      expect(s.height, closeTo(776 * 2100 / 1440, 1e-9));
    });

    test('平板横屏·竖版图：高度受限，整幅装入图区视口', () {
      final s = restoreDisplaySize(
        window: _tabletLandscape,
        topPadding: 0,
        bottomInset: 48,
        imageWidth: 1440,
        imageHeight: 2100,
      );
      // 堆叠布局 + 控制面板常见高度预算（kStackedPanelBudget）
      final stageH = 800 -
          48 -
          kToolbarHeight -
          kZoomStripHeight -
          kStackedPanelBudget -
          24;
      final stageW = 1280 - 24;
      expect(s.height, closeTo(stageH, 1e-9));
      expect(s.width, closeTo(stageH * 1440 / 2100, 1e-9));
      expect(s.width, lessThanOrEqualTo(stageW));
      // 对照：改动前按窗口宽铺满，同一张图高出现口两倍多（minScale=1 缩不回去）
      expect((1280 - 24) * 2100 / 1440, greaterThan(2.5 * stageH));
    });

    test('平板横屏·横版图：宽度受限', () {
      final s = restoreDisplaySize(
        window: _tabletLandscape,
        topPadding: 24,
        bottomInset: 48,
        imageWidth: 3000,
        imageHeight: 1000,
      );
      // 高度（含面板预算）比宽度更受限：整幅装入时宽高都由高度决定
      final stageH = 800 -
          24 -
          48 -
          kToolbarHeight -
          kZoomStripHeight -
          kStackedPanelBudget -
          24;
      final stageW = 1280 - 24;
      expect(s.height, closeTo(stageH, 1e-9));
      expect(s.width, closeTo(stageH * 3000 / 1000, 1e-9));
      expect(s.width, lessThanOrEqualTo(stageW));
    });

    test('带状态栏时图区视口相应变矮，图不出视口', () {
      final s = restoreDisplaySize(
        window: _tabletLandscape,
        topPadding: 24,
        bottomInset: 48,
        imageWidth: 1440,
        imageHeight: 2100,
      );
      expect(
        s.height,
        closeTo(
          800 -
              24 -
              48 -
              kToolbarHeight -
              kZoomStripHeight -
              kStackedPanelBudget -
              24,
          1e-9,
        ),
      );
    });
  });

  // ============================ 主页 ============================

  group('主页', () {
    testWidgets('手机竖屏：2×2 铺满，卡片矩形与原布局公式一致', (tester) async {
      await _window(tester, _phone);
      await tester.pumpWidget(_app(home: HomePage()));
      await tester.pumpAndSettle();
      final cards = find.byType(Card);
      expect(cards, findsNWidgets(4));
      // 原布局：body 四周 8，两排 Expanded(Row(Expanded×2))；Card 的矩形含自身
      // 的 8 margin（margin 在 Card 内部），所以 Card 矩形 = 单元格矩形
      final cellW = (393 - 16) / 2;
      final cellH = (851 - kToolbarHeight - 16) / 2;
      for (var i = 0; i < 4; i++) {
        final r = tester.getRect(cards.at(i));
        expect(r.left, closeTo(8 + (i % 2) * cellW, 0.01));
        expect(r.top, closeTo(kToolbarHeight + 8 + (i ~/ 2) * cellH, 0.01));
        expect(r.width, closeTo(cellW, 0.01));
        expect(r.height, closeTo(cellH, 0.01));
      }
    });

    testWidgets('平板横屏：一排 4 张，卡片高度封顶，整组限宽居中', (tester) async {
      await _window(tester, _tabletLandscape);
      await tester.pumpWidget(_app(home: HomePage()));
      await tester.pumpAndSettle();
      final cards = find.byType(Card);
      expect(cards, findsNWidgets(4));
      final rs = [for (var i = 0; i < 4; i++) tester.getRect(cards.at(i))];
      for (var i = 1; i < 4; i++) {
        expect(rs[i].top, rs[0].top); // 同一排
        expect(rs[i].left, greaterThan(rs[i - 1].right)); // 从左到右不重叠
      }
      final groupW = rs[3].right - rs[0].left;
      expect(groupW, lessThanOrEqualTo(1120));
      expect(rs[0].left, closeTo((1280 - groupW) / 2, 0.5)); // 水平居中
      expect(rs[0].height, inInclusiveRange(130, 220)); // 不再是半屏高的巨卡
      // 整组在可用高度内垂直居中
      expect(
        rs[0].top - kToolbarHeight,
        closeTo(800 - rs[0].bottom, 0.5),
      );
    });

    testWidgets('平板竖屏：两排各 2 张，卡片不被拉到整屏高', (tester) async {
      await _window(tester, _tabletPortrait);
      await tester.pumpWidget(_app(home: HomePage()));
      await tester.pumpAndSettle();
      final cards = find.byType(Card);
      final rs = [for (var i = 0; i < 4; i++) tester.getRect(cards.at(i))];
      expect(rs[1].top, rs[0].top);
      expect(rs[2].top, greaterThan(rs[0].bottom));
      expect(rs[0].width, lessThan(400));
      expect(rs[0].height, lessThan(300));
      expect(rs[0].top, greaterThan(kToolbarHeight + 100)); // 整组垂直居中
    });

    testWidgets('手机横屏：一排 4 张（不被高度压成扁条），无溢出', (tester) async {
      await _window(tester, _phoneLandscape);
      await tester.pumpWidget(_app(home: HomePage()));
      await tester.pumpAndSettle();
      final cards = find.byType(Card);
      final rs = [for (var i = 0; i < 4; i++) tester.getRect(cards.at(i))];
      for (var i = 1; i < 4; i++) {
        expect(rs[i].top, rs[0].top);
      }
      expect(rs[0].bottom, lessThanOrEqualTo(393));
    });
  });

  // ========================== 图片转换 ==========================

  group('图片转换页', () {
    testWidgets('手机竖屏：单列，预览宽 = 屏宽 - 32，选图按钮在预览下方', (tester) async {
      await _window(tester, _phone);
      await tester.pumpWidget(_app(home: ImportPage()));
      await tester.pumpAndSettle();
      final preview = tester.getRect(find.byType(AspectRatio));
      expect(preview.left, 16);
      expect(preview.width, closeTo(393 - 32, 0.01));
      expect(preview.height, closeTo(preview.width, 0.01));
      final gallery = tester.getRect(find.text("相册"));
      expect(gallery.top, greaterThan(preview.bottom));
      expect(find.byType(SingleChildScrollView), findsNothing); // 仍是整页 ListView
    });

    testWidgets('平板横屏：预览居左（正方形、按高度受限），参数面板靠右', (tester) async {
      await _window(tester, _tabletLandscape);
      await tester.pumpWidget(_app(home: ImportPage()));
      await tester.pumpAndSettle();
      final preview = tester.getRect(find.byType(AspectRatio));
      // 左栏内宽 1280-1-360-32 = 887、内高 800-56-32 = 712 → 正方形取 712
      expect(preview.width, closeTo(712, 0.01));
      expect(preview.height, closeTo(preview.width, 0.01));
      expect(preview.right, lessThanOrEqualTo(1280 - kSidePanelWidth - 1));
      final settings = tester.getRect(find.text("格子数"));
      expect(settings.left, greaterThanOrEqualTo(1280 - kSidePanelWidth));
      final gallery = tester.getRect(find.text("相册"));
      expect(gallery.left, greaterThanOrEqualTo(1280 - kSidePanelWidth));
      expect(gallery.top, lessThan(settings.top));
      expect(find.text("开始转换"), findsOneWidget);
    });

    testWidgets('平板竖屏：右栏 360，预览仍有 400 以上', (tester) async {
      await _window(tester, _tabletPortrait);
      await tester.pumpWidget(_app(home: ImportPage()));
      await tester.pumpAndSettle();
      final preview = tester.getRect(find.byType(AspectRatio));
      expect(preview.width, closeTo(800 - 1 - 360 - 32, 0.01));
      expect(preview.left, 16); // 预览在左栏内
    });

    testWidgets('刚够放面板的宽度（${_twoPaneMin.round()}）：面板仍是 360，主区 340', (
      tester,
    ) async {
      await _window(tester, Size(_twoPaneMin, 960));
      await tester.pumpWidget(_app(home: ImportPage()));
      await tester.pumpAndSettle();
      final preview = tester.getRect(find.byType(AspectRatio));
      expect(
          preview.width, closeTo(_twoPaneMin - 1 - kSidePanelWidth - 32, 0.01));
      expect(find.text("格子数").evaluate().isNotEmpty, isTrue);
    });

    testWidgets('窄窗口（600 宽，放不下面板）：保持单列，不横向溢出', (tester) async {
      await _window(tester, const Size(600, 960));
      await tester.pumpWidget(_app(home: ImportPage()));
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsNothing); // 整页 ListView
      final preview = tester.getRect(find.byType(AspectRatio));
      expect(preview.left, 16);
      expect(preview.width, closeTo(600 - 32, 0.01));
      final gallery = tester.getRect(find.text("相册"));
      expect(gallery.top, greaterThan(preview.bottom));
    });
  });

  // ========================== 对话框 ==========================

  group('对话框限宽', () {
    /// 对话框的 Material（AlertDialog 最外层是带 insetPadding 的
    /// AnimatedPadding，矩形 = 整个窗口，不能拿它量宽度）
    Finder dialogBox() => find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Material),
        )
        .first;

    /// 起完整 App（main.dart 的真实主题），等启动页遮罩淡出。
    /// 每次先卸掉旧树：同类型根 widget 会被复用，导航栈会留在上一轮的页面
    Future<void> pumpApp(WidgetTester tester, Size window) async {
      await _window(tester, window);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const BeadStudioApp());
      // 启动页遮罩静止 600ms 后才淡出——pumpAndSettle 在没有动画帧时会提前
      // 返回，先把表拨过 600ms 再 settle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
    }

    testWidgets('短内容对话框：宽度由内容决定（≥280），三档一致', (tester) async {
      for (final w in [_phone, _tabletPortrait, _tabletLandscape]) {
        await pumpApp(tester, w);
        await tester.tap(find.text("图片转换"));
        await tester.pumpAndSettle();
        await tester.tap(find.text("自定义"));
        await tester.pumpAndSettle();
        expect(find.text("自定义格子数"), findsOneWidget);
        expect(
          tester.getRect(dialogBox()).width,
          closeTo(280, 0.5),
          reason: '$w',
        );
      }
    });

    testWidgets('长文案对话框：手机 = 屏宽 - 80（不变）；平板封顶 560 居中', (
      tester,
    ) async {
      // AlertDialog 内有 IntrinsicWidth：短内容按内容宽，长文案会一直撑到
      // 可用宽度的上限——改动前上限 = 窗口宽 - 80，平板横屏约 1200dp
      final long = List.filled(12, "豆板有未保存的修改，离开前要先保存吗？").join();
      Future<Rect> open(Size window) async {
        await pumpApp(tester, window);
        // 从 App 内部弹，拿到 main.dart 的真实主题
        final ctx = tester.element(find.text("豆田"));
        showDialog<void>(
          context: ctx,
          builder: (_) => AlertDialog(
            title: const Text("提示"),
            content: Text(long),
            actions: [
              TextButton(onPressed: () {}, child: const Text("确定")),
            ],
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(dialogBox());
      }

      final phone = await open(_phone);
      expect(phone.width, closeTo(393 - 80, 0.5));

      final portrait = await open(_tabletPortrait);
      expect(portrait.width, closeTo(560, 0.5));

      final landscape = await open(_tabletLandscape);
      expect(landscape.width, closeTo(560, 0.5));
      expect(landscape.center.dx, closeTo(640, 0.5));
    });
  });

  // ======================= 用料统计 / 库存 =======================

  group('列表页限宽', () {
    testWidgets('用料统计·手机竖屏：摘要卡仍铺满屏宽', (tester) async {
      await _window(tester, _phone);
      await tester.pumpWidget(
        _app(home: StatsPage(model: _model, palette: _palette)),
      );
      await tester.pumpAndSettle();
      // Card 矩形含自己的 12 margin → 等于整屏宽
      expect(tester.getRect(find.byType(Card)).width, closeTo(393, 0.01));
    });

    testWidgets('用料统计·平板横屏：摘要卡与列表限宽 640 居中', (tester) async {
      await _window(tester, _tabletLandscape);
      await tester.pumpWidget(
        _app(home: StatsPage(model: _model, palette: _palette)),
      );
      await tester.pumpAndSettle();
      final card = tester.getRect(find.byType(Card));
      expect(card.width, lessThanOrEqualTo(640));
      expect(card.left, closeTo((1280 - card.width) / 2, 0.5));
      final row = tester.getRect(find.byType(ListTile).first);
      expect(row.left, greaterThanOrEqualTo(319.5)); // 列表同样在 640 内
      expect(row.right, lessThanOrEqualTo(960.5));
    });

    testWidgets('库存·手机竖屏铺满 / 平板横屏限宽 640 居中', (tester) async {
      final dir = Directory.systemTemp.createTempSync("bead_tablet_test");
      const channel = MethodChannel("plugins.flutter.io/path_provider");
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => dir.path);
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        dir.deleteSync(recursive: true);
      });
      await _window(tester, _phone);
      await tester.pumpWidget(
        _app(home: InventoryPage(palette: _palette)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(TextField)).width,
        closeTo(393 - 32, 0.01),
      );

      await _window(tester, _tabletLandscape);
      await tester.pumpAndSettle();
      final field = tester.getRect(find.byType(TextField));
      expect(field.width, closeTo(640 - 32, 0.01));
      expect(field.left, closeTo((1280 - field.width) / 2, 0.5));
    });
  });

  // ========================== 编辑器 ==========================

  group('编辑器选区条', () {
    testWidgets('手机竖屏：左右铺开（原样）', (tester) async {
      await _window(tester, _phone);
      await tester.pumpWidget(
        _app(home: EditorPage(model: _model, palette: _palette)),
      );
      await tester.pumpAndSettle();
      final bar = await _dragSelection(tester);
      expect(bar.left, 10);
      expect(bar.width, closeTo(393 - 20, 0.01));
    });

    testWidgets('平板横屏：宽度随内容，不再横贯整屏', (tester) async {
      await _window(tester, _tabletLandscape);
      await tester.pumpWidget(
        _app(home: EditorPage(model: _model, palette: _palette)),
      );
      await tester.pumpAndSettle();
      final bar = await _dragSelection(tester);
      expect(bar.left, 10);
      expect(bar.right, lessThan(1280 - 400));
    });
  });

  // ======================= 还原步骤骨架 =======================

  group('还原步骤骨架（StageFrame）', () {
    Widget stubStage({
      required Rect? sel,
      required void Function(Rect) onSel,
      CustomPainter? overlay,
      List<Offset>? cornerPts,
      void Function(int, Offset)? onCornerDrag,
      Offset? miniAnchor,
      void Function(Offset)? onMiniAnchor,
      bool panFallback = false,
    }) =>
        const SizedBox.expand(
          key: _stageKey,
          child: ColoredBox(color: Color(0xFF00FF00)),
        );

    /// 缩放条替身：与页面 `_zoomStrip` 同几何（按钮 34 + 上下 padding 各 2 = 38）
    /// 缩放条替身：与页面 `_zoomStrip` 同几何——上下 padding 各 2，
    /// 内含 ZoomControls（3 钮 × 34 + 2 × 6 间距 = 114 宽、34 高）靠右
    Widget stubZoom(
      TransformationController ctrl,
      Size Function() contentSize, {
      double maxScale = 10,
      Size Function()? viewport,
    }) =>
        const Padding(
          key: _zoomKey,
          padding: EdgeInsets.fromLTRB(16, 2, 16, 2),
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: 114, height: 34),
          ),
        );

    /// 面板：三个步骤的面板都是 Padding(16, 0, 16, 12, Column)，按 padding 值定位
    /// （不能取「最近的 Padding 祖先」——按钮内部也有 Padding）
    final panel = find.byWidgetPredicate(
      (w) =>
          w is Padding && w.padding == const EdgeInsets.fromLTRB(16, 0, 16, 12),
    );

    Widget frameStep() => FrameStep(
          imageStage: stubStage,
          zoomStrip: stubZoom,
          viewerCtrl: TransformationController(),
          displaySize: () => const Size(300, 420), // 存根图高：真实设备载图后必有图高
          stageViewSize: () => Size.zero,
          sel: null,
          overlay: null,
          hint: "提示文案",
          showAutoSelect: true,
          recognizing: false,
          blankEnable: false,
          onSel: (_) {},
          onAutoSelect: () {},
          onBlankChanged: (_) {},
          onRecognize: () {},
        );

    Widget alignStep() => AlignStep(
          imageStage: stubStage,
          zoomStrip: stubZoom,
          viewerCtrl: TransformationController(),
          displaySize: () => const Size(300, 420), // 存根图高：真实设备载图后必有图高
          stageViewSize: () => Size.zero,
          overlay: null,
          cornerPts: null,
          onCornerDrag: null,
          miniAnchor: null,
          onMiniAnchor: null,
          useCorner: false,
          hint: "提示文案",
          pitchX: 0,
          recognizing: false,
          blankEnable: false,
          colsCtrl: TextEditingController(),
          rowsCtrl: TextEditingController(),
          onDimChanged: () {},
          onSwitchMode: (_) {},
          onResetCorners: () {},
          onBlankChanged: (_) {},
          step: 0.01,
          onStepChange: (_) {},
          onAdjustPitch: (_) {},
          onNudge: (_, __) {},
          onRecognize: () {},
          onGoFrame: () {},
          detecting: false,
          onRedetect: () {},
        );

    Widget legendStep({required bool scanned, required bool expanded}) {
      final legend = [if (scanned) LegendEntry(0)];
      for (final e in legend) {
        e.countCtrl.text = "5";
      }
      return LegendStep(
        imageStage: stubStage,
        zoomStrip: stubZoom,
        viewerCtrl: TransformationController(),
        displaySize: () => const Size(300, 420), // 存根图高：真实设备载图后必有图高
        stageViewSize: () => Size.zero,
        legendSel: null,
        overlay: null,
        onSel: (_) {},
        onClearSel: () {},
        legendBusy: false,
        legendByOcr: true,
        panelExpanded: expanded,
        colsCtrl: TextEditingController(),
        rowsCtrl: TextEditingController(),
        legend: legend,
        legendSort: LegendSort.code,
        onSortChange: (_) {},
        palette: _palette,
        onAutoSelect: () {},
        onScan: () {},
        onGoAlign: () {},
        onTogglePanel: () {},
        onAddColor: () {},
        onChangeColor: (_) {},
        onRemoveEntry: (_) {},
      );
    }

    final cases = <(String, Widget Function())>[
      ("③框选主体", frameStep),
      ("②九宫格对齐", alignStep),
      ("①框图例·未识别", () => legendStep(scanned: false, expanded: false)),
      (
        "①框图例·清单展开",
        () => legendStep(scanned: true, expanded: true),
      ),
    ];

    testWidgets('手机竖屏：图区在上、缩放条贴图区下缘、面板在底部铺满——与原布局几何一致', (
      tester,
    ) async {
      await _window(tester, _phone);
      for (final (name, build) in cases) {
        await tester.pumpWidget(_app(home: Scaffold(body: build())));
        await tester.pumpAndSettle();
        final stage = tester.getRect(find.byKey(_stageKey));
        final zoom = tester.getRect(find.byKey(_zoomKey));
        final p = tester.getRect(panel);
        // 原 Column[Expanded(Padding(12, 图区)), 缩放条(38), Padding(16,0,16,12, 面板)]
        expect(stage.left, 12, reason: name);
        expect(stage.top, 12, reason: name);
        expect(stage.right, 393 - 12, reason: name);
        expect(stage.bottom, lessThan(zoom.top), reason: name);
        expect(zoom.top, stage.bottom + 12, reason: "$name：图区下 padding 12");
        expect(zoom.height, kZoomStripHeight, reason: name);
        expect(zoom.left, 0, reason: name);
        expect(p.left, 0, reason: name); // Padding 外框贴屏缘，内容左右各留 16
        expect(p.right, 393, reason: name);
        expect(p.top, zoom.bottom, reason: name);
        expect(p.bottom, 851, reason: name); // 内容底留 12
      }
    });

    testWidgets('平板竖屏（紧凑档）：仍是上下堆叠', (tester) async {
      await _window(tester, _tabletPortrait);
      for (final (name, build) in cases) {
        await tester.pumpWidget(_app(home: Scaffold(body: build())));
        await tester.pumpAndSettle();
        final stage = tester.getRect(find.byKey(_stageKey));
        final p = tester.getRect(panel);
        expect(stage.left, 12, reason: name);
        expect(stage.right, 800 - 12, reason: name);
        expect(p.left, 0, reason: name);
        expect(p.right, 800, reason: name);
        expect(p.top, greaterThan(stage.bottom), reason: name);
        expect(p.bottom, 1280, reason: name);
      }
    });

    testWidgets('平板横屏（完全手机式）：与竖屏同一堆叠结构，控件行全宽', (tester) async {
      await _window(tester, _tabletLandscape);
      for (final (name, build) in cases) {
        await tester.pumpWidget(_app(home: Scaffold(body: build())));
        await tester.pumpAndSettle();
        final stage = tester.getRect(find.byKey(_stageKey));
        final zoom = tester.getRect(find.byKey(_zoomKey));
        final p = tester.getRect(panel);
        expect(stage.left, 12, reason: name);
        expect(stage.top, 12, reason: name);
        expect(stage.right, 1280 - 12, reason: name); // 图区吃满全宽
        expect(zoom.top, stage.bottom + 12, reason: name);
        expect(zoom.height, kZoomStripHeight, reason: name);
        expect(zoom.right, 1280, reason: name); // 缩放条全宽、按钮贴右
        expect(p.left, 0, reason: name);
        expect(p.right, 1280, reason: name); // 控件行全宽（用户定稿）
        expect(p.top, zoom.bottom, reason: name);
        expect(p.bottom, 800, reason: name);
      }
    });

    testWidgets('展开档清单：列表吃掉面板剩余高度，底部按钮完整露出', (tester) async {
      await _window(tester, _tabletLandscape);
      await tester.pumpWidget(
        _app(
          home: Scaffold(
            body: legendStep(scanned: true, expanded: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = tester.getRect(find.byType(ListView));
      final next = tester.getRect(find.text("下一步：九宫格对齐（1色）"));
      expect(list.left, greaterThanOrEqualTo(0));
      expect(list.top, greaterThan(40)); // 在摘要行 / 操作行之下
      expect(list.bottom, lessThanOrEqualTo(next.top)); // 不压住底部按钮
      expect(next.bottom, lessThanOrEqualTo(800 - 12 + 0.5)); // 底部按钮完整露出
      // 紧凑公式：max(视口800 - 图高420 - 172, 42%=336) -> 336，上限 590 不绑定
      expect(list.height, closeTo(336, 1.0));
    });

    testWidgets('窗口很矮时（高 500，展开档下限）面板也不溢出', (tester) async {
      await _window(tester, const Size(1280, 500));
      for (final (name, build) in cases) {
        await tester.pumpWidget(_app(home: Scaffold(body: build())));
        await tester.pumpAndSettle();
        final p = tester.getRect(panel);
        expect(p.bottom, 500, reason: name);
      }
    });
  });

  // ======================== 还原页整页 ========================

  group('还原页整页载图', () {
    testWidgets('手机竖屏：图片显示宽 = 屏宽 - 24（不变）', (tester) async {
      await _window(tester, _phone);
      await tester.pumpWidget(_app(home: RestorePage()));
      await tester.pumpAndSettle();
      await _loadImage(tester);
      expect(find.byType(LegendStep), findsOneWidget);
      final image = tester.getRect(find.byType(Image));
      expect(image.width, closeTo(393 - 24, 0.5));
      expect(image.height, closeTo((393 - 24) * 210 / 144, 0.5));
      expect(image.left, 12);
    });

    testWidgets('平板横屏：整幅图在图区视口内可见，面板靠右；窗口跨档时显示尺寸跟随', (
      tester,
    ) async {
      // 先在平板竖屏（紧凑档）载图
      await _window(tester, _tabletPortrait);
      await tester.pumpWidget(_app(home: RestorePage()));
      await tester.pumpAndSettle();
      await _loadImage(tester);
      var image = tester.getRect(find.byType(Image));
      expect(image.width, closeTo(800 - 24, 0.5));

      // 转到横屏（完全手机式：堆叠 + 整幅装入 + 水平居中）
      tester.view.physicalSize = _tabletLandscape;
      await tester.pumpAndSettle();
      image = tester.getRect(find.byType(Image));
      // 测试窗口无系统栏：topPadding/bottomInset = 0
      final stageH =
          800 - kToolbarHeight - kZoomStripHeight - kStackedPanelBudget - 24;
      expect(image.top, kToolbarHeight + 12);
      expect(image.bottom, lessThanOrEqualTo(800 - kZoomStripHeight));
      expect(image.height, closeTo(stageH, 0.5));
      // 水平居中：图区视口 x 12..1268dp，图在其中居中
      expect(
        image.left,
        closeTo(12 + (1256 - image.width) / 2, 1.0),
      );
      expect(image.width, closeTo(stageH * 144 / 210, 0.5));
      // 面板在图区下方（不再分栏）
      final auto = tester.getRect(find.text("自动框选图例区"));
      expect(auto.top, greaterThan(image.bottom));
      expect(auto.left, greaterThanOrEqualTo(0));
      expect(auto.right, lessThanOrEqualTo(1280));
    });
  });
}
