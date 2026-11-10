import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_build.dart';
import '../../core/app_snack_bar.dart';
import '../../core/decode_image.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/pixel_engine.dart';
import '../../core/quantizer.dart';
import '../editor/editor_page.dart';

/// 图片转换页（主页「图片转换」进入）：选图 -> 选色卡/板尺寸/抖动 -> 转换进编辑器
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  static const _boardSizes = [26, 29, 52, 78];

  XFile? _pickedFile;
  Uint8List? _pickedBytes;

  ///< 跨平台图片字节（web 上 XFile.path 是 blob URL 不能走 dart:io）
  Uint8List? _displayBytes;

  ///< 预览用重编码 JPEG（decodeForDisplay 产物，转换仍用原始字节）
  var _decoding = false;

  ///< 解码/重编码中（预览区转圈，避免"白屏不知发生什么"）
  var _boardSize = 52;
  var _style = ConvertStyle.blocks;
  var _converting = false;

  // 色卡（初始空占位，initState 异步换为用户选中的色卡）
  BeadPalette _palette = const BeadPalette([]);
  List<PaletteInfo> _palettes = const [];
  String _paletteId = "";

  @override
  void initState() {
    super.initState();
    _initPalette();
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 加载选中色卡 + 全部可选色卡
  Future<void> _initPalette() async {
    final selected = await PaletteRegistry.loadSelected();
    final all = await PaletteRegistry.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _palette = selected.palette;
      _paletteId = selected.id;
      _palettes = all;
    });
  }

  /// 切换色卡并持久化
  Future<void> _switchPalette(String id) async {
    if (id == _paletteId) {
      return;
    }
    await PaletteRegistry.saveSelectedId(id);
    final target = _palettes.where((p) => p.id == id).first;
    setState(() {
      _paletteId = id;
      _palette = target.palette;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    // 不传 imageQuality：任何非空值都会触发解码->重编码（quality 100 也逃不掉）
    final picked = await picker.pickImage(source: source);
    if (picked != null) {
      final bytes = await picked.readAsBytes();
      setState(() => _decoding = true);
      try {
        // 预览统一走重编码 JPEG + 长边限幅（decodeForDisplay），转换仍用原始字节
        final (_, display) = await decodeForDisplay(bytes);
        if (!mounted) {
          return;
        }
        setState(() {
          _pickedFile = picked;
          _pickedBytes = bytes;
          _displayBytes = display;
        });
      } catch (e) {
        if (mounted) {
          AppSnackBar.show(context, "无法解码图片: $e");
        }
      } finally {
        if (mounted) {
          setState(() => _decoding = false);
        }
      }
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
      final model = await PixelEngine(_palette)
          .convert(bytes: bytes, boardSize: _boardSize, style: _style);
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => EditorPage(model: model, palette: _palette),
        ),
      );
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, "转换失败: $e");
      }
    } finally {
      if (mounted) {
        setState(() {
          _converting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("图片转换")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 预览区
          AspectRatio(
            aspectRatio: 1,
            child: _pickedBytes == null || _decoding
                ? Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      border: Border.all(color: Colors.black12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      // 解码转圈遮罩：与空白占位同框，避免"白屏不知发生什么"
                      child: _decoding
                          ? const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 10),
                                Text("正在解码图片…", style: TextStyle(fontSize: 13)),
                              ],
                            )
                          : const Text("选择一张图片开始"),
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    // 喂重编码 JPEG（decodeForDisplay 产物），转换仍用原始字节
                    child: Image.memory(
                      _displayBytes!,
                      fit: BoxFit.cover,
                      // 解码失败必须可见（红底提示），不能静默白屏让用户"不知发生了什么"
                      errorBuilder: (ctx, error, stack) {
                        return ColoredBox(
                          color: Colors.redAccent,
                          child: Center(
                            child: Text(
                              "显示解码失败: $error",
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
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
            ],
          ),
          const SizedBox(height: 20),

          // 色卡选择
          if (_palettes.length > 1) ...[
            const Text("色卡", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                for (final p in _palettes)
                  ButtonSegment(value: p.id, label: Text(p.label)),
              ],
              selected: {_paletteId},
              onSelectionChanged: (sel) => _switchPalette(sel.first),
            ),
            const SizedBox(height: 4),
            Text(
              "色号与实物拼豆对齐（如 MARD A1~M15）；切换后新作品用新色卡，旧作品按原色号打开",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
          ],

          // 板尺寸
          const Text("板尺寸", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (final s in _boardSizes)
                ButtonSegment(value: s, label: Text("$s×$s")),
            ],
            selected: {_boardSize},
            onSelectionChanged: (sel) => setState(() => _boardSize = sel.first),
          ),
          const SizedBox(height: 8),
          Text(
            "$_boardSize×$_boardSize = ${_boardSize * _boardSize} 颗",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),

          // 转换风格选择
          const Text("转换风格", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<ConvertStyle>(
            segments: const [
              ButtonSegment(value: ConvertStyle.blocks, label: Text("色块")),
              ButtonSegment(value: ConvertStyle.detail, label: Text("细节")),
            ],
            selected: {_style},
            onSelectionChanged: (sel) => setState(() => _style = sel.first),
          ),
          const SizedBox(height: 4),
          Text(switch (_style) {
            ConvertStyle.blocks => "近似色自动合并成整块，消除孤立色点，照片/插画首选",
            ConvertStyle.detail => "保留更多色彩层次与微小细节，适合线稿/像素画",
          }, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),

          FilledButton.icon(
            onPressed: _pickedFile == null || _converting ? null : _convert,
            icon: _converting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_converting ? "转换中…" : "开始转换"),
          ),
          const SizedBox(height: 12),
          // 构建标识：现场确认模拟器/设备上跑的是哪次构建
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              "构建 $appBuildLabel",
              style: const TextStyle(fontSize: 10, color: Colors.black26),
            ),
          ),
        ],
      ),
    );
  }
}
