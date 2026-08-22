import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/draft_store.dart';
import '../../core/file_saver.dart';
import '../../core/grid_ops.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';
import '../../core/quantizer.dart';
import '../stats/stats_page.dart';
import 'grid_painter.dart';
import 'sheets.dart';

/// 工具类型
enum _Tool { brush, eraser, bucket, eyedropper, select }

/// 撤销快照（含尺寸：改尺寸/旋转后网格长度会变）
class _Snapshot {
  final List<int> grid;
  final int width;
  final int height;

  const _Snapshot(this.grid, this.width, this.height);
}

/// 编辑器：网格画布 + 五工具（画笔/橡皮/油漆桶/吸管/选区）+ 撤销重做
/// + 变换/降噪/限色/换色 + 草稿 + 导出
class EditorPage extends StatefulWidget {
  final PatternModel model;
  final BeadPalette palette;

  const EditorPage({super.key, required this.model, required this.palette});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  static const _maxUndo = 50;
  static const _brushSizes = [1, 2, 3, 5];

  late PatternModel _model;
  final _revision = ValueNotifier<int>(0); ///< 网格内容版本号，驱动画布重绘
  final List<_Snapshot> _undoStack = [];
  final List<_Snapshot> _redoStack = [];
  var _tool = _Tool.brush;
  var _brushSize = 1;
  var _currentColor = 9; ///< 默认选中红色（显眼）

  // 拼装模式：点颜色条 = 高亮该色全部格子（其余色降饱和），辅助对照实物拼豆
  var _assembleMode = false;
  int? _highlightIndex;

  // 矩形选区（格子坐标，拖拽中实时更新）
  int? _selX0, _selY0, _selX1, _selY1;

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

  // ==================== 撤销 / 重做 ====================

  _Snapshot _snapshot() => _Snapshot(_model.copyGrid(), _model.width, _model.height);

