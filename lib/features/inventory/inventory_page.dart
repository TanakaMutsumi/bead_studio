import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/inventory_store.dart';
import '../../core/palette.dart';

/// 珠子库存管理页：每色库存颗数的清点/入库/出库，供缺料校验用
class InventoryPage extends StatefulWidget {
  final BeadPalette palette;

  const InventoryPage({super.key, required this.palette});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  Map<String, int> _counts = {};
  var _loading = true;
  String _search = "";

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _loading = false;
      return;
    }
    _reload();
  }

  Future<void> _reload() async {
    final counts = await InventoryStore.read();
    if (!mounted) {
      return;
    }
    setState(() {
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _save() => InventoryStore.save(_counts);

  /// 快捷增减（+100 / -100 / 自定义）
  Future<void> _adjust(String id, int delta) async {
    setState(() => _counts[id] = (_counts[id] ?? 0) + delta);
    await _save();
  }

  /// 点行弹窗直接清点设定
  Future<void> _setCount(BeadColor c) async {
    final ctrl = TextEditingController(text: "${_counts[c.id] ?? 0}");
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("清点 ${c.id} ${c.name}"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: "库存颗数",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text),
            child: const Text("确定"),
          ),
        ],
      ),
    );
    final n = int.tryParse(input ?? "");
    if (n == null || n < 0) {
      return;
    }
    setState(() => _counts[c.id] = n);
    await _save();
  }

  Future<void> _batchSet() async {
    final ctrl = TextEditingController(text: "1000");
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("批量入库"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: "全部颜色设为该颗数",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text),
            child: const Text("确定"),
          ),
        ],
      ),
    );
    final n = int.tryParse(input ?? "");
    if (n == null || n < 0) {
      return;
    }
    setState(() {
      for (final c in widget.palette.colors) {
        _counts[c.id] = n;
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text("珠子库存")),
        body: const Center(child: Text("网页版暂不支持本地库存")),
      );
    }
    final colors = widget.palette.colors
        .where(
          (c) =>
              _search.isEmpty ||
              c.id.contains(_search) ||
              c.name.contains(_search),
        )
        .toList();
    final total = _counts.values.fold(0, (a, b) => a + b);

    return Scaffold(
      appBar: AppBar(
        title: Text("珠子库存 · 共 $total 颗"),
        actions: [
          IconButton(
            onPressed: _batchSet,
            icon: const Icon(Icons.library_add),
            tooltip: "批量入库",
          ),
          IconButton(
            onPressed: () async {
              await InventoryStore.clear();
              _reload();
            },
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: "清空库存",
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    onChanged: (s) => setState(() => _search = s.trim()),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: "搜索色号 / 名称",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: colors.length,
                    itemBuilder: (context, i) {
                      final c = colors[i];
                      final n = _counts[c.id] ?? 0;
                      return ListTile(
                        onTap: () => _setCount(c),
                        leading: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Color.fromARGB(255, c.r, c.g, c.b),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.black26),
                          ),
                        ),
                        title: Text("${c.id} ${c.name}"),
                        subtitle: Text(
                          "点按清点 · 现有 $n 颗",
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: n >= 100
                                  ? () => _adjust(c.id, -100)
                                  : null,
                              icon: const Icon(Icons.remove_circle_outline),
                              tooltip: "-100",
                            ),
                            SizedBox(
                              width: 56,
                              child: Text(
                                "$n",
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => _adjust(c.id, 100),
                              icon: const Icon(Icons.add_circle_outline),
                              tooltip: "+100",
                            ),
                          ],
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
