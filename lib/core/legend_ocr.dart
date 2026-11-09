import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'native_ocr.dart';
import 'palette.dart';

/// 图例 OCR 识别元素（色号或颗数，带几何框供跨行配对）
class OcrElem {
  final int seq;

  ///< 收集序（block/line/element 遍历序，保底配对用）
  final Rect rect;

  ///< 元素框（放大图坐标系；个别平台可能退化为 0 框）
  final int? code;

  ///< 色号 -> 调色板索引（与 count 互斥）
  int? count;

  ///< 颗数（非终值：统一括号格式下的幻影 1 剥离会改值）
  bool used = false;

  ///< 已被配对消费（数字侧）
  int? pairedCount;

  ///< 色号侧配到的颗数
  String dbgText = "";

  ///< OCR 原始文本（合并去重按其长度保完整读数、括号剥离/救援链按其
  /// contains("(") 分流——算法工作字段，非日志）
  OcrElem(this.seq, this.rect, this.code, this.count);
}

/// 检测到的图例色条（颜色识别融合用）
class LegendBar {
  final Rect rect;

  ///< 色条框（放大图坐标系）
  final int r, g, b;

  ///< 条内高饱和像素均值（黑/白文字与白底已排除）
  int? colorIdx;

  ///< 颜色最近匹配的调色板索引（超色差阈值时 null）
  OcrElem? codeElem;

  ///< 几何归属的 OCR 色号元素（印在条内/条近旁）
  OcrElem? countElem;

  ///< 几何归属的 OCR 颗数元素（条下方/右侧最近）
  LegendBar(this.rect, this.r, this.g, this.b);
}

/// OCR 常见字符混淆表（色号匹配用：印刷小字 0/O、1/I/L、2/Z、5/S、6/G、8/B、4/A 互混）
const Map<String, List<String>> ocrConfusions = {
  "0": ["O"],
  "O": ["0"],
  "1": ["I", "L"],
  "I": ["1"],
  "L": ["1"],
  "2": ["Z"],
  "Z": ["2"],
  "5": ["S"],
  "S": ["5"],
  "6": ["G"],
  "G": ["6"],
  "8": ["B"],
  "B": ["8"],
  "4": ["A"],
  "A": ["4"],
};

/// 格子 OCR 裁剪参数（encodeCellOcrPng 的 compute 入参）
class CellOcrArgs {
  final img.Image image;

  ///< 原图（isolate 内裁剪）
  final int x, y, w, h;

  ///< 裁剪区（图片坐标）
  final double scale;

  ///< 放大倍率（1.0=不缩放）
  const CellOcrArgs(this.image, this.x, this.y, this.w, this.h, this.scale);
}

/// 裁剪+缩放+PNG 编码（顶层函数供 compute isolate 调用）：喂 ML Kit 前
/// 的重活，百万像素级同步跑在主 isolate 会冻结 UI 秒级（ANR），与
/// encodeDisplayJpg 同理
Uint8List encodeCellOcrPng(CellOcrArgs a) {
  final crop = img.copyCrop(a.image, x: a.x, y: a.y, width: a.w, height: a.h);
  final out = a.scale == 1.0
      ? crop
      : img.copyResize(crop, width: (crop.width * a.scale).round());
  return img.encodePng(out);
}

/// 掉字母色号的色块采样：图例条目整条是彩色豆底块（色号/颗数直接印在彩底上），
/// 取色号框外扩窗口内高饱和像素的 RGB 均值——黑/白文字与白色底块饱和度低，
/// 天然被排除，剩下的就是豆底颜色
(int, int, int)? sampleSwatch(img.Image image, Rect codeRect) {
  final m = codeRect.height;
  final left = (codeRect.left - m).round().clamp(0, image.width - 1);
  final right = (codeRect.right + m).round().clamp(0, image.width - 1);
  final top = (codeRect.top - m * 0.6).round().clamp(0, image.height - 1);
  final bottom = (codeRect.bottom + m * 0.6).round().clamp(0, image.height - 1);
  var sr = 0, sg = 0, sb = 0, n = 0;
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      final p = image.getPixel(x, y);
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (mx - mn < 40) {
        continue; // 黑/白文字与白底低饱和，排除
      }
      sr += r;
      sg += g;
      sb += b;
      n++;
    }
  }
  if (n < 20) {
    return null; // 采样点太少（白底条目无彩底），不可信
  }
  return (sr ~/ n, sg ~/ n, sb ~/ n);
}

/// 掉字母色号按「数字后缀候选 + 条目色块颜色最近匹配」补全。
/// 返回补全的调色板索引；候选为空/色块不可采样/颜色差过远（色卡切换
/// 不对或本就不是色号）时返回 null 保守放弃
int? fixCodeBySwatch(
  BeadPalette palette,
  int bareNum,
  Rect codeRect,
  img.Image scaled,
) {
  final suffix = bareNum.toString();
  final cands = <int>[
    for (var i = 0; i < palette.colors.length; i++)
      if (palette.colors[i].id.length == suffix.length + 1 &&
          palette.colors[i].id.endsWith(suffix))
        i,
  ];
  if (cands.isEmpty) {
    return null;
  }
  final swatch = sampleSwatch(scaled, codeRect);
  if (swatch == null) {
    return null;
  }
  var best = -1;
  var bestDist = 1 << 30;
  for (final i in cands) {
    final c = palette.colors[i];
    final d = (c.r - swatch.$1) * (c.r - swatch.$1) +
        (c.g - swatch.$2) * (c.g - swatch.$2) +
        (c.b - swatch.$3) * (c.b - swatch.$3);
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  if (best < 0 || bestDist > 120 * 120 * 3) {
    return null;
  }
  return best;
}

/// 同行嵌套碎片清理：与另一元素同行且横向嵌套重叠过半的元素，是分段
/// 裁切或 ML Kit 重复子元素产出的碎片——完整读数已在表里（wx2 实测：
/// 段切把跨重叠区的 "(27)" 裁掉前缀只读出尾巴 "7)"；wx3 实测：整读
/// "D15" 之外又吐出末位 "5" 子元素，框嵌在整读框尾）。碎片留着必为祸：
/// 色块补全把它当掉字母色号、以条色最近匹配 Fabricate 出跨色系幻影条
/// 目（wx2 "7)"→R7、wx3 "5"→H5 重复条目），配对轮 1 又会抢走真颗数
/// （wx3 "5" 比 "(6)" 更贴 D15）。整只删除，保文本更长的完整版；正常
/// 布局同行的相邻元素并排不嵌套（条目间距 ≥5 字高），不会误删。单段
/// 图例不走 mergeSegmentElems，故在编排层独立调用。返回删除数。
int removeNestedFragments(List<OcrElem> elems) {
  if (elems.length < 2) {
    return 0;
  }
  var heightSum = 0.0;
  for (final e in elems) {
    heightSum += e.rect.height;
  }
  final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
  final dead = <OcrElem>{};
  for (var i = 0; i < elems.length; i++) {
    for (var j = i + 1; j < elems.length; j++) {
      final a = elems[i], b = elems[j];
      if (dead.contains(a) || dead.contains(b)) {
        continue;
      }
      if ((a.rect.center.dy - b.rect.center.dy).abs() > avgH * 0.6) {
        continue; // 不同行
      }
      final ov = math.min(a.rect.right, b.rect.right) -
          math.max(a.rect.left, b.rect.left);
      if (ov <= math.min(a.rect.width, b.rect.width) * 0.6) {
        continue; // 并排不嵌套：不同条目的元素
      }
      dead.add(a.dbgText.length >= b.dbgText.length ? b : a); // 保完整读数
    }
  }
  if (dead.isEmpty) {
    return 0;
  }
  elems.removeWhere(dead.contains);
  return dead.length;
}

/// 色块补全候选筛选（掉字母色号修复）：裸数字（无括号颗数元素）中，
/// 左侧同行 4 字高内（配对轮 1 同款窗口）或正上方 3.5 字高内（配对轮 2
/// 同款）已有色号的不是掉字母色号——它就是那条目的颗数，只是括号连同
/// 前几位被误读（"(97)"→"7)"，真颗数丢失但槽位还在）。真掉字母的色号
/// 是孤立裸数字：色号位上没有任何其它元素。窗口与配对一致是硬约束：
/// 配对够得着的颗数若被补全成色号，会把邻条目链式搅乱。
List<OcrElem> swatchCodeCandidates(List<OcrElem> elems) {
  var heightSum = 0.0;
  for (final e in elems) {
    heightSum += e.rect.height;
  }
  final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
  final codes = elems.where((e) => e.code != null).toList();
  return [
    for (final e in elems)
      if (e.code == null &&
          !e.dbgText.contains("(") &&
          !_codeNearby(e, codes, avgH))
        e,
  ];
}

/// [swatchCodeCandidates] 的色号近旁判定（与 pairLegendOcr 两轮窗口同口径）
bool _codeNearby(OcrElem e, List<OcrElem> codes, double avgH) {
  for (final c in codes) {
    // 左侧同行（配对轮 1 同款：紧邻才配，远处数字属邻条目）
    if ((c.rect.center.dy - e.rect.center.dy).abs() <= avgH * 0.7 &&
        c.rect.right < e.rect.left + avgH * 0.5 &&
        e.rect.left - c.rect.right <= avgH * 4) {
      return true;
    }
    // 正上方（配对轮 2 同款：垂直紧邻 + 水平接近）
    if (c.rect.bottom <= e.rect.top + avgH * 0.3 &&
        e.rect.top - c.rect.bottom <= avgH * 3.5 &&
        (c.rect.center.dx - e.rect.center.dx).abs() <= avgH * 1.5) {
      return true;
    }
  }
  return false;
}

/// 分段 OCR 元素合并（宽图例分段放大用）：[tagged] 为 (元素, 段序)，元素
/// rect 已换算到全放大图坐标；[segX0]/[segX1] 为各段（含重叠）在全图的
/// 起止。两步清洗：
/// 1. 标记切边嫌疑——rect 触到本段切边（非全图边缘）说明可能被切断；
///    切断侧会读出合法假值（"C3"→"3" 成假颗数、"H12"→"H1" 命中色号
///    表成幻影色号）。段间重叠 ≥ 最大元素宽时完整副本必在邻段。
/// 2. 近位置去重——同行且（中心距 < 0.9*avgH 或横向嵌套重叠 ≥ 0.6 倍
///    窄者宽）的近似对保离本段切边更远的副本（完整读数在段内深处、
///    切断读数贴边），平手保文本更长者。嵌套判定是中心距兜不住的尾巴
///    碎片专用：段切掉的常是前缀（"(27)"→"7)"），碎片中心比全读偏右
///    近一个字符位，中心距恰超 0.9*avgH 窗口（wx1 实测 96.5 vs 94.5），
///    但碎片必横躺在全读框内；之后仍存活且近旁（1.2*avgH 内）有其它
///    存活元素的嫌疑碎片判为切断残留删除，孤立的保留（宁要可能碎片
///    不要丢条目）。
List<OcrElem> mergeSegmentElems(
  List<(OcrElem, int)> tagged,
  List<double> segX0,
  List<double> segX1,
) {
  if (tagged.length <= 1 || segX0.length < 2) {
    return [for (final (e, _) in tagged) e];
  }
  final heights = [
    for (final (e, _) in tagged)
      if (e.rect.height > 0) e.rect.height,
  ];
  final avgH =
      heights.isEmpty ? 40.0 : heights.reduce((a, b) => a + b) / heights.length;
  final totalW = segX1.last;
  final suspect = List<bool>.filled(tagged.length, false);
  for (var i = 0; i < tagged.length; i++) {
    final (e, si) = tagged[i];
    suspect[i] = (segX0[si] > 1 && e.rect.left <= segX0[si] + 2) ||
        (segX1[si] < totalW - 1 && e.rect.right >= segX1[si] - 2);
  }
  double edgeDist(int i) {
    final (e, si) = tagged[i];
    return math.min(e.rect.left - segX0[si], segX1[si] - e.rect.right);
  }

  final dead = List<bool>.filled(tagged.length, false);
  for (var i = 0; i < tagged.length; i++) {
    if (dead[i]) {
      continue;
    }
    final ci = tagged[i].$1.rect.center;
    for (var j = i + 1; j < tagged.length; j++) {
      if (dead[j]) {
        continue;
      }
      final cj = tagged[j].$1.rect.center;
      if ((ci.dy - cj.dy).abs() >= avgH * 0.5) {
        continue;
      }
      final ra = tagged[i].$1.rect, rb = tagged[j].$1.rect;
      final ov = math.min(ra.right, rb.right) - math.max(ra.left, rb.left);
      final nested = ov >= 0.6 * math.min(ra.width, rb.width);
      if (!nested && (ci.dx - cj.dx).abs() >= avgH * 0.9) {
        continue;
      }
      final ei = edgeDist(i), ej = edgeDist(j);
      final keepJ = ej > ei ||
          (ej == ei &&
              tagged[j].$1.dbgText.length > tagged[i].$1.dbgText.length);
      dead[keepJ ? i : j] = true;
    }
  }
  for (var i = 0; i < tagged.length; i++) {
    if (dead[i] || !suspect[i]) {
      continue;
    }
    final ci = tagged[i].$1.rect.center;
    for (var j = 0; j < tagged.length; j++) {
      if (j == i || dead[j] || suspect[j]) {
        continue;
      }
      final cj = tagged[j].$1.rect.center;
      if ((ci.dx - cj.dx).abs() <= avgH * 1.2 &&
          (ci.dy - cj.dy).abs() <= avgH * 0.6) {
        dead[i] = true; // 切断碎片：完整副本就在近旁
        break;
      }
    }
  }
  return [
    for (var i = 0; i < tagged.length; i++)
      if (!dead[i]) tagged[i].$1,
  ];
}

/// 色号与颗数配对（两轮，几何驱动）
///
/// 轮 1：颗数与色号同行且在其右侧 -> 最近者配对（A6 64 型布局）；
/// 轮 2：未配色号找正下方紧邻数字（垂直近 + 水平接近，H2/118 型布局），
///       按色号从下往上处理——下方行的色号先消费下方数字，避免上一行
///       漏配的色号抢走下一行的颗数。
/// 几何框缺失（个别平台 rect 退化）时退回收集序「色号后第一个数字」。
List<(int, int)> pairLegendOcr(List<OcrElem> elems) {
  final codes = elems.where((e) => e.code != null).toList();
  final nums = elems.where((e) => e.count != null).toList();
  if (codes.isEmpty || nums.isEmpty) {
    return const [];
  }
  final heights = [
    for (final e in elems)
      if (e.rect.height > 0) e.rect.height,
  ];
  if (heights.isEmpty) {
    return pairInSeqOrder(codes, nums);
  }
  final avgH = heights.reduce((a, b) => a + b) / heights.length;

  // 轮 1：同行右侧最近的未消费数字
  for (final c in codes) {
    OcrElem? best;
    for (final n in nums) {
      if (n.used || n.rect.center.dx <= c.rect.center.dx) {
        continue;
      }
      if ((n.rect.center.dy - c.rect.center.dy).abs() > avgH * 0.7) {
        continue; // 不同行
      }
      if (n.rect.left - c.rect.right > avgH * 4) {
        continue; // 颗数紧邻色号；远处数字属邻条目，不抢（否则 B1 颗数
        // 漏读时会横跨抢走 H15 的颗数，H15 再抢 M3 的，链式错位尾部落空）
      }
      if (best == null || n.rect.left < best.rect.left) {
        best = n;
      }
    }
    if (best != null) {
      best.used = true;
      c.pairedCount = best.count;
    }
  }

  // 轮 2：正下方紧邻数字（从下往上的色号顺序）
  final belowFirst = [...codes]
    ..sort((a, b) => b.rect.top.compareTo(a.rect.top));
  for (final c in belowFirst) {
    if (c.pairedCount != null) {
      continue;
    }
    OcrElem? best;
    for (final n in nums) {
      if (n.used || n.rect.top <= c.rect.center.dy) {
        continue; // 必须在色号下方
      }
      // 窗口 3.5*avgH：wx1 双行图例实测颗数顶-色号中心距 ≈ 2.65*avgH，
      // 旧 2.5 窗口整行漏配（E15/G8/H2/H4/M8/M12 全 0）
      if (n.rect.top - c.rect.center.dy > avgH * 3.5) {
        continue; // 只认紧邻下方
      }
      final dx = (n.rect.center.dx - c.rect.center.dx).abs();
      // 收紧到 1.5*avgH：窗口放宽后水平约束是唯一防跨条目抢数的防线
      // （wx1 条目间距 ≈ 5*avgH，邻条颗数被此窗口挡在外面）
      if (dx > avgH * 1.5) {
        continue; // 水平接近（同列附近），不跨到邻条目
      }
      // 水平距离优先：正下方布局里水平对齐是本质特征；top 只差 OCR 框
      // 噪声几像素，若 top 优先会把邻条目的颗数抢过来（H2 抢到 H3 的 31）
      if (best == null ||
          dx < (best.rect.center.dx - c.rect.center.dx).abs() ||
          (dx == (best.rect.center.dx - c.rect.center.dx).abs() &&
              n.rect.top < best.rect.top)) {
        best = n;
      }
    }
    if (best != null) {
      best.used = true;
      c.pairedCount = best.count;
    }
  }

  // 阅读顺序输出：先上后下，同行先左后右。
  // 未配上颗数的色号也保留（颗数 0）：条目本身是真的（OCR 漏读了它的颗数），
  // 丢弃会让清单直接少一色（H15 曾因此消失）；颗数 0 用户在清单里手改即可
  final sorted = [...codes]..sort((a, b) {
      final dy = a.rect.top - b.rect.top;
      return dy.abs() > avgH * 0.7
          ? (dy > 0 ? 1 : -1)
          : a.rect.left.compareTo(b.rect.left);
    });
  return [for (final c in sorted) (c.code!, c.pairedCount ?? 0)];
}

/// 保底配对：按收集顺序「色号 -> 其后第一个数字」（几何框不可用时）
List<(int, int)> pairInSeqOrder(List<OcrElem> codes, List<OcrElem> nums) {
  final merged = [...codes, ...nums]..sort((a, b) => a.seq.compareTo(b.seq));
  final pairs = <(int, int)>[];
  int? cur;
  for (final e in merged) {
    if (e.code != null) {
      cur = e.code;
    } else if (cur != null) {
      pairs.add((cur, e.count!));
      cur = null; // 一条色号只配第一个数字，防后续串号
    }
  }
  return pairs;
}

/// 像素是否高饱和（色条实心区）：黑白文字与白底饱和度低天然排除
bool _saturatedPixel(img.Pixel p) {
  final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
  final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
  final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
  return mx - mn >= 40 && mx >= 80;
}

/// 检测图例色条：行投影切行带（竖排图例每带一条、横排一带多条，条间
/// 白底/颗数行天然是低饱和间隔），行带内再列投影切单个色条；条色取
/// 条内高饱和像素均值。返回阅读顺序（先上后下、同行先左后右）。
/// 白/黑色块无饱和度检测不出（靠融合时的孤立 OCR 色号保住这类条目）。
List<LegendBar> detectLegendBars(img.Image image) {
  final w = image.width, h = image.height;
  if (w < 12 || h < 12) {
    return const [];
  }
  final mask = List<Uint8List>.generate(h, (_) => Uint8List(w));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (_saturatedPixel(image.getPixel(x, y))) {
        mask[y][x] = 1;
      }
    }
  }
  final rowCnt = List<int>.filled(h, 0);
  for (var y = 0; y < h; y++) {
    var c = 0;
    for (var x = 0; x < w; x++) {
      c += mask[y][x];
    }
    rowCnt[y] = c;
  }
  // 行带：连续高饱和行（容忍 2 行边缘噪声缺口）
  final rowTh = math.max(3, w ~/ 16);
  final bands = <(int, int)>[];
  var top = -1;
  var gap = 0;
  for (var y = 0; y <= h; y++) {
    final on = y < h && rowCnt[y] >= rowTh;
    if (on) {
      if (top < 0) top = y;
      gap = 0;
    } else if (top >= 0 && ++gap > 2) {
      bands.add((top, y - gap));
      top = -1;
      gap = 0;
    }
  }
  if (top >= 0) {
    bands.add((top, h - 1)); // 色条顶到图边的行带（尾带不会被间隙关上）
  }
  final bars = <LegendBar>[];
  for (final (by0, by1) in bands) {
    final bh = by1 - by0 + 1;
    if (bh < 6) {
      continue; // 噪声薄带
    }
    final colCnt = List<int>.filled(w, 0);
    for (var y = by0; y <= by1; y++) {
      final row = mask[y];
      for (var x = 0; x < w; x++) {
        colCnt[x] += row[x];
      }
    }
    // 色条段：行带内连续高饱和列（列数须过行带高一半以上才是实心条）
    final colTh = math.max(2, bh * 2 ~/ 5);
    var x0 = -1;
    gap = 0;
    for (var x = 0; x <= w; x++) {
      final on = x < w && colCnt[x] >= colTh;
      if (on) {
        if (x0 < 0) x0 = x;
        gap = 0;
      } else if (x0 >= 0 && ++gap > 3) {
        _addBar(image, mask, bars, x0, x - gap, by0, by1);
        x0 = -1;
        gap = 0;
      }
    }
    if (x0 >= 0) {
      _addBar(image, mask, bars, x0, w - 1, by0, by1); // 顶到图边的色条
    }
  }
  return _mergeBarFragments(bars);
}

