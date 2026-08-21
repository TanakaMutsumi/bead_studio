/// 草稿本地存储：JSON 文件存取（应用文档目录）
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'pattern_model.dart';

class DraftStore {
  static const _dirName = "bead_drafts";

  static Future<Directory> _draftDir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory("${root.path}${Platform.pathSeparator}$_dirName");
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 保存草稿，返回文件
  static Future<File> save(PatternModel model) async {
    final dir = await _draftDir();
    final now = DateTime.now();
    final name = "draft_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.json";
    final file = File("${dir.path}${Platform.pathSeparator}$name");
    return file.writeAsString(const JsonEncoder().convert(model.toJson()));
  }

  /// 列出全部草稿（新→旧）
  static Future<List<File>> list() async {
    final dir = await _draftDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(".json"))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  static Future<PatternModel> read(File file) async {
    final json = await file.readAsString();
    return PatternModel.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  static void delete(File file) {
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  static String _two(int v) => v.toString().padLeft(2, "0");
}
