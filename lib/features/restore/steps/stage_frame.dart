import 'package:flutter/material.dart';

import '../../../core/responsive.dart';

/// 图区步骤的骨架（①框图例 / ②九宫格对齐 / ③框选主体共用）：图区吃满、
/// 缩放条贴图区下缘、控制面板在底部。
///
/// 紧凑档（手机竖屏 / 平板竖屏，见 isExpandedWidth）：与原先各步手写的
/// Column[Expanded(Padding(12, 图区)), 缩放条, 面板] 布局逐像素一致。
///
/// 展开档（平板横屏 / 桌面）：图区又宽又矮，底部面板还要再压掉一截高度
/// ——改「图区居左 + 控制面板靠右」：横向空间换给图区，面板独占
/// kSidePanelWidth 一列、不再挤占图区高度（图的显示尺寸见页面 _displaySize）。
/// 面板内容都是手机宽度的排版，面板宽取 kSidePanelWidth 后原样可用。
class StageFrame extends StatelessWidget {
  final Widget stage;

  ///< 图区（页面 _imageStage 的产物，吃满可用区域）

  final Widget zoomStrip;

  ///< 缩放按钮条（贴图区下缘）

  final Widget panel;

  ///< 本步的控制面板（自带 padding）

  const StageFrame({
    super.key,
    required this.stage,
    required this.zoomStrip,
    required this.panel,
  });

  @override
  Widget build(BuildContext context) {
    final stageColumn = Column(
      children: [
        Expanded(
          child: Padding(padding: const EdgeInsets.all(12), child: stage),
        ),
        zoomStrip,
      ],
    );
    if (!isExpandedWidth(context)) {
      return Column(children: [Expanded(child: stageColumn), panel]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: stageColumn),
        const VerticalDivider(width: 1),
        SizedBox(width: kSidePanelWidth, child: panel),
      ],
    );
  }
}
