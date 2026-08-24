/// 调色板注册表：内置色卡加载 + 选中持久化 + 草稿调色板解析
///
/// 内置色卡：演示色卡（40 色硬编码）+ MARD 色卡（assets/palettes/mard.json，220 色）
/// 草稿兼容：作品存有生成时的 paletteIds，打开时与本色卡不一致则按 id 逐色查回
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../data/demo_palette.dart';
import 'palette.dart';
import 'pattern_model.dart';

/// 一个可选色卡
class PaletteInfo {
  final String id; ///< 注册表键（"demo" / "mard"）
  final String label; ///< UI 显示名
  final BeadPalette palette;

  const PaletteInfo(this.id, this.label, this.palette);
}

class PaletteRegistry {
  static List<PaletteInfo>? _cache;

  /// 加载全部内置色卡（结果缓存；mard 资产缺失时静默降级为仅演示色卡）
  static Future<List<PaletteInfo>> load() async {
    final cached = _cache;
    if (cached != null) {
      return cached;
    }
    final list = <PaletteInfo>[
      const PaletteInfo("demo", "演示色卡 40 色", demoPalette),
    ];
    try {
      final raw = await rootBundle.loadString("assets/palettes/mard.json");
      list.add(PaletteInfo(
        "mard",
        "MARD 色卡 220 色",
        BeadPalette.fromJson(jsonDecode(raw) as List<dynamic>),
      ));
    } catch (_) {
      // 资产缺失（打包遗漏等）：仅剩演示色卡，不崩
    }
    _cache = list;
    return list;
  }

  // ==================== 选中持久化 ====================

  /// 读选中的色卡 id（无记录/读失败回退 "mard"；web 无本地文件恒走回退）
  static Future<String> loadSelectedId() async {
    if (kIsWeb) {
      return "mard";
    }
    try {
      final f = await _settingsFile();
      if (f.existsSync()) {
        final id = (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)["palette"] as String?;
        if (id != null) {
          return id;
        }
      }
    } catch (_) {
      // 损坏设置文件当不存在
    }
    return "mard";
  }

  static Future<void> saveSelectedId(String id) async {
    if (kIsWeb) {
      return;
    }
    try {
      final f = await _settingsFile();
      f.writeAsStringSync(jsonEncode({"palette": id}));
    } catch (_) {
      // 写失败不影响主流程
    }
  }

  static Future<File> _settingsFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File("${root.path}${Platform.pathSeparator}bead_settings.json");
  }

  /// 加载当前选中的色卡（id 失效时回退第一个）
  static Future<PaletteInfo> loadSelected() async {
    final all = await load();
    final id = await loadSelectedId();
    for (final p in all) {
      if (p.id == id) {
        return p;
      }
    }
    return all.first;
  }

  // ==================== 草稿调色板解析 ====================

  /// 为作品解析渲染用调色板：paletteIds 与某内置色卡完全一致则直接用；
  /// 否则按 id 跨色卡逐色查回组装专属调色板（查不到的索引给灰色占位，网格不错位）
  static Future<BeadPalette> resolveForModel(PatternModel model, BeadPalette fallback) async {
    final all = await load();
    for (final info in all) {
      if (_sameIds(info.palette, model.paletteIds)) {
        return info.palette;
      }
    }
    if (_sameIds(fallback, model.paletteIds)) {
      return fallback;
    }
    // 跨色卡/老草稿：id -> 色合并表（先注册的优先，demo 在前不影响 mard 唯一性）
    final merged = <String, BeadColor>{};
    for (final info in all) {
      for (final c in info.palette.colors) {
        merged.putIfAbsent(c.id, () => c);
      }
    }
    return BeadPalette([
      for (final id in model.paletteIds) merged[id] ?? BeadColor(id, "缺失色", 0xFF808080),
    ]);
  }

  static bool _sameIds(BeadPalette palette, List<String> ids) {
    if (palette.colors.length != ids.length) {
      return false;
    }
    for (var i = 0; i < ids.length; i++) {
      if (palette.colors[i].id != ids[i]) {
        return false;
      }
    }
    return true;
  }
}
