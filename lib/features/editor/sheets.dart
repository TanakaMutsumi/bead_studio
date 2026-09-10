/// 编辑器功能弹窗集：改尺寸 / 降噪 / 限制色数 / 全局换色
///
/// 全部为 showModalBottomSheet 函数式封装，通过 onApply 回调结果
library;

import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/palette.dart';

/// 通用弹窗外壳
Widget _sheet(BuildContext context, String title, Widget child) {
  return SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
}

/// 改尺寸弹窗：预设 + 自定义宽高（最近邻重采样）
Future<void> showResizeSheet(
  BuildContext context, {
  required int width,
  required int height,
  required void Function(int newWidth, int newHeight) onApply,
}) async {
  final ctrlW = TextEditingController(text: width.toString());
  final ctrlH = TextEditingController(text: height.toString());
  const presets = [26, 29, 36, 52, 78, 104];

  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => _sheet(
      sheetContext,
      "调整网格尺寸（最近邻重采样）",
      StatefulBuilder(
        builder: (context, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in presets)
                  ActionChip(
                    label: Text("$p×$p"),
                    onPressed: () {
                      ctrlW.text = p.toString();
                      ctrlH.text = p.toString();
                      setSheetState(() {});
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ctrlW,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "宽（列数）",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text("×"),
                ),
                Expanded(
                  child: TextField(
                    controller: ctrlH,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "高（行数）",
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "当前 $width×$height，缩放后细节会有损失",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final w = int.tryParse(ctrlW.text) ?? 0;
                  final h = int.tryParse(ctrlH.text) ?? 0;
                  if (w < 4 || h < 4 || w > 400 || h > 400) {
                    AppSnackBar.show(sheetContext, "宽高须在 4-400 之间");
                    return;
                  }
                  Navigator.of(sheetContext).pop();
                  onApply(w, h);
                },
                child: const Text("应用"),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 降噪弹窗：多数投票迭代次数
Future<void> showDenoiseSheet(
  BuildContext context, {
  required void Function(int passes) onApply,
}) async {
  var passes = 1.0;
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => _sheet(
      sheetContext,
      "降噪（3×3 多数投票）",
      StatefulBuilder(
        builder: (context, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: passes,
              min: 1,
              max: 3,
              divisions: 2,
              label: "${passes.round()} 次",
              onChanged: (v) => setSheetState(() => passes = v),
            ),
            Text(
              "强度 ${passes.round()}：孤立噪点会被周围颜色同化，次数越多越平滑",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  onApply(passes.round());
                },
                child: const Text("应用"),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 限制色数弹窗：保留出现频率最高的 N 色
Future<void> showLimitColorsSheet(
  BuildContext context, {
  required int usedColors,
  required int maxColors,
  required void Function(int n) onApply,
}) async {
  var n = usedColors.clamp(2, maxColors).toDouble();
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => _sheet(
      sheetContext,
      "限制颜色数量",
      StatefulBuilder(
        builder: (context, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Slider(
              value: n,
              min: 2,
              max: maxColors.toDouble(),
              divisions: (maxColors - 2).clamp(1, 1000),
              label: "${n.round()} 色",
              onChanged: (v) => setSheetState(() => n = v),
            ),
            Text(
              "当前已用 $usedColors 色 → 保留 ${n.round()} 色（按用量保留主色，其余映射到最近保留色）",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  onApply(n.round());
                },
                child: const Text("应用"),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 色板横向单选行（换色弹窗用）
class _PaletteRow extends StatelessWidget {
  final BeadPalette palette;
  final int selected;
  final String label;
  final void Function(int index) onPicked;

  const _PaletteRow({
    required this.palette,
    required this.selected,
    required this.label,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: palette.colors.length + 1, // +1 = 空格（擦除）
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final isBlank = i == palette.colors.length;
              final sel = selected == (isBlank ? -1 : i);
              final c = isBlank ? null : palette.colors[i];
              return GestureDetector(
                onTap: () => onPicked(isBlank ? -1 : i),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c != null
                        ? Color.fromARGB(255, c.r, c.g, c.b)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: sel ? Colors.blue : Colors.black26,
                      width: sel ? 3 : 1,
                    ),
                  ),
                  child: isBlank
                      ? const Icon(Icons.block, size: 20, color: Colors.black38)
                      : Center(
                          child: Text(
                            c!.id.replaceFirst("P", ""),
                            style: TextStyle(
                              fontSize: 10,
                              color: (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) >
                                      150
                                  ? Colors.black54
                                  : Colors.white70,
                            ),
                          ),
                        ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 全局换色弹窗：from → to 全部替换
Future<void> showReplaceColorSheet(
  BuildContext context, {
  required BeadPalette palette,
  required int initialFrom,
  required int initialTo,
  required void Function(int from, int to) onApply,
}) async {
  var from = initialFrom;
  var to = initialTo;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _sheet(
        sheetContext,
        "全局换色（整幅图案替换）",
        StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PaletteRow(
                palette: palette,
                selected: from,
                label: "把这一种颜色",
                onPicked: (i) => setSheetState(() => from = i),
              ),
              const SizedBox(height: 12),
              _PaletteRow(
                palette: palette,
                selected: to,
                label: "全部替换为",
                onPicked: (i) => setSheetState(() => to = i),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: from == to
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          onApply(from, to);
                        },
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text("替换"),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
