import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';
import '../../data/demo_palette.dart';
import '../stats/stats_page.dart';
import 'grid_painter.dart';

enum _Tool { brush, eraser, bucket }

/// 编辑器：网格画布 + 画笔/橡皮/油漆桶 + 撤销 + 草稿 + 导出
class EditorPage extends StatefulWidget {
  final PatternModel model;
  final BeadPalette palette;

  const EditorPage({super.key, required this.model, required this.palette});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  static const _maxUndo = 50;

  late final PatternModel _model;
  final _revision = ValueNotifier<int>(0); ///< 网格内容版本号，驱动画布重绘
  final List<List<int>> _undoStack = [];
  var _tool = _Tool.brush;
  var _currentColor = 9; ///< 默认选中红色（显眼）

  @override
  void initState() {
    super.initState();
    _model = widget.model;
  }

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }

  void _pushUndo() {
    _undoStack.add(_model.copyGrid());
    if (_undoStack.length > _maxUndo) {
      _undoStack.removeAt(0);
    }
  }

  void _applyAt(Offset local, Size canvasSize, {required bool isStart}) {
    final cell = canvasSize.width / _model.width;
    final x = (local.dx ~/ cell).clamp(0, _model.width - 1);
    final y = (local.dy ~/ cell).clamp(0, _model.height - 1);

    if (isStart) {
      _pushUndo();
    }
    switch (_tool) {
      case _Tool.brush:
        _model.setCell(x, y, _currentColor);
        break;
      case _Tool.eraser:
        _model.setCell(x, y, -1);
        break;
      case _Tool.bucket:
        if (isStart) {
          _model.floodFill(x, y, _currentColor);
        }
        break;
    }
    _revision.value++;
  }

  void _undo() {
    if (_undoStack.isEmpty) {
      return;
    }
    setState(() {
      final g = _undoStack.removeLast();
      for (var i = 0; i < g.length; i++) {
        _model.grid[i] = g[i];
      }
      _revision.value++;
    });
  }

  Future<void> _saveDraft() async {
    final file = await DraftStore.save(_model);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("草稿已保存：${file.path.split(Platform.pathSeparator).last}")));
    }
  }

  Future<void> _exportPng() async {
    final bytes = _model.exportPng(cellPixels: 24, palette: widget.palette);
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory("${root.path}${Platform.pathSeparator}bead_exports")..createSync(recursive: true);
    final file = File("${dir.path}${Platform.pathSeparator}pattern_${DateTime.now().millisecondsSinceEpoch}.png");
    await file.writeAsBytes(bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已导出：${file.path}")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("编辑 ${_model.width}×${_model.height}"),
        actions: [
          IconButton(
            onPressed: _undoStack.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo),
            tooltip: "撤销",
          ),
          IconButton(onPressed: _saveDraft, icon: const Icon(Icons.save_outlined), tooltip: "保存草稿"),
          IconButton(onPressed: _exportPng, icon: const Icon(Icons.download), tooltip: "导出PNG"),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => StatsPage(model: _model, palette: widget.palette)),
            ),
            icon: const Icon(Icons.list_alt),
            tooltip: "用料统计",
          ),
        ],
      ),
      body: Column(
        children: [
          // 工具栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<_Tool>(
              segments: const [
                ButtonSegment(value: _Tool.brush, icon: Icon(Icons.brush), label: Text("画笔")),
                ButtonSegment(value: _Tool.eraser, icon: Icon(Icons.delete_outline), label: Text("橡皮")),
                ButtonSegment(value: _Tool.bucket, icon: Icon(Icons.format_color_fill), label: Text("油漆桶")),
              ],
              selected: {_tool},
              onSelectionChanged: (sel) => setState(() => _tool = sel.first),
            ),
          ),

          // 画布
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final side = constraints.biggest.shortestSide * 0.96;
                  final canvasSize = Size.square(side);
                  return GestureDetector(
                    onPanDown: (d) => _applyAt(d.localPosition, canvasSize, isStart: true),
                    onPanUpdate: (d) => _applyAt(d.localPosition, canvasSize, isStart: false),
                    child: CustomPaint(
                      size: canvasSize,
                      painter: GridPainter(
                        model: _model,
                        palette: widget.palette,
                        selectedColorIndex: _currentColor,
                        repaint: _revision,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // 颜色选择条
          SizedBox(
            height: 68,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              itemCount: widget.palette.colors.length,
              itemBuilder: (context, i) {
                final c = widget.palette.colors[i];
                final selected = i == _currentColor;
                return GestureDetector(
                  onTap: () => setState(() {
                    _currentColor = i;
                    if (_tool == _Tool.eraser) {
                      _tool = _Tool.brush;
                    }
                  }),
                  child: Container(
                    width: 48,
                    height: 48,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Color.fromARGB(255, c.r, c.g, c.b),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? Colors.blue : Colors.black26,
                        width: selected ? 3 : 1,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        c.id.replaceFirst("P", ""),
                        style: TextStyle(
                          fontSize: 11,
                          color: _isLightColor(c) ? Colors.black54 : Colors.white70,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 粗略判断浅色（决定色块上文字颜色）
  bool _isLightColor(BeadColor c) => (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) > 150;
}
