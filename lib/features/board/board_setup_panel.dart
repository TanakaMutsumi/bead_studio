import 'package:flutter/material.dart';

import 'placed_work.dart';

/// 豆板配置页的配置面板与底部操作条（从页面抽出，回调注入）
///
/// 配置面板：板尺寸预设（52/78/104/自定义）+ 加粗框线间隔 + 顶点相位
/// 四向微调 + 统计摘要行（点开豆数统计明细）

/// 相位微调小图标钮（紧凑）
Widget _phaseBtn(IconData icon, String tip, VoidCallback onTap) => IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      tooltip: tip,
      visualDensity: VisualDensity.compact,
    );

class BoardConfigPanel extends StatelessWidget {
  static const presets = [52, 78, 104];

  ///< 板尺寸预设档位（0 = 自定义）
  final bool presetSelected;

  ///< 当前板宽命中预设档（false = 自定义）
  final int bw, bh;

  ///< 当前板宽高（提示行展示）
  final int interval;

  ///< 加粗框线间隔（每 N 格加粗）
  final Widget majorColorDot;

  ///< 粗框线颜色圆钮（页面构建：含选色弹窗逻辑）
  final int worksCount;

  ///< 板上作品数（统计摘要行）
  final Map<String, int> stats;

  ///< 豆数统计（色号 -> 颗数，摘要行展示色数/总数）
  final void Function(int size) onSelectPreset;

  ///< 点预设档位（>0）
  final VoidCallback onCustom;

  ///< 点「自定义」档
  final void Function(int v) onSetInterval;

  ///< 换加粗间隔
  final void Function({int dx, int dy}) onShiftPhase;

  ///< 顶点相位微调（dx 增=竖线左移 / dy 增=横线上移）
  final VoidCallback onShowStats;

  ///< 点统计摘要行（弹豆数统计明细）
  const BoardConfigPanel({
    super.key,
    required this.presetSelected,
    required this.bw,
    required this.bh,
    required this.interval,
    required this.majorColorDot,
    required this.worksCount,
    required this.stats,
    required this.onSelectPreset,
    required this.onCustom,
    required this.onSetInterval,
    required this.onShiftPhase,
    required this.onShowStats,
  });

  @override
  Widget build(BuildContext context) {
    final total = stats.values.fold(0, (a, b) => a + b);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    for (final s in presets)
                      ButtonSegment(value: s, label: Text("$s×$s")),
                    const ButtonSegment(value: 0, label: Text("自定义")),
                  ],
                  selected: presetSelected ? {bw} : const {0},
                  onSelectionChanged: (sel) {
                    if (sel.first > 0) {
                      onSelectPreset(sel.first);
                    } else {
                      onCustom();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text("加粗框线", style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 5, label: Text("每5")),
                    ButtonSegment(value: 8, label: Text("每8")),
                    ButtonSegment(value: 10, label: Text("每10")),
                  ],
                  selected: {interval},
                  onSelectionChanged: (sel) => onSetInterval(sel.first),
                ),
              ),
              const SizedBox(width: 8),
              majorColorDot,
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text("顶点", style: Theme.of(context).textTheme.labelMedium),
              _phaseBtn(Icons.arrow_back, "竖线左移", () => onShiftPhase(dx: 1)),
              _phaseBtn(
                  Icons.arrow_forward, "竖线右移", () => onShiftPhase(dx: -1)),
              _phaseBtn(Icons.arrow_upward, "横线上移", () => onShiftPhase(dy: 1)),
              _phaseBtn(
                  Icons.arrow_downward, "横线下移", () => onShiftPhase(dy: -1)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "板 $bw×$bh · 每$interval格加粗 · 点作品选中后拖动",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: onShowStats,
            child: Text(
              "$worksCount 件作品 · ${stats.length} 种色 · $total 颗豆 ›",
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部操作条：导入作品 + 开始拼豆（有作品超板时禁用并提示换大板）
class BoardBottomBar extends StatelessWidget {
  final List<PlacedWork> works;

  ///< 板上作品（空=「导入作品」文案 + 开始钮禁用）
  final int bw, bh;

  ///< 板宽高（fits 判定）
  final VoidCallback onAddWork;

  ///< 导入/添加作品
  final VoidCallback? onStart;

  ///< 开始拼豆（作品空或超板时调用方传 null 禁用）
  const BoardBottomBar({
    super.key,
    required this.works,
    required this.bw,
    required this.bh,
    required this.onAddWork,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final anyOverflow = works.any((w) => !w.fits(bw, bh));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (works.isNotEmpty && anyOverflow)
            Text(
              "有作品超出豆板 $bw×$bh，请换大板或自定义尺寸",
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: onAddWork,
                icon: const Icon(Icons.library_add_outlined, size: 18),
                label: Text(works.isEmpty ? "导入作品" : "添加作品"),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text("开始拼豆"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
