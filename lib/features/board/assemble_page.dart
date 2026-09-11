import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/board_config.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/zoom_controls.dart';
import 'board_painter.dart';
import 'placed_work.dart';

/// 拼豆界面：豆板画布（多作品按各自偏移叠加）+ 点色高亮 + 点格标记已放 +
/// 进度/剩余颗数 + 返回自动保存进度
///
/// 选色与高亮按色号跨作品统一（同一色号在所有作品中一起高亮）；
/// placed 按作品分账，保存时写回各自作品文件
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
  var _labelMode = LabelMode.id;

  ///< 格子文字层模式（选中色号后可切横向/竖向编号；默认只色号）
  Size _canvasSize = Size.zero;

  ///< 画布内容尺寸速记（LayoutBuilder builder 内赋值供缩放边界计算用）

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

  /// 画布点按：先选色（高亮色号），再点该色格子标记/取消已放
  void _toggleAt(Offset local, double canvasW, double canvasH) {
    final hi = _highlightId;
    if (hi == null) {
      AppSnackBar.show(context, "先点下方颜色选择要拼的色，再点格子标记已放");
      return;
    }
    final b = widget.board;
    final bx = (local.dx / (canvasW / b.w)).floor();
    final by = (local.dy / (canvasH / b.h)).floor();
    final idx = _hitWorkIndex(bx, by);
    if (idx < 0) {
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
    if (id != hi) {
      return; // 非高亮色格子不响应
    }
    setState(() {
      _placed[idx].contains(i) ? _placed[idx].remove(i) : _placed[idx].add(i);
    });
  }

  // ==================== 统计 ====================

  /// 全部作品豆数加和：色号 -> 颗数
  Map<String, int> _totalStats() {
    final stats = <String, int>{};
    for (final w in widget.works) {
      final m = w.model;
      m.countByColor().forEach((v, n) {
        final id = v < m.paletteIds.length ? m.paletteIds[v] : "?$v";
        stats[id] = (stats[id] ?? 0) + n;
      });
    }
    return stats;
  }

  /// 该色号剩余颗数（总 - 全部作品中已放）
  int _remainOf(String id, Map<String, int> totals) {
    var placedCount = 0;
    for (var i = 0; i < widget.works.length; i++) {
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
    final totals = _totalStats();
    final (done, total) = _progress();
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _onWillPop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.works.length == 1
                ? "拼豆 · ${widget.works.first.entry.name}"
                : "拼豆 · ${widget.works.length} 件作品",
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            // 缩放控制组（外置 AppBar，不放画布上——浮在画布会挡格子）：
            // 放大/缩小（以画面中心为锚）+ 还原全幅（双指把板面拖丢后
            // 一键复位）。Center 内 constrained IV 的视口=画布盒（与内容
            // 同尺寸）显式传；本页 painter 无 viewScale 依赖，onChanged 免
            ZoomControls(
              controller: _viewerCtrl,
              contentSize: () => _canvasSize,
              viewportSize: () => _canvasSize,
              maxScale: 12,
            ),
            const SizedBox(width: 8),
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
                  if (_highlightId != null)
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
            _buildColorBar(totals),
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
                      // 粗线颜色随板配置（默认橙）
                      board: widget.board,
                      labelMode: _labelMode,
                      showLabels: true,
                      items: [
                        for (var i = 0; i < widget.works.length; i++)
                          BoardPaintItem(
                            model: widget.works[i].model,
                            palette: widget.works[i].palette,
                            ox: widget.works[i].ox,
                            oy: widget.works[i].oy,
                            highlightId: _highlightId,
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

  /// 底部颜色条：全部作品用到的色（按色号合并）+ 剩余颗数（点选高亮；放完绿框）
  Widget _buildColorBar(Map<String, int> totals) {
    final used = totals.keys.toList()
      ..sort((a, b) => totals[b]!.compareTo(totals[a]!));
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
          final remain = _remainOf(id, totals);
          final selected = id == _highlightId;
          final borderColor = selected
              ? Colors.blue
              : (count > 0 && remain == 0)
                  ? const Color(0xFF2E7D32)
                  : Colors.black26;
          final light =
              c != null && (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) > 150;
          return GestureDetector(
            onTap: () => setState(() {
              _highlightId = _highlightId == id ? null : id;
            }),
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
                  Text(
                    id.replaceFirst("P", ""),
                    style: TextStyle(
                      fontSize: 11,
                      color: light ? Colors.black54 : Colors.white70,
                    ),
                  ),
                  Text(
                    "$remain/$count",
                    style: TextStyle(
                      fontSize: 9,
                      color: light ? Colors.black45 : Colors.white60,
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
