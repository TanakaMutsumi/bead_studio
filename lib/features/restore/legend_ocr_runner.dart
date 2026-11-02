import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../core/legend_ocr.dart';
import '../../core/palette.dart';

/// 一次图例 OCR 编排的结果
class LegendOcrRun {
  /// 配对成功的 [(色号调色板索引, 颗数)] 按阅读顺序；异常/无配对为 null
  final List<(int, int)>? pairs;

  /// 【临时调试】调试快照（放大图 + 元素 + 框选区），异常路径也可能非空
  final OcrDebugInfo? debug;

  /// 色卡外色号（如 MARD 卡没有的 H7），调用方提示用户手工补
  final List<String> orphanNotes;

  /// 分段识别中失败的段数（0=全成；=段数=OCR 整体失败），上层可提示
  /// 「识别不完整建议重新框选」
  final int segFails;

  const LegendOcrRun(this.pairs, this.debug, this.orphanNotes,
      [this.segFails = 0]);
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
  const LegendPrepArgs(
    this.image,
    this.x,
    this.y,
    this.w,
    this.h,
    this.scale,
    this.segX0,
    this.segX1,
  );
}

/// [prepLegendOcr] 的结果（isolate 出参）
class LegendPrepResult {
  final img.Image scaled;

  ///< 全放大图（后续色块采样/空隙裁剪用）
  final List<LegendBar> bars;

  ///< 色条检测（在全放大图坐标系）
  final Uint8List debugPng;

  ///< 全放大图 PNG（调试快照/调试面板底图）
  final List<Uint8List> segPngs;

  ///< 各段 PNG（喂 ML Kit）
  LegendPrepResult(this.scaled, this.bars, this.debugPng, this.segPngs);
}

