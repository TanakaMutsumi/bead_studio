/// 单格原图核对弹窗（识别复核用）：整幅原图可缩放平移 + 该格位置
/// 高亮框标注，双击在 整图 / 放大到该格 间切换——确认"这颗豆在照片
/// 里到底是什么颜色"用
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// [image] 显示版解码图（复核步的 cellSrc）；[cellRect] 该格矩形
/// （原图坐标），[scaleX]/[scaleY] = 显示图 / 原图 尺寸比（矩形换算用）；
/// [swatch]/[label] 头部当前归类提示（null = 空白）
Future<void> showCellPreview(
  BuildContext context, {
  required ui.Image image,
  required Rect cellRect,
  required double scaleX,
  required double scaleY,
  Color? swatch,
  required String label,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CellPreviewDialog(
      image: image,
      cellRect: cellRect,
      scaleX: scaleX,
      scaleY: scaleY,
      swatch: swatch,
      label: label,
    ),
  );
}

class _CellPreviewDialog extends StatefulWidget {
  final ui.Image image;
  final Rect cellRect;
  final double scaleX;
  final double scaleY;
  final Color? swatch;
  final String label;

  const _CellPreviewDialog({
    required this.image,
    required this.cellRect,
    required this.scaleX,
    required this.scaleY,
    required this.swatch,
    required this.label,
  });

  @override
  State<_CellPreviewDialog> createState() => _CellPreviewDialogState();
}

class _CellPreviewDialogState extends State<_CellPreviewDialog> {
  final _ctrl = TransformationController();
  var _zoomed = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black87,
      insetPadding: EdgeInsets.zero,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: widget.swatch ?? Colors.white,
                    border: Border.all(color: Colors.white38),
                  ),
                  child: widget.swatch == null
                      ? const Icon(Icons.close, size: 14, color: Colors.black54)
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white70),
                  tooltip: "关闭",
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, c) {
                // 整图 fit 进视口（图大于视口的常规场景；小图居中）
                final s = math.min(
                  c.maxWidth / widget.image.width,
                  c.maxHeight / widget.image.height,
                );
                final w = widget.image.width * s;
                final h = widget.image.height * s;
                // 格矩形：原图坐标 -> 显示图像素 -> 内容坐标
                final rect = Rect.fromLTWH(
                  widget.cellRect.left * widget.scaleX * s,
                  widget.cellRect.top * widget.scaleY * s,
                  widget.cellRect.width * widget.scaleX * s,
                  widget.cellRect.height * widget.scaleY * s,
                );
                return GestureDetector(
                  // 双击：整图 <-> 放大到该格（格中心对准视口中心，占视口
                  // 短边约六成）；之后仍可双指缩放/拖动细看
                  onDoubleTap: () {
                    if (_zoomed) {
                      _ctrl.value = Matrix4.identity();
                      setState(() => _zoomed = false);
                      return;
                    }
                    final k = (c.smallest.shortestSide * 0.6 / rect.longestSide)
                        .clamp(2.0, 12.0)
                        .toDouble();
                    final cc = rect.center;
                    _ctrl.value = Matrix4.identity()
                      ..translate(c.maxWidth / 2, c.maxHeight / 2)
                      ..scale(k)
                      ..translate(-cc.dx, -cc.dy);
                    setState(() => _zoomed = true);
                  },
                  child: InteractiveViewer(
                    transformationController: _ctrl,
                    maxScale: 16,
                    child: Center(
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: RawImage(
                                image: widget.image,
                                fit: BoxFit.fill,
                              ),
                            ),
                            // 聚焦标注：格以外整体压暗 + 黄圈描边画在
                            // 格外侧——格内印刷色号不被笔触盖住，暗底
                            // 衬托下目标豆一眼跳出（旧实现纯描边框，
                            // 整图视角下小格被边框占满，格内啥也看不见）
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _CellFocusPainter(rect),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                "双指缩放/拖动查看 · 双击 定位该豆 / 回到整图",
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单格聚焦层：目标格以外的区域半透明压暗（拉黑衬托），目标格本身
/// 不做任何覆盖——印刷色号完整可见；黄圈 + 黑衬描边画在格外侧
///（rect 外扩半线宽起笔），笔触不压进格内
class _CellFocusPainter extends CustomPainter {
  final Rect rect;

  _CellFocusPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );
    // 黑衬边：rect.inflate(2) 笔宽 4 → 覆盖 [格边, 格边+4]（全在格外）
    final back = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    canvas.drawRect(rect.inflate(2), back);
    // 黄描边：rect.inflate(1) 笔宽 2 → 覆盖 [格边, 格边+2]，压在黑衬
    // 内侧一半上，任何底色旁都可见
    final ring = Paint()
      ..color = Colors.yellowAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect.inflate(1), ring);
  }

  @override
  bool shouldRepaint(covariant _CellFocusPainter oldDelegate) =>
      oldDelegate.rect != rect;
}