  void _pushUndo() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > _maxUndo) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void _restore(_Snapshot s) {
    if (s.width != _model.width || s.height != _model.height) {
      // 尺寸变化：必须换新实例（width/height 是 final）
      _model = PatternModel(width: s.width, height: s.height, grid: s.grid, paletteIds: _model.paletteIds);
    } else {
      for (var i = 0; i < s.grid.length; i++) {
        _model.grid[i] = s.grid[i];
      }
    }
    _revision.value++;
  }

  void _undo() {
    if (_undoStack.isEmpty) {
      return;
    }
    setState(() {
      _redoStack.add(_snapshot());
      _restore(_undoStack.removeLast());
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) {
      return;
    }
    setState(() {
      _undoStack.add(_snapshot());
      _restore(_redoStack.removeLast());
    });
  }

  // ==================== 画布交互 ====================

  /// 局部坐标 -> 格子坐标
  int _cellX(Offset local, double canvasSide) =>
      (local.dx / (canvasSide / _model.width)).floor().clamp(0, _model.width - 1);

  int _cellY(Offset local, double canvasSide) =>
      (local.dy / (canvasSide / _model.height)).floor().clamp(0, _model.height - 1);

  void _applyAt(Offset local, double canvasSide, {required bool isStart}) {
    final x = _cellX(local, canvasSide);
    final y = _cellY(local, canvasSide);

    switch (_tool) {
      case _Tool.brush:
      case _Tool.eraser:
        if (isStart) {
          _pushUndo();
        }
        final value = _tool == _Tool.brush ? _currentColor : -1;
        _paintSquare(x, y, value);
        _revision.value++;
        break;

      case _Tool.bucket:
        if (isStart) {
          _pushUndo();
          _model.floodFill(x, y, _currentColor);
          _revision.value++;
        }
        break;

      case _Tool.eyedropper:
        if (isStart) {
          final v = _model.cell(x, y);
          if (v >= 0) {
            setState(() {
              _currentColor = v;
              if (_tool != _Tool.brush) {
                _tool = _Tool.brush;
              }
            });
          }
        }
        break;

      case _Tool.select:
        if (isStart) {
          _selX0 = _selX1 = x;
          _selY0 = _selY1 = y;
        } else {
          _selX1 = x;
          _selY1 = y;
        }
        setState(() {}); // 选区矩形实时预览
        break;
    }
  }

  /// 以 (x,y) 为中心画 _brushSize 边长方形
  void _paintSquare(int x, int y, int value) {
    final half = (_brushSize - 1) ~/ 2;
    for (var dy = -half; dy <= _brushSize - 1 - half; dy++) {
      for (var dx = -half; dx <= _brushSize - 1 - half; dx++) {
        _model.setCell(x + dx, y + dy, value);
      }
    }
  }

  /// 归一化选区（格子坐标，x0<=x1 / y0<=y1），无选区返回 null
  Rect? get _selRectCells {
    if (_selX0 == null) {
      return null;
    }
    final x0 = _selX0! < _selX1! ? _selX0! : _selX1!;
    final x1 = _selX0! < _selX1! ? _selX1! : _selX0!;
    final y0 = _selY0! < _selY1! ? _selY0! : _selY1!;
    final y1 = _selY0! < _selY1! ? _selY1! : _selY0!;
    return Rect.fromLTRB(x0.toDouble(), y0.toDouble(), (x1 + 1).toDouble(), (y1 + 1).toDouble());
  }

  void _clearSelection() => setState(() {
        _selX0 = null;
        _selY0 = null;
        _selX1 = null;
        _selY1 = null;
      });

  /// 选区另存为新的图案
  void _saveSelectionAsNew() {
    final sel = _selRectCells;
    if (sel == null) {
      return;
    }
    final x = sel.left.toInt(), y = sel.top.toInt();
    final w = sel.width.toInt(), h = sel.height.toInt();
    final r = extractSubGrid(_model.grid, _model.width, x, y, w, h);
    _clearSelection();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorPage(
          model: PatternModel(width: r.width, height: r.height, grid: r.grid, paletteIds: _model.paletteIds),
          palette: widget.palette,
        ),
      ),
    );
  }

  /// 选区内全部填充当前色
  void _fillSelection() {
    final sel = _selRectCells;
    if (sel == null) {
      return;
    }
    _pushUndo();
    for (var y = sel.top.toInt(); y < sel.bottom.toInt(); y++) {
      for (var x = sel.left.toInt(); x < sel.right.toInt(); x++) {
        _model.setCell(x, y, _currentColor);
      }
    }
    _revision.value++;
    _clearSelection();
  }

  // ==================== 整图操作 ====================

  /// 用 GridResult 替换当前图案（变换/改尺寸后）
  void _replaceModel(GridResult r) {
    setState(() {
      _model = PatternModel(width: r.width, height: r.height, grid: r.grid, paletteIds: _model.paletteIds);
      _clearSelection();
      _revision.value++;
    });
  }

  /// 原地替换网格内容（同尺寸操作）
  void _replaceGrid(List<int> newGrid) {
    setState(() {
      for (var i = 0; i < newGrid.length; i++) {
        _model.grid[i] = newGrid[i];
      }
      _revision.value++;
    });
  }

  void _transform(GridResult Function() op) {
    _pushUndo();
    _replaceModel(op());
  }

  void _openResizeSheet() {
    showResizeSheet(
      context,
      width: _model.width,
      height: _model.height,
      onApply: (w, h) {
        _pushUndo();
        _replaceModel(resizeGrid(_model.grid, _model.width, _model.height, w, h));
      },
    );
  }

  void _openDenoiseSheet() {
    showDenoiseSheet(
      context,
      onApply: (passes) {
        _pushUndo();
        _replaceGrid(denoiseMajority(_model.grid, _model.width, _model.height, passes));
      },
    );
  }

  void _openLimitColorsSheet() {
    showLimitColorsSheet(
      context,
      usedColors: _model.countByColor().length,
      maxColors: widget.palette.colors.length,
      onApply: (n) {
        _pushUndo();
        _replaceGrid(Quantizer(widget.palette).limitColors(_model.grid, n));
      },
    );
  }

  void _openReplaceColorSheet() {
    showReplaceColorSheet(
      context,
      palette: widget.palette,
      initialFrom: _currentColor,
      initialTo: (_currentColor + 1).clamp(0, widget.palette.colors.length - 1),
      onApply: (from, to) {
        _pushUndo();
        final count = replaceColor(_model.grid, from, to);
        _revision.value++;
        setState(() {});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已替换 $count 格")));
        }
      },
    );
  }

  // ==================== 草稿 / 导出 ====================

  Future<void> _saveDraft() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("网页版暂不支持本地草稿")));
      return;
    }
    final file = await DraftStore.save(_model);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("草稿已保存：${file.path.split(Platform.pathSeparator).last}")));
    }
  }

  Future<void> _exportPng() async {
    final bytes = _model.exportPng(cellPixels: 24, palette: widget.palette);
    if (kIsWeb) {
      await downloadBytes(bytes, "pattern_${DateTime.now().millisecondsSinceEpoch}.png");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已触发浏览器下载")));
      }
      return;
    }
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory("${root.path}${Platform.pathSeparator}bead_exports")..createSync(recursive: true);
    final file = File("${dir.path}${Platform.pathSeparator}pattern_${DateTime.now().millisecondsSinceEpoch}.png");
    await file.writeAsBytes(bytes);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已导出：${file.path}")));
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final usedColors = _model.countByColor().length;
    return Scaffold(
      appBar: AppBar(
        title: Text("编辑 ${_model.width}×${_model.height} · $usedColors 色"),
        actions: [
          IconButton(onPressed: _undoStack.isEmpty ? null : _undo, icon: const Icon(Icons.undo), tooltip: "撤销"),
          IconButton(onPressed: _redoStack.isEmpty ? null : _redo, icon: const Icon(Icons.redo), tooltip: "重做"),
          IconButton(onPressed: _saveDraft, icon: const Icon(Icons.save_outlined), tooltip: "保存草稿"),
          IconButton(onPressed: _exportPng, icon: const Icon(Icons.download), tooltip: "导出PNG"),
          IconButton(
            onPressed: () => setState(() {
              _assembleMode = !_assembleMode;
              _highlightIndex = null;
            }),
            icon: Icon(_assembleMode ? Icons.visibility : Icons.visibility_outlined),
            tooltip: _assembleMode ? "退出拼装模式" : "拼装模式",
          ),
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
          _buildToolRow(),
          if (_selRectCells != null) _buildSelectionBar(),
          Expanded(child: _buildCanvas()),
          _buildOpsRow(),
          if (_assembleMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                _highlightIndex == null
                    ? "拼装模式：点下方颜色高亮该色全部格子，再点一次取消"
                    : "已高亮 ${widget.palette.colors[_highlightIndex!].id}（${_model.countByColor()[_highlightIndex!] ?? 0} 颗）",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          _buildColorBar(_model.countByColor()),
        ],
      ),
    );
  }

  /// 工具行：五工具 + 笔刷大小
  Widget _buildToolRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<_Tool>(
                segments: const [
                  ButtonSegment(value: _Tool.brush, icon: Icon(Icons.brush), label: Text("画笔")),
                  ButtonSegment(value: _Tool.eraser, icon: Icon(Icons.delete_outline), label: Text("橡皮")),
                  ButtonSegment(value: _Tool.bucket, icon: Icon(Icons.format_color_fill), label: Text("油漆桶")),
                  ButtonSegment(value: _Tool.eyedropper, icon: Icon(Icons.colorize), label: Text("吸管")),
                  ButtonSegment(value: _Tool.select, icon: Icon(Icons.crop_free), label: Text("选区")),
                ],
                selected: {_tool},
                onSelectionChanged: (sel) => setState(() {
                  _tool = sel.first;
                  if (_tool != _Tool.select) {
                    _clearSelection();
                  }
                }),
              ),
            ),
          ),
          if (_tool == _Tool.brush || _tool == _Tool.eraser) ...[
            const SizedBox(width: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final s in _brushSizes) ButtonSegment(value: s, label: Text("$s")),
              ],
              selected: {_brushSize},
              onSelectionChanged: (sel) => setState(() => _brushSize = sel.first),
            ),
          ],
        ],
      ),
    );
  }

  /// 选区操作条
  Widget _buildSelectionBar() {
    final sel = _selRectCells!;
    final w = sel.width.toInt(), h = sel.height.toInt();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        children: [
          Text("选区 $w×$h", style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 4),
          TextButton(onPressed: _saveSelectionAsNew, child: const Text("另存为图案")),
          TextButton(onPressed: _fillSelection, child: const Text("填充当前色")),
          TextButton(onPressed: _clearSelection, child: const Text("取消")),
        ],
      ),
    );
  }

  /// 画布
  Widget _buildCanvas() {
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.biggest.shortestSide * 0.96;
          final canvasSize = Size.square(side);
          return GestureDetector(
            onPanDown: (d) => _applyAt(d.localPosition, side, isStart: true),
            onPanUpdate: (d) => _applyAt(d.localPosition, side, isStart: false),
            child: CustomPaint(
              size: canvasSize,
              painter: GridPainter(
                model: _model,
                palette: widget.palette,
                selectedColorIndex: _currentColor,
                repaint: _revision,
                selectionRect: _selectionPixels(canvasSize),
                highlightIndex: _assembleMode ? _highlightIndex : null,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 格子选区 -> 画布像素矩形
  Rect? _selectionPixels(Size canvasSize) {
    final sel = _selRectCells;
    if (sel == null) {
      return null;
    }
    final cellW = canvasSize.width / _model.width;
    final cellH = canvasSize.height / _model.height;
    return Rect.fromLTRB(sel.left * cellW, sel.top * cellH, sel.right * cellW, sel.bottom * cellH);
  }

  /// 整图操作行
  Widget _buildOpsRow() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          ActionChip(avatar: const Icon(Icons.flip_outlined, size: 18), label: const Text("左右翻转"), onPressed: () => _transform(() => flipHorizontal(_model.grid, _model.width, _model.height))),
          ActionChip(avatar: const Icon(Icons.flip), label: const Text("上下翻转"), onPressed: () => _transform(() => flipVertical(_model.grid, _model.width, _model.height))),
          ActionChip(avatar: const Icon(Icons.rotate_right_outlined), label: const Text("旋转90°"), onPressed: () => _transform(() => rotate90(_model.grid, _model.width, _model.height))),
          ActionChip(avatar: const Icon(Icons.photo_size_select_large), label: const Text("改尺寸"), onPressed: _openResizeSheet),
          ActionChip(avatar: const Icon(Icons.auto_fix_high), label: const Text("降噪"), onPressed: _openDenoiseSheet),
          ActionChip(avatar: const Icon(Icons.palette_outlined), label: const Text("限制色数"), onPressed: _openLimitColorsSheet),
          ActionChip(avatar: const Icon(Icons.swap_horiz), label: const Text("全局换色"), onPressed: _openReplaceColorSheet),
        ],
      ),
    );
  }

  /// 底部颜色选择条（拼装模式下兼作高亮选择器，显示每色用量）
  Widget _buildColorBar(Map<int, int> counts) {
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: widget.palette.colors.length,
        itemBuilder: (context, i) {
          final c = widget.palette.colors[i];
          final count = counts[i] ?? 0;
          final selected = _assembleMode ? i == _highlightIndex : i == _currentColor;
          return GestureDetector(
            onTap: () => setState(() {
              if (_assembleMode) {
                // 拼装模式：切换高亮（再点同色取消），不改绘画色
                _highlightIndex = _highlightIndex == i ? null : i;
                return;
              }
              _currentColor = i;
              if (_tool == _Tool.eraser) {
                _tool = _Tool.brush;
              }
            }),
            child: Container(
              width: 48,
              height: 60,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: Color.fromARGB(255, c.r, c.g, c.b),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? Colors.blue : Colors.black26,
                  width: selected ? 3 : 1,
                ),
              ),
              child: _assembleMode
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          c.id.replaceFirst("P", ""),
                          style: TextStyle(
                            fontSize: 11,
                            color: _isLightColor(c) ? Colors.black54 : Colors.white70,
                          ),
                        ),
                        Text(
                          "×$count",
                          style: TextStyle(
                            fontSize: 9,
                            color: _isLightColor(c) ? Colors.black45 : Colors.white60,
                          ),
                        ),
                      ],
                    )
                  : Center(
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
    );
  }

  /// 粗略判断浅色（决定色块上文字颜色）
  bool _isLightColor(BeadColor c) => (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) > 150;
}