/// 裁剪+放大+色条检测+PNG 编码（顶层函数供 compute isolate 调用）
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
  final debugPng = img.encodePng(scaled);
  final segPngs = <Uint8List>[
    for (var i = 0; i < a.segX0.length; i++)
      img.encodePng(
        img.copyCrop(
          scaled,
          x: a.segX0[i],
          y: 0,
          width: a.segX1[i] - a.segX0[i],
          height: scaled.height,
        ),
      ),
  ];
  return LegendPrepResult(scaled, bars, debugPng, segPngs);
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
  var dbgPath = ""; // 【临时调试】异常路径已产出的放大图路径（写盘成功后才有值）
  var dbgW = 0;
  var dbgH = 0;
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

    final tmp = File(
      "${(await getTemporaryDirectory()).path}/legend_ocr.png",
    );
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
      ),
    );
    await tmp.writeAsBytes(prep.debugPng);
    dbgPath = tmp.path; // 【临时调试】记下放大图，异常路径的快照也要能看图
    dbgW = prep.scaled.width;
    dbgH = prep.scaled.height;
    final scaled = prep.scaled;

    // 精确 + 混淆变体查找表（图例 OCR 与格子 OCR 共用）
    final codeMap = buildCodeMap(palette);

    // 收集全部色号/颗数元素（带几何框：颗数可能在色号下一行，纯行内序配不上）；
    // 原图轮/反色轮共用同一收集逻辑；xOff 把段内坐标换算回全放大图坐标
    List<OcrElem> collect(RecognizedText result, int seqStart, double xOff) {
      final out = <OcrElem>[];
      var seq = seqStart;
      for (final block in result.blocks) {
        for (final line in block.lines) {
          for (final element in line.elements) {
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
                final bb = element.boundingBox;
                final e = OcrElem(
                  seq++,
                  Rect.fromLTRB(
                    bb.left + xOff,
                    bb.top,
                    bb.right + xOff,
                    bb.bottom,
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
              final bb = element.boundingBox;
              final e = OcrElem(
                seq++,
                Rect.fromLTRB(
                  bb.left + xOff,
                  bb.top,
                  bb.right + xOff,
                  bb.bottom,
                ),
                null,
                n,
              );
              e.dbgText = element.text; // 【临时调试】保留原始文本
              out.add(e);
            }
          }
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
      for (var i = 0; i < prep.segPngs.length; i++) {
        try {
          // 段文件独立命名：调试全图固定用 legend_ocr.png，覆写会让调试
          // 面板出现「末段小图 + 全图坐标」的静默错位
          final segFile = File(
            "${tmp.parent.path}/legend_ocr_seg$i.png",
          );
          await segFile.writeAsBytes(prep.segPngs[i]);
          final recognized = await recognizer.processImage(
            InputImage.fromFilePath(segFile.path),
          );
          final got = collect(recognized, seq, segX0[i].toDouble());
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
    final ocrFailed = segFails >= prep.segPngs.length;
    final orphanNotes = <String>[];
    var fixedCount = 0,
        gapFixed = 0,
        belowFixed = 0,
        gridFixed = 0,
        rightFixed = 0,
        parenStripped = 0,
        parenCount = 0,
        bareCount = 0;
    var layoutNote = "";
    final belowDbg = <String>[]; // 【临时调试】下方/右侧 OCR 救援排障行
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
          fixedCount++;
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
      gapFixed = await fixOrphanCountCodes(
        palette,
        elems,
        scaled,
        codeMap,
        tmp.parent.path,
        orphanNotes,
        layout: layout,
        dbg: belowDbg,
      );
      // 孤儿色号重读（对称救援）：色号近旁无颗数 = 颗数被 ML Kit 整条吞掉
      //（wx1：B22 的 5、C21/F7/H22 的 6），裁色号下方小区放大重读补回
      belowFixed = await fixOrphanCodeCounts(
        elems,
        scaled,
        tmp.parent.path,
        dbg: belowDbg,
      );
      // 网格盲区补全：行列都在而完全静默的格位（白底浅字整条吞掉，new1
      // C23）按格位重读补回色号；右侧布局的颗数由下方布局块的模板位补读
      gridFixed = await fixBlindGridCodes(
        elems,
        prep.bars,
        scaled,
        codeMap,
        tmp.parent.path,
        orphanNotes,
        dbg: belowDbg,
      );
      if (layout != null) {
        // 括号格式成立时剥离首尾幻影 1（"(53)"→"1531"、"(39)"→"(391"
        // 型括号弧线误读，证据制：对侧括号在场或边缘字形窄于数字）；
        // 右侧布局中颗数被吞的条目按模板距离裁色号右侧小区重读（下方
        // 布局已由 fixOrphanCodeCounts 覆盖）
        parenStripped = applyPhantomParenStrip(elems, layout.parens, scaled);
        if (layout.countsRight) {
          rightFixed = await fixRightCountsByLayout(
            elems,
            scaled,
            tmp.parent.path,
            layout,
            dbg: belowDbg,
          );
        }
        layoutNote =
            " 布局(${layout.countsRight ? "右" : "下"}dx${layout.dx.toInt()}${layout.parens ? "括号" : ""})";
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
    // 【临时调试】保存本次 OCR 快照（放大图 + 元素 + 色条 + 框选区），正式版移除
    final debug = OcrDebugInfo(
      ocrFailed
          ? "$source（OCR异常）"
          : segFails > 0
              ? "$source（段$segFails/${prep.segPngs.length}失败）"
              : source,
      tmp.path,
      scaled.width,
      scaled.height,
      elems,
      rx,
      ry,
      rw,
      rh,
      bars,
    );
    // 【临时调试】元素明细同时打 logcat 与写文件（个别环境 logcat 收不到
    // flutter tag，文件可 adb pull，像素判读调试面板太费劲），正式版移除
    final dbgLines = <String>[
      "框选($source) $rx,$ry ${rw}x$rh 段${prep.segPngs.length}(失败$segFails, 去重${tagged.length - elems.length}) elems=${elems.length}(色块补全$fixedCount, 空隙OCR$gapFixed, 下方OCR$belowFixed, 盲格OCR$gridFixed, 右侧OCR$rightFixed, 括号剥$parenStripped, 括号颗数$parenCount/裸数字$bareCount) 色条${bars.length}条 img=${scaled.width}x${scaled.height}${ocrFailed ? " OCR异常" : ""}$layoutNote"
          "${orphanNotes.isEmpty ? "" : " 色卡外色号=[${orphanNotes.toSet().join(" ")}]"}",
      ...belowDbg, // 【临时调试】下方 OCR 救援排障行（正式版随 dbg 参数移除）
    ];
    for (final e in elems) {
      final kind = e.code != null
          ? "code:${palette.colors[e.code!].id}"
          : "count:${e.count}";
      dbgLines.add(
        "elem $kind raw=\"${e.dbgText}\" "
        // 小数 rect：剥离/连通域决策对亚像素框敏感（round 差 1px 即翻转），
        // 整数截断的日志无法在宿主机精确复现设备端行为
        "rect=(${e.rect.left.toStringAsFixed(1)},${e.rect.top.toStringAsFixed(1)} "
        "${e.rect.width.toStringAsFixed(1)}x${e.rect.height.toStringAsFixed(1)})",
      );
    }
    for (final b in bars) {
      final cand = b.colorIdx == null ? "✗" : palette.colors[b.colorIdx!].id;
      final ce = b.codeElem == null
          ? ""
          : " 色号:${palette.colors[b.codeElem!.code!].id}";
      final cn = b.countElem == null ? "" : " 颗数:${b.countElem!.count}";
      dbgLines.add(
        "bar 颜色候选$cand rgb=(${b.r},${b.g},${b.b}) "
        "rect=(${b.rect.left.toInt()},${b.rect.top.toInt()} "
        "${b.rect.width.toInt()}x${b.rect.height.toInt()})$ce$cn",
      );
    }
    final unpaired = elems
        .where((e) => e.code != null && e.pairedCount == null)
        .map((e) => "${palette.colors[e.code!].id}(${e.dbgText})")
        .join(" ");
    dbgLines.add(
      "result=${fused.length}对 未配色号=[${unpaired.isEmpty ? "无" : unpaired}] ${[
        for (final (idx, n) in fused) "${palette.colors[idx].id}=$n"
      ].join(" ")}",
    );
    for (final l in dbgLines) {
      debugPrint("【临时调试】$l");
    }
    File("${tmp.parent.path}/legend_ocr_log.txt").writeAsStringSync(
      dbgLines.join("\n"),
    );
    return LegendOcrRun(fused, debug, orphanNotes, segFails);
  } catch (_) {
    // 【临时调试】识别抛异常也记快照（source 标"异常"）：调试视图能看到放大图 + 0 个
    // 元素——比入口直接消失更有排障价值；放大图都没产出（crop 就失败）则保持 null
    if (dbgPath.isNotEmpty) {
      final debug = OcrDebugInfo(
        "$source（异常）",
        dbgPath,
        dbgW,
        dbgH,
        const [],
        rx,
        ry,
        rw,
        rh,
      );
      return LegendOcrRun(null, debug, const []);
    }
    return const LegendOcrRun(null, null, []);
  }
}
