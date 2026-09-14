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
