import 'package:flutter/material.dart';

import '../../core/adaptive_text.dart';
import '../../core/app_snack_bar.dart';
import '../../core/board_config.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/zoom_controls.dart';
import '../restore/restore_types.dart';
import 'board_painter.dart';
import 'major_color_picker.dart';
import 'placed_work.dart';

/// 拼豆界面：豆板画布（多作品按各自偏移叠加）+ 点色高亮 + 点格标记已放 +
/// 进度/剩余颗数 + 返回自动保存进度
///
/// 高亮方案两档：按全部作品（同色号跨作品一起高亮/统计）/ 按单件作品
///（色条与高亮只算所选作品，点格也只标记它；选中色后范围外作品整体
/// 压灰为"未选中"观感）；双击色号 = 范围内该色一次性全部标记已放
///（再双击撤销）。placed 按作品分账，保存时写回各自作品文件
///
/// 色条排序（orderAssembleColors）：完成的色（范围内剩余 0）整段垫后
/// 摆，段内按所选模式排（图例核对步同款四模式，初始沿用作品
/// meta.sortMode，本会话内可切不回写）
///
/// 后续拼豆辅助操作（本页为基座）在此基础上扩展
class AssemblePage extends StatefulWidget {
  final List<PlacedWork> works;

  ///< 板上作品（含偏移与渲染调色板）
  final BoardConfig board;

  const AssemblePage({super.key, required this.works, required this.board});

  @override
  State<AssemblePage> createState() => _AssemblePageState();
}

class _AssemblePageState extends State<AssemblePage> {
  final _viewerCtrl = TransformationController();
  late final List<Set<int>> _placed = [
    for (final w in widget.works) {...w.placed},
  ];
  String? _highlightId;
  var _scopeAll = true;

  ///< 高亮方案：true = 按全部作品（同色号跨作品一起高亮）；false =
  ///< 按单件作品（只看/只标 [_scopeWork]）
  int? _scopeWork;

  ///< 单件作品方案的当前作品索引（多件作品时由分段选择激活）

  var _labelMode = LabelMode.id;

  ///< 格子文字层模式（选中色号后可切横向/竖向编号；默认只色号）
  var _labelColorMode = LabelColorMode.adaptive;

  ///< 格子文字颜色模式（自适应/全黑/全白，默认自适应：浅豆黑字深豆
  ///< 白字；个别豆色自适应判浅判深不合口味时强制黑白）
  var _showOtherIds = true;

  ///< 是否显示未选中色号的文本（高亮中关掉只留选中色编号降噪；
  ///< 无高亮时关掉 = 纯色块净板视图）
  int? _majorColor;

  ///< 粗框线颜色覆盖（本会话内即时生效；进页取板配置值，不回写板文件
  ///<——持久配色仍走板设置页，两页状态互不踩）
  Size _canvasSize = Size.zero;

  ///< 画布内容尺寸速记（LayoutBuilder builder 内赋值供缩放边界计算用）
  late LegendSort _colorSort = _initColorSort();

  ///< 色条排序模式（完成色垫后的段内排序）：初始沿用作品 meta.sortMode
  ///<（首个非空的作品），全空/未知名回落颗数降序 = 原行为。切换只在
  ///< 本会话生效不回写——拼豆色条是板级视图（多作品合并），写回会让
  ///< 各作品的信息排序偏好互相覆盖
  late final Map<String, int> _codeOrder = _buildCodeOrder();

  ///< 色号 -> 调色板自然序索引（A1→A2→…→B1…，色号序用；先到的作品
  ///< 优先——同注册表下各作品一致，跨注册表混摆属退化场景取首个）
  LegendSort _initColorSort() {
    for (final w in widget.works) {
      final m = legendSortFromName(w.entry.sortMode);
      if (m != null) {
        return m;
      }
    }
    return LegendSort.countDesc;
  }

  Map<String, int> _buildCodeOrder() {
    final m = <String, int>{};
    for (final w in widget.works) {
      final cs = w.palette.colors;
      for (var i = 0; i < cs.length; i++) {
        m.putIfAbsent(cs[i].id, () => i);
      }
    }
    return m;
  }

