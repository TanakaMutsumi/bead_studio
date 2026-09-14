import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/decode_image.dart';
import '../../core/legend_ocr.dart';
import '../../core/palette.dart';
import 'restore_painters.dart';

/// 【临时调试】图例 OCR 调试视图：喂给 ML Kit 的放大图 + 元素框 + 配对连线
///
/// 用于排查「为什么框选后读出来是错的」：
/// - 图本身不对（框错区域）-> 放大图一眼看出
/// - 字读错（OCR 误识别）-> 元素列表看原始文本
/// - 配对错（色号-颗数连错线）-> 红色连线直观可见
/// 正式版随调试功能一起移除。
void showOcrDebugSheet(BuildContext context, OcrDebugInfo dbg, BeadPalette palette) {
  final codes = dbg.elems.where((e) => e.code != null).length;
  final nums = dbg.elems.where((e) => e.count != null).length;
  final paired =
      dbg.elems.where((e) => e.code != null && e.pairedCount != null).length;
  final barRows = <_BarRow>[
    for (final b in dbg.bars)
      _BarRow(
        b,
        b.colorIdx == null
            ? "✗无候选"
            : "候选${palette.colors[b.colorIdx!].id}",
      ),
  ];
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.bug_report, size: 18, color: Colors.black54),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "OCR 调试 · ${dbg.source} · 色号$codes/颗数$nums/配上$paired对/色条${dbg.bars.length}",
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          // 【临时调试】框选区（原图坐标）：报坐标可精确复现同一次框选
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 16, 4),
            child: Text(
              "框选(原图坐标): x=${dbg.selX.round()} y=${dbg.selY.round()} · ${dbg.selW.round()}×${dbg.selH.round()}",
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ),
          // 放大图 1:1 显示（横向滚动看细节），元素框与连线直接用图坐标
          Expanded(
            flex: 6,
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: dbg.imgW.toDouble(),
                  height: dbg.imgH.toDouble(),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 放大图宽可达 ~4800，超 GLES 纹理上限（2048）会渲染成
                      // 一条带——超限时按解码目标宽限幅（等比，不放大小图）
                      Image.file(
                        File(dbg.imgPath),
                        fit: BoxFit.fill,
                        cacheWidth:
                            dbg.imgW > kDisplayMaxEdge ? kDisplayMaxEdge : null,
                      ),
                      CustomPaint(
                        painter: OcrDebugPainter(dbg.elems, dbg.bars),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 元素明细：原始文本 + 几何框 + 配对结果；色条明细附后
          // （颜色候选/归属情况，颜色融合排障用）
          Expanded(
            flex: 4,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              itemCount: dbg.elems.length + barRows.length,
              itemBuilder: (_, i) {
                if (i >= dbg.elems.length) {
                  final row = barRows[i - dbg.elems.length];
                  final b = row.bar;
                  final geo =
                      "(${b.rect.left.toInt()},${b.rect.top.toInt()} "
                      "${b.rect.width.toInt()}×${b.rect.height.toInt()})";
                  final code = b.codeElem == null
                      ? ""
                      : " · 色号${b.codeElem!.dbgText}";
                  final cnt = b.countElem == null
                      ? ""
                      : " · 颗数${b.countElem!.count}";
                  return Text(
                    "色条${row.label}$geo$code$cnt",
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.deepOrange,
                    ),
                  );
                }
                final e = dbg.elems[i];
                final geo = "(${e.rect.left.toInt()},${e.rect.top.toInt()} "
                    "${e.rect.width.toInt()}×${e.rect.height.toInt()})";
                return Text(
                  e.code != null
                      ? "色号「${e.dbgText}」$geo → ${e.pairedCount ?? "✗未配上"}"
                      : "颗数「${e.dbgText}」$geo ${e.used ? "已消费" : "未消费"}",
                  style: TextStyle(
                    fontSize: 11,
                    color: e.code != null
                        ? (e.pairedCount != null ? Colors.green : Colors.red)
                        : Colors.blue,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// 色条明细行（调试列表用）
class _BarRow {
  final LegendBar bar;
  final String label;
  _BarRow(this.bar, this.label);
}
