import 'package:flutter/material.dart';

import '../../core/board_config.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/pattern_model.dart';
import 'assemble_page.dart';
import 'board_painter.dart';

/// 豆板配置页：选板尺寸（52/78/104/自定义）+ 加粗框线（每5/8/10）+
/// 顶点相位四向微调 + 导入作品 + 板上拖动摆放 → 开始拼豆
///
/// [initial] 保存作品后直接开始拼豆时带入的作品；null = 从主界面进入，
/// 页内「导入作品」从作品库选择
class BoardSetupPage extends StatefulWidget {
  final WorkEntry? initial;

  const BoardSetupPage({super.key, this.initial});

  @override
  State<BoardSetupPage> createState() => _BoardSetupPageState();
}

class _BoardSetupPageState extends State<BoardSetupPage> {
  static const _presets = [52, 78, 104];

  WorkEntry? _entry;
  BeadPalette _palette = const BeadPalette([]);

  var _bw = 52;

  ///< 板宽（格）
  var _bh = 52;

  ///< 板高（格）
  var _interval = 5;

  ///< 加粗框线间隔
  var _phaseX = 0;

  ///< 竖粗线相位
  var _phaseY = 0;

  ///< 横粗线相位
  var _ox = 0;

  ///< 作品列偏移
  var _oy = 0;

