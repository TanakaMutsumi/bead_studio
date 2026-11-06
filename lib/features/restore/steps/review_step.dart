import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show LongPressGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../../core/app_snack_bar.dart';
import '../../../core/palette.dart';
import '../../../core/pattern_model.dart';
import '../../editor/grid_painter.dart';
import '../cell_preview.dart';
import '../restore_painters.dart';
import '../restore_types.dart';

/// 阶段四：按色号分组复核 + 手工归类 + 图例数量对账
///
/// 筛选关闭（-2）显示总览豆图；选中色号切换为该色全部格子的截图墙
/// （截图取自原图同位置，肉眼核对印刷色号/颜色，错认的点击选中后
/// 重新归类）。截图墙支持范围连选：按住 0.5 秒锁定拖选（指下格未选
/// 中则连选=选中、已选中则连选=取消），随后拖动把「锁定格到当前格」
/// 的整片矩形范围一次套用——不必逐格划过；未满 0.5 秒移动仍归列表
/// 滚动；锁定后拖到视口上下边缘自动滚屏继续扩选
class ReviewStep extends StatefulWidget {
  final ZoomStripBuilder zoomStrip;

  ///< 画布缩放按钮条构建器（页面注入）
  final PatternModel model;
  final BeadPalette palette;
  final List<LegendEntry> legend;

  ///< 图例清单（数量对账 + 归类候选口径）
  final LegendSort legendSort;

  ///< 信息排序（沿用图例核对步选定：chips 组内排序同款）
  final List<Rect> cellRects;

  ///< 各格矩形（图片坐标，与 grid 扁平索引同序；截图取材用）
  final List<double> cellScores;

  ///< 各格识别置信度（与 grid 同序；截图墙低分优先，null 安全兜底 1.0）
  final ui.Image? cellSrc;

  ///< 截图数据源（限幅显示版解码；null=加载中）
  final img.Image image;

  ///< 原图（截图源坐标换算基准）
  final int reviewColor;

  ///< 当前复核色：-2 总览 / -1 空白 / >=0 调色板索引
  final int crossCount;

  ///< 截图墙每行列数（拖选命中换算与 GridView 共用同值）
  final void Function(int) onCrossCountChange;

  ///< 切换每行列数（状态留在页面，跨阶段往返保持）
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
  final void Function(Iterable<int> cells, bool select) onPickCells;

  ///< 批量置选中/取消（截图墙长按拖动选择用；绝对语义可重放）
  final VoidCallback onSelectAll;

  ///< 全选当前复核色
  final VoidCallback onInvertPick;

  ///< 反选当前复核色（已选取消、未选选中）
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
    required this.legendSort,
    required this.cellRects,
    required this.cellScores,
    required this.cellSrc,
    required this.image,
    required this.reviewColor,
    required this.crossCount,
    required this.onCrossCountChange,
    required this.picked,
    required this.reviewCtrl,
    required this.reviewCanvasSize,
    required this.onCanvasSize,
    required this.onChipTap,
    required this.onTogglePick,
    required this.onPickCells,
    required this.onSelectAll,
    required this.onInvertPick,
    required this.onClearPicked,
    required this.onReassign,
    required this.hasClassifyTarget,
    required this.onSave,
    required this.onOpenEditor,
  });

  @override
  State<ReviewStep> createState() => _ReviewStepState();
}

class _ReviewStepState extends State<ReviewStep> {
  static const _gap = 4.0;

  ///< 截图墙横/纵间距（拖选步距换算用；double：spacing 形参类型）
  static const _pad = 4.0;

  ///< 截图墙四边 padding（拖选命中换算用）

  final _galleryScroll = ScrollController();

  ///< 截图墙滚动控制器（拖选把 local 位置换算回内容格需读滚动偏移）

  // ==== 拖选（长按 0.5 秒锁定后范围连选）状态 ====
  RenderBox? _dragBox;