/// 色条碎片合并：同一色块被条内白字/白线劈开时，检测会产出一串窄碎片
///（new1：1816px 宽色块碎成 8-40px 窄条，各自成为颜色候选条目，产出
/// F20/E8/D10 型幻影重复条目）。水平相邻（间隙 ≤ 半个条高且行带重叠）
/// 或上下相邻（x 重叠过半、垂直间隙 ≤ 0.6 条高——色块被条内文字行劈成
/// 两条带）且颜色相近（RGB 欧氏距离 < 64；wx38 密排异色条 20px 间隙也
/// 不受影响）的条迭代合并，条色按面积加权平均。
List<LegendBar> _mergeBarFragments(List<LegendBar> bars) {
  if (bars.length < 2) {
    return bars;
  }
  var cur = bars;
  var changed = true;
  while (changed) {
    changed = false;
    outer:
    for (var i = 0; i < cur.length; i++) {
      for (var j = i + 1; j < cur.length; j++) {
        final a = cur[i], b = cur[j];
        final d2 = (a.r - b.r) * (a.r - b.r) +
            (a.g - b.g) * (a.g - b.g) +
            (a.b - b.b) * (a.b - b.b);
        if (d2 >= 64 * 64) {
          continue;
        }
        final yOverlap = math.min(a.rect.bottom, b.rect.bottom) -
            math.max(a.rect.top, b.rect.top);
        final gapX = math.max(a.rect.left, b.rect.left) -
            math.min(a.rect.right, b.rect.right);
        final xOverlap = math.min(a.rect.right, b.rect.right) -
            math.max(a.rect.left, b.rect.left);
        final gapY = math.max(a.rect.top, b.rect.top) -
            math.min(a.rect.bottom, b.rect.bottom);
        final minH = math.min(a.rect.height, b.rect.height);
        final horiz = gapX <= 0.5 * minH && yOverlap >= 0.6 * minH;
        final vert = gapY <= 0.6 * minH &&
            xOverlap >= 0.5 * math.min(a.rect.width, b.rect.width);
        if (!horiz && !vert) {
          continue;
        }
        final wa = a.rect.width * a.rect.height;
        final wb = b.rect.width * b.rect.height;
        final merged = LegendBar(
          a.rect.expandToInclude(b.rect),
          ((a.r * wa + b.r * wb) / (wa + wb)).round(),
          ((a.g * wa + b.g * wb) / (wa + wb)).round(),
          ((a.b * wa + b.b * wb) / (wa + wb)).round(),
        );
        cur = [
          for (var k = 0; k < cur.length; k++)
            if (k != i && k != j) cur[k],
          merged,
        ];
        changed = true;
        break outer;
      }
    }
  }
  return cur;
}

/// 色条落表：宽度过滤 + 条内高饱和像素均值作条色
void _addBar(
  img.Image image,
  List<Uint8List> mask,
  List<LegendBar> out,
  int x0,
  int x1,
  int y0,
  int y1,
) {
  if (x1 - x0 + 1 < 8) {
    return; // 过窄（噪声/边线）
  }
  var sr = 0, sg = 0, sb = 0, n = 0;
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      if (mask[y][x] == 0) {
        continue;
      }
      final p = image.getPixel(x, y);
      sr += p.r.toInt();
      sg += p.g.toInt();
      sb += p.b.toInt();
      n++;
    }
  }
  if (n < 20) {
    return; // 采样点太少不可信
  }
  out.add(
    LegendBar(
      Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1 + 1.0, y1 + 1.0),
      sr ~/ n,
      sg ~/ n,
      sb ~/ n,
    ),
  );
}

/// 融合清单的锚点（一个锚点 = 清单一条）
class _Anchor {
  final Rect rect;

  ///< 锚点位置（色条框或色号框，排序用）
  final int code;

  ///< 色号（调色板索引）
  final int count;

  ///< 颗数（无来源时 0，用户清单里手改）
  final bool ocr;

  ///< 色号来自 OCR（false = 色条颜色猜测，去重时让位 OCR 版）
  final bool lone;

  ///< 孤立色号锚点（未被任何色条认领的 OCR 色号）——只有它参与去重
  ///< 误杀邻条（wx38：已认领色号的色条锚点把邻条颜色候选整行杀光）
  _Anchor(this.rect, this.code, this.count, this.ocr, [this.lone = false]);
}

