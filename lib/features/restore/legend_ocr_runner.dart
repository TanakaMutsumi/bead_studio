import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../core/legend_ocr.dart';
import '../../core/native_ocr.dart';
import '../../core/palette.dart';

/// 一次图例 OCR 编排的结果
class LegendOcrRun {
  /// 配对成功的 [(色号调色板索引, 颗数)] 按阅读顺序；异常/无配对为 null
  final List<(int, int)>? pairs;

  /// 色卡外色号（如 MARD 卡没有的 H7），调用方提示用户手工补
  final List<String> orphanNotes;

  /// 分段识别中失败的段数（0=全成；=段数=OCR 整体失败），上层可提示
  /// 「识别不完整建议重新框选」
  final int segFails;

  const LegendOcrRun(this.pairs, this.orphanNotes, [this.segFails = 0]);
}

/// 分段重活打包（compute isolate 入参）：裁剪/放大/色条检测/PNG 编码
/// 全在 isolate 内做——全放大图百万像素级（wx1 达 10.6K×1.3K≈13.6MP），
/// 同步跑主 isolate 会冻结 UI 秒级（ANR），与 encodeCellOcrPng 同理
class LegendPrepArgs {
  final img.Image image;

  ///< 原图（isolate 内裁剪）
  final int x, y, w, h;

  ///< 框选区（图片坐标）
  final double scale;

  ///< 放大倍率
  final List<int> segX0, segX1;

  ///< 各段在全放大图的起止（含重叠；单发路径只有整图一段）
  final String tmpDir;

  ///< 临时目录（段 RGBA 在 isolate 内落盘，不走 isolate 出参）
  const LegendPrepArgs(
    this.image,
    this.x,
    this.y,
    this.w,
    this.h,
    this.scale,
    this.segX0,
    this.segX1,
    this.tmpDir,
  );
}

/// [prepLegendOcr] 的结果（isolate 出参）
///
/// 段字节在 isolate 内落盘、只回路径：数十 MB 字节数组
/// 跨 isolate 回传会在主 isolate 反序列化，主线程二次冻结（2026-11-03
/// 实测 prep 出参 90MB 级回传，主线程与 OCR 调用同段满载）
class LegendPrepResult {
  final img.Image scaled;

  ///< 全放大图（后续色块采样/空隙裁剪用）
  final List<LegendBar> bars;

  ///< 色条检测（在全放大图坐标系）
  final List<String> segPaths;

  ///< 各段原始 RGBA 文件路径（原生通道按文件读，段宽 = segX1[i]-segX0[i]、
  ///< 段高 = scaled.height）
  LegendPrepResult(this.scaled, this.bars, this.segPaths);
}

/// 裁剪+放大+色条检测+段落盘（顶层函数供 compute isolate 调用）
LegendPrepResult prepLegendOcr(LegendPrepArgs a) {
  final crop = img.copyCrop(
    a.image,
    x: a.x,
    y: a.y,
    width: a.w,
    height: a.h,
  );
  final scaled = img.copyResize(crop, width: (crop.width * a.scale).round());
  final bars = detectLegendBars(scaled);
  final segPaths = <String>[
    for (var i = 0; i < a.segX0.length; i++)
      "${a.tmpDir}/legend_seg_$i.rgba",
  ];
  for (var i = 0; i < a.segX0.length; i++) {
    final bytes = img
        .copyCrop(
          scaled,
          x: a.segX0[i],
          y: 0,
          width: a.segX1[i] - a.segX0[i],
          height: scaled.height,
        )
        .getBytes(order: img.ChannelOrder.rgba);
    File(segPaths[i]).writeAsBytesSync(bytes);
  }
  return LegendPrepResult(scaled, bars, segPaths);
}