  ///< 截图墙视口 RenderBox（手势 localPosition 的坐标系）
  Offset _dragLast = Offset.zero;

  ///< 当前指位（视口局部坐标；自动滚屏边缘判定用）
  (int, int)? _dragAnchorCR;

  ///< 锚点格（列,行）——范围连选起点（锁定时刻指下格；空白尾区为 null，首移惰性取）
  Offset? _dblTapPos;

  ///< 总览双击落点（onDoubleTap 回调无坐标，从 onDoubleTapDown 速记）
  bool _dragSelect = true;

  ///< 拖选模式：锁定时锚点格未选中=true（连选=选中）/ 已选中=false（连选=取消）
  Timer? _dragAutoScroll;

  ///< 拖选自动滚屏定时器（锁定后指到视口上下边缘时按深度加速滚动）
  List<int> _dragCells = const [];

  ///< 截图墙当前格子列表速记（build 期间赋值，拖选索引换算用）

  @override
  void dispose() {
    _dragAutoScroll?.cancel();
    _galleryScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counts = widget.model.countByColor();
    final blankCount = widget.model.cellCount -
        counts.values.fold<int>(0, (a, b) => a + b);
    final order = _chipOrder(counts);
    return Column(
      children: [
        _buildChips(order, counts, blankCount),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: widget.reviewColor == -2
                ? _buildOverview()
                : _buildCellGallery(),
          ),
        ),
        // 总览缩放条（内容尺寸=速记值；截图墙无变换，复用同一控制器无碍）。
        // 截图墙模式在缩放条左端挂「每行列数」选择——chips 行是横滚列表，
        // 放列表里会被裁到末端不可发现；总览模式无截图墙不显示
        widget.reviewColor == -2
            ? widget.zoomStrip(widget.reviewCtrl, widget.reviewCanvasSize,
                maxScale: 12)
            : Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 0, 2),
                    child: _crossCountPicker(),
                  ),
                  Expanded(
                    child: widget.zoomStrip(widget.reviewCtrl,
                        widget.reviewCanvasSize,
                        maxScale: 12),
                  ),
                ],
              ),
        _buildActions(context, order, counts),
      ],
    );
  }

  /// 复核 chips 排序：超出的排最前，其次不足/不符，正确的垫后（不用翻页
  /// 找错），组内沿用图例核对步选定的排序（颗数取 图例颗数 ?? 实际颗数；
  /// 图例外的色位置序位次取大数垫底，色号序按调色板自然序）
  List<int> _chipOrder(Map<int, int> counts) {
    final pos = <int, int>{};
    final expected = <int, int?>{};
    for (var k = 0; k < widget.legend.length; k++) {
      pos[widget.legend[k].paletteIndex] = k;
      expected[widget.legend[k].paletteIndex] =
          widget.legend[k].expectedCount;
    }
    const tail = 1 << 20;
    int keyCount(int idx) => expected[idx] ?? counts[idx] ?? 0;
    // 档位：0=超出（实际比图例多，多出的豆要挑出来）1=不足/不符 2=正确
    int tier(int idx) {
      final e = expected[idx];
      if (e == null) {
        return 2;
      }
      final c = counts[idx] ?? 0;
      return c == e ? 2 : (c > e ? 0 : 1);
    }

    final keys = counts.keys.toList();
    keys.sort((a, b) {
      final t = tier(a) - tier(b);
      if (t != 0) {
        return t;
      }
      final d = switch (widget.legendSort) {
        LegendSort.position => (pos[a] ?? tail).compareTo(pos[b] ?? tail),
        LegendSort.countDesc => keyCount(b).compareTo(keyCount(a)),
        LegendSort.countAsc => keyCount(a).compareTo(keyCount(b)),
        LegendSort.code => a.compareTo(b),
      };
      return d != 0 ? d : a.compareTo(b);
    });
    return keys;
  }

  /// 双击格子：原图核对弹窗——标注该格在照片里的位置（高亮框），
  /// 放大细看确认"这颗豆到底是不是想要的颜色"（总览与截图墙同入口）
  void _openCellPreview(int cell) {
    final src = widget.cellSrc;
    if (src == null || cell < 0 || cell >= widget.model.grid.length) {
      return;
    }
    final cr = cell < widget.cellRects.length ? widget.cellRects[cell] : null;
    if (cr == null || cr.isEmpty) {
      return;
    }
    final v = widget.model.grid[cell];
    final c = v >= 0 && v < widget.palette.colors.length
        ? widget.palette.colors[v]
        : null;
    showCellPreview(
      context,
      image: src,
      cellRect: cr,
      scaleX: src.width / widget.image.width,
      scaleY: src.height / widget.image.height,
      swatch: c == null ? null : Color.fromARGB(255, c.r, c.g, c.b),
      label: "第${cell ~/ widget.model.width + 1}行 "
          "第${cell % widget.model.width + 1}列 · "
          "${c == null ? "空白" : "${c.id} ${c.name}"}",
    );
  }

  /// 总览：整幅豆图（长按拖动缩放、点选格子、双击原图核对）
  Widget _buildOverview() {
    return Stack(
      children: [
        Center(
          child: InteractiveViewer(
            maxScale: 12,
            transformationController: widget.reviewCtrl,
            child: AspectRatio(
              aspectRatio: widget.model.width / widget.model.height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cellW = constraints.maxWidth / widget.model.width;
                  final cellH = constraints.maxHeight / widget.model.height;
                  // 速记画布内容尺寸（无 setState，build 期间赋值）——
                  // ZoomControls 缩放边界计算用
                  widget.onCanvasSize(
                    Size(constraints.maxWidth, constraints.maxHeight),
                  );
                  return GestureDetector(
                    onTapUp: (d) {
                      if (widget.reviewColor == -2) {
                        return;
                      }
                      final cx = (d.localPosition.dx / cellW).floor();
                      final cy = (d.localPosition.dy / cellH).floor();
                      if (cx < 0 ||
                          cx >= widget.model.width ||
                          cy < 0 ||
                          cy >= widget.model.height) {
                        return;
                      }
                      widget.onTogglePick(cy * widget.model.width + cx);
                    },
                    // 双击：原图核对（总览态 -2 也可用，看任意格的原始照片）
                    onDoubleTapDown: (d) => _dblTapPos = d.localPosition,
                    onDoubleTap: () {
                      final p = _dblTapPos;
                      if (p == null) {
                        return;
                      }
                      final cx = (p.dx / cellW).floor();
                      final cy = (p.dy / cellH).floor();
                      if (cx < 0 ||
                          cx >= widget.model.width ||
                          cy < 0 ||
                          cy >= widget.model.height) {
                        return;
                      }
                      _openCellPreview(cy * widget.model.width + cx);
                    },
                    child: Stack(
                      children: [
                        CustomPaint(
                          size: Size.infinite,
                          painter: GridPainter(
                            model: widget.model,
                            palette: widget.palette,
                            selectedColorIndex: -1,
                            highlightIndex:
                                widget.reviewColor >= 0
                                ? widget.reviewColor
                                : null,
                          ),
                        ),
                        if (widget.reviewColor == -1)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: BlankMarksPainter(model: widget.model),
                            ),
                          ),
                        if (widget.picked.isNotEmpty)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: ReviewMarksPainter(
                                model: widget.model,
                                picked: widget.picked,
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
  /// 同序），点击选中/取消，配合「归类到…」或点目标色号 chip 重新分配。
  /// 排序按识别置信度升序（低分=可疑的先看，同分保持阅读序）；手工
  /// 归类过的格分数置 1 自然沉底。范围连选：按住 0.5 秒锁定拖选（指
  /// 下格即选/即取消并震动确认），随后拖动把「锁定格到当前格」的整片
  /// 矩形范围一次套用（划路径改为覆盖区域，大片连续错认不必逐格划过），
  /// 拖到视口上下边缘自动滚屏继续扩选；未满 0.5 秒就移动则让给列
  /// 表滚动（默认 500ms 长按在滚动列表里几乎
  /// 必被拖动抢走，实测起不了拖选）
  Widget _buildCellGallery() {
    final src = widget.cellSrc;
    final cells = [
      for (var i = 0; i < widget.model.grid.length; i++)
        if (widget.model.grid[i] == widget.reviewColor) i,
    ]..sort((a, b) {
        final sa = a < widget.cellScores.length ? widget.cellScores[a] : 1.0;
        final sb = b < widget.cellScores.length ? widget.cellScores[b] : 1.0;
        final d = sa.compareTo(sb);
        return d != 0 ? d : a.compareTo(b);
      });
    // 速记格子列表（拖选索引换算用，build 期间赋值）
    _dragCells = cells;
    if (src == null) {
      return Center(
        child: Text(
          "截图加载中…（共 ${cells.length} 格）",
          style: const TextStyle(fontSize: 13, color: Colors.black45),
        ),
      );
    }
    final scaleX = src.width / widget.image.width;
    final scaleY = src.height / widget.image.height;
    final srcBounds = Rect.fromLTWH(
      0,
      0,
      src.width.toDouble(),
      src.height.toDouble(),
    );
    return Builder(
      builder: (gctx) => RawGestureDetector(
        // opaque：列表尾部空白区按住 0.5 秒也能锁定（虽无格可作用，行为一致）
        behavior: HitTestBehavior.opaque,
        gestures: {
          _DelayedLongPressRecognizer:
              GestureRecognizerFactoryWithHandlers<
                _DelayedLongPressRecognizer
              >(
                () => _DelayedLongPressRecognizer(),
                (r) {
                  r.onLongPressStart = (d) => _dragStart(gctx, d);
                  r.onLongPressMoveUpdate = _dragMove;
                  r.onLongPressEnd = (d) => _dragEnd();
                  r.onLongPressCancel = _dragEnd;
                },
              ),
        },
        child: GridView.builder(
          controller: _galleryScroll,
          padding: const EdgeInsets.all(4),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: widget.crossCount,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
          ),
          itemCount: cells.length,
          itemBuilder: (cellCtx, k) {
            final i = cells[k];
            // 格矩形（原图坐标）-> 截图源坐标（cellSrc 是限幅显示版，按比例
            // 换算），intersect 源界防超界（四角模式角点拖出图界时矩形越界，
            // drawImageRect srcRect 越界直接抛异常）
            Rect? srcRect;
            if (i < widget.cellRects.length) {
              final cr = widget.cellRects[i];
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
            final isPicked = widget.picked.contains(i);
            // 选中格去色 + 压暗（蓝框照旧）：与未选格的彩色截图一眼
            // 可分——薄蓝框在花色截图墙上不够醒目，批量拖选时会漏选
            Widget? thumb;
            if (srcRect != null) {
              Widget t = CustomPaint(
                painter: CellThumbPainter(src: src, srcRect: srcRect),
                size: Size.infinite,
              );
              if (isPicked) {
                t = ColorFiltered(
                  colorFilter: ColorFilter.saturation(0),
                  child: t,
                );
              }
              thumb = t;
            }
            return GestureDetector(
              onTap: () => widget.onTogglePick(i),
              // 双击：放大看该格在原图里的位置与真实颜色
              onDoubleTap: () => _openCellPreview(i),
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
                    if (thumb != null) ClipRect(child: thumb),
                    if (isPicked)
                      Positioned.fill(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.35),
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
                          "${i % widget.model.width + 1},${i ~/ widget.model.width + 1}",
                          style: const TextStyle(
                            fontSize: 8,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ==== 拖选（长按 0.5 秒锁定后范围连选）====

  /// 锁定时刻：记视口 RenderBox、锚点格与模式（锚点格已选 -> 连选取消，
  /// 未选 -> 连选选中），先把锚点格选上/取消给出即时反馈（震动一下
  /// 确认已锁定，不用盯屏幕等计时），并启动自动滚屏定时器
  void _dragStart(BuildContext gctx, LongPressStartDetails d) {
    final box = gctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || _dragCells.isEmpty) {
      return;
    }
    _dragBox = box;
    _dragLast = d.localPosition;
    _dragAnchorCR = _tileCR(d.localPosition);
    _dragAutoScroll?.cancel();
    _dragAutoScroll = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _dragAutoScrollTick(),
    );
    final under = _cellAt(d.localPosition);
    if (under == null) {
      return;
    }
    _dragSelect = !widget.picked.contains(under);
    HapticFeedback.mediumImpact();
    widget.onPickCells([under], _dragSelect);
  }

  /// 拖动：把「锚点格 → 指下格」整片矩形范围套用拖选模式（含两端，
  /// 行列各取 min/max 成矩形）。绝对语义可重放——每次移动全范围重放，
  /// 同格重复套用无副作用，拖回缩小时多余的格按模式自然回收
  void _dragMove(LongPressMoveUpdateDetails d) {
    if (_dragBox == null || _dragCells.isEmpty) {
      return;
    }
    _dragLast = d.localPosition;
    _applyDragRange(d.localPosition);
  }

  void _dragEnd() {
    _dragAutoScroll?.cancel();
    _dragAutoScroll = null;
    _dragBox = null;
    _dragAnchorCR = null;
  }

  /// 拖选自动滚屏：指到视口上下边缘（或拖出界）按深度加速滚动；滚动
  /// 后内容在指下移动，锚点不动、当前端随滚动延伸——重放整个范围
  void _dragAutoScrollTick() {
    final box = _dragBox;
    if (box == null ||
        !_galleryScroll.hasClients ||
        _galleryScroll.positions.length != 1) {
      return;
    }
    final pos = _galleryScroll.position;
    const zone = 72.0;
    var delta = 0.0;
    if (_dragLast.dy < zone) {
      delta = -(zone - _dragLast.dy).clamp(0.0, zone * 2) / zone * 8;
    } else if (_dragLast.dy > box.size.height - zone) {
      delta =
          (_dragLast.dy - (box.size.height - zone)).clamp(0.0, zone * 2) /
          zone *
          8;
    }
    if (delta == 0) {
      return;
    }
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (target == pos.pixels) {
      return; // 已滚到头，指下无新格可扩
    }
    pos.jumpTo(target);
    _applyDragRange(_dragLast);
  }

  /// 范围套用：锚点格到指下格的矩形内全部格子按拖选模式置选/置不选。
  /// 锚点在空白尾区（锁定时指下无格）则惰性取当前格为锚并按它定模式
  void _applyDragRange(Offset local) {
    final cr = _tileCR(local);
    if (cr == null) {
      return;
    }
    final a = _dragAnchorCR;
    if (a == null) {
      _dragAnchorCR = cr;
      final t = cr.$2 * widget.crossCount + cr.$1;
      if (t < _dragCells.length) {
        _dragSelect = !widget.picked.contains(_dragCells[t]);
      }
    }
    final anchor = _dragAnchorCR!;
    final c0 = math.min(anchor.$1, cr.$1);
    final c1 = math.max(anchor.$1, cr.$1);
    final r0 = math.min(anchor.$2, cr.$2);
    final r1 = math.max(anchor.$2, cr.$2);
    final cells = <int>[];
    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        final t = r * widget.crossCount + c;
        if (t < _dragCells.length) {
          cells.add(_dragCells[t]);
        }
      }
    }
    if (cells.isNotEmpty) {
      widget.onPickCells(cells, _dragSelect);
    }
  }

  /// 视口局部坐标 -> 截图墙格位（列,行）（越出格子区返回 null）。
  /// 网格几何：N 列（用户可选）+ 间距 4 + padding 4、方格（childAspectRatio
  /// 默认 1）；纵坐标补上滚动偏移回到内容坐标（自动滚屏时偏移随时在变，现读）
  (int, int)? _tileCR(Offset local) {
    final box = _dragBox;
    if (box == null) {
      return null;
    }
    final pitch = _tilePitch();
    final scroll = _galleryScroll.hasClients &&
            _galleryScroll.positions.length == 1
        ? _galleryScroll.offset
        : 0.0;
    final col = ((local.dx - _pad) / pitch).floor();
    final row = ((local.dy - _pad + scroll) / pitch).floor();
    if (col < 0 || col >= widget.crossCount || row < 0) {
      return null;
    }
    return (col, row);
  }

  /// 视口局部坐标 -> 格子扁平索引（越界返回 null；_tileCR 的格位换算）
  int? _cellAt(Offset local) {
    final cr = _tileCR(local);
    if (cr == null) {
      return null;
    }
    final t = cr.$2 * widget.crossCount + cr.$1;
    return t < _dragCells.length ? _dragCells[t] : null;
  }

  /// 单格边长 + 间距（格距）：方格按视口宽均分推算
  double _tilePitch() {
    final box = _dragBox;
    final w = box == null ? 0.0 : box.size.width;
    final tile =
        (w - _pad * 2 - (widget.crossCount - 1) * _gap) / widget.crossCount;
    return tile + _gap;
  }

  /// 复核色号 chips（总豆数 + 空白 + 各色 + 图例数量对账）
  Widget _buildChips(List<int> order, Map<int, int> counts, int blankCount) {
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          // 总豆数（非空格豆）：置顶常驻，翻筛选也能看到
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black38),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(Icons.grain, size: 14, color: Colors.black54),
                  const SizedBox(width: 4),
                  Text(
                    "总豆数 $total",
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
            selected: widget.reviewColor == -1,
            onTap: () => widget.onChipTap(-1),
          ),
          for (final idx in order)
            () {
              final c = widget.palette.colors[idx];
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
                selected: widget.reviewColor == idx,
                ok: ok,
                onTap: () => widget.onChipTap(idx),
              );
            }(),
        ],
      ),
    );
  }

  /// 截图墙每行列数选择（缩放条左端，截图墙模式常显）：列数决定截图
  /// 大小——密集图案想一屏多看几格调大、要看清格内印刷色号调小。状态
  /// 留在页面 State，复核↔其他阶段往返不丢
  Widget _crossCountPicker() {
    const choices = [4, 5, 6, 8, 10, 12];
    // 自定义列数（3/7/9…）不在快捷项里，initialValue 必须是菜单内的值
    // （debug 断言直接抛），不在时传 null 仅失去初始高亮
    final preset = choices.contains(widget.crossCount) ? widget.crossCount : null;
    return PopupMenuButton<int>(
      tooltip: "截图墙每行列数",
      initialValue: preset,
      onSelected: (v) {
        if (v == -1) {
          _promptCustomCrossCount();
        } else {
          widget.onCrossCountChange(v);
        }
      },
      itemBuilder: (_) => [
        for (final n in choices)
          PopupMenuItem(
            value: n,
            child: Row(
              children: [
                Icon(
                  Icons.check,
                  size: 16,
                  color: n == widget.crossCount
                      ? Colors.blue
                      : Colors.transparent,
                ),
                const SizedBox(width: 4),
                Text("每行 $n 格"),
              ],
            ),
          ),
        const PopupMenuItem(
          value: -1,
          child: Row(
            children: [
              SizedBox(width: 20),
              Icon(Icons.edit, size: 16, color: Colors.black54),
              SizedBox(width: 4),
              Text("自定义…"),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const Icon(Icons.grid_view, size: 14, color: Colors.black54),
            const SizedBox(width: 4),
            Text(
              "每行${widget.crossCount}格",
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const Icon(Icons.arrow_drop_down, size: 16, color: Colors.black54),
          ],
        ),
      ),
    );
  }

  /// 自定义每行列数：快捷菜单盖不住的值（3/7/9/16…）弹数字输入，钳到
  /// 2-16（1 列截图墙没法看，>16 缩略图小于色号文本失去复核意义）
  Future<void> _promptCustomCrossCount() async {
    final input = await showDialog<int>(
      context: context,
      builder: (ctx) => const _CrossCountDialog(),
    );
    if (input == null) {
      return; // 取消/空输入/非数字
    }
    if (input < 2 || input > 16) {
      if (mounted) {
        AppSnackBar.show(context, "每行格数须在 2-16 之间");
      }
      return;
    }
    widget.onCrossCountChange(input);
  }

  /// 图例标注数量（无条目/未填返回 null = 不对账）
  int? _expectedOf(int paletteIndex) {
    for (final e in widget.legend) {
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
    for (final e in widget.legend) {
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
            "④ 点色号筛选看该色格子截图 → 点截图选中（按住 0.5 秒锁定后拖动，从起点到当前位置整片矩形选/取消，拖到上下边缘自动滚屏；直接拖动为滚动）→ 归类到图例色号或空白；再点同一色号回总览；双击任意豆可放大原图核对其位置与真实颜色",
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
                onPressed: widget.reviewColor == -2 ? null : widget.onSelectAll,
                child: const Text("全选当前色"),
              ),
              OutlinedButton(
                onPressed:
                    widget.reviewColor == -2 ? null : widget.onInvertPick,
                child: const Text("反选当前色"),
              ),
              OutlinedButton(
                onPressed: widget.picked.isEmpty ? null : widget.onClearPicked,
                child: Text("清除选中(${widget.picked.length})"),
              ),
              OutlinedButton.icon(
                onPressed:
                    widget.picked.isEmpty || !widget.hasClassifyTarget
                    ? null
                    : widget.onReassign,
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
                  onPressed: widget.onSave,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text("保存作品"),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: widget.onOpenEditor,
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

/// 0.5 秒长按识别器：拖选要求按住满 0.5 秒才锁定手势——期间手指一挪
/// 就让给列表滚动（滚动列表里直接拖会被竖向滚动手势抢走，拖选起不
/// 来）；满 0.5 秒则本识别器胜出竞技场，后续移动全部派发给拖选，
/// 滚屏改由拖到视口边缘的自动滚屏承担
class _DelayedLongPressRecognizer extends LongPressGestureRecognizer {
  _DelayedLongPressRecognizer()
    : super(duration: const Duration(milliseconds: 500));
}

/// 自定义每行列数对话框。控制器由对话框自身 State 持有并在 dispose 释放：
/// showDialog 的 Future 在 pop() 即刻完成，此刻退场动画仍在跑、TextField
/// 还挂在树上，外层立刻 dispose 会在下一帧动画 tick 触发
/// "TextEditingController was used after being disposed" 断言，连环炸成
/// 整页 ErrorWidget（2026-11-06 模拟器实测红屏）；State.dispose 则等到
/// 路由子树真正卸载（动画结束）才执行，天然安全
class _CrossCountDialog extends StatefulWidget {
  const _CrossCountDialog();

  @override
  State<_CrossCountDialog> createState() => _CrossCountDialogState();
}

class _CrossCountDialogState extends State<_CrossCountDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("每行格数"),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 2,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          hintText: "输入 2 - 16 的整数",
          counterText: "",
        ),
        onSubmitted: (t) => Navigator.pop(context, int.tryParse(t.trim())),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, int.tryParse(_ctrl.text.trim())),
          child: const Text("确定"),
        ),
      ],
    );
  }
}
