// 图例色条检测（detectLegendBars）+ 颜色/OCR 融合（fuseLegendBars）的
// 确定性单元测试：合成图 + 手工构造的 OcrElem，不依赖真机 ML Kit。
//
// 覆盖三类真实布局：
// - test_pic5 竖排：色号印色条内、颗数在色条下方（OCR 可能全瞎/半瞎）
// - wx1/new1 横排：色块 + 色号 + 颗数同行（经典布局，回归保护）
// - 白底色块：无饱和度检测不出色条，靠孤立色号保住条目
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:bead_studio/core/legend_ocr.dart';
import 'package:bead_studio/core/palette.dart';

// 测试色卡：前 4 色对应合成图色条，H9 是干扰色（不应对应任何条）
const _palette = BeadPalette([
  BeadColor("A1", "红", 0xE31A1C),
  BeadColor("B1", "蓝", 0x1F78B4),
  BeadColor("C1", "绿", 0x33A02C),
  BeadColor("D1", "橙", 0xFF7F00),
  BeadColor("A2", "深红", 0xC51B1B),
  BeadColor("W1", "白", 0xF5F5F5),
  BeadColor("H9", "紫", 0x6A3D9A),
]);

int _barRgb(int i) => switch (i) {
      0 => 0xE31A1C,
      1 => 0x1F78B4,
      2 => 0x33A02C,
      _ => 0xFF7F00,
    };

/// 竖排图例（test_pic5 布局）：4 条 200×80 色条上下排，间隔 40 行白底，
/// 条内印黑色色号小字（低饱和，检测应排除）
img.Image _verticalLegend() {
  const barW = 200, barH = 80, gap = 40, n = 4;
  final im = img.Image(width: barW, height: n * barH + (n - 1) * gap);
  img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
  for (var i = 0; i < n; i++) {
    final top = i * (barH + gap);
    final rgb = _barRgb(i);
    for (var y = top; y < top + barH; y++) {
      for (var x = 0; x < barW; x++) {
        im.setPixelRgba(
          x,
          y,
          (rgb >> 16) & 0xFF,
          (rgb >> 8) & 0xFF,
          rgb & 0xFF,
          255,
        );
      }
    }
    // 条内「色号」黑字块
    for (var y = top + 35; y < top + 45; y++) {
      for (var x = 70; x < 100; x++) {
        im.setPixelRgba(x, y, 20, 20, 20, 255);
      }
    }
  }
  return im;
}

/// 横排图例（wx1/new1 布局）：4 块 80×80 色块左右排，间隔 20 列
img.Image _horizontalLegend() {
  const blk = 80, gap = 20, n = 4;
  final im = img.Image(width: n * blk + (n - 1) * gap, height: 120);
  img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
  for (var i = 0; i < n; i++) {
    final left = i * (blk + gap);
    final rgb = _barRgb(i);
    for (var y = 20; y < 100; y++) {
      for (var x = left; x < left + blk; x++) {
        im.setPixelRgba(
          x,
          y,
          (rgb >> 16) & 0xFF,
          (rgb >> 8) & 0xFF,
          rgb & 0xFF,
          255,
        );
      }
    }
  }
  return im;
}

/// 第 [i] 条色条正下方的颗数元素（test_pic5 的「颗数在条下」几何）
OcrElem _countBelowBar(int i, int n) => OcrElem(
      100 + i,
      Rect.fromLTRB(85.0, i * 120.0 + 86, 115.0, i * 120.0 + 110),
      null,
      n,
    )..dbgText = "($n)";

/// 第 [i] 条色条条内的色号元素（test_pic5 的「色号印条内」几何）
OcrElem _codeInsideBar(int i, int codeIdx) => OcrElem(
      200 + i,
      Rect.fromLTRB(70.0, i * 120.0 + 35, 100.0, i * 120.0 + 45),
      codeIdx,
      null,
    )..dbgText = "条内色号$i";

