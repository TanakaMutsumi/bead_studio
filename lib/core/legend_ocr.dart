import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'palette.dart';

/// 图例 OCR 识别元素（色号或颗数，带几何框供跨行配对）
class OcrElem {
  final int seq;

  ///< 收集序（block/line/element 遍历序，保底配对用）
  final Rect rect;

  ///< 元素框（放大图坐标系；个别平台可能退化为 0 框）
  final int? code;

  ///< 色号 -> 调色板索引（与 count 互斥）
  final int? count;

  ///< 颗数
  bool used = false;

  ///< 已被配对消费（数字侧）
  int? pairedCount;

  ///< 色号侧配到的颗数
  // 【临时调试】配对的另一侧元素引用（调试视图画连线用，正式版随调试功能一起移除）
  OcrElem? pairedWith;
  String dbgText = "";

  ///< 【临时调试】OCR 原始文本
  OcrElem(this.seq, this.rect, this.code, this.count);
}

/// 【临时调试】一次图例 OCR 的调试快照（正式版随调试视图一起移除）
class OcrDebugInfo {
  final String source;

  ///< 来源（自动扫描档位 / 手动框选）
  final String imgPath;

  ///< 喂给 ML Kit 的放大选区图路径
  final int imgW, imgH;

  ///< 放大图尺寸（元素框坐标系）
  final List<OcrElem> elems;

  ///< 全部识别元素（含配对引用）
  final double selX, selY, selW, selH;

