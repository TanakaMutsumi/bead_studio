import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/responsive.dart';
import 'douyin_import_sheet.dart';
import 'xhs_import_sheet.dart';

/// 阶段一：选图入口（相册 / 拍照 / 小红书 / 抖音链接）
///
/// 手机竖屏：四个入口纵向排列（原布局，逐像素不变）。平板/宽屏（宽 ≥ 600dp）：
/// 单列居中在 1280dp 横屏上是一条孤零零的细柱、两侧大片空白——四个入口改
/// 2×2 网格、整组限宽 720 居中（2026-11-24 用户反馈「排布明显不合理」）
class PickStep extends StatelessWidget {
  final void Function(ImageSource source) onPick;

  /// 链接导入（小红书/抖音）：拿到选中图的原始字节，
  /// 走与相册选图相同的下游链路
  final void Function(Uint8List bytes) onLinkBytes;

  const PickStep({super.key, required this.onPick, required this.onLinkBytes});

  @override
  Widget build(BuildContext context) {
    final entries = <(IconData, String, VoidCallback)>[
      (
        Icons.photo_library,
        "从相册选择图纸",
        () => onPick(ImageSource.gallery),
      ),
      (Icons.photo_camera, "拍照图纸", () => onPick(ImageSource.camera)),
      (
        Icons.link,
        "小红书链接导入",
        () => showXhsImportSheet(context, onLinkBytes),
      ),
      (
        Icons.music_note,
        "抖音链接导入",
        () => showDouyinImportSheet(context, onLinkBytes),
      ),
    ];
    Widget entryButton(int i) => FilledButton.tonalIcon(
          onPressed: entries[i].$3,
          icon: Icon(entries[i].$1),
          label: Text(entries[i].$2),
        );
    final intro = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.grid_on, size: 72, color: Colors.black26),
        const SizedBox(height: 16),
        const Text("导入拼豆图纸，五步还原为可编辑图案", textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text(
          "框图例 → 核对用色 → 九宫格对齐 → 框选主体 → 识别 → 手工纠错",
          style: TextStyle(fontSize: 12, color: Colors.black45),
        ),
      ],
    );
    if (!isMediumWidth(context)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...intro.children,
              const SizedBox(height: 32),
              entryButton(0),
              const SizedBox(height: 12),
              entryButton(1),
              const SizedBox(height: 12),
              entryButton(2),
              const SizedBox(height: 12),
              entryButton(3),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...intro.children,
            const SizedBox(height: 24),
            // 整组限宽：入口各 340dp 固定宽，放得下就 2×2，放不下自动折行
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  for (var i = 0; i < entries.length; i++)
                    SizedBox(width: 340, child: entryButton(i)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