/// 色条颜色识别与 OCR 融合：[paired] 为 pairLegendOcr 的配对结果
/// （OCR 主结果，经典布局下已回归验证），融合补两类 OCR 盲区——
/// 1. OCR 整条吞掉的条目（色号印深色条内对比度差读不出，如 test_pic5
///    竖排图例）：色条量化色 -> 色卡最近色号兜底，颗数按色条几何归属
///    （条正下方/条右侧最近数字）；
/// 2. 色号读出但颗数在色条正下方、超出按字高估计的配对窗口（条高远
///    大于字高的布局）：同样按色条几何归属补颗数。
/// 锚点 = 色条 + 未落在任何色条近旁的孤立色号；OCR 读出的色号/配对
/// 颗数一律优先于颜色猜测。色条为空时原样返回 [paired]（零回归路径）。
List<(int, int)> fuseLegendBars(
  BeadPalette palette,
  List<OcrElem> elems,
  List<(int, int)> paired,
  List<LegendBar> bars,
) {
  if (bars.isEmpty) {
    return paired;
  }
  final heights = [
    for (final e in elems)
      if (e.rect.height > 0) e.rect.height,
  ];
  final avgH = heights.isEmpty
      ? bars.first.rect.height * 0.5
      : heights.reduce((a, b) => a + b) / heights.length;

  // 色号归属：中心印在条内（test_pic5 布局）或紧贴条右缘（经典布局）
  // 才归属。不能用中心-矩形距离：密集横排里下一个色块的色号离上一块
  // 的右缘比自己的更近，会链式错位
  double codeDist(OcrElem e, Rect r) {
    final c = e.rect.center;
    if (c.dx >= r.left &&
        c.dx <= r.right &&
        c.dy >= r.top &&
        c.dy <= r.bottom) {
      return 0; // 印在条内
    }
    if (c.dy >= r.top - avgH && c.dy <= r.bottom + avgH) {
      // 条右侧近旁（经典布局）：允许少量压条右缘（色号印在条缘内）
      if (e.rect.left >= r.right - r.height * 0.3) {
        return math.max(0.0, e.rect.left - r.right);
      }
      // 条左侧近旁：必须完全在条左缘外——压左缘的更可能是左邻条的
      // 右侧色号（否则密集横排里它会以更近的距离抢走邻条的归属）
      if (e.rect.right <= r.left) {
        return r.left - e.rect.right;
      }
    }
    return double.infinity;
  }

  final codeElems = elems.where((e) => e.code != null).toList();
  // 轮A：中心印在条内的色号先认领——密集横排里若条旁色号先到会挤走条内
  // 色号造成链式错位（wx1：E16 抢走 F5 的色条，F5 又挤 F7 的）
  final claimed = <OcrElem>{};
  for (final e in codeElems) {
    final c = e.rect.center;
    for (final b in bars) {
      if (b.codeElem != null) {
        continue;
      }
      if (c.dx >= b.rect.left &&
          c.dx <= b.rect.right &&
          c.dy >= b.rect.top &&
          c.dy <= b.rect.bottom) {
        b.codeElem = e;
        claimed.add(e);
        break;
      }
    }
  }
  // 轮B：其余色号按条内/条右/条左最近窗口认领剩余条
  for (final e in codeElems) {
    if (claimed.contains(e)) {
      continue;
    }
    LegendBar? best;
    var bestD = double.infinity;
    for (final b in bars) {
      if (b.codeElem != null) {
        continue;
      }
      final d = codeDist(e, b.rect);
      if (d < bestD) {
        bestD = d;
        best = b;
      }
    }
    if (best != null && bestD >= 0 && bestD <= avgH * 2.5) {
      best.codeElem = e;
    }
  }

  // 颗数归属：条正下方最近优先（条下颗数布局），条右侧兜底（同行布局，
  // 此时 pairLegendOcr 通常已配好，归属只影响未配上颗数的条目）。
  // 已配对/已消费的颗数跳过：它们的归属由配对结果决定，条几何再抢一遍
  // 会把同一颗数记进两条目（wx1：C7 的 1 被链式错位的 C8 条抢走）
  double belowCap(LegendBar bar) {
    final base = math.max(bar.rect.height, avgH) * 2.2;
    // 下邻行色条顶（只统计条高过本条一半的，防噪声残段把窗口压没）：
    // 双行图例行距 < 原窗口时，上行条会跨行抢走下行颗数（wx1：C3 抢
    // M12 的 121；new1：行距 48 < 字高 63 时旧行距守卫失效回退宽窗口，
    // 行 3 合并宽色条跨行抢走行 4 G29 的 53）。只要存在合格下邻行条顶
    // 就把窗口压到行距——本行颗数必在行距内（颗数行在下一行色条之上），
    // 压不掉合法归属
    var nextTop = double.infinity;
    for (final o in bars) {
      if (o.rect.top > bar.rect.bottom - 1 &&
          o.rect.height >= bar.rect.height * 0.5) {
        nextTop = math.min(nextTop, o.rect.top);
      }
    }
    final rowGap = nextTop - bar.rect.bottom;
    return (nextTop < double.infinity && rowGap < base) ? rowGap : base;
  }

  // 颗数行聚类（top 相差 < avgH*0.6 算同行；倾斜漂移自然分裂成多簇，
  // 「最近行」跟随漂移）。色条下方归属只认最近颗数行——下一行色块是
  // 黑/白等无饱和色检测不出条时（wx1 行 2），行界仍由颗数行本身提供
  final countTops = [
    for (final e in elems)
      if (e.count != null && e.rect.top > 0) e.rect.top,
  ]..sort();
  final rowCountTops = <double>[];
  for (final t in countTops) {
    if (rowCountTops.isEmpty || t - rowCountTops.last > avgH * 0.6) {
      rowCountTops.add(t);
    }
  }
  double? nearestCountRowTop(Rect r) {
    final threshold = r.bottom - r.height * 0.25 - avgH * 0.3;
    for (final t in rowCountTops) {
      if (t >= threshold) {
        return t;
      }
    }
    return null;
  }

  for (final e in elems) {
    if (e.count == null || e.used) {
      continue;
    }
    LegendBar? best;
    var bestD = double.infinity;
    final cx = e.rect.center.dx;
    for (final b in bars) {
      final r = b.rect;
      final rowTop = nearestCountRowTop(r);
      final below = rowTop != null &&
          (e.rect.top - rowTop).abs() <= avgH * 0.6 &&
          e.rect.top >= r.bottom - r.height * 0.25 &&
          e.rect.top - r.bottom <= belowCap(b) &&
          cx >= r.left - e.rect.width &&
          cx <= r.right + e.rect.width;
      final right = e.rect.left >= r.right - r.height * 0.3 &&
          e.rect.left - r.right <= avgH * 4 &&
          e.rect.center.dy >= r.top - avgH &&
          e.rect.center.dy <= r.bottom + avgH;
      if (below || right) {
        // 下方布局优先：右侧兜底距离加惩罚，正下方的颗数不被斜上方抢走
        final d =
            below ? e.rect.top - r.bottom : e.rect.left - r.right + avgH * 2;
        if (d < bestD) {
          bestD = d;
          best = b;
        }
      }
    }
    if (best != null) {
      best.countElem ??= e;
    }
  }

  // 条色 -> 色卡最近色号候选（超色差阈值不猜，宁缺毋滥——错色号入清单
  // 比缺一条更难被发现）。阈值与 fixCodeBySwatch 一致
  for (final b in bars) {
    var best = -1;
    var bestD = 1 << 30;
    for (var i = 0; i < palette.colors.length; i++) {
      final c = palette.colors[i];
      final d = (c.r - b.r) * (c.r - b.r) +
          (c.g - b.g) * (c.g - b.g) +
          (c.b - b.b) * (c.b - b.b);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    b.colorIdx = best >= 0 && bestD <= 120 * 120 * 3 ? best : null;
  }

  // 锚点：色条（色号 = 归属 OCR 色号 ?? 颜色候选；颗数 = OCR 配对颗数
  // ?? 条几何归属颗数）+ 未归属任何色条的孤立色号（经典配对结果原样）
  final anchors = <_Anchor>[];
  for (final b in bars) {
    final ce = b.codeElem;
    final idx = ce?.code ?? b.colorIdx;
    if (idx == null) {
      continue; // 颜色对不上色卡且 OCR 没读出色号：不可信不入清单
    }
    anchors.add(
      _Anchor(
          b.rect, idx, ce?.pairedCount ?? b.countElem?.count ?? 0, ce != null),
    );
  }
  final barElems = {for (final b in bars) b.codeElem};
  for (final e in elems) {
    if (e.code == null || barElems.contains(e)) {
      continue;
    }
    anchors.add(_Anchor(e.rect, e.code!, e.pairedCount ?? 0, true, true));
  }
  // 去重：颜色猜测的锚点与近旁孤立 OCR 锚点（条内/条右/条下没归属上的
  // 色号）是同一条目——锚点位置纵向重叠且横向近旁（右侧一个条宽内、
  // 左侧不越过 avgH）视为同条目，保 OCR 版（读出的色号权威），颜色猜
  // 测让位。两个边界都是必要的：只有右边界时，行内任何位于目标色条左
  // 侧远处的孤立色号都能杀掉它（wx38：E15 孤立色号把右侧 18 条无色号
  // 色条的颜色候选整行杀光，31 格图例只剩 5 条）；而已认领色号的色条
  // 锚点不参与去重——它的色号落在自己条内/条缘，与邻条颜色候选不在
  // 同条目，密集单行布局里邻条间距小于一个条宽，参与就是误杀
  anchors.removeWhere(
    (g) =>
        !g.ocr &&
        anchors.any(
          (o) =>
              o.lone &&
              o.rect.top < g.rect.bottom + avgH &&
              o.rect.bottom > g.rect.top - avgH &&
              o.rect.left < g.rect.right + g.rect.width &&
              o.rect.right > g.rect.left - avgH,
        ),
  );
  // 阅读顺序输出（与 pairLegendOcr 的排序口径一致）：逐行从左到右的
  // 物理位置序。锚点矩形混着两种来源——色条矩形（top 靠上）与孤立文
  // 字矩形（top 低约一个条高）——按中心 y/top 直接聚行都会把同一行劈
  // 成「条锚点在前、文字锚点殿后」两截（t4 三行竖条图例实测 A1、B13
  // 的条漏检走文字锚点被排到行尾）。有色条时改用行条带：每行条带 =
  // [本行条顶 - 容差, 本行条顶 + 条高 + 一行字高)，锚点按自身 top 落
  // 入的条带归行（条下正印的色号字落在带内；更下方的无条整行出界，
  // 出界锚点自行按中心 y 聚行排在条带行之后——wx1 行 2 无条实测）。
  // 无色条图例（纯文字）全部走中心 y 聚行（同源矩形，口径一致）
  final rowTops = <double>[];
  var barH = 0.0;
  if (bars.isNotEmpty) {
    final sortedBars = [...bars]
      ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    final heights = [
      for (final b in sortedBars) b.rect.height,
    ]..sort();
    barH = heights[heights.length ~/ 2];
    for (final b in sortedBars) {
      if (rowTops.isEmpty || b.rect.top - rowTops.last > avgH * 0.7) {
        rowTops.add(b.rect.top);
      }
    }
  }
  int? stripRow(_Anchor a) {
    for (var k = rowTops.length - 1; k >= 0; k--) {
      if (a.rect.top >= rowTops[k] - avgH * 0.7) {
        return a.rect.top < rowTops[k] + barH + avgH ? k : null;
      }
    }
    return null;
  }

  final rowKey = <_Anchor, int>{};
  if (rowTops.isNotEmpty) {
    for (final a in anchors) {
      final k = stripRow(a);
      if (k != null) {
        rowKey[a] = k;
      }
    }
    // 出界锚点（条带下方无色条的行）：按中心 y 顺序聚行，行号接在
    // 条带行之后
    final beyond = anchors.where((a) => !rowKey.containsKey(a)).toList()
      ..sort((a, b) => a.rect.center.dy.compareTo(b.rect.center.dy));
    var next = rowTops.length;
    double? lastC;
    for (final a in beyond) {
      final c = a.rect.center.dy;
      if (lastC == null || c - lastC > avgH * 0.7) {
        next++;
      }
      rowKey[a] = next;
      lastC = c;
    }
  }
  anchors.sort((a, b) {
    if (rowTops.isNotEmpty) {
      final d = (rowKey[a] ?? 0).compareTo(rowKey[b] ?? 0);
      return d != 0 ? d : a.rect.left.compareTo(b.rect.left);
    }
    final dy = a.rect.center.dy - b.rect.center.dy;
    return dy.abs() > avgH * 0.7
        ? (dy > 0 ? 1 : -1)
        : a.rect.left.compareTo(b.rect.left);
  });
  return [for (final a in anchors) (a.code, a.count)];
}

/// 全色卡「精确 + 混淆变体」查找表：variant -> 调色板索引（图例 OCR
/// 与格子 OCR 共用；变体撞车先到先得）
Map<String, int> buildCodeMap(BeadPalette palette) {
  final codeMap = <String, int>{};
  final realIds = <String>{
    for (final c in palette.colors) c.id.toUpperCase(),
  };
  for (var i = 0; i < palette.colors.length; i++) {
    final variants = <String>{};
    final id = palette.colors[i].id.toUpperCase();
    collectCodeVariants(id, 0, "", variants);
    // 零填充别名：图纸常把一位数色号印成两位（A01/B09/M07），OCR 原样
    // 读出带 0 文本直接查表 miss 整条丢弃；MARD 卡 id 无零填充（A1/H2）
    // 实测图例全零填充。仅在色卡没有同名真色号时补，不挤真键
    final m = RegExp(r'^([A-Z]+)(\d)$').firstMatch(id);
    if (m != null) {
      final padded = '${m[1]}0${m[2]}';
      if (!realIds.contains(padded)) {
        collectCodeVariants(padded, 0, "", variants);
      }
    }
    for (final v in variants) {
      codeMap[v] ??= i;
    }
  }
  return codeMap;
}

/// 递归生成色号的 OCR 混淆变体（0/O、1/I/L、2/Z、5/S、6/G、8/B、4/A）
void collectCodeVariants(String src, int i, String cur, Set<String> out) {
  if (i == src.length) {
    out.add(cur);
    return;
  }
  collectCodeVariants(src, i + 1, cur + src[i], out);
  for (final alt in ocrConfusions[src[i]] ?? const <String>[]) {
    collectCodeVariants(src, i + 1, cur + alt, out);
  }
}

/// 解析 OCR 数字文本为颗数（容忍逗号/空格/字母混淆），非法返回 null
int? parseCountText(String raw) {
  // 图例颗数常带包围符号印制（如 "A6 (64)"、全角括号、书名号等），先剥掉再解析；
  // 带括号的数字剥不掉会整条丢弃——色号找到了却配不上颗数就是这种格式
  var t = raw.trim().toUpperCase();
  t = t.replaceAll(RegExp(r"[()\[\]{}（）【】《》〈〉「」『』]"), "");
  t = t.replaceAll(",", "").replaceAll(" ", "");
  t = t
      .replaceAll("O", "0")
      .replaceAll("I", "1")
      .replaceAll("L", "1")
      .replaceAll("S", "5")
      .replaceAll("B", "8")
      .replaceAll("G", "6");
  if (!RegExp(r"^\d+$").hasMatch(t)) {
    return null;
  }
  final v = int.tryParse(t);
  return (v == null || v <= 0 || v > 100000) ? null : v;
}

/// 孤儿颗数修复：颗数（带括号，或颗数在色号正下方的布局里的裸数字）的
/// 近旁都没有色号元素，说明该条目的色号整条被 ML Kit 吞掉（深底白字/
/// 浅底浅字识别不稳定；H7 案例：(343) 读出而 H7 消失）。按布局裁空隙
/// 小区放大后单独再识别（原图 + 反色两轮）：经典布局裁颗数左侧同行空隙，
/// 颗数下布局（wx1 型）裁颗数正上方区域，读出的色号按空隙几何位置补回
/// [elems] 参与最终配对。[layout]（[inferLegendLayout] 提前探测）为右侧
/// 布局时，无括号裸数字也是孤儿候选——幻影括号剥离前 "(53)" 读成
/// "1531" 无括号可循，只有布局能判定它是颗数（new1 G29 案例）。
/// 经典布局的空隙识别按 ×2/×3/×4 构图梯子重试（×2 空手时换构图才有
/// 新信息，与 ocrGapVariants 同理；new1 H6 深底白字 ×2 整轮零元素）。
/// 返回补全数；识别到但当前色卡没有的色号（如 MARD 卡外的 H7）收集到
/// [orphanNotes] 供上层提示用户手工补。[ocrGap] 可注入替换空隙识别
///（单测用）。[tmpDirPath] 为历史参数：喂图改 fromBitmap 原始字节后不再
/// 落临时文件，仅为调用方签名兼容保留（四个 fix* 同）
/// 补读链进度回调：(已处理, 总数)——阶段文案由编排层（legend_ocr_runner
/// 的 relabel）注入，核心函数只报计数
typedef FixProgress = void Function(int done, int total);

/// 忙操作被用户终止：编排层注入的进度回调（FixProgress/onBand/onBatch
/// 等）在检查点抛出，本文件的分带/补读循环 `on BusyCancelled rethrow`
/// 放行（其余异常照旧吞成空结果），由调用方（restore_page 的识别链）
/// 捕获后清锁退出——isolate 单元无法强杀，终止=回调检查点尽快中断
class BusyCancelled implements Exception {
  const BusyCancelled();
}

/// 补读小区构图参数（[buildGapVariant] 的 compute 入参）：[gap] 为主
/// isolate 裁好的原生分辨率小区（MB 级，跨 isolate 拷贝 ~ms 级），构图
/// 重活在 isolate 内做——放大/反色/二值化/衬底逐候选数百 ms 同步块跑
/// 主 isolate 会把补读链的进度圈打成幻灯片（2026-11-09 用户反馈），与
/// encodeCellOcrPng 同理
class GapVariantArgs {
  final img.Image gap;

  ///< 原生分辨率小区
  final double zoom;

  ///< 放大倍率
  final bool smooth;

  ///< true=线性插值（平滑边）false=最近邻（锯齿边）
  final bool invert;

  ///< 反色（ocrGapVariants 构型）
  final bool binarize;

  ///< 硬二值 140（ocrGapVariants 构型，反色之后执行）
  final bool darkBar;

  ///< 深底暗字 Otsu 二值+浅色列漂白（空隙救援构型）
  final int thrBoost;

  ///< darkBar 的切点上移
  final bool adaptive;

  ///< 局部自适应二值（盲格浅字构型）
  final double padF, padAvgH;

  ///< 衬底：字高×padF×zoom 像素四周补边（0=不加）
  final bool padDark;

  ///< 衬底黑底（反色构型），否则白底
  final bool invertToo, needGray;

  ///< 附带反色副本 / 附带放大图平均灰度（深底判定）
  const GapVariantArgs(
    this.gap,
    this.zoom,
    this.smooth,
    this.invert,
    this.binarize,
    this.darkBar,
    this.thrBoost,
    this.adaptive,
    this.padF,
    this.padAvgH,
    this.padDark,
    this.invertToo,
    this.needGray,
  );
}

/// [buildGapVariant] 的出参：v=构图终图；rgba=v 的 RGBA 字节（isolate
/// 内取好，主 isolate 免一次 O(N) getBytes 大拷贝）；inverted/rgbaInverted
/// 为 v 的反色副本（ocrGapText 第二轮用，invertToo 时才有）；meanGray
/// 为放大图平均灰度（needGray 时才有，否则 -1）
class GapVariantOut {
  final img.Image v;
  final Uint8List rgba;
  final img.Image? inverted;
  final Uint8List? rgbaInverted;
  final double meanGray;
  const GapVariantOut(
    this.v,
    this.rgba,
    this.inverted,
    this.rgbaInverted,
    this.meanGray,
  );
}

/// 反色副本（RGB 逐像素反转）
img.Image _invertImage(img.Image src) {
  final inv = img.Image.from(src);
  for (final p in inv) {
    p.r = 255 - p.r;
    p.g = 255 - p.g;
    p.b = 255 - p.b;
  }
  return inv;
}

/// 补读小区构图（顶层函数供 compute isolate 调用）：放大 → 反色 → 硬
/// 二值 → 深底二值/自适应二值 → 衬底，各步骤与旧主 isolate 内联路径
/// 逐位一致（只是换线程执行），调用方按各自构型置参
GapVariantOut buildGapVariant(GapVariantArgs a) {
  var v = img.copyResize(
    a.gap,
    width: (a.gap.width * a.zoom).round(),
    interpolation:
        a.smooth ? img.Interpolation.linear : img.Interpolation.nearest,
  );
  final gray = a.needGray ? _meanGray(v) : -1.0;
  if (a.invert) {
    for (final p in v) {
      p.r = 255 - p.r;
      p.g = 255 - p.g;
      p.b = 255 - p.b;
    }
  }
  if (a.binarize) {
    for (final p in v) {
      final b = (p.r + p.g + p.b) / 3 < 140 ? 0 : 255;
      p.r = b;
      p.g = b;
      p.b = b;
    }
  }
  if (a.darkBar) {
    v = _binarizeDarkBarText(v, thrBoost: a.thrBoost);
  }
  if (a.adaptive) {
    v = _adaptiveBinarize(v);
  }
  final pad = (a.padAvgH * a.padF * a.zoom).round();
  if (pad > 0) {
    final bg = a.padDark ? 0 : 255;
    final p2 = img.Image(width: v.width + pad * 2, height: v.height + pad * 2);
    img.fill(p2, color: img.ColorRgba8(bg, bg, bg, 255));
    img.compositeImage(p2, v, dstX: pad, dstY: pad);
    v = p2;
  }
  final inverted = a.invertToo ? _invertImage(v) : null;
  return GapVariantOut(
    v,
    v.getBytes(order: img.ChannelOrder.rgba),
    inverted,
    inverted?.getBytes(order: img.ChannelOrder.rgba),
    gray,
  );
}

/// [buildGapVariant] 的 compute 包装（web 上 compute 同线程直跑，行为
/// 与旧内联一致）
Future<GapVariantOut> gapVariant(
  img.Image gap, {
  double zoom = 3,
  bool smooth = false,
  bool invert = false,
  bool binarize = false,
  bool darkBar = false,
  int thrBoost = 0,
  bool adaptive = false,
  double padF = 0,
  double padAvgH = 0,
  bool padDark = false,
  bool invertToo = false,
  bool needGray = false,
}) {
  return compute(
    buildGapVariant,
    GapVariantArgs(
      gap,
      zoom,
      smooth,
      invert,
      binarize,
      darkBar,
      thrBoost,
      adaptive,
      padF,
      padAvgH,
      padDark,
      invertToo,
      needGray,
    ),
  );
}

Future<int> fixOrphanCountCodes(
  BeadPalette palette,
  List<OcrElem> elems,
  img.Image scaled,
  Map<String, int> codeMap,
  String tmpDirPath,
  List<String> orphanNotes, {
  LegendLayout? layout,
  Future<(String, Rect)?> Function(img.Image gapBig)? ocrGap,
  List<String>? dbg,
  FixProgress? onProgress,
}) async {
  if (elems.isEmpty) {
    return 0;
  }
  var heightSum = 0.0;
  for (final e in elems) {
    heightSum += e.rect.height;
  }
  final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
  final codes = elems.where((e) => e.code != null).toList();

  // 色号近旁判定窗口与 pairLegendOcr 两轮配对一致，配得上的不是孤儿
  bool hasCodeNearby(OcrElem c) {
    for (final s in codes) {
      final dy = (s.rect.center.dy - c.rect.center.dy).abs();
      // 同行左侧窗口（配对轮 1 同款）
      if (dy <= avgH * 0.7 &&
          s.rect.right < c.rect.left + avgH * 0.5 &&
          c.rect.left - s.rect.right <= avgH * 4) {
        return true;
      }
      // 正上方窗口（配对轮 2 同款口径：颗数顶过色号中心、距 ≤3.5·avgH、
      // dx ≤1.5·avgH）。窗口必须不窄于配对窗口：否则配上对的颗数会被误判
      // 孤儿，空隙 OCR 再把真色号重读一遍产出重复锚点，把带颗数的条目挤成
      // 0（wx1：28 条重复，清单几乎整列 0）
      if (c.rect.top > s.rect.center.dy &&
          c.rect.top - s.rect.center.dy <= avgH * 3.5 &&
          (s.rect.center.dx - c.rect.center.dx).abs() <= avgH * 1.5) {
        return true;
      }
    }
    return false;
  }

  // 布局判别：颗数大多在色号正下方（wx1 型，颗数可能裸数字无括号）还是
  // 同行右侧（经典型，颗数带括号）。下方布局缺失的色号在颗数正上方，
  // 空隙裁剪方向随布局走
  var belowN = 0;
  var countTotal = 0;
  for (final c in elems) {
    if (c.count == null) {
      continue;
    }
    countTotal++;
    for (final s in codes) {
      if (s.rect.bottom <= c.rect.top + avgH * 0.3 &&
          c.rect.top - s.rect.bottom <= avgH * 3.5 &&
          (s.rect.center.dx - c.rect.center.dx).abs() <= avgH * 2) {
        belowN++;
        break;
      }
    }
  }
  final countsBelow = countTotal > 0 && belowN * 2 >= countTotal;
  // 右侧布局（layout 探测）追加裸数字孤儿：幻影括号剥离前 "(53)" 被读成
  // "1531" 无括号，靠布局判定它仍是颗数，其左侧空隙重读补回色号
  final orphans = elems
      .where(
        (e) =>
            e.code == null &&
            !hasCodeNearby(e) &&
            (e.dbgText.contains("(") ||
                countsBelow ||
                layout?.countsRight == true),
      )
      .toList();
  if (orphans.isEmpty) {
    return 0;
  }
  dbg?.add(
    "空隙OCR调试 countsBelow=$countsBelow orphans=${orphans.length}="
    "[${orphans.map((o) => o.dbgText).join(" ")}] avgH=${avgH.toStringAsFixed(1)}",
  );
  var nextSeq = 0;
  for (final e in elems) {
    if (e.seq >= nextSeq) {
      nextSeq = e.seq + 1;
    }
  }
  var fixed = 0;
  var progI = 0;
  for (final c in orphans) {
    onProgress?.call(++progI, orphans.length);
    double gLeft, gTop, gBottom, gRight;
    if (countsBelow) {
      // 颗数下布局：缺失的色号在颗数正上方 ~1.6-4 字高处，横向以颗数
      // 中心为轴（条目宽 ~10 字高内）
      final acx = c.rect.center.dx;
      gLeft = (acx - avgH * 5).clamp(0.0, scaled.width - 1.0);
      gRight = (acx + avgH * 5).clamp(gLeft + 1.0, scaled.width.toDouble());
      gTop = (c.rect.top - avgH * 4.2).clamp(0.0, scaled.height - 1.0);
      gBottom =
          (c.rect.top - avgH * 1.6).clamp(gTop + 1.0, scaled.height.toDouble());
    } else {
      // 空隙左界：左邻元素（同行、在颗数左侧、不太远）的最大右缘
      gLeft = c.rect.left - avgH * 6;
      for (final e in elems) {
        if (identical(e, c)) {
          continue;
        }
        final dy = (e.rect.center.dy - c.rect.center.dy).abs();
        if (dy > avgH * 0.8 || e.rect.right >= c.rect.left) {
          continue;
        }
        if (c.rect.left - e.rect.right > avgH * 8) {
          continue;
        }
        if (e.rect.right > gLeft) {
          gLeft = e.rect.right;
        }
      }
      if (gLeft < 0) {
        gLeft = 0;
      }
      // 右界内收半个字高：颗数元素框可能没包住被误读的前导括号弧线
      //（new1 H6 的 "(129" 印刷字形左伸到元素框外 ~1 字高，裁到元素
      // 左缘会把半个 "(" 切进构图右缘干扰识别）
      gRight = c.rect.left - avgH * 0.5;
      gTop = (c.rect.top - avgH * 0.8).clamp(0.0, scaled.height - 1.0);
      gBottom = (c.rect.bottom + avgH * 0.8)
          .clamp(gTop + 1.0, scaled.height.toDouble());
    }
    final gapW = gRight - gLeft;
    // 空隙窄于一个字高：位置上放不下色号，跳过
    if (gapW < avgH * 0.8) {
      continue;
    }
    final gap = img.copyCrop(
      scaled,
      x: gLeft.toInt(),
      y: gTop.toInt(),
      width: gapW.toInt(),
      height: (gBottom - gTop).toInt(),
    );
    // 构图梯子：经典布局 ×2 空手就换 ×3/×4（同构图重试无新信息）；
    // 注入的 ocrGap 单构图直调。放大/反色/二值化走 compute isolate
    //（gapVariant，构图与旧主 isolate 内联逐位一致）
    final zooms = countsBelow || ocrGap != null
        ? [countsBelow ? 3.0 : 2.0]
        : const [2.0, 3.0, 4.0];
    (String, Rect)? hit;
    var hitZoom = zooms.first;
    for (final z in zooms) {
      final v0 = await gapVariant(
        gap,
        zoom: z,
        invertToo: ocrGap == null,
        needGray: ocrGap == null,
      );
      hit = ocrGap != null
          ? await ocrGap(v0.v)
          : await ocrGapText(
              v0.v,
              inverted: v0.inverted,
              rgba: v0.rgba,
              rgbaInverted: v0.rgbaInverted,
            );
      if (hit == null && ocrGap == null && v0.meanGray < 130) {
        // 深底暗字第三轮（浅色列漂白+深区Otsu二值）：原图/反色 ML Kit
        // 全瞎时，小区平均灰度深说明字墨与底色同暗（new1 G29 色号印深蓝
        // 条上 Δ≈20）；白底图例（wx1 型）灰度浅不触发，行为不变
        final d3a =
            await gapVariant(gap, zoom: z, darkBar: true, invertToo: true);
        hit = await ocrGapText(
          d3a.v,
          inverted: d3a.inverted,
          rgba: d3a.rgba,
          rgbaInverted: d3a.rgbaInverted,
          onDbg: dbg == null ? null : (m) => dbg.add("深3a $m"),
        );
        // 3b 轮：切点上移 10 加肥笔画（Otsu 切点常落在字墨模的核上，
        // 笔画偏瘦 ML Kit 易碎读；上移后字/底之间仍有谷带隔着）
        if (hit == null) {
          final d3b = await gapVariant(
            gap,
            zoom: z,
            darkBar: true,
            thrBoost: 10,
            invertToo: true,
          );
          hit = await ocrGapText(
            d3b.v,
            inverted: d3b.inverted,
            rgba: d3b.rgba,
            rgbaInverted: d3b.rgbaInverted,
            onDbg: dbg == null ? null : (m) => dbg.add("深3b $m"),
          );
        }
        // 第四轮兜底（局部自适应二值化）：Otsu 双模不清（底/字灰度
        // 交叠）时按局部均值硬分
        if (hit == null) {
          final d4 =
              await gapVariant(gap, zoom: z, adaptive: true, invertToo: true);
          hit = await ocrGapText(
            d4.v,
            inverted: d4.inverted,
            rgba: d4.rgba,
            rgbaInverted: d4.rgbaInverted,
            onDbg: dbg == null ? null : (m) => dbg.add("深4 $m"),
          );
        }
      }
      hitZoom = z;
      if (hit != null) {
        break;
      }
    }
    if (hit == null) {
      dbg?.add(
        "空隙OCR未命中 \"${c.dbgText}\": 带[${gLeft.toInt()},${gRight.toInt()}]x"
        "[${gTop.toInt()},${gBottom.toInt()}]",
      );
      continue;
    }
    final (text, rel) = hit;
    // 空隙小区坐标 -> 放大图坐标（gap 又放大了 hitZoom 倍）
    final abs = Rect.fromLTWH(
      gLeft + rel.left / hitZoom,
      gTop + rel.top / hitZoom,
      rel.width / hitZoom,
      rel.height / hitZoom,
    );
    final code = codeMap[text];
    if (code != null) {
      final ne = OcrElem(nextSeq++, abs, code, null);
      ne.dbgText = "$text(空隙OCR)";
      elems.add(ne);
      fixed++;
      continue;
    }
    // 掉字母裸数字：与全图轮同一套「后缀候选 + 色块颜色」补全
    final n = parseCountText(text);
    if (n != null && n < 1000) {
      final idx = fixCodeBySwatch(palette, n, abs, scaled);
      if (idx != null) {
        final ne = OcrElem(nextSeq++, abs, idx, null);
        ne.dbgText = "$text→${palette.colors[idx].id}(空隙OCR+色块)";
        elems.add(ne);
        fixed++;
        continue;
      }
    }
    // 色号样式但色卡没有：提示用户用"添加颜色"补
    if (RegExp(r'^[A-Z]{1,2}\d{1,2}$').hasMatch(text)) {
      orphanNotes.add(text);
    }
  }
  return fixed;
}

/// 孤儿色号的颗数修复（对称于 [fixOrphanCountCodes]）：色号元素近旁既无
/// 右侧同行颗数也无正下方颗数，说明该条目的颗数整条被 ML Kit 吞掉
/// （wx1 案例：B22 的 5、C21/F7/H22 的 6 全程未读出）。裁色号下方小区
/// 放大后单独再识别（只认纯数字，防误收下一行的色号），读出的颗数按
/// 小区几何位置补回 [elems] 参与配对。返回补全数。
/// [ocrGap] 可注入替换空隙识别（单测用），默认原图+反色两轮真识别；
/// [dbg] 非空时收集调试行（排障用，正式版移除）
Future<int> fixOrphanCodeCounts(
  List<OcrElem> elems,
  img.Image scaled,
  String tmpDirPath, {
  Future<(String, Rect)?> Function(img.Image gapBig)? ocrGap,
  List<String>? dbg,
  FixProgress? onProgress,
}) async {
  if (elems.isEmpty) {
    return 0;
  }
  var heightSum = 0.0;
  for (final e in elems) {
    heightSum += e.rect.height;
  }
  final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
  final counts = elems.where((e) => e.count != null).toList();

  // 颗数近旁判定与 pairLegendOcr 两轮配对同口径：窗口内配得上的不是孤儿
  bool hasCountNearby(OcrElem s) {
    for (final c in counts) {
      // 正下方（配对轮 2 同款）
      if (c.rect.top > s.rect.center.dy &&
          c.rect.top - s.rect.center.dy <= avgH * 3.5 &&
          (s.rect.center.dx - c.rect.center.dx).abs() <= avgH * 1.5) {
        return true;
      }
      // 右侧同行（配对轮 1 同款）
      if ((c.rect.center.dy - s.rect.center.dy).abs() <= avgH * 0.7 &&
          c.rect.left >= s.rect.right &&
          c.rect.left - s.rect.right <= avgH * 4) {
        return true;
      }
    }
    return false;
  }

  final orphans =
      elems.where((e) => e.code != null && !hasCountNearby(e)).toList();
  if (orphans.isEmpty) {
    return 0;
  }
  var nextSeq = 0;
  for (final e in elems) {
    if (e.seq >= nextSeq) {
      nextSeq = e.seq + 1;
    }
  }
  // 颗数行聚类（与 fuseLegendBars 同法）：孤儿色号的颗数落在其下方最近
  // 的颗数行上。按行带裁剪而非从色号底盲裁——盲裁窗口上半是条目色块
  //（wx1 的 F7 深色块占满窗口），ML Kit 只见色块读不到数字
  final countTops = [
    for (final c in counts)
      if (c.rect.top > 0) c.rect.top,
  ]..sort();
  final rowCountTops = <double>[];
  for (final t in countTops) {
    if (rowCountTops.isEmpty || t - rowCountTops.last > avgH * 0.6) {
      rowCountTops.add(t);
    }
  }
  dbg?.add(
    "下方OCR调试 orphans=${orphans.length}=[${orphans.map((o) => o.dbgText).join(" ")}] "
    "avgH=${avgH.toStringAsFixed(1)} 行顶=${rowCountTops.map((t) => t.toStringAsFixed(0)).join("/")}",
  );
  const zoom = 3;
  var fixed = 0;
  var progI = 0;
  for (final s in orphans) {
    onProgress?.call(++progI, orphans.length);
    // 下方最近颗数行（行顶须在配对轮 2 窗口内，补回才配得上）
    double? rowTop;
    for (final t in rowCountTops) {
      if (t > s.rect.center.dy && t - s.rect.center.dy <= avgH * 3.5) {
        rowTop = t;
        break;
      }
    }
    if (rowTop == null) {
      dbg?.add("下方OCR跳过 ${s.dbgText}: 下方无颗数行");
      continue; // 下方没有颗数行（经典右侧布局/尾行）：无从裁起
    }
    // 颗数行宽带：横向以色号为中心 ±6 字高，把左右邻条目的颗数带进视野
    // 凑成「文本行」——单个 350px 大字孤立在小画布上 ML Kit 直接返回空
    //（wx1 实测 916×516 黑字白底 0 元素），多字符行 + ×3 缩放与空隙救援
    //（H7/H4，~2280×600 读出）同款口径才读得出。目标颗数靠 pickNear 按
    // 位置挑（邻条目颗数在条目间距 ≈5 字高外，窗口内不会误挑），整行粘连
    // 文本靠宽度上限剔除
    final acx = s.rect.center.dx;
    final gLeft = (acx - avgH * 6).clamp(0.0, scaled.width - 1.0);
    final gRight = (acx + avgH * 6).clamp(gLeft + 1.0, scaled.width.toDouble());
    final gTop = (rowTop - avgH * 0.3).clamp(0.0, scaled.height - 1.0);
    final gBottom =
        (rowTop + avgH * 1.4).clamp(gTop + 1.0, scaled.height.toDouble());
    final gapW = gRight - gLeft;
    if (gapW < avgH * 0.8 || gBottom - gTop < avgH) {
      continue; // 小区放不下颗数
    }
    final gap = img.copyCrop(
      scaled,
      x: gLeft.toInt(),
      y: gTop.toInt(),
      width: gapW.toInt(),
      height: (gBottom - gTop).toInt(),
    );
    // 目标颗数在小区坐标系（gap 原生分辨率）里的期望框：色号正下方
    // ±1.5 字高 × 行带；中心落框内的候选才收（框/宽度均按原生坐标给，
    // ocrGapVariants 内部按各变体的放大倍率换算）
    final pickNear = Rect.fromLTWH(
      acx - avgH * 1.5 - gLeft,
      rowTop - avgH * 0.3 - gTop,
      avgH * 3,
      avgH * 1.7,
    );
    final hit = ocrGap != null
        ? await ocrGap((await gapVariant(gap, zoom: zoom.toDouble())).v)
        : await ocrGapVariants(
            gap,
            pickNear: pickNear,
            maxElemW: avgH * 3,
            onDbg: dbg == null ? null : (m) => dbg.add(m),
          );
    if (hit == null) {
      // 字形模板匹配兜底：12 种构图 ML Kit 全失败（wx1 C21/H22 的 6），
      // 字形本身完好时按同图模板分类补回
      final m = matchCountGlyphs(
        scaled,
        counts,
        pickNear.translate(gLeft, gTop),
        onDbg: dbg == null ? null : (msg) => dbg.add(msg),
      );
      if (m != null) {
        final ne = OcrElem(nextSeq++, m.$2, null, m.$1);
        ne.dbgText = "${m.$1}(字形匹配)";
        elems.add(ne);
        fixed++;
        continue;
      }
      dbg?.add(
        "下方OCR未命中 ${s.dbgText}: 带[${gLeft.toInt()},${gRight.toInt()}]x"
        "[${gTop.toInt()},${gBottom.toInt()}]",
      );
      continue;
    }
    final n = parseCountText(hit.$1);
    if (n == null) {
      dbg?.add("下方OCR解析失败 ${s.dbgText}: \"${hit.$1}\"");
      continue;
    }
    // 小区坐标 -> 放大图坐标：注入的 ocrGap 返回 bigGap（×zoom）坐标，
    // ocrGapVariants 已换算回小区原生坐标
    final rel = hit.$2;
    final abs = ocrGap != null
        ? Rect.fromLTWH(
            gLeft + rel.left / zoom,
            gTop + rel.top / zoom,
            rel.width / zoom,
            rel.height / zoom,
          )
        : rel.translate(gLeft, gTop);
    final ne = OcrElem(nextSeq++, abs, null, n);
    ne.dbgText = "${hit.$1}(下方OCR)";
    elems.add(ne);
    fixed++;
  }
  return fixed;
}

/// 网格盲区补全：图例格式统一（同一图纸所有条目同格式）时，已读色号
/// 聚类成规则行列网格；某格「行列都在而内容完全静默」——无色号、无
/// 颗数、也无色条（白/浅色块无饱和度 + 浅字淡墨，ML Kit 全段识别整条
/// 吞掉，new1 C23：行5列1 的 C23(15) 全链路无痕）——按格位裁小区构图
/// 梯子重读补回色号。完全静默是硬条件：只有颗数的格子走空隙 OCR
/// （[fixOrphanCountCodes]）、有色条的走颜色融合，各有归属不越权；格
/// 位框与任何已读元素/色条相交也跳过——列聚类分裂出的幻影格位必与真
/// 条目元素相交，天然防误读邻条目。补回的色号进 [elems] 参与配对：
/// 下方布局的既有颗数由配对轮 2 直接接上，右侧布局的颗数由后续
/// [fixRightCountsByLayout] 按模板位补读。读出色号但色卡没有的收集进
/// [orphanNotes]。返回补全数；[ocrGap] 可注入替换识别（单测用）
Future<int> fixBlindGridCodes(
  List<OcrElem> elems,
  List<LegendBar> bars,
  img.Image scaled,
  Map<String, int> codeMap,
  String tmpDirPath,
  List<String> orphanNotes, {
  Future<(String, Rect)?> Function(img.Image gapBig)? ocrGap,
  List<String>? dbg,
  FixProgress? onProgress,
}) async {
  if (elems.isEmpty) {
    return 0;
  }
  var heightSum = 0.0;
  for (final e in elems) {
    heightSum += e.rect.height;
  }
  final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
  final codes = elems.where((e) => e.code != null).toList();
  if (codes.length < 4) {
    return 0; // 元素太少，网格无从谈起
  }
  // 行/列聚类：色号 top/left 排序后按间距切（行距/列距远大于行内抖动）
  List<List<OcrElem>> cluster(
    List<OcrElem> src,
    double Function(OcrElem) key,
    double gapTh,
  ) {
    final sorted = [...src]..sort((a, b) => key(a).compareTo(key(b)));
    final out = <List<OcrElem>>[];
    for (final e in sorted) {
      if (out.isEmpty || key(e) - key(out.last.last) > gapTh) {
        out.add([e]);
      } else {
        out.last.add(e);
      }
    }
    return out;
  }

  final rows = cluster(codes, (e) => e.rect.top, avgH * 0.7);
  final cols = cluster(codes, (e) => e.rect.left, avgH * 2);
  if (rows.length < 2 || cols.length < 2) {
    return 0; // 单行/单列图例没有「网格内空格」可言
  }
  bool overlaps(Rect a, Rect b) =>
      a.left < b.right &&
      b.left < a.right &&
      a.top < b.bottom &&
      b.top < a.bottom;

  // 静默格：格位框（列首左 -1.5 字高 .. +9 字高 × 行首顶 -1 .. +2 字高，
  // 盖住条目 色块尾+色号+颗数 的印刷区）内无任何元素/色条
  final cells = <Rect>[];
  for (final row in rows) {
    var rowTop = double.maxFinite;
    for (final e in row) {
      rowTop = math.min(rowTop, e.rect.top);
    }
    for (final col in cols) {
      var colLeft = double.maxFinite;
      for (final e in col) {
        colLeft = math.min(colLeft, e.rect.left);
      }
      final cell = Rect.fromLTRB(
        (colLeft - avgH * 1.5).clamp(0.0, scaled.width - 1.0),
        (rowTop - avgH).clamp(0.0, scaled.height - 1.0),
        (colLeft + avgH * 9).clamp(1.0, scaled.width.toDouble()),
        (rowTop + avgH * 2).clamp(1.0, scaled.height.toDouble()),
      );
      if (elems.any((e) => overlaps(e.rect, cell))) {
        continue;
      }
      if (bars.any((b) => overlaps(b.rect, cell))) {
        continue;
      }
      cells.add(cell);
    }
  }
  if (cells.isEmpty) {
    return 0;
  }
  // 探测上限：病态图例静默格可能很多，只探前 12 个（省时，也防大面积
  // 幻读——正常图例静默格是个位数）
  final probed = cells.length > 12 ? cells.sublist(0, 12) : cells;
  dbg?.add(
    "盲格OCR调试 rows=${rows.length} cols=${cols.length} "
    "静默格=${cells.length}${cells.length > probed.length ? "(探${probed.length})" : ""}="
    "[${cells.map((c) => "(${c.left.toInt()},${c.top.toInt()})").join(" ")}] "
    "avgH=${avgH.toStringAsFixed(1)}",
  );
  var nextSeq = 0;
  for (final e in elems) {
    if (e.seq >= nextSeq) {
      nextSeq = e.seq + 1;
    }
  }
  var fixed = 0;
  var progI = 0;
  for (final cell in probed) {
    onProgress?.call(++progI, probed.length);
    final gap = img.copyCrop(
      scaled,
      x: cell.left.toInt(),
      y: cell.top.toInt(),
      width: cell.width.toInt(),
      height: cell.height.toInt(),
    );
    // 构图梯子：最近邻×3（原图/反色两轮）→ 平滑×3/×4 自适应二值（浅字
    // 淡墨全段漏读的主构型——字墨灰 ~41 被最近邻放大成块状中灰，ML Kit
    // 内部二值化丢弃；局部均值二值还原干净笔画）。构图走 compute
    // isolate（gapVariant，与旧主 isolate 内联逐位一致）
    (String, Rect)? hit;
    var hitZoom = 3.0;
    if (ocrGap != null) {
      hit = await ocrGap((await gapVariant(gap, zoom: 3)).v);
    } else {
      final v1 = await gapVariant(gap, zoom: 3, invertToo: true);
      hit = await ocrGapText(
        v1.v,
        inverted: v1.inverted,
        rgba: v1.rgba,
        rgbaInverted: v1.rgbaInverted,
        onDbg: dbg == null ? null : (m) => dbg.add(m),
      );
      if (hit == null) {
        final v2 = await gapVariant(
          gap,
          zoom: 3,
          smooth: true,
          adaptive: true,
          invertToo: true,
        );
        hit = await ocrGapText(
          v2.v,
          inverted: v2.inverted,
          rgba: v2.rgba,
          rgbaInverted: v2.rgbaInverted,
        );
      }
      if (hit == null) {
        final v3 = await gapVariant(
          gap,
          zoom: 4,
          smooth: true,
          adaptive: true,
          invertToo: true,
        );
        hit = await ocrGapText(
          v3.v,
          inverted: v3.inverted,
          rgba: v3.rgba,
          rgbaInverted: v3.rgbaInverted,
        );
        hitZoom = 4.0;
      }
    }
    if (hit == null) {
      dbg?.add(
        "盲格OCR未命中 格[${cell.left.toInt()}..${cell.right.toInt()}]x"
        "[${cell.top.toInt()}..${cell.bottom.toInt()}]",
      );
      continue;
    }
    final (text, rel) = hit;
    // 小区坐标 -> 放大图坐标（注入的 ocrGap 返回 ×3 构图坐标）
    final abs = Rect.fromLTWH(
      cell.left + rel.left / hitZoom,
      cell.top + rel.top / hitZoom,
      rel.width / hitZoom,
      rel.height / hitZoom,
    );
    final code = codeMap[text];
    if (code != null) {
      final ne = OcrElem(nextSeq++, abs, code, null);
      ne.dbgText = "$text(盲格OCR)";
      elems.add(ne);
      fixed++;
      continue;
    }
    if (RegExp(r'^[A-Z]{1,2}\d{1,2}$').hasMatch(text)) {
      orphanNotes.add(text);
    }
  }
  return fixed;
}

/// 统一括号格式下的幻影括号剥离：图例格式全局一致（右侧布局带括号的
/// 图纸，颗数全部印成 "(N)"），括号弧线被 ML Kit 读成 1/I/3 等字符后经
/// 混淆表变成真数字——new1 实测 "(53)"→"1531"、"(98)"→"1983"、
/// "i261"→1261、131)"→131 全是这一类。[parens] 由多数已读颗数带括号
/// 证明（[inferLegendLayout]）。
///
/// 证据优先级（new1 实测教训："(15)" 读成 "15)" 时前导 1 是真的——
/// 弧线被漏读、真 1 与弧线字形同宽 ~17px，宽度分不出彼此）：
/// - 证据B（字形几何）独占：[scaled]/[rect] 可用且字符与连通域对得上
///   （含差一个粘连/漏读）时按 [_stripPhantomEdges] 的结构规则裁定，
///   有意见（含「保持不动」）即采纳，不再跑证据A；
/// - 证据A（文本）仅兜底：无图或图像无意见时，「对侧括号在场」仍可
///   剥（"(391" 的首弧证明尾 1 是幻影；"i98)" 同理）。
/// 真括号被正确读出的颗数（"(86)"）两侧剥离都是值中性的，不受影响。
int? stripPhantomParenCount(
  String raw, {
  required bool parens,
  img.Image? scaled,
  Rect? rect,
}) {
  var t = raw.trim().toUpperCase().replaceAll(",", "").replaceAll(" ", "");
  if (parens) {
    if (scaled != null && rect != null) {
      final e = _stripPhantomEdges(t, scaled, rect);
      if (e != null) {
        return parseCountText(e);
      }
    }
    const phantom = "1IL";
    // 证据A：对侧括号在场（无图/图像无意见的文本兜底）
    if (t.contains(")") &&
        t.isNotEmpty &&
        phantom.contains(t[0]) &&
        !t.contains("(")) {
      t = t.substring(1);
    } else if (t.contains("(") &&
        t.isNotEmpty &&
        phantom.contains(t[t.length - 1]) &&
        !t.contains(")")) {
      t = t.substring(0, t.length - 1);
    }
  }
  return parseCountText(t);
}

/// 证据B 实现（图像独占）：[t] 与 [rect] 内墨水连通域对齐（数差 ≤1），
/// 按「边缘窄字形 = 括号弧线」的结构规则剥首尾。墨水极性/阈值自适应
///（[_adaptiveInkComps]）。返回 null =
/// 无意见（字符与字形对不上，退回证据A）；返回原文 = 有意见不动。
String? _stripPhantomEdges(String t, img.Image scaled, Rect rect) {
  final n = t.length;
  if (n < 2) {
    return null;
  }
  final comps = _adaptiveInkComps(scaled, rect, n);
  final m = comps.length;
  if (m < 2 || m > n + 1 || m < n - 1) {
    return null; // 字符与字形差太多（粘连/漏读复合），几何证据失效
  }
  final widths = [for (final c in comps) c.width];
  final maxW = widths.reduce(math.max);
  final wide = [
    for (final w in widths)
      if (w >= maxW * 0.55) w
  ];
  // 一对数字粘连成一个连通域（m==n-1）时宽类基准失真，按最宽的一半估
  final digitW = m == n - 1 ? maxW / 2 : _median(wide);
  if (digitW <= 0) {
    return null;
  }
  final thr = digitW * 0.7;
  if (m == n + 1) {
    const parenCh = "()[]";
    // 括号字符在文本边缘 = 该侧弧线已读出：漏掉的字形无从定位，不动
    //（parseCountText 自会剥括号，new1 E2 "18)"→18）
    if (parenCh.contains(t[0]) || parenCh.contains(t[n - 1])) {
      return t;
    }
    // 其余唯一合理解释：某个边缘弧线窄字形未被读出（m==n+1）。丢弃后
    // 剩余字符须各得其所——括号/幻影类字符可坐窄弧线，其余数字字符须
    // 坐宽字形。两端各试一次，恰有一侧可行才采纳（双侧可行=歧义不剥）
    List<Rect>? kept;
    for (final dropLeft in [true, false]) {
      final drop = dropLeft ? comps.first : comps.last;
      if (drop.width >= thr) {
        continue;
      }
      final rest = dropLeft ? comps.sublist(1) : comps.sublist(0, m - 1);
      var ok = true;
      for (var i = 0; i < n; i++) {
        final narrow = rest[i].width < thr;
        final ch = t[i];
        if (narrow == parenCh.contains(ch) || narrow == phantom1(ch)) {
          continue;
        }
        if (!narrow && !parenCh.contains(ch)) {
          continue; // 数字字符坐宽字形
        }
        ok = false;
        break;
      }
      if (ok && kept == null) {
        kept = rest;
      } else if (ok) {
        kept = null; // 双侧都行：歧义，宁可不剥
        break;
      }
    }
    if (kept == null) {
      return null;
    }
    return _stripAlignedEdges(t, kept, thr);
  }
  // 危险对称复核：m==n 且双侧窄、恰一侧边缘字符是括号（该侧弧线已读出）、
  // 另一侧是幻影类 = 对称剥离可能杀真字符的构型（E2 实拍 "(18)" 的 '('
  // 印在元素框外左侧，框内读出 "18)" 双侧窄，旧规则对称剥成 8）。左右各
  // 外扩 0.8 字高重数：恰 n+1 域且有域落在原框外 = 藏匿弧线确实在场，
  // 保持原文（parseCountText 自会剥括号）；复核不成立才走对称剥离
  //（"(31"→3、G15 "I218)"→218 依旧——它们的幻影字符在框内，框外无弧线）
  if (m == n && n > 2 && comps.first.width < thr && comps.last.width < thr) {
    const parenCh = "()[]";
    final lParen = parenCh.contains(t[0]), rParen = parenCh.contains(t[n - 1]);
    if (lParen != rParen && (lParen ? phantom1(t[n - 1]) : phantom1(t[0]))) {
      final pad = rect.height * 0.8;
      final padded = Rect.fromLTRB(
        (rect.left - pad).clamp(0.0, scaled.width - 1.0),
        rect.top,
        (rect.right + pad).clamp(1.0, scaled.width.toDouble()),
        rect.bottom,
      );
      final pc = _adaptiveInkComps(scaled, padded, n + 1);
      if (pc.length == n + 1 &&
          (pc.first.right <= rect.left + 2 || pc.last.left >= rect.right - 2)) {
        return t;
      }
    }
  }
  return _stripAlignedEdges(t, comps, thr);
}

/// 幻影类字符（弧线被读成 1/I/L）
bool phantom1(String ch) => "1IL".contains(ch);

/// 对齐后的首尾剥离决策：双侧边缘窄 = 括号弧线对都在场，首尾字符
///（无论被读成什么）都是弧线，剥两端（"(53)"→"1531"、"(98)"→"1983"、
/// G29 "(53)" 粘连版→"1531"）。仅单侧窄时宽度无法分辨真 1 与弧线
///（new1 实测两者同宽 16-24px）：只有对侧括号字符已读出、且窄侧字符
/// 是幻影类才剥（"(31"→3）；"15)" 型（尾括号已读出、首 1 无旁证）保持
/// 原文，交给 parseCountText。
String _stripAlignedEdges(String t, List<Rect> comps, double thr) {
  final n = t.length;
  final narrowL = comps.first.width < thr;
  final narrowR = comps.last.width < thr;
  const parenCh = "()[]";
  if (narrowL && narrowR) {
    return n > 2 ? t.substring(1, n - 1) : t;
  }
  if (narrowR && parenCh.contains(t[n - 1])) {
    return t;
  }
  if (narrowL && parenCh.contains(t[0])) {
    return phantom1(t[n - 1]) ? t.substring(0, n - 1) : t;
  }
  return t;
}

/// [stripPhantomParenCount] 的全表应用：剥离改变了值的颗数就地改写并
/// 标注 dbgText（日志可追溯）。返回改写数。
int applyPhantomParenStrip(
  List<OcrElem> elems,
  bool parens,
  img.Image scaled,
) {
  if (!parens) {
    return 0;
  }
  var n = 0;
  for (final e in elems) {
    if (e.count == null) {
      continue;
    }
    final fixed = stripPhantomParenCount(
      e.dbgText,
      parens: true,
      scaled: scaled,
      rect: e.rect,
    );
    if (fixed != null && fixed != e.count) {
      e.dbgText = "${e.dbgText}→$fixed(括号剥离)";
      e.count = fixed;
      n++;
    }
  }
  return n;
}

/// 图例统一布局（图纸图例所有条目格式一致）：由已读元素推断颗数在色号
/// 右侧同行还是正下方，及模板距离/是否带括号——缺失颗数的条目按模板
/// 位置补读（[fixRightCountsByLayout]），不再靠盲裁。
class LegendLayout {
  final bool countsRight;

  ///< true=颗数在色号右侧同行；false=颗数在色号正下方
  final double dx;

  ///< 右侧布局：颗数中心-色号中心的水平中位距
  final bool parens;

  ///< 颗数带括号（多数已读颗数的 raw 含括号）
  const LegendLayout(this.countsRight, this.dx, this.parens);
}

/// 布局探测：每个色号按配对同款窗口找右侧同行颗数/正下方颗数，多数
/// 票定方向（≥2 票且压倒对方）。右侧布局额外统计括号占比（过半为真）。
LegendLayout? inferLegendLayout(List<OcrElem> elems) {
  if (elems.isEmpty) {
    return null;
  }
  var heightSum = 0.0;
  for (final e in elems) {
    heightSum += e.rect.height;
  }
  final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
  final codes = elems.where((e) => e.code != null).toList();
  final counts = elems.where((e) => e.count != null).toList();
  if (codes.length < 2 || counts.isEmpty) {
    return null;
  }
  var rightVotes = 0, belowVotes = 0, parenVotes = 0;
  final rDx = <double>[];
  for (final c in codes) {
    for (final n in counts) {
      final dy = (n.rect.center.dy - c.rect.center.dy).abs();
      if (dy <= avgH * 0.7 &&
          n.rect.left >= c.rect.right - avgH * 0.2 &&
          n.rect.left - c.rect.right <= avgH * 6) {
        rightVotes++;
        rDx.add(n.rect.center.dx - c.rect.center.dx);
        if (n.dbgText.contains("(") || n.dbgText.contains(")")) {
          parenVotes++;
        }
        break;
      }
    }
    for (final n in counts) {
      if (n.rect.top > c.rect.bottom - avgH * 0.3 &&
          n.rect.top - c.rect.bottom <= avgH * 3.5 &&
          (n.rect.center.dx - c.rect.center.dx).abs() <= avgH * 1.5) {
        belowVotes++;
        break;
      }
    }
  }
  final right = rightVotes >= 2 && rightVotes > belowVotes;
  final below = belowVotes >= 2 && belowVotes > rightVotes;
  if (!right && !below) {
    return null;
  }
  return LegendLayout(
    right,
    right ? _median(rDx) : 0.0,
    right && parenVotes * 2 >= rightVotes,
  );
}

/// 右侧布局缺颗数补读（[inferLegendLayout] 后，对称于 [fixOrphanCodeCounts]
/// 的下方重读）：色号近旁两窗口（右侧同行/正下方）均无颗数 = 该条目颗数
/// 被 ML Kit 整条吞掉，按模板距离裁色号右侧小区（code.right+dx·[0.15,1.6]
/// × 行带）多变体重读，命中按位置框补回 [elems]。[ocrGap] 可注入替换
///（单测用），默认 [ocrGapVariants]。返回补全数。
Future<int> fixRightCountsByLayout(
  List<OcrElem> elems,
  img.Image scaled,
  String tmpDirPath,
  LegendLayout layout, {
  Future<(String, Rect)?> Function(img.Image gapBig)? ocrGap,
  List<String>? dbg,
  FixProgress? onProgress,
}) async {
  if (elems.isEmpty) {
    return 0;
  }
  var heightSum = 0.0;
  for (final e in elems) {
    heightSum += e.rect.height;
  }
  final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
  final counts = elems.where((e) => e.count != null).toList();

  // 缺颗数色号：右侧同行与正下方两窗口（不窄于配对窗口）均空
  final orphans = <OcrElem>[];
  for (final s in elems.where((e) => e.code != null)) {
    var has = false;
    for (final c in counts) {
      final dy = (c.rect.center.dy - s.rect.center.dy).abs();
      if (dy <= avgH * 0.7 &&
          c.rect.left >= s.rect.right - avgH * 0.2 &&
          c.rect.left - s.rect.right <= avgH * 6) {
        has = true;
        break;
      }
      if (c.rect.top > s.rect.center.dy &&
          c.rect.top - s.rect.center.dy <= avgH * 3.5 &&
          (c.rect.center.dx - s.rect.center.dx).abs() <= avgH * 1.5) {
        has = true;
        break;
      }
    }
    if (!has) {
      orphans.add(s);
    }
  }
  if (orphans.isEmpty) {
    return 0;
  }
  dbg?.add(
    "右侧OCR调试 orphans=${orphans.length}=[${orphans.map((o) => o.dbgText).join(" ")}] "
    "dx=${layout.dx.toStringAsFixed(0)} avgH=${avgH.toStringAsFixed(1)}",
  );
  var nextSeq = 0;
  for (final e in elems) {
    if (e.seq >= nextSeq) {
      nextSeq = e.seq + 1;
    }
  }
  const zoom = 3;
  var fixed = 0;
  var progI = 0;
  for (final s in orphans) {
    onProgress?.call(++progI, orphans.length);
    final gLeft =
        (s.rect.right + layout.dx * 0.15).clamp(0.0, scaled.width - 1.0);
    final gRight = (s.rect.right + layout.dx * 1.6)
        .clamp(gLeft + 1.0, scaled.width.toDouble());
    final gTop = (s.rect.top - avgH * 0.35).clamp(0.0, scaled.height - 1.0);
    final gBottom = (s.rect.bottom + avgH * 0.35)
        .clamp(gTop + 1.0, scaled.height.toDouble());
    if (gBottom - gTop < avgH * 0.8 || gRight - gLeft < avgH * 0.8) {
      continue; // 小区放不下颗数
    }
    final gap = img.copyCrop(
      scaled,
      x: gLeft.toInt(),
      y: gTop.toInt(),
      width: (gRight - gLeft).toInt(),
      height: (gBottom - gTop).toInt(),
    );
    // 期望颗数位（小区原生坐标）：模板距离处 ±1.5 字高 × 行带
    final expCx = s.rect.center.dx + layout.dx - gLeft;
    final pickNear = Rect.fromLTWH(
      (expCx - avgH * 1.5).clamp(0.0, gap.width - 1.0),
      0,
      avgH * 3,
      gap.height.toDouble(),
    );
    final hit = ocrGap != null
        ? await ocrGap((await gapVariant(gap, zoom: zoom.toDouble())).v)
        : await ocrGapVariants(
            gap,
            pickNear: pickNear,
            maxElemW: avgH * 3,
            onDbg: dbg == null ? null : (m) => dbg.add(m),
          );
    if (hit == null) {
      dbg?.add(
        "右侧OCR未命中 ${s.dbgText}: 带[${gLeft.toInt()},${gRight.toInt()}]x"
        "[${gTop.toInt()},${gBottom.toInt()}]",
      );
      continue;
    }
    // 小区坐标 -> 放大图坐标：注入的 ocrGap 返回 bigGap（×zoom）坐标，
    // ocrGapVariants 已换算回小区原生坐标
    final rel = hit.$2;
    final abs = ocrGap != null
        ? Rect.fromLTWH(
            gLeft + rel.left / zoom,
            gTop + rel.top / zoom,
            rel.width / zoom,
            rel.height / zoom,
          )
        : rel.translate(gLeft, gTop);
    final n = stripPhantomParenCount(
      hit.$1,
      parens: layout.parens,
      scaled: scaled,
      rect: abs,
    );
    if (n == null) {
      dbg?.add("右侧OCR解析失败 ${s.dbgText}: \"${hit.$1}\"");
      continue;
    }
    final ne = OcrElem(nextSeq++, abs, null, n);
    ne.dbgText = "${hit.$1}(右侧OCR)";
    elems.add(ne);
    fixed++;
  }
  return fixed;
}

/// 颗数带多变体识别（[fixOrphanCodeCounts] 默认路径）：同一带裁剪用
/// 原图/反色/二值化 × ×3/×4 多种构图分别喂 ML Kit，首个 pickNear 命中
/// 即返回。ML Kit 对孤立数字行的输出随构图漂移（wx1 实测：同一个 6 在
/// ×3 带裁剪读出、全段识别里漏读；另一条带连邻条目数字都不返回），
/// 同构图重试无新信息，换构图才有。返回 (文本, 小区原生坐标框)。
Future<(String, Rect)?> ocrGapVariants(
  img.Image gap, {
  required Rect pickNear,
  required double maxElemW,
  void Function(String)? onDbg,
}) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    // (预处理, 放大倍率, 插值0最近邻/1平滑, 衬底=按字高加白/黑边)：
    // 0=原图 1=反色 2=二值化 3=二值化反色。最近邻×3 原图/反色是 B22/F7
    // 的实证命中构型排最前；顽固条目（wx1 C21/H22：同一数字换 6 种构图
    // 仍漏/整带零元素）靠平滑插值（最近邻×3 锯齿边→平滑边）、衬底
    // （文字贴裁剪边被丢）、不同倍率继续换构图攻
    const variants = <(int, int, int, double)>[
      (0, 3, 0, 0.0),
      (1, 3, 0, 0.0),
      (0, 3, 1, 0.5),
      (1, 3, 1, 0.5),
      (0, 4, 0, 0.0),
      (2, 3, 0, 0.0),
      (0, 2, 1, 0.0),
      (1, 2, 1, 0.0),
      (0, 6, 1, 0.0),
      (1, 4, 1, 0.5),
      (2, 4, 1, 0.5),
      (3, 3, 1, 0.0),
    ];
    final avgH = maxElemW / 3;
    for (final (mode, z, smooth, padF) in variants) {
      // 构图（放大/反色/二值/衬底）走 compute isolate——主 isolate 内联
      // 逐构型数百 ms 同步像素块把进度圈打成幻灯片，与补读链其余环节
      // 同批修（gapVariant 构图与旧内联逐位一致）
      final out = await gapVariant(
        gap,
        zoom: z.toDouble(),
        smooth: smooth == 1,
        invert: mode == 1 || mode == 3,
        binarize: mode == 2 || mode == 3,
        padF: padF,
        padAvgH: avgH,
        padDark: mode == 1 || mode == 3,
      );
      final v = out.v;
      // 衬底像素宽（isolate 内已加衬，坐标换算还要用同值还原偏移）
      final pad = (avgH * padF * z).round();
      final els = await ocrRgba(v, rgba: out.rgba) ??
          await ocrRgbaPlugin(recognizer, v);
      final texts = <String>[];
      final cands = <String>[]; // 【临时调试】全部数字样式候选@原生中心
      (String, Rect)? best;
      var bestD = double.infinity;
      for (final element in els) {
        // 连字符剥除：代码印成 "G-29" 型（new1 G29），色号字符集不含
        // 连字符，带着它 codeLike/数字样式全失配
        final text = element.text
            .trim()
            .toUpperCase()
            .replaceAll(" ", "")
            .replaceAll("-", "");
        texts.add(text);
        // 候选先剥包围符再校验：带括号颗数 "(198)" 若按原文匹配
        //（括号不在数字形近字符类里）整类候选被拒——右侧布局补读
        // 会整轮空手（new1 的 (198)/(15) 全在此路径）
        final bare = text.replaceAll(
          RegExp(r"[()\[\]{}（）【】《》〈〉「」『』]"),
          "",
        );
        if (bare.length > 4 ||
            !RegExp(r'^[\dOSBGIL]{1,4}$').hasMatch(bare) ||
            parseCountText(bare) == null) {
          continue;
        }
        // 变体坐标（含衬底偏移）-> 小区原生坐标
        final bb = element.rect;
        final native = Rect.fromLTWH(
          bb.left / z - pad / z,
          bb.top / z - pad / z,
          bb.width / z,
          bb.height / z,
        );
        cands.add(
          "$text@${native.center.dx.toInt()},${native.center.dy.toInt()}"
          "w${native.width.toInt()}",
        );
        if (native.width > maxElemW) {
          continue; // 整行粘连文本
        }
        if (!pickNear.contains(native.center)) {
          continue;
        }
        final d = (native.center - pickNear.center).distance;
        if (d < bestD) {
          bestD = d;
          best = (text, native);
        }
      }
      onDbg?.call(
        "带OCR变体$mode×$z${smooth == 1 ? "滑" : ""}${padF > 0 ? "衬" : ""} "
        "文本=[${texts.join("|")}] 候选=[${cands.join("|")}] 命中=${best?.$1 ?? "无"}",
      );
      if (best != null) {
        return best;
      }
    }
  } finally {
    await recognizer.close();
  }
  return null;
}

