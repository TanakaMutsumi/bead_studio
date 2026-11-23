import 'package:flutter/material.dart';

/// 图区步骤的骨架（①框图例 / ②九宫格对齐 / ③框选主体共用）：
/// 图区吃满剩余高度、缩放条贴图区下缘、控制面板在底部——完全手机式的
/// 上下堆叠结构，各窗口尺寸一致（2026-11-24 用户定稿：不再做平板横屏的
/// 「图左面板右」分栏，控件行随屏宽拉伸）。图的显示尺寸见页面
/// _displaySize / restoreDisplaySize（宽屏下整幅装入视口并水平居中）。
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
    return Column(
      children: [
        Expanded(
          child: Padding(padding: const EdgeInsets.all(12), child: stage),
        ),
        zoomStrip,
        panel,
      ],
    );
  }
}
