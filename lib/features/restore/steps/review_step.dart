import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../core/palette.dart';
import '../../../core/pattern_model.dart';
import '../../editor/grid_painter.dart';
import '../restore_painters.dart';
import '../restore_types.dart';

/// 阶段四：按色号分组复核 + 手工归类 + 图例数量对账
///
/// 筛选关闭（-2）显示总览豆图；选中色号切换为该色全部格子的截图墙
/// （截图取自原图同位置，肉眼核对印刷色号/颜色，错认的点击选中后
/// 重新归类）
class ReviewStep extends StatelessWidget {
  final ZoomStripBuilder zoomStrip;

  ///< 画布缩放按钮条构建器（页面注入）
  final PatternModel model;
  final BeadPalette palette;
  final List<LegendEntry> legend;

  ///< 图例清单（数量对账 + 归类候选口径）
  final List<Rect> cellRects;

  ///< 各格矩形（图片坐标，与 grid 扁平索引同序；截图取材用）
  final ui.Image? cellSrc;

  ///< 截图数据源（限幅显示版解码；null=加载中）
  final img.Image image;

  ///< 原图（截图源坐标换算基准）
  final int reviewColor;

  ///< 当前复核色：-2 总览 / -1 空白 / >=0 调色板索引
  final Set<int> picked;

  ///< 选中的格子（扁平索引）
  final TransformationController reviewCtrl;

  ///< 总览变换（还原全幅按钮复位用）
  final Size Function() reviewCanvasSize;

  ///< 总览画布内容尺寸速记（缩放条边界用）
  final void Function(Size s) onCanvasSize;

  ///< 总览画布尺寸速记回写（LayoutBuilder 内赋值）
  final void Function(int target) onChipTap;

  ///< 点 chip：页面判「归类选中格」或「切换筛选色」
  final void Function(int i) onTogglePick;

  ///< 格子选中/取消（总览点选与截图墙共用）
  final VoidCallback onSelectAll;

  ///< 全选当前复核色
  final VoidCallback onClearPicked;
  final VoidCallback onReassign;

  ///< 归类到…（弹受限选色器）
  final bool hasClassifyTarget;

  ///< 「归类到…」是否还有有效目标（禁用判定留在页面）
  final VoidCallback onSave;
  final VoidCallback onOpenEditor;

  const ReviewStep({
    super.key,
    required this.zoomStrip,
    required this.model,
    required this.palette,
    required this.legend,
    required this.cellRects,
    required this.cellSrc,
    required this.image,
    required this.reviewColor,
    required this.picked,
    required this.reviewCtrl,
    required this.reviewCanvasSize,
    required this.onCanvasSize,
    required this.onChipTap,
    required this.onTogglePick,
    required this.onSelectAll,
    required this.onClearPicked,
    required this.onReassign,
    required this.hasClassifyTarget,
    required this.onSave,
    required this.onOpenEditor,
  });