/// [box] 内墨水连通域（8 连通，面积 >30px），按 x 排序。默认深墨
/// （灰度 < [thr]=140，黑字白底）；[brightInk] 取亮墨（白字深底）。
/// 字形切分与模板/目标两侧共用
List<Rect> _inkComponents(
  img.Image image,
  Rect box, {
  double thr = 140,
  bool brightInk = false,
}) {
  final x0 = box.left.round().clamp(0, image.width - 1);
  final y0 = box.top.round().clamp(0, image.height - 1);
  final x1 = box.right.round().clamp(x0 + 1, image.width);
  final y1 = box.bottom.round().clamp(y0 + 1, image.height);
  final w = x1 - x0, h = y1 - y0;
  if (w <= 0 || h <= 0) {
    return const [];
  }
  final ink = List<bool>.filled(w * h, false);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x0 + x, y0 + y);
      final g = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      if (brightInk ? g > thr : g < thr) {
        ink[y * w + x] = true;
      }
    }
  }
  final seen = List<bool>.filled(w * h, false);
  final out = <Rect>[];
  final stack = <int>[];
  for (var sy = 0; sy < h; sy++) {
    for (var sx = 0; sx < w; sx++) {
      final start = sy * w + sx;
      if (!ink[start] || seen[start]) {
        continue;
      }
      seen[start] = true;
      stack.add(start);
      var n = 0;
      var minX = sx, maxX = sx, minY = sy, maxY = sy;
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        final cx = cur % w, cy = cur ~/ w;
        n++;
        if (cx < minX) minX = cx;
        if (cx > maxX) maxX = cx;
        if (cy < minY) minY = cy;
        if (cy > maxY) maxY = cy;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = cx + dx, ny = cy + dy;
            if (nx < 0 ||
                nx >= w ||
                ny < 0 ||
                ny >= h ||
                (dx == 0 && dy == 0)) {
              continue;
            }
            final idx = ny * w + nx;
            if (ink[idx] && !seen[idx]) {
              seen[idx] = true;
              stack.add(idx);
            }
          }
        }
      }
      if (n > 30) {
        out.add(Rect.fromLTWH(
          (x0 + minX).toDouble(),
          (y0 + minY).toDouble(),
          (maxX - minX + 1).toDouble(),
          (maxY - minY + 1).toDouble(),
        ));
      }
    }
  }
  out.sort((a, b) => a.left.compareTo(b.left));
  return out;
}