  @override
  void initState() {
    super.initState();
    _majorColor = widget.board.majorColor;
  }

  @override
  void dispose() {
    _viewerCtrl.dispose();
    super.dispose();
  }

  // ==================== 标记交互 ====================

  /// 板格 -> 命中作品索引（上层优先，与绘制顺序一致）
  int _hitWorkIndex(int bx, int by) {
    for (var i = widget.works.length - 1; i >= 0; i--) {
      final w = widget.works[i];
      final m = w.model;
      if (bx >= w.ox &&
          bx < w.ox + m.width &&
          by >= w.oy &&
          by < w.oy + m.height) {
        return i;
      }
    }
    return -1;
  }

  /// 画布点按：未选色时点某颗豆 = 选中该豆的颜色（单件方案顺手切到该豆
  /// 的作品）；已选色时点该色格子标记/取消已放
  void _toggleAt(Offset local, double canvasW, double canvasH) {
    final b = widget.board;
    final bx = (local.dx / (canvasW / b.w)).floor();
    final by = (local.dy / (canvasH / b.h)).floor();
    final idx = _hitWorkIndex(bx, by);
    if (idx < 0) {
      if (_highlightId == null) {
        AppSnackBar.show(context, "点图上的豆可选中它的颜色，或点下方颜色条选择");
      }
      return; // 点在板空区
    }
    final w = widget.works[idx];
    final m = w.model;
    final x = bx - w.ox, y = by - w.oy;
    if (x < 0 || x >= m.width || y < 0 || y >= m.height) {
      return;
    }
    final i = y * m.width + x;
    final v = m.grid[i];
    final id = v >= 0 && v < m.paletteIds.length ? m.paletteIds[v] : null;
    final hi = _highlightId;
    if (hi == null) {
      if (id == null) {
        return; // 空白格：无可选的色
      }
      setState(() {
        _highlightId = id;
        // 单件方案下点到别的作品的豆 = 用户在看那件，切过去再高亮
        if (!_scopeAll) {
          _scopeWork = idx;
        }
      });
      return;
    }
    if (!_scopeAll) {
      final scope = _scopeWork;
      if (scope != null && idx != scope) {
        AppSnackBar.show(
          context,
          "当前按「${widget.works[scope].entry.name}」标记，"
          "点的是别的作品——切换方案或改选作品",
        );
        return;
      }
    }
    if (id != hi) {
      return; // 非高亮色格子不响应
    }
    setState(() {
      _placed[idx].contains(i) ? _placed[idx].remove(i) : _placed[idx].add(i);
    });
  }

  /// 双击色号：范围内该色一次性全部标记已放；已全部标记时双击撤销
  ///（整批放错重来的出口）。范围随高亮方案：全部作品 = 每件都标，
  /// 单件作品 = 只标所选作品
  void _completeColor(String id) {
    final scope = _scope;
    // 先判方向：范围内还有该色未标格 -> 补齐；否则撤销全部标记
    var undo = true;
    scan:
    for (var i = 0; i < widget.works.length; i++) {
      if (scope != null && i != scope) {
        continue;
      }
      final m = widget.works[i].model;
      for (var c = 0; c < m.grid.length; c++) {
        final v = m.grid[c];
        final cid = v >= 0 && v < m.paletteIds.length ? m.paletteIds[v] : null;
        if (cid == id && !_placed[i].contains(c)) {
          undo = false;
          break scan;
        }
      }
    }
    var changed = 0;
    setState(() {
      for (var i = 0; i < widget.works.length; i++) {
        if (scope != null && i != scope) {
          continue;
        }
        final m = widget.works[i].model;
        for (var c = 0; c < m.grid.length; c++) {
          final v = m.grid[c];
          final cid = v >= 0 && v < m.paletteIds.length ? m.paletteIds[v] : null;
          if (cid != id) {
            continue;
          }
          final ok = undo ? _placed[i].remove(c) : _placed[i].add(c);
          if (ok) {
            changed++;
          }
        }
      }
    });
    AppSnackBar.show(
      context,
      undo ? "已撤销 $id 已放标记 $changed 颗" : "已标记 $id 完成 $changed 颗",
    );
  }

