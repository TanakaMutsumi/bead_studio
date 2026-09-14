import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:image/image.dart' as img;

import 'board_detect.dart';
import 'legend_detect.dart';

/// 主体检测 bbox 结果（均为图片坐标）
class SubjectBBox {
  /// 密集行/列聚簇的原始包围盒（四侧数字边剔除前，调试对拍用）
  final double rawLeft, rawTop, rawRight, rawBottom;

  /// 数字边剔除后的最终包围盒
  final double left, top, right, bottom;

  const SubjectBBox(
    this.rawLeft,
    this.rawTop,
    this.rawRight,
    this.rawBottom,
    this.left,
    this.top,
    this.right,
    this.bottom,
  );
}

/// 自动检测主体区域：排除图例带 -> 行扫描密集行聚簇（内容桥接）->
/// 带内列扫描 -> 包围盒（含主体周围一圈豆行豆列）
///
/// 主体 = 图例带上方非白像素密集的豆行豆列区（每行非白占比 >= dense）。
/// 聚簇行间的 gap 行只要有内容（nonWhite >= bridge）仍桥接——图案内
/// 的白豆行被格线打断仍残留内容，而图例与主体间的纯白隔离带不满足
/// 桥接条件被天然隔断（防把图例框进主体）。
/// [legendTop] 图例带顶（图片坐标；无图例传图高 = 整图候选）。
/// 找不到密集区返回 null（调用方提示手动框选）。
SubjectBBox? detectSubjectBBox(
  img.Image image, {
  required double legendTop,
  required double pitchX,
  required double pitchY,
}) {
  const step = 2, dense = 0.22, bridge = 0.03, maxGap = 60;
  final w = image.width, h = image.height;
  var scanBottom = math.min(h, legendTop.round());
  // 列序尺封底：图例检测失败（无图例图/漏检）时 scanBottom=图底，板底
  // 尺下方的页脚/导航条内容会泄进主体 bbox——尺顶是不依赖图例的板底
  // 硬边界（只在 scanBottom 上方 120px 窗内找，画稿区假阳性够不着；
  // 原理与阈值见 lib/core/board_detect.dart）
  final rulerTop = detectRulerTop(image, scanBottom);
  if (rulerTop != null && rulerTop < scanBottom) {
    scanBottom = rulerTop;
  }
  // 行扫描：每行非白占比（RGB>>4 量化，与图例检测同款白判定）。
  // 贴行缘的非白游程（页边框，wx1 两侧 ~290px 黑边）跳过不计——否则
  // 每行占比 0.30 起步、全页皆密集行，聚簇失效主体框成整页
  int qAt(int x, int y) {
    final p = image.getPixel(x, y);
    return ((p.r.toInt() >> 4) << 8) |
        ((p.g.toInt() >> 4) << 4) |
        (p.b.toInt() >> 4);
  }

  final rowNw = <int, double>{};
  for (var y = 0; y < scanBottom; y += step) {
    var x0 = 0;
    while (x0 < w && !qWhite(qAt(x0, y))) {
      x0++;
    }
    var x1 = w - 1;
    while (x1 > x0 && !qWhite(qAt(x1, y))) {
      x1--;
    }
    if (x0 > x1) {
      rowNw[y] = 1.0; // 整行找不到白像素：按全内容行处理
      continue;
    }
    var nw = 0;
    for (var x = x0; x <= x1; x++) {
      if (!qWhite(qAt(x, y))) {
        nw++;
      }
    }
    rowNw[y] = nw / w;
  }
  // 密集行聚簇：相邻直连；gap 行全部有内容才桥接（隔断纯白带），桥接
  // 距离上限 maxGap 防跨大空白误并；取内容量和最大的簇为主体
  final denseYs = [
    for (final e in rowNw.entries)
      if (e.value >= dense) e.key,
  ]..sort();
  if (denseYs.isEmpty) {
    return null;
  }
  final rowClusters = <List<int>>[
    [denseYs.first, denseYs.first]
  ];
  for (final y in denseYs.skip(1)) {
    var bridged = true;
    for (var gy = rowClusters.last[1] + step; gy < y; gy += step) {
      if ((rowNw[gy] ?? 0) < bridge) {
        bridged = false;
        break;
      }
    }
    if (y - rowClusters.last[1] <= 2 * step ||
        (y - rowClusters.last[1] <= maxGap && bridged)) {
      rowClusters.last[1] = y;
    } else {
      rowClusters.add([y, y]);
    }
  }
  List<int> main = rowClusters.first;
  var bestMass = -1.0;
  for (final c in rowClusters) {
    var mass = 0.0;
    for (var y = c[0]; y <= c[1]; y += step) {
      mass += rowNw[y] ?? 0;
    }
    if (mass > bestMass) {
      bestMass = mass;
      main = c;
    }
  }
  final yTop = main[0].toDouble(), yBot = main[1].toDouble();
  // 带内列扫描同法（外圈豆行豆列的左右边界）。贴图上下缘的非白整列
  // （页边框，wx1 黑边整列全高）不计：从图顶/图底向内找首个白像素，
  // 计数仅在 [yTop, yBot] 与之的交集内——否则边框列恒 1.0 密集，主体
  // 框横向撑满整页
  final colNw = <int, double>{};
  final nRows = ((yBot - yTop) / step).floor() + 1;
  for (var x = 0; x < w; x += step) {
    var y0 = 0;
    while (y0 < h && !qWhite(qAt(x, y0))) {
      y0++;
    }
    var y1 = h - 1;
    while (y1 > y0 && !qWhite(qAt(x, y1))) {
      y1--;
    }
    final lo = math.max(y0, yTop.toInt());
    final hi = math.min(y1, yBot.toInt());
    var nw = 0;
    for (var y = lo; y <= hi; y += step) {
      if (!qWhite(qAt(x, y))) {
        nw++;
      }
    }
    colNw[x] = nw / nRows;
  }
  final denseXs = [
    for (final e in colNw.entries)
      if (e.value >= dense) e.key,
  ]..sort();
  if (denseXs.isEmpty) {
    return null;
  }
  final colClusters = <List<int>>[
    [denseXs.first, denseXs.first]
  ];
  for (final x in denseXs.skip(1)) {
    var bridged = true;
    for (var gx = colClusters.last[1] + step; gx < x; gx += step) {
      if ((colNw[gx] ?? 0) < bridge) {
        bridged = false;
        break;
      }
    }
    if (x - colClusters.last[1] <= 2 * step ||
        (x - colClusters.last[1] <= maxGap && bridged)) {
      colClusters.last[1] = x;
    } else {
      colClusters.add([x, x]);
    }
  }
  List<int> mainX = colClusters.first;
  var bestMassX = -1.0;
  for (final c in colClusters) {
    var mass = 0.0;
    for (var x = c[0]; x <= c[1]; x += step) {
      mass += colNw[x] ?? 0;
    }
    if (mass > bestMassX) {
      bestMassX = mass;
      mainX = c;
    }
  }
  // 四侧行列数字边剔除：图纸主体四周常印一圈行列编号小数字，数字行与
  // 主体豆行间没有干净白行时聚簇桥接，bbox 会把数字带一并框进去。从
  // bbox 每边由外向内按半格步进检查（上限 4 带）：墨覆盖率低且彩色墨
  // 占比低的带 = 纯数字带，剔除；近乎全白（cov<0.02）= 缝隙白隙穿越
  // 继续；高覆盖或彩色的带 = 豆带，停。半格带跨界（半格数字+半格豆行
  // 边缘）墨覆盖可到 0.55-0.7，覆盖上限取 0.7——过冲 < 半格由调用方
  // 吸附格线归位（离线合成验证：贴边数字带剔后误差 <3px，无数字原图
  // 零误剪）
  final halfX = pitchX * 0.5, halfY = pitchY * 0.5;
  (double, double) bandStats(double x0, double y0, double x1, double y1) {
    var tot = 0, nw = 0, ch = 0;
    for (var y = y0.toInt(); y < y1; y += 2) {
      for (var x = x0.toInt(); x < x1; x += 2) {
        if (x < 0 || x >= w || y < 0 || y >= h) {
          continue;
        }
        final p = image.getPixel(x, y);
        final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
        tot++;
        final white = r >= 240 && g >= 240 && b >= 240;
        if (white) {
          continue;
        }
        nw++;
        final mx = math.max(r, math.max(g, b));
        final mn = math.min(r, math.min(g, b));
        if (mx - mn >= 45) {
          ch++; // 彩色墨（彩色豆带特征；灰黑印刷数字不命中）
        }
      }
    }
    final cov = tot == 0 ? 1.0 : nw / tot;
    final cf = nw == 0 ? 0.0 : ch / nw;
    return (cov, cf);
  }

  int trimBands(Rect Function(int) band) {
    var n = 0;
    for (var k = 0; k < 4; k++) {
      final r = band(k);
      final (cov, cf) = bandStats(r.left, r.top, r.right, r.bottom);
      if (cov < 0.02) {
        n++;
        continue;
      }
      if (!(cov <= 0.7 && cf <= 0.35)) {
        break;
      }
      n++;
    }
    return n;
  }

  var bxL = mainX[0].toDouble(), bxT = yTop;
  var bxR = mainX[1].toDouble(), bxB = yBot;
  var n = trimBands(
    (k) => Rect.fromLTRB(bxL + k * halfX, bxT, bxL + (k + 1) * halfX, bxB + 1),
  );
  bxL += n * halfX;
  n = trimBands(
    (k) => Rect.fromLTRB(bxL, bxT + k * halfY, bxR + 1, bxT + (k + 1) * halfY),
  );
  bxT += n * halfY;
  n = trimBands(
    (k) => Rect.fromLTRB(
      bxR + 1 - (k + 1) * halfX,
      bxT,
      bxR + 1 - k * halfX,
      bxB + 1,
    ),
  );
  bxR -= n * halfX;
  n = trimBands(
    (k) => Rect.fromLTRB(
      bxL,
      bxB + 1 - (k + 1) * halfY,
      bxR + 1,
      bxB + 1 - k * halfY,
    ),
  );
  bxB -= n * halfY;
  return SubjectBBox(
    mainX[0].toDouble(),
    yTop,
    mainX[1].toDouble(),
    yBot,
    bxL,
    bxT,
    bxR,
    bxB,
  );
}