/// Otsu 阈值：[hist] 为盒内灰度直方图（[total] 像素总数），类间方差
/// 最大的分割点。空图返回 140（调用方按无墨处理）
int _otsuThreshold(List<int> hist, int total) {
  if (total <= 0) {
    return 140;
  }
  var sumAll = 0.0;
  for (var t = 0; t < 256; t++) {
    sumAll += t * hist[t];
  }
  var sumB = 0.0, wB = 0, bestV = -1.0, thr = 140;
  for (var t = 0; t < 255; t++) {
    wB += hist[t];
    if (wB == 0) {
      continue;
    }
    final wF = total - wB;
    if (wF == 0) {
      break;
    }
    sumB += t * hist[t];
    final mB = sumB / wB;
    final mF = (sumAll - sumB) / wF;
    final v = wB * wF * (mB - mF) * (mB - mF);
    if (v > bestV) {
      bestV = v;
      thr = t;
    }
  }
  return thr;
}

/// [box] 内墨水连通域（极性/阈值自适应）：Otsu 与固定 140 × 深墨/亮墨
/// 四种配置各取连通域（矮屑过滤后），取「连通域数最接近 [nChars]」的
/// 配置，平手取连通域多的。图例颗数既有白字深底（固定 140 干净、Otsu
/// 反而粘连——new1 H5 的 "98" 在 Otsu 下糊成 3 域），也有暗字暗底
/// （对比度 Δ≈35，只有 Otsu 分得开——new1 B22/G29 印深色条上），单一
/// 判据必挂一边
List<Rect> _adaptiveInkComps(
  img.Image image,
  Rect box,
  int nChars, {
  void Function(String)? onDbg,
  List<(double, bool)>? cfgsOverride,
}) {
  final x0 = box.left.round().clamp(0, image.width - 1);
  final y0 = box.top.round().clamp(0, image.height - 1);
  final x1 = box.right.round().clamp(x0 + 1, image.width);
  final y1 = box.bottom.round().clamp(y0 + 1, image.height);
  final w = x1 - x0, h = y1 - y0;
  if (w <= 0 || h <= 0) {
    return const [];
  }
  final hist = List<int>.filled(256, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x0 + x, y0 + y);
      hist[(0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255)]++;
    }
  }
  final otsu = _otsuThreshold(hist, w * h).toDouble();
  List<Rect>? best;
  // Otsu 语义是「≤t 为暗类」，_inkComponents 用严格 <／>：暗墨取
  // t+0.5、亮墨取 t-0.5 才把切点放回两类之间（两类灰度的 Otsu 平台上
  // 首个最大点恰为暗模值本身，严格不等号会把整类墨水切掉）。
  // [cfgs] 仅供排障探针覆盖阈值组合（正式路径走默认四配置）
  final cfgs = cfgsOverride ??
      [
        (otsu + 0.5, false),
        (otsu - 0.5, true),
        (140.0, false),
        (140.0, true),
      ];
  for (final (thr, bright) in cfgs) {
    var cs = _inkComponents(image, box, thr: thr, brightInk: bright);
    // 整片背景过滤：bbox 占盒面积七成以上的连通域是底色/色条本身成墨
    //（new1 H5 深条在暗配置下 175x80 盖满整盒，旧版它当「最左字形」
    // 参与决策产出 1983）
    cs = [
      for (final c in cs)
        if (c.width * c.height <= w * h * 0.7) c,
    ];
    if (cs.length >= 2) {
      // 矮屑过滤按最高连通域 0.6 倍：中位数会被大量屑拉低（H5 暗配置下
      // 条屑高 8-16px 把中位压到 8，旧 0.45×中位过滤形同虚设）；真字形
      // 高度均匀（实测同盒内 48-64px，比值 ≥0.75），0.6 倍于最高者只杀屑
      final maxH = [for (final c in cs) c.height].reduce(math.max);
      cs = [
        for (final c in cs)
          if (c.height >= maxH * 0.6) c
      ];
    }
    onDbg?.call(
      "${bright ? "亮" : "暗"}${thr.toStringAsFixed(0)}: "
      "${cs.length}域[${cs.map((c) => "${c.width.toInt()}x${c.height.toInt()}@${c.left.toInt()}").join(" ")}]",
    );
    if (cs.isEmpty) {
      continue;
    }
    // 配置有效性：幸存最高字形不足盒高 0.35 倍 = 全是屑（背景过滤后只剩
    // 噪声的配置不参与竞选，否则数凑巧时屑团会赢）
    if ([for (final c in cs) c.height].reduce(math.max) < h * 0.35) {
      continue;
    }
    final dNew = (cs.length - nChars).abs();
    final dOld = best == null ? null : (best.length - nChars).abs();
    if (best == null ||
        dNew < dOld! ||
        (dNew == dOld && cs.length > best.length)) {
      best = cs;
    }
  }
  return best ?? const [];
}

