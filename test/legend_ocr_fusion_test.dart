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
}