  // ==================== 统计 ====================

  /// 当前高亮范围：null = 按全部作品；否则 = 单件方案的该作品索引
  int? get _scope => _scopeAll ? null : _scopeWork;

  /// 豆数统计：色号 -> 颗数（[only] = 只算该作品；null = 全部作品合并）
  Map<String, int> _totalStats([int? only]) {
    final stats = <String, int>{};
    for (var i = 0; i < widget.works.length; i++) {
      if (only != null && i != only) {
        continue;
      }
      final m = widget.works[i].model;
      m.countByColor().forEach((v, n) {
        final id = v < m.paletteIds.length ? m.paletteIds[v] : "?$v";
        stats[id] = (stats[id] ?? 0) + n;
      });
    }
    return stats;
  }

  /// 该色号剩余颗数（范围内总数 - 范围内已放）
  int _remainOf(String id, Map<String, int> totals, [int? only]) {
    var placedCount = 0;
    for (var i = 0; i < widget.works.length; i++) {
      if (only != null && i != only) {
        continue;
      }
      final m = widget.works[i].model;
      for (final cell in _placed[i]) {
        if (cell < 0 || cell >= m.grid.length) {
          continue;
        }
        final v = m.grid[cell];
        final cid = v >= 0 && v < m.paletteIds.length ? m.paletteIds[v] : null;
        if (cid == id) {
          placedCount++;
        }
      }
    }
    return (totals[id] ?? 0) - placedCount;
  }

  (int, int) _progress() {
    var total = 0;
    var done = 0;
    for (var i = 0; i < widget.works.length; i++) {
      final m = widget.works[i].model;
      for (var c = 0; c < m.grid.length; c++) {
        if (m.grid[c] >= 0) {
          total++;
        }
      }
      done += _placed[i].length;
    }
    return (done, total);
  }

  /// 色号查显示颜色（任一含该色的作品调色板）
  BeadColor? _colorOf(String id) {
    for (final w in widget.works) {
      final c = w.palette.byId(id);
      if (c != null) {
        return c;
      }
    }
    return null;
  }

  /// 粗框线颜色色板（共用 major_color_picker）：只改本会话视图不落盘
  ///（持久化在板设置页；见 _majorColor 注释）
  Future<void> _pickMajorColor() async {
    final picked = await showMajorColorPicker(context, _majorColor);
    if (picked == null || !mounted) {
      return; // 点外部/取消不改动
    }
    setState(() {
      _majorColor = picked == BoardConfig.defaultMajorColor ? null : picked;
    });
  }

  // ==================== 保存 ====================

  Future<void> _saveAll() async {
    for (var i = 0; i < widget.works.length; i++) {
      // 拼装进度随各作品覆写（板配置在进入前已由配置页写入，保留）
      await DraftStore.saveWork(
        widget.works[i].entry.model,
        overwrite: widget.works[i].entry.file,
        // 保存前逆映射回原坐标（作品文件存原始坐标系，不感知变换）
        placed: widget.works[i].toOriginalCells(_placed[i]),
      );
    }
  }

  Future<void> _saveProgress() async {
    await _saveAll();
    if (mounted) {
      AppSnackBar.show(context, "拼豆进度已保存");
    }
  }

