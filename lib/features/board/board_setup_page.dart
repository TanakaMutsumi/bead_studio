import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/adaptive_text.dart';
import '../../core/app_snack_bar.dart';
import '../../core/board_config.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/zoom_controls.dart';
import 'assemble_page.dart';
import 'board_dialogs.dart';
import 'board_painter.dart';
import 'board_setup_panel.dart';
import 'board_stats.dart';
import 'major_color_picker.dart';
import 'placed_work.dart';

/// 豆板配置页：选板尺寸（52/78/104/自定义）+ 加粗框线（每5/8/10）+
/// 顶点相位四向微调 + 导入多件作品 + 选中后拖动摆放 + 豆数统计 → 开始拼豆
///
/// 交互约定：点作品选中（再点空白取消），选中后单指拖动该作品、
/// 右上角叉移除选中作品；未选中时单指平移画布、双指缩放。
/// 摆放是软约束：添加永远成功（找不到互不重叠的空位就落左上角），
/// 拖动自由摆放，压豆重叠处浅红标注；超板作品可拖动选哪一段落在板内。
/// 开始拼豆前才硬性要求：全部作品完整在板内且互不压豆（空豆位置交叠
/// 不碍事——判定按豆级，非矩形级）
///
/// 豆板管理：右上菜单「新建空板 / 打开豆板 / 另存为 / 删除当前板」；
/// 已命名豆板随增删/拖动/换板自动覆盖保存。「开始拼豆」与 back 退出都先弹
/// 保存确认（是=保存后继续；否=不保存继续；点外部=留在本页），未命名板
/// 选「是」先问豆板名。不打开旧豆板进入 = 新的空板
///
/// [initial] 保存作品后直接开始拼豆时带入的作品；null = 不带入
/// [initialBoard] 从豆板选择页进入时带入的豆板（载入其配置与作品摆位）；
/// 两个都 null = 新的空板
class BoardSetupPage extends StatefulWidget {
  final WorkEntry? initial;
  final BoardEntry? initialBoard;

  const BoardSetupPage({super.key, this.initial, this.initialBoard});

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
  int? _majorColor;

  ///< 粗框线颜色 ARGB（null = 默认橙；色板入口选择，随板持久化）
  Size _lastCanvasSize = Size.zero;

  ///< 画布内容尺寸速记（LayoutBuilder builder 内赋值供缩放边界计算用）
  String? _boardName;

  ///< 当前豆板名（null = 未命名新板，变更不落盘）
  File? _boardFile;

  ///< 已命名豆板的目标文件（自动覆盖保存用）
  int _selected = -1;

  ///< 选中作品索引（-1 = 无选中；只有选中后才能拖动）
  var _popAllowed = false;

