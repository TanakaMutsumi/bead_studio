/// 珠子库存本地存储：色号 -> 库存颗数（JSON，应用文档目录）
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class InventoryStore {
  static const _fileName = "bead_inventory.json";

  static Future<File> _file() async {
    final root = await getApplicationDocumentsDirectory();
    return File("${root.path}${Platform.pathSeparator}$_fileName");
  }

  /// 读全部库存（无文件返回空表）
  static Future<Map<String, int>> read() async {
    final f = await _file();
    if (!f.existsSync()) {
      return {};
    }
    final json = jsonDecode(f.readAsStringSync());
    if (json is! Map<String, dynamic>) {
      return {};
    }
    final counts = json["counts"];
    if (counts is! Map<String, dynamic>) {
      return {};
    }
    return {
      for (final e in counts.entries)
        if (e.value is num) e.key: (e.value as num).toInt(),
    };
  }

  /// 全量保存
  static Future<void> save(Map<String, int> counts) async {
    final f = await _file();
    await f.writeAsString(const JsonEncoder().convert({"counts": counts}));
  }

  /// 清空库存
  static Future<void> clear() => save({});
}
