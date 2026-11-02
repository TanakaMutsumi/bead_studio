import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_snack_bar.dart';
import '../../core/draft_store.dart';
import '../../core/file_saver.dart';
import '../../core/grid_ops.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';
import '../../core/quantizer.dart';
import '../palette_picker.dart';
import '../preview/preview_page.dart';
import '../stats/stats_page.dart';
import 'board_split.dart';
import 'editor_bars.dart';
import 'editor_undo.dart';
import 'grid_painter.dart';
import 'sheets.dart';

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
  final File? sourceFile;

  ///< 来源作品文件（作品库打开时传入：保存=覆写而非另存）
  final Set<int> placed;

  ///< 拼装进度（作品库打开时恢复；新建为空）
  final String? sortMode;

  ///< 信息排序模式（作品 meta 携带，用料统计沿用；null = 默认颗数降序）

  const EditorPage({
    super.key,
    required this.model,
    required this.palette,
    this.sourceFile,
    this.placed = const <int>{},
    this.sortMode,
  });

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late PatternModel _model;
  final _revision = ValueNotifier<int>(0);

  ///< 网格内容版本号，驱动画布重绘
  final _history = SnapshotHistory<_Snapshot>();
  var _tool = EditorTool.brush;
  var _brushSize = 1;
  int? _currentColor;

  ///< 当前绘画色（null = 未选色：画笔/油漆桶/选区填充一律不落笔，
  ///< 必须点下方选色按钮或用吸管取色指定）

  // 拼装模式：点颜色条 = 高亮该色全部格子（其余色降饱和），辅助对照实物拼豆；
  // 点画布格子 = 标记已放（半透明白罩+对勾，剩余颗数递减），进度随作品保存
  var _assembleMode = false;
  int? _highlightIndex;
  late final Set<int> _placed = {...widget.placed};

  // 分板模式：按底板边长把图案切块导航，板外格子淡出，颜色条显示本板用量
  var _boardMode = false;
  var _boardSize = 29;
  var _boardIndex = 0;

  ///< 当前板序号（行优先）

  // 矩形选区（格子坐标，拖拽中实时更新）
  int? _selX0, _selY0, _selX1, _selY1;

  // ==================== 分板 ====================

  int get _boardsAcross => (_model.width / _boardSize).ceil();

  int get _boardsDown => (_model.height / _boardSize).ceil();

  int get _boardCount => _boardsAcross * _boardsDown;

  /// 第 [index] 块板的格子范围（clamp 到图案边界）
  Rect _boardRectOf(int index) => boardRectOf(_model, _boardSize, index);

  /// 本板用料统计
  Map<int, int> _boardCounts(Rect r) => boardCounts(_model, r);

  /// 切换板尺寸：索引 clamp 到新板数
  void _setBoardSize(int size) {
    setState(() {
      _boardSize = size;
      _boardIndex = _boardIndex.clamp(0, _boardCount - 1);
    });
  }

  void _stepBoard(int delta) {
    setState(() {
      _boardIndex = (_boardIndex + delta).clamp(0, _boardCount - 1);
    });
  }

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

  _Snapshot _snapshot() =>
      _Snapshot(_model.copyGrid(), _model.width, _model.height);

  void _pushUndo() => _history.push(_snapshot());

  void _restore(_Snapshot s) {
    if (s.width != _model.width || s.height != _model.height) {
      // 尺寸变化：必须换新实例（width/height 是 final）
      _model = PatternModel(
        width: s.width,
        height: s.height,
        grid: s.grid,
        paletteIds: _model.paletteIds,
      );
    } else {
      for (var i = 0; i < s.grid.length; i++) {
        _model.grid[i] = s.grid[i];
      }
    }
    _revision.value++;
  }

  void _undo() {
    setState(() {
      final s = _history.undo(_snapshot());
      if (s != null) {
        _restore(s);
      }
    });
  }

  void _redo() {
    setState(() {
      final s = _history.redo(_snapshot());
      if (s != null) {
        _restore(s);
      }
    });
  }

  // ==================== 画布交互 ====================

  /// 局部坐标 -> 格子坐标（画布宽高随图案宽高比走，横纵格边长可不同）
  int _cellX(Offset local, double canvasW) =>
      (local.dx / (canvasW / _model.width)).floor().clamp(
            0,
            _model.width - 1,
          );

  int _cellY(Offset local, double canvasH) =>
      (local.dy / (canvasH / _model.height)).floor().clamp(
            0,
            _model.height - 1,
          );

  void _applyAt(Offset local, Size canvasSize, {required bool isStart}) {
    final x = _cellX(local, canvasSize.width);
    final y = _cellY(local, canvasSize.height);

    // 拼装模式画布只做标记：点格=放/取消一颗（拖动不连标，防误触），
    // 绘制工具全部旁路——拼装中途不可能误改图案
    if (_assembleMode) {
      if (isStart) {
        _togglePlaced(x, y);
      }
      return;
    }

    switch (_tool) {
      case EditorTool.brush:
      case EditorTool.eraser:
        final color = _currentColor;
        if (_tool == EditorTool.brush && color == null) {
          // 未选色不落笔：先在颜色条指定颜色（拖动中不重复提示）
          if (isStart) {
            AppSnackBar.show(context, "先点下方按钮选择颜色，再绘制");
          }
          return;
        }
        if (isStart) {
          _pushUndo();
        }
        _paintSquare(x, y, _tool == EditorTool.brush ? color! : -1);
        _revision.value++;
        break;

      case EditorTool.bucket:
        final color = _currentColor;
        if (color == null) {
          if (isStart) {
            AppSnackBar.show(context, "先点下方按钮选择颜色，再填充");
          }
          return;
        }
        if (isStart) {
          _pushUndo();
          _model.floodFill(x, y, color);
          _revision.value++;
        }
        break;

      case EditorTool.eyedropper:
        if (isStart) {
          final v = _model.cell(x, y);
          if (v >= 0) {
            setState(() {
              _currentColor = v;
              if (_tool != EditorTool.brush) {
                _tool = EditorTool.brush;
              }
            });
          }
        }
        break;

      case EditorTool.select:
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

  /// 拼装标记：只允许标记当前高亮色（先选色再放豆），再点取消
  void _togglePlaced(int x, int y) {
    final i = y * _model.width + x;
    final hi = _highlightIndex;
    if (hi == null) {
      AppSnackBar.show(context, "先点下方颜色选择要拼的色，再点格子标记已放");
      return;
    }
    if (_model.grid[i] != hi) {
      return; // 非高亮色格子不响应（防串色误标）
    }
    setState(() {
      _placed.contains(i) ? _placed.remove(i) : _placed.add(i);
    });
  }

  /// 该色剩余颗数（总 - 已放）
  int _remainOf(int colorIndex, Map<int, int> counts) {
    final total = counts[colorIndex] ?? 0;
    var placedCount = 0;
    for (final i in _placed) {
      if (i >= 0 && i < _model.grid.length && _model.grid[i] == colorIndex) {
        placedCount++;
      }
    }
    return total - placedCount;
  }

  /// 拼装进度（已放/总数；分板模式按本板统计）
  (int, int) _assembleProgress() {
    var total = 0;
    var done = 0;
    if (_boardMode) {
      final r = _boardRectOf(_boardIndex);
      for (var y = r.top.toInt(); y < r.bottom.toInt(); y++) {
        for (var x = r.left.toInt(); x < r.right.toInt(); x++) {
          if (_model.cell(x, y) >= 0) {
            total++;
            if (_placed.contains(y * _model.width + x)) {
              done++;
            }
          }
        }
      }
    } else {
      for (var i = 0; i < _model.grid.length; i++) {
        if (_model.grid[i] >= 0) {
          total++;
          if (_placed.contains(i)) {
            done++;
          }
        }
      }
    }
    return (done, total);
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
    return Rect.fromLTRB(
      x0.toDouble(),
      y0.toDouble(),
      (x1 + 1).toDouble(),
      (y1 + 1).toDouble(),
    );
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
          model: PatternModel(
            width: r.width,
            height: r.height,
            grid: r.grid,
            paletteIds: _model.paletteIds,
          ),
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
    final color = _currentColor;
    if (color == null) {
      AppSnackBar.show(context, "先点下方按钮选择颜色");
      return;
    }
    _pushUndo();
    for (var y = sel.top.toInt(); y < sel.bottom.toInt(); y++) {
      for (var x = sel.left.toInt(); x < sel.right.toInt(); x++) {
        _model.setCell(x, y, color);
      }
    }
    _revision.value++;
    _clearSelection();
  }

  // ==================== 整图操作 ====================

  /// 用 GridResult 替换当前图案（变换/改尺寸后）
  void _replaceModel(GridResult r) {
    setState(() {
      if (r.width * r.height != _model.grid.length) {
        _placed.clear(); // 网格长度变了，扁平索引全部失效
      }
      _model = PatternModel(
        width: r.width,
        height: r.height,
        grid: r.grid,
        paletteIds: _model.paletteIds,
      );
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
        _replaceModel(
          resizeGrid(_model.grid, _model.width, _model.height, w, h),
        );
      },
    );
  }

  void _openDenoiseSheet() {
    showDenoiseSheet(
      context,
      onApply: (passes) {
        _pushUndo();
        _replaceGrid(
          denoiseMajority(_model.grid, _model.width, _model.height, passes),
        );
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
      initialFrom: _currentColor ?? 0,
      initialTo: ((_currentColor ?? 0) + 1)
          .clamp(0, widget.palette.colors.length - 1),
      onApply: (from, to) {
        _pushUndo();
        final count = replaceColor(_model.grid, from, to);
        _revision.value++;
        setState(() {});
        if (mounted) {
          AppSnackBar.show(context, "已替换 $count 格");
        }
      },
    );
  }

  // ==================== 草稿 / 导出 ====================

  Future<void> _saveDraft() async {
    if (kIsWeb) {
      AppSnackBar.show(context, "网页版暂不支持本地草稿");
      return;
    }
    // 从作品库打开的：覆写原文件（保留名字/分组），否则另存新作品；
    // 拼装进度一并保存（覆写时显式传当前进度，防止回退成旧进度）
    final file = await DraftStore.saveWork(
      _model,
      overwrite: widget.sourceFile,
      placed: _placed,
      sortMode: widget.sortMode,
    );
    if (mounted) {
      AppSnackBar.show(
        context,
        widget.sourceFile != null
            ? "作品已更新"
            : "已保存到作品库：${file.path.split(Platform.pathSeparator).last}",
      );
    }
  }

  Future<void> _exportPng() async {
    final bytes = _model.exportPng(cellPixels: 24, palette: widget.palette);
    if (kIsWeb) {
      await downloadBytes(
        bytes,
        "pattern_${DateTime.now().millisecondsSinceEpoch}.png",
      );
      if (mounted) {
        AppSnackBar.show(context, "已触发浏览器下载");
      }
      return;
    }
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory("${root.path}${Platform.pathSeparator}bead_exports")
      ..createSync(recursive: true);
    final file = File(
      "${dir.path}${Platform.pathSeparator}pattern_${DateTime.now().millisecondsSinceEpoch}.png",
    );
    await file.writeAsBytes(bytes);
    if (mounted) {
      AppSnackBar.show(context, "已导出：${file.path}");
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final usedColors = _model.countByColor().length;
    return Scaffold(
      appBar: AppBar(
        title: Text("编辑 ${_model.width}×${_model.height} · $usedColors 色"),
        // 窄屏放不下九个图标按钮（会与返回键互相遮挡）：常驻撤销/重做/
        // 保存，其余收进 ⋮ 菜单
        actions: [
          IconButton(
            onPressed: _history.canUndo ? _undo : null,
            icon: const Icon(Icons.undo),
            tooltip: "撤销",
          ),
          IconButton(
            onPressed: _history.canRedo ? _redo : null,
            icon: const Icon(Icons.redo),
            tooltip: "重做",
          ),
          IconButton(
            onPressed: _saveDraft,
            icon: const Icon(Icons.save_outlined),
            tooltip: "保存草稿",
          ),
          PopupMenuButton<String>(
            tooltip: "更多",
            onSelected: (k) {
              switch (k) {
                case 'export':
                  _exportPng();
                case 'assemble':
                  setState(() {
                    _assembleMode = !_assembleMode;
                    _highlightIndex = null;
                  });
                case 'board':
                  setState(() {
                    _boardMode = !_boardMode;
                    if (_boardMode) {
                      _boardIndex = _boardIndex.clamp(0, _boardCount - 1);
                    }
                  });
                case 'preview':
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          PreviewPage(model: _model, palette: widget.palette),
                    ),
                  );
                case 'stats':
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => StatsPage(
                        model: _model,
                        palette: widget.palette,
                        sortMode: widget.sortMode,
                      ),
                    ),
                  );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.download),
                    SizedBox(width: 12),
                    Text("导出PNG"),
                  ],
                ),
              ),
              CheckedPopupMenuItem(
                value: 'assemble',
                checked: _assembleMode,
                child: const Text("拼装模式"),
              ),
              CheckedPopupMenuItem(
                value: 'board',
                checked: _boardMode,
                child: const Text("分板拼装"),
              ),
              const PopupMenuItem(
                value: 'preview',
                child: Row(
                  children: [
                    Icon(Icons.view_in_ar_outlined),
                    SizedBox(width: 12),
                    Text("预览"),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'stats',
                child: Row(
                  children: [
                    Icon(Icons.list_alt),
                    SizedBox(width: 12),
                    Text("用料统计"),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildToolRow(),
          if (_selRectCells != null) _buildSelectionBar(),
          Expanded(child: _buildCanvas()),
          _buildOpsRow(),
          if (_boardMode) _buildBoardBar(),
          if (_assembleMode)
            Builder(
              builder: (ctx) {
                final (done, total) = _assembleProgress();
                final hi = _highlightIndex;
                final remainTxt = hi == null
                    ? "先点下方颜色选择要拼的色"
                    : () {
                        final counts = _boardMode
                            ? _boardCounts(_boardRectOf(_boardIndex))
                            : _model.countByColor();
                        final remain = _remainOf(hi, counts);
                        return "${widget.palette.colors[hi].id} 剩 $remain/${counts[hi] ?? 0} 颗";
                      }();
                return EditorAssembleProgress(
                  done: done,
                  total: total,
                  remainText: remainTxt,
                );
              },
            ),
          // 拼装模式：色条兼高亮选择器（显示每色用量/剩余）；编辑模式：
          // 点按钮展开色卡网格选绘画色（与图例"添加色号"同一选择器）
          if (_assembleMode)
            _buildColorBar(
              _boardMode
                  ? _boardCounts(_boardRectOf(_boardIndex))
                  : _model.countByColor(),
            )
          else
            _buildColorPickerEntry(),
        ],
      ),
    );
  }

  /// 工具行：五工具 + 笔刷大小
  Widget _buildToolRow() {
    return EditorToolRow(
      tool: _tool,
      brushSize: _brushSize,
      onSelectTool: (t) => setState(() {
        _tool = t;
        if (t != EditorTool.select) {
          _clearSelection();
        }
      }),
      onSelectBrushSize: (s) => setState(() => _brushSize = s),
    );
  }

  /// 选区操作条
  Widget _buildSelectionBar() {
    final sel = _selRectCells!;
    return EditorSelectionBar(
      selW: sel.width.toInt(),
      selH: sel.height.toInt(),
      onSave: _saveSelectionAsNew,
      onFill: _fillSelection,
      onCancel: _clearSelection,
    );
  }

  /// 画布：尺寸随图案宽高比适配可用区域（先前固定正方形，竖版图案
  /// 网格总高超出画布——底部横线画到画布外被底部控件盖住，且点击
  /// 映射跟着错位）
  Widget _buildCanvas() {
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final area = constraints.biggest * 0.96;
          final aspect = _model.width / _model.height;
          final canvasSize = area.aspectRatio > aspect
              ? Size(area.height * aspect, area.height)
              : Size(area.width, area.width / aspect);
          return GestureDetector(
            onPanDown: (d) =>
                _applyAt(d.localPosition, canvasSize, isStart: true),
            onPanUpdate: (d) =>
                _applyAt(d.localPosition, canvasSize, isStart: false),
            child: CustomPaint(
              size: canvasSize,
              painter: GridPainter(
                model: _model,
                palette: widget.palette,
                selectedColorIndex: _currentColor,
                repaint: _revision,
                selectionRect: _selectionPixels(canvasSize),
                highlightIndex: _assembleMode ? _highlightIndex : null,
                boardRect: _boardMode ? _boardRectOf(_boardIndex) : null,
                placedCells: _assembleMode ? _placed : null,
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
    return Rect.fromLTRB(
      sel.left * cellW,
      sel.top * cellH,
      sel.right * cellW,
      sel.bottom * cellH,
    );
  }

  /// 整图操作行
  Widget _buildOpsRow() {
    return EditorOpsRow(
      onFlipH: () => _transform(
        () => flipHorizontal(_model.grid, _model.width, _model.height),
      ),
      onFlipV: () => _transform(
        () => flipVertical(_model.grid, _model.width, _model.height),
      ),
      onRotate: () => _transform(
        () => rotate90(_model.grid, _model.width, _model.height),
      ),
      onResize: _openResizeSheet,
      onDenoise: _openDenoiseSheet,
      onLimitColors: _openLimitColorsSheet,
      onReplaceColor: _openReplaceColorSheet,
    );
  }

  /// 分板控制条：板尺寸 + 板导航 + 本板颗数
  Widget _buildBoardBar() {
    final counts = _boardCounts(_boardRectOf(_boardIndex));
    final total = counts.values.fold(0, (a, b) => a + b);
    return EditorBoardBar(
      boardSize: _boardSize,
      boardIndex: _boardIndex,
      boardCount: _boardCount,
      boardsAcross: _boardsAcross,
      totalBeads: total,
      onSelectSize: _setBoardSize,
      onStep: _stepBoard,
    );
  }

  /// 底部选色入口（编辑模式）：点开才展开全部色号网格——常驻整条色卡
  /// 在大色卡（291 色）下又长又难找，与图例"添加色号"统一交互
  Widget _buildColorPickerEntry() {
    final idx = _currentColor;
    final c = idx != null && idx < widget.palette.colors.length
        ? widget.palette.colors[idx]
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _pickPaintColor,
          icon: c == null
              ? const Icon(Icons.palette_outlined, size: 22)
              : Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Color.fromARGB(255, c.r, c.g, c.b),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.black26),
                  ),
                ),
          label: Text(
            c == null ? "选择颜色" : "${c.id} ${c.name} · 点击换色",
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  /// 弹色卡网格选绘画色（吸管/色条同源：选完自动从橡皮切回画笔）
  Future<void> _pickPaintColor() async {
    final i = await showPaletteColorPicker(
      context,
      palette: widget.palette,
      title: "选择绘画颜色",
    );
    if (i == null || i < 0 || !mounted) {
      return;
    }
    setState(() {
      _currentColor = i;
      if (_tool == EditorTool.eraser) {
        _tool = EditorTool.brush;
      }
    });
  }

  /// 底部颜色选择条（拼装模式下兼作高亮选择器，显示每色用量）
  Widget _buildColorBar(Map<int, int> counts) {
    return EditorColorBar(
      palette: widget.palette,
      counts: counts,
      assembleMode: _assembleMode,
      highlightIndex: _highlightIndex,
      currentColor: _currentColor,
      remainOf: _remainOf,
      onTap: (i) => setState(() {
        if (_assembleMode) {
          // 拼装模式：切换高亮（再点同色取消），不改绘画色
          _highlightIndex = _highlightIndex == i ? null : i;
          return;
        }
        _currentColor = i;
        if (_tool == EditorTool.eraser) {
          _tool = EditorTool.brush;
        }
      }),
    );
  }
}