void main() {
  test('detectLegendBars：竖排色条按行带切分，条内黑字被排除', () {
    final bars = detectLegendBars(_verticalLegend());
    expect(bars.length, 4);
    for (var i = 0; i < 4; i++) {
      final top = i * 120.0;
      expect(bars[i].rect.top, closeTo(top, 1.0));
      expect(bars[i].rect.bottom, closeTo(top + 80, 1.0));
      final rgb = _barRgb(i);
      expect(bars[i].r, (rgb >> 16) & 0xFF);
      expect(bars[i].g, (rgb >> 8) & 0xFF);
      expect(bars[i].b, rgb & 0xFF);
    }
  });

  test('detectLegendBars：横排色块行带内按列切分', () {
    final bars = detectLegendBars(_horizontalLegend());
    expect(bars.length, 4);
    for (var i = 0; i < 4; i++) {
      expect(bars[i].rect.left, closeTo(i * 100.0, 1.0));
      expect(bars[i].rect.right, closeTo(i * 100.0 + 80, 1.0));
    }
  });

  test('detectLegendBars：全白图无色条', () {
    final im = img.Image(width: 100, height: 100);
    img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
    expect(detectLegendBars(im), isEmpty);
  });

  test('fuseLegendBars：OCR 全瞎时纯颜色产清单（test_pic5 兜底）', () {
    final bars = detectLegendBars(_verticalLegend());
    final fused = fuseLegendBars(_palette, [], const [], bars);
    expect(fused, [
      (0, 0), // A1
      (1, 0), // B1
      (2, 0), // C1
      (3, 0), // D1
    ]);
  });

  test('fuseLegendBars：颗数在色条下方按条几何归属（无色号 OCR）', () {
    final bars = detectLegendBars(_verticalLegend());
    final elems = [
      _countBelowBar(0, 82),
      _countBelowBar(1, 126),
      _countBelowBar(2, 35),
      _countBelowBar(3, 7),
    ];
    final fused = fuseLegendBars(_palette, elems, const [], bars);
    expect(fused, [
      (0, 82),
      (1, 126),
      (2, 35),
      (3, 7),
    ]);
  });

  test('fuseLegendBars：条内色号 OCR 优先于颜色候选', () {
    final bars = detectLegendBars(_verticalLegend());
    // 条 0 涂的是 A1 的颜色，但 OCR 在条内读出 A2（索引 4）——应信 OCR
    final elems = [_codeInsideBar(0, 4), _countBelowBar(0, 82)];
    final fused = fuseLegendBars(_palette, elems, const [], bars);
    expect(fused.first, (4, 82));
    expect(fused.length, 4); // 其余 3 条仍由颜色候选兜底
  });

  test('fuseLegendBars：无色条时原样返回配对结果（零回归路径）', () {
    final paired = <(int, int)>[(0, 10), (1, 20)];
    final fused = fuseLegendBars(_palette, [], paired, const []);
    expect(fused, same(paired));
  });

  test('fuseLegendBars：经典横排布局不回归（含白底条目）', () {
    // 3 个有色块 + 1 个白底块（检测不出色条）；色号在块右侧、颗数再右侧
    // 同行，颗数都带括号。经典路径 pairLegendOcr 全配上，融合后应一致，
    // 且白底条目靠孤立色号保住
    const blk = 80, gap = 20;
    final im = img.Image(width: 4 * blk + 3 * gap, height: 120);
    img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
    for (var i = 0; i < 3; i++) {
      final left = i * (blk + gap);
      final rgb = _barRgb(i);
      for (var y = 20; y < 100; y++) {
        for (var x = left; x < left + blk; x++) {
          im.setPixelRgba(x, y, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF,
              rgb & 0xFF, 255);
        }
      }
    }
    final codes = <OcrElem>[];
    final nums = <OcrElem>[];
    for (var i = 0; i < 4; i++) {
      final left = i * (blk + gap);
      final code = OcrElem(
        i,
        Rect.fromLTRB(left + 84.0, 48, left + 114.0, 72),
        i == 3 ? 5 : i, // 白底块条目色号 W1（索引 5）
        null,
      )..dbgText = "code$i";
      final count = OcrElem(
        10 + i,
        Rect.fromLTRB(left + 122.0, 48, left + 152.0, 72),
        null,
        64 + i,
      )..dbgText = "(${64 + i})";
      codes.add(code);
      nums.add(count);
    }
    final elems = [...codes, ...nums];
    final paired = pairLegendOcr(elems);
    final bars = detectLegendBars(im);
    expect(bars.length, 3); // 白底块无饱和度，检测不出
    final fused = fuseLegendBars(_palette, elems, paired, bars);
    // 4 条全在（白底条目保住），值与经典配对一致，顺序阅读序
    expect(fused, [
      (0, 64),
      (1, 65),
      (2, 66),
      (5, 67),
    ]);
  });

  test('fuseLegendBars：颜色候选与近旁同色号孤立 OCR 锚点去重', () {
    final bars = detectLegendBars(_verticalLegend());
    // 条 0（A1 色）右侧归属半径（avgH*2.5=60）之外放一个 A1 孤立色号：
    // 没归属上色条，两端各出一个 A1 锚点——去重应保 OCR 版只留一条
    final lone = OcrElem(
      0,
      const Rect.fromLTRB(380.0, 30, 410.0, 54),
      0,
      null,
    )..dbgText = "A1";
    final fused = fuseLegendBars(_palette, [lone], const [], bars);
    // 条 0 的 A1 颜色候选被去掉（与孤立 A1 位置重叠），清单仍是 4 条
    expect(fused.length, 4);
    expect(fused[0], (0, 0));
  });

  // ---- 双行图例（wx1 型）回归 ----

  /// 双行图例合成：行 1 两个 100x120 色块（只有行 1 有可检测色条，行 2
  /// 是黑/白块无饱和度），行距足够近——旧版条下窗口 max(条高,avgH)*2.2
  /// 能跨到行 2 颗数（wx1：C3 抢 M12 的 121、B22 抢 M2 的 1）
  img.Image _twoRowLegend() {
    final im = img.Image(width: 300, height: 380);
    img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
    for (var i = 0; i < 2; i++) {
      final left = 20 + i * 140;
      final rgb = _barRgb(i);
      for (var y = 20; y < 140; y++) {
        for (var x = left; x < left + 100; x++) {
          im.setPixelRgba(
              x, y, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF, 255);
        }
      }
    }
    return im;
  }

  test('fuseLegendBars：双行图例行 1 色条不抢行 2 颗数（wx1 回归）', () {
    final bars = detectLegendBars(_twoRowLegend());
    expect(bars.length, 2);
    // 行 1：条内色号 + 条下颗数（条 1 的颗数缺失模拟 OCR 漏读）
    // 行 2：色号 y=240 / 颗数 y=330（无色条，靠孤立色号 + 轮 2 配对保住）
    final elems = <OcrElem>[
      OcrElem(0, const Rect.fromLTRB(40, 60, 80, 84), 0, null),
      OcrElem(1, const Rect.fromLTRB(40, 170, 60, 194), null, 5),
      OcrElem(2, const Rect.fromLTRB(180, 60, 220, 84), 1, null),
      OcrElem(3, const Rect.fromLTRB(40, 240, 80, 264), 4, null),
      OcrElem(4, const Rect.fromLTRB(50, 330, 90, 354), null, 121),
      OcrElem(5, const Rect.fromLTRB(180, 240, 220, 264), 5, null),
      OcrElem(6, const Rect.fromLTRB(190, 330, 210, 354), null, 9),
    ];
    for (final (i, e) in elems.indexed) {
      e.dbgText = "e$i";
    }
    final paired = pairLegendOcr(elems);
    final fused = fuseLegendBars(_palette, elems, paired, bars);
    // 行 2 颗数 121 配行 2 色号（轮 2 扩窗 dx 紧凑），不再被行 1 条抢走；
    // 条 1 颗数缺失就是 0（用户手填），不会错拿 121
    expect(fused, [
      (0, 5),
      (1, 0),
      (4, 121),
      (5, 9),
    ]);
  });

  test('pairLegendOcr：颗数在色号正下方 3.2 字高处仍配上（wx1 行距）', () {
    // wx1 实测：颗数顶 - 色号中心 ≈ 2.65*avgH，旧 2.5 窗口整行漏配
    final code = OcrElem(0, const Rect.fromLTRB(100, 40, 140, 60), 0, null)
      ..dbgText = "A1";
    final count = OcrElem(1, const Rect.fromLTRB(104, 104, 124, 128), null, 64)
      ..dbgText = "64";
    expect(pairLegendOcr([code, count]), [(0, 64)]);
  });

  test('pairLegendOcr：下方颗数横向紧凑约束（1.5 字高）不跨邻条目', () {
    // 两个色号同排，颗数在第二个色号正下方——第一个色号不得跨条目抢配
    final c1 = OcrElem(0, const Rect.fromLTRB(100, 40, 140, 60), 0, null)
      ..dbgText = "A1";
    final c2 = OcrElem(1, const Rect.fromLTRB(300, 40, 340, 60), 1, null)
      ..dbgText = "B1";
    final n2 = OcrElem(2, const Rect.fromLTRB(304, 104, 324, 128), null, 32)
      ..dbgText = "32";
    final paired = pairLegendOcr([c1, c2, n2]);
    expect(paired, contains((1, 32)));
    expect(paired, isNot(contains((0, 32))));
  });

  test('mergeSegmentElems：切边碎片让位邻段完整读数、重叠区去重', () {
    // 段 [0,3800) 与 [3400,7200)（重叠 400）：
    // - "C12" 完整读数在段 1 内部，段 0 里它的切断碎片 "C1" 贴右切边
    // - 同一 "82" 颗数两段都读到（重叠区纯重复）
    // - 段 1 左切边孤立碎片（邻段没读到）：保留
    final whole = OcrElem(0, const Rect.fromLTRB(3700, 50, 3850, 90), 0, null)
      ..dbgText = "C12";
    final frag = OcrElem(1, const Rect.fromLTRB(3700, 50, 3800, 90), 2, null)
      ..dbgText = "C1";
    final dupA = OcrElem(2, const Rect.fromLTRB(1000, 50, 1040, 90), null, 82)
      ..dbgText = "82";
    final dupB = OcrElem(3, const Rect.fromLTRB(1002, 50, 1042, 90), null, 82)
      ..dbgText = "82";
    final loneFrag = OcrElem(4, const Rect.fromLTRB(3402, 200, 3450, 240), 1,
            null)
        ..dbgText = "B1?";
    final merged = mergeSegmentElems(
      [(frag, 0), (dupA, 0), (whole, 1), (dupB, 1), (loneFrag, 1)],
      [0.0, 3400.0],
      [3800.0, 7200.0],
    );
    // 碎片 "C1" 消失（完整 "C12" 在段 1 深处）、重复 82 只留一份、
    // 孤立碎片保留（宁要可能碎片不要丢条目）
    expect(merged.length, 3);
    expect(merged.any((e) => e.dbgText == "C12"), isTrue);
    expect(merged.any((e) => e.dbgText == "C1"), isFalse);
    expect(merged.where((e) => e.dbgText == "82").length, 1);
    expect(merged.any((e) => identical(e, loneFrag)), isTrue);
  });

  test('mergeSegmentElems：尾巴碎片嵌套在全读框内（wx1 "7)"→R7 幻影回归）', () {
    // wx1 实测几何（段0 [0,3800) 段1 [3446,7246)）：D4 颗数 "(27)" 跨重叠
    // 区，段 0 读全，段 1 从 3446 裁掉 "(2" 只读出尾巴 "7)"。碎片墨迹离
    // 切边 32px（>2px 嫌疑窗口）不标嫌疑；中心距 96.5 恰超 0.9*avgH(94.5)
    // 旧去重也漏 → "7)" 裸数字存活，色块补全按条色 Fabricate 出 R7
    final whole = OcrElem(0, const Rect.fromLTRB(3288, 207, 3541, 311), null, 27)
      ..dbgText = "(27)";
    final frag = OcrElem(1, const Rect.fromLTRB(3478, 208, 3544, 312), null, 7)
      ..dbgText = "7)";
    final merged = mergeSegmentElems(
      [(whole, 0), (frag, 1)],
      [0.0, 3446.0],
      [3800.0, 7246.0],
    );
    expect(merged.length, 1);
    expect(merged.first.dbgText, "(27)");
  });

  test('removeNestedFragments：同行嵌套碎片删除（wx2 段切尾巴/wx3 重复子元素）', () {
    // wx2 实测：全读 "(27)"(3288..3541) + 段切尾巴 "7)"(3478..3544) 同行
    // 嵌套；H16 "(26)"(10169..10433) + 尾巴 "3)"(10366..10430) 同款。
    // wx3 实测：整读 "D15"(9416..9624) 之外 ML Kit 又吐出末位 "5" 子元素
    // (9610..9623) 嵌在其框尾——不删会在配对轮 1 抢走 D15 的 "(6)"。
    // 不同条目的元素并排（无重叠）不受影响
    final wholeA = OcrElem(0, const Rect.fromLTRB(3288, 207, 3541, 311), null, 27)
      ..dbgText = "(27)";
    final fragA = OcrElem(1, const Rect.fromLTRB(3478, 208, 3544, 312), null, 7)
      ..dbgText = "7)";
    final code = OcrElem(2, const Rect.fromLTRB(9416, 949, 9624, 1057), 3, null)
      ..dbgText = "D15";
    final subElem = OcrElem(3, const Rect.fromLTRB(9610, 940, 9623, 1061), null, 5)
      ..dbgText = "5";
    final count6 = OcrElem(4, const Rect.fromLTRB(9791, 949, 9970, 1057), null, 6)
      ..dbgText = "(6)";
    final elems = [wholeA, fragA, code, subElem, count6];
    final removed = removeNestedFragments(elems);
    expect(removed, 2);
    expect(elems.length, 3);
    expect(elems.any((e) => e.dbgText == "7)"), isFalse);
    expect(elems.any((e) => e.dbgText == "5"), isFalse);
    expect(elems.any((e) => e.dbgText == "(27)"), isTrue);
    expect(elems.any((e) => identical(e, code)), isTrue);
    expect(elems.any((e) => identical(e, count6)), isTrue);
  });

  test('swatchCodeCandidates：颗数槽位的裸数字不补全、孤立裸数字保留', () {
    // 括号被误读的颗数（"(97)"→"7)"）：左侧同行 4 字高内已有其色号，
    // 槽位判定它是颗数不是掉字母色号——补全会 Fabricate 出 X7 幻影
    //（wx1 用户实测 R7：深蓝条色最近匹配到深绿 R7）
    final code = OcrElem(0, const Rect.fromLTRB(2896, 216, 3032, 304), 3, null)
      ..dbgText = "D4";
    final misread = OcrElem(1, const Rect.fromLTRB(3300, 207, 3366, 311), null, 7)
      ..dbgText = "7)";
    // 真掉字母色号：色号位孤立裸数字（new1 型），左侧近距无任何色号
    final lone = OcrElem(2, const Rect.fromLTRB(5000, 207, 5100, 311), null, 16)
      ..dbgText = "16";
    // 带括号颗数本就不在候选内
    final paren = OcrElem(3, const Rect.fromLTRB(5300, 207, 5500, 311), null, 33)
      ..dbgText = "(33)";
    final out = swatchCodeCandidates([code, misread, lone, paren]);
    expect(out.length, 1);
    expect(identical(out.first, lone), isTrue);
  });

  test('fixOrphanCountCodes：色号在颗数上方 3.1 字高处不算孤儿（wx1 回归）',
      () async {
    // wx1 实测几何（×8 放大）：色号 top=237 h=67、颗数 top=496 h=88，
    // 颗数顶-色号中心 ≈ 3.1*avgH（配对轮 2 窗口内，配得上对）。旧 2.5·avgH
    // 窗口把这类有主颗数全判孤儿，空隙 OCR 把真色号再读一遍产出 28 条
    // 重复锚点，UI 去重取首条后清单几乎整列颗数 0
    final code = OcrElem(0, const Rect.fromLTRB(233, 237, 330, 304), 0, null)
      ..dbgText = "A4";
    final count = OcrElem(1, const Rect.fromLTRB(256, 496, 295, 584), null, 1)
      ..dbgText = "1";
    final notes = <String>[];
    final fixed = await fixOrphanCountCodes(
      _palette,
      [code, count],
      img.Image(width: 8, height: 8),
      buildCodeMap(_palette),
      ".",
      notes,
    );
    expect(fixed, 0); // 不是孤儿：不触发空隙重读
    expect(notes, isEmpty);
  });

  test('fixOrphanCodeCounts：颗数被吞的色号裁下方重读补回（wx1 回归）',
      () async {
    // wx1 实测几何：正常条目 A4(233,237 97x67)+颗数1(256,496 39x88) 提供字高
    // 基准；B22(982,240 153x64) 的颗数 5 被 ML Kit 整条吞掉。注入的假 OCR
    // 在放大小区内返回 "5"（框按小区坐标给，换算回全图应落在色号正下方）
    final code = OcrElem(0, const Rect.fromLTRB(233, 237, 330, 304), 0, null)
      ..dbgText = "A4";
    final count = OcrElem(1, const Rect.fromLTRB(256, 496, 295, 584), null, 1)
      ..dbgText = "1";
    final orphanCode = OcrElem(2, const Rect.fromLTRB(982, 240, 1135, 304), 1,
            null)
        ..dbgText = "B22";
    final elems = [code, count, orphanCode];
    // 宽带小区：avgH=73、acx=1058.5，gLeft=acx-6*avgH≈620、gTop=496-0.3*73
    // ≈474，×3 缩放。假框换算目标 abs≈(1040,490)（行带上真颗数位）：
    // rel = (abs-小区原点)*3
    final fixed = await fixOrphanCodeCounts(
      elems,
      img.Image(width: 2000, height: 1300),
      ".",
      ocrGap: (_) async => ("5", const Rect.fromLTRB(1258, 47, 1498, 317)),
    );
    expect(fixed, 1);
    final added = elems.where((e) => e.dbgText.contains("下方OCR")).single;
    expect(added.count, 5);
    // 补回的颗数经配对轮 2 与孤儿色号配上（不是 A4 抢走）
    final paired = pairLegendOcr(elems);
    expect(paired, contains((1, 5)));
    expect(paired, contains((0, 1)));
    expect(orphanCode.pairedCount, 5);
  });

  test('fixOrphanCodeCounts：右侧同行已有颗数的色号不触发重读', () async {
    // 经典布局（颗数在色号右侧同行）：配对轮 1 窗口内有颗数的色号不是孤儿
    final code = OcrElem(0, const Rect.fromLTRB(100, 40, 140, 60), 0, null)
      ..dbgText = "A1";
    final count = OcrElem(1, const Rect.fromLTRB(160, 42, 180, 62), null, 64)
      ..dbgText = "(64)";
    final elems = [code, count];
    final fixed = await fixOrphanCodeCounts(
      elems,
      img.Image(width: 400, height: 200),
      ".",
      ocrGap: (_) => throw "不应触发重读",
    );
    expect(fixed, 0);
    expect(elems.length, 2);
  });

  test('fuseLegendBars：条内色号先认领（密集横排链式错位回归）', () {
    // 两块色条 A[0,100] B[120,220]；B 的色号印在 B 内，A 的色号在 A 右缘
    // 外（两块之间）。旧版按元素序单轮认领时 A 的色号先到会把 B 的条抢
    // 走，B 的条内色号被挤到 A（wx1：E16 抢 F5 的条，F5 再挤 F7 的）
    final barA = LegendBar(const Rect.fromLTRB(0, 0, 100, 120), 227, 26, 28);
    final barB = LegendBar(const Rect.fromLTRB(120, 0, 220, 120), 31, 120, 180);
    // A 的色号：贴 A 右缘（对 B 的左窗口也近——次近距离）
    final codeA = OcrElem(0, const Rect.fromLTRB(102, 40, 118, 64), 0, null)
      ..dbgText = "A1";
    // B 的色号：印在 B 条内
    final codeB = OcrElem(1, const Rect.fromLTRB(140, 48, 180, 72), 1, null)
      ..dbgText = "B1";
    fuseLegendBars(_palette, [codeA, codeB], const [], [barA, barB]);
    expect(identical(barB.codeElem, codeB), isTrue);
    expect(identical(barA.codeElem, codeA), isTrue);
  });

  test('fuseLegendBars：已配对颗数不再被条几何抢走', () {
    // 色号是孤立锚点（无色条），其颗数已由 pairLegendOcr 配对消费——
    // 近旁色条不得再把它记作自己的颗数（一颗数进两条目）
    final bar = LegendBar(const Rect.fromLTRB(0, 0, 100, 120), 227, 26, 28);
    final code = OcrElem(0, const Rect.fromLTRB(10, 130, 50, 154), 0, null)
      ..dbgText = "A1";
    final count = OcrElem(1, const Rect.fromLTRB(20, 160, 40, 184), null, 64)
      ..dbgText = "64";
    pairLegendOcr([code, count]); // 64 配给 A1，used = true
    expect(count.used, isTrue);
    fuseLegendBars(_palette, [code, count], const [], [bar]);
    expect(bar.countElem, isNull); // 没被条抢走
  });

  // ---- 字形模板匹配（matchCountGlyphs）----

  test('matchCountGlyphs：孔洞门控+中位数NCC 识别漏读颗数（毒模板被隔离）',
      () {
    final hit = matchCountGlyphs(
      _glyphFixture(),
      _glyphCounts(),
      const Rect.fromLTWH(90, 104, 60, 68),
    );
    expect(hit, isNotNull);
    expect(hit!.$1, 6); // 6 胜出，40 毒模板（8 字形双孔）被孔洞门控排除
    // 返回框落在目标字形上（后续配对轮 2 的几何窗口依赖它）
    expect(hit.$2.left, closeTo(100, 2));
    expect(hit.$2.top, closeTo(110, 2));
  });

  test('matchCountGlyphs：空白窗口/字形杂乱返回 null（宁缺毋滥）', () {
    final im = _glyphFixture();
    final counts = _glyphCounts();
    // 空白窗口：无墨水连通域（目标行粘连对在 x200-278，不碰本窗口）
    expect(
      matchCountGlyphs(im, counts, const Rect.fromLTWH(300, 104, 60, 68)),
      isNull,
    );
    // 窗口跨进模板行捞到 6 个字形：按混入邻条目拒绝
    expect(
      matchCountGlyphs(im, counts, const Rect.fromLTWH(80, 8, 420, 68)),
      isNull,
    );
  });

  test('matchCountGlyphs：孔拓扑无同类的字形一律不认（孔洞门控回归）', () {
    // 目标 8 字形（双孔），模板池去掉双孔类（8 本尊 + 40 的毒 0 位画的
    // 也是 8）只剩无孔/单孔类——孔数对不上全类出局返回 null。门控若被
    // 删掉，8 字形会被 NCC 硬归类成环状的 0 出非 null，此测试即失败
    //（wx1 C21 的 6↔9 镜像混乱正是靠孔指纹拦的）
    final counts = [
      for (final e in _glyphCounts())
        if (e.count != 8 && e.count != 40) e,
    ];
    final im = _glyphFixture();
    expect(
      matchCountGlyphs(im, counts, const Rect.fromLTWH(444, 4, 64, 72)),
      isNull,
    );
    // 对照：池里存在「单孔在上」类（9）时同一构造认得出——证上面的 null
    // 是门控拒绝，不是窗口/模板构造问题
    expect(
      matchCountGlyphs(im, counts, const Rect.fromLTWH(164, 4, 64, 72))!.$1,
      9,
    );
  });

  test('matchCountGlyphs：粘连双字并成一个连通域按过宽拒绝', () {
    // 目标行两个 8 交叠 2px 粘连成一个连通域：模板侧有「连通域数=位数」
    // 拒绝，目标侧原先没有等价拒绝——粘连的两位数会被当单字形硬分类
    //（评审确认）。宽度超模板中位字形宽 1.4 倍即拒绝返回 null
    final im = _glyphFixture();
    expect(
      matchCountGlyphs(im, _glyphCounts(), const Rect.fromLTWH(194, 104, 96, 68)),
      isNull,
    );
  });

  // ---- 统一布局：碎片合并 / 幻影括号剥离 / 布局推断+右侧补读 ----

  test('detectLegendBars：同色碎片（条内白缝劈开）合并为一条', () {
    // 一个红色块被竖白缝劈成两段、再被横白线劈成上下带——3 条碎片
    // 应迭代合并回 1 条（new1：1816px 色块碎成 8-40px 窄条产出幻影条目）
    final im = img.Image(width: 260, height: 130);
    img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
    void block(int x0, int y0, int x1, int y1) {
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          im.setPixelRgba(x, y, 0xE3, 0x1A, 0x1C, 255);
        }
      }
    }
    block(20, 20, 100, 70);
    block(108, 20, 220, 70);
    block(20, 84, 220, 112);
    final bars = detectLegendBars(im);
    expect(bars.length, 1);
    expect(bars[0].rect.left, closeTo(20, 2));
    expect(bars[0].rect.right, closeTo(220, 2));
    expect(bars[0].rect.top, closeTo(20, 2));
    expect(bars[0].rect.bottom, closeTo(112, 2));
  });

  test('stripPhantomParenCount：文本证据（对侧括号在场）的首尾幻影剥离', () {
    // new1 实拍误读样例：单侧括号读出时，对侧幻影 1/I 有文本证据可剥
    expect(stripPhantomParenCount("131)", parens: true), 31);
    expect(stripPhantomParenCount("(391", parens: true), 39);
    expect(stripPhantomParenCount("(31", parens: true), 3);
    // 真括号被正确读出 / 无格式证据（非括号图例）：一律不动
    expect(stripPhantomParenCount("(86)", parens: true), 86);
    expect(stripPhantomParenCount("1531", parens: false), 1531);
    expect(stripPhantomParenCount("121", parens: false), 121);
    // 无任何证据（无括号字符、无字形图）时不剥——"(15)" 被干净读成
    // "15]" 时真前导 1 就是被旧版无证据规则误杀成 5 的（new1 F20 回归）
    expect(stripPhantomParenCount("1531", parens: true), 1531);
    expect(stripPhantomParenCount("i261", parens: true), 1261);
  });

  test('stripPhantomParenCount：字形宽度证据（证据B）剥弧线保真 1', () {
    // 墨水连通域按印刷几何画：括号弧线 ~16px 远窄于数字 ~40px 的 0.7 倍
    //（28px），真数字 1 ~36px 宽过阈值保住
    img.Image inkRow(List<int> widths) {
      var x = 8;
      final im = img.Image(
        width: 16 + widths.fold(0, (a, b) => a + b + 8),
        height: 76,
      );
      img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
      for (final w in widths) {
        for (var y = 8; y < 68; y++) {
          for (var dx = 0; dx < w; dx++) {
            im.setPixelRgba(x + dx, y, 20, 20, 20, 255);
          }
        }
        x += w + 8;
      }
      return im;
    }

    Rect whole(img.Image im) =>
        Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble());

    // "1531"（"(53)" 双弧线被读成 1）：两侧弧线都剥
    final im = inkRow([16, 40, 40, 16]);
    expect(
      stripPhantomParenCount("1531", parens: true, scaled: im, rect: whole(im)),
      53,
    );
    // "15]"（"(15)" 被干净读出）：尾弧窄剥掉，真前导 1 宽保留
    final im2 = inkRow([36, 40, 16]);
    expect(
      stripPhantomParenCount("15]", parens: true, scaled: im2, rect: whole(im2)),
      15,
    );
    // "i261"：无文本证据但有字形证据，两侧弧线剥掉
    final im3 = inkRow([16, 40, 40, 16]);
    expect(
      stripPhantomParenCount(
        "i261",
        parens: true,
        scaled: im3,
        rect: whole(im3),
      ),
      26,
    );
    // 字符数与连通域不对应（粘连/漏读）：几何证据失效不剥
    final im4 = inkRow([40, 40, 40]);
    expect(
      stripPhantomParenCount(
        "1531",
        parens: true,
        scaled: im4,
        rect: whole(im4),
      ),
      1531,
    );
  });

  test('stripPhantomParenCount：证据B极性自适应+结构规则（new1 复位）', () {
    // 三种墨水极性都按印刷几何画：白底深字 / 深底白字（H5 型，固定 140
    // 亮墨干净）/ 暗底暗字（B22/G29 型印深色条上，对比度 Δ≈42，只有
    // Otsu 分得开）
    img.Image row(List<int> widths, int bg, int ink) {
      var x = 8;
      final im = img.Image(
        width: 16 + widths.fold(0, (a, b) => a + b + 8),
        height: 76,
      );
      img.fill(im, color: img.ColorRgba8(bg, bg, bg, 255));
      for (final w in widths) {
        for (var y = 8; y < 68; y++) {
          for (var dx = 0; dx < w; dx++) {
            im.setPixelRgba(x + dx, y, ink, ink, ink, 255);
          }
        }
        x += w + 8;
      }
      return im;
    }

    Rect whole(img.Image im) =>
        Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble());

    // H5 "(98)"→"1983"（深底白字）：双侧窄弧对称剥两端，尾弧读成 3 也剥
    final h5 = row([16, 48, 40, 16], 30, 235);
    expect(
      stripPhantomParenCount("1983", parens: true, scaled: h5, rect: whole(h5)),
      98,
    );
    // B22 "(26)"→"i261"（暗底暗字）：m==n+1 丢弃首 8px 弧屑后对称剥
    final b22 = row([8, 16, 40, 40, 16], 72, 30);
    expect(
      stripPhantomParenCount("i261", parens: true, scaled: b22, rect: whole(b22)),
      26,
    );
    // F20 "(15)"→"15)"：尾括号已读出、首 1 无旁证——真前导 1 保住
    final f20 = row([17, 32, 23], 255, 20);
    expect(
      stripPhantomParenCount("15)", parens: true, scaled: f20, rect: whole(f20)),
      15,
    );
    // E2 "(18)"→"18)"：双侧都不窄（24/40 宽于阈），保持原文
    final e2 = row([24, 16, 40], 255, 20);
    expect(
      stripPhantomParenCount("18)", parens: true, scaled: e2, rect: whole(e2)),
      18,
    );
    // E2 实拍构型：'(' 印在元素框外左侧（框只盖 "18)" 三字形）——框内
    // m==n=3 双侧窄且尾是括号/首是幻影 1，旧规则对称剥成 8；危险对称
    // 复核外扩 0.8 字高数出 4 域且首域（弧线）跨出框左缘 → 保原文 → 18
    final e2real = row([16, 16, 48, 16], 255, 20);
    expect(
      stripPhantomParenCount(
        "18)",
        parens: true,
        scaled: e2real,
        rect: const Rect.fromLTWH(32, 0, 96, 76),
      ),
      18,
    );
    // G29 "(53)"→"1531"（5/3 粘成一个 88px 连通域，m==n-1）：maxW/2 估
    // 基准后对称剥
    final g29 = row([16, 88, 15], 72, 30);
    expect(
      stripPhantomParenCount(
        "1531",
        parens: true,
        scaled: g29,
        rect: whole(g29),
      ),
      53,
    );
    // 图像无意见退回证据A："i98)" 连通域数对不上（2≠4±1）→ 文本兜底剥 i
    final junk = row([40, 40], 255, 20);
    expect(
      stripPhantomParenCount(
        "i98)",
        parens: true,
        scaled: junk,
        rect: whole(junk),
      ),
      98,
    );
    // "(31)"→"131)"：双窄弧对称剥
    final d31 = row([16, 40, 36, 16], 255, 20);
    expect(
      stripPhantomParenCount(
        "131)",
        parens: true,
        scaled: d31,
        rect: whole(d31),
      ),
      31,
    );
  });

  test('applyPhantomParenStrip：全表应用只改写被剥离的颗数', () {
    // a 的 "(391" 尾 1 是幻影（首弧在场为证）；b 的 "(86)" 真括号正确
    // 读出——字形证据两侧剥离值中性，不触发改写
    final im = img.Image(width: 200, height: 100);
    img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
    void ink(double x0, double y0, double x1, double y1) {
      for (var y = y0.toInt(); y < y1.toInt(); y++) {
        for (var x = x0.toInt(); x < x1.toInt(); x++) {
          im.setPixelRgba(x, y, 20, 20, 20, 255);
        }
      }
    }

    ink(0, 0, 16, 20);
    ink(24, 0, 64, 20);
    ink(72, 0, 112, 20);
    ink(120, 0, 136, 20);
    ink(0, 40, 16, 60);
    ink(24, 40, 64, 60);
    ink(72, 40, 112, 60);
    ink(120, 40, 136, 60);
    final a = OcrElem(0, const Rect.fromLTRB(0, 0, 136, 20), null, 391)
      ..dbgText = "(391";
    final b = OcrElem(1, const Rect.fromLTRB(0, 40, 136, 60), null, 86)
      ..dbgText = "(86)";
    final stripped = applyPhantomParenStrip([a, b], true, im);
    expect(stripped, 1);
    expect(a.count, 39);
    expect(b.count, 86); // 真括号不动
  });

  test('fixOrphanCountCodes：右侧布局的无括号裸数字也判孤儿（new1 G29）',
      () async {
    // 右侧带括号布局中 "(53)" 被读成 "1531"（幻影剥离前无括号可循）：
    // 按布局选中孤儿，裁左侧空隙重读补回色号（注入假 OCR）
    final code1 = OcrElem(0, const Rect.fromLTRB(100, 40, 140, 60), 0, null)
      ..dbgText = "A1";
    final count1 = OcrElem(1, const Rect.fromLTRB(170, 42, 205, 62), null, 64)
      ..dbgText = "(64)";
    final bare = OcrElem(2, const Rect.fromLTRB(900, 42, 1060, 62), null, 1531)
      ..dbgText = "1531";
    final elems = [code1, count1, bare];
    final notes = <String>[];
    final fixed = await fixOrphanCountCodes(
      _palette,
      elems,
      img.Image(width: 1200, height: 100),
      buildCodeMap(_palette),
      ".",
      notes,
      layout: const LegendLayout(true, 300, true),
      ocrGap: (_) async => ("A1", const Rect.fromLTRB(60, 40, 140, 60)),
    );
    expect(fixed, 1);
    final added = elems.where((e) => e.dbgText.contains("空隙OCR")).single;
    expect(added.code, 0);
    // 补回的色号与裸数字配上对（配对轮 1 同行右侧窗口内）
    expect(pairLegendOcr(elems), contains((0, 1531)));
    expect(notes, isEmpty);
  });

  test('inferLegendLayout+fixRightCountsByLayout：右侧布局缺颗数按模板位补读',
      () async {
    // 右侧同行带括号布局：code1/code3 配上颗数，code2 的颗数被吞——
    // 按模板距离裁小区重读（注入假 OCR），补回后配对轮 1 用上
    final code1 = OcrElem(0, const Rect.fromLTRB(100, 40, 140, 60), 0, null)
      ..dbgText = "A1";
    final count1 = OcrElem(1, const Rect.fromLTRB(170, 42, 205, 62), null, 64)
      ..dbgText = "(64)";
    final code2 = OcrElem(2, const Rect.fromLTRB(300, 40, 340, 60), 1, null)
      ..dbgText = "B1";
    final code3 = OcrElem(3, const Rect.fromLTRB(500, 40, 540, 60), 2, null)
      ..dbgText = "C1";
    final count3 = OcrElem(4, const Rect.fromLTRB(570, 42, 605, 62), null, 15)
      ..dbgText = "(15)";
    final elems = [code1, count1, code2, code3, count3];
    final layout = inferLegendLayout(elems);
    expect(layout, isNotNull);
    expect(layout!.countsRight, isTrue);
    expect(layout.dx, closeTo(67.5, 0.1));
    expect(layout.parens, isTrue);
    // 注入假 OCR：code2 右侧模板位（小区原生 x≈30-45 → ×3 后 bigGap 坐标）
    final fixed = await fixRightCountsByLayout(
      elems,
      img.Image(width: 700, height: 100),
      ".",
      layout,
      ocrGap: (_) async => ("(15)", const Rect.fromLTRB(90, 30, 135, 75)),
    );
    expect(fixed, 1);
    final paired = pairLegendOcr(elems);
    expect(paired, contains((1, 15)));
    expect(paired, contains((0, 64)));
  });

  test('fuseLegendBars：密集单行去重不误杀邻条（wx38 回归）', () {
    // wx38 实拍复刻：4 条密排色条（条宽 80、间距 20），仅中间两条的条内
    // 色号被 OCR 读出，行左端另有一个没归属上色条的孤立色号。旧去重是
    // 「任何 OCR 锚点可杀颜色候选、且无左界」：孤立色号把右侧全部颜色
    // 候选杀光、已认领色号的条锚点又杀掉邻条候选（wx38 31 格只剩 5 条）。
    // 修复后只有孤立锚点参与去重且有左界——4 条 + 孤立共 5 条全保住
    final im = img.Image(width: 540, height: 120);
    img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
    for (var i = 0; i < 4; i++) {
      final left = 140 + i * 100;
      final rgb = _barRgb(i);
      for (var y = 20; y < 100; y++) {
        for (var x = left; x < left + 80; x++) {
          im.setPixelRgba(x, y, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF,
              rgb & 0xFF, 255);
        }
      }
    }
    final lone = OcrElem(0, const Rect.fromLTRB(20, 50, 56, 74), 4, null)
      ..dbgText = "A2";
    final codeB = OcrElem(1, const Rect.fromLTRB(260, 50, 296, 74), 1, null)
      ..dbgText = "B1";
    final codeC = OcrElem(2, const Rect.fromLTRB(360, 50, 396, 74), 2, null)
      ..dbgText = "C1";
    final bars = detectLegendBars(im);
    expect(bars.length, 4);
    final fused = fuseLegendBars(_palette, [lone, codeB, codeC], const [], bars);
    // 输出序 = 位置序（逐行从左到右）：孤立 A2 锚点在行最左端（x20 <
    // 首条 140），按中心 y 聚行后同排一行、以 left 排序应居首——旧 top
    // 排序把它劈到行尾是混合锚点来源的排序伪影（t4 实测同因）
    expect(fused, [
      (4, 0), // 左端孤立 A2（真实条目，保留）
      (0, 0), // 条 0 颜色候选 A1：未被左端远处孤立 A2 杀（新增左界）
      (1, 0), // 条 1 条内色号 B1
      (2, 0), // 条 2 条内色号 C1
      (3, 0), // 条 3 颜色候选 D1：未被邻条条锚点杀（条锚点不参与去重）
    ]);
  });

  // ---- 网格盲区补全（fixBlindGridCodes）----

  test('fixBlindGridCodes+fixRightCountsByLayout：静默格补码再按模板位补颗数（new1 C23）',
      () async {
    // 3×3 网格，(行1,列1) 格完全静默（无色号/颗数/色条——白底浅字被
    // ML Kit 整条吞掉），其余 8 格齐备。格位重读注入 "A2"、右侧补读注入
    // "(12)"，链路应产出 A2=12 而不是丢条目
    final elems = <OcrElem>[];
    var seq = 0;
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 3; c++) {
        final x = 100.0 + c * 800, y = 100.0 + r * 300;
        if (r == 1 && c == 0) {
          continue; // 静默格
        }
        final code = OcrElem(
          seq++,
          Rect.fromLTRB(x, y, x + 120, y + 60),
          (r * 3 + c) % 7,
          null,
        )..dbgText = "code$r$c";
        final count = OcrElem(
          seq++,
          Rect.fromLTRB(x + 180, y, x + 240, y + 60),
          null,
          10 + r * 3 + c,
        )..dbgText = "(${10 + r * 3 + c})";
        elems.addAll([code, count]);
      }
    }
    final notes = <String>[];
    final probes = <int>[];
    final fixed = await fixBlindGridCodes(
      elems,
      const [],
      img.Image(width: 2400, height: 900),
      buildCodeMap(_palette),
      ".",
      notes,
      ocrGap: (big) async {
        probes.add(big.width);
        return ("A2", const Rect.fromLTWH(150, 120, 150, 180));
      },
    );
    expect(fixed, 1);
    expect(probes.length, 1); // 只探了静默格，其余 8 格元素在场不触发
    final added = elems.where((e) => e.dbgText.contains("盲格OCR")).single;
    expect(added.code, 4); // A2
    expect(notes, isEmpty);
    // 补回的色号无颗数：布局探测 + 右侧模板位补读接棒
    final layout = inferLegendLayout(elems);
    expect(layout!.countsRight, isTrue);
    final rightFixed = await fixRightCountsByLayout(
      elems,
      img.Image(width: 2400, height: 900),
      ".",
      layout,
      ocrGap: (_) async => ("(12)", const Rect.fromLTWH(360, 120, 180, 90)),
    );
    expect(rightFixed, 1);
    expect(pairLegendOcr(elems), contains((4, 12)));
  });

  test('buildCodeMap：一位数色号补零填充别名（图纸印 A01/B09 型）', () {
    final m = buildCodeMap(_palette);
    // 零填充原文与混淆变体都命中原色（A01→A1 索引0、W01→W1 索引5）
    expect(m["A01"], 0);
    expect(m["W01"], 5);
    expect(m["AO1"], 0); // 0↔O 混淆变体带别名
    // 两位数色号数字部分已是两位不再补（MARD A10 印刷即 A10）；
    // 一位数字部分的两位号照补：A2→A02（图纸印 A02 37 正是此型）
    expect(m["A2"], 4);
    expect(m["A02"], 4);
    // H9 别名 H09 也通
    expect(m["H09"], 6);
  });

  test('fixBlindGridCodes：有颗数的格子不探测（归空隙 OCR 管，不越权）', () async {
    // 2×3 网格，(行0,列1) 格只有颗数（G29 型：色号被吞但颗数在场）——
    // 盲格探测不得触发（注入 ocrGap 即抛错）
    final elems = <OcrElem>[];
    var seq = 0;
    for (var r = 0; r < 2; r++) {
      for (var c = 0; c < 3; c++) {
        final x = 100.0 + c * 800, y = 100.0 + r * 300;
        if (r == 0 && c == 0) {
          elems.add(
            OcrElem(seq++, Rect.fromLTRB(x + 80, y, x + 140, y + 60), null, 53)
              ..dbgText = "(53)",
          );
          continue;
        }
        final code = OcrElem(
          seq++,
          Rect.fromLTRB(x, y, x + 120, y + 60),
          c * 2 + r,
          null,
        )..dbgText = "code$r$c";
        final count = OcrElem(
          seq++,
          Rect.fromLTRB(x + 180, y, x + 240, y + 60),
          null,
          7,
        )..dbgText = "(7)";
        elems.addAll([code, count]);
      }
    }
    final fixed = await fixBlindGridCodes(
      elems,
      const [],
      img.Image(width: 2600, height: 600),
      buildCodeMap(_palette),
      ".",
      [],
      ocrGap: (_) => throw "有颗数的格子不应探测",
    );
    expect(fixed, 0);
  });
}

