import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../board/board_select_page.dart';
import '../import/import_page.dart';
import '../restore/restore_page.dart';
import '../works/works_page.dart';

/// 主页：四大功能入口（2×2 卡片）——开始拼豆 / 图纸还原 / 图片转换 / 我的作品
///
/// 色卡在进入「我的作品」时需作 fallback 传入，主页启动即预加载当前选中色卡
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BeadPalette _palette = const BeadPalette([]);

  ///< 当前选中色卡（作品渲染 fallback，进入页前加载好）

  @override
  void initState() {
    super.initState();
    _loadPalette();
  }

  Future<void> _loadPalette() async {
    final selected = await PaletteRegistry.loadSelected();
    if (mounted) {
      setState(() => _palette = selected.palette);
    }
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// 入口卡片：图标 + 标题 + 副标题
  Widget _entryCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.all(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 44, color: cs.primary),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.black45),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("拼豆图案工作室")),
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _entryCard(
                      context,
                      icon: Icons.grid_view_outlined,
                      title: "开始拼豆",
                      subtitle: "选择豆板摆板拼装",
                      onTap: () => _push(const BoardSelectPage()),
                    ),
                  ),
                  Expanded(
                    child: _entryCard(
                      context,
                      icon: Icons.document_scanner,
                      title: "图纸还原",
                      subtitle: "拍照图纸转图案",
                      onTap: () => _push(const RestorePage()),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _entryCard(
                      context,
                      icon: Icons.image_outlined,
                      title: "图片转换",
                      subtitle: "选图转拼豆图案",
                      onTap: () => _push(const ImportPage()),
                    ),
                  ),
                  Expanded(
                    child: _entryCard(
                      context,
                      icon: Icons.folder_open,
                      title: "我的作品",
                      subtitle: "作品库与拼装进度",
                      onTap: () => _push(WorksPage(palette: _palette)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
