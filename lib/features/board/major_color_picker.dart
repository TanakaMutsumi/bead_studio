/// 粗框线颜色选择：预设色 BottomSheet（板设置页/拼豆页共用）
library;

import 'package:flutter/material.dart';

import '../../core/board_config.dart';

/// 预设色单（首位 = 默认橙；选中它由调用方映射回 null 与未配置旧板同语义）
const majorColorPresets = <int>[
  BoardConfig.defaultMajorColor, // 橙（默认）
  0xFFFFB300, // 琥珀
  0xFFE53935, // 红
  0xFF43A047, // 绿
  0xFF1E88E5, // 蓝
  0xFF8E24AA, // 紫
  0xFF212121, // 黑（浅底接近原始观感）
  0xFFFFFFFF, // 白
];

/// 打开色板选粗线颜色：返回所选 ARGB（含默认橙原值）；取消/点外部返回 null
Future<int?> showMajorColorPicker(BuildContext context, int? current) {
  return showModalBottomSheet<int>(
    context: context,
    builder: (sctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("粗框线颜色", style: Theme.of(sctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final v in majorColorPresets)
                  _colorOption(
                    sctx,
                    Color(v),
                    v == (current ?? BoardConfig.defaultMajorColor),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "粗线画在豆色之上（顶层），深色豆上选亮色更醒目",
              style: Theme.of(sctx).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}

/// 单颗圆色块：选中画蓝圈+对勾（勾色按背景亮度取黑/白）
Widget _colorOption(BuildContext sctx, Color c, bool selected) {
  return GestureDetector(
    onTap: () => Navigator.pop(sctx, c.toARGB32()),
    child: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? Colors.blue : Colors.black26,
          width: selected ? 3 : 1,
        ),
      ),
      child: selected
          ? Icon(
              Icons.check,
              size: 22,
              color: c.computeLuminance() > 0.5 ? Colors.black54 : Colors.white,
            )
          : null,
    ),
  );
}
