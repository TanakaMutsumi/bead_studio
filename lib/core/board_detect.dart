/// 豆板底部「列序尺」检测（board_detect）——给主体检测一个板底硬边界
///
/// 列序尺 = 豆板最底一行印刷的列号数字（1,2,3,... 从 1 起连续递增、
/// 全行同一种颜色）。用户规格（2026-09-14）：
///   「豆板底部列序的行，特征应该具体是两点，从左到右的连续的从1开始的
///    数字，并且是连续的同种颜色」
///
/// 无 OCR 的结构代理（数字值/连续性不可验，用可验的同色+密集微小游程+
/// 全宽跨度代替；数字碎笔画使游程数远大于列数，42 列板实测 56-71 个）：
///
/// 1. **行签名**：>=40 个非白游程（>=2px、剔贴边页框）、最长 <=26px
///    （数字笔画微小；图例色片 145px+、豆行 >=30px 直接排除）、主色
///    （nibble 三元组众数 +-1）覆盖 >=85%（全行同色；图例表文字行实测
///    13-72% 多色）、横向跨度 >=88% 宽、非白占比 4-30%。
/// 2. **防伪一（白豆板格线）**：白豆行之间的空隙游程（格线残段）与尺行
///    同签名（微小/同色/等距/全宽），但白豆行上下必贴横贯格线——候选行
///    +-6px（随宽度缩放）邻行存在 >=0.5w 长游程即否决。
/// 3. **防伪二（位置窗）**：板内图案行（天空/浅色底纹的碎游程行）也能
///    偶然命中签名（u1 画稿区 4 处、test_pic5 图纸区 2 处实测假阳性），
///    但列序尺天然紧贴图例/板底——只收 scanBottom（图例带顶或图底）上方
///    120px 内的带（fleet 真例 4-32px），画稿区假阳性距底 268px+ 全灭。
/// 4. **带合并**：相邻命中行（<=8px）并带；带必须整体在 scanBottom 之上。
///
/// 用途：_autoDetectSubject 的行扫描下界。图例检测失败（wx4 类无图例图）
/// 时 scanBottom=图底，尺下方的页脚/导航条会被当内容框进主体——尺顶是
/// 不依赖图例的板底硬边界。阈值随图宽 /1440 等比缩放，无需归一化。
library;

import 'package:image/image.dart' as img;

import 'legend_detect.dart' show qWhite;

/// 在 scanBottom 上方 120px 窗内找列序尺，返回尺带顶（图片坐标）；
/// 无合格带返回 null（调用方维持原 scanBottom）
int? detectRulerTop(img.Image image, int scanBottom) {
  final w = image.width, h = image.height;
  final k = w / 1440.0; // 阈值缩放因子（1440 基准）
  final mxCap = 26 > w / 55 ? 26.0 : w / 55; // 与 PIL 原型 max(26, w/55) 同式
  final neighborOff = (6 * k).round();
  final mergeGap = (8 * k).round();
  final window = (120 * k).round();
  final longRun = 0.5 * w;

  int qAt(int x, int y) {
    final p = image.getPixel(x, y);
    return ((p.r.toInt() >> 4) << 8) |
        ((p.g.toInt() >> 4) << 4) |
        (p.b.toInt() >> 4);
  }

  // 一行内 >=2px 非白游程（剔贴边页框）
  List<(int, int, int)> rowInk(int y) {
    final runs = <(int, int, int)>[]; // (量化色, 长, 起点)
    var col = -1, len = 0, start = 0;
    for (var x = 0; x < w; x++) {
      final q = qAt(x, y);
      if (q == col) {
        len++;
      } else {
        if (col >= 0) runs.add((col, len, start));
        col = q;
        len = 1;
        start = x;
      }
    }
    if (col >= 0) runs.add((col, len, start));
    return [
      for (final (c, l, s) in runs)
        if (!qWhite(c) && s > 0 && s + l < w && l >= 2) (c, l, s),
    ];
  }

  // 行签名（见库注释 1）
  bool rulerRow(List<(int, int, int)> ink) {
    final n = ink.length;
    if (n < 40 || n > 150) return false;
    var mx = 0, mass = 0;
    for (final (_, l, _) in ink) {
      if (l > mx) mx = l;
      mass += l;
    }
    if (mx > mxCap) return false;
    final nw = mass / w;
    if (nw < 0.04 || nw > 0.30) return false;
    // 主色（众数 nibble 三元组）覆盖 >=85%
    final counts = <int, int>{};
    for (final (c, _, _) in ink) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    var modeC = 0, modeN = 0;
    counts.forEach((c, n) {
      if (n > modeN) {
        modeN = n;
        modeC = c;
      }
    });
    final mr = (modeC >> 8) & 15, mg = (modeC >> 4) & 15, mb = modeC & 15;
    var same = 0;
    for (final (c, _, _) in ink) {
      final dr = ((c >> 8) & 15) - mr,
          dg = ((c >> 4) & 15) - mg,
          db = (c & 15) - mb;
      if (dr.abs() <= 1 && dg.abs() <= 1 && db.abs() <= 1) same++;
    }
    if (same < 0.85 * n) return false;
    final ext = ink.last.$3 + ink.last.$2 - ink.first.$3;
    return ext >= 0.88 * w;
  }

  // 邻行长游程（横贯格线）检测（见库注释 2）
  bool neighborHasLongRun(int y) {
    for (final off in [neighborOff, neighborOff * 2 ~/ 3, neighborOff ~/ 3]) {
      for (final yy in [y - off, y + off]) {
        if (yy < 0 || yy >= h) continue;
        var len = 0, mx = 0;
        for (var x = 0; x < w; x++) {
          if (!qWhite(qAt(x, yy))) {
            len++;
            if (len > mx) mx = len;
          } else {
            len = 0;
          }
        }
        if (mx >= longRun) return true;
      }
    }
    return false;
  }

  // 扫描窗口：scanBottom 上方 120px（带整体须在 scanBottom 之上）
  final lo = (scanBottom - window).clamp(0, h - 1);
  final hi = (scanBottom - 1).clamp(0, h - 1);
  final hits = <int>[];
  for (var y = lo; y <= hi; y += 2) {
    if (rulerRow(rowInk(y)) && !neighborHasLongRun(y)) {
      hits.add(y);
    }
  }
  if (hits.isEmpty) return null;
  // 相邻命中并带，取最底带（尺贴板底；窗口内多带时底带最可能是尺）
  var bandTop = hits.first, bandBottom = hits.first;
  var bestTop = hits.first, bestBottom = hits.first;
  for (final y in hits.skip(1)) {
    if (y - bandBottom <= mergeGap) {
      bandBottom = y;
    } else {
      bandTop = y;
      bandBottom = y;
    }
    if (bandBottom >= bestBottom) {
      bestTop = bandTop;
      bestBottom = bandBottom;
    }
  }
  return bestTop;
}
