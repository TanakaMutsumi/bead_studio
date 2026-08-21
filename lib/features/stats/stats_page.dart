import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/pattern_model.dart';

/// 用料统计页：按数量降序列出每种颜色的珠子用量
class StatsPage extends StatelessWidget {
  final PatternModel model;
  final BeadPalette palette;

  const StatsPage({super.key, required this.model, required this.palette});

  @override
  Widget build(BuildContext context) {
    final counts = model.countByColor();
    final entries = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final totalBeads = counts.values.fold(0, (a, b) => a + b);

    return Scaffold(
      appBar: AppBar(title: const Text("用料统计")),
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
                  _SummaryCell(label: "网格", value: "${model.width}×${model.height}"),
                ],
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text("画布为空"))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final c = e.key < palette.colors.length ? palette.colors[e.key] : null;
                      final color = c != null ? Color.fromARGB(255, c.r, c.g, c.b) : Colors.grey;
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
                        title: Text(c != null ? "${c.id} ${c.name}" : "#${e.key}"),
                        trailing: Text(
                          "${e.value} 颗",
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
