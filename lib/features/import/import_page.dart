import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/draft_store.dart';
import '../../core/pixel_engine.dart';
import '../../core/quantizer.dart';
import '../../data/demo_palette.dart';
import '../editor/editor_page.dart';
import '../restore/restore_page.dart';

/// 导入页：选图 -> 选板尺寸/抖动 -> 转换进编辑器；支持打开历史草稿
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  static const _boardSizes = [26, 29, 52, 78];

  XFile? _pickedFile;
  Uint8List? _pickedBytes; ///< 跨平台图片字节（web 上 XFile.path 是 blob URL 不能走 dart:io）
  var _boardSize = 52;
  var _kernel = DitherKernel.none;
  var _converting = false;

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 100);
    if (picked != null) {
      final bytes = await picked.readAsBytes();
      setState(() {
        _pickedFile = picked;
        _pickedBytes = bytes;
      });
    }
  }

  Future<void> _convert() async {
    if (_pickedFile == null) {
      return;
    }
    setState(() {
      _converting = true;
    });
    try {
      final bytes = _pickedBytes!;
      final model = PixelEngine(demoPalette).convert(
        bytes: bytes,
        boardSize: _boardSize,
        kernel: _kernel,
      );
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => EditorPage(model: model, palette: demoPalette)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("转换失败: $e")));
      }
    } finally {
      if (mounted) {
        setState(() {
          _converting = false;
        });
      }
    }
  }

  Future<void> _openDrafts() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("网页版暂不支持本地草稿")));
      return;
    }
    final files = await DraftStore.list();
    if (!mounted) {
      return;
    }
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("暂无草稿")));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          children: [
            for (final f in files)
              ListTile(
                leading: const Icon(Icons.drafts_outlined),
                title: Text(f.path.split(Platform.pathSeparator).last),
                subtitle: Text(_fmtTime(f)),
                onTap: () async {
                  final model = await DraftStore.read(f);
                  if (!sheetContext.mounted) {
                    return;
                  }
                  Navigator.of(sheetContext).pop();
                  if (!mounted) {
                    return;
                  }
                  await Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => EditorPage(model: model, palette: demoPalette)),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(File f) {
    final name = f.path.split(Platform.pathSeparator).last;
    // draft_YYYYMMDD_HHMMSS.json -> YYYY-MM-DD HH:MM:SS
    if (name.startsWith("draft_") && name.length >= 24) {
      final d = name.substring(6, 14);
      final t = name.substring(15, 21);
      return "${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)} "
          "${t.substring(0, 2)}:${t.substring(2, 4)}:${t.substring(4, 6)}";
    }
    return "";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("拼豆图案工作室"), actions: [
        IconButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const RestorePage()),
          ),
          icon: const Icon(Icons.document_scanner),
          tooltip: "图纸还原",
        ),
        IconButton(onPressed: _openDrafts, icon: const Icon(Icons.folder_open), tooltip: "打开草稿"),
      ]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 预览区
          AspectRatio(
            aspectRatio: 1,
            child: _pickedBytes == null
                ? Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(child: Text("选择一张图片开始")),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(_pickedBytes!, fit: BoxFit.cover),
                  ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library),
                label: const Text("相册"),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.photo_camera),
                label: const Text("拍照"),
              ),
            ),
          ]),
          const SizedBox(height: 20),

          // 板尺寸
          const Text("板尺寸", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (final s in _boardSizes) ButtonSegment(value: s, label: Text("$s×$s")),
            ],
            selected: {_boardSize},
            onSelectionChanged: (sel) => setState(() => _boardSize = sel.first),
          ),
          const SizedBox(height: 8),
          Text("$_boardSize×$_boardSize = ${_boardSize * _boardSize} 颗", style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),

          // 抖动核选择
          const Text("抖动算法", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<DitherKernel>(
              segments: const [
                ButtonSegment(value: DitherKernel.none, label: Text("无")),
                ButtonSegment(value: DitherKernel.floydSteinberg, label: Text("FS")),
                ButtonSegment(value: DitherKernel.atkinson, label: Text("Atkinson")),
                ButtonSegment(value: DitherKernel.ordered, label: Text("有序")),
              ],
              selected: {_kernel},
              onSelectionChanged: (sel) => setState(() => _kernel = sel.first),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            switch (_kernel) {
              DitherKernel.none => "色块干净，渐变断层明显",
              DitherKernel.floydSteinberg => "误差扩散，渐变过渡自然",
              DitherKernel.atkinson => "扩散更强，整体更亮更均匀",
              DitherKernel.ordered => "网点风格，无误差累积",
            },
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),

          FilledButton.icon(
            onPressed: _pickedFile == null || _converting ? null : _convert,
            icon: _converting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_converting ? "转换中…" : "开始转换"),
          ),
        ],
      ),
    );
  }
}
