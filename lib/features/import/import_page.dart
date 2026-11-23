import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_build.dart';
import '../../core/app_snack_bar.dart';
import '../../core/decode_image.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/responsive.dart';
import '../../core/pixel_engine.dart';
import '../../core/quantizer.dart';
import '../editor/editor_page.dart';

/// 图片转换页（主页「图片转换」进入）：选图 -> 选色卡/格子数/风格 -> 转换进编辑器
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  static const _presets = [26, 29, 52, 78];

  ///< 预设档（正方形）；自定义档用哨兵 0（同板设置 combobox 惯例）
  static const _customPreset = 0;

  XFile? _pickedFile;
  Uint8List? _pickedBytes;

  ///< 跨平台图片字节（web 上 XFile.path 是 blob URL 不能走 dart:io）
  Uint8List? _displayBytes;

  ///< 预览用重编码 JPEG（decodeForDisplay 产物，转换仍用原始字节）
  var _decoding = false;

  ///< 解码/重编码中（预览区转圈，避免"白屏不知发生什么"）
  var _gridW = 52, _gridH = 52;

  ///< 目标格子数（宽×高，自定义无上限，可非正方形）
  var _srcW = 0, _srcH = 0;

  ///< 源图尺寸（自定义格子数「按图片比例算高」用）
  var _style = ConvertStyle.blocks;
  var _converting = false;

  ///< 当前选中的档位值：正方形命中预设取边长，否则自定义哨兵
  int get _presetValue =>
      _gridW == _gridH && _presets.contains(_gridW) ? _gridW : _customPreset;

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
        final (decoded, display) = await decodeForDisplay(bytes);
        if (!mounted) {
          return;
        }
        setState(() {
          _pickedFile = picked;
          _pickedBytes = bytes;
          _displayBytes = display;
          _srcW = decoded.width;
          _srcH = decoded.height;
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
      final model = await PixelEngine(_palette).convert(
        bytes: bytes,
        width: _gridW,
        height: _gridH,
        style: _style,
      );
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

  /// 自定义格子数对话框：宽/高自由输入（≥1 无上限），
  /// 已选图时提供「按图片比例算高」（高 = 宽 × 源图高宽比）
  Future<void> _pickCustomGrid() async {
    final wCtrl = TextEditingController(text: _gridW.toString());
    final hCtrl = TextEditingController(text: _gridH.toString());
    final res = await showDialog<(int, int)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text("自定义格子数"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: wCtrl,
                      decoration: const InputDecoration(
                        labelText: "宽（格）",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setDialog(() {}),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text("×"),
                  ),
                  Expanded(
                    child: TextField(
                      controller: hCtrl,
                      decoration: const InputDecoration(
                        labelText: "高（格）",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setDialog(() {}),
                    ),
                  ),
                ],
              ),
              if (_srcW > 0 && _srcH > 0) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      final w = int.tryParse(wCtrl.text) ?? 0;
                      if (w < 1) return;
                      hCtrl.text = math.max(
                        1,
                        (w * _srcH / _srcW).round(),
                      ).toString();
                      setDialog(() {});
                    },
                    icon: const Icon(Icons.aspect_ratio, size: 18),
                    label: const Text("高按图片比例算"),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                _customHint(wCtrl.text, hCtrl.text),
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("取消"),
            ),
            FilledButton(
              onPressed: () {
                final w = int.tryParse(wCtrl.text) ?? 0;
                final h = int.tryParse(hCtrl.text) ?? 0;
                if (w < 1 || h < 1) {
                  AppSnackBar.show(ctx, "宽和高都要 ≥1");
                  return;
                }
                Navigator.of(ctx).pop((w, h));
              },
              child: const Text("确定"),
            ),
          ],
        ),
      ),
    );
    // 注：不手动 dispose 控制器——showDialog 的 future 在 pop() 时即完成，
    // 对话框出场动画（~150ms）期间 TextField 仍在树上，提前
    // dispose 会引发 wrong build scope 崩帧；路由销毁后无引用自然可回收
    if (res != null) {
      setState(() {
        _gridW = res.$1;
        _gridH = res.$2;
      });
    }
  }

  /// 对话框底部的颗数/耗时提示
  String _customHint(String wText, String hText) {
    final w = int.tryParse(wText) ?? 0;
    final h = int.tryParse(hText) ?? 0;
    if (w < 1 || h < 1) {
      return "宽和高都要 ≥1";
    }
    final n = w * h;
    final heavy = w >= 300 || h >= 300 || n >= 100000;
    return "$w×$h = $n 颗${heavy ? " · 格子很多，转换耗时较长" : ""}";
  }

  /// 格子数信息行：“W×H = N 颗”，超大格附耗时提示（不硬限上限）
  String _gridInfoLine() {
    final n = _gridW * _gridH;
    final heavy = _gridW >= 300 || _gridH >= 300 || n >= 100000;
    return "$_gridW×$_gridH = $n 颗${heavy ? " · 格子很多，转换耗时较长" : ""}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("图片转换")),
      // 平板/宽屏（放得下右侧面板的宽度，见 fitsSidePanel）：预览居左、选图与参数居右
      // 分两栏；手机竖屏与放不下面板的窄窗口走原单列滚动布局不变
      body: fitsSidePanel(MediaQuery.sizeOf(context).width)
          ? _buildWide(context)
          : _buildCompact(context),
    );
  }

  /// 手机竖屏：单列滚动（原布局，组件树逐节点不变）
  Widget _buildCompact(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildPreview(context),
        const SizedBox(height: 12),
        _buildSourceButtons(),
        const SizedBox(height: 20),
        ..._buildSettings(context),
      ],
    );
  }

  /// 平板 / 宽屏：预览区吃掉左侧全部空间（正方形，宽高同时受限居中），
  /// 选图按钮与全部参数收进右侧面板——单列铺满时预览方块会撑到整屏宽
  /// （横屏 ~1250dp）、比视口还高，参数全被挤到折叠线以下。
  /// 面板宽度固定 = kSidePanelWidth，不随窗口收窄（里面的分段按钮是按手机可用宽度排的，
  /// 收到 ~270dp 会横向溢出）；窗口窄到放不下面板（见 fitsSidePanel）就保持单列。
  /// 内容偏多或窗口偏矮时面板自身滚动，不挤预览
  Widget _buildWide(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: _buildPreview(context)),
          ),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: kSidePanelWidth,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSourceButtons(),
                const SizedBox(height: 20),
                ..._buildSettings(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 预览区（正方形；未选图时为占位框）
  Widget _buildPreview(BuildContext context) {
    return AspectRatio(
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
    );
  }

  /// 选图入口：相册 / 拍照
  Widget _buildSourceButtons() {
    return Row(
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
    );
  }

  /// 参数区：色卡 / 格子数 / 转换风格 / 开始转换（紧凑、宽屏两套布局共用）
  List<Widget> _buildSettings(BuildContext context) {
    return [
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

      // 格子数（预设正方形 + 自定义无上限宽×高）
      const Text("格子数", style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        segments: [
          for (final s in _presets)
            ButtonSegment(value: s, label: Text("$s×$s")),
          const ButtonSegment(value: _customPreset, label: Text("自定义")),
        ],
        selected: {_presetValue},
        onSelectionChanged: (sel) {
          final v = sel.first;
          if (v == _customPreset) {
            _pickCustomGrid();
          } else {
            setState(() {
              _gridW = v;
              _gridH = v;
            });
          }
        },
      ),
      const SizedBox(height: 8),
      Text(_gridInfoLine(), style: Theme.of(context).textTheme.bodySmall),
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
    ];
  }
}
