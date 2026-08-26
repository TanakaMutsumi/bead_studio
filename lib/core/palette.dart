/// 调色板模型：珠子颜色集合（演示版 40 色，正式版替换为实测色卡）
library;

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