  Future<void> _onWillPop() async {
    // 返回即自动保存（点保存按钮也存，幂等）
    await _saveAll();
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    final totals = _totalStats(scope);
    final (done, total) = _progress();
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _onWillPop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          // 长作品名先缩字号再截断（AdaptiveTitleText，2026-11-10 用户
          // 反馈标题「…」截死）
          title: AdaptiveTitleText(
            widget.works.length == 1
                ? "拼豆 · ${widget.works.first.entry.name}"
                : "拼豆 · ${widget.works.length} 件作品",
          ),
          actions: [
            IconButton(
              onPressed: _saveProgress,
              icon: const Icon(Icons.save_outlined),
              tooltip: "保存进度",
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "板 ${widget.board.w}×${widget.board.h} · "
                      "每${widget.board.interval}格加粗 · 已放 $done/$total",
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 粗框线颜色（与板设置页同款色板；本会话内即时生效）
                  Tooltip(
                    message: "粗框线颜色",
                    child: InkWell(
                      onTap: _pickMajorColor,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Color(
                            _majorColor ?? BoardConfig.defaultMajorColor,
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black38),
                        ),
                      ),
                    ),
                  ),
                  // 未选中色号文本开关（常显——高亮降噪/无高亮净板视图）
                  IconButton(
                    onPressed: () =>
                        setState(() => _showOtherIds = !_showOtherIds),
                    icon: Icon(
                      _showOtherIds
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                    ),
                    tooltip: _showOtherIds ? "隐藏未选中色号文本" : "显示未选中色号文本",
                    visualDensity: VisualDensity.compact,
                  ),
                  // 文字层模式切换（常显：编号模式须先选色才有效果，但入口
                  // 不必藏着——用户可能先设模式再选色）
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _labelMode = switch (_labelMode) {
                        LabelMode.id => LabelMode.rowNumber,
                        LabelMode.rowNumber => LabelMode.colNumber,
                        LabelMode.colNumber => LabelMode.id,
                      };
                    }),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: Icon(
                      switch (_labelMode) {
                        LabelMode.rowNumber => Icons.swap_horiz,
                        LabelMode.colNumber => Icons.swap_vert,
                        LabelMode.id => Icons.text_fields,
                      },
                      size: 16,
                    ),
                    label: Text(
                      switch (_labelMode) {
                        LabelMode.rowNumber => "横向排列",
                        LabelMode.colNumber => "竖向排列",
                        LabelMode.id => "只显示色号",
                      },
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  // 色条排序（与图例核对步同款四模式单选菜单）：完成色
                  //（剩余 0）恒垫后由排序函数保证，这里只管段内次序
                  _sortPopup(),
                  // 字色模式（三档单选）：自适应=浅色豆黑字/深色豆白字
                  //（默认）；全黑/全白强制一色——个别豆色自适应选的字色
                  // 看不清时（如纯白豆配浅灰字）手动兜底
                  _labelColorPopup(),
                ],
              ),
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: total > 0 ? done / total : 0,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            Expanded(child: _buildCanvas()),
            // 缩放控制组（外置条，紧贴画布底缘——放 AppBar 顶部离图太远
            // 够不着）：放大/缩小（以画面中心为锚）+ 还原全幅。Center 内
            // constrained IV 的视口=画布盒（与内容同尺寸）显式传
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
              child: Align(
                alignment: Alignment.centerRight,
                child: ZoomControls(
                  controller: _viewerCtrl,
                  contentSize: () => _canvasSize,
                  viewportSize: () => _canvasSize,
                  maxScale: 12,
                ),
              ),
            ),
            _buildScopeRow(),
            _buildColorBar(totals, scope),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return Center(
      child: Padding(
        // 板四周留边距：满屏形态板外框贴屏幕边看不清（与配置页同款）
        padding: const EdgeInsets.all(8),
        child: InteractiveViewer(
          transformationController: _viewerCtrl,
          maxScale: 12,
          panEnabled: true,

          ///< 本页无画布手势，平移缩放都给查看器
          child: AspectRatio(
            aspectRatio: widget.board.w / widget.board.h,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 速记画布内容尺寸（无 setState，build 期间赋值）——
                // ZoomControls 缩放边界计算用（闭包跨出本 builder）
                _canvasSize = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _toggleAt(
                    d.localPosition,
                    constraints.maxWidth,
                    constraints.maxHeight,
                  ),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: BoardPainter(
                      // 空白格白底；选中色号后其他豆+空白区统一变灰
                      //（BoardPainter 按 highlightId 自动处理）；
                      // 粗线颜色随板配置 + 本页色钮会话内覆盖
                      board: widget.board.copyWith(majorColor: _majorColor),
                      labelMode: _labelMode,
                      labelColorMode: _labelColorMode,
                      showLabels: true,
                      showNonHiLabels: _showOtherIds,
                      // ctrl：格线/对勾线宽随缩放实时补偿（painter 挂
                      // repaint 监听，捏合/缩放条不 setState 也跟着重画）
                      ctrl: _viewerCtrl,
                      items: [
                        for (var i = 0; i < widget.works.length; i++)
                          BoardPaintItem(
                            model: widget.works[i].model,
                            palette: widget.works[i].palette,
                            ox: widget.works[i].ox,
                            oy: widget.works[i].oy,

                            ///< 按作品方案：只有范围内作品带高亮，范围外
                            ///< 作品整体压灰（同未选中观感——用户要看
                            ///< 清"当前在拼哪件"）；全部方案维持同色号
                            ///< 跨作品一起高亮。未选色时都不压灰
                            highlightId: (_scope == null || i == _scope)
                                ? _highlightId
                                : null,
                            dimAll: _scope != null &&
                                i != _scope &&
                                _highlightId != null,
                            placedCells: _placed[i],
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
    );
  }

  /// 高亮方案行（多件作品才有意义）：全部作品（同色号跨作品一起高亮/
  /// 统计）/ 单件作品（下拉选作品——色条、高亮、点格与双击完成只算它）
  Widget _buildScopeRow() {
    if (widget.works.length < 2) {
      return const SizedBox.shrink();
    }
    final sw = _scopeWork ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
      child: Row(
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: true, label: Text("全部作品")),
              ButtonSegment(value: false, label: Text("单件作品")),
            ],
            selected: {_scopeAll},
            onSelectionChanged: (s) => setState(() {
              _scopeAll = s.first;
              if (!_scopeAll) {
                _scopeWork = (_scopeWork ?? 0).clamp(
                  0,
                  widget.works.length - 1,
                );
              }
            }),
          ),
          if (!_scopeAll) ...[
            const SizedBox(width: 8),
            Expanded(
              child: PopupMenuButton<int>(
                tooltip: "选择作品",
                initialValue: sw,
                onSelected: (i) => setState(() => _scopeWork = i),
                itemBuilder: (_) => [
                  for (var i = 0; i < widget.works.length; i++)
                    PopupMenuItem(
                      value: i,
                      child: Text(widget.works[i].entry.name),
                    ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black26),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.filter_center_focus, size: 14),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.works[sw].entry.name,
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 字色模式下拉（顶行尾部，图标钮省宽度）：三模式单选，当前带勾。
  /// 自适应按豆色亮度选黑白字（画布文字层的默认行为），全黑/全白为
  /// 强制档（BoardPainter.labelColorMode）
  Widget _labelColorPopup() {
    return PopupMenuButton<LabelColorMode>(
      tooltip: "字色模式（自适应/全黑/全白）",
      initialValue: _labelColorMode,
      onSelected: (m) => setState(() => _labelColorMode = m),
      itemBuilder: (_) => [
        for (final m in LabelColorMode.values)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Icon(
                  Icons.check,
                  size: 16,
                  color: m == _labelColorMode ? Colors.blue : Colors.transparent,
                ),
                const SizedBox(width: 4),
                Text(switch (m) {
                  LabelColorMode.adaptive => "字色自适应",
                  LabelColorMode.black => "字色全黑",
                  LabelColorMode.white => "字色全白",
                }),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.contrast, size: 15, color: Colors.black54),
      ),
    );
  }

  /// 色条排序下拉（摘要行内，图例核对步 _sortPopup 同款样式）：四模式
  /// 单选，当前模式带勾。完成色垫后不归它管（恒生效），见
  /// orderAssembleColors
  Widget _sortPopup() {
    return PopupMenuButton<LegendSort>(
      tooltip: "色条排序",
      initialValue: _colorSort,
      onSelected: (s) => setState(() => _colorSort = s),
      itemBuilder: (_) => [
        for (final e in LegendSort.values)
          PopupMenuItem(
            value: e,
            child: Row(
              children: [
                Icon(
                  Icons.check,
                  size: 16,
                  color: e == _colorSort ? Colors.blue : Colors.transparent,
                ),
                const SizedBox(width: 4),
                Text(legendSortLabels[e]!),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.sort, size: 14, color: Colors.black54),
            const SizedBox(width: 2),
            Text(
              legendSortLabels[_colorSort]!,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const Icon(Icons.arrow_drop_down, size: 16, color: Colors.black54),
          ],
        ),
      ),
    );
  }

  /// 底部颜色条：范围内用到的色（按色号合并）+ 剩余颗数
  ///（单击选色高亮；双击整色标记已放；放完绿框并排到条尾）
  Widget _buildColorBar(Map<String, int> totals, int? scope) {
    // 剩余颗数一次算全：垫后判定与条目绿框/文案复用（范围随 scope）
    final remain = {
      for (final id in totals.keys) id: _remainOf(id, totals, scope),
    };
    final used = orderAssembleColors(
      totals.keys.toList(),
      totals,
      remain,
      _colorSort,
      (id) => _codeOrder[id] ?? 1 << 30,
    );
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: used.length,
        itemBuilder: (context, idx) {
          final id = used[idx];
          final c = _colorOf(id);
          final count = totals[id] ?? 0;
          final left = remain[id] ?? 0;
          final selected = id == _highlightId;
          final borderColor = selected
              ? Colors.blue
              : (count > 0 && left == 0)
                  ? const Color(0xFF2E7D32)
                  : Colors.black26;
          final light =
              c != null && (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) > 150;
          return GestureDetector(
            // 单击选色（注册了双击后单击会延迟一拍，属预期）
            onTap: () => setState(() {
              _highlightId = _highlightId == id ? null : id;
            }),

            ///< 双击 = 范围内该色全部标记已放（已全完则撤销）
            onDoubleTap: () => _completeColor(id),
            child: Container(
              width: 48,
              height: 60,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: c != null
                    ? Color.fromARGB(255, c.r, c.g, c.b)
                    : Colors.grey,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: borderColor,
                  width: selected ? 3 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 浅色豆黑字/深色豆白字，对比拉到 87/纯白：黑 54/45 在
                  // 纯白浅豆（H1/H2 类）上小字号下几乎看不见
                  Text(
                    id.replaceFirst("P", ""),
                    style: TextStyle(
                      fontSize: 11,
                      color: light ? Colors.black87 : Colors.white,
                    ),
                  ),
                  Text(
                    "$left/$count",
                    style: TextStyle(
                      fontSize: 9,
                      color: light ? Colors.black54 : Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 色条排序：完成的色（[remain] 为 0）整段垫后——拼豆进行中没拼完的
/// 色留在手边，翻到尾才是拼完的；段内按 [sort]（图例核对步同款四
/// 模式：[totals] 取颗数、[codeOf] 取色号自然序）。position 模式段内
/// 保持 [ids] 传入序（= totals 插入序 = 跨作品网格扫描首现序，与用料
/// 统计页同口径——图例物理位置序未随作品存档，无从还原）
List<String> orderAssembleColors(
  List<String> ids,
  Map<String, int> totals,
  Map<String, int> remain,
  LegendSort sort,
  int Function(String) codeOf,
) {
  final undone = <String>[];
  final done = <String>[];
  for (final id in ids) {
    ((remain[id] ?? 0) <= 0 ? done : undone).add(id);
  }
  int byCode(String a, String b) => codeOf(a).compareTo(codeOf(b));
  int Function(String, String) cmp;
  switch (sort) {
    case LegendSort.countDesc:
      cmp = (a, b) {
        final d = totals[b]!.compareTo(totals[a]!);
        return d != 0 ? d : byCode(a, b);
      };
    case LegendSort.countAsc:
      cmp = (a, b) {
        final d = totals[a]!.compareTo(totals[b]!);
        return d != 0 ? d : byCode(a, b);
      };
    case LegendSort.code:
      cmp = byCode;
    case LegendSort.position:
      cmp = (a, b) => 0;
  }
  // position 不调 sort（List.sort 非稳定，比较器返回 0 保不住传入序）
  if (sort != LegendSort.position) {
    undone.sort(cmp);
    done.sort(cmp);
  }
  return [...undone, ...done];
}
