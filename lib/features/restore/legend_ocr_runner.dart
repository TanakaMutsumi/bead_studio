import 'dart:io';

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

  const LegendOcrRun(this.pairs, this.debug, this.orphanNotes);
}

/// OCR 图例选区 -> [(印刷色号调色板索引, 印刷颗数)] 按阅读顺序
///
/// 图纸图例每条目 = 色块 + 色号 + 颗数（印刷数字）；颗数有时跟在色号右侧同行，
/// 有时印在色号/色块正下方，色号也可能直接印在色块内（深底白字）。裁剪选区
/// 放大喂 ML Kit，收集全部色号/颗数 element（带几何框）走 [pairLegendOcr]
/// 两轮配对，再与 [detectLegendBars]/[fuseLegendBars] 色条颜色识别融合
/// （色号被 OCR 吞掉的条目由条色兜底、条下颗数按条几何归属）。
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
  var dbgPath = ""; // 【临时调试】异常路径已产出的放大图路径（crop/写盘成功后才有值）
  var dbgW = 0;
  var dbgH = 0;
  try {
    final crop = img.copyCrop(
      image,
      x: rx.toInt(),
      y: ry.toInt(),
      width: rw.toInt(),
      height: rh.toInt(),
    );
    // 小字放大提高识别率：按高度放大到 ~960px（数字高 ~120px+）。
    // 固定 ×2/×3 在小字图例（色号字高 ~20 原图像素）下分辨率不足，
    // 实测 480 目标时第三行 5 条目只读出 3 个色号（2026-08-27 pic4），
    // 提到 960 后字高 ~74px 识别稳定；同时按宽度 cap 防超 ML Kit 输入上限
    var scale = (960 / rh).clamp(3.0, 8.0);
    // 长边（宽或高）cap 防超 ML Kit 输入上限：竖长条图例按高度放大曾到
    // 4479px，processImage 直接抛异常整链回退量化（test_pic5 案例）；
    // 横条按宽 cap 与原逻辑一致
    final cap = 3800 / (rw > rh ? rw : rh);
    if (scale > cap) {
      scale = cap;
    }
    final scaled = img.copyResize(crop, width: (crop.width * scale).round());
    final tmp = File(
      "${(await getTemporaryDirectory()).path}/legend_ocr.png",
    );
    await tmp.writeAsBytes(img.encodePng(scaled));
    dbgPath = tmp.path; // 【临时调试】记下放大图，异常路径的快照也要能看图
    dbgW = scaled.width;
    dbgH = scaled.height;

    // 精确 + 混淆变体查找表（图例 OCR 与格子 OCR 共用）
    final codeMap = buildCodeMap(palette);

    // 收集全部色号/颗数元素（带几何框：颗数可能在色号下一行，纯行内序配不上）；
    // 原图轮/反色轮共用同一收集逻辑
    List<OcrElem> collect(RecognizedText result, int seqStart) {
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
                final e = OcrElem(seq++, element.boundingBox, code, null);
                e.dbgText = element.text; // 【临时调试】保留原始文本
                out.add(e);
                continue;
              }
            }
            final n = parseCountText(element.text);
            if (n != null) {
              final e = OcrElem(seq++, element.boundingBox, null, n);
              e.dbgText = element.text; // 【临时调试】保留原始文本
              out.add(e);
            }
          }
        }
      }
      return out;
    }

    final elems = <OcrElem>[];
    final orphanNotes = <String>[];
    var fixedCount = 0, gapFixed = 0, parenCount = 0, bareCount = 0;
    var ocrFailed = false;
    try {
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(tmp.path),
      );
      await recognizer.close();
      elems.addAll(collect(recognized, 0));
      // 掉字母色号修复：深底反白/浅底浅字色号被 ML Kit 吞掉首字母，读成
      // 无括号纯数字 count（真颗数全部带括号 (N)）。当图内带括号颗数占绝对
      // 多数（≥6 且 ≥2×无括号数）时，无括号纯数字判定为掉字母色号：按数字
      // 后缀取色卡候选，用条目色块颜色（色号左侧最饱和区）最近匹配补全。
      // 后缀候选多（如 16 有 A16~H16），颜色是唯一决定性约束——图例色块
      // 印的就是该色号的实物色。
      parenCount = elems
          .where((e) => e.code == null && e.dbgText.contains("("))
          .length;
      bareCount = elems
          .where((e) => e.code == null && !e.dbgText.contains("("))
          .length;
      if (parenCount >= 6 && bareCount > 0 && bareCount * 2 <= parenCount) {
        final bare = elems
            .where((e) => e.code == null && !e.dbgText.contains("("))
            .toList();
        for (final e in bare) {
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
      // 孤儿颗数二次 OCR：带括号颗数的左侧同行/正上方近旁都没有色号元素，
      // 说明该条目的色号整条被 ML Kit 吞掉（深底白字识别不稳定；H7 案例：
      // (343) 正常读出而 H7 消失）。裁「左邻元素右缘 -> 颗数左缘」的空隙
      // 小区放大后单独再识别（原图 + 反色两轮），读出的色号补回元素表参与
      // 最终配对
      gapFixed = await fixOrphanCountCodes(
        palette,
        elems,
        scaled,
        codeMap,
        tmp.parent.path,
        orphanNotes,
      );
    } catch (_) {
      // ML Kit 抛异常（如输入超限）或修复环节出错：OCR 无元素，色条颜色
      // 融合仍可产清单，不再整链作废（test_pic5 竖排图例案例）
      ocrFailed = true;
    }
    final paired = ocrFailed
        ? <(int, int)>[]
        : pairLegendOcr(elems).toList();
    // 配对后兜底：仍未消费的裸数字若命中混淆变体（掉字母色号 "81"→B1
    // 型），回落为色号条目（颗数 0，进未配色号提示让用户手填）。先配对
    // 后兜底的顺序保证 "H7 81" 型同行的 81 优先成为左侧色号的颗数，
    // 而不是被 B1 变体抢走导致 H7 悬空
    for (final e in [...elems]) {
      if (e.code != null || e.used || e.dbgText.contains("(")) {
        continue;
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
    final bars = detectLegendBars(scaled);
    final fused = fuseLegendBars(palette, elems, paired, bars);
    // 【临时调试】保存本次 OCR 快照（放大图 + 元素 + 色条 + 框选区），正式版移除
    final debug = OcrDebugInfo(
      ocrFailed ? "$source（OCR异常）" : source,
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
      "框选($source) $rx,$ry ${rw}x$rh elems=${elems.length}(色块补全$fixedCount, 空隙OCR$gapFixed, 括号颗数$parenCount/裸数字$bareCount) 色条${bars.length}条 img=${scaled.width}x${scaled.height}${ocrFailed ? " OCR异常" : ""}"
          "${orphanNotes.isEmpty ? "" : " 色卡外色号=[${orphanNotes.toSet().join(" ")}]"}",
    ];
    for (final e in elems) {
      final kind = e.code != null
          ? "code:${palette.colors[e.code!].id}"
          : "count:${e.count}";
      dbgLines.add(
        "elem $kind raw=\"${e.dbgText}\" "
        "rect=(${e.rect.left.toInt()},${e.rect.top.toInt()} "
        "${e.rect.width.toInt()}x${e.rect.height.toInt()})",
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
    return LegendOcrRun(fused, debug, orphanNotes);
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