  ///< 作品行偏移
  final _viewerCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    if (e != null) {
      _entry = e;
      _restoreBoard(e);
      _resolvePalette(e);
    } else {
      _loadFallbackPalette();
    }
  }

  @override
  void dispose() {
    _viewerCtrl.dispose();
    super.dispose();
  }

  /// 恢复作品已保存的板配置（无则板 52 居中摆）
  void _restoreBoard(WorkEntry e) {
    final b = e.board;
    final m = e.model;
    if (b != null) {
      _bw = b.w;
      _bh = b.h;
      _interval = b.interval;
      _phaseX = b.phaseX;
      _phaseY = b.phaseY;
      _ox = b.ox;
      _oy = b.oy;
    } else {
      _ox = (_bw - m.width) ~/ 2;
      _oy = (_bh - m.height) ~/ 2;
    }
  }

  Future<void> _resolvePalette(WorkEntry e) async {
    final selected = await PaletteRegistry.loadSelected();
    final resolved = await PaletteRegistry.resolveForModel(
      e.model,
      selected.palette,
    );
    if (!mounted) {
      return;
    }
    setState(() => _palette = resolved);
  }

  Future<void> _loadFallbackPalette() async {
    final selected = await PaletteRegistry.loadSelected();
    if (mounted) {
      setState(() => _palette = selected.palette);
    }
  }

  // ==================== 板参数 ====================

  void _setBoardSize(int side) => _applyBoardSize(side, side);

  void _applyBoardSize(int w, int h) {
    setState(() {
      _bw = w;
      _bh = h;
      _centerWork();
    });
  }

  /// 作品摆到板中央（换板后重置摆放）
  void _centerWork() {
    final m = _entry?.model;
    if (m == null) {
      return;
    }
    _ox = ((_bw - m.width) / 2).round().clamp(0, _maxOx);
    _oy = ((_bh - m.height) / 2).round().clamp(0, _maxOy);
  }

  int get _maxOx => (_bw - (_entry?.model.width ?? 0)).clamp(0, _bw);

  int get _maxOy => (_bh - (_entry?.model.height ?? 0)).clamp(0, _bh);

  /// 作品是否完全放进板内
  bool get _fitsBoard {
    final m = _entry?.model;
    if (m == null) {
      return false;
    }
    return m.width <= _bw && m.height <= _bh;
  }

  void _setInterval(int v) => setState(() {
    _interval = v;
    _phaseX = _phaseX.clamp(0, v - 1);
    _phaseY = _phaseY.clamp(0, v - 1);
  });

  // 顶点相位：phaseX 增 = 竖粗线左移，减 = 右移；phaseY 增 = 横粗线上移，减 = 下移
  void _shiftPhase({int dx = 0, int dy = 0}) => setState(() {
    _phaseX = (_phaseX + dx + _interval) % _interval;
    _phaseY = (_phaseY + dy + _interval) % _interval;
  });

  /// 自定义板尺寸
  Future<void> _openCustomSize() async {
    final wCtrl = TextEditingController(text: "$_bw");
    final hCtrl = TextEditingController(text: "$_bh");
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text("自定义豆板尺寸"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: wCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "宽（格）",
                hintText: "8 ~ 400",
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: hCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "高（格）",
                hintText: "8 ~ 400",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text("确定"),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    final w = int.tryParse(wCtrl.text.trim()) ?? 0;
    final h = int.tryParse(hCtrl.text.trim()) ?? 0;
    if (w < 8 || h < 8 || w > 400 || h > 400) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("尺寸须在 8~400 之间")),
        );
      }
      return;
    }
    _applyBoardSize(w, h);
  }

  // ==================== 导入作品 ====================

  Future<void> _openWorkPicker() async {
    final works = await DraftStore.listWorks();
    if (!mounted) {
      return;
    }
    if (works.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("作品库为空，先去保存一个作品")));
      return;
    }
    final selected = await PaletteRegistry.loadSelected();
    final picked = await showModalBottomSheet<WorkEntry>(
      context: context,
      builder: (sctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "导入作品",
                style: Theme.of(sctx).textTheme.titleMedium,
              ),
            ),
            for (final w in works)
              ListTile(
                leading: const Icon(Icons.grid_on_outlined),
                title: Text(w.name),
                subtitle: Text(
                  "${w.model.width}×${w.model.height} · "
                  "${w.updatedAt.month}/${w.updatedAt.day} "
                  "${w.updatedAt.hour.toString().padLeft(2, "0")}:"
                  "${w.updatedAt.minute.toString().padLeft(2, "0")}",
                ),
                onTap: () => Navigator.pop(sctx, w),
              ),
          ],
        ),
      ),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _entry = picked;
      _restoreBoard(picked);
    });
    _resolvePalette(picked);
  }

  // ==================== 摆放拖动 ===================

  ///< 双指缩放手势内上一帧 scale（帧间增量换算用）
  var _lastScale = 1.0;

  ///< 拖动亚格像素累计器（逐帧 round 会丢亚格增量，攒够一整格才结算）
  var _accDx = 0.0;
  var _accDy = 0.0;

  /// 画布手势统一入口：单指拖 = 平移作品（格数换算含缩放补偿）；双指 = 缩放画布
  ///
  /// 手势收归本层而非 InteractiveViewer：其 ScaleGestureRecognizer 会在超 slop 时
  /// 主动抢占竞技场，导致子层 onPanUpdate 永远收不到单指拖动
  void _onCanvasScale(ScaleUpdateDetails d, double canvasW) {
    if (d.pointerCount >= 2) {
      final cur = _viewerCtrl.value.getMaxScaleOnAxis();
      var next = cur;
      if (_lastScale > 0 && d.scale > 0) {
        next = (cur * d.scale / _lastScale).clamp(1.0, 10.0);
        final focal = d.localFocalPoint;
        final m = Matrix4.identity()
          ..translate(focal.dx, focal.dy)
          ..scale(next / cur)
          ..translate(-focal.dx, -focal.dy);
        _viewerCtrl.value = m * _viewerCtrl.value;
      }
      _lastScale = d.scale;
      return;
    }
    _lastScale = 1.0;
    final m = _entry?.model;
    if (m == null || !_fitsBoard) {
      return;
    }
    final scale = _viewerCtrl.value.getMaxScaleOnAxis();
    final cell = canvasW / _bw / scale;
    _accDx += d.focalPointDelta.dx;
    _accDy += d.focalPointDelta.dy;
    final dx = (_accDx / cell).truncate();
    final dy = (_accDy / cell).truncate();
    if (dx == 0 && dy == 0) {
      return;
    }
    _accDx -= dx * cell;
    _accDy -= dy * cell;
    setState(() {
      _ox = (_ox + dx).clamp(0, _maxOx).toInt();
      _oy = (_oy + dy).clamp(0, _maxOy).toInt();
    });
  }

  // ==================== 开始拼豆 ====================

  Future<void> _startAssemble() async {
    final e = _entry;
    final m = e?.model;
    if (e == null || m == null || !_fitsBoard) {
      return;
    }
    final board = BoardConfig(
      w: _bw,
      h: _bh,
      interval: _interval,
      phaseX: _phaseX,
      phaseY: _phaseY,
      ox: _ox,
      oy: _oy,
    );
    // 板配置随作品持久化（placed 进度不动）
    await DraftStore.saveWork(
      m,
      overwrite: e.file,
      board: board,
      placed: e.placed,
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AssemblePage(
          entry: e,
          board: board,
          palette: _palette,
          placed: e.placed,
        ),
      ),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final m = _entry?.model;
    final presetSelected = _presets.any(
      (s) => s == _bw && s == _bh,
    );
    return Scaffold(
      appBar: AppBar(title: const Text("拼豆板设置")),
      body: Column(
        children: [
          _buildConfigRows(presetSelected),
          Expanded(child: _buildCanvas()),
          _buildBottomBar(m),
        ],
      ),
    );
  }

  Widget _buildConfigRows(bool presetSelected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    for (final s in _presets)
                      ButtonSegment(value: s, label: Text("$s×$s")),
                    const ButtonSegment(value: 0, label: Text("自定义")),
                  ],
                  selected: presetSelected ? {_bw} : const {0},
                  onSelectionChanged: (sel) {
                    if (sel.first > 0) {
                      _setBoardSize(sel.first);
                    } else {
                      _openCustomSize();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text("加粗框线", style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 5, label: Text("每5")),
                    ButtonSegment(value: 8, label: Text("每8")),
                    ButtonSegment(value: 10, label: Text("每10")),
                  ],
                  selected: {_interval},
                  onSelectionChanged: (sel) => _setInterval(sel.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text("顶点", style: Theme.of(context).textTheme.labelMedium),
              _phaseBtn(Icons.arrow_back, "竖线左移", () => _shiftPhase(dx: 1)),
              _phaseBtn(Icons.arrow_forward, "竖线右移", () => _shiftPhase(dx: -1)),
              _phaseBtn(Icons.arrow_upward, "横线上移", () => _shiftPhase(dy: 1)),
              _phaseBtn(Icons.arrow_downward, "横线下移", () => _shiftPhase(dy: -1)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "板 $_bw×$_bh · 粗线偏移 横 $_phaseY/$_interval 竖 $_phaseX/$_interval · 拖动图上作品调整位置，双指缩放",
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _phaseBtn(IconData icon, String tip, VoidCallback onTap) => IconButton(
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    tooltip: tip,
    visualDensity: VisualDensity.compact,
  );

  Widget _buildCanvas() {
    final m = _entry?.model;
    if (m == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add_photo_alternate_outlined,
              size: 48,
              color: Colors.black26,
            ),
            const SizedBox(height: 8),
            const Text("还没有导入作品", style: TextStyle(color: Colors.black38)),
          ],
        ),
      );
    }
    return Center(
      child: InteractiveViewer(
        transformationController: _viewerCtrl,
        maxScale: 10,
        panEnabled: false,
        scaleEnabled: false,

        ///< 双指缩放由子层 onScaleUpdate 驱动，避免其手势抢占单指拖动
        boundaryMargin: const EdgeInsets.all(300),
        child: AspectRatio(
          aspectRatio: _bw / _bh,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final canvasW = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) {
                  _lastScale = 1.0;
                  _accDx = 0;
                  _accDy = 0;
                },
                onScaleUpdate: (d) => _onCanvasScale(d, canvasW),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: BoardPainter(
                    board: BoardConfig(
                      w: _bw,
                      h: _bh,
                      interval: _interval,
                      phaseX: _phaseX,
                      phaseY: _phaseY,
                      ox: _ox,
                      oy: _oy,
                    ),
                    model: m,
                    palette: _palette,
                    showWorkBorder: true,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(PatternModel? m) {
    final fits = _fitsBoard;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m != null && !fits)
            Text(
              "作品 ${m.width}×${m.height} 超出豆板 $_bw×$_bh，请换大板或自定义尺寸",
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _openWorkPicker,
                icon: const Icon(Icons.library_add_outlined, size: 18),
                label: Text(m == null ? "导入作品" : "更换作品"),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: m != null && fits ? _startAssemble : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text("开始拼豆"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
