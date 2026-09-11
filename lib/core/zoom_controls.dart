import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderStack;

/// 可缩放画布的缩放控制组：放大 / 缩小 / 还原全幅，横排三钮（外置用）
///
/// 以当前画面（视口）中心为锚缩放——中心处内容不动，画面向外扩张/
/// 收缩；scale 夹在 [1, maxScale]，平移夹在内容可见边界（与双指捏合
/// 同款边界），缩到顶/底再点按不再变化。
///
/// 本组件不再自带 Positioned 悬浮（旧版浮在画布 Stack 右下角会挡住
/// 选区把手/图像内容），由调用方放进图区外的工具条/AppBar 横排嵌入；
/// 因此视口尺寸必须经 [viewportSize] 显式传入（aspect-fit 画布传画布
/// 盒尺寸=内容尺寸；constrained:false 铺满型图区传图区 LayoutBuilder
/// 约束），否则缩放锚点与平移夹限会算错
///
/// [contentSize] 画布内容原始尺寸（缩放边界计算用）；[onChanged] 缩放
/// 落定后回调——painter 依赖 viewScale 的页面借此 setState 刷新补偿量
class ZoomControls extends StatelessWidget {
  final TransformationController controller;

  ///< 缩放变换控制器
  final Size Function() contentSize;

  ///< 画布内容原始尺寸
  final double maxScale;

  ///< 缩放上限（下限恒 1 = 还原全幅）
  final VoidCallback? onChanged;

  ///< 缩放/复位落定后回调（viewScale 依赖方 setState 用）
  final Size Function()? viewportSize;

  ///< 视口尺寸提供者（null = 经 ancestor RenderStack 探取）。Center 内
  ///< constrained InteractiveViewer 自身尺寸=aspect-fit 画布盒，与内容同
  ///< 尺寸——此类页面传画布尺寸当视口，锚点/平移夹限才与 IV 手势一致
  final String fitAllTooltip;

  ///< 还原全幅钮提示文案（各页语义微差）
  static const _step = 1.25;

  ///< 单击缩放倍率（放大 ×1.25 / 缩小 ×0.8，四步一倍）

  const ZoomControls({
    super.key,
    required this.controller,
    required this.contentSize,
    this.maxScale = 10,
    this.onChanged,
    this.viewportSize,
    this.fitAllTooltip = "还原全幅（缩放/平移复位）",
  });

  /// 以 [anchor]（视口坐标）为锚缩放 [factor] 倍：锚点内容不动，
  /// scale/平移按夹限重算；返回是否实际变化（未变时调用方跳过刷新）
  static bool zoomAt({
    required TransformationController controller,
    required Size viewport,
    required Size content,
    required double factor,
    double maxScale = 10,
    Offset? anchor,
  }) {
    final cur = controller.value;
    final s0 = cur.getMaxScaleOnAxis();
    final s1 = (s0 * factor).clamp(1.0, maxScale).toDouble();
    if ((s1 - s0).abs() < 0.001) {
      return false;
    }
    final c = anchor ?? viewport.center(Offset.zero);
    final t0 = cur.getTranslation();
    // 屏幕点 p = t + s*x；锚点 c 的内容保持在 c：t1 = c - (c - t0) * s1/s0
    var dx = c.dx - (c.dx - t0.x) * (s1 / s0);
    var dy = c.dy - (c.dy - t0.y) * (s1 / s0);
    final minX = math.min(0.0, viewport.width - content.width * s1);
    final minY = math.min(0.0, viewport.height - content.height * s1);
    dx = dx.clamp(minX, 0.0).toDouble();
    dy = dy.clamp(minY, 0.0).toDouble();
    // 直设矩阵元（translate/scale 已废弃）：纯平移 + 等比缩放，无旋转
    final m = Matrix4.identity();
    m.setEntry(0, 0, s1);
    m.setEntry(1, 1, s1);
    m.setEntry(0, 3, dx);
    m.setEntry(1, 3, dy);
    controller.value = m;
    return true;
  }

  void _zoom(BuildContext ctx, double factor) {
    final vp = _viewportOf(ctx);
    final changed = zoomAt(
      controller: controller,
      viewport: vp,
      content: contentSize(),
      factor: factor,
      maxScale: maxScale,
    );
    if (changed) {
      onChanged?.call();
    }
  }

  void _fitAll() {
    controller.value = Matrix4.identity();
    onChanged?.call();
  }

  Size _viewportOf(BuildContext ctx) {
    final vp = viewportSize?.call();
    if (vp != null && vp.width > 0 && vp.height > 0) {
      return vp; // 显式视口优先（零尺寸=首帧前未速记，回退探取）
    }
    final ro = ctx.findAncestorRenderObjectOfType<RenderStack>();
    return ro?.size ?? MediaQuery.sizeOf(ctx);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _btn(
          icon: Icons.add,
          tooltip: "放大（以画面中心为准）",
          onTap: () => _zoom(context, _step),
        ),
        const SizedBox(width: 6),
        _btn(
          icon: Icons.remove,
          tooltip: "缩小（以画面中心为准）",
          onTap: () => _zoom(context, 1 / _step),
        ),
        const SizedBox(width: 6),
        _btn(
          icon: Icons.fit_screen,
          tooltip: fitAllTooltip,
          onTap: _fitAll,
        ),
      ],
    );
  }

  Widget _btn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      elevation: 2,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: onTap,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, size: 19, color: Colors.black54),
          ),
        ),
      ),
    );
  }
}