// 5×7 像素字体（scale 8 → 每字 40×56）：孔洞拓扑与 wx1 实拍字体一致
// ——6/9 一孔、8 两孔、0 一孔、3/4 无孔
const _font5x7 = <String, List<String>>{
  "0": ["#####", "#...#", "#...#", "#...#", "#...#", "#...#", "#####"],
  "3": ["#####", "....#", "....#", "#####", "....#", "....#", "#####"],
  "4": ["#...#", "#...#", "#...#", "#####", "....#", "....#", "....#"],
  "6": ["#####", "#....", "#....", "#####", "#...#", "#...#", "#####"],
  "8": ["#####", "#...#", "#...#", "#####", "#...#", "#...#", "#####"],
  "9": ["#####", "#...#", "#...#", "#####", "....#", "....#", "....#"],
};

void _drawDigit(img.Image im, String d, int x, int y, [int scale = 8]) {
  final rows = _font5x7[d]!;
  for (var ry = 0; ry < rows.length; ry++) {
    for (var rx = 0; rx < rows[ry].length; rx++) {
      if (rows[ry][rx] != "#") {
        continue;
      }
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          im.setPixelRgba(
              x + rx * scale + dx, y + ry * scale + dy, 20, 20, 20, 255);
        }
      }
    }
  }
}

