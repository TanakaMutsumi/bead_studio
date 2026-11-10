import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/adaptive_text.dart';
import '../../core/app_snack_bar.dart';
import '../../core/draft_store.dart';
import '../../core/file_saver.dart';
import '../../core/grid_ops.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';
import '../../core/quantizer.dart';
import '../../core/zoom_controls.dart';
import '../palette_picker.dart';
import '../preview/preview_page.dart';
import '../stats/stats_page.dart';
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
  final String? workName;

  ///< 作品名（作品库打开时传入，标题显示用；编辑中另存后回填）

  const EditorPage({
    super.key,
    required this.model,
    required this.palette,
    this.sourceFile,
    this.placed = const <int>{},
    this.sortMode,
    this.workName,
  });

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late PatternModel _model;

  ///< 标题显示的作品名：作品库打开=传入名，另存后=回填保存名
  late String? _name = widget.workName;
  final _revision = ValueNotifier<int>(0);

  ///< 网格内容版本号，驱动画布重绘
  final _history = SnapshotHistory<_Snapshot>();
  var _tool = EditorTool.view;

  ///< 默认「查看」：打开作品点/拖画布零副作用（2026-11-09 用户反馈
  ///< 误触绘制）——想画显式切画笔；选色/吸管取色后自动切回画笔
  var _brushSize = 1;
  int? _currentColor;

  ///< 当前绘画色（null = 未选色：画笔/油漆桶/选区填充一律不落笔，
  ///< 必须点下方选色按钮或用吸管取色指定）

  // 画布缩放（2026-11-10 用户反馈：编辑器缺其他视图共有的缩放按钮；
  ///< 双指捏合照板设置页同款自实现，单指留给绘画）
  final _viewerCtrl = TransformationController();
  var _lastScale = 1.0;

  ///< 捏合缩放的相对基准（onScaleStart 重置为 1）
  Size _lastCanvasSize = Size.zero;

  ///< 画布内容尺寸速记（LayoutBuilder 赋值，ZoomControls 边界计算用）
  var _dirty = false;

  ///< 有未保存的内容修改（返回时确认；保存后清零）——拼装/分板模式
  ///< 已移除（2026-11-10 用户定稿：那是「开始拼豆」的功能，编辑器
  ///< 只管改图案），进度数据经 widget.placed 原样带回保存

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
    _viewerCtrl.dispose();
    super.dispose();
  }

  // ==================== 撤销 / 重做 ====================

  _Snapshot _snapshot() =>
      _Snapshot(_model.copyGrid(), _model.width, _model.height);

  /// 记录一次编辑前的快照；一切内容修改都先经此（dirty 也在这置位）
  void _pushUndo() {
    _history.push(_snapshot());
    _dirty = true;
  }

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

    // 查看工具：点/拖画布零副作用（默认工具，防打开作品误触绘制）
    if (_tool == EditorTool.view) {
      return;
    }

    switch (_tool) {
      case EditorTool.view: // 前面已 early return，此分支不可达（保穷尽）
        return;
      case EditorTool.brush:
      case EditorTool.eraser:
        final color = _currentColor;
        if (_tool == EditorTool.brush && color == null) {
          // 未选色不落笔：先在颜色条指定颜色（拖动中不重复提示）
          if (isStart) {
            AppSnackBar.show(context, "先在上方选择颜色，再绘制");
          }
          return;
        }
        if (isStart) {
          _pushUndo();
        }
        _paintSquare(x, y, _tool == EditorTool.brush ? color! : -1);
        // setState：除了重绘，还要刷新 AppBar 撤销/重做按钮的可用态
        // （2026-11-10 用户反馈编辑后撤销钮还是灰的点不动——此前只
        // _revision++ 驱动重绘，按钮 canUndo 不重建）
        setState(() => _revision.value++);
        break;

      case EditorTool.bucket:
        final color = _currentColor;
        if (color == null) {
          if (isStart) {
            AppSnackBar.show(context, "先在上方选择颜色，再填充");
          }
          return;
        }
        if (isStart) {
          _pushUndo();
          _model.floodFill(x, y, color);
          setState(() => _revision.value++);
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
      AppSnackBar.show(context, "先在上方选择颜色");
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
    // 拼装进度原样带回（编辑器已不改动进度——拼装/分板移去「开始拼豆」）
    final file = await DraftStore.saveWork(
      _model,
      overwrite: widget.sourceFile,
      placed: widget.placed,
      sortMode: widget.sortMode,
    );
    _dirty = false;
    // 回填作品名：新建保存后标题从「未命名图案」变成实际保存名
    if (mounted) {
      final entry = await DraftStore.readEntry(file);
      if (mounted && entry.name != _name) {
        setState(() => _name = entry.name);
      }
    }
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

  /// 导出软件图案文件（.beadpattern）：JSON 自描述格式，可在「我的
  /// 作品 → 导入」原样导回（2026-11-10 用户需求：软件豆图格式的
  /// 导出与导入——跨设备搬家/备份/分享给同好用）
  Future<void> _exportPatternFile() async {
    final name = (_name ?? "pattern").replaceAll(RegExp(r'[\\/:*?"<>|]'), "_");
    final payload = {
      "app": "beadstudio",
      "type": "bead-pattern",
      "version": 1,
      "name": _name ?? "未命名图案",
      // 调色板不用单独声明：pattern.paletteIds 自描述，导入端
      // PaletteRegistry.resolveForModel 按色号解析渲染色卡
      "pattern": _model.toJson(),
    };
    final bytes = utf8.encode(const JsonEncoder().convert(payload));
    if (kIsWeb) {
      await downloadBytes(bytes, "$name.beadpattern");
      if (mounted) {
        AppSnackBar.show(context, "已触发浏览器下载（$name.beadpattern）");
      }
      return;
    }
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory("${root.path}${Platform.pathSeparator}bead_exports")
      ..createSync(recursive: true);
    final file = File(
      "${dir.path}${Platform.pathSeparator}$name.beadpattern",
    );
    await file.writeAsBytes(bytes);
    if (mounted) {
      AppSnackBar.show(context, "已导出：${file.path}");
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final counts = _model.countByColor();
    final usedColors = counts.length;
    final totalBeads = counts.values.fold(0, (a, b) => a + b);
    return Scaffold(
      appBar: AppBar(
        // 标题双行（同还原页模式）：上行作品名自适应缩放（长名不再
        // 「…」截死，2026-11-10 用户反馈），下行小字尺寸/色数——此前
        // 「编辑 55×47 · 12 色」在撤销/重做/保存/⋮ 四钮挤压下必然截断
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveTitleText(_name ?? "未命名图案"),
            Text(
              // 总豆数上标题（2026-11-10 用户反馈）：随编辑实时刷新
              "${_model.width}×${_model.height} · $totalBeads 颗 · $usedColors 色",
              style: const TextStyle(fontSize: 10, color: Colors.black38),
            ),
          ],
        ),
        // 窄屏放不下九个图标按钮（会与返回键互相遮挡）：常驻撤销/重做，
        // 保存与其余收进 ⋮ 菜单（2026-11-10 三轮：保存也让位给标题——
        // 四钮把标题挤到 ~72dp，作品名必被「…」截死）
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
          PopupMenuButton<String>(
            tooltip: "更多",
            onSelected: (k) {
              switch (k) {
                case 'save':
                  _saveDraft();
                case 'export':
                  _exportPng();
                case 'exportFile':

                  ///< 导出软件图案文件（.beadpattern，可再导入）
                  _exportPatternFile();
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
                // 整图操作（2026-11-09 用户反馈重排：原先横滚操作条在
                // 画布下方常驻挤占空间还看不到头，收进菜单）
                case 'flipH':
                  _transform(
                    () => flipHorizontal(_model.grid, _model.width, _model.height),
                  );
                case 'flipV':
                  _transform(
                    () => flipVertical(_model.grid, _model.width, _model.height),
                  );
                case 'rotate':
                  _transform(
                    () => rotate90(_model.grid, _model.width, _model.height),
                  );
                case 'resize':
                  _openResizeSheet();
                case 'denoise':
                  _openDenoiseSheet();
                case 'limit':
                  _openLimitColorsSheet();
                case 'replace':
                  _openReplaceColorSheet();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'save',
                child: Row(
                  children: [
                    Icon(Icons.save_outlined),
                    SizedBox(width: 12),
                    Text("保存草稿"),
                  ],
                ),
              ),
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
              // 拼装模式/分板拼装已移除（2026-11-10 用户定稿：那是
              // 「开始拼豆」链路的功能，编辑器专注改图案）
              const PopupMenuItem(
                value: 'exportFile',
                child: Row(
                  children: [
                    Icon(Icons.file_present_outlined),
                    SizedBox(width: 12),
                    Text("导出图案文件"),
                  ],
                ),
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
              const PopupMenuDivider(),
              _menuRow('flipH', Icons.flip_outlined, "左右翻转"),
              _menuRow('flipV', Icons.flip, "上下翻转"),
              _menuRow('rotate', Icons.rotate_right_outlined, "旋转90°"),
              _menuRow('resize', Icons.photo_size_select_large, "改尺寸"),
              _menuRow('denoise', Icons.auto_fix_high, "降噪"),
              _menuRow('limit', Icons.palette_outlined, "限制色数"),
              _menuRow('replace', Icons.swap_horiz, "全局换色"),
            ],
          ),
        ],
      ),
      // 返回守卫（2026-11-10 用户反馈：有未保存修改直接返回丢改动）：
      // 系统返回手势与 AppBar 返回箭头都走 _confirmExit；无修改直接退
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _confirmExit();
          }
        },
        child: Column(
          children: [
            // 顶行 = 工具图标组 + 当前色圆（2026-11-10 用户反馈二轮：
            // 颜色选择拉上来与工具同栏，底部完全让给画布）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(
                children: [
                  Expanded(child: _buildToolRow()),
                  EditorColorChip(
                    palette: widget.palette,
                    currentColor: _currentColor,
                    onTap: _pickPaintColor,
                  ),
                ],
              ),
            ),
            // 画布区：笔刷条/选区条改为**悬浮卡**叠在画布上（2026-11-10
            // 用户反馈：条件插入行会挤压画布让豆图位移，不允许）；
            // 缩放条常驻画布下方（其他视图共有的缩放按钮，本页补齐）
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildCanvas()),
                  if (_tool == EditorTool.brush || _tool == EditorTool.eraser)
                    Positioned(
                      top: 6,
                      right: 10,
                      child: _floatCard(
                        EditorBrushBar(
                          brushSize: _brushSize,
                          onSelectBrushSize: (s) =>
                              setState(() => _brushSize = s),
                        ),
                      ),
                    ),
                  if (_selRectCells != null)
                    Positioned(
                      top: 6,
                      left: 10,
                      right: 10,
                      child: _floatCard(_buildSelectionBar()),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: ZoomControls(
                  controller: _viewerCtrl,
                  contentSize: () => _lastCanvasSize,
                  viewportSize: () => _lastCanvasSize,
                  maxScale: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮操作卡：叠在画布上的小面板（不占布局高度，画布零位移）
  Widget _floatCard(Widget child) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(10),
      color: Theme.of(context).colorScheme.surface,
      child: child,
    );
  }

  /// 有未保存修改时的退出确认：保存并退出 / 不保存退出 / 取消
  Future<void> _confirmExit() async {
    if (!_dirty) {
      if (mounted) {
        Navigator.of(context).pop();
      }
      return;
    }
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("有未保存的修改"),
        // 三选一竖排满宽钮（此前 actions 三钮一行，窄屏 OverflowBar
        // 换行成参差多行——2026-11-10 用户反馈「排布问题严重」）
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text("退出前要保存吗？不保存将丢失这次编辑。"),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, "save"),
                icon: const Icon(Icons.save_outlined),
                label: const Text("保存并退出"),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(ctx, "discard"),
                style: ButtonStyle(
                  foregroundColor: WidgetStatePropertyAll(
                    Theme.of(ctx).colorScheme.error,
                  ),
                ),
                icon: const Icon(Icons.logout),
                label: const Text("不保存退出"),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(ctx, "cancel"),
                child: const Text("取消"),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    if (act == "save") {
      await _saveDraft();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } else if (act == "discard") {
      Navigator.of(context).pop();
    }
  }

  /// 菜单行（图标 + 文字）——整图操作收进 ⋮ 菜单用
  PopupMenuItem<String> _menuRow(String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  /// 工具行：六工具图标（笔刷/选区附属条由 body 条件插入）
  Widget _buildToolRow() {
    return EditorToolRow(
      tool: _tool,
      onSelectTool: (t) => setState(() {
        _tool = t;
        if (t != EditorTool.select) {
          _clearSelection();
        }
      }),
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
          // 速记画布尺寸（无 setState，build 期间赋值）——ZoomControls
          // 缩放边界计算用（闭包跨出本 builder）
          _lastCanvasSize = canvasSize;
          // 缩放/绘画手势分发（板设置页同款）：单指=当前工具作用；双指=
          // 捏合缩放+平移（手动驱动控制器）。IV 的 hit test 带逆变换，
          // localFocalPoint 天然是画布坐标——放大后点格依旧准
          return SizedBox(
            width: canvasSize.width,
            height: canvasSize.height,
            child: InteractiveViewer(
              transformationController: _viewerCtrl,
              maxScale: 10,
              panEnabled: false,
              scaleEnabled: false,
              boundaryMargin: const EdgeInsets.all(300),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 快速点按（无位移）scale 识别器不 accept，竞技场被 sweep
                // 给 tap——油漆桶/吸管这类「点一下」的工具走 onTapUp 通道
                // （板设置页同款双通道：点=onTapUp、拖/捏=onScale*；
                // 拖动时 tap 识别器被拒不会触发 onTapUp，无双重分发）
                onTapUp: (d) => _applyAt(d.localPosition, canvasSize,
                    isStart: true),
                onScaleStart: (d) {
                  _lastScale = 1.0;
                  if (d.pointerCount == 1) {
                    _applyAt(d.localFocalPoint, canvasSize, isStart: true);
                  }
                },
                onScaleUpdate: (d) {
                  if (d.pointerCount >= 2) {
                    _pinchZoom(d);
                    return;
                  }
                  // 查看工具单指拖动 = 平移画布（四箭头语义：只拖动看图）
                  // ——放大后单指也能拖着走；编辑工具的单指仍留给落笔
                  if (_tool == EditorTool.view) {
                    _panCanvas(d.focalPointDelta, canvasSize);
                    return;
                  }
                  _lastScale = 1.0;
                  _applyAt(d.localFocalPoint, canvasSize, isStart: false);
                },
                child: CustomPaint(
                  size: canvasSize,
                  painter: GridPainter(
                    model: _model,
                    palette: widget.palette,
                    selectedColorIndex: _currentColor,
                    repaint: _revision,
                    selectionRect: _selectionPixels(canvasSize),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 双指捏合缩放+平移：绕焦点缩放（[ScaleUpdateDetails.scale] 相对
  /// [_lastScale] 的增量）+ 焦点位移作平移；clamp [1, 10]。
  /// 自实现（IV 自带 scale 关闭）：单指要留给绘画，手势须在手势区
  /// 分发而不是让 IV 抢走（板设置页同款方案）
  void _pinchZoom(ScaleUpdateDetails d) {
    final cur = _viewerCtrl.value.getMaxScaleOnAxis();
    if (_lastScale <= 0 || d.scale <= 0) {
      return;
    }
    final next = (cur * d.scale / _lastScale).clamp(1.0, 10.0);
    final focal = d.localFocalPoint;
    // focalPointDelta 是子坐标（含 IV 逆变换），×cur 折算父空间才跟手
    final m = Matrix4.identity()
      ..translate(d.focalPointDelta.dx * cur, d.focalPointDelta.dy * cur)
      ..translate(focal.dx, focal.dy)
      ..scale(next / cur)
      ..translate(-focal.dx, -focal.dy);
    _viewerCtrl.value = m * _viewerCtrl.value;
    _lastScale = d.scale;
  }

  /// 查看工具单指平移画布（放大后拖看）。[delta] 是子坐标系位移，
  /// ×当前 scale 折算父空间；平移必须**前乘**（`T×M`，父空间）——
  /// 后乘 `M×T` 平移落在子空间会被 scale 再放大一次（2× 缩放时
  /// 实际平移 scale² 倍，实测 300px 手势把画布拖飞出屏）。
  /// clamp ±画布尺寸防拖飞
  void _panCanvas(Offset delta, Size canvasSize) {
    if (delta == Offset.zero) {
      return;
    }
    final scale = _viewerCtrl.value.getMaxScaleOnAxis();
    final m = Matrix4.identity()
      ..translate(delta.dx * scale, delta.dy * scale)
      ..multiply(_viewerCtrl.value);
    final s = m.storage;
    s[12] = s[12].clamp(-canvasSize.width, canvasSize.width).toDouble();
    s[13] = s[13].clamp(-canvasSize.height, canvasSize.height).toDouble();
    _viewerCtrl.value = m;
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

  /// 弹色卡网格选绘画色（吸管同源：选完自动从橡皮/查看切回画笔）
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
      if (_tool == EditorTool.eraser || _tool == EditorTool.view) {
        _tool = EditorTool.brush; // 点了颜色=要画：顺手切回画笔
      }
    });
  }
}
