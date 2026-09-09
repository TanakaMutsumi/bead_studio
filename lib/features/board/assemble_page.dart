import 'package:flutter/material.dart';

import '../../core/board_config.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';
import 'board_painter.dart';

/// 拼豆界面：豆板画布（作品按偏移叠加）+ 点色高亮 + 点格标记已放 +
/// 进度/剩余颗数 + 返回自动保存进度
///
/// 后续拼豆辅助操作（本页为基座）在此基础上扩展
class AssemblePage extends StatefulWidget {
  final WorkEntry entry;
  final BoardConfig board;
  final BeadPalette palette;
  final Set<int> placed;

  const AssemblePage({
    super.key,
    required this.entry,
    required this.board,
    required this.palette,
    this.placed = const <int>{},
  });

  @override
  State<AssemblePage> createState() => _AssemblePageState();
}

class _AssemblePageState extends State<AssemblePage> {
  final _viewerCtrl = TransformationController();
  late final Set<int> _placed = {...widget.placed};
  int? _highlightIndex;

  PatternModel get _model => widget.entry.model;

  @override
  void dispose() {
    _viewerCtrl.dispose();
    super.dispose();
  }

  // ==================== 标记交互 ====================

  /// 画布点按：板坐标 -> 作品格，标记/取消已放（只响应当前高亮色，防串色误标）
  void _toggleAt(Offset local, double canvasW, double canvasH) {
    final b = widget.board;
    final hi = _highlightIndex;
    if (hi == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("先点下方颜色选择要拼的色，再点格子标记已放")),
      );
      return;
    }
    final bx = (local.dx / (canvasW / b.w)).floor();
    final by = (local.dy / (canvasH / b.h)).floor();
    final x = bx - b.ox;
    final y = by - b.oy;
    if (x < 0 || x >= _model.width || y < 0 || y >= _model.height) {
      return; // 点在板空区/作品外
    }
    final i = y * _model.width + x;
    if (_model.grid[i] != hi) {
      return; // 非高亮色格子不响应
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

  (int, int) _progress() {
    var total = 0;
    var done = 0;
    for (var i = 0; i < _model.grid.length; i++) {
      if (_model.grid[i] >= 0) {
        total++;
        if (_placed.contains(i)) {
          done++;
        }
      }
    }
    return (done, total);
  }

  // ==================== 保存 ====================

  Future<void> _saveProgress() async {
    // 拼装进度随作品覆写（板配置在进入前已由配置页写入，保留）
    await DraftStore.saveWork(
      _model,
      overwrite: widget.entry.file,
      placed: _placed,
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("拼豆进度已保存")));
    }
  }

  Future<void> _onWillPop() async {
    // 返回即自动保存（点保存按钮也存，幂等）
    await DraftStore.saveWork(
      _model,
      overwrite: widget.entry.file,
      placed: _placed,
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final counts = _model.countByColor();
    final (done, total) = _progress();
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _onWillPop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text("拼豆 · ${widget.entry.name}"),
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
                      "板 ${widget.board.w}×${widget.board.h} · 每${widget.board.interval}格加粗 · "
                      "已放 $done/$total",
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
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
            _buildColorBar(counts),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    return Center(
      child: InteractiveViewer(
        transformationController: _viewerCtrl,
        maxScale: 12,
        panEnabled: true,

        ///< 本页无画布手势，平移缩放都给查看器
        child: AspectRatio(
          aspectRatio: widget.board.w / widget.board.h,
          child: LayoutBuilder(
            builder: (context, constraints) {
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
                    board: widget.board,
                    model: _model,
                    palette: widget.palette,
                    highlightIndex: _highlightIndex,
                    placedCells: _placed,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 底部颜色条：作品用到的色 + 剩余颗数（点选高亮；放完绿框）
  Widget _buildColorBar(Map<int, int> counts) {
    final used = counts.keys.toList()..sort((a, b) => counts[b]! - counts[a]!);
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: used.length,
        itemBuilder: (context, idx) {
          final i = used[idx];
          final c = widget.palette.colors[i];
          final count = counts[i] ?? 0;
          final remain = _remainOf(i, counts);
          final selected = i == _highlightIndex;
          final borderColor = selected
              ? Colors.blue
              : (count > 0 && remain == 0)
              ? const Color(0xFF2E7D32)
              : Colors.black26;
          final light = (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) > 150;
          return GestureDetector(
            onTap: () => setState(() {
              _highlightIndex = _highlightIndex == i ? null : i;
            }),
            child: Container(
              width: 48,
              height: 60,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: Color.fromARGB(255, c.r, c.g, c.b),
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
                    c.id.replaceFirst("P", ""),
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
