import 'package:flutter/material.dart';

import '../../core/board_config.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import 'assemble_page.dart';
import 'board_painter.dart';
import 'placed_work.dart';

/// 豆板配置页：选板尺寸（52/78/104/自定义）+ 加粗框线（每5/8/10）+
/// 顶点相位四向微调 + 导入多件作品 + 选中后拖动摆放 + 豆数统计 → 开始拼豆
///
/// 交互约定：点作品选中（再点空白取消），选中后单指拖动该作品、
/// 右上角叉移除选中作品；未选中时单指平移画布、双指缩放。
/// 作品之间不能相交：添加时找空位（无空位拒绝），拖动贴边滑动不产生重叠
///
/// [initial] 保存作品后直接开始拼豆时带入的作品；null = 从主界面进入，
/// 恢复上次会话（板配置 + 已摆作品），页内「添加作品」继续补充
class BoardSetupPage extends StatefulWidget {
  final WorkEntry? initial;

  const BoardSetupPage({super.key, this.initial});

  @override
  State<BoardSetupPage> createState() => _BoardSetupPageState();
}

class _BoardSetupPageState extends State<BoardSetupPage> {
  static const _presets = [52, 78, 104];

  final List<PlacedWork> _works = [];

  ///< 板上作品列表（后加入的画在上层）
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
  int _selected = -1;