  @override
  Widget build(BuildContext context) {
    final counts = model.countByColor();
    final blankCount =
        model.cellCount - counts.values.fold<int>(0, (a, b) => a + b);
    final order = counts.keys.toList()..sort((a, b) => counts[b]! - counts[a]!);
    return Column(
      children: [
        _buildChips(order, counts, blankCount),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: reviewColor == -2 ? _buildOverview() : _buildCellGallery(),
          ),
        ),
        // 总览缩放条（内容尺寸=速记值；截图墙无变换，复用同一控制器无碍）
        zoomStrip(reviewCtrl, reviewCanvasSize, maxScale: 12),
        _buildActions(context, order, counts),
      ],
    );
  }

  /// 总览：整幅豆图（长按拖动缩放、点选格子）
  Widget _buildOverview() {
    return Stack(
      children: [
        Center(
          child: InteractiveViewer(
            maxScale: 12,
            transformationController: reviewCtrl,
            child: AspectRatio(
              aspectRatio: model.width / model.height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cellW = constraints.maxWidth / model.width;
                  final cellH = constraints.maxHeight / model.height;
                  // 速记画布内容尺寸（无 setState，build 期间赋值）——
                  // ZoomControls 缩放边界计算用
                  onCanvasSize(
                    Size(constraints.maxWidth, constraints.maxHeight),
                  );
                  return GestureDetector(
                    onTapUp: (d) {
                      if (reviewColor == -2) {
                        return;
                      }
                      final cx = (d.localPosition.dx / cellW).floor();
                      final cy = (d.localPosition.dy / cellH).floor();
                      if (cx < 0 ||
                          cx >= model.width ||
                          cy < 0 ||
                          cy >= model.height) {
                        return;
                      }
                      onTogglePick(cy * model.width + cx);
                    },
                    child: Stack(
                      children: [
                        CustomPaint(
                          size: Size.infinite,
                          painter: GridPainter(
                            model: model,
                            palette: palette,
                            selectedColorIndex: -1,
                            highlightIndex:
                                reviewColor >= 0 ? reviewColor : null,
                          ),
                        ),
                        if (reviewColor == -1)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: BlankMarksPainter(model: model),
                            ),
                          ),
                        if (picked.isNotEmpty)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: ReviewMarksPainter(
                                model: model,
                                picked: picked,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 截图墙：当前复核色全部格子的原图截图（cellRects 与 grid 扁平索引
  /// 同序），点击选中/取消，配合「归类到…」或点目标色号 chip 重新分配
  Widget _buildCellGallery() {
    final src = cellSrc;
    final cells = [
      for (var i = 0; i < model.grid.length; i++)
        if (model.grid[i] == reviewColor) i,
    ];
    if (src == null) {
      return Center(
        child: Text(
          "截图加载中…（共 ${cells.length} 格）",
          style: const TextStyle(fontSize: 13, color: Colors.black45),
        ),
      );
    }
    final scaleX = src.width / image.width;
    final scaleY = src.height / image.height;
    final srcBounds = Rect.fromLTWH(
      0,
      0,
      src.width.toDouble(),
      src.height.toDouble(),
    );
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: cells.length,
      itemBuilder: (_, k) {
        final i = cells[k];
        // 格矩形（原图坐标）-> 截图源坐标（cellSrc 是限幅显示版，按比例
        // 换算），intersect 源界防超界（四角模式角点拖出图界时矩形越界，
        // drawImageRect srcRect 越界直接抛异常）
        Rect? srcRect;
        if (i < cellRects.length) {
          final cr = cellRects[i];
          final r = Rect.fromLTWH(
            cr.left * scaleX,
            cr.top * scaleY,
            cr.width * scaleX,
            cr.height * scaleY,
          ).intersect(srcBounds);
          if (!r.isEmpty) {
            srcRect = r;
          }
        }
        final isPicked = picked.contains(i);
        return GestureDetector(
          onTap: () => onTogglePick(i),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: isPicked ? Colors.blue : Colors.black12,
                width: isPicked ? 2.5 : 1,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (srcRect != null)
                  ClipRect(
                    child: CustomPaint(
                      painter: CellThumbPainter(src: src, srcRect: srcRect),
                      size: Size.infinite,
                    ),
                  ),
                // 右下角行列号（1 起）：错认截图回报位置用
                Positioned(
                  right: 1,
                  bottom: 1,
                  child: Container(
                    color: Colors.black45,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      "${i % model.width + 1},${i ~/ model.width + 1}",
                      style: const TextStyle(fontSize: 8, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 复核色号 chips（空白 + 各色 + 图例数量对账）
  Widget _buildChips(List<int> order, Map<int, int> counts, int blankCount) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _chip(
            lead: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black38),
              ),
              child: const Icon(Icons.close, size: 14),
            ),
            label: "空白 $blankCount",
            selected: reviewColor == -1,
            onTap: () => onChipTap(-1),
          ),
          for (final idx in order)
            () {
              final c = palette.colors[idx];
              final expected = _expectedOf(idx);
              final actual = counts[idx] ?? 0;
              final ok = expected == null ? null : actual == expected;
              return _chip(
                lead: Container(
                  width: 20,
                  height: 20,
                  color: Color.fromARGB(255, c.r, c.g, c.b),
                ),
                label: expected == null
                    ? "${c.id} $actual"
                    : "${c.id} $actual/$expected",
                selected: reviewColor == idx,
                ok: ok,
                onTap: () => onChipTap(idx),
              );
            }(),
        ],
      ),
    );
  }

  /// 图例标注数量（无条目/未填返回 null = 不对账）
  int? _expectedOf(int paletteIndex) {
    for (final e in legend) {
      if (e.paletteIndex == paletteIndex) {
        return e.expectedCount;
      }
    }
    return null;
  }

  Widget _chip({
    required Widget lead,
    required String label,
    required bool selected,
    bool? ok,
    VoidCallback? onTap,
  }) {
    final border = ok == false
        ? Colors.orange
        : ok == true
            ? Colors.green
            : (selected ? Colors.blue : Colors.black26);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              lead,
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  /// 复核操作条：对账状态 + 选中操作 + 进编辑器
  Widget _buildActions(
    BuildContext context,
    List<int> order,
    Map<int, int> counts,
  ) {
    var mismatch = 0;
    var accounted = 0;
    for (final e in legend) {
      final expected = e.expectedCount;
      if (expected != null) {
        accounted++;
        if ((counts[e.paletteIndex] ?? 0) != expected) {
          mismatch++;
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "④ 点色号筛选看该色格子截图 → 点截图选中 → 归类到图例色号或空白；再点同一色号回总览",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          if (accounted > 0)
            Text(
              mismatch == 0 ? "✓ 数量一致" : "⚠ $mismatch 项数量有误（实际/图例）",
              style: TextStyle(
                fontSize: 12,
                color: mismatch == 0 ? Colors.green : Colors.orange,
              ),
            ),
          const SizedBox(height: 8),
          // Wrap 折行代替 Row 单行：三按钮总宽超屏（用户实测「归类到…」
          // 被裁出手机界面右侧），窄屏/大字体下自动折行不再溢出
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: reviewColor == -2 ? null : onSelectAll,
                child: const Text("全选当前色"),
              ),
              OutlinedButton(
                onPressed: picked.isEmpty ? null : onClearPicked,
                child: Text("清除选中(${picked.length})"),
              ),
              OutlinedButton.icon(
                onPressed:
                    picked.isEmpty || !hasClassifyTarget ? null : onReassign,
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text("归类到…"),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text("保存作品"),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onOpenEditor,
                icon: const Icon(Icons.edit),
                label: const Text("进编辑器"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
