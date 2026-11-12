import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/adaptive_text.dart';
import '../../core/app_snack_bar.dart';
import '../../core/board_config.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/zoom_controls.dart';
import '../editor/grid_painter.dart';
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
/// 拖动自由摆放（宽/高最多移出板外二分之一，出界部分悬挂板外），
/// 压豆重叠与豆子出板处红标标注。开始拼豆前才硬性要求：没有非空白
/// 豆格出板且互不压豆（空白格出板/空豆位置交叠不碍事——判定按豆级）
///
/// 豆板管理：右上「保存豆板」图标 + 撤销/重做图标（随编辑历史启停）+
/// ⋮ 菜单（保存/另存为…/新建/打开…/删除，仅已命名板有删除）。改动不再
/// 连续自动保存——dirty 由状态键派生（_stateKey 与最近保存基线比对，
/// undo 回到已存态自动变 clean）；有未保存修改时新建/打开其他豆板/
/// back 退出统一弹三键确认（保存/不保存/取消，Office 规范），干净板
/// 静默放行。未命名板选「保存」先问豆板名。不打开旧豆板进入 = 新的空板
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
  final List<PlacedWork> _works = [];

  ///< 板上作品列表（后加入的画在上层）
  var _bw = 52;

  ///< 板宽（格）
  var _bh = 52;

  ///< 板高（格）

  /// 画布板外余量（格）：作品宽/高各自最多悬挂 floor(W/2) 出板（clampTo
  /// 半界口径），画布按板上最大作品的可能悬挂量对称留边——CustomPaint
  /// 越界绘制会被 cull 裁掉，余量必须算进画布尺寸。空板 0（画布即板）。
  /// 拼豆门槛拦的是「非空白格出板」，空白悬挂不拦但同样要画得出来
  int get _padX => _works.isEmpty
      ? 0
      : _works
            .map((w) => (w.model.width + 1) ~/ 2)
            .reduce((a, b) => a > b ? a : b);
  int get _padY => _works.isEmpty
      ? 0
      : _works
            .map((w) => (w.model.height + 1) ~/ 2)
            .reduce((a, b) => a > b ? a : b);
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
  String? _savedKey;

  ///< 最近保存/载入时的状态键（null = 尚无基线，视为 clean）。dirty 由
  ///< 键比对派生，免手工维护 flag——undo 回到已存态自动变 clean
  final List<_SetupSnap> _undoStack = [];

  ///< 撤销栈（栈顶 = 最近一次改动前的状态；上限 50 步，超出丢最旧）
  final List<_SetupSnap> _redoStack = [];

  ///< 重做栈（undo 时压入当前态；任何新改动即清空）
  _SetupSnap? _dragSnap;

  ///< 拖动手势起手快照（onScaleStart 捕获，onScaleEnd 真有位移才入栈）
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
      _savedKey = _stateKey(); // 载入失败/空板的兜底基线（载入成功后刷新）
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
    _savedKey = _stateKey();
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

  // ==================== dirty 状态与撤销/重做 ====================

  /// 当前状态键：板配置 + 各作品（文件@偏移@变换）。与 [_savedKey] 比对
  /// 派生 dirty；选中等视图态不参与（不构成「修改」）
  String _stateKey() {
    final sb = StringBuffer(
      "$_bw|$_bh|$_interval|$_phaseX|$_phaseY|$_majorColor",
    );
    for (final w in _works) {
      sb.write(
        "|${w.entry.file.path}"
        "@${w.ox},${w.oy},${w.rot},${w.flipH},${w.flipV}",
      );
    }
    return sb.toString();
  }

  /// 有未保存修改（Office 文档 dirty；无基线=刚进页/载入中，视为干净）
  bool get _dirty => _savedKey != null && _stateKey() != _savedKey;

  /// 置当前态为已保存基线（保存/另存/载入/新建重置后调用）
  void _markSaved() => _savedKey = _stateKey();

  _SetupSnap _captureSnap() => _SetupSnap(
        name: _boardName,
        file: _boardFile,
        bw: _bw,
        bh: _bh,
        interval: _interval,
        phaseX: _phaseX,
        phaseY: _phaseY,
        majorColor: _majorColor,
        key: _stateKey(),
        works: [
          for (final w in _works)
            _SnapWork(
              ref: w,
              ox: w.ox,
              oy: w.oy,
              rot: w.rot,
              flipH: w.flipH,
              flipV: w.flipV,
            ),
        ],
      );

  /// 变更前调用（快照 = 改动前状态）。与栈顶同键（前一次操作未产生实际
  /// 变化）不入栈，避免出现「按撤销没反应」的空步
  void _pushUndo() {
    final s = _captureSnap();
    if (_undoStack.isNotEmpty && _undoStack.last.key == s.key) {
      return;
    }
    _undoStack.add(s);
    if (_undoStack.length > 50) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    setState(() {}); // AppBar 撤销/重做按钮启停跟随
  }

  /// 拖动手势结束：起手快照与当前态不同（真拖动了作品/板）才入栈。
  /// 注意不能按 _pushUndo 的同键折叠——拖动前栈顶常恰好等于起手态
  ///（上一步刚改过），这里要的是「回到起手」这一步
  void _endDrag() {
    final s = _dragSnap;
    _dragSnap = null;
    if (s == null || s.key == _stateKey()) {
      return;
    }
    _undoStack.add(s);
    if (_undoStack.length > 50) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
    setState(() {});
  }

  void _undo() {
    if (_undoStack.isEmpty) {
      return;
    }
    setState(() {
      _redoStack.add(_captureSnap());
      _applySnap(_undoStack.removeLast());
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) {
      return;
    }
    setState(() {
      _undoStack.add(_captureSnap());
      _applySnap(_redoStack.removeLast());
    });
  }

  /// 应用快照（undo/redo 共用；不 setState，由调用方包裹）。作品实例
  /// 优先按同一性回填（保留 resolveForModel 换过的调色板）；copyWith
  /// 换过壳的按作品文件兜底匹配；实例已不在当前列表（被移除的作品）用
  /// 快照里的引用复活——它带着离板时已解析的调色板
  void _applySnap(_SetupSnap s) {
    final pool = List<PlacedWork>.of(_works);
    final restored = <PlacedWork>[];
    for (final e in s.works) {
      PlacedWork? cur;
      for (var i = 0; i < pool.length; i++) {
        if (identical(pool[i], e.ref)) {
          cur = pool.removeAt(i);
          break;
        }
      }
      if (cur == null) {
        for (var i = 0; i < pool.length; i++) {
          if (pool[i].entry.file == e.ref.entry.file) {
            cur = pool.removeAt(i);
            break;
          }
        }
      }
      final w = cur ?? e.ref;
      w.ox = e.ox;
      w.oy = e.oy;
      w.setTransform(rot: e.rot, flipH: e.flipH, flipV: e.flipV);
      restored.add(w);
    }
    _boardName = s.name;
    _boardFile = s.file;
    _bw = s.bw;
    _bh = s.bh;
    _interval = s.interval;
    _phaseX = s.phaseX;
    _phaseY = s.phaseY;
    _majorColor = s.majorColor;
    _works
      ..clear()
      ..addAll(restored);
    _selected = -1; // 快照不带选中态（视图不属于历史），回到无选中
  }

  /// 打开豆板列表（BottomSheet 点选载入）
  Future<void> _openBoardPicker() async {
    final boards = await DraftStore.listBoards();
    if (!mounted) {
      return;
    }
    if (boards.isEmpty) {
      AppSnackBar.show(context, "还没有已保存的豆板——摆好当前板后用「保存豆板」存下来");
      return;
    }

    ///< 有未保存修改先三键确认（保存/不保存/取消），干净板直接换
    if (!await _confirmUnsavedAction("打开豆板")) {
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
    if (!mounted) {
      return;
    }
    // 载入完成：载入态即基线（clean），撤销历史属新文档从头计
    setState(() {
      _markSaved();
      _undoStack.clear();
      _redoStack.clear();
    });
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
    setState(() {
      _boardName = n;
      _markSaved();
    });
    AppSnackBar.show(context, "已保存豆板「$n」");
  }

  /// 菜单「保存豆板」：显式主保存动词（Office 的 Ctrl+S 位）——已命名板
  /// 覆盖保存并提示；未命名板先问名字（2026-11-12 反馈：此前菜单只有
  /// 「另存为」一个保存入口，用户无从确认列表里的板是已保存文件）
  Future<void> _saveBoard() async {
    final name = _boardName;
    if (name == null) {
      await _ensureSaved(); // 问名 + 保存 + snackbar（内部已完成）
      return;
    }
    _boardFile = await DraftStore.saveBoardFile(_currentSession(name));
    if (!mounted) {
      return; // 保存已完成，页面销毁只跳过 UI 更新
    }
    setState(() => _markSaved());
    AppSnackBar.show(context, "已保存豆板「$name」");
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
      _markSaved();
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
    setState(() {
      _boardName = n;
      _markSaved();
    });
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

  /// back 退出确认：有未保存修改时问是否保存——显式三键（是=保存退出 /
  /// 否=不保存直接退出 / 取消=留在本页；点外部同取消）；干净板静默退出
  Future<void> _confirmExit() async {
    if (!_dirty) {
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

  /// 有未保存修改时的三键确认（2026-11-12 需求：新建豆板/打开其他豆板
  /// 与退出同理先问保存）。返回 true=放行（改动已保存或明确丢弃）；
  /// false=取消留在本页。干净板直接放行，不恐吓式弹窗
  Future<bool> _confirmUnsavedAction(String action) async {
    if (!_dirty) {
      return true;
    }
    final save = await _confirmDialog(
      "保存豆板？",
      "当前豆板有未保存的修改。「是」保存后$action；「否」不保存直接"
      "$action（丢弃修改）；「取消」留在本页",
      cancelLabel: "取消",
    );
    if (save == null || !mounted) {
      return false;
    }
    if (save) {
      final ok = await _ensureSaved();
      if (!ok || !mounted) {
        return false; // 未命名板放弃输名字：视同取消
      }
    }
    return true;
  }

  /// 新建豆板（有未保存修改先三键确认）；新文档新历史——撤销栈清空、
  /// 空板态即基线
  Future<void> _newBoard() async {
    if (!await _confirmUnsavedAction("新建豆板")) {
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
      _undoStack.clear();
      _redoStack.clear();
      _markSaved();
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
    // 删除即终结：文件已没了，历史不可回（弹窗已明示无法恢复）——
    // 回空板态重置基线并清栈
    setState(() {
      _boardName = null;
      _boardFile = null;
      _works.clear();
      _selected = -1;
      _undoStack.clear();
      _redoStack.clear();
      _markSaved();
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
    if (w == _bw && h == _bh) {
      return; // 尺寸没变：不产生历史也不标脏（自定义框原值确定）
    }
    _pushUndo();
    setState(() {
      _bw = w;
      _bh = h;
      for (final work in _works) {
        work.clampTo(w, h); // 换板保留相对布局，出界作品拉回可达范围
      }
    });
  }

  void _setInterval(int v) {
    if (v == _interval) {
      return;
    }
    _pushUndo();
    setState(() {
      _interval = v;
      _phaseX = _phaseX.clamp(0, v - 1);
      _phaseY = _phaseY.clamp(0, v - 1);
    });
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
    final v = picked == BoardConfig.defaultMajorColor ? null : picked;
    if (v == _majorColor) {
      return; // 选了原色：无改动
    }
    _pushUndo();
    setState(() => _majorColor = v);
  }

  // 顶点相位：phaseX 增 = 竖粗线左移，减 = 右移；phaseY 增 = 横粗线上移，减 = 下移
  void _shiftPhase({int dx = 0, int dy = 0}) {
    _pushUndo();
    setState(() {
      _phaseX = (_phaseX + dx + _interval) % _interval;
      _phaseY = (_phaseY + dy + _interval) % _interval;
    });
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
    // 预览图调色板逐件解析（GridPainter 需要渲染色卡；作品库页同款做法）
    final sel = await PaletteRegistry.loadSelected();
    final palettes = <WorkEntry, BeadPalette>{};
    for (final w in all) {
      palettes[w] = await PaletteRegistry.resolveForModel(w.model, sel.palette);
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
            for (final w in all)
              ListTile(
                // 作品预览图（2026-11-12 需求：不再用占位图标——库里
                // 同名/近似图案多，认图比认名快）；非方形按原始宽高比。
                // 缩略图口径同作品库卡片：去格线+浅黑外框+透明底
                leading: SizedBox(
                  width: 56,
                  height: 56,
                  // 占满方形盒：图案 contain 缩放居中（GridPainter 内做），
                  // 各作品外框大小一致（2026-11-12 需求），非方形不再变窄
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: GridPainter(
                      model: w.model,
                      palette: palettes[w]!,
                      selectedColorIndex: -1,
                      showGrid: false,
                      outline: true,
                    ),
                  ),
                ),
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
    _pushUndo();
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

  /// 右上角叉：移除选中作品（可撤销——撤销栈持有作品引用，一步回滚）
  void _removeSelected() {
    if (_selected < 0 || _selected >= _works.length) {
      return;
    }
    _pushUndo();
    setState(() {
      _works.removeAt(_selected);
      _selected = -1;
    });
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
      // cell 尺寸含板外余量（画布全幅 = 板 + 两侧 pad）
      final cell = canvasW / (_bw + 2 * _padX) / scale;
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

      ///< 偏移可达范围与 clampTo 同口径：宽/高最多移出板外二分之一
      ///（2026-11-12 用户需求：出界部分悬挂板外，非空白格出界由
      /// 开始拼豆门槛拦截）
      final nx =
          (w.ox + dx).clamp(-(m.width ~/ 2), _bw - (m.width + 1) ~/ 2).toInt();
      final ny = (w.oy + dy)
          .clamp(-(m.height ~/ 2), _bh - (m.height + 1) ~/ 2)
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
    // cell 尺寸含板外余量；板坐标 = 画布坐标减 pad（原点在板左上角）
    final cellW = canvasW / (_bw + 2 * _padX);
    final cellH = canvasH / (_bh + 2 * _padY);
    final hitR = 26 / _viewerCtrl.value.getMaxScaleOnAxis();
    for (var i = _works.length - 1; i >= 0; i--) {
      if (i != _selected) {
        continue; // 只有选中作品的叉可点（与 painter 只给选中作品画叉一致）
      }
      final w = _works[i];
      final m = w.model;
      final center = Offset(
        (w.ox + _padX + m.width) * cellW,
        (w.oy + _padY) * cellH,
      );
      if ((local - center).distance <= hitR) {
        _confirmRemoveAt(i);
        return;
      }
    }
    final bx = (local.dx / cellW).floor() - _padX;
    final by = (local.dy / cellH).floor() - _padY;
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
    _pushUndo();
    setState(() {
      _works.removeAt(index);
      if (_selected == index) {
        _selected = -1;
      } else if (_selected > index) {
        _selected--;
      }
    });
  }

  // ==================== 豆数统计 ====================

  /// 变换选中作品（旋转 ±90°/翻转），clamp 回可达范围（可撤销）
  void _transformSelected({int? rotDelta, bool? flipH, bool? flipV}) {
    if (_selected < 0 || _selected >= _works.length) {
      return;
    }
    final w = _works[_selected];
    _pushUndo();
    w.setTransform(
      rot: rotDelta == null ? null : (w.rot + rotDelta) % 4,
      flipH: flipH == null ? null : !w.flipH,
      flipV: flipV == null ? null : !w.flipV,
    );
    w.clampTo(_bw, _bh);
    setState(() {});
  }

  /// 豆数统计明细（BottomSheet：色块 + 色号/名 + 颗数，按颗数降序）
  Future<void> _showBeadStats() {
    return showBeadStatsSheet(context, works: _works);
  }

  // ==================== 开始拼豆 ====================

  /// 摆放是否就绪（开始拼豆的硬门槛）：没有非空白豆格出板且互不压豆
  ///（空白格出板/空豆位置交叠不算冲突——判定按豆级）。摆放期间出板/
  /// 压豆只是红标提示，进入实际拼豆前必须收拾干净
  bool _boardClean() =>
      !boardHasBeadOutside(_works, _bw, _bh) && !boardHasOverlap(_works);

  /// 开始拼豆：确认「保存并开始拼豆？」（是=保存后进入；否/点外部=留在本页）
  Future<void> _startAssemble() async {
    if (_works.isEmpty) {
      return;
    }
    if (boardHasBeadOutside(_works, _bw, _bh)) {
      AppSnackBar.show(context, "有豆子超出豆板（红标处），拖回板内或换大板后再开始");
      return;
    }
    if (boardHasOverlap(_works)) {
      AppSnackBar.show(context, "作品有压豆重叠（红标处），拖开后再开始拼豆");
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
    return PopScope(
      // back 先问保存（是/否/取消）；干净板与已确认退出直接放行
      canPop: _popAllowed || !_dirty,
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
            // 选中作品时先给变换工具组（Office 上下文工具语义，2026-11-12
            // 十六轮：新建/打开图标撤掉——表意不清，入口收进 ⋮ 菜单，
            // dirty 三键提示已保证不丢改动，少两个图标换来常驻撤销/重做）
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

            ///< 保存/撤销/重做常驻（不随选中让位）：拖完作品仍处于选中态，
            ///< 撤销得一步可达。撤销/重做栈空时置灰（onPressed null）
            IconButton(
              onPressed: _saveBoard,
              icon: const Icon(Icons.save_outlined),
              tooltip: "保存豆板",
            ),
            IconButton(
              onPressed: _undoStack.isEmpty ? null : _undo,
              icon: const Icon(Icons.undo),
              tooltip: "撤销",
            ),
            IconButton(
              onPressed: _redoStack.isEmpty ? null : _redo,
              icon: const Icon(Icons.redo),
              tooltip: "重做",
            ),
            PopupMenuButton<String>(
              tooltip: "豆板菜单",
              onSelected: (action) {
                switch (action) {
                  case "new":
                    _newBoard();
                  case "open":
                    _openBoardPicker();
                  case "save":
                    _saveBoard();
                  case "saveas":
                    _saveBoardAs();
                  case "delete":
                    _deleteBoard();
                }
              },

              ///< Office 文件菜单语序：保存/另存为在上，新建/打开居中，
              ///< 删除（仅已命名板）垫底（2026-11-12 按钮规范整理）
              itemBuilder: (_) => [
                const PopupMenuItem(value: "save", child: Text("保存豆板")),
                const PopupMenuItem(value: "saveas", child: Text("另存为豆板…")),
                const PopupMenuDivider(),
                const PopupMenuItem(value: "new", child: Text("新建豆板")),
                const PopupMenuItem(value: "open", child: Text("打开豆板…")),
                if (_boardFile != null) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: "delete",
                    child: Text("删除当前豆板"),
                  ),
                ],
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            _buildConfigRows(),
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

  Widget _buildConfigRows() {
    return BoardConfigPanel(
      bw: _bw,
      bh: _bh,
      interval: _interval,
      phaseX: _phaseX,
      phaseY: _phaseY,
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
                // 画布纵横比含板外余量（悬挂作品的出板部分要画得出来，
                // 见 _padX 注释）
                aspectRatio: (_bw + 2 * _padX) / (_bh + 2 * _padY),
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
                        _dragSnap = _captureSnap(); // 拖动起手快照（真有位移才入撤销栈）
                        _lastScale = 1.0;
                        _accDx = 0;
                        _accDy = 0;
                      },
                      onScaleUpdate: (d) => _onCanvasScale(d, canvasW, canvasH),
                      onScaleEnd: (_) => _endDrag(),
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
                          padX: _padX,
                          padY: _padY,
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

/// 撤销/重做的状态快照：板配置 + 板名/文件 + 各作品坐标副本。
/// [key] 为捕获时的状态键（与页面 _stateKey 同式）——拖动手势靠它判
/// 「起手到松手有没有真改动」，无需另记位移量
class _SetupSnap {
  final String? name;
  final File? file;
  final int bw, bh, interval, phaseX, phaseY;
  final int? majorColor;
  final String key;
  final List<_SnapWork> works;
  const _SetupSnap({
    required this.name,
    required this.file,
    required this.bw,
    required this.bh,
    required this.interval,
    required this.phaseX,
    required this.phaseY,
    required this.majorColor,
    required this.key,
    required this.works,
  });
}

/// 快照里的一件作品：持有 PlacedWork 引用 + 坐标/变换副本（PlacedWork
/// 的 ox/oy/rot/flip 是可变字段，快照必须抄数值；引用留着是为了撤销
/// 移除时能把作品原样复活——含它已解析的调色板与拼装进度）
class _SnapWork {
  final PlacedWork ref;
  final int ox, oy, rot;
  final bool flipH, flipV;
  const _SnapWork({
    required this.ref,
    required this.ox,
    required this.oy,
    required this.rot,
    required this.flipH,
    required this.flipV,
  });
}