  ///< 选中作品索引（-1 = 无选中；只有选中后才能拖动）
  final _viewerCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    if (e != null) {
      final b = e.board;
      if (b != null) {
        _bw = b.w;
        _bh = b.h;
        _interval = b.interval;
        _phaseX = b.phaseX;
        _phaseY = b.phaseY;
      }
      final w = PlacedWork(
        entry: e,
        palette: const BeadPalette([]),
        ox: b?.ox ?? ((_bw - e.model.width) / 2).round(),
        oy: b?.oy ?? ((_bh - e.model.height) / 2).round(),
      );
      w.clampTo(_bw, _bh);
      _works.add(w);
      _selected = 0;
      _resolvePalette(0);
      _persistSession();
    } else {
      _restoreSession();
    }
  }

  @override
  void dispose() {
    _viewerCtrl.dispose();
    super.dispose();
  }

  /// 恢复上次豆板会话（板配置 + 作品引用逐个读回，失效文件跳过）
  Future<void> _restoreSession() async {
    final session = await DraftStore.loadBoardSession();
    if (session == null || !mounted) {
      return;
    }
    setState(() {
      _bw = session.board.w;
      _bh = session.board.h;
      _interval = session.board.interval;
      _phaseX = session.board.phaseX;
      _phaseY = session.board.phaseY;
    });
    final selected = await PaletteRegistry.loadSelected();
    for (final sw in session.works) {
      final WorkEntry entry;
      try {
        entry = await DraftStore.readEntry(sw.file);
      } catch (_) {
        continue; // 作品文件已删/损坏，跳过
      }
      if (!mounted) {
        return;
      }
      final palette = await PaletteRegistry.resolveForModel(
        entry.model,
        selected.palette,
      );
      if (!mounted) {
        return;
      }
      final w = PlacedWork(
        entry: entry,
        palette: palette,
        ox: sw.ox,
        oy: sw.oy,
      )..clampTo(_bw, _bh);
      setState(() => _works.add(w));
    }
  }

  /// 会话落盘（增删/拖动结束/换板/换相位后调用）
  Future<void> _persistSession() async {
    await DraftStore.saveBoardSession(
      BoardSession(
        board: BoardConfig(
          w: _bw,
          h: _bh,
          interval: _interval,
          phaseX: _phaseX,
          phaseY: _phaseY,
        ),
        works: [
          for (final w in _works)
            BoardSessionWork(file: w.entry.file, ox: w.ox, oy: w.oy),
        ],
      ),
    );
  }

  Future<void> _resolvePalette(int index) async {
    final selected = await PaletteRegistry.loadSelected();
    if (index < 0 || index >= _works.length) {
      return;
    }
    final w = _works[index];
    final palette = await PaletteRegistry.resolveForModel(
      w.entry.model,
      selected.palette,
    );
    if (!mounted || index >= _works.length || _works[index] != w) {
      return;
    }
    setState(() => _works[index] = w.copyWith(palette: palette));
  }

  // ==================== 板参数 ====================

  void _setBoardSize(int side) => _applyBoardSize(side, side);

  void _applyBoardSize(int w, int h) {
    setState(() {
      _bw = w;
      _bh = h;
      for (final work in _works) {
        work.clampTo(w, h); // 换板保留相对布局，只把出界作品拉回板内
      }
    });
    _persistSession();
  }

  void _setInterval(int v) {
    setState(() {
      _interval = v;
      _phaseX = _phaseX.clamp(0, v - 1);
      _phaseY = _phaseY.clamp(0, v - 1);
    });
    _persistSession();
  }

  // 顶点相位：phaseX 增 = 竖粗线左移，减 = 右移；phaseY 增 = 横粗线上移，减 = 下移
  void _shiftPhase({int dx = 0, int dy = 0}) {
    setState(() {
      _phaseX = (_phaseX + dx + _interval) % _interval;
      _phaseY = (_phaseY + dy + _interval) % _interval;
    });
    _persistSession();
  }

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

  // ==================== 作品增删 ====================

  Future<void> _openWorkPicker() async {
    final all = await DraftStore.listWorks();
    if (!mounted) {
      return;
    }
    if (all.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("作品库为空，先去保存一个作品")));
      return;
    }
    final onBoard = _works.map((w) => w.entry.file.path).toSet();
    final candidates = all
        .where((w) => !onBoard.contains(w.file.path))
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("作品库的作品都已在板上，先叉掉一个再来添加")),
      );
      return;
    }
    final picked = await showModalBottomSheet<WorkEntry>(
      context: context,
      builder: (sctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "添加作品到板上",
                style: Theme.of(sctx).textTheme.titleMedium,
              ),
            ),
            for (final w in candidates)
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
    final spot = _findSpot(picked.model.width, picked.model.height);
    if (spot == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "放不下了：${picked.model.width}×${picked.model.height} 的作品在 "
              "$_bw×$_bh 板上找不到不与其他作品相交的空位（或超出板面）",
            ),
          ),
        );
      }
      return;
    }
    final (ox, oy) = spot;
    setState(() {
      _works.add(
        PlacedWork(
          entry: picked,
          palette: const BeadPalette([]),
          ox: ox,
          oy: oy,
        ),
      );
      _selected = _works.length - 1;
    });
    _resolvePalette(_works.length - 1);
    _persistSession();
  }

  /// 找第一个放得下的空位（行扫描，不与已摆作品矩形相交）
  ///
  /// 空板从 (0,0) 角落起排（多件堆排友好；居中会让第二件找不到空位）；
  /// 超板或无空位返回 null（调用方提示并拒绝添加）
  (int, int)? _findSpot(int w, int h) {
    if (w > _bw || h > _bh) {
      return null;
    }
    if (_works.isEmpty) {
      return (0, 0);
    }
    for (var y = 0; y + h <= _bh; y++) {
      for (var x = 0; x + w <= _bw; x++) {
        if (!_wouldOverlap(-1, x, y, w, h)) {
          return (x, y);
        }
      }
    }
    return null;
  }

  int _maxOf(int boardSide, int workSide) =>
      boardSide - workSide > 0 ? boardSide - workSide : 0;

  ///< (nx,ny) 尺寸 (mw,mh) 的矩形是否与 skipIdx 之外的作品相交
  bool _wouldOverlap(int skipIdx, int nx, int ny, int mw, int mh) {
    for (var i = 0; i < _works.length; i++) {
      if (i == skipIdx) {
        continue;
      }
      final o = _works[i];
      final om = o.entry.model;
      if (nx < o.ox + om.width &&
          nx + mw > o.ox &&
          ny < o.oy + om.height &&
          ny + mh > o.oy) {
        return true;
      }
    }
    return false;
  }

  /// 右上角叉：移除选中作品
  void _removeSelected() {
    if (_selected < 0 || _selected >= _works.length) {
      return;
    }
    setState(() {
      _works.removeAt(_selected);
      _selected = -1;
    });
    _persistSession();
  }

  // ==================== 摆放交互 ===================

  ///< 双指缩放手势内上一帧 scale（帧间增量换算用）
  var _lastScale = 1.0;

  ///< 拖动亚格像素累计器（逐帧 round 会丢亚格增量，攒够一整格才结算）
  var _accDx = 0.0;

  var _accDy = 0.0;

  /// 画布手势统一入口：
  /// 双指 = 缩放画布；单指+选中 = 按格拖动该作品；单指未选中 = 平移画布
  void _onCanvasScale(
    ScaleUpdateDetails d,
    double canvasW,
    double canvasH,
  ) {
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

    // 单指 + 选中：按格拖动选中作品（防相交：贴边滑动，不与其他作品重叠）
    if (_selected >= 0 && _selected < _works.length) {
      final w = _works[_selected];
      if (!w.fits(_bw, _bh)) {
        return; // 超板作品不给拖（先换大板）
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
      final m = w.entry.model;
      var nx = (w.ox + dx).clamp(0, _maxOf(_bw, m.width)).toInt();
      var ny = (w.oy + dy).clamp(0, _maxOf(_bh, m.height)).toInt();
      // 原位置不重叠时，新位置逐轴回退到贴边（贴着其他作品边缘滑走）；
      // 原位置本就重叠（历史遗留/换小板收拢）则放开限制，允许直接拖出
      if (!_wouldOverlap(_selected, w.ox, w.oy, m.width, m.height)) {
        while (nx != w.ox && _wouldOverlap(_selected, nx, ny, m.width, m.height)) {
          nx += nx > w.ox ? -1 : 1;
        }
        while (ny != w.oy && _wouldOverlap(_selected, nx, ny, m.width, m.height)) {
          ny += ny > w.oy ? -1 : 1;
        }
        if (_wouldOverlap(_selected, nx, ny, m.width, m.height)) {
          return; // 两轴都退无可退（正常拖动不会到这）
        }
      }
      setState(() {
        w.ox = nx;
        w.oy = ny;
      });
      return;
    }

    // 单指未选中：平移画布（跟手，clamp 防拖飞）
    final delta = d.focalPointDelta;
    final m = Matrix4.copy(_viewerCtrl.value)..translate(delta.dx, delta.dy);
    final s = m.storage;
    s[12] = s[12].clamp(-canvasW, canvasW).toDouble();
    s[13] = s[13].clamp(-canvasH, canvasH).toDouble();
    _viewerCtrl.value = m;
  }

  /// 点按命中测试：点中作品选中（上层优先），点空白取消选中
  void _onCanvasTap(Offset local, double canvasW, double canvasH) {
    final bx = (local.dx / (canvasW / _bw)).floor();
    final by = (local.dy / (canvasH / _bh)).floor();
    var hit = -1;
    for (var i = _works.length - 1; i >= 0; i--) {
      final w = _works[i];
      final m = w.entry.model;
      if (bx >= w.ox && bx < w.ox + m.width && by >= w.oy && by < w.oy + m.height) {
        hit = i;
        break;
      }
    }
    setState(() => _selected = hit);
  }

  // ==================== 豆数统计 ====================

  /// 板上全部作品的豆数加和：色号 -> 颗数（跨作品同色号合并）
  Map<String, int> _beadStats() {
    final stats = <String, int>{};
    for (final w in _works) {
      final m = w.entry.model;
      m.countByColor().forEach((v, n) {
        final id = v < m.paletteIds.length ? m.paletteIds[v] : "?$v";
        stats[id] = (stats[id] ?? 0) + n;
      });
    }
    return stats;
  }

  /// 色号查显示颜色（任一含该色的作品调色板）
  BeadColor? _colorOf(String id) {
    for (final w in _works) {
      final c = w.palette.byId(id);
      if (c != null) {
        return c;
      }
    }
    return null;
  }

  /// 豆数统计明细（BottomSheet：色块 + 色号/名 + 颗数，按颗数降序）
  Future<void> _showBeadStats() async {
    if (_works.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("板上还没有作品")));
      return;
    }
    final stats = _beadStats();
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
                "豆数统计 · ${_works.length} 件作品 · ${stats.length} 种色 · 共 $total 颗",
                style: Theme.of(sctx).textTheme.titleMedium,
              ),
            ),
            for (final e in entries)
              ListTile(
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _colorOf(e.key) != null
                        ? Color.fromARGB(
                            255,
                            _colorOf(e.key)!.r,
                            _colorOf(e.key)!.g,
                            _colorOf(e.key)!.b,
                          )
                        : Colors.grey,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.black26),
                  ),
                ),
                title: Text(
                  "${e.key} ${_colorOf(e.key)?.name ?? ""}".trim(),
                ),
                trailing: Text("${e.value} 颗"),
              ),
          ],
        ),
      ),
    );
  }

  // ==================== 开始拼豆 ====================

  Future<void> _startAssemble() async {
    if (_works.isEmpty || _works.any((w) => !w.fits(_bw, _bh))) {
      return;
    }
    final board = BoardConfig(
      w: _bw,
      h: _bh,
      interval: _interval,
      phaseX: _phaseX,
      phaseY: _phaseY,
    );
    // 板配置（含各自偏移）随各作品持久化；placed 进度不动
    for (final w in _works) {
      await DraftStore.saveWork(
        w.entry.model,
        overwrite: w.entry.file,
        board: board.copyWith(ox: w.ox, oy: w.oy),
        placed: w.entry.placed,
      );
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AssemblePage(works: List.of(_works), board: board),
      ),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final presetSelected = _presets.any((s) => s == _bw && s == _bh);
    return Scaffold(
      appBar: AppBar(
        title: const Text("拼豆板设置"),
        actions: [
          if (_selected >= 0)
            IconButton(
              onPressed: _removeSelected,
              icon: const Icon(Icons.close),
              tooltip: "移除选中作品",
            ),
        ],
      ),
      body: Column(
        children: [
          _buildConfigRows(presetSelected),
          Expanded(child: _buildCanvas()),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildConfigRows(bool presetSelected) {
    final stats = _beadStats();
    final total = stats.values.fold(0, (a, b) => a + b);
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
            "板 $_bw×$_bh · 每$_interval格加粗 · 点作品选中后拖动",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: _showBeadStats,
            child: Text(
              "${_works.length} 件作品 · ${stats.length} 种色 · $total 颗豆 ›",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
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
    if (_works.isEmpty) {
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

        ///< 平移/缩放由子层 onScaleUpdate 分发（未选中平移/选中拖作品/双指缩放）
        boundaryMargin: const EdgeInsets.all(300),
        child: AspectRatio(
          aspectRatio: _bw / _bh,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final canvasW = constraints.maxWidth;
              final canvasH = constraints.maxHeight;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onCanvasTap(
                  d.localPosition,
                  canvasW,
                  canvasH,
                ),
                onScaleStart: (_) {
                  _lastScale = 1.0;
                  _accDx = 0;
                  _accDy = 0;
                },
                onScaleUpdate: (d) => _onCanvasScale(d, canvasW, canvasH),
                onScaleEnd: (_) => _persistSession(),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: BoardPainter(
                    board: BoardConfig(
                      w: _bw,
                      h: _bh,
                      interval: _interval,
                      phaseX: _phaseX,
                      phaseY: _phaseY,
                    ),
                    items: [
                      for (var i = 0; i < _works.length; i++)
                        BoardPaintItem(
                          model: _works[i].entry.model,
                          palette: _works[i].palette,
                          ox: _works[i].ox,
                          oy: _works[i].oy,
                          showBorder: true,
                          selected: i == _selected,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final anyOverflow = _works.any((w) => !w.fits(_bw, _bh));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_works.isNotEmpty && anyOverflow)
            Text(
              "有作品超出豆板 $_bw×$_bh，请换大板或自定义尺寸",
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _openWorkPicker,
                icon: const Icon(Icons.library_add_outlined, size: 18),
                label: Text(_works.isEmpty ? "导入作品" : "添加作品"),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _works.isNotEmpty && !anyOverflow
                      ? _startAssemble
                      : null,
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
