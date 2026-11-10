import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_snack_bar.dart';
import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/pattern_model.dart';
import '../editor/editor_page.dart';
import '../editor/grid_painter.dart';

/// 作品条目 + 渲染用调色板（按作品自己的 paletteIds 解析，跨色卡旧作不串色）
class _WorkVM {
  final WorkEntry entry;
  final BeadPalette palette;

  const _WorkVM(this.entry, this.palette);
}

/// 作品库页：缩略图网格 + 分组筛选 + 重命名/移动/复制/删除 + 多选批量操作
class WorksPage extends StatefulWidget {
  final BeadPalette palette;

  ///< 兜底调色板（作品色号解析失败时用）

  const WorksPage({super.key, required this.palette});

  @override
  State<WorksPage> createState() => _WorksPageState();
}

class _WorksPageState extends State<WorksPage> {
  List<_WorkVM> _works = [];
  var _loading = true;
  Object? _loadError;

  ///< 列表读取异常（目录权限/IO 等）：不再永远转圈，显示原因 + 重试
  String? _folderFilter;

  ///< null = 全部
  var _multiSelect = false;
  final Set<File> _selected = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 导入 .beadpattern 图案文件（编辑器「导出图案文件」的对端）：
  /// 选文件 → 校验格式 → 存作品库 → 刷新列表
  Future<void> _importPatternFile() async {
    final result = await FilePickerPlatform.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: ["beadpattern"],
    );
    if (result.isEmpty) {
      return; // 用户取消
    }
    final picked = result.single;
    final bytes = await picked.readAsBytes();
    try {
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map<String, dynamic> || data["type"] != "bead-pattern") {
        throw const FormatException("不是豆田图案文件");
      }
      final model = PatternModel.fromJson(data["pattern"]);
      if (model.width <= 0 ||
          model.height <= 0 ||
          model.grid.length != model.width * model.height) {
        throw const FormatException("图案数据不完整");
      }
      final name = (data["name"] as String?)?.trim();
      final file = await DraftStore.saveWork(
        model,
        name: (name == null || name.isEmpty) ? null : name,
      );
      await _reload();
      if (mounted) {
        AppSnackBar.show(
          context,
          "已导入：${file.path.split(Platform.pathSeparator).last}",
        );
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(
          context,
          "导入失败：${picked.name}（不是有效的 .beadpattern 文件）",
        );
      }
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final works = await DraftStore.listWorks();
      final vms = <_WorkVM>[];
      for (final w in works) {
        vms.add(
          _WorkVM(
            w,
            await PaletteRegistry.resolveForModel(w.model, widget.palette),
          ),
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _works = vms;
        _loading = false;
        _selected.clear();
        if (_multiSelect && _selected.isEmpty) {
          _multiSelect = false;
        }
      });
    } catch (e) {
      // 读取链路抛异常（如作品目录权限异常）时 _loading 会卡在 true，
      // 页面永远转圈进不去（真机/模拟器均复现过）——落进错误态可重试
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadError = e;
      });
    }
  }

  List<String> get _folders => _works
      .map((w) => w.entry.folder)
      .where((f) => f.isNotEmpty)
      .toSet()
      .toList()
    ..sort();

  List<_WorkVM> get _filtered => _folderFilter == null
      ? _works
      : _works.where((w) => w.entry.folder == _folderFilter).toList();

  // ==================== 操作 ====================

  void _open(_WorkVM w) {
    // push（非 pushReplacement）：编辑器返回时回作品库列表而不是主页
    // （2026-11-10 用户反馈：退出编辑应回上一层的「我的作品」）
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorPage(
          model: w.entry.model,
          palette: w.palette,
          sourceFile: w.entry.file,
          placed: w.entry.placed,
          sortMode: w.entry.sortMode,
          workName: w.entry.name,
        ),
      ),
    );
  }

  Future<void> _rename(_WorkVM w) async {
    final ctrl = TextEditingController(text: w.entry.name);
    final name = await _inputDialog("重命名", "作品名", ctrl);
    if (name == null || name.trim().isEmpty) {
      return;
    }
    await DraftStore.renameWork(w.entry.file, name.trim());
    _reload();
  }

  Future<void> _move(List<File> files) async {
    final folders = _folders;
    final folder = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "移动到分组",
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final f in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(f),
                onTap: () => Navigator.of(sheetContext).pop(f),
              ),
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: const Text("未分组"),
              onTap: () => Navigator.of(sheetContext).pop(""),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text("新建分组"),
              onTap: () async {
                final name = await _inputDialog(
                  "新建分组",
                  "分组名",
                  TextEditingController(),
                );
                if (!sheetContext.mounted) {
                  return;
                }
                Navigator.of(sheetContext)
                    .pop(name?.trim().isEmpty == true ? null : name?.trim());
              },
            ),
          ],
        ),
      ),
    );
    if (folder == null) {
      return;
    }
    for (final f in files) {
      await DraftStore.moveWork(f, folder);
    }
    _reload();
  }

  Future<void> _copy(_WorkVM w) async {
    await DraftStore.copyWork(w.entry.file);
    _reload();
  }

  Future<void> _delete(List<File> files) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(files.length == 1 ? "删除作品？" : "删除 ${files.length} 个作品？"),
        content: const Text("删除后无法恢复"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("删除"),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    for (final f in files) {
      await DraftStore.deleteWork(f);
    }
    _reload();
  }

  /// 单行输入对话框，取消返回 null
  Future<String?> _inputDialog(
    String title,
    String hint,
    TextEditingController ctrl,
  ) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(ctrl.text),
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  void _toggleSelect(File f) => setState(() {
        if (_selected.contains(f)) {
          _selected.remove(f);
        } else {
          _selected.add(f);
        }
        if (_selected.isEmpty) {
          _multiSelect = false;
        }
      });

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _multiSelect
            ? Text("已选 ${_selected.length} 项")
            : const Text("我的作品"),
        actions: [
          if (_multiSelect)
            IconButton(
              onPressed: () => setState(() {
                _multiSelect = false;
                _selected.clear();
              }),
              icon: const Icon(Icons.close),
              tooltip: "退出多选",
            )
          else ...[
            // 导入 .beadpattern 图案文件（编辑器「导出图案文件」的对端，
            // 2026-11-10 用户需求：软件豆图格式导出与导入）
            IconButton(
              onPressed: _importPatternFile,
              icon: const Icon(Icons.file_open_outlined),
              tooltip: "导入图案文件",
            ),
            IconButton(
              onPressed: () async {
                final name = await _inputDialog(
                  "新建分组",
                  "分组名",
                  TextEditingController(),
                );
                if (name == null || name.trim().isEmpty) {
                  return;
                }
                setState(() => _folderFilter = name.trim());
              },
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: "新建分组",
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 56, color: Colors.black26),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      "作品列表读取失败：$_loadError",
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text("重试"),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                _buildFolderBar(),
                Expanded(
                  child: _filtered.isEmpty ? _buildEmpty() : _buildGrid(),
                ),
                if (_multiSelect) _buildBatchBar(),
              ],
            ),
    );
  }

  /// 分组筛选条
  Widget _buildFolderBar() {
    final folders = _folders;
    if (folders.isEmpty && _folderFilter == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: const Text("全部"),
              selected: _folderFilter == null,
              onSelected: (_) => setState(() => _folderFilter = null),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              label: const Text("未分组"),
              selected: _folderFilter == "",
              onSelected: (_) => setState(() => _folderFilter = ""),
            ),
          ),
          for (final f in folders)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(f),
                selected: _folderFilter == f,
                onSelected: (_) => setState(() => _folderFilter = f),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.collections_outlined,
            size: 72,
            color: Colors.black26,
          ),
          const SizedBox(height: 16),
          Text(_folderFilter == null ? "还没有作品，去导入图片生成一个吧" : "该分组下暂无作品"),
        ],
      ),
    );
  }

  /// 缩略图网格
  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // 卡片内容自适应（缩略图 Expanded 收缩）：大字体下文本行变高
        // 也不会把日期行裁出卡外——曾用固定 0.72 + 固定两行文本，
        // 系统字体放大时日期被卡片底缘裁掉
        childAspectRatio: 0.78,
      ),
      itemCount: _filtered.length,
      itemBuilder: (context, i) {
        final w = _filtered[i];
        final checked = _selected.contains(w.entry.file);
        return GestureDetector(
          onTap: () {
            if (_multiSelect) {
              _toggleSelect(w.entry.file);
            } else {
              _open(w);
            }
          },
          onLongPress: () {
            setState(() {
              _multiSelect = true;
              _selected.add(w.entry.file);
            });
          },
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 缩略图 Expanded：文本行随字体放大变高时自动收缩缩略图，
                // 永不溢出卡片（AspectRatio 在有界高度内取 min(宽,高) 方形）
                Expanded(
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: GridPainter(
                                model: w.entry.model,
                                palette: w.palette,
                                selectedColorIndex: -1,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (checked)
                        Positioned.fill(
                          child: Container(
                            color: Colors.blue.withValues(alpha: 0.25),
                            child: const Icon(
                              Icons.check_circle,
                              color: Colors.blue,
                              size: 32,
                            ),
                          ),
                        ),
                      if (!_multiSelect)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Container(
                            // 32px 紧凑圆：原 40px 在小卡上盖住缩略图一角过多
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              // 深底白图标：浅色缩略图上也看得清（半透明白圆叠
                              // 亮黄缩略图完全不可见，用户找不到删除入口）
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: PopupMenuButton<String>(
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              color: Colors.white,
                              icon: const Icon(
                                Icons.more_vert,
                                size: 18,
                                color: Colors.white,
                              ),
                              tooltip: "作品操作",
                              onSelected: (action) {
                                switch (action) {
                                  case "open":
                                    _open(w);
                                  case "rename":
                                    _rename(w);
                                  case "move":
                                    _move([w.entry.file]);
                                  case "copy":
                                    _copy(w);
                                  case "delete":
                                    _delete([w.entry.file]);
                                }
                              },
                              itemBuilder: (menuContext) => const [
                                PopupMenuItem(value: "open", child: Text("打开")),
                                PopupMenuItem(
                                  value: "rename",
                                  child: Text("重命名"),
                                ),
                                PopupMenuItem(
                                  value: "move",
                                  child: Text("移动到分组"),
                                ),
                                PopupMenuItem(value: "copy", child: Text("复制")),
                                PopupMenuItem(
                                    value: "delete", child: Text("删除")),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.entry.name,
                        maxLines: 2,

                        ///< 长名两行放完，不再一行截「…」（2026-11-10 反馈）
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        "${w.entry.model.width}×${w.entry.model.height} · ${_fmtTime(w.entry.updatedAt)}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.black45, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 多选模式底部批量操作条
  Widget _buildBatchBar() {
    return SafeArea(
      child: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            TextButton.icon(
              onPressed:
                  _selected.isEmpty ? null : () => _move(_selected.toList()),
              icon: const Icon(Icons.drive_file_move_outlined),
              label: const Text("移动"),
            ),
            TextButton.icon(
              onPressed:
                  _selected.isEmpty ? null : () => _delete(_selected.toList()),
              icon: const Icon(Icons.delete_outline),
              label: const Text("删除"),
            ),
            TextButton(
              onPressed:
                  _filtered.isEmpty || _selected.length == _filtered.length
                      ? null
                      : () => setState(
                            () => _selected
                                .addAll(_filtered.map((w) => w.entry.file)),
                          ),
              child: const Text("全选"),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      "${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
}
