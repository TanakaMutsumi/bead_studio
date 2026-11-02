import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/palette.dart';
import 'placed_work.dart';

/// 豆板豆数统计（从页面抽出，作品列表显式传入）

/// 板上全部作品的豆数加和：色号 -> 颗数（跨作品同色号合并）
Map<String, int> beadStats(List<PlacedWork> works) {
  final stats = <String, int>{};
  for (final w in works) {
    final m = w.model;
    m.countByColor().forEach((v, n) {
      final id = v < m.paletteIds.length ? m.paletteIds[v] : "?$v";
      stats[id] = (stats[id] ?? 0) + n;
    });
  }
  return stats;
}

/// 板上是否有作品真压豆重叠：豆级判定——同一板格被两件作品同时占豆
///（两边都非空格）才算冲突；矩形相交但交叠处是空豆的不碍事（开始
/// 拼豆放行）。画布浅红标注同一口径，只标真冲突格
bool boardHasOverlap(List<PlacedWork> works) {
  for (var i = 0; i < works.length; i++) {
    for (var j = i + 1; j < works.length; j++) {
      final a = works[i], b = works[j];
      final x0 = math.max(a.ox, b.ox);
      final y0 = math.max(a.oy, b.oy);
      final x1 = math.min(a.ox + a.model.width, b.ox + b.model.width);
      final y1 = math.min(a.oy + a.model.height, b.oy + b.model.height);
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final av = a.model.grid[(y - a.oy) * a.model.width + (x - a.ox)];
          final bv = b.model.grid[(y - b.oy) * b.model.width + (x - b.ox)];
          if (av >= 0 && bv >= 0) {
            return true;
          }
        }
      }
    }
  }
  return false;
}

/// 色号查显示颜色（任一含该色的作品调色板）
BeadColor? colorOf(List<PlacedWork> works, String id) {
  for (final w in works) {
    final c = w.palette.byId(id);
    if (c != null) {
      return c;
    }
  }
  return null;
}

/// 豆数统计明细（BottomSheet：色块 + 色号/名 + 颗数，按颗数降序）
Future<void> showBeadStatsSheet(
  BuildContext context, {
  required List<PlacedWork> works,
}) async {
  if (works.isEmpty) {
    AppSnackBar.show(context, "板上还没有作品");
    return;
  }
  final stats = beadStats(works);
  final total = stats.values.fold(0, (a, b) => a + b);
  final entries = stats.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  await showModalBottomSheet<void>(
    context: context,
    builder: (sctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              "豆数统计 · ${works.length} 件作品 · ${stats.length} 种色 · 共 $total 颗",
              style: Theme.of(sctx).textTheme.titleMedium,
            ),
          ),
          for (final e in entries)
            ListTile(
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colorOf(works, e.key) != null
                      ? Color.fromARGB(
                          255,
                          colorOf(works, e.key)!.r,
                          colorOf(works, e.key)!.g,
                          colorOf(works, e.key)!.b,
                        )
                      : Colors.grey,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.black26),
                ),
              ),
              title: Text(
                "${e.key} ${colorOf(works, e.key)?.name ?? ""}".trim(),
              ),
              trailing: Text("${e.value} 颗"),
            ),
        ],
      ),
    ),
  );
}