  ///< 退出确认已通过（放行本次 pop，防 PopScope 拦截自己发起的 pop）
  final _viewerCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    if (e == null) {
      final b = widget.initialBoard;
      if (b != null) {
        _loadBoard(b); // 从豆板选择页进入：载入选中豆板（异步，含失效作品跳过）
      }
      return; // 都不带：新的空板（要继续旧板走「打开豆板」）
    }
    final b = e.board;
    if (b != null) {
      _bw = b.w;
      _bh = b.h;
      _interval = b.interval;
      _phaseX = b.phaseX;
      _phaseY = b.phaseY;
      _majorColor = b.majorColor;
    }
    final w = PlacedWork(
      entry: e,
      palette: const BeadPalette([]),
      rot: b?.rot ?? 0,
      flipH: b?.flipH ?? false,
      flipV: b?.flipV ?? false,
      ox: b?.ox ?? 0,
      oy: b?.oy ?? 0,
    );
    // 无历史偏移时按变换后尺寸居中（rot 奇数宽高互换，不能用原始宽高）
    if (b?.ox == null) {
      w.ox = ((_bw - w.model.width) / 2).round();
    }
    if (b?.oy == null) {
      w.oy = ((_bh - w.model.height) / 2).round();
    }
    w.clampTo(_bw, _bh);
    _works.add(w);
    _selected = 0;
    _resolvePalette(0);
  }

  @override
  void dispose() {
    _viewerCtrl.dispose();
    super.dispose();
  }

  // ==================== 豆板管理（保存/打开/新建） ====================

  /// 当前编辑状态打包（板配置 + 作品引用）
  BoardSession _currentSession(String name) => BoardSession(
        name: name,
        board: BoardConfig(
          w: _bw,
          h: _bh,
          interval: _interval,
          phaseX: _phaseX,
          phaseY: _phaseY,
          majorColor: _majorColor,
        ),
        works: [
          for (final w in _works)
            BoardSessionWork(
              file: w.entry.file,
              ox: w.ox,
              oy: w.oy,
              rot: w.rot,
              flipH: w.flipH,
              flipV: w.flipV,
            ),
        ],
      );

  /// 已命名豆板自动覆盖保存（增删/拖动结束/换板/换相位后调用；未命名板不落盘）
  Future<void> _persistBoard() async {
    final name = _boardName;
    if (name == null) {
      return;
    }
    _boardFile = await DraftStore.saveBoardFile(_currentSession(name));
  }

  /// 打开豆板列表（BottomSheet 点选载入）
  Future<void> _openBoardPicker() async {
    final boards = await DraftStore.listBoards();
    if (!mounted) {
      return;
    }
    if (boards.isEmpty) {
      AppSnackBar.show(context, "还没有保存过豆板，先摆好再「另存为豆板」");
      return;
    }
    final picked = await showModalBottomSheet<BoardEntry>(
      context: context,
      builder: (sctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text("打开豆板", style: Theme.of(sctx).textTheme.titleMedium),
            ),
            for (final b in boards)
              ListTile(
                leading: const Icon(Icons.grid_view_outlined),
                title: Text(b.name),
                subtitle: Text(
                  "${b.workCount} 件作品 · ${b.boardLabel}"
                  " · ${b.updatedAt.month}/${b.updatedAt.day} "
                  "${b.updatedAt.hour.toString().padLeft(2, "0")}:"
                  "${b.updatedAt.minute.toString().padLeft(2, "0")}",
                ),
                onTap: () => Navigator.pop(sctx, b),
              ),
          ],
        ),
      ),
    );
    if (picked == null) {
      return;
    }
    await _loadBoard(picked);
  }

  /// 载入一块豆板（板配置 + 作品引用逐个读回；失效作品文件跳过）
  Future<void> _loadBoard(BoardEntry picked) async {
    final session = await DraftStore.loadBoardFile(picked.file);
    if (session == null || !mounted) {
      return;
    }
    setState(() {
      _boardName = session.name;
      _boardFile = picked.file;
      _bw = session.board.w;
      _bh = session.board.h;
      _interval = session.board.interval;
      _phaseX = session.board.phaseX;
      _phaseY = session.board.phaseY;
      _majorColor = session.board.majorColor;
      _works.clear();
      _selected = -1;
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
        rot: sw.rot,
        flipH: sw.flipH,
        flipV: sw.flipV,
        ox: sw.ox,
        oy: sw.oy,
      )..clampTo(_bw, _bh);
      setState(() => _works.add(w));
    }
  }

  /// 另存为豆板（输入名字保存；保存后随编辑自动覆盖）
  Future<void> _saveBoardAs() async {
    final n = await _askBoardName("另存为豆板");
    if (n == null) {
      return;
    }
    _boardFile = await DraftStore.saveBoardFile(_currentSession(n));
    if (!mounted) {
      return; // 保存已完成，页面销毁只跳过 UI 更新
    }
    setState(() => _boardName = n);
    AppSnackBar.show(context, "已保存豆板「$n」，继续编辑会自动保存");
  }

  /// 询问豆板名（预填当前名；取消返回 null；空名在框内拦截不关框）
  Future<String?> _askBoardName(String title) async {
    final ctrl = TextEditingController(text: _boardName ?? "");
    final name = await _inputDialog(
      title,
      "豆板名",
      ctrl,
      emptyError: "豆板名不能为空",
    );
    final n = name?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  /// 确保当前豆板已保存：已命名板直接覆盖；未命名板先问名字（取消返回 false）
  Future<bool> _ensureSaved() async {
    final name = _boardName;
    if (name != null) {
      _boardFile = await DraftStore.saveBoardFile(_currentSession(name));
      return true;
    }
    final n = await _askBoardName("保存豆板");
    if (n == null || !mounted) {
      return false;
    }
    _boardFile = await DraftStore.saveBoardFile(_currentSession(n));
    if (!mounted) {
      return true; // 保存已完成，页面销毁只跳过 UI 更新（调用方另查 mounted）
    }
    setState(() => _boardName = n);
    AppSnackBar.show(context, "已保存豆板「$n」");
    return true;
  }

  /// 确认框：否(false) / 是(true)；[cancelLabel] 非空时首个按钮是显式
  /// 「取消」（返回 null，与点外部同义）——是/否/取消三键场景用
  Future<bool?> _confirmDialog(
    String title,
    String content, {
    String? cancelLabel,
  }) {
    return confirmDialog(context, title, content, cancelLabel: cancelLabel);
  }

  /// back 退出确认：板上有作品时问是否保存——显式三键（是=保存退出 /
  /// 否=不保存直接退出 / 取消=留在本页；点外部同取消）
  Future<void> _confirmExit() async {
    if (_works.isEmpty) {
      _doExit();
      return;
    }
    final save = await _confirmDialog(
      "保存豆板？",
      "「是」保存当前豆板后退出；「否」不保存直接退出；「取消」留在本页",
      cancelLabel: "取消",
    );
    if (save == null || !mounted) {
      return;
    }
    if (save) {
      final ok = await _ensureSaved();
      if (!ok || !mounted) {
        return; // 未命名板放弃输名字：留在本页
      }
    }
    _doExit();
  }

  /// 放行并执行退出（先置 _popAllowed 再等重建完成后 pop，否则会被 PopScope 再次拦截）
  void _doExit() {
    setState(() => _popAllowed = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  /// 新建空板（当前摆板丢弃，确认后执行）
  Future<void> _newBoard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text("新建空板？"),
        content: const Text("当前摆板未保存的改动会丢弃"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text("新建"),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    setState(() {
      _boardName = null;
      _boardFile = null;
      _bw = 52;
      _bh = 52;
      _interval = 5;
      _phaseX = 0;
      _phaseY = 0;
      _majorColor = null;
      _works.clear();
      _selected = -1;
    });
  }

  /// 删除当前已命名豆板（删文件并回到空板态）
  Future<void> _deleteBoard() async {
    final f = _boardFile;
    final name = _boardName;
    if (f == null || name == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text("删除豆板「$name」？"),
        content: const Text("只删摆板布局，作品本身不受影响，删除后无法恢复"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text("删除"),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    await DraftStore.deleteBoardFile(f);
    if (!mounted) {
      return;
    }
    setState(() {
      _boardName = null;
      _boardFile = null;
      _works.clear();
      _selected = -1;
    });
  }

  /// 单行输入对话框，取消返回 null；[emptyError] 非空时空值点确定
  /// 不关框、输入框下红字提示（豆板名必填，替代旧版静默关框无反应）
  Future<String?> _inputDialog(
    String title,
    String hint,
    TextEditingController ctrl, {
    String? emptyError,
  }) {
    return inputDialog(context, title, hint, ctrl, emptyError: emptyError);
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
        work.clampTo(w, h); // 换板保留相对布局，出界作品拉回可达范围
      }
    });
    _persistBoard();
  }

  void _setInterval(int v) {
    setState(() {
      _interval = v;
      _phaseX = _phaseX.clamp(0, v - 1);
      _phaseY = _phaseY.clamp(0, v - 1);
    });
    _persistBoard();
  }

  /// 粗框线颜色圆钮：显示当前颜色（null = 默认橙），点开色板选择
  Widget _majorColorDot() {
    final c = Color(_majorColor ?? BoardConfig.defaultMajorColor);
    return Tooltip(
      message: "粗框线颜色",
      child: InkWell(
        onTap: _pickMajorColor,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black38),
          ),
        ),
      ),
    );
  }

  /// 粗框线颜色色板（共用 major_color_picker）：选中默认橙存 null
  ///（与未配置旧板同语义），其余存显式 ARGB；随板持久化
  Future<void> _pickMajorColor() async {
    final picked = await showMajorColorPicker(context, _majorColor);
    if (picked == null || !mounted) {
      return; // 点外部/取消不改动
    }
    setState(() {
      _majorColor = picked == BoardConfig.defaultMajorColor ? null : picked;
    });
    _persistBoard();
  }

  // 顶点相位：phaseX 增 = 竖粗线左移，减 = 右移；phaseY 增 = 横粗线上移，减 = 下移
  void _shiftPhase({int dx = 0, int dy = 0}) {
    setState(() {
      _phaseX = (_phaseX + dx + _interval) % _interval;
      _phaseY = (_phaseY + dy + _interval) % _interval;
    });
    _persistBoard();
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
        AppSnackBar.show(context, "尺寸须在 8~400 之间");
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
      AppSnackBar.show(context, "作品库为空，先去保存一个作品");
      return;
    }
    // 不按「已在板上」过滤：同一作品可重复添加多件（拼两幅同款等场景），
    // 重复件各占一块板位、可单独叉掉
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
            for (final w in all)
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
    // 找不到空位不拒绝：落 (0,0) 照常摆上（重叠处浅红标注，可再拖开）；
    // 超板作品同样放行（出界部分悬挂板外右/下）
    final (ox, oy) = spot ?? (0, 0);
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
    if (spot == null && mounted) {
      AppSnackBar.show(context, "没找到空位：已放在左上角，重叠处浅红标注，可拖开");
    }
    _resolvePalette(_works.length - 1);
    _persistBoard();
  }

  /// 找第一个放得下的空位（行扫描，不与已摆作品矩形相交）
  ///
  /// 空板从 (0,0) 角落起排（多件堆排友好；居中会让第二件找不到空位）；
  /// 超板或无空位返回 null（调用方落 (0,0) 重叠摆放，不再拒绝添加）
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

  ///< (nx,ny) 尺寸 (mw,mh) 的矩形是否与 skipIdx 之外的作品相交
  bool _wouldOverlap(int skipIdx, int nx, int ny, int mw, int mh) {
    for (var i = 0; i < _works.length; i++) {
      if (i == skipIdx) {
        continue;
      }
      final o = _works[i];
      final om = o.model;
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
    _persistBoard();
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
        // 矩阵更新本身无需 setState（InteractiveViewer 应用变换），但
        // BoardPainter 的 viewScale（删除叉尺寸补偿）依赖重建取新值，
        // 缩放中跟随刷新——shouldRepaint 挡住非缩放场景的重画
        setState(() {});
      }
      _lastScale = d.scale;
      return;
    }
    _lastScale = 1.0;

    // 单指 + 选中：按格拖动选中作品（自由摆放：允许重叠，重叠处浅红
    // 标注；超板作品允许负偏移，拖动选哪一段落在板内）
    if (_selected >= 0 && _selected < _works.length) {
      final w = _works[_selected];
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
      final m = w.model;
      // 偏移可达范围与 clampTo 同口径：放得下 [0, 板边-作品边]；超板
      // [板边-作品边, 0]（出界部分悬挂板外左/上）
      final nx = (w.ox + dx)
          .clamp(math.min(0, _bw - m.width), math.max(0, _bw - m.width))
          .toInt();
      final ny = (w.oy + dy)
          .clamp(math.min(0, _bh - m.height), math.max(0, _bh - m.height))
          .toInt();
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
    // 删除叉命中检测（仅选中作品，与 painter 画叉同款几何）：圆心=作品
    // 右上角顶点，半径按视图缩放补偿（放大后命中区视觉恒定）
    final cellW = canvasW / _bw;
    final cellH = canvasH / _bh;
    final hitR = 26 / _viewerCtrl.value.getMaxScaleOnAxis();
    for (var i = _works.length - 1; i >= 0; i--) {
      if (i != _selected) {
        continue; // 只有选中作品的叉可点（与 painter 只给选中作品画叉一致）
      }
      final w = _works[i];
      final m = w.model;
      final center = Offset((w.ox + m.width) * cellW, w.oy * cellH);
      if ((local - center).distance <= hitR) {
        _confirmRemoveAt(i);
        return;
      }
    }
    final bx = (local.dx / (canvasW / _bw)).floor();
    final by = (local.dy / (canvasH / _bh)).floor();
    var hit = -1;
    for (var i = _works.length - 1; i >= 0; i--) {
      final w = _works[i];
      final m = w.model;
      if (bx >= w.ox &&
          bx < w.ox + m.width &&
          by >= w.oy &&
          by < w.oy + m.height) {
        hit = i;
        break;
      }
    }
    setState(() => _selected = hit);
  }

  /// 删除板上作品确认（作品右上角小叉入口）：确认文案带作品名；从板上
  /// 移除不影响作品库原作品。await 弹窗期间列表可能被并发改动，回来后
  /// 索引越界复查再动手
  Future<void> _confirmRemoveAt(int index) async {
    if (index < 0 || index >= _works.length) {
      return;
    }
    final name = _works[index].entry.name;
    final ok = await _confirmDialog(
      "删除作品？",
      "把「$name」从板上移除？（作品库里的原作品不受影响）",
    );
    if (ok != true || !mounted) {
      return;
    }
    if (index >= _works.length) {
      return; // 弹窗期间列表已变，索引失效放弃本次删除
    }
    setState(() {
      _works.removeAt(index);
      if (_selected == index) {
        _selected = -1;
      } else if (_selected > index) {
        _selected--;
      }
    });
    _persistBoard();
  }

  // ==================== 豆数统计 ====================

  /// 变换选中作品（旋转 ±90°/翻转），clamp 回板内并持久化
  void _transformSelected({int? rotDelta, bool? flipH, bool? flipV}) {
    if (_selected < 0 || _selected >= _works.length) {
      return;
    }
    final w = _works[_selected];
    w.setTransform(
      rot: rotDelta == null ? null : (w.rot + rotDelta) % 4,
      flipH: flipH == null ? null : !w.flipH,
      flipV: flipV == null ? null : !w.flipV,
    );
    w.clampTo(_bw, _bh);
    setState(() {});
    _persistBoard();
  }

  /// 豆数统计明细（BottomSheet：色块 + 色号/名 + 颗数，按颗数降序）
  Future<void> _showBeadStats() {
    return showBeadStatsSheet(context, works: _works);
  }

  // ==================== 开始拼豆 ====================

  /// 摆放是否就绪（开始拼豆的硬门槛）：全部作品完整在板内且互不压豆
  ///（空豆位置交叠不算冲突）。摆放期间超板/压豆只是浅红提示，进入
  /// 实际拼豆前必须收拾干净
  bool _boardClean() =>
      !_works.any((w) => !w.fits(_bw, _bh)) && !boardHasOverlap(_works);

  /// 开始拼豆：确认「保存并开始拼豆？」（是=保存后进入；否/点外部=留在本页）
  Future<void> _startAssemble() async {
    if (_works.isEmpty) {
      return;
    }
    if (_works.any((w) => !w.fits(_bw, _bh))) {
      AppSnackBar.show(context, "有作品超出豆板（可换大板或自定义尺寸）");
      return;
    }
    if (boardHasOverlap(_works)) {
      AppSnackBar.show(context, "作品有压豆重叠（浅红标注处），拖开后再开始拼豆");
      return;
    }
    final save = await _confirmDialog("保存并开始拼豆？", "保存当前豆板后进入拼豆");
    if (save != true || !mounted) {
      return;
    }
    final ok = await _ensureSaved();
    if (!ok || !mounted) {
      return; // 未命名板放弃输名字：留在本页
    }
    final board = BoardConfig(
      w: _bw,
      h: _bh,
      interval: _interval,
      phaseX: _phaseX,
      phaseY: _phaseY,
      majorColor: _majorColor,
    );
    // 板配置（含各自偏移与变换）随各作品持久化；placed 逆映射回原坐标
    // 保存（作品文件存原始坐标系，不感知变换）
    for (final w in _works) {
      await DraftStore.saveWork(
        w.entry.model,
        overwrite: w.entry.file,
        board: board.copyWith(
          ox: w.ox,
          oy: w.oy,
          rot: w.rot,
          flipH: w.flipH,
          flipV: w.flipV,
        ),
        placed: w.placedOriginal(),
      );
    }
    if (!mounted) {
      return;
    }
    // pushReplacement：拼豆页返回时退到「选择豆板」页而不是本页
    //（2026-11-11 需求：拼豆是本链路终点，回去的下一站是换板/换作品；
    // 要重新摆板从选择页再进即可，进度随作品文件保留）
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AssemblePage(works: List.of(_works), board: board),
      ),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final presetSelected = _presets.any((s) => s == _bw && s == _bh);
    return PopScope(
      // back 先问保存（是/否/取消）；空板与已确认退出直接放行
      canPop: _popAllowed || _works.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: AdaptiveTitleText(
              _boardName == null ? "拼豆板设置" : "拼豆板 · $_boardName"),
          actions: [
            if (_selected >= 0) ...[
              IconButton(
                onPressed: () => _transformSelected(rotDelta: 3),
                icon: const Icon(Icons.rotate_left),
                tooltip: "逆时针旋转 90°",
              ),
              IconButton(
                onPressed: () => _transformSelected(rotDelta: 1),
                icon: const Icon(Icons.rotate_right),
                tooltip: "顺时针旋转 90°",
              ),
              IconButton(
                onPressed: () => _transformSelected(flipH: true),
                icon: const Icon(Icons.flip),
                tooltip: "左右翻转",
              ),
              IconButton(
                onPressed: () => _transformSelected(flipV: true),
                icon: const RotatedBox(
                  quarterTurns: 1,
                  child: Icon(Icons.flip),
                ),
                tooltip: "上下翻转",
              ),
              IconButton(
                onPressed: _removeSelected,
                icon: const Icon(Icons.close),
                tooltip: "移除选中作品",
              ),
            ],
            PopupMenuButton<String>(
              tooltip: "豆板菜单",
              onSelected: (action) {
                switch (action) {
                  case "new":
                    _newBoard();
                  case "open":
                    _openBoardPicker();
                  case "saveas":
                    _saveBoardAs();
                  case "delete":
                    _deleteBoard();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: "new", child: Text("新建空板")),
                const PopupMenuItem(value: "open", child: Text("打开豆板…")),
                const PopupMenuItem(value: "saveas", child: Text("另存为豆板…")),
                if (_boardFile != null)
                  const PopupMenuItem(
                    value: "delete",
                    child: Text("删除当前豆板"),
                  ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            _buildConfigRows(presetSelected),
            Expanded(child: _buildCanvas()),
            // 缩放控制组（外置条，不放画布上——浮在画布会挡作品删除叉）：
            // 放大/缩小（以画面中心为锚）+ 还原全幅。onChanged 里 setState
            // ——viewScale（叉尺寸补偿）须随矩阵变化刷新。Center 内
            // constrained IV 的视口=画布盒（与内容同尺寸），显式传
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
              child: Align(
                alignment: Alignment.centerRight,
                child: ZoomControls(
                  controller: _viewerCtrl,
                  contentSize: () => _lastCanvasSize,
                  viewportSize: () => _lastCanvasSize,
                  maxScale: 10,
                  onChanged: () => setState(() {}),
                ),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigRows(bool presetSelected) {
    return BoardConfigPanel(
      presetSelected: presetSelected,
      bw: _bw,
      bh: _bh,
      interval: _interval,
      majorColorDot: _majorColorDot(),
      worksCount: _works.length,
      stats: beadStats(_works),
      onSelectPreset: _setBoardSize,
      onCustom: _openCustomSize,
      onSetInterval: _setInterval,
      onShiftPhase: _shiftPhase,
      onShowStats: _showBeadStats,
    );
  }

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
    return Stack(
      children: [
        Center(
          child: Padding(
            // 板四周留边距：板外框（加粗黑边）撑满宽时贴屏幕边，粗线被
            // 屏幕边吃掉看不清——原始效果板不顶到屏幕边
            padding: const EdgeInsets.all(8),
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
                    // 速记画布内容尺寸（无 setState，build 期间赋值）——
                    // ZoomControls 缩放边界计算用（闭包跨出本 builder）
                    _lastCanvasSize = Size(canvasW, canvasH);
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
                      onScaleEnd: (_) => _persistBoard(),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: BoardPainter(
                          board: BoardConfig(
                            w: _bw,
                            h: _bh,
                            interval: _interval,
                            phaseX: _phaseX,
                            phaseY: _phaseY,
                            // 本页预览也要带粗线色（否则色板选色只在拼豆
                            // 页生效，本页恒默认橙、状态已变视图不反映）
                            majorColor: _majorColor,
                          ),
                          // viewScale：删除叉尺寸/线宽补偿（缩放中视觉恒定）；
                          // showClose：仅选中作品画右上角删除叉（先点选中、
                          // 再点叉删，未选中不显示也不可点，防误触）
                          viewScale: _viewerCtrl.value.getMaxScaleOnAxis(),
                          items: [
                            for (var i = 0; i < _works.length; i++)
                              BoardPaintItem(
                                model: _works[i].model,
                                palette: _works[i].palette,
                                ox: _works[i].ox,
                                oy: _works[i].oy,
                                showBorder: true,
                                selected: i == _selected,
                                showClose: i == _selected,
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar() {
    return BoardBottomBar(
      works: _works,
      bw: _bw,
      bh: _bh,
      onAddWork: _openWorkPicker,
      onStart: _works.isNotEmpty && _boardClean() ? _startAssemble : null,
    );
  }
}
