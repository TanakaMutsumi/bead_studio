import 'package:flutter/material.dart';

import '../restore_types.dart';

/// 阶段②：九宫格标定每格大小（本步只做标定，框选主体在下一步独立
/// 进行）；四角对齐作歪图透视备选（四角即区域、无独立框选步，直接识别）
class AlignStep extends StatelessWidget {
  final ImageStageBuilder imageStage;
  final ZoomStripBuilder zoomStrip;
  final TransformationController viewerCtrl;
  final Size Function() displaySize;
  final Size Function() stageViewSize;
  final CustomPainter? overlay;

  ///< 对齐覆盖层（九宫格/四角网格，页面 _mainOverlay）
  final List<Offset>? cornerPts;

  ///< 四角点（四角模式非空）
  final void Function(int, Offset)? onCornerDrag;

  ///< 拖角回调
  final Offset? miniAnchor;

  ///< 九宫格锚点（九宫格模式非空）
  final void Function(Offset)? onMiniAnchor;

  ///< 九宫格锚点变更
  final bool useCorner;

  ///< true=四角对齐模式
  final String hint;

  ///< 引导文案（页面 _alignHint：含检测中/未就绪/已定格距三态）
  final double pitchX;

  ///< 当前格距（按钮启用与读数）
  final bool recognizing;
  final bool blankEnable;
  final TextEditingController colsCtrl;
  final TextEditingController rowsCtrl;
  final VoidCallback onDimChanged;

  ///< 行列输入变化（页面 setState 重画四角覆盖层）
  final void Function(bool corner) onSwitchMode;

  ///< 切换九宫格/四角模式
  final VoidCallback onResetCorners;

  ///< 四角重置回默认
  final void Function(bool v) onBlankChanged;
  final void Function(double step) onAdjustPitch;

  ///< 格子大小 ±（步进 ±0.2 图片像素）
  final void Function(double dx, double dy) onNudge;

  ///< 微移（±1 格距/8）
  final VoidCallback onRecognize;

  ///< 开始识别（四角模式入口）
  final VoidCallback onGoFrame;

  ///< 下一步：框选主体
  final bool detecting;

  ///< 九宫格自动检测进行中（重新识别按钮置灰）
  final VoidCallback onRedetect;

  ///< 重新识别：重跑全图格距自动检测、重放九宫格（手调废了重来）

  const AlignStep({
    super.key,
    required this.imageStage,
    required this.zoomStrip,
    required this.viewerCtrl,
    required this.displaySize,
    required this.stageViewSize,
    required this.overlay,
    required this.cornerPts,
    required this.onCornerDrag,
    required this.miniAnchor,
    required this.onMiniAnchor,
    required this.useCorner,
    required this.hint,
    required this.pitchX,
    required this.recognizing,
    required this.blankEnable,
    required this.colsCtrl,
    required this.rowsCtrl,
    required this.onDimChanged,
    required this.onSwitchMode,
    required this.onResetCorners,
    required this.onBlankChanged,
    required this.onAdjustPitch,
    required this.onNudge,
    required this.onRecognize,
    required this.onGoFrame,
    required this.detecting,
    required this.onRedetect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: imageStage(
              // 本步无选区交互：sel 恒 null，九宫格未命中的拖动走
              // panFallback=平移画面查看（放大核对格线重叠情况）
              sel: null,
              onSel: (_) {},
              overlay: overlay,
              cornerPts: cornerPts,
              onCornerDrag: onCornerDrag,
              miniAnchor: miniAnchor,
              onMiniAnchor: onMiniAnchor,
              panFallback: true,
            ),
          ),
        ),
        zoomStrip(
          viewerCtrl,
          displaySize,
          viewport: stageViewSize,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.grid_3x3, size: 18),
                    label: Text("九宫格标定"),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.crop_free, size: 18),
                    label: Text("四角对齐"),
                  ),
                ],
                selected: {useCorner},
                onSelectionChanged: (sel) => onSwitchMode(sel.first),
              ),
              const SizedBox(height: 6),
              Text(hint, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              if (useCorner) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: TextField(
                        controller: colsCtrl,
                        keyboardType: TextInputType.number,
                        // 四角覆盖层读 controller 文本定行列，改动即重画
                        onChanged: (_) => onDimChanged(),
                        decoration: const InputDecoration(
                          labelText: "列",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text("×"),
                    ),
                    SizedBox(
                      width: 64,
                      child: TextField(
                        controller: rowsCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => onDimChanged(),
                        decoration: const InputDecoration(
                          labelText: "行",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: onResetCorners,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text("重置四角"),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          "偏色过大识别为空白格",
                          style: TextStyle(fontSize: 13),
                        ),
                        value: blankEnable,
                        onChanged: onBlankChanged,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: recognizing ? null : onRecognize,
                        icon: recognizing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.document_scanner),
                        label: Text(recognizing ? "识别中…" : "开始识别"),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // 紧凑 IconButton（36 逻辑点击区 + 22 图标）+ 格子大小/微移
                // 拆两行：单行放 6 个按钮加标签在窄屏/大字体下仍会溢出
                // （用户实测微移控件被裁出屏错误显示）
                Row(
                  children: [
                    const Text("格子大小"),
                    _compactIconBtn(
                      onPressed: pitchX > 0 ? () => onAdjustPitch(-0.2) : null,
                      icon: Icons.remove_circle_outline,
                    ),
                    Text(pitchX > 0 ? pitchX.toStringAsFixed(2) : "--"),
                    _compactIconBtn(
                      onPressed: pitchX > 0 ? () => onAdjustPitch(0.2) : null,
                      icon: Icons.add_circle_outline,
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Text("微移"),
                    _compactIconBtn(
                      onPressed: pitchX > 0 ? () => onNudge(-1, 0) : null,
                      icon: Icons.arrow_left,
                      tooltip: "左移",
                    ),
                    _compactIconBtn(
                      onPressed: pitchX > 0 ? () => onNudge(0, -1) : null,
                      icon: Icons.arrow_upward,
                      tooltip: "上移",
                    ),
                    _compactIconBtn(
                      onPressed: pitchX > 0 ? () => onNudge(0, 1) : null,
                      icon: Icons.arrow_downward,
                      tooltip: "下移",
                    ),
                    _compactIconBtn(
                      onPressed: pitchX > 0 ? () => onNudge(1, 0) : null,
                      icon: Icons.arrow_right,
                      tooltip: "右移",
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 重新识别：手调格距/微移越调越歪时重跑自动检测重放九宫格
                //（与图例步的重新识别对位；进入本步时自动跑过一次，改动
                // 后想重选即点这里）
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: detecting ? null : onRedetect,
                        icon: detecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(detecting ? "检测中…" : "重新识别"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed:
                            pitchX > 0 && miniAnchor != null ? onGoFrame : null,
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text("下一步：框选主体"),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 紧凑图标按钮（对齐面板格子大小/微移行专用）：默认 IconButton 48
/// 逻辑宽，一行 6 个加标签在窄屏溢出，压到 36 宽/22 图标
Widget _compactIconBtn({
  required IconData icon,
  VoidCallback? onPressed,
  String? tooltip,
}) {
  return IconButton(
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    iconSize: 22,
    onPressed: onPressed,
    tooltip: tooltip,
    icon: Icon(icon),
  );
}