/// 局部自适应二值化（积分图局部均值 - 12）：深底暗字（对比度 Δ≈30，
/// new1 G29 色号印深蓝条上）全局阈值不可分——小区混着左邻白底时 Otsu
/// 被拉爆、固定 140 整片全墨；按局部均值分墨后黑白分明 ML Kit 才读得出。
/// 返回同尺寸二值图
img.Image _adaptiveBinarize(img.Image g) {
  final w = g.width, h = g.height;
  final gray = List<int>.filled(w * h, 0);
  final integral = List<int>.filled((w + 1) * (h + 1), 0);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++, i++) {
      final p = g.getPixel(x, y);
      final v = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
      gray[i] = v;
      integral[(y + 1) * (w + 1) + (x + 1)] = v +
          integral[y * (w + 1) + (x + 1)] +
          integral[(y + 1) * (w + 1) + x] -
          integral[y * (w + 1) + x];
    }
  }
  final half = (math.min(w, h) ~/ 4).clamp(7, 30);
  final out = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    final ty0 = math.max(0, y - half), ty1 = math.min(h - 1, y + half);
    for (var x = 0; x < w; x++) {
      final tx0 = math.max(0, x - half), tx1 = math.min(w - 1, x + half);
      final sum = integral[(ty1 + 1) * (w + 1) + (tx1 + 1)] -
          integral[ty0 * (w + 1) + (tx1 + 1)] -
          integral[(ty1 + 1) * (w + 1) + (tx0)] +
          integral[ty0 * (w + 1) + (tx0)];
      final mean = sum / ((tx1 - tx0 + 1) * (ty1 - ty0 + 1));
      final v = gray[y * w + x] < mean - 12 ? 0 : 255;
      out.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  return out;
}

