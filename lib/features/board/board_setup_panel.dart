import 'package:flutter/material.dart';

import 'board_stats.dart';
import 'placed_work.dart';

/// 豆板配置页的配置面板与底部操作条（从页面抽出，回调注入）
///
/// 配置面板（2026-11-12 十六轮改版）：板尺寸 / 分割数两个下拉框（此前
/// SegmentedButton 两行大条，占竖向空间且「自定义」混在档位里表意含糊），
/// 顶点相位改带数值的紧凑步进器（相位是连续微调，下拉框不适用，但补上
/// 当前值显示）+ 粗线颜色圆钮 + 统计摘要行（点开豆数统计明细）

/// 带边框下拉框（combobox 形态）：label 前缀 + 展开箭头，选中项右对齐
class _Combo<T> extends StatelessWidget {
  final String label;

  ///< 框内前缀标签（恒显示，选中值跟随在后）
  final T value;

  ///< 当前值（必须在 [items] 里，否则显示空——调用方保证）
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  const _Combo({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          style: Theme.of(context).textTheme.bodyMedium,
          icon: const Icon(Icons.arrow_drop_down, size: 22),
          borderRadius: BorderRadius.circular(8),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 相位步进器：标签 + 左右（或上下）箭头 + 当前值——连续微调不适合
/// 下拉框，但比起旧版四个裸箭头补上了数值显示（改了什么、改到哪了）
class _PhaseStep extends StatelessWidget {
  final String label;

  ///< 「竖线」/「横线」
  final String minusTip;

  ///< 减方向 tooltip（竖线=右移 / 横线=下移）
  final String plusTip;

  ///< 加方向 tooltip（竖线=左移 / 横线=上移）
  final IconData minusIcon;
  final IconData plusIcon;
  final int value;

  ///< 当前相位值（0 ~ 分割数-1，随板持久化）
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _PhaseStep({
    required this.label,
    required this.minusTip,
    required this.plusTip,
    required this.minusIcon,
    required this.plusIcon,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, String tip, VoidCallback onTap) => IconButton(
          onPressed: onTap,
          icon: Icon(i, size: 18),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        btn(minusIcon, minusTip, onMinus),
        SizedBox(
          width: 18,
          child: Text(
            "$value",
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        btn(plusIcon, plusTip, onPlus),
      ],
    );
  }
}

class BoardConfigPanel extends StatelessWidget {
  static const presets = [52, 78, 104];

  ///< 板尺寸预设档位
  static const intervals = [5, 8, 10];

  ///< 加粗间隔档位
  final int bw, bh;

  ///< 当前板宽高（自定义板时下拉框显示「自定义 W×H」）
  final int interval;

  ///< 加粗框线间隔（每 N 格加粗）
  final int phaseX, phaseY;

  ///< 顶点相位（0 ~ 分割数-1，步进器显示当前值）
  final Widget majorColorDot;

  ///< 粗框线颜色圆钮（页面构建：含选色弹窗逻辑）
  final int worksCount;

  ///< 板上作品数（统计摘要行）
  final Map<String, int> stats;

  ///< 豆数统计（色号 -> 颗数，摘要行展示色数/总数）
  final void Function(int size) onSelectPreset;

  ///< 点预设档位（>0）
  final VoidCallback onCustom;

  ///< 点「自定义…」档
  final void Function(int v) onSetInterval;

  ///< 换加粗间隔
  final void Function({int dx, int dy}) onShiftPhase;

  ///< 顶点相位微调（dx 增=竖线左移 / dy 增=横线上移）
  final VoidCallback onShowStats;

  ///< 点统计摘要行（弹豆数统计明细）
  const BoardConfigPanel({
    super.key,
    required this.bw,
    required this.bh,
    required this.interval,
    required this.phaseX,
    required this.phaseY,
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
    // 预设档命中（正方形）；否则走「自定义」项（值显示当前实际尺寸）
    final presetHit = presets.any((s) => s == bw && s == bh);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _Combo<int>(
                  label: "板尺寸 ",
                  value: presetHit ? bw : 0,
                  items: [
                    for (final s in presets)
                      DropdownMenuItem(value: s, child: Text("$s×$s")),
                    DropdownMenuItem(
                      value: 0,
                      child: Text(
                        presetHit ? "自定义…" : "自定义 $bw×$bh",
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    if (v > 0) {
                      onSelectPreset(v);
                    } else {
                      onCustom();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Combo<int>(
                  label: "分割数 ",
                  value: interval,
                  // 旧板/外部数据可能出现非档位间隔：动态补一项保证当前值
                  // 可显示（选它无副作用，值本身没变）
                  items: [
                    for (final v in intervals)
                      DropdownMenuItem(value: v, child: Text("每$v格")),
                    if (!intervals.contains(interval))
                      DropdownMenuItem(
                        value: interval,
                        child: Text("每$interval格"),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null && v != interval) onSetInterval(v);
                  },
                ),
              ),
              const SizedBox(width: 8),
              majorColorDot,
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _PhaseStep(
                label: "竖线",
                minusTip: "竖线右移",
                plusTip: "竖线左移",
                minusIcon: Icons.chevron_left,
                plusIcon: Icons.chevron_right,
                value: phaseX,
                onMinus: () => onShiftPhase(dx: -1),
                onPlus: () => onShiftPhase(dx: 1),
              ),
              const SizedBox(width: 12),
              _PhaseStep(
                label: "横线",
                minusTip: "横线下移",
                plusTip: "横线上移",
                minusIcon: Icons.expand_more,
                plusIcon: Icons.expand_less,
                value: phaseY,
                onMinus: () => onShiftPhase(dy: -1),
                onPlus: () => onShiftPhase(dy: 1),
              ),
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

/// 底部操作条：导入作品 + 开始拼豆（豆子出板或相互重叠时禁用并提示）
class BoardBottomBar extends StatelessWidget {
  final List<PlacedWork> works;

  ///< 板上作品（空=「导入作品」文案 + 开始钮禁用）
  final int bw, bh;

  ///< 板宽高（豆级出界判定）
  final VoidCallback onAddWork;

  ///< 导入/添加作品
  final VoidCallback? onStart;

  ///< 开始拼豆（作品空、豆子出板或重叠时调用方传 null 禁用）
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
    final anyOutside = boardHasBeadOutside(works, bw, bh);
    final anyOverlap = !anyOutside && boardHasOverlap(works);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (works.isNotEmpty && anyOutside)
            Text(
              "有豆子超出豆板 $bw×$bh（可继续摆放；开始拼豆前需拖回板内或换大板）",
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            )
          else if (works.isNotEmpty && anyOverlap)
            const Text(
              "有作品相互重叠（红标处），拖开后才能开始拼豆",
              style: TextStyle(fontSize: 12, color: Colors.orange),
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