  ///< 框选区（原图坐标）——复现框选用
  OcrDebugInfo(
    this.source,
    this.imgPath,
    this.imgW,
    this.imgH,
    this.elems,
    this.selX,
    this.selY,
    this.selW,
    this.selH,
  );
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
      // 【临时调试】记录配对引用供调试视图画连线
      c.pairedWith = best;
      best.pairedWith = c;
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
      if (n.rect.top - c.rect.center.dy > avgH * 2.5) {
        continue; // 只认紧邻下方
      }
      final dx = (n.rect.center.dx - c.rect.center.dx).abs();
      if (dx > avgH * 3) {
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
      // 【临时调试】记录配对引用供调试视图画连线
      c.pairedWith = best;
      best.pairedWith = c;
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

/// 全色卡「精确 + 混淆变体」查找表：variant -> 调色板索引（图例 OCR
/// 与格子 OCR 共用；变体撞车先到先得）
Map<String, int> buildCodeMap(BeadPalette palette) {
  final codeMap = <String, int>{};
  for (var i = 0; i < palette.colors.length; i++) {
    final variants = <String>{};
    collectCodeVariants(
      palette.colors[i].id.toUpperCase(),
      0,
      "",
      variants,
    );
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
      .replaceAll("B", "8");
  if (!RegExp(r"^\d+$").hasMatch(t)) {
    return null;
  }
  final v = int.tryParse(t);
  return (v == null || v <= 0 || v > 100000) ? null : v;
}

/// 孤儿颗数修复：带括号颗数的左侧同行/正上方近旁都没有色号元素，说明该
/// 条目的色号整条被 ML Kit 吞掉（H7 案例：(343) 读出而 H7 消失）。裁
/// 「左邻元素右缘 -> 颗数左缘」的空隙小区放大后单独再识别，读出的色号
/// 按空隙几何位置补回 [elems] 参与最终配对。
/// 返回补全数；识别到但当前色卡没有的色号（如 MARD 卡外的 H7）收集到
/// [orphanNotes] 供上层提示用户手工补。[tmpDirPath] 只取目录，临时文件名固定
Future<int> fixOrphanCountCodes(
  BeadPalette palette,
  List<OcrElem> elems,
  img.Image scaled,
  Map<String, int> codeMap,
  String tmpDirPath,
  List<String> orphanNotes,
) async {
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
      // 正上方窗口（配对轮 2 同款）
      if (s.rect.bottom <= c.rect.center.dy &&
          c.rect.center.dy - s.rect.top <= avgH * 2.5 &&
          (s.rect.center.dx - c.rect.center.dx).abs() <= avgH * 3) {
        return true;
      }
    }
    return false;
  }

  final orphans = elems
      .where(
        (e) => e.code == null && e.dbgText.contains("(") && !hasCodeNearby(e),
      )
      .toList();
  if (orphans.isEmpty) {
    return 0;
  }
  var nextSeq = 0;
  for (final e in elems) {
    if (e.seq >= nextSeq) {
      nextSeq = e.seq + 1;
    }
  }
  var fixed = 0;
  for (final c in orphans) {
    // 空隙左界：左邻元素（同行、在颗数左侧、不太远）的最大右缘
    var gLeft = c.rect.left - avgH * 6;
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
    final gapW = c.rect.left - gLeft;
    // 空隙窄于一个字高：位置上放不下色号，跳过
    if (gapW < avgH * 0.8) {
      continue;
    }
    final gTop = (c.rect.top - avgH * 0.8).clamp(0.0, scaled.height - 1.0);
    final gBottom = (c.rect.bottom + avgH * 0.8)
        .clamp(gTop + 1.0, scaled.height.toDouble());
    final gap = img.copyCrop(
      scaled,
      x: gLeft.toInt(),
      y: gTop.toInt(),
      width: gapW.toInt(),
      height: (gBottom - gTop).toInt(),
    );
    final hit = await ocrGapText(
      img.copyResize(gap, width: gap.width * 2),
      File("$tmpDirPath/legend_ocr_gap.png"),
    );
    if (hit == null) {
      continue;
    }
    final (text, rel) = hit;
    // 空隙小区坐标 -> 放大图坐标（gap 又放大了 2 倍）
    final abs = Rect.fromLTWH(
      gLeft + rel.left / 2,
      gTop + rel.top / 2,
      rel.width / 2,
      rel.height / 2,
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

/// 空隙小区单独识别：原图 + 反色（深底白字对反色更稳定）两轮，返回第一
/// 个「像色号」的元素文本与其在 [gapBig] 中的框；每轮内色号样式优先于
/// 裸数字，未识别到返回 null
Future<(String, Rect)?> ocrGapText(img.Image gapBig, File tmp) async {
  await tmp.writeAsBytes(img.encodePng(gapBig));
  final inverted = img.Image.from(gapBig);
  for (final p in inverted) {
    p.r = 255 - p.r;
    p.g = 255 - p.g;
    p.b = 255 - p.b;
  }
  final codeLike = RegExp(r'^[A-Z]{1,2}\d{1,2}$');
  final numLike = RegExp(r'^\d{1,3}$');
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    for (var round = 0; round < 2; round++) {
      if (round == 1) {
        await tmp.writeAsBytes(img.encodePng(inverted));
      }
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(tmp.path),
      );
      (String, Rect)? numHit;
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          for (final element in line.elements) {
            final text = element.text.trim().toUpperCase().replaceAll(" ", "");
            if (text.length > 4) {
              continue; // 长文本是杂项，不是色号
            }
            if (codeLike.hasMatch(text)) {
              return (text, element.boundingBox);
            }
            if (numHit == null && numLike.hasMatch(text)) {
              numHit = (text, element.boundingBox);
            }
          }
        }
      }
      if (numHit != null) {
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
  double pitchY,
) async {
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
    final cropH = (cy1 - cy0).toInt();
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
    // 裁剪/缩放/PNG 编码走 compute isolate：百万像素级同步重活（大图
    // 12MP+）在主 isolate 会冻结 UI 秒级（ANR），与 encodeDisplayJpg
    // 同理
    final pngBytes = await compute(
      encodeCellOcrPng,
      CellOcrArgs(image, cx0.toInt(), cy0.toInt(), cropW, cropH, scale),
    );
    final tmp = File(
      "${(await getTemporaryDirectory()).path}/cells_ocr.png",
    );
    await tmp.writeAsBytes(pngBytes);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final recognized = await recognizer.processImage(
      InputImage.fromFilePath(tmp.path),
    );
    await recognizer.close();
    // 元素中心（放大图坐标）-> 图片坐标 -> 归类到格
    final rawByCell = <int, List<(double, String)>>{};
    final centerLimit = 0.65 * math.max(avgW, avgH);
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final text = element.text.trim().toUpperCase().replaceAll(" ", "");
          if (text.isEmpty ||
              text.length > 4 ||
              !RegExp(r'^[A-Z0-9]+$').hasMatch(text)) {
            continue; // 只收色号样式（≤4 字母数字），长文本/杂项不做
          }
          final bc = element.boundingBox.center;
          final p = Offset(cx0 + bc.dx / scale, cy0 + bc.dy / scale);
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
            if (p.dx < bLeft ||
                p.dx > bRight ||
                p.dy < bTop ||
                p.dy > bBottom) {
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
      }
    }
    // 同格多元素（"F" "2" 分开识别等）按 x 排序拼接
    final out = <int, String>{};
    rawByCell.forEach((idx, list) {
      list.sort((a, b) => a.$1.compareTo(b.$1));
      out[idx] = [for (final t in list) t.$2].join();
    });
    return out;
  } catch (_) {
    return const {};
  }
}
