/// 调色板模型：珠子颜色集合（演示版 40 色，正式版替换为实测色卡）
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 单颗珠子颜色定义
class BeadColor {
  final String id;

  ///< 颜色编号（如 "P01"）
  final String name;

  ///< 显示名（如 "奶白"）
  final int rgb;

  ///< 0xRRGGBB

  const BeadColor(this.id, this.name, this.rgb);

  int get r => (rgb >> 16) & 0xFF;
  int get g => (rgb >> 8) & 0xFF;
  int get b => rgb & 0xFF;
}

/// 珠子调色板
class BeadPalette {
  final List<BeadColor> colors;

  const BeadPalette(this.colors);

  /// 按 id 查找，找不到返回 null
  BeadColor? byId(String id) {
    for (final c in colors) {
      if (c.id == id) {
        return c;
      }
    }
    return null;
  }

  /// 从 JSON 加载（草稿/用户自定义调色板）
  factory BeadPalette.fromJson(List<dynamic> json) {
    return BeadPalette([
      for (final item in json)
        BeadColor(
          item["id"] as String,
          item["name"] as String? ?? "",
          (item["rgb"] as num).toInt(),
        ),
    ]);
  }

  List<Map<String, dynamic>> toJson() => [
        for (final c in colors) {"id": c.id, "name": c.name, "rgb": c.rgb},
      ];
}

/// 色号文本用黑字（true）还是白字（false）：按 WCAG 相对亮度算黑/白
/// 两者的对比度取高者；近中间的饱和色（中蓝/玫红类）偏白——彩底配
/// 白字是习惯且更轻盈。
///
/// 取代旧判法 `luma > 150`（2026-11-10 用户反馈自适应没生效）：亮度
/// 阈值会把 M2/H20 类浅灰米色（luma 145~157）判成深色出白字，浅底
/// 白字看不见；H2 类近白底黑字两边判法一致，对比度法不会回退。
bool beadLabelDark(Color c) {
  double lin(double v) {
    final u = v / 255;
    return u <= 0.03928
        ? u / 12.92
        : math.pow((u + 0.055) / 1.055, 2.4).toDouble();
  }

  final l = 0.2126 * lin(c.r * 255) +
      0.7152 * lin(c.g * 255) +
      0.0722 * lin(c.b * 255);
  final whiteContrast = 1.05 / (l + 0.05);
  final blackContrast = (l + 0.05) / 0.05;
  return blackContrast > whiteContrast + 1.2;
}
