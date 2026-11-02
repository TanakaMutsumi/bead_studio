import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_snack_bar.dart';
import '../../core/file_saver.dart';
import '../../core/inventory_store.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';
import '../inventory/inventory_page.dart';
import '../restore/restore_types.dart';

/// 用料统计页：按选定模式列出每种颜色的珠子用量（默认颗数降序；
/// 作品携带图例核对步选定的排序时沿用该排序）
/// + 库存校验模式（需要 vs 库存，缺口标红）+ 采购单 CSV 导出
class StatsPage extends StatefulWidget {
  final PatternModel model;
  final BeadPalette palette;
  final String? sortMode;

  ///< 排序模式名（LegendSort.name；null = 默认颗数降序）

  const StatsPage({
    super.key,
    required this.model,
    required this.palette,
    this.sortMode,
  });

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  Map<String, int>? _inventory;

  ///< null = 未进入校验模式；加载中为空表

  bool get _checkMode => _inventory != null;

  /// 读取库存进入校验模式（web 不可用）
  Future<void> _toggleCheck() async {
    if (kIsWeb) {
      AppSnackBar.show(context, "网页版暂不支持本地库存");
      return;
    }
    if (_checkMode) {
      setState(() => _inventory = null);
      return;
    }
    setState(() => _inventory = {});
    final inv = await InventoryStore.read();
    if (mounted) {
      setState(() => _inventory = inv);
    }
  }

  /// 导出缺料采购单 CSV（仅校验模式下有缺口时可用）
  Future<void> _exportShoppingList(List<_StatRow> rows) async {
    final shortages =
        rows.where((r) => r.color != null && r.shortage > 0).toList();
    if (shortages.isEmpty) {
      AppSnackBar.show(context, "库存充足，无需采购");
      return;
    }
    final buf = StringBuffer("色号,名称,需要,库存,缺口\n");
    for (final r in shortages) {
      buf.writeln(
        "${r.color!.id},${r.color!.name},${r.needed},${r.stocked},${r.shortage}",
      );
    }
    final bytes = utf8.encode("﻿${buf.toString()}"); // BOM：Excel 中文不乱码
    final name =
        "bead_shopping_list_${DateTime.now().millisecondsSinceEpoch}.csv";

    if (kIsWeb) {
      await downloadBytes(bytes, name);
      if (mounted) {
        AppSnackBar.show(context, "已导出采购单");
      }
      return;
    }
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory("${root.path}${Platform.pathSeparator}bead_exports")
      ..createSync(recursive: true);
    final file = File("${dir.path}${Platform.pathSeparator}$name");
    await file.writeAsBytes(bytes);
    if (mounted) {
      AppSnackBar.show(context, "采购单已导出：${file.path}");
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = widget.model.countByColor();
    // 排序：默认（含旧作品 null）颗数降序；带 meta.sortMode 时沿用图例
    // 核对步的选择（position = map 插入序 = 图格扫描序；"reading" 是
    // 位置序的旧名，兼容旧作品存档）
    final mode = widget.sortMode == "reading"
        ? LegendSort.position
        : LegendSort.values.asNameMap()[widget.sortMode ?? ""];
    final entries = counts.entries.toList();
    if (mode == null || mode == LegendSort.countDesc) {
      entries.sort((a, b) => b.value.compareTo(a.value));
    } else if (mode == LegendSort.countAsc) {
      entries.sort((a, b) => a.value.compareTo(b.value));
    } else if (mode == LegendSort.code) {
      entries.sort((a, b) => a.key.compareTo(b.key));
    } // position：保持插入序（首个出现顺序）
    final totalBeads = counts.values.fold(0, (a, b) => a + b);
    final inv = _inventory;
    final rows = [
      for (final e in entries)
        _StatRow(
          color: e.key < widget.palette.colors.length
              ? widget.palette.colors[e.key]
              : null,
          index: e.key,
          needed: e.value,
          stocked: inv?[(e.key < widget.palette.colors.length
                  ? widget.palette.colors[e.key].id
                  : "")] ??
              0,
        ),
    ];
    final totalShortage = rows.fold(0, (a, r) => a + r.shortage);

    return Scaffold(
      appBar: AppBar(
        title: const Text("用料统计"),
        actions: [
          IconButton(
            onPressed: _toggleCheck,
            icon: Icon(
              _checkMode ? Icons.checkroom : Icons.inventory_2_outlined,
            ),
            tooltip: _checkMode ? "退出库存校验" : "库存校验",
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => InventoryPage(palette: widget.palette),
              ),
            ),
            icon: const Icon(Icons.warehouse_outlined),
            tooltip: "库存管理",
          ),
        ],
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _SummaryCell(label: "总豆数", value: "$totalBeads"),
                  _SummaryCell(label: "用色数", value: "${entries.length}"),
                  _SummaryCell(
                    label: "网格",
                    value: "${widget.model.width}×${widget.model.height}",
                  ),
                  if (_checkMode)
                    _SummaryCell(
                      label: "缺料",
                      value: totalShortage > 0 ? "$totalShortage" : "无",
                      highlight: totalShortage > 0,
                    ),
                ],
              ),
            ),
          ),
          if (_checkMode && totalShortage > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _exportShoppingList(rows),
                  icon: const Icon(Icons.shopping_cart_outlined),
                  label: Text("导出采购单（缺 $totalShortage 颗）"),
                ),
              ),
            ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text("画布为空"))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => _buildRow(rows[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(_StatRow r) {
    final c = r.color;
    final color = c != null ? Color.fromARGB(255, c.r, c.g, c.b) : Colors.grey;
    final invLoaded = _inventory != null;

    return ListTile(
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.black26),
        ),
      ),
      title: Text(c != null ? "${c.id} ${c.name}" : "#${r.index}"),
      trailing: _checkMode
          ? (invLoaded
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      "需 ${r.needed} / 存 ${r.stocked}",
                      style: TextStyle(
                        fontSize: 13,
                        color: r.shortage > 0 ? Colors.red : Colors.black87,
                        fontWeight: r.shortage > 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    Text(
                      r.shortage > 0 ? "缺 ${r.shortage} 颗" : "充足",
                      style: TextStyle(
                        fontSize: 11,
                        color: r.shortage > 0 ? Colors.red : Colors.green,
                      ),
                    ),
                  ],
                )
              : const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ))
          : Text(
              "${r.needed} 颗",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
    );
  }
}

/// 单行统计（校验模式含库存/缺口）
class _StatRow {
  final BeadColor? color;
  final int index;

  ///< 调色板索引（color 为 null 时兜底显示）
  final int needed;
  final int stocked;

  int get shortage => needed > stocked ? needed - stocked : 0;

  const _StatRow({
    required this.color,
    required this.index,
    required this.needed,
    required this.stocked,
  });
}

class _SummaryCell extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  ///< 缺料等警示标红

  const _SummaryCell({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: highlight ? Colors.red : null,
                fontWeight: highlight ? FontWeight.bold : null,
              ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
