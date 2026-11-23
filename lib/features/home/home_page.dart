import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/responsive.dart';
import '../board/board_select_page.dart';
import '../import/import_page.dart';
import '../restore/restore_page.dart';
import '../works/works_page.dart';

/// 主页：四大功能入口（2×2 卡片）——开始拼豆 / 图纸还原 / 图片转换 / 我的作品
///
/// 色卡在进入「我的作品」时需作 fallback 传入，主页启动即预加载当前选中色卡
///
/// 平板适配（2026-11-22）：手机竖屏两排铺满不变（[_buildCompact]）；宽 ≥ 600dp
/// 起卡片不再横向拉伸到整屏——按窗口比例排 4 列（横屏/近方形窗口，一排）或
/// 2 列（竖屏，两排），整组限宽居中、卡片高度封顶（[_buildWide]）
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

  /// 四个入口的数据，紧凑 / 宽屏两套布局共用
  List<({IconData icon, String title, String subtitle, VoidCallback onTap})>
      _entries() => [
            (
              icon: Icons.grid_view_outlined,
              title: "开始拼豆",
              subtitle: "选择豆板摆板拼装",
              onTap: () => _push(const BoardSelectPage()),
            ),
            (
              icon: Icons.document_scanner,
              title: "图纸还原",
              subtitle: "拍照图纸转图案",
              onTap: () => _push(const RestorePage()),
            ),
            (
              icon: Icons.image_outlined,
              title: "图片转换",
              subtitle: "选图转拼豆图案",
              onTap: () => _push(const ImportPage()),
            ),
            (
              icon: Icons.folder_open,
              title: "我的作品",
              subtitle: "作品库与拼装进度",
              onTap: () => _push(WorksPage(palette: _palette)),
            ),
          ];

  /// 入口卡片：图标 + 标题 + 副标题
  Widget _entryCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    double padding = 20,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.all(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(padding),
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
      appBar: AppBar(title: const Text("豆田")),
      body:
          isMediumWidth(context) ? _buildWide(context) : _buildCompact(context),
    );
  }

  /// 手机竖屏：两排各两张卡，铺满可用区域（原布局，逐像素不变）
  Widget _buildCompact(BuildContext context) {
    final e = _entries();
    Widget cell(int i) => Expanded(
          child: _entryCard(
            context,
            icon: e[i].icon,
            title: e[i].title,
            subtitle: e[i].subtitle,
            onTap: e[i].onTap,
          ),
        );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          Expanded(child: Row(children: [cell(0), cell(1)])),
          Expanded(child: Row(children: [cell(2), cell(3)])),
        ],
      ),
    );
  }

  /// 平板 / 宽屏：卡片不铺满整屏
  ///
  /// 列数看窗口比例而不是只看宽度——4 张卡只排得下 2 列或 4 列：横向或
  /// 近方形窗口（宽 > 高 × 1.2）与 ≥ 1000dp 一律 4 列一排，否则 2 列两排；
  /// 手机横屏（~851×393）也因此落到一排，不会被高度压成扁条。
  /// 卡片宽高比封顶 1.3（宽屏上不再是一眼望不到底的巨卡），窗口偏矮时
  /// 按可用高度整体收缩；整组限宽 1120 居中。矮到两排放不下卡片内容的
  /// 竖向窗口（高 < 420）退回紧凑布局
  Widget _buildWide(BuildContext context) {
    final e = _entries();
    return LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth;
        final h = cons.maxHeight;
        final cols = w >= 1000 || w > h * 1.2 ? 4 : 2;
        const pad = 16.0;
        const gap = 12.0;
        if (cols == 2 && h < 420) {
          return _buildCompact(context);
        }
        final gridW = math.min(w, 1120.0);
        final cardW = (gridW - pad * 2 - gap * (cols - 1)) / cols;
        final rowCnt = (e.length / cols).ceil();
        final cardH = math.min(
          cardW / 1.3,
          (h - pad * 2 - gap * (rowCnt - 1)) / rowCnt,
        );
        return Center(
          child: SizedBox(
            width: gridW,
            height: cardH * rowCnt + gap * (rowCnt - 1) + pad * 2,
            child: GridView.builder(
              padding: const EdgeInsets.all(pad),
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                childAspectRatio: cardW / cardH,
              ),
              itemCount: e.length,
              itemBuilder: (context, i) => _entryCard(
                context,
                icon: e[i].icon,
                title: e[i].title,
                subtitle: e[i].subtitle,
                onTap: e[i].onTap,
                padding: 14,
              ),
            ),
          ),
        );
      },
    );
  }
}
