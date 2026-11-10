import 'package:flutter/material.dart';

import '../../core/palette.dart';

/// 编辑器的工具行 / 笔刷条 / 选区条 / 颜色圆（从页面抽出，状态留在
/// 页面、回调注入）。分板条 / 拼装进度条 / 底部色条已随编辑器「拼装
/// 模式 / 分板拼装」移除（2026-11-10 用户定稿：那是「开始拼豆」链路
/// 的功能，assemble_page 有完整实现，编辑器专注改图案）

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

/// 橡皮擦图标：Material 图标库没有 eraser（ink_eraser 仅存在于更新的
/// Material Symbols），自绘一枚——斜放双色橡皮（粉头+白身+描边）。
/// 2026-11-10 用户反馈：delete_outline 垃圾桶被当成删除工具，橡皮就该
/// 长得像橡皮
class EraserIcon extends StatelessWidget {
  const EraserIcon({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.onSurfaceVariant;
    final w = size * 0.58;
    final h = size * 0.84;
    return Transform.rotate(
      angle: -0.72, // 约 -41°，斜放的橡皮姿态
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.1),
          border: Border.all(color: outline, width: 1.4),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Container(height: h * 0.4, color: const Color(0xFFEC8CA0)),
            const Expanded(child: ColoredBox(color: Color(0xFFFAFAFA))),
          ],
        ),
      ),
    );
  }
}

/// 工具行：六工具纯图标（36dp 紧凑钮，一屏放下不滚动）。
/// 2026-11-10 用户反馈二轮：此前六段「图标+文字」的 SegmentedButton
/// 一行放不下靠横向滚动遮丑（还要左右拖才能看到吸管/选区），完全
/// 不合格——纯图标后 360dp 窄屏也放得下；笔刷大小挪到独立的条件条
/// （仅画笔/橡皮态出现，见 [EditorBrushBar]），工具名走 tooltip。
/// 三轮：查看图标改四向拖动（open_with，语义=只拖动看图不落笔）、
/// 橡皮改 [EraserIcon]（垃圾桶易误读为删除）。
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
    Widget toolBtn(EditorTool t, Widget icon, String label) => IconButton(
          isSelected: tool == t,
          icon: icon,
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
        toolBtn(
            EditorTool.view, const Icon(Icons.open_with, size: 22), "查看（拖动看图，不落笔）"),
        toolBtn(EditorTool.brush, const Icon(Icons.brush, size: 22), "画笔"),
        toolBtn(EditorTool.eraser, const EraserIcon(size: 22), "橡皮"),
        toolBtn(EditorTool.bucket, const Icon(Icons.format_color_fill, size: 22),
            "油漆桶"),
        toolBtn(
            EditorTool.eyedropper, const Icon(Icons.colorize, size: 22), "吸管"),
        toolBtn(
            EditorTool.select, const Icon(Icons.crop_free, size: 22), "选区"),
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