/// 字形匹配测试底图：模板行（y=10）8/3/9/30/40（毒模板：0 位画的是 8——
/// 复刻 wx1 F5「16→10」误读，实测毒字形双孔）/63，目标行（y=110）一个 6
/// + 一对交叠 2px 粘连成一个连通域的 8（目标侧粘连拒绝回归用）
img.Image _glyphFixture() {
  final im = img.Image(width: 720, height: 200);
  img.fill(im, color: img.ColorRgba8(255, 255, 255, 255));
  _drawDigit(im, "8", 10, 10);
  _drawDigit(im, "3", 90, 10);
  _drawDigit(im, "9", 170, 10);
  _drawDigit(im, "3", 250, 10);
  _drawDigit(im, "0", 310, 10);
  _drawDigit(im, "4", 390, 10);
  _drawDigit(im, "8", 450, 10);
  _drawDigit(im, "6", 530, 10);
  _drawDigit(im, "3", 610, 10);
  _drawDigit(im, "6", 100, 110);
  _drawDigit(im, "8", 200, 110);
  _drawDigit(im, "8", 238, 110);
  return im;
}

List<OcrElem> _glyphCounts() => [
      for (final (seq, n, r) in [
        (0, 8, const Rect.fromLTRB(8, 8, 52, 68)),
        (1, 3, const Rect.fromLTRB(88, 8, 132, 68)),
        (2, 9, const Rect.fromLTRB(168, 8, 212, 68)),
        (3, 30, const Rect.fromLTRB(248, 8, 352, 68)),
        (4, 40, const Rect.fromLTRB(388, 8, 492, 68)),
        (5, 63, const Rect.fromLTRB(528, 8, 652, 68)),
      ])
        OcrElem(seq, r, null, n)..dbgText = "($n)",
    ];
