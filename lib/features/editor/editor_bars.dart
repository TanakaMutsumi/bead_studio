import 'package:flutter/material.dart';

import '../../core/palette.dart';

/// 编辑器的工具行 / 选区条 / 分板条 / 颜色条 / 拼装进度条 / 颜色圆行
/// （从页面抽出，状态留在页面、回调注入）

/// 工具类型
enum EditorTool {
  view,

  ///< 查看：点/拖画布无任何副作用——作品库打开的图默认此工具，
  ///< 纯看图不误改；想画再显式切画笔
  brush,
  eraser,
  bucket,
  eyedropper,
  select,
}

/// 粗略判断浅色（决定色块上文字颜色）
bool isLightColor(BeadColor c) =>
    (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) > 150;

/// 工具行：六工具纯图标（36dp 紧凑钮，一屏放下不滚动）。
/// 2026-11-10 用户反馈二轮：此前六段「图标+文字」的 SegmentedButton
/// 一行放不下靠横向滚动遮丑（还要左右拖才能看到吸管/选区），完全
/// 不合格——纯图标后 360dp 窄屏也放得下；笔刷大小挪到独立的条件条
/// （仅画笔/橡皮态出现，见 [EditorBrushBar]），工具名走 tooltip。
class EditorToolRow extends StatelessWidget {
  final EditorTool tool;
  final void Function(EditorTool t) onSelectTool;

  const EditorToolRow({
    super.key,
    required this.tool,
    required this.onSelectTool,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget toolBtn(EditorTool t, IconData icon, String label) => IconButton(
          isSelected: tool == t,
          icon: Icon(icon, size: 22),
          tooltip: label,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
          padding: EdgeInsets.zero,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected)
                  ? cs.secondaryContainer
                  : null,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected)
                  ? cs.onSecondaryContainer
                  : null,
            ),
          ),
          onPressed: () => onSelectTool(t),
        );
    return Row(
      children: [
        toolBtn(EditorTool.view, Icons.visibility_outlined, "查看（不落笔）"),
        toolBtn(EditorTool.brush, Icons.brush, "画笔"),
        toolBtn(EditorTool.eraser, Icons.delete_outline, "橡皮"),
        toolBtn(EditorTool.bucket, Icons.format_color_fill, "油漆桶"),
        toolBtn(EditorTool.eyedropper, Icons.colorize, "吸管"),
        toolBtn(EditorTool.select, Icons.crop_free, "选区"),
      ],
    );
  }
}

/// 笔刷条：仅画笔/橡皮工具时出现（工具行放不下笔刷段选——360dp 窄屏
/// 六图标+段选+色圆必然溢出，附属参数独立成条件行，与选区条同模式）
class EditorBrushBar extends StatelessWidget {
  static const brushSizes = [1, 2, 3, 5];

  final int brushSize;
  final void Function(int size) onSelectBrushSize;

  const EditorBrushBar({
    super.key,
    required this.brushSize,
    required this.onSelectBrushSize,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Text("笔刷",
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
            segments: [
              for (final s in brushSizes)
                ButtonSegment(value: s, label: Text("$s")),
            ],
            selected: {brushSize},
            onSelectionChanged: (sel) => onSelectBrushSize(sel.first),
          ),
        ],
      ),
    );
  }
}

/// 选区操作条：尺寸展示 + 另存/填充/取消
class EditorSelectionBar extends StatelessWidget {
  final int selW, selH;
  final VoidCallback onSave;
  final VoidCallback onFill;
  final VoidCallback onCancel;

  const EditorSelectionBar({
    super.key,
    required this.selW,
    required this.selH,
    required this.onSave,
    required this.onFill,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    // Wrap 防溢出：大字号/窄屏下「选区 NxN + 三个按钮」一行放不下
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text("选区 $selW×$selH",
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 4),
          TextButton(onPressed: onSave, child: const Text("另存为图案")),
          TextButton(onPressed: onFill, child: const Text("填充当前色")),
          TextButton(onPressed: onCancel, child: const Text("取消")),
        ],
      ),
    );
  }
}

/// 编辑模式当前色圆（顶栏内联）：色圆 + 色号，点击弹色卡换色。
/// 2026-11-10 用户反馈二轮：从底部整行拉上来放进顶行尾部，紧凑内联
/// 不占行（未选色画灰圆）
class EditorColorChip extends StatelessWidget {
  final BeadPalette palette;
  final int? currentColor;
  final VoidCallback onTap;

