/// 豆板选择页：主页「开始拼豆」的第一跳——已保存豆板列表（缩略图 +
/// 名称，形态同「我的作品」），点选进入板设置继续编辑/拼豆；也可新建
/// 空板。缩略图直接复用 BoardPainter 静态渲染（板底格 + 各作品按摆位
/// 叠加），与板设置页所见一致。
library;

import 'package:flutter/material.dart';

import '../../core/draft_store.dart';
import '../../core/palette_registry.dart';
import 'board_dialogs.dart';
import 'board_painter.dart';
import 'board_setup_page.dart';
import 'placed_work.dart';

/// 一块豆板的展示模型：列表条目 + 完整会话（板配置/作品引用）+
/// 逐件解析出的渲染用 PlacedWork（含调色板）
class _BoardVM {
  final BoardEntry entry;
  final BoardSession session;
  final List<PlacedWork> works;

  const _BoardVM(this.entry, this.session, this.works);
}

class BoardSelectPage extends StatefulWidget {
  const BoardSelectPage({super.key});

  @override
  State<BoardSelectPage> createState() => _BoardSelectPageState();
}

class _BoardSelectPageState extends State<BoardSelectPage> {
  List<_BoardVM> _boards = [];
  var _loading = true;
  Object? _loadError;
  var _firstLoad = true;

  ///< 首次加载为空时自动跳新板设置（保留旧「开始拼豆直达空板」习惯）；
  /// 删光豆板后的空态不跳，留按钮手动进

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final selected = await PaletteRegistry.loadSelected();
      final vms = <_BoardVM>[];
      for (final b in await DraftStore.listBoards()) {
        // listBoards 只给元数据，缩略图须再读会话与各作品图案
        final session = await DraftStore.loadBoardFile(b.file);
        if (session == null) {
          continue;
        }
        final works = <PlacedWork>[];
        for (final sw in session.works) {
          try {
            final e = await DraftStore.readEntry(sw.file);
            works.add(
              PlacedWork(
                entry: e,
                palette: await PaletteRegistry.resolveForModel(
                  e.model,
                  selected.palette,
                ),
                ox: sw.ox,
                oy: sw.oy,
                rot: sw.rot,
                flipH: sw.flipH,
                flipV: sw.flipV,
              ),
            );
          } catch (_) {
            // 作品文件已删/损坏：跳过该件（缩略图少一块，不影响打开）
          }
        }
        vms.add(_BoardVM(b, session, works));
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _boards = vms;
        _loading = false;
      });
      // 首次进来一块板都没有：选择页无事可做，直达新板设置
      if (_firstLoad && vms.isEmpty) {
        _newBoard();
      }
      _firstLoad = false;
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _loadError = e;
      });
    }
  }

  // ==================== 操作 ====================

  /// 进入板设置（选中板带入 / 空板）。pushReplacement：板设置退出回主页，
  /// 与「我的作品 → 编辑器」同款导航栈形态
  void _open(_BoardVM? vm) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => vm == null
            ? const BoardSetupPage()
            : BoardSetupPage(initialBoard: vm.entry),
      ),
    );
  }

  /// 新建空板（无确认：本页没有可丢的编辑状态）
  void _newBoard() => _open(null);

  /// 重命名：同名覆盖语义——新名存一份，旧名文件删除
  Future<void> _rename(_BoardVM vm) async {
    final ctrl = TextEditingController(text: vm.entry.name);
    final name = await inputDialog(
      context,
      "重命名豆板",
      "豆板名",
      ctrl,
      emptyError: "豆板名不能为空",
    );
    final n = name?.trim();
    if (n == null || n.isEmpty) {
      return;
    }
    await DraftStore.saveBoardFile(
      BoardSession(
        name: n,
        board: vm.session.board,
        works: vm.session.works,
        savedAt: vm.session.savedAt,
      ),
    );
    if (n != vm.entry.name) {
      await DraftStore.deleteBoardFile(vm.entry.file);
    }
    _reload();
  }

  Future<void> _delete(_BoardVM vm) async {
    final ok = await confirmDialog(
      context,
      "删除豆板「${vm.entry.name}」？",
      "只删摆板布局，作品本身不受影响，删除后无法恢复",
    );
    if (ok != true) {
      return;
    }
    await DraftStore.deleteBoardFile(vm.entry.file);
    _reload();
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("选择豆板"),
        actions: [
          IconButton(
            onPressed: _loading ? null : _newBoard,
            icon: const Icon(Icons.add),
            tooltip: "新建空板",
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 56,
                        color: Colors.black26,
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          "豆板列表读取失败：$_loadError",
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
              : _boards.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.grid_view_outlined,
                            size: 72,
                            color: Colors.black26,
                          ),
                          const SizedBox(height: 16),
                          const Text("还没有保存过豆板，先摆好再「另存为豆板」"),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _newBoard,
                            icon: const Icon(Icons.add),
                            label: const Text("新建空板"),
                          ),
                        ],
                      ),
                    )
                  : _buildGrid(),
    );
  }

  /// 缩略图网格（「我的作品」同款卡片形态）
  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: _boards.length,
      itemBuilder: (context, i) {
        final vm = _boards[i];
        return GestureDetector(
          onTap: () => _open(vm),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 缩略图 Expanded + 板纵横比（板通常方形，自定义板可长方）：
                // 文本行随字体放大变高时自动收缩，永不溢出卡片
                Expanded(
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: vm.session.board.w / vm.session.board.h,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: BoardPainter(
                                board: vm.session.board,
                                items: [
                                  for (final w in vm.works)
                                    BoardPaintItem(
                                      model: w.model,
                                      palette: w.palette,
                                      ox: w.ox,
                                      oy: w.oy,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
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
                            tooltip: "豆板操作",
                            onSelected: (action) {
                              switch (action) {
                                case "open":
                                  _open(vm);
                                case "rename":
                                  _rename(vm);
                                case "delete":
                                  _delete(vm);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: "open", child: Text("打开")),
                              PopupMenuItem(
                                value: "rename",
                                child: Text("重命名"),
                              ),
                              PopupMenuItem(
                                value: "delete",
                                child: Text("删除"),
                              ),
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
                        vm.entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        "${vm.entry.workCount} 件作品 · ${vm.entry.boardLabel}"
                        " · ${_fmtTime(vm.entry.updatedAt)}",
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

  String _fmtTime(DateTime t) =>
      "${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";
}
