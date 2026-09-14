import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 阶段一：选图入口（相册 / 拍照）
class PickStep extends StatelessWidget {
  final void Function(ImageSource source) onPick;

  const PickStep({super.key, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
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
            const SizedBox(height: 32),
            FilledButton.tonalIcon(
              onPressed: () => onPick(ImageSource.gallery),
              icon: const Icon(Icons.photo_library),
              label: const Text("从相册选择图纸"),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => onPick(ImageSource.camera),
              icon: const Icon(Icons.photo_camera),
              label: const Text("拍照图纸"),
            ),
          ],
        ),
      ),
    );
  }
}