/// 深底暗字小区的二值分离（空隙救援第三轮预处理）：浅色边带是三类
/// 统计的毒药——局部均值二值化在白底/深条过渡带产出整高黑竖条、全局
/// Otsu/线性拉伸被白色主导（new1 G29 实拍：字 55 vs 深条 72，Δ≈20，
/// 原图/反色/局部二值化 ML Kit 全未命中，二值化产物字形碎裂还带两根
/// 满高黑条，分位拉伸又把条底噪声放大成墨）。列均值 >160 的浅色列
/// 整列漂白（不裁剪——裁剪会平移坐标，空隙救援的元素框按原图坐标
/// 换算；漂白列还顺带当 ML Kit 衬底），再在深色列上按 Otsu 二值：
/// 字墨→0、条底→255。深色占比不足/阈值贴底/墨水占深色过半（纯条
/// 无字，切点劈在条底模内）时原样返回不硬分
img.Image _binarizeDarkBarText(img.Image g, {int thrBoost = 0}) {
  if (g.width < 4 || g.height < 4) {
    return g;
  }
  final colSum = List<int>.filled(g.width, 0);
  for (var y = 0; y < g.height; y++) {
    for (var x = 0; x < g.width; x++) {
      final p = g.getPixel(x, y);
      colSum[x] += (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
    }
  }
  final lightCol = 160.0 * g.height;
  final isLight = [
    for (var x = 0; x < g.width; x++) colSum[x] > lightCol,
  ];
  // 直方图只统计深色列像素（<160）：漂白列参与统计会把 Otsu 拉到
  // 白/非白切点，整条深底成墨
  final hist = List<int>.filled(256, 0);
  var dark = 0;
  for (var y = 0; y < g.height; y++) {
    for (var x = 0; x < g.width; x++) {
      if (isLight[x]) {
        continue;
      }
      final p = g.getPixel(x, y);
      final v = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      if (v < 160) {
        hist[v]++;
        dark++;
      }
    }
  }
  // 深色占比不足深色区三成：不是深底构型，无从分离
  final darkArea = g.height * (isLight.where((l) => !l).length);
  if (darkArea <= 0 || dark < darkArea * 0.3) {
    return g;
  }
  final thr = math.min(159, _otsuThreshold(hist, dark) + thrBoost);
  var inkN = 0;
  for (var t = 0; t < thr; t++) {
    inkN += hist[t];
  }
  if (thr <= 8 || inkN * 2 >= dark) {
    return g; // 阈值贴底（近全黑）/墨水占深色过半（纯条无字）
  }
  final out = img.Image(width: g.width, height: g.height);
  for (var y = 0; y < g.height; y++) {
    for (var x = 0; x < g.width; x++) {
      var b = 255;
      if (!isLight[x]) {
        final p = g.getPixel(x, y);
        b = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b < thr ? 0 : 255;
      }
      out.setPixelRgba(x, y, b, b, b, 255);
    }
  }
  return out;
}

/// 整图平均灰度（深色小区判定用）
double _meanGray(img.Image g) {
  var sum = 0;
  for (final p in g) {
    sum += (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
  }
  final n = g.width * g.height;
  return n == 0 ? 255.0 : sum / n;
}

/// 字形孔洞的纵向质心列表（升序）：bbox 内二值化（<140 墨），从边框灌
/// 白（4 连通）后剩余的 ≥6px 白域各取质心 y / 字形高。噪声斑点（JPEG
/// 压缩在粗笔画里挤出的白点）不足 6px 不计。
/// 孔数 + 孔位是数字的拓扑指纹：6 孔在下（wx1 实测 y≈0.68）、9 孔在
/// 上（≈0.22）、0/8 双孔（0.24/0.65 附近）——比 NCC 可靠得多（6↔9 上下
/// 镜像，紧框归一化后 NCC 系统性认反，wx1 C21 实测 9:0.645 > 6:0.548）
List<double> _glyphHoleYs(img.Image image, Rect r) {
  final x0 = r.left.round().clamp(0, image.width - 1);
  final y0 = r.top.round().clamp(0, image.height - 1);
  final x1 = r.right.round().clamp(x0 + 1, image.width);
  final y1 = r.bottom.round().clamp(y0 + 1, image.height);
  final w = x1 - x0, h = y1 - y0;
  if (w <= 0 || h <= 0) {
    return const [];
  }
  final white = List<bool>.filled(w * h, false);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x0 + x, y0 + y);
      if (0.299 * p.r + 0.587 * p.g + 0.114 * p.b >= 140) {
        white[y * w + x] = true;
      }
    }
  }
  final seen = List<bool>.filled(w * h, false);
  final stack = <int>[];
  void flood4(int start) {
    seen[start] = true;
    stack.add(start);
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      final cx = cur % w, cy = cur ~/ w;
      for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final nx = cx + dx, ny = cy + dy;
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) {
          continue;
        }
        final idx = ny * w + nx;
        if (white[idx] && !seen[idx]) {
          seen[idx] = true;
          stack.add(idx);
        }
      }
    }
  }

  // 边框灌白：接触 bbox 边的白域是字形外部，不算孔
  for (var x = 0; x < w; x++) {
    for (final y in [0, h - 1]) {
      final idx = y * w + x;
      if (white[idx] && !seen[idx]) {
        flood4(idx);
      }
    }
  }
  for (var y = 0; y < h; y++) {
    for (final x in [0, w - 1]) {
      final idx = y * w + x;
      if (white[idx] && !seen[idx]) {
        flood4(idx);
      }
    }
  }
  // 剩余白域 = 孔（面积 ≥6px 才算，噪声斑点不计）
  final holes = <double>[];
  for (var sy = 0; sy < h; sy++) {
    for (var sx = 0; sx < w; sx++) {
      final start = sy * w + sx;
      if (!white[start] || seen[start]) {
        continue;
      }
      var n = 0;
      var ySum = 0;
      seen[start] = true;
      stack.add(start);
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        n++;
        ySum += cur ~/ w;
        final cx = cur % w, cy = cur ~/ w;
        for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final nx = cx + dx, ny = cy + dy;
          if (nx < 0 || nx >= w || ny < 0 || ny >= h) {
            continue;
          }
          final idx = ny * w + nx;
          if (white[idx] && !seen[idx]) {
            seen[idx] = true;
            stack.add(idx);
          }
        }
      }
      if (n >= 6) {
        holes.add(ySum / n / h);
      }
    }
  }
  holes.sort();
  return holes;
}

