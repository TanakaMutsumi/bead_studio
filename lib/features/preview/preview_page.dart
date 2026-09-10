/// 预览页：成品片（2D 圆豆）/ 熨烫效果 / 3D 旋转 三种视图 + 亮度调节 + 导出 PNG
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_snack_bar.dart';
import '../../core/file_saver.dart';
import '../../core/iron_image.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';
import 'preview_painters.dart';

/// 预览模式
enum _PreviewMode { flat, ironed, scene }

class PreviewPage extends StatefulWidget {
  final PatternModel model;
  final BeadPalette palette;

  const PreviewPage({super.key, required this.model, required this.palette});

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage>
    with SingleTickerProviderStateMixin {
  var _mode = _PreviewMode.flat;
  var _brightness = 1.0;

  // 3D 场景状态
  var _yaw = 0.0;
  var _pitch = 0.0;
  var _zoom = 1.0;
  var _ironed3d = false;
  var _autoRotate = false;
  AnimationController? _rotator;
  var _scaleStartZoom = 1.0;

  ///< 双指缩放起始值（onScaleStart 记录）

  // 熨烫图（合成一次缓存）
  Uint8List? _ironedPng;
  bool _ironBuilding = false;

  final _boundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _rotator = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..addListener(() => setState(() => _yaw += 0.35 * 1 / 60));
  }

  @override
  void dispose() {
    _rotator?.dispose();
    super.dispose();
  }

  /// 切换模式：熨烫图按需合成（只算一次）
  void _switchMode(_PreviewMode mode) {
    setState(() => _mode = mode);
    if (mode == _PreviewMode.ironed && _ironedPng == null && !_ironBuilding) {
      _buildIronedImage();
    }
  }

  /// 后台合成熨烫图（大图耗时，异步 + loading 提示）
  Future<void> _buildIronedImage() async {
    setState(() => _ironBuilding = true);
    final cell = IronSimulator.cellPixelsFor(widget.model.width);
    final png = await compute(
      _ironJob,
      _IronJobArg(widget.model, widget.palette, cell),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _ironedPng = png;
      _ironBuilding = false;
    });
  }

  void _toggleAutoRotate() {
    setState(() {
      _autoRotate = !_autoRotate;
      if (_autoRotate) {
        _rotator?.repeat();
      } else {
        _rotator?.stop();
      }
    });
  }

  /// 亮度色矩阵（对任意模式实时生效，无需重建图像）
  ColorFilter get _brightnessFilter => ColorFilter.matrix([
        _brightness, 0, 0, 0, 0, //
        0, _brightness, 0, 0, 0,
        0, 0, _brightness, 0, 0,
        0, 0, 0, 1, 0,
      ]);

  /// 导出当前预览（RepaintBoundary 截图，所见即所得）
  Future<void> _exportCurrent() async {
    final boundary = _boundaryKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) {
      return;
    }
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    final name =
        "preview_${_mode.name}_${DateTime.now().millisecondsSinceEpoch}.png";
    if (kIsWeb) {
      await downloadBytes(bytes, name);
      if (mounted) {
        AppSnackBar.show(context, "已触发浏览器下载");
      }
      return;
    }
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory("${root.path}${Platform.pathSeparator}bead_exports")
      ..createSync(recursive: true);
    final file = File("${dir.path}${Platform.pathSeparator}$name");
    await file.writeAsBytes(bytes);
    if (mounted) {
      AppSnackBar.show(context, "已导出：${file.path}");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("预览 ${widget.model.width}×${widget.model.height}"),
        actions: [
          if (_mode == _PreviewMode.scene)
            IconButton(
              onPressed: _toggleAutoRotate,
              icon: Icon(_autoRotate ? Icons.pause_circle : Icons.play_circle),
              tooltip: _autoRotate ? "停止旋转" : "自动旋转",
            ),
          if (_mode == _PreviewMode.scene)
            IconButton(
              onPressed: () => setState(() {
                _ironed3d = !_ironed3d;
              }),
              icon: Icon(
                _ironed3d
                    ? Icons.local_fire_department
                    : Icons.radio_button_checked,
              ),
              tooltip: _ironed3d ? "圆豆形态" : "熨烫形态",
            ),
          IconButton(
            onPressed: _exportCurrent,
            icon: const Icon(Icons.download),
            tooltip: "导出当前预览",
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<_PreviewMode>(
              segments: const [
                ButtonSegment(
                  value: _PreviewMode.flat,
                  label: Text("成品片"),
                  icon: Icon(Icons.grid_on),
                ),
                ButtonSegment(
                  value: _PreviewMode.ironed,
                  label: Text("熨烫效果"),
                  icon: Icon(Icons.local_fire_department_outlined),
                ),
                ButtonSegment(
                  value: _PreviewMode.scene,
                  label: Text("3D 预览"),
                  icon: Icon(Icons.view_in_ar_outlined),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (sel) => _switchMode(sel.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.brightness_6, size: 18),
                Expanded(
                  child: Slider(
                    value: _brightness,
                    min: 0.6,
                    max: 1.4,
                    onChanged: (v) => setState(() => _brightness = v),
                  ),
                ),
                Text(_brightness.toStringAsFixed(2)),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return RepaintBoundary(
      key: _boundaryKey,
      child: ColorFiltered(
        colorFilter: _brightnessFilter,
        child: switch (_mode) {
          _PreviewMode.flat => CustomPaint(
              painter: BeadFlatPainter(
                model: widget.model,
                palette: widget.palette,
              ),
              size: Size.infinite,
            ),
          _PreviewMode.ironed => _buildIroned(),
          _PreviewMode.scene => _buildScene(),
        },
      ),
    );
  }

  /// 熨烫效果：合成中显示进度，完成后显示成片
  Widget _buildIroned() {
    if (_ironBuilding) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text("正在合成熨烫效果…"),
          ],
        ),
      );
    }
    final png = _ironedPng;
    if (png == null) {
      return const Center(child: Text("尚未生成"));
    }
    return Image.memory(png, fit: BoxFit.contain);
  }

  /// 3D 场景：单指拖拽旋转 / 双指捏合缩放（统一走 scale 回调，避免手势竞争）
  Widget _buildScene() {
    return GestureDetector(
      onScaleStart: (details) {
        if (_autoRotate && details.pointerCount == 1) {
          _toggleAutoRotate();
        }
        _scaleStartZoom = _zoom;
      },
      onScaleUpdate: (details) {
        setState(() {
          if (details.pointerCount >= 2) {
            _zoom = (_scaleStartZoom * details.scale).clamp(0.45, 3.5);
          } else {
            _yaw += details.focalPointDelta.dx * 0.008;
            _pitch = (_pitch + details.focalPointDelta.dy * 0.007).clamp(
              -1.35,
              1.35,
            );
          }
        });
      },
      child: CustomPaint(
        painter: BeadScenePainter(
          model: widget.model,
          palette: widget.palette,
          yaw: _yaw,
          pitch: _pitch,
          zoom: _zoom,
          brightness: 1, // 亮度走外层 ColorFiltered，避免双重缩放
          ironed: _ironed3d,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// compute 隔离任务的参数（model/palette 必须可序列化传递）
class _IronJobArg {
  final PatternModel model;
  final BeadPalette palette;
  final int cellPixels;
  const _IronJobArg(this.model, this.palette, this.cellPixels);
}

Uint8List _ironJob(_IronJobArg arg) {
  final image = IronSimulator.render(
    arg.model,
    arg.palette,
    cellPixels: arg.cellPixels,
  );
  return IronSimulator.encode(image);
}
