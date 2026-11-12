import 'package:flutter/material.dart';

import 'board_stats.dart';
import 'placed_work.dart';

/// 豆板配置页的配置面板与底部操作条（从页面抽出，回调注入）
///
/// 配置面板（2026-11-12 十六轮改版）：板尺寸 / 分割数两个下拉框（此前
/// SegmentedButton 两行大条，占竖向空间且「自定义」混在档位里表意含糊），
/// 顶点相位改带数值的紧凑步进器（相位是连续微调，下拉框不适用，但补上
/// 当前值显示）+ 粗线颜色圆钮 + 统计摘要行（点开豆数统计明细）。
/// 十七轮：框内恒显 label 前缀说明用途；分割数含「无」档（interval=0
/// 不画加粗线，相位步进器随之禁用）。
/// 十八轮：下拉改 PopupMenuButton 锚定框正下方贴边弹出（DropdownButton
/// 的菜单按选中项对齐定位会飘到面板上方远处 + 独立圆角卡观感太分离，
/// 用户反馈不像下拉）；粗线颜色新增「不显示」档（全透明，分块保留）。

/// 带边框下拉框（combobox 形态）：框内恒显「label 前缀 + 当前值」，
/// 说清这个框管什么（2026-11-12 用户反馈：光一个 104×104 看不出是
/// 板尺寸还是分割数）。菜单贴框正下方弹出、宽同框、勾选当前项
///（十八轮：DropdownButton 原生菜单定位/观感与框太分离，不像下拉）
class _Combo<T> extends StatelessWidget {
  final String label;

  ///< 框内前缀标签（恒显示，选中值跟随在后）
  final String display;

  ///< 框内显示的当前值文本（与 [value] 对应项的菜单文本一致）
  final T value;

  ///< 当前值（菜单里对应项打勾）
  final List<(T, String)> items;

  ///< 菜单项：(值, 菜单文本)
  final ValueChanged<T> onSelected;
  const _Combo({
    super.key,
    required this.label,
    required this.display,
    required this.value,
    required this.items,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, cons) => PopupMenuButton<T>(
        // 菜单宽与框一致（默认按最宽菜单项步进缩放，窄于框时视觉断开）
        constraints: BoxConstraints(minWidth: cons.maxWidth, maxWidth: cons.maxWidth),
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: cs.outlineVariant),
        ),
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final (v, t) in items)
            PopupMenuItem(
              value: v,
              height: 48,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: v == value
                        ? Icon(Icons.check, size: 18, color: cs.primary)
                        : null,
                  ),
                  const SizedBox(width: 2),
                  Text(t, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
        ],
        child: Container(
          height: 40,
          padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: Colors.black54),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 22),
            ],
          ),
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
  final bool enabled;

  ///< 无分割线（interval=0）时相位无意义：按钮禁用
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _PhaseStep({
    required this.label,
    required this.minusTip,
    required this.plusTip,
    required this.minusIcon,
    required this.plusIcon,
    required this.value,
    this.enabled = true,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, String tip, VoidCallback onTap) => IconButton(
          onPressed: enabled ? onTap : null,
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
  final bool majorHidden;

  ///< 粗线颜色=「不显示」（十八轮）：info 行换口径提示分块仍在
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
    required this.majorHidden,
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
                  display: presetHit ? "$bw×$bh" : "自定义 $bw×$bh",
                  value: presetHit ? bw : 0,
                  items: [
                    for (final s in presets) (s, "$s×$s"),
                    (0, presetHit ? "自定义…" : "自定义 $bw×$bh"),
                  ],
                  onSelected: (v) {
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
                  display: interval <= 0 ? "无" : "每$interval格",
                  value: interval <= 0 ? 0 : interval,
                  // 「无」= 0（不加粗分割线，2026-11-12 需求：分割线要有
                  // 无的选项）；旧板/外部数据可能出现非档位间隔：动态补项
                  // 保证当前值可显示（选它无副作用，值本身没变）
                  items: [
                    (0, "无"),
                    for (final v in intervals) (v, "每$v格"),
                    if (interval > 0 && !intervals.contains(interval))
                      (interval, "每$interval格"),
                  ],
                  onSelected: (v) {
                    if (v != interval) onSetInterval(v);
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
                enabled: interval > 0,
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
                enabled: interval > 0,
                onMinus: () => onShiftPhase(dy: -1),
                onPlus: () => onShiftPhase(dy: 1),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "板 $bw×$bh · ${interval > 0 ? (majorHidden ? "每$interval格分块·线不显示" : "每$interval格加粗") : "无分割线"}"
            " · 点作品选中后拖动",
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