/// 字形归一化 patch：bbox 裁剪强缩到 40×60 灰度（NCC 前的形状归一化）
List<double> _glyphPatch(img.Image image, Rect r) {
  final x0 = r.left.round().clamp(0, image.width - 1);
  final y0 = r.top.round().clamp(0, image.height - 1);
  final x1 = r.right.round().clamp(x0 + 1, image.width);
  final y1 = r.bottom.round().clamp(y0 + 1, image.height);
  if (x1 - x0 <= 0 || y1 - y0 <= 0) {
    return List<double>.filled(40 * 60, 0);
  }
  final crop =
      img.copyCrop(image, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
  final small = img.copyResize(
    crop,
    width: 40,
    height: 60,
    interpolation: img.Interpolation.linear,
  );
  return [
    for (final p in small) 0.299 * p.r + 0.587 * p.g + 0.114 * p.b,
  ];
}

double _glyphNcc(List<double> a, List<double> b) {
  final n = math.min(a.length, b.length);
  if (n == 0) {
    return 0;
  }
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < n; i++) {
    final va = a[i] - ma, vb = b[i] - mb;
    num += va * vb;
    da += va * va;
    db += vb * vb;
  }
  return da > 0 && db > 0 ? num / (math.sqrt(da) * math.sqrt(db)) : 0;
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// 字形模板匹配兜底（[fixOrphanCodeCounts] 的 ML Kit 全变体失败后调用）：
/// 同图已读出的颗数元素切字形作模板（同字体/字号/光照），目标窗口内切
/// 字形按「孔洞拓扑指纹 + NCC 确认」分类。
///
/// 为什么不用纯 NCC：6↔9 上下镜像，紧框归一化后 NCC 系统性认反（wx1
/// C21 的 6 实测 9:0.645 > 6:0.548）。孔洞指纹确定性分辨——孔数 + 每孔
/// 纵向质心：6 孔在下（y≈0.68）、9 孔在上（≈0.22）、双孔 0/8（模板两端
/// 实测比对，不硬编码先验，字体差异自然吸收）。误读模板毒化也被拓扑
/// 隔离：wx1 F5「16→10」的毒字形实测双孔，对单孔 6 目标整类出局。
/// NCC 只在孔指纹相同的候选类间作确认/仲裁（类得分取中位数，单条毒
/// 模板拉不高整类）：多候选取分高且裕度 ≥0.05；单候选取低门槛确认
/// （拓扑已完成判别，NCC 只拦杂形）。不过门槛返回 null（颗数留 0 用户
/// 手填，宁缺毋滥）。返回 (颗数, 字形联合框 scaled 坐标)。
(int, Rect)? matchCountGlyphs(
  img.Image scaled,
  List<OcrElem> countElems,
  Rect window, {
  void Function(String)? onDbg,
}) {
  // 模板池：颗数元素切字形按数字位标注；字形数与位数不符（切断/粘连）
  // 的元素整条弃用；本次救援补回的元素不回头当模板（猜的不配教别人）
  final tmpls = <(String, List<double>, List<double>)>[];
  final tmplWids = <double>[]; // 模板字形宽度（目标侧粘连拒绝基准）
  for (final e in countElems) {
    if (e.count == null || e.rect.width <= 0 || e.rect.height <= 0) {
      continue;
    }
    if (e.dbgText.contains("下方OCR") || e.dbgText.contains("字形匹配")) {
      continue;
    }
    final digits = e.count.toString();
    final comps = _inkComponents(scaled, e.rect);
    if (comps.length != digits.length) {
      continue;
    }
    for (var i = 0; i < comps.length; i++) {
      tmplWids.add(comps[i].width);
      tmpls.add((
        digits[i],
        _glyphHoleYs(scaled, comps[i]),
        _glyphPatch(scaled, comps[i]),
      ));
    }
  }
  if (tmpls.isEmpty) {
    onDbg?.call("字形匹配: 无可用模板");
    return null;
  }
  // 目标字形：窗口内墨水连通域（1-3 个，超出说明窗口混入邻条目/杂线）
  final comps = _inkComponents(scaled, window);
  if (comps.isEmpty || comps.length > 3) {
    onDbg?.call("字形匹配: 窗口字形数${comps.length}（空/杂）");
    return null;
  }
  // 目标连通域宽度健全性：模板侧有「连通域数=位数」拒绝切断/粘连，目标
  // 侧原先没有等价拒绝——粘连成一个连通域的两位数会被当单字形硬分类
  //（评审确认）。宽度超模板中位字形宽 1.4 倍按粘连/杂形拒绝
  final maxCompW = _median(tmplWids) * 1.4;
  if (comps.any((c) => c.width > maxCompW)) {
    onDbg?.call(
      "字形匹配: 目标连通域过宽${comps.map((c) => c.width.toInt()).join("/")}"
      ">${maxCompW.toInt()}（粘连/杂形）",
    );
    return null;
  }
  var text = "";
  var union = comps.first;
  for (final c in comps) {
    union = union.expandToInclude(c);
  }
  for (final c in comps) {
    final holes = _glyphHoleYs(scaled, c);
    final patch = _glyphPatch(scaled, c);
    // 孔指纹筛选：孔数相同且各孔质心纵向对齐（±0.12）的模板类才参选
    final byClass = <String, List<double>>{};
    for (final (d, th, tp) in tmpls) {
      if (th.length != holes.length) {
        continue;
      }
      var ok = true;
      for (var i = 0; i < th.length; i++) {
        if ((th[i] - holes[i]).abs() > 0.12) {
          ok = false;
          break;
        }
      }
      if (ok) {
        byClass.putIfAbsent(d, () => []).add(_glyphNcc(patch, tp));
      }
    }
    final ranked = [
      for (final d in byClass.keys) (d, _median(byClass[d]!)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    onDbg?.call(
      "字形匹配: 孔=${holes.length}@[${holes.map((t) => t.toStringAsFixed(2)).join(",")}] "
      "类分=[${ranked.map((r) => "${r.$1}:${r.$2.toStringAsFixed(3)}").join("|")}]",
    );
    if (ranked.isEmpty) {
      return null; // 孔指纹无同类：字体库覆盖不到，宁可不认
    }
    if (ranked.length == 1) {
      if (ranked[0].$2 < 0.15) {
        return null; // 单候选低门槛确认：拓扑已完成判别，NCC 只拦杂形
      }
    } else if (ranked[0].$2 < 0.18 || ranked[0].$2 - ranked[1].$2 < 0.05) {
      return null; // 多候选：分数/裕度门槛，区分度不足宁可不认
    }
    text += ranked[0].$1;
  }
  final n = int.tryParse(text);
  if (n == null || n <= 0 || n > 100000) {
    return null;
  }
  return (n, union);
}

/// 空隙小区单独识别：原图 + 反色（深底白字对反色更稳定）两轮，返回第一
/// 个「像色号」的元素文本与其在 [gapBig] 中的框；每轮内色号样式优先于
/// 裸数字，未识别到返回 null。[preferNumber] 为 true 时只认纯数字
/// （孤儿色号的颗数重读用：小区可能跨进下一行，字母色号文本必须拒收）
///
/// 喂图走 InputImage.fromBitmap 原始 RGBA 字节（image 包 rgba8 内存序即
/// RGBA，零转换直传）：原路径 encodePng（纯 Dart zlib）+ 写盘 + 原生解码
/// 全在主 isolate，救援链逐孤儿 × 多构型 × 多轮累计把 UI 线程打成秒级连续
/// 满载（2026-11-02 模拟器实测识别全程主线程冻结 7.6s）；像素与 PNG 逐位
/// 一致（同为无损传输），ML Kit 侧结果不变
///
/// [inverted]/[rgba]/[rgbaInverted] 为调用方在 compute isolate 内预备的
/// 反色副本与 RGBA 字节（补读链 gapVariant 出参，主 isolate 免逐轮反型
/// 循环与 getBytes 大拷贝）；缺省时本函数就地构建，行为与旧版一致
Future<(String, Rect)?> ocrGapText(
  img.Image gapBig, {
  img.Image? inverted,
  Uint8List? rgba,
  Uint8List? rgbaInverted,
  bool preferNumber = false,
  Rect? pickNear,
  double? maxElemW,
  void Function(String)? onDbg,
}) async {
  final inv = inverted ?? _invertImage(gapBig);
  final codeLike = RegExp(r'^[A-Z]{1,2}\d{1,2}$');
  // 纯数字判定：颗数重读轮放宽到数字形近字母（5↔S、6↔G、8↔B、1↔I/L、
  // 0↔O），换算交给 parseCountText；色号救援轮保持纯数字不动
  final numLike =
      preferNumber ? RegExp(r'^[\dOSBGIL]{1,3}$') : RegExp(r'^\d{1,3}$');
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    for (var round = 0; round < 2; round++) {
      final v = round == 0 ? gapBig : inv;
      if (round == 1 && onDbg != null) {
        // 【临时调试】反色是否真的发生：中点像素对拍 + 底层数据格式 + 字节数
        final px = gapBig.width ~/ 2, py = gapBig.height ~/ 2;
        final a = gapBig.getPixel(px, py), b = inv.getPixel(px, py);
        onDbg(
          "反色校验 原(${a.r},${a.g},${a.b}) 反(${b.r},${b.g},${b.b}) "
          "fmt=${gapBig.format}/${inv.format} "
          "通道${gapBig.numChannels}/${inv.numChannels} "
          "bytes=${v.getBytes(order: img.ChannelOrder.rgba).length}",
        );
      }
      final els = await ocrRgba(
            v,
            rgba: round == 0 ? rgba : rgbaInverted,
          ) ??
          await ocrRgbaPlugin(recognizer, v);
      (String, Rect)? numHit;
      final numCands = <(String, Rect)>[]; // pickNear 位置挑选用候选
      final texts = <String>[]; // onDbg 调试用：本轮全部元素文本
      for (final element in els) {
        // 连字符剥除（同 ocrGapVariants）：代码印成 "G-29" 型，色号
        // 字符集不含连字符，带着它 codeLike/数字样式全失配
        final text = element.text
            .trim()
            .toUpperCase()
            .replaceAll(" ", "")
            .replaceAll("-", "");
        texts.add(text);
        if (text.length > 4) {
          continue; // 长文本是杂项，不是色号
        }
        if (!preferNumber && codeLike.hasMatch(text)) {
          return (text, element.rect);
        }
        // numHit 须过 parseCountText：白字黑底被误读成 "0"/"O"（解析为
        // 颗数 0 无效）时不能当命中——那会带着垃圾提前 return，中断
        // 反色轮（wx1：F7/H22 的白 6 黑底轮 0 读成 0，反色轮没跑）
        if (numHit == null &&
            numLike.hasMatch(text) &&
            parseCountText(text) != null) {
          numHit = (text, element.rect);
        }
        if (numLike.hasMatch(text) && parseCountText(text) != null) {
          numCands.add((text, element.rect));
        }
      }
      if (onDbg != null) {
        onDbg(
          "空隙OCR轮$round(${round == 0 ? "原" : "反"}) "
          "文本=[${texts.join("|")}] numHit=${numHit?.$1 ?? "无"}",
        );
      }
      // pickNear 模式：目标颗数按位置挑（宽带裁剪带进了邻条目颗数），
      // 中心落在期望框内、宽度不超限（整行粘连文本）的候选里取最接近
      // 期望中心者；无 pickNear 时沿用首个命中
      if (pickNear != null) {
        (String, Rect)? best;
        var bestD = double.infinity;
        for (final c in numCands) {
          if (maxElemW != null && c.$2.width > maxElemW) {
            continue;
          }
          if (!pickNear.contains(c.$2.center)) {
            continue;
          }
          final d = (c.$2.center - pickNear.center).distance;
          if (d < bestD) {
            bestD = d;
            best = c;
          }
        }
        if (best != null) {
          return best;
        }
      } else if (numHit != null) {
        return numHit;
      }
    }
  } finally {
    await recognizer.close();
  }
  return null;
}

/// 选区整图单次 OCR：裁全部格子包围盒外扩半格，放大喂 ML Kit，元素
/// 中心换算回图片坐标归类到格（九宫格模式按格线相位解析 col/row +
/// 中心距校验；四角模式取最近格中心），同格多元素按 x 排序拼接成
/// 整串色号。返回 格扁平索引 -> 拼接文本；web/异常/无识别返回空 map
/// （调用方回落色彩识别）。
Future<Map<int, String>> ocrCells(
  img.Image image,
  List<Rect> cellRects,
  List<Offset> centers,
  Offset gridOrigin,
  int cols,
  int rows,
  bool useCorner,
  double pitchX,
  double pitchY, {
  void Function(Map<int, String> band)? onBand,
}) async {
  if (kIsWeb) {
    return const {};
  }
  if (cellRects.isEmpty) {
    return const {};
  }
  try {
    // 裁剪范围：全部格子包围盒外扩半格（边缘格文字完整）
    var bLeft = image.width.toDouble();
    var bTop = image.height.toDouble();
    var bRight = 0.0, bBottom = 0.0;
    var sumW = 0.0, sumH = 0.0;
    for (final cr in cellRects) {
      if (cr.left < bLeft) {
        bLeft = cr.left;
      }
      if (cr.top < bTop) {
        bTop = cr.top;
      }
      if (cr.right > bRight) {
        bRight = cr.right;
      }
      if (cr.bottom > bBottom) {
        bBottom = cr.bottom;
      }
      sumW += cr.width;
      sumH += cr.height;
    }
    final avgW = sumW / cellRects.length;
    final avgH = sumH / cellRects.length;
    final cx0 = (bLeft - avgW / 2).clamp(0.0, image.width - 4.0);
    final cy0 = (bTop - avgH / 2).clamp(0.0, image.height - 4.0);
    final cx1 = (bRight + avgW / 2).clamp(cx0 + 4.0, image.width.toDouble());
    final cy1 = (bBottom + avgH / 2).clamp(cy0 + 4.0, image.height.toDouble());
    final cropW = (cx1 - cx0).toInt();
    // 放大策略：目标宽 3600（格内色号字小，格距 ~31px 时字高 ~10px，
    // 不放大 ML Kit 读不出），上限 6 防小选区过度放大锯齿化丢字；大选区
    // （相机原片 crop ≥3600px 宽）不再强制放大——旧版 clamp 下限 2.0 会
    // 把 4000px crop 拉到 8000px 宽（48MP），并按 ML Kit 输入上限把输出
    // 宽 cap 在 3800 内（同图例路径 widthCap），防超限后 processImage
    // 异常被下方 catch 吞掉整轮 OCR 静默失效
    var scale = (3600 / cropW).clamp(1.0, 6.0);
    final widthCap = 3800 / cropW;
    if (scale > widthCap) {
      scale = widthCap;
    }
    final centerLimit = 0.65 * math.max(avgW, avgH);
    final tmpDir = (await getTemporaryDirectory()).path;
    // 分带逐带识别（2026-11-06 进度反馈）：单张大图一次 processImage 全程
    // 无事件，进度只能 0→结尾两跳；按 ~350px 原图带高切 2-8 带，每带一次
    // 识别一次回调，总像素不变只多几次调用往返。带缘外扩半格——交界处
    // 压线文字两带都会读到，归类按中心距离归位、Map 覆盖不重复计数
    final bands = ((cy1 - cy0) / 350).clamp(2.0, 8.0).round();
    final out = <int, String>{};
    for (var b = 0; b < bands; b++) {
      final bt0 = cy0 + (cy1 - cy0) * b / bands;
      final bt1 = cy0 + (cy1 - cy0) * (b + 1) / bands;
      final by0 = (bt0 - avgH / 2).clamp(0.0, image.height - 4.0);
      final by1 = (bt1 + avgH / 2).clamp(by0 + 4.0, image.height.toDouble());
      final bandH = (by1 - by0).toInt();
      // 裁剪/缩放/PNG 编码走 compute isolate：百万像素级同步重活（大图
      // 12MP+）在主 isolate 会冻结 UI 秒级（ANR），与 encodeDisplayJpg
      // 同理
      final pngBytes = await compute(
        encodeCellOcrPng,
        CellOcrArgs(image, cx0.toInt(), by0.toInt(), cropW, bandH, scale),
      );
      final tmp = File("$tmpDir/cells_ocr_$b.png");
      await tmp.writeAsBytes(pngBytes);
      // 解码+推理走原生后台线程通道（插件 fromFilePath 在平台线程=UI 线程
      // 上跑，识别期间主线程冻结）；通道不可用回退插件
      var els = await ocrImageFile(tmp.path);
      if (els == null) {
        final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
        els = await ocrFilePlugin(recognizer, tmp.path);
        await recognizer.close();
      }
      // 元素中心（放大图坐标）-> 图片坐标 -> 归类到格
      final rawByCell = <int, List<(double, String)>>{};
      for (final element in els) {
        final text = element.text.trim().toUpperCase().replaceAll(" ", "");
        if (text.isEmpty ||
            text.length > 4 ||
            !RegExp(r'^[A-Z0-9]+$').hasMatch(text)) {
          continue; // 只收色号样式（≤4 字母数字），长文本/杂项不做
        }
        final bc = element.rect.center;
        final p = Offset(cx0 + bc.dx / scale, by0 + bc.dy / scale);
        int? cellIdx;
        if (!useCorner) {
          // 九宫格模式：按格线相位直接解析 col/row，中心距校验防
          // 串格（文字压在格线上时 floor 会落到邻格）
          final col = ((p.dx - gridOrigin.dx) / pitchX).floor();
          final row = ((p.dy - gridOrigin.dy) / pitchY).floor();
          if (col >= 0 && col < cols && row >= 0 && row < rows) {
            final idx = row * cols + col;
            if ((p - centers[idx]).distance < centerLimit) {
              cellIdx = idx;
            }
          }
        }
        if (cellIdx == null) {
          // 兜底（四角模式主路径）：最近格中心，超限丢弃。格子联合
          // 包围盒（不含外扩半格）之外的元素是选区外内容（行列编号/
          // 图例杂文）——裁剪外扩半格会把它读进 OCR，若被收进边缘格
          // 会与格内色号按 x 拼接成 "F2"+"1"→"F21" 型错串（撞上混淆
          // 变体即按 OCR 权威错认上色），直接丢弃
          if (p.dx < bLeft || p.dx > bRight || p.dy < bTop || p.dy > bBottom) {
            continue;
          }
          var best = -1;
          var bestD = double.infinity;
          for (var i = 0; i < centers.length; i++) {
            final d = (p - centers[i]).distance;
            if (d < bestD) {
              bestD = d;
              best = i;
            }
          }
          if (best >= 0 && bestD < centerLimit) {
            cellIdx = best;
          }
        }
        if (cellIdx != null) {
          rawByCell.putIfAbsent(cellIdx, () => []).add((p.dx, text));
        }
      }
      // 同格多元素（"F" "2" 分开识别等）按 x 排序拼接；本带结果立即
      // 回调（进度）并并入总表
      final band = <int, String>{};
      rawByCell.forEach((idx, list) {
        list.sort((a, b) => a.$1.compareTo(b.$1));
        band[idx] = [for (final t in list) t.$2].join();
      });
      out.addAll(band);
      onBand?.call(band);
    }
    return out;
  } on BusyCancelled {
    rethrow; // 用户终止：放行给调用方清锁，不吞成「识别为空」
  } catch (_) {
    return const {};
  }
}

/// 二遍逐格补读拼瓦参数（encodeTilesJpg 的 compute 入参）
class TilesOcrArgs {
  final img.Image image;

  ///< 原图（isolate 内逐瓦裁剪）
  final List<Rect> rects;

  ///< 瓦片矩形（图片坐标，已含外扩）
  final int slotW, slotH;

  ///< 统一瓦片槽尺寸（放大后）
  final int gutter;

  ///< 槽间白带宽（防跨瓦字符粘连）
  final int perRow;

  ///< 每行槽数
  const TilesOcrArgs(
    this.image,
    this.rects,
    this.slotW,
    this.slotH,
    this.gutter,
    this.perRow,
  );
}

/// 二遍补读拼瓦编码（compute isolate 内）：逐瓦裁剪→均匀性检查（亮度
/// 极差 <22 视为无印刷：空白格/纯色无码格直接留白，不喂 OCR 不产噪）→
/// 等比放大居中入槽，整批拼一张白底大图。重活进 isolate 与
/// encodeCellOcrPng 同理（百万像素级同步跑主 isolate 会冻结 UI 秒级）。
/// 编码用 JPEG q95（拼瓦数百万像素，PNG 编码数秒级拖慢逐批节奏，JPEG
/// 快一个量级且 q95 对放大后的字形块无损感知）
Uint8List encodeTilesJpg(TilesOcrArgs a) {
  final n = a.rects.length;
  final rows = (n + a.perRow - 1) ~/ a.perRow;
  final strideX = a.slotW + a.gutter;
  final strideY = a.slotH + a.gutter;
  final canvas = img.Image(
    width: strideX * a.perRow - a.gutter,
    height: strideY * rows - a.gutter,
  );
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  for (var k = 0; k < n; k++) {
    final r = a.rects[k];
    final x0 = r.left.round().clamp(0, a.image.width - 1);
    final y0 = r.top.round().clamp(0, a.image.height - 1);
    final x1 = r.right.round().clamp(x0 + 1, a.image.width);
    final y1 = r.bottom.round().clamp(y0 + 1, a.image.height);
    final crop = img.copyCrop(
      a.image,
      x: x0,
      y: y0,
      width: x1 - x0,
      height: y1 - y0,
    );
    var mn = 255, mx = 0;
    for (var y = 0; y < crop.height; y += 2) {
      for (var x = 0; x < crop.width; x += 2) {
        final p = crop.getPixel(x, y);
        final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
        if (l < mn) {
          mn = l;
        }
        if (l > mx) {
          mx = l;
        }
      }
    }
    if (mx - mn < 22) {
      continue; // 无印刷（空白/纯色无码）：槽留白
    }
    final scale = math.min(a.slotW / crop.width, a.slotH / crop.height);
    var big = crop;
    if (scale > 1.01) {
      big = img.copyResize(
        crop,
        width: (crop.width * scale).round(),
        height: (crop.height * scale).round(),
      );
    }
    img.compositeImage(
      canvas,
      big,
      dstX: strideX * (k % a.perRow) + (a.slotW - big.width) ~/ 2,
      dstY: strideY * (k ~/ a.perRow) + (a.slotH - big.height) ~/ 2,
    );
  }
  return img.encodeJpg(canvas, quality: 95);
}

/// 二遍逐格补读：整图一遍 OCR 没读到色号的格，逐格裁剪放大拼白底瓦阵
/// 分批补识别——一次 processImage 读一批瓦（逐格单图调用要数秒×格数，
/// 见 ocrCells 头注）。文本是图纸的权威声明，一遍没读到≠格内没有文本
/// （字小/压格线/全局放大倍率不够都会漏），色彩回退前必须给足文本机会。
/// 批粒度 ~120 瓦：每批一次进图，[onBatch](起始下标, 本批瓦数, 文本表)
/// 每批回调一次（含零命中的批——本批瓦的文本阶段已终结，进度照走）。
/// 返回/回调文本表的键是 rects 的下标（非格子编号，调用方自映射），值=
/// 瓦内按 x 拼接的文本（可能仍不是 palette 色号，由调用方查 codeMap）
Future<Map<int, String>> ocrCellsSecondPass(
  img.Image image,
  List<Rect> cellRects, {
  void Function(int start, int count, Map<int, String> batch)? onBatch,
}) async {
  final out = <int, String>{};
  if (kIsWeb || cellRects.isEmpty) {
    return out;
  }
  try {
    var sumW = 0.0, sumH = 0.0;
    for (final r in cellRects) {
      sumW += r.width;
      sumH += r.height;
    }
    final avgW = sumW / cellRects.length;
    final avgH = sumH / cellRects.length;
    // 槽尺寸：格外扩 30%（压格线的字完整入瓦）后放大到槽宽 ~160px
    // （色号字高到 40-50px 的 ML Kit 舒适区；一遍 3600/cropW 的全局倍率
    // 在小选区上字可能只有 ~20px——补读的意义就在这），上限 8 防大格
    // 锯齿化、槽上限 400 防离谱大格撑爆拼瓦
    final scale = (160 / (avgW * 1.6)).clamp(1.0, 8.0);
    final slotW = math.min(400, (avgW * 1.6 * scale).round());
    final slotH = math.min(400, (avgH * 1.6 * scale).round());
    final gutter = math.max(48, (slotH * 0.6).round());
    final strideX = slotW + gutter, strideY = slotH + gutter;
    final perRow = math.max(1, (3800 + gutter) ~/ strideX);
    // 批量：整图高限 4200 内的整行数，再钳到 ~120 瓦/批（进度条 tick 粒度）
    final rowsCap = math.max(1, (4200 + gutter) ~/ strideY);
    final perBatch = math.min(perRow * rowsCap, math.max(perRow, 120));
    // 瓦片矩形：格外扩 30% 后夹回图内
    final rects = <Rect>[];
    for (final cr in cellRects) {
      final m = math.max(cr.width, cr.height) * 0.3;
      rects.add(Rect.fromLTRB(
        (cr.left - m).clamp(0.0, image.width - 1.0),
        (cr.top - m).clamp(0.0, image.height - 1.0),
        (cr.right + m).clamp(1.0, image.width.toDouble()),
        (cr.bottom + m).clamp(1.0, image.height.toDouble()),
      ));
    }
    final tmpDir = (await getTemporaryDirectory()).path;
    final codeLike = RegExp(r'^[A-Z0-9]+$');
    for (var b = 0; b * perBatch < rects.length; b++) {
      final part = rects.sublist(
        b * perBatch,
        math.min((b + 1) * perBatch, rects.length),
      );
      // 注：image 随 args 整体拷入 isolate，大图每批一次拷贝成本已计入
      // 批粒度权衡（测试图 ~2MP 级无感；真机大图若慢再优化为预裁剪共享）
      final jpgBytes = await compute(
        encodeTilesJpg,
        TilesOcrArgs(image, part, slotW, slotH, gutter, perRow),
      );
      final tmp = File("$tmpDir/cells_ocr2_$b.jpg");
      await tmp.writeAsBytes(jpgBytes);
      var els = await ocrImageFile(tmp.path);
      if (els == null) {
        final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
        els = await ocrFilePlugin(recognizer, tmp.path);
        await recognizer.close();
      }
      // 元素中心 -> 槽行列 -> 瓦下标；槽内中心区校验（同一遍 centerLimit
      // 思路）：瓦间白带/瓦缘的文字=邻格压线字，收进来会把邻格色号安到
      // 本格（"F2"+"1"→"F21" 型错串按 OCR 权威上色），弃
      final byLocal = <int, List<(double, String)>>{};
      for (final element in els) {
        final text = element.text.trim().toUpperCase().replaceAll(" ", "");
        if (text.isEmpty || text.length > 4 || !codeLike.hasMatch(text)) {
          continue;
        }
        final c = element.rect.center;
        final col = (c.dx / strideX).floor();
        final row = (c.dy / strideY).floor();
        if (col < 0 || col >= perRow || row < 0) {
          continue;
        }
        final local = row * perRow + col;
        if (local >= part.length) {
          continue;
        }
        final fx = (c.dx - col * strideX) / slotW;
        final fy = (c.dy - row * strideY) / slotH;
        if (fx < 0.15 || fx > 0.85 || fy < 0.15 || fy > 0.85) {
          continue;
        }
        byLocal.putIfAbsent(local, () => []).add((c.dx, text));
      }
      final batch = <int, String>{};
      byLocal.forEach((local, list) {
        list.sort((p, q) => p.$1.compareTo(q.$1));
        batch[local] = [for (final t in list) t.$2].join();
      });
      out.addAll(batch);
      onBatch?.call(b * perBatch, part.length, batch);
    }
    return out;
  } on BusyCancelled {
    rethrow; // 用户终止：放行给调用方清锁，不吞成「补读失败」
  } catch (_) {
    return out; // 补读整体失败：保持一遍结果，色彩回退兜底
  }
}
