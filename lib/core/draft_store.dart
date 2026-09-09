/// 作品库本地存储：JSON 文件存取（应用文档目录）+ 元数据（名字/文件夹/更新时间）
///
/// 新格式：{"meta": {name, folder, updatedAt}, "pattern": {…PatternModel}}
/// 旧格式（平铺 PatternModel）读取时自动补默认元数据，首次改名/移动才升级写回
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'board_config.dart';
import 'pattern_model.dart';

/// 一个作品的完整条目（元数据 + 已解析的图案 + 拼装进度 + 板配置）
class WorkEntry {
  final File file;
  final String name;
  final String folder;

  ///< 分组名，空串 = 未分组
  final DateTime updatedAt;
  final PatternModel model;
  final Set<int> placed;

  ///< 拼装已放格子（扁平索引；复刻原版 assemble/progress 的本地版）
  final BoardConfig? board;

  ///< 拼豆板配置（null = 未配置过板）

  const WorkEntry({
    required this.file,
    required this.name,
    required this.folder,
    required this.updatedAt,
    required this.model,
    this.placed = const <int>{},
    this.board,
  });
}

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

  // ==================== 兼容旧 API ====================

  /// 保存草稿，返回文件
  static Future<File> save(PatternModel model) => saveWork(model);

  /// 列出全部草稿文件（新→旧）
  static Future<List<File>> list() async {
    final dir = await _draftDir();
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(".json"))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  static Future<PatternModel> read(File file) async {
    final entry = await readEntry(file);
    return entry.model;
  }

  static void delete(File file) => deleteWork(file);

  // ==================== 作品库 API ====================

  /// 列出全部作品（按更新时间新→旧），并解析元数据
  static Future<List<WorkEntry>> listWorks() async {
    final files = await list();
    final works = <WorkEntry>[];
    for (final f in files) {
      try {
        works.add(await readEntry(f));
      } catch (_) {
        // 单个损坏文件跳过，不拖垮整个列表
      }
    }
    works.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return works;
  }

  /// 解析单个文件（兼容旧平铺格式）
  static Future<WorkEntry> readEntry(File file) async {
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final PatternModel model;
    String name = "";
    String folder = "";
    DateTime updatedAt = file.lastModifiedSync();
    Set<int> placed = const <int>{};
    BoardConfig? board;

    final meta = json["meta"];
    if (meta is Map<String, dynamic>) {
      model = PatternModel.fromJson(json["pattern"] as Map<String, dynamic>);
      name = meta["name"] as String? ?? "";
      folder = meta["folder"] as String? ?? "";
      updatedAt =
          DateTime.tryParse(meta["updatedAt"] as String? ?? "") ?? updatedAt;
      final rawPlaced = meta["placed"];
      if (rawPlaced is List) {
        placed = rawPlaced.whereType<int>().toSet();
      }
      board = BoardConfig.fromJson(meta["board"] as Map<String, dynamic>?);
    } else {
      model = PatternModel.fromJson(json);
    }
    return WorkEntry(
      file: file,
      name: name.isEmpty ? _defaultName(updatedAt) : name,
      folder: folder,
      updatedAt: updatedAt,
      model: model,
      placed: placed,
      board: board,
    );
  }

  /// 保存作品；[overwrite] 非空时覆写该文件（保留其 name/folder），否则新建。
  /// [placed] 拼装进度 / [board] 拼豆板配置（null = 覆写时保留旧值、新建时空）
  static Future<File> saveWork(
    PatternModel model, {
    String? name,
    String? folder,
    File? overwrite,
    Set<int>? placed,
    BoardConfig? board,
  }) async {
    final dir = await _draftDir();
    if (overwrite != null && overwrite.existsSync()) {
      final old = await readEntry(overwrite);
      return overwrite.writeAsString(
        const JsonEncoder().convert({
          "meta": {
            "name": name ?? old.name,
            "folder": folder ?? old.folder,
            "updatedAt": DateTime.now().toIso8601String(),
            "placed": (placed ?? old.placed).toList(),
            if ((board ?? old.board) != null)
              "board": (board ?? old.board)!.toJson(),
          },
          "pattern": model.toJson(),
        }),
      );
    }

    final now = DateTime.now();
    final stamp =
        "${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}${_two(now.second)}";
    final file = File("${dir.path}${Platform.pathSeparator}draft_$stamp.json");
    return file.writeAsString(
      const JsonEncoder().convert({
        "meta": {
          "name": (name == null || name.isEmpty) ? _defaultName(now) : name,
          "folder": folder ?? "",
          "updatedAt": now.toIso8601String(),
          "placed": (placed ?? const <int>[]).toList(),
          if (board != null) "board": board.toJson(),
        },
        "pattern": model.toJson(),
      }),
    );
  }

  /// 重命名（顺带升级旧格式）
  static Future<void> renameWork(File file, String name) =>
      _rewriteMeta(file, name: name);

  /// 移动到分组
  static Future<void> moveWork(File file, String folder) =>
      _rewriteMeta(file, folder: folder);

  /// 复制一份（名字加「副本」，拼装进度一并复制）
  static Future<File> copyWork(File file) async {
    final e = await readEntry(file);
    return saveWork(
      e.model,
      name: "${e.name} 副本",
      folder: e.folder,
      placed: e.placed,
    );
  }

  static Future<void> deleteWork(File file) {
    if (file.existsSync()) {
      file.deleteSync();
    }
    return Future.value();
  }

  /// 改名/移动共用的元数据重写（保留网格内容与拼装进度/板配置）
  static Future<void> _rewriteMeta(
    File file, {
    String? name,
    String? folder,
  }) async {
    final e = await readEntry(file);
    await file.writeAsString(
      const JsonEncoder().convert({
        "meta": {
          "name": name ?? e.name,
          "folder": folder ?? e.folder,
          "updatedAt": DateTime.now().toIso8601String(),
          "placed": e.placed.toList(),
          if (e.board != null) "board": e.board!.toJson(),
        },
        "pattern": e.model.toJson(),
      }),
    );
  }

  static String _defaultName(DateTime t) =>
      "图案 ${t.month}${_two(t.day)}日 ${_two(t.hour)}:${_two(t.minute)}";

  static String _two(int v) => v.toString().padLeft(2, "0");
}
