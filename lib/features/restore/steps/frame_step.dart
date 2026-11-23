import 'package:flutter/material.dart';

import '../restore_types.dart';
import 'stage_frame.dart';

/// 阶段③：框选主体区域（九宫格已定格距，本步只做框选——拖画/挪框/
/// 把手调大小）。选区四边吸附格线（相位锚定九宫格锚点）：框的一切
/// 变化都是整格增减，框到哪格就是哪格；覆盖层只在选区内铺格线并在
/// 框上方实时显示行列数（不再全图画虚线格——标定只用来约束框选，
/// 图面保持干净）
class FrameStep extends StatelessWidget {
  final ImageStageBuilder imageStage;
  final ZoomStripBuilder zoomStrip;
  final TransformationController viewerCtrl;
  final Size Function() displaySize;
  final Size Function() stageViewSize;
  final Rect? sel;

  ///< 主体选区（显示坐标，已吸附格线）
  final CustomPainter? overlay;

  ///< 框选覆盖层（选区内格线 + 行列数徽标）
  final String hint;

  ///< 引导文案（页面 _frameHint：含实时预告切分行列数）
  final bool showAutoSelect;

  ///< 显示「自动框选主体」按钮（无有效选区时）
  final bool recognizing;
  final bool blankEnable;
  final void Function(Rect r) onSel;

  ///< 选区变更（页面内先吸附格线再落状态）
  final VoidCallback onAutoSelect;
  final void Function(bool v) onBlankChanged;
  final VoidCallback onRecognize;

  const FrameStep({
    super.key,
    required this.imageStage,
    required this.zoomStrip,
    required this.viewerCtrl,
    required this.displaySize,
    required this.stageViewSize,
    required this.sel,
    required this.overlay,
    required this.hint,
    required this.showAutoSelect,
    required this.recognizing,
    required this.blankEnable,
    required this.onSel,
    required this.onAutoSelect,
    required this.onBlankChanged,
    required this.onRecognize,
  });

  @override
  Widget build(BuildContext context) {
    return StageFrame(
      stage: imageStage(sel: sel, onSel: onSel, overlay: overlay),
      zoomStrip: zoomStrip(
        viewerCtrl,
        displaySize,
        viewport: stageViewSize,
        selection: () => sel,
      ),
      panel: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            // 显式自动框选入口（与①「自动框选图例区」同范式）：进本步已
            // 自动尝试过一次，检测失败/想重跑时点这里（有选区后隐藏——
            // 重选直接拖新框覆盖即可）
            if (showAutoSelect) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onAutoSelect,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text("自动框选主体"),
                ),
              ),
              const SizedBox(height: 8),
            ],
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.document_scanner),
                    label: Text(recognizing ? "识别中…" : "开始识别"),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