  const EditorColorChip({
    super.key,
    required this.palette,
    required this.currentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final idx = currentColor;
    final c = idx != null && idx < palette.colors.length
        ? palette.colors[idx]
        : null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(19),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: c == null
                    ? null
                    : Color.fromARGB(255, c.r, c.g, c.b),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black26),
              ),
              child: c == null
                  ? const Icon(
                      Icons.palette_outlined,
                      size: 17,
                      color: Colors.black38,
                    )
                  : null,
            ),
            const SizedBox(width: 7),
            Text(
              c == null ? "选色" : c.id,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }
}

/// 分板控制条：板尺寸 + 板导航 + 本板颗数
class EditorBoardBar extends StatelessWidget {
  static const boardSizes = [26, 29, 52];

  ///< 常见拼豆板边长
  final int boardSize;
  final int boardIndex;

  ///< 当前板序号（行优先，0 起）
  final int boardCount;
  final int boardsAcross;

  ///< 每行板数（行/列号展示用）
  final int totalBeads;

  ///< 本板颗数
  final void Function(int size) onSelectSize;
  final void Function(int delta) onStep;

  const EditorBoardBar({
    super.key,
    required this.boardSize,
    required this.boardIndex,
    required this.boardCount,
    required this.boardsAcross,
    required this.totalBeads,
    required this.onSelectSize,
    required this.onStep,
  });

  @override
  Widget build(BuildContext context) {
    final row = boardIndex ~/ boardsAcross + 1;
    final col = boardIndex % boardsAcross + 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final s in boardSizes)
                ButtonSegment(value: s, label: Text("$s")),
            ],
            selected: {boardSize},
            onSelectionChanged: (sel) => onSelectSize(sel.first),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: boardIndex > 0 ? () => onStep(-1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            "${boardIndex + 1}/$boardCount",
            style: Theme.of(context).textTheme.labelMedium,
          ),
          IconButton(
            onPressed: boardIndex < boardCount - 1 ? () => onStep(1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              "第$row行·第$col列 · 本板 $totalBeads 颗",
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 拼装进度条：已放/总数 + 当前色剩余 + 进度指示
class EditorAssembleProgress extends StatelessWidget {
  final int done;
  final int total;
  final String remainText;

  const EditorAssembleProgress({
    super.key,
    required this.done,
    required this.total,
    required this.remainText,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "拼装 $done/$total · 点格子标记已放，再点取消 · $remainText",
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          LinearProgressIndicator(
            value: total > 0 ? done / total : 0,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
        ],
      ),
    );
  }
}

/// 底部颜色选择条（拼装模式下兼作高亮选择器，显示每色用量）
class EditorColorBar extends StatelessWidget {
  final BeadPalette palette;
  final Map<int, int> counts;

  ///< 用量（分板模式为本板用量）
  final bool assembleMode;
  final int? highlightIndex;
  final int? currentColor;

  ///< 当前绘画色（null = 未选色，色条全不高亮）
  final int Function(int colorIndex, Map<int, int> counts) remainOf;

  ///< 该色剩余颗数（拼装模式显示 remain/count）
  final void Function(int index) onTap;

  const EditorColorBar({
    super.key,
    required this.palette,
    required this.counts,
    required this.assembleMode,
    required this.highlightIndex,
    required this.currentColor,
    required this.remainOf,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: palette.colors.length,
        itemBuilder: (context, i) {
          final c = palette.colors[i];
          final count = counts[i] ?? 0;
          final remain = assembleMode ? remainOf(i, counts) : 0;
          final selected =
              assembleMode ? i == highlightIndex : i == currentColor;
          // 拼装模式：该色放完 = 绿框（一眼看出哪色收工）；选中蓝框优先
          final borderColor = selected
              ? Colors.blue
              : (assembleMode && count > 0 && remain == 0)
                  ? const Color(0xFF2E7D32)
                  : Colors.black26;
          return GestureDetector(
            onTap: () => onTap(i),
            child: Container(
              width: 48,
              height: 60,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: Color.fromARGB(255, c.r, c.g, c.b),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: borderColor,
                  width: selected ? 3 : 1,
                ),
              ),
              child: assembleMode
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          c.id.replaceFirst("P", ""),
                          style: TextStyle(
                            fontSize: 11,
                            color: isLightColor(c)
                                ? Colors.black54
                                : Colors.white70,
                          ),
                        ),
                        Text(
                          "$remain/$count",
                          style: TextStyle(
                            fontSize: 9,
                            color: isLightColor(c)
                                ? Colors.black45
                                : Colors.white60,
                          ),
                        ),
                      ],
                    )
                  : Center(
                      child: Text(
                        c.id.replaceFirst("P", ""),
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              isLightColor(c) ? Colors.black54 : Colors.white70,
                        ),
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }
}
