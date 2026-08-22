import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/grid_detector.dart';
import '../../core/pattern_model.dart';
import '../../core/quantizer.dart';
import '../../data/demo_palette.dart';
import '../editor/editor_page.dart';
import '../editor/grid_painter.dart';

/// 页面阶段：选图 -> 裁剪对齐 -> 识别预览
enum _Stage { pick, align, preview }

/// 图纸还原页：导入图纸/成品照 -> 框选主体 -> 自动网格对齐 -> 逐格识别 -> 进编辑器
///
/// 复现原 App 蓝图还原链路的本地算法版（颜色采样量化，不依赖外部模型）
class RestorePage extends StatefulWidget {
  const RestorePage({super.key});

  @override
  State<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends State<RestorePage> {
  _Stage _stage = _Stage.pick;
  Uint8List? _bytes; ///< 原图字节
  img.Image? _image; ///< 解码后的原图
  Rect? _selDisplay; ///< 选区（显示坐标）

  GridDetectResult? _detect;
  late final TextEditingController _colsCtrl;
  late final TextEditingController _rowsCtrl;
  var _detecting = false;

  PatternModel? _model;
  var _recognizing = false;

  @override
  void initState() {
    super.initState();
    _colsCtrl = TextEditingController();
    _rowsCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _colsCtrl.dispose();
    _rowsCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 100);
    if (picked == null) {
      return;
    }
    final bytes = await picked.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("无法解码图片")));
      }
      return;
    }
    setState(() {
      _bytes = bytes;
      _image = decoded;
      _selDisplay = null;
      _detect = null;
      _model = null;
      _stage = _Stage.align;
    });
  }

  /// 自动检测网格（在选区内跑投影分析）
  void _autoDetect(Size displaySize) {
    final image = _image;
    if (image == null) {
      return;
    }
    final sel = _selDisplay;
    // 选区（图片坐标）
    final scaleX = image.width / displaySize.width;
    final scaleY = image.height / displaySize.height;
    int rx, ry, rw, rh;
    if (sel != null && sel.width > 8 && sel.height > 8) {
      rx = (sel.left * scaleX).clamp(0, image.width - 4).toInt();
      ry = (sel.top * scaleY).clamp(0, image.height - 4).toInt();
      rw = (sel.width * scaleX).clamp(4, image.width - rx).toInt();
      rh = (sel.height * scaleY).clamp(4, image.height - ry).toInt();
    } else {
      rx = 0;
      ry = 0;
      rw = image.width;
      rh = image.height;
    }

    setState(() => _detecting = true);
    // 投影分析较重，下一帧再算避免卡住选区动画
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final gray = <int>[];
      for (var y = ry; y < ry + rh; y++) {
        for (var x = rx; x < rx + rw; x++) {
          final p = image.getPixel(x, y);
          gray.add((p.r * 0.299 + p.g * 0.587 + p.b * 0.114).round());
        }
      }
      final result = detectGrid(gray, rw, rh);
      if (!mounted) {
        return;
      }
      setState(() {
        _detecting = false;
        _detect = result;
        if (result != null) {
          _colsCtrl.text = result.cols.toString();
          _rowsCtrl.text = result.rows.toString();
        }
      });
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("未检测到网格，请框选更规整的区域或手动填行列数")),
        );
      }
    });
  }

  /// 按当前行列数识别：每格中心 3×3 均值采样 -> Lab 最近调色板色
  void _recognize(Size displaySize) {
    final image = _image;
    if (image == null) {
      return;
    }
    final cols = int.tryParse(_colsCtrl.text) ?? 0;
    final rows = int.tryParse(_rowsCtrl.text) ?? 0;
    if (cols < 4 || rows < 4 || cols > 400 || rows > 400) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("行列数须在 4-400 之间")));
      return;
    }

    setState(() => _recognizing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 识别区域（图片坐标）：选区优先，否则全图
      final sel = _selDisplay;
      final scaleX = image.width / displaySize.width;
      final scaleY = image.height / displaySize.height;
      double rx = 0, ry = 0, rw = image.width.toDouble(), rh = image.height.toDouble();
      if (sel != null && sel.width > 8 && sel.height > 8) {
        rx = (sel.left * scaleX).clamp(0, image.width - 4);
        ry = (sel.top * scaleY).clamp(0, image.height - 4);
        rw = (sel.width * scaleX).clamp(4, image.width - rx);
        rh = (sel.height * scaleY).clamp(4, image.height - ry);
      }

      final quantizer = Quantizer(demoPalette);
      final grid = List<int>.filled(cols * rows, 0);
      final cellW = rw / cols;
      final cellH = rh / rows;
      // 自动检测过且行列未被手改：用检测的网格参数采样（对齐真实网格线，更准）
      final det = _detect;
      final useDetect = det != null && det.cols == cols && det.rows == rows;
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final double cx, cy, cw, ch;
          if (useDetect) {
            cx = rx + det.offsetX + c * det.pitchX;
            cy = ry + det.offsetY + r * det.pitchY;
            cw = det.pitchX;
            ch = det.pitchY;
          } else {
            cx = rx + (c + 0.5) * cellW;
            cy = ry + (r + 0.5) * cellH;
            cw = cellW;
            ch = cellH;
          }
          // 格子中心（避开边缘采 3×3 均值，抗网格线/珠子高光干扰）
          var sr = 0, sg = 0, sb = 0, n = 0;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              final px = (cx + dx * (cw / 6)).round().toInt();
              final py = (cy + dy * (ch / 6)).round().toInt();
              if (px < 0 || px >= image.width || py < 0 || py >= image.height) {
                continue;
              }
              final p = image.getPixel(px, py);
              sr += p.r.toInt();
              sg += p.g.toInt();
              sb += p.b.toInt();
              n++;
            }
          }
          grid[r * cols + c] = n == 0 ? 0 : quantizer.nearestIndex(sr ~/ n, sg ~/ n, sb ~/ n);
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _model = PatternModel(
          width: cols,
          height: rows,
          grid: grid,
          paletteIds: [for (final c in demoPalette.colors) c.id],
        );
        _recognizing = false;
        _stage = _Stage.preview;
      });
    });
  }

  void _openEditor() {
    final model = _model;
    if (model == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditorPage(model: model, palette: demoPalette)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (_stage) {
          _Stage.pick => "图纸还原 · 选图",
          _Stage.align => "图纸还原 · 裁剪对齐",
          _Stage.preview => "图纸还原 · 识别结果",
        }),
      ),
      body: switch (_stage) {
        _Stage.pick => _buildPick(),
        _Stage.align => _buildAlign(),
        _Stage.preview => _buildPreview(),
      },
    );
  }

  /// 阶段一：选图入口
  Widget _buildPick() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_on, size: 72, color: Colors.black26),
            const SizedBox(height: 16),
            const Text("导入拼豆图纸或成品照片，自动识别为可编辑图案", textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text("（尽量正拍、网格清晰，识别率更高）", style: TextStyle(fontSize: 12, color: Colors.black45)),
            const SizedBox(height: 32),
            FilledButton.tonalIcon(
              onPressed: () => _pickImage(ImageSource.gallery),
              icon: const Icon(Icons.photo_library),
              label: const Text("从相册选择图纸"),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => _pickImage(ImageSource.camera),
              icon: const Icon(Icons.photo_camera),
              label: const Text("拍照成品"),
            ),
          ],
        ),
      ),
    );
  }

  /// 阶段二：框选主体 + 网格对齐参数
  Widget _buildAlign() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 按原图宽高比铺满可用宽度
                final size = constraints.biggest;
                final displayW = size.width;
                final displayH = displayW * _image!.height / _image!.width;
                return SingleChildScrollView(
                  child: GestureDetector(
                    onPanDown: (d) => setState(() => _selDisplay = Rect.fromPoints(d.localPosition, d.localPosition)),
                    onPanUpdate: (d) => setState(() => _selDisplay = Rect.fromPoints(_selDisplay!.topLeft, d.localPosition)),
                    child: Stack(
                      children: [
                        Image.memory(_bytes!, width: displayW, height: displayH, fit: BoxFit.fill),
                        // 选区遮罩 + 边框
                        if (_selDisplay != null && _selDisplay!.width > 2)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _SelPainter(_selDisplay!),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _selDisplay != null && _selDisplay!.width > 8 ? "已框选主体区域（拖动重新框选）" : "在图上拖动框选要识别的区域",
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _colsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: "列数", border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text("×")),
                  Expanded(
                    child: TextField(
                      controller: _rowsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: "行数", border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _detecting ? null : () => _autoDetect(_displaySize(context)),
                    icon: _detecting
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_awesome, size: 18),
                    label: const Text("自动检测"),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _recognizing ? null : () => _recognize(_displaySize(context)),
                  icon: _recognizing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.document_scanner),
                  label: Text(_recognizing ? "识别中…" : "开始识别"),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 图片实际显示尺寸（与 _buildAlign 布局公式保持一致：可用宽 = 屏幕 - 两侧 12 padding）
  Size _displaySize(BuildContext context) {
    final displayW = MediaQuery.sizeOf(context).width - 24;
    return Size(displayW, displayW * _image!.height / _image!.width);
  }

  /// 阶段三：识别结果预览
  Widget _buildPreview() {
    final model = _model!;
    final usedColors = model.countByColor().length;
    final totalBeads = model.width * model.height;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: AspectRatio(
                aspectRatio: model.width / model.height,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: GridPainter(model: model, palette: demoPalette, selectedColorIndex: -1),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("识别为 ${model.width}×${model.height} · $usedColors 色 · 共 $totalBeads 格", style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              const Text("颜色不对可用编辑器换色/吸管修正", style: TextStyle(fontSize: 12, color: Colors.black45)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() => _stage = _Stage.align),
                      child: const Text("返回调整"),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _openEditor,
                      icon: const Icon(Icons.edit),
                      label: const Text("进编辑器"),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 选区绘制：外部半透明遮罩 + 蓝色边框
class _SelPainter extends CustomPainter {
  final Rect rect;

  _SelPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final mask = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    path.addPath(Path()..addRect(rect), Offset.zero);
    canvas.drawPath(Path.combine(PathOperation.difference, path, Path()), mask);
    canvas.drawRect(rect, border);
  }

  @override
  bool shouldRepaint(covariant _SelPainter oldDelegate) => oldDelegate.rect != rect;
}