/// OCR 图例选区 -> [(印刷色号调色板索引, 印刷颗数)] 按阅读顺序
///
/// 图纸图例每条目 = 色块 + 色号 + 颗数（印刷数字）；颗数有时跟在色号右侧同行，
/// 有时印在色号/色块正下方，色号也可能直接印在色块内（深底白字）。裁剪选区
/// 放大喂 ML Kit，收集全部色号/颗数 element（带几何框）走 [pairLegendOcr]
/// 两轮配对，再与 [detectLegendBars]/[fuseLegendBars] 色条颜色识别融合
/// （色号被 OCR 吞掉的条目由条色兜底、条下颗数按条几何归属）。
/// 宽条选区按 ML Kit 输入上限切段放大（每段长边 ≤3800 含重叠预算），
/// 元素换算回全放大图坐标后 [mergeSegmentElems] 合并去重。
/// OCR 环节抛异常时仍可由色条融合产清单；裁剪/写盘失败 pairs 为 null
/// （调用方回退色块量化清单）。
Future<LegendOcrRun> runLegendOcr(
  img.Image image,
  BeadPalette palette,
  double rx,
  double ry,
  double rw,
  double rh, {
  String source = "手动框选",
}) async {
  try {
    // 小字放大提高识别率：按高度放大到 ~960px（数字高 ~120px+）。
    // 固定 ×2/×3 在小字图例（色号字高 ~20 原图像素）下分辨率不足，
    // 实测 480 目标时第三行 5 条目只读出 3 个色号（2026-08-27 pic4），
    // 提到 960 后字高 ~74px 识别稳定
    var scale = (960 / rh).clamp(3.0, 8.0);
    // 长边（宽或高）cap 防超 ML Kit 输入上限：竖长条图例按高度放大曾到
    // 4479px，processImage 直接抛异常整链回退量化（test_pic5 案例）
    final cap = 3800 / math.max(rw, rh);
    final segX0 = <int>[];
    final segX1 = <int>[];
    if (rw > rh && rw * scale > 3800) {
      // 宽条分段：宽度约束解除后用满放大上限（wx1 实测 ×2.87 时字高仅
      // 20-30px，30 个色号只配出 19 个颗数、4 条整条目丢失；分段后每段
      // 独立 ≤3800，字高可到 ~80px 稳定区）。高度同时不得超限
      scale = math.max(scale, math.min(8.0, 3800 / rh));
      if (rh * scale > 3800) {
        scale = 3800 / rh;
      }
      final total = (rw * scale).round();
      // 段间重叠须 ≥ 最大元素宽（色号 2-4 字符）：按行高 1/16 估字高再
      // 放大 6 字符宽。重叠不足时切点落在元素内部，两段各读出半截——
      // "C3"→"3" 成假颗数、"H12"→"H1" 命中色号表成幻影色号
      final over = (rh * scale / 16 * 6).clamp(120.0, 600.0).round();
      final stride = 3800 - over; // 段宽硬上限 3800 已含重叠预算
      var k = ((total - over) / stride).ceil();
      if (k < 1) {
        k = 1;
      }
      for (var i = 0; i < k; i++) {
        final x0 = (i * stride).clamp(0, total - 1);
        final x1 = (x0 + 3800).clamp(x0 + 1, total);
        segX0.add(x0);
        segX1.add(x1);
        if (x1 >= total) {
          break;
        }
      }
    } else {
      if (scale > cap) {
        scale = cap;
      }
      segX0.add(0);
      segX1.add((rw * scale).round());
    }

    final tmpDir = (await getTemporaryDirectory()).path;
    final prep = await compute(
      prepLegendOcr,
      LegendPrepArgs(
        image,
        rx.toInt(),
        ry.toInt(),
        rw.toInt(),
        rh.toInt(),
        scale,
        segX0,
        segX1,
        tmpDir,
      ),
    );
    final scaled = prep.scaled;

    // 精确 + 混淆变体查找表（图例 OCR 与格子 OCR 共用）
    final codeMap = buildCodeMap(palette);

    // 收集全部色号/颗数元素（带几何框：颗数可能在色号下一行，纯行内序配不上）；
    // 原图轮/反色轮共用同一收集逻辑；xOff 把段内坐标换算回全放大图坐标。
    // 入参是展平元素表（原生通道/插件回退同出参，见 native_ocr.dart）
    List<OcrElem> collect(List<OcrTextElem> result, int seqStart, double xOff) {
      final out = <OcrElem>[];
      var seq = seqStart;
      for (final element in result) {
        final text = element.text.trim().toUpperCase().replaceAll(
              " ",
              "",
            );
        // 色号最多 4 字符（A1/H12 型），长文本是正文/杂项不做色号。
        // 纯数字文本即使命中混淆变体（8↔B 使 "81"→B1）也先按颗数
        // 收集——它更常是左侧色号的真颗数（"H7 81" 行的 81），
        // 配对后仍未消费的裸数字才兜底回落为色号
        if (text.length <= 4 && RegExp(r'^[A-Z]').hasMatch(text)) {
          final code = codeMap[text];
          if (code != null) {
            final e = OcrElem(
              seq++,
              Rect.fromLTRB(
                element.rect.left + xOff,
                element.rect.top,
                element.rect.right + xOff,
                element.rect.bottom,
              ),
              code,
              null,
            );
            e.dbgText = element.text; // 【临时调试】保留原始文本
            out.add(e);
            continue;
          }
        }
        final n = parseCountText(element.text);
        if (n != null) {
          final e = OcrElem(
            seq++,
            Rect.fromLTRB(
              element.rect.left + xOff,
              element.rect.top,
              element.rect.right + xOff,
              element.rect.bottom,
            ),
            null,
            n,
          );
          e.dbgText = element.text; // 【临时调试】保留原始文本
          out.add(e);
        }
      }
      return out;
    }

    final tagged = <(OcrElem, int)>[];
    var seq = 0;
    var segFails = 0;
    // 段识别：单段异常只记该段失败（重建 recognizer 防异常实例毒化后续段），
    // 全部段失败才视为 OCR 整体失败
    var recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      for (var i = 0; i < prep.segPaths.length; i++) {
        try {
          // 段识别走原生后台线程通道（bead_native_ocr：插件通道固定在
          // 平台线程=UI 线程上构位图+推理，每次调用主线程 100% 冻结；
          // 段 RGBA 由 prep isolate 落盘、通道直接读文件，主 isolate
          // 全程不碰大字节）。通道不可用回退插件（保功能，会冻结）
          final segW = segX1[i] - segX0[i];
          var els = await ocrRgbaFile(prep.segPaths[i], segW, prep.scaled.height);
          if (els == null) {
            els = await ocrRgbaPlugin(
              recognizer,
              img.copyCrop(
                prep.scaled,
                x: segX0[i],
                y: 0,
                width: segW,
                height: prep.scaled.height,
              ),
            );
          }
          final got = collect(els, seq, segX0[i].toDouble());
          seq += got.length;
          tagged.addAll([for (final e in got) (e, i)]);
        } catch (_) {
          segFails++;
          try {
            await recognizer.close();
          } catch (_) {}
          recognizer = TextRecognizer(script: TextRecognitionScript.latin);
        }
      }
    } finally {
      await recognizer.close();
    }
    final elems = mergeSegmentElems(
      tagged,
      [for (final x in segX0) x.toDouble()],
      [for (final x in segX1) x.toDouble()],
    );
    // 同行嵌套碎片清理（单段图例 mergeSegmentElems 不跑，须独立做）：
    // 段切尾巴/ML Kit 重复子元素会被色块补全 Fabricate 成幻影色号
    //（wx2 "7)"→R7、wx3 "5"→H5 重复条目）
    removeNestedFragments(elems);
    final ocrFailed = segFails >= prep.segPaths.length;
    final orphanNotes = <String>[];
    var parenCount = 0, bareCount = 0;
    if (!ocrFailed) {
      // 掉字母色号修复：深底反白/浅底浅字色号被 ML Kit 吞掉首字母，读成
      // 无括号纯数字 count（真颗数全部带括号 (N)）。当图内带括号颗数占绝对
      // 多数（≥6 且 ≥2×无括号数）时，无括号纯数字判定为掉字母色号：按数字
      // 后缀取色卡候选，用条目色块颜色（色号左侧最饱和区）最近匹配补全。
      // 后缀候选多（如 16 有 A16~H16），颜色是唯一决定性约束——图例色块
      // 印的就是该色号的实物色
      parenCount = elems
          .where((e) => e.code == null && e.dbgText.contains("("))
          .length;
      bareCount = elems
          .where((e) => e.code == null && !e.dbgText.contains("("))
          .length;
      if (parenCount >= 6 && bareCount > 0 && bareCount * 2 <= parenCount) {
        for (final e in swatchCodeCandidates(elems)) {
          final best = fixCodeBySwatch(palette, e.count!, e.rect, scaled);
          if (best == null) {
            continue;
          }
          final fixed = OcrElem(e.seq, e.rect, best, null);
          fixed.dbgText = "${e.dbgText}→${palette.colors[best].id}(色块补全)";
          elems.remove(e);
          elems.add(fixed);
        }
      }
      // 统一布局（new1 型图纸：图例所有条目格式一致）：由已读元素推断颗数
      // 在色号右侧同行还是正下方、模板距离与括号格式。探测提前到救援链
      // 之前——右侧布局的孤儿颗数选中要用它（幻影括号剥离前 "(53)" 读成
      // "1531" 无括号可循，只有布局能判定它是颗数）
      final layout = inferLegendLayout(elems);
      // 孤儿颗数二次 OCR：颗数（带括号或位于条下颗数位/右侧布局）的近旁
      // 都没有色号元素，说明该条目的色号整条被 ML Kit 吞掉。裁空隙小区
      // 放大后单独再识别（原图 + 反色两轮），读出的色号补回元素表参与
      // 最终配对
      await fixOrphanCountCodes(
        palette,
        elems,
        scaled,
        codeMap,
        tmpDir,
        orphanNotes,
        layout: layout,
      );
      // 孤儿色号重读（对称救援）：色号近旁无颗数 = 颗数被 ML Kit 整条吞掉
      //（wx1：B22 的 5、C21/F7/H22 的 6），裁色号下方小区放大重读补回
      await fixOrphanCodeCounts(
        elems,
        scaled,
        tmpDir,
      );
      // 网格盲区补全：行列都在而完全静默的格位（白底浅字整条吞掉，new1
      // C23）按格位重读补回色号；右侧布局的颗数由下方布局块的模板位补读
      await fixBlindGridCodes(
        elems,
        prep.bars,
        scaled,
        codeMap,
        tmpDir,
        orphanNotes,
      );
      if (layout != null) {
        // 括号格式成立时剥离首尾幻影 1（"(53)"→"1531"、"(39)"→"(391"
        // 型括号弧线误读，证据制：对侧括号在场或边缘字形窄于数字）；
        // 右侧布局中颗数被吞的条目按模板距离裁色号右侧小区重读（下方
        // 布局已由 fixOrphanCodeCounts 覆盖）
        applyPhantomParenStrip(elems, layout.parens, scaled);
        if (layout.countsRight) {
          await fixRightCountsByLayout(
            elems,
            scaled,
            tmpDir,
            layout,
          );
        }
      }
    }
    final paired = ocrFailed
        ? <(int, int)>[]
        : pairLegendOcr(elems).toList();
    // 颗数位判定：正上方有色号（配对轮 2 同款窗口）或正上方有检测色条
    // （条下窗口内）——位于颗数位的裸数字是颗数不是色号，变体兜底不得
    // 把它变幻影条目（wx1 行 2 最左的 82 曾被兜底成 B2）
    final heights = [
      for (final e in elems)
        if (e.rect.height > 0) e.rect.height,
    ];
    final avgH = heights.isEmpty ? 40.0 : heights.reduce((a, b) => a + b) / heights.length;
    bool inCountPosition(OcrElem e) {
      for (final c in elems) {
        if (c.code != null &&
            c.rect.bottom <= e.rect.top + avgH * 0.3 &&
            e.rect.top - c.rect.bottom <= avgH * 3.5 &&
            (c.rect.center.dx - e.rect.center.dx).abs() <= avgH * 1.5) {
          return true;
        }
      }
      for (final b in prep.bars) {
        final r = b.rect;
        if (e.rect.top >= r.bottom - r.height * 0.25 &&
            e.rect.top - r.bottom <= math.max(r.height, avgH) * 2.2 &&
            e.rect.center.dx >= r.left - e.rect.width &&
            e.rect.center.dx <= r.right + e.rect.width) {
          return true;
        }
      }
      return false;
    }

    // 配对后兜底：仍未消费的裸数字若命中混淆变体（掉字母色号 "81"→B1
    // 型），回落为色号条目（颗数 0，进未配色号提示让用户手填）。先配对
    // 后兜底的顺序保证 "H7 81" 型同行的 81 优先成为左侧色号的颗数，
    // 而不是被 B1 变体抢走导致 H7 悬空
    for (final e in [...elems]) {
      if (e.code != null || e.used || e.dbgText.contains("(")) {
        continue;
      }
      if (inCountPosition(e)) {
        continue; // 颗数位的裸数字（其色号在正上方被漏读）：留给空隙 OCR/手补
      }
      final t = e.dbgText.trim().toUpperCase().replaceAll(" ", "");
      final hit = t.length <= 4 ? codeMap[t] : null;
      if (hit == null) {
        continue;
      }
      final fixed = OcrElem(e.seq, e.rect, hit, null);
      fixed.dbgText = "${e.dbgText}→${palette.colors[hit].id}(变体兜底)";
      elems.remove(e);
      elems.add(fixed);
      paired.add((hit, 0));
    }
    // 色条颜色识别融合：检测高饱和色条 -> 条色最近色卡色号候选；OCR 元素
    // 按色条几何归属。补两类 OCR 盲区：色号印深色条内读不出的条目由颜色
    // 兜底、颗数在色条正下方超出按字高估计的配对窗口时由条几何归属补。
    // OCR 读出的色号/配对颗数一律优先于颜色猜测；无色条时结果不变
    final bars = prep.bars;
    final fused = fuseLegendBars(palette, elems, paired, bars);
    return LegendOcrRun(fused, orphanNotes, segFails);
  } catch (_) {
    return const LegendOcrRun(null, []);
  }
}
