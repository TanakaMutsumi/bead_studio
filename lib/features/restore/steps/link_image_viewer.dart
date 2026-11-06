import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../core/app_snack_bar.dart';
import '../../../core/decode_image.dart';
import '../../../core/gallery_save.dart';
import '../../../core/zoom_controls.dart';

/// LOD 裁片 isolate 端：全分辨率图上取矩形 → JPEG q92（顶层函数供
/// compute 调用；img.Image 随消息拷入 isolate，124MB 级拷贝 ~0.1s 可接受）
Uint8List _cropJpg((img.Image, int, int, int, int) a) {
  final (im, x, y, w, h) = a;
  final crop = img.copyCrop(im, x: x, y: y, width: w, height: h);
  return Uint8List.fromList(img.encodeJpg(crop, quality: 92));
}

/// 全屏原图查看（小红书/抖音链接导入共用）：黑底，缩放与 app 其他图显
/// 同款——双指捏合 + 外置 ZoomControls 条（放大/缩小/还原）+ 双击以点击处
/// 为锚放大/回整图；右上角下载按钮存相册。
///
/// [loadOriginal] 返回原图字节（调用方负责缓存）；[width]/[height] 仅用于
/// 标题角标（未知传 0）。
class LinkImageViewerPage extends StatefulWidget {
  const LinkImageViewerPage({
    super.key,
    required this.title,
    required this.width,
    required this.height,
    required this.savePrefix,
    required this.loadOriginal,
  });

  final String title;
  final int width;
  final int height;
  final String savePrefix;
  final Future<Uint8List> Function() loadOriginal;

  @override
  State<LinkImageViewerPage> createState() => _LinkImageViewerPageState();
}

class _LinkImageViewerPageState extends State<LinkImageViewerPage> {
  Uint8List? _bytes;
  Uint8List? _display;
  int _dispW = 0;
  int _dispH = 0;
  Object? _error;
  var _saving = false;
  final _ctrl = TransformationController();

  ///< aspect-fit 画布盒尺寸速记（build 期间赋值）——ZoomControls 的
  ///< 锚点/平移夹限按它算（视口=画布盒：IV 缩到画布尺寸的同款几何）
  Size _canvasSize = Size.zero;

  ///< 画布盒在图区内的偏移（双击锚点 图区→画布 坐标换算用）
  Offset _canvasOrigin = Offset.zero;
  Offset _dblAnchor = Offset.zero;

  ///< 全分辨率解码图（LOD 裁片源；显示上限 4096 压不住原图时放大
  ///< 到地平线以上就按可见区域裁它叠显，清晰度推到原图本身）
  img.Image? _full;

  ///< 最大缩放倍率（build 期间按 原图地平线×2 夹 [8,16] 动态定：
  ///< 5364px 图 ~10×、6400px ~12×，小图维持 8——倍率随导入图大小走）
  double _maxZoom = kPhotoMaxZoom;

  ///< 当前 LOD 裁片字节与其覆盖的画布矩形（null = 未激活/已清除）
  Uint8List? _cropBytes;
  Rect? _cropCanvasRect;
  var _cropBusy = false;
  var _cropPending = false;

  ///< 设备像素比速记（build 期间赋值，LOD 阈值/倍率推导用）
  double _dpr = 1.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.loadOriginal();
      // 显示层重编码走全局 4096 上限（kDisplayMaxEdge，2026-11-05 起全
      // app 显示统一放宽）；保存/识别用的都是未限幅原始字节。decoded
      // 全分辨率图留住当 LOD 裁片源（放大超地平线后可见区裁片叠显）
      final (decoded, display) = await decodeForDisplay(bytes);
      if (!mounted) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _display = display;
        _full = decoded;
        _dispW = decoded.width;
        _dispH = decoded.height;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e);
      }
    }
  }

  Future<void> _save() async {
    if (_bytes == null || _saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      final name = await saveImageToGallery(_bytes!, namePrefix: widget.savePrefix);
      if (mounted) {
        AppSnackBar.show(context, '已保存到相册：$name');
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 双击：整图 ↔ 以双击处为锚放大 2.5×（放大态下双击回整图）
  void _onDoubleTap() {
    if (_ctrl.value.getMaxScaleOnAxis() > 1.01) {
      _ctrl.value = Matrix4.identity();
      _maybeCrop();
      return;
    }
    // 图区坐标 → 画布盒坐标（ZoomControls.zoomAt 的锚点/夹限按画布盒算）
    final anchor = Offset(
      (_dblAnchor.dx - _canvasOrigin.dx).clamp(0.0, _canvasSize.width),
      (_dblAnchor.dy - _canvasOrigin.dy).clamp(0.0, _canvasSize.height),
    );
    ZoomControls.zoomAt(
      controller: _ctrl,
      viewport: _canvasSize,
      content: _canvasSize,
      factor: 2.5,
      maxScale: _maxZoom,
      anchor: anchor,
    );
    _maybeCrop();
  }

  /// LOD 裁片：缩放过显示图地平线后，取可见区域对应的全分辨率矩形，
  /// isolate 裁片重编码叠显（叠在限幅显示图之上、按画布坐标对位）。
  /// 缩回阈值以下/平移仍在现有裁片覆盖内则不动。
  Future<void> _maybeCrop() async {
    final full = _full;
    if (full == null || _canvasSize == Size.zero || _display == null) {
      return;
    }
    if (_cropBusy) {
      _cropPending = true;
      return;
    }
    final dispLong = math
        .min(math.max(_dispW, _dispH), kDisplayMaxEdge)
        .toDouble();
    final physLong = _canvasSize.longestSide * _dpr;
    final rect = photoLodCropRect(
      m: _ctrl.value,
      canvas: _canvasSize,
      srcW: full.width,
      srcH: full.height,
      dispLongPx: dispLong,
      physLongPx: physLong,
    );
    if (rect == null) {
      if (_cropBytes != null) {
        setState(() {
          _cropBytes = null;
          _cropCanvasRect = null;
        });
      }
      return;
    }
    // 裁片覆盖的画布矩形（源矩形放回画布坐标）
    final canvasRect = Rect.fromLTRB(
      rect.left * _canvasSize.width / full.width,
      rect.top * _canvasSize.height / full.height,
      rect.right * _canvasSize.width / full.width,
      rect.bottom * _canvasSize.height / full.height,
    );
    final covered = _cropCanvasRect;
    if (_cropBytes != null &&
        covered != null &&
        covered.contains(canvasRect.topLeft) &&
        covered.contains(canvasRect.bottomRight)) {
      return; // 平移未超出已有裁片覆盖，无需重算
    }
    _cropBusy = true;
    try {
      final bytes = await compute(
        _cropJpg,
        (
          full,
          rect.left.round(),
          rect.top.round(),
          rect.width.round().clamp(1, full.width),
          rect.height.round().clamp(1, full.height),
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cropBytes = bytes;
        _cropCanvasRect = canvasRect;
      });
    } catch (_) {
      // 裁片失败保持限幅显示图，不影响交互
    } finally {
      _cropBusy = false;
    }
    if (_cropPending) {
      _cropPending = false;
      _maybeCrop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    final h = widget.height;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(
          w > 0 ? '${widget.title}  $w×$h' : widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            tooltip: '保存到相册',
            onPressed: _bytes == null || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.file_download_outlined),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Text(
                '加载原图失败：$_error',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            )
          : _display == null
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 12),
                      Text(
                        '正在下载原图…',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (ctx, c) {
                          // 整图 aspect-fit 进图区（与复核单格预览同款几何）
                          final s = math.min(
                            c.maxWidth / _dispW,
                            c.maxHeight / _dispH,
                          );
                          final cw = _dispW * s;
                          final ch = _dispH * s;
                          _canvasSize = Size(cw, ch);
                          _canvasOrigin = Offset(
                            (c.maxWidth - cw) / 2,
                            (c.maxHeight - ch) / 2,
                          );
                          _dpr = MediaQuery.devicePixelRatioOf(ctx);
                          // 最大倍率随原图大小走：原图地平线（原图像素/
                          // 屏幕物理像素）×2 夹 [8,16]（5364px ~10×、
                          // 6400px ~12×；LOD 裁片保证放大后依然清晰）
                          _maxZoom = (math.max(_dispW, _dispH) /
                                  (math.max(cw, ch) * _dpr) *
                                  2)
                              .clamp(kPhotoMaxZoom, 16.0)
                              .toDouble();
                          return GestureDetector(
                            onDoubleTapDown: (d) => _dblAnchor = d.localPosition,
                            onDoubleTap: _onDoubleTap,
                            child: Center(
                              child: InteractiveViewer(
                                transformationController: _ctrl,
                                maxScale: _maxZoom,
                                onInteractionEnd: (_) => _maybeCrop(),
                                child: SizedBox(
                                  width: cw,
                                  height: ch,
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Image.memory(
                                          _display!,
                                          fit: BoxFit.fill,
                                        ),
                                      ),
                                      // LOD 裁片：全分辨率可见区叠在限幅
                                      // 显示图上，按画布坐标精确对位
                                      if (_cropBytes != null)
                                        Positioned.fromRect(
                                          rect: _cropCanvasRect!,
                                          child: Image.memory(
                                            _cropBytes!,
                                            fit: BoxFit.fill,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    // 缩放按钮条（与还原页图区同款外置条）：手势缩放可发现性
                    // 差，屏幕上要有显式按钮；双击/捏合照常可用
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ZoomControls(
                              controller: _ctrl,
                              contentSize: () => _canvasSize,
                              viewportSize: () => _canvasSize,
                              maxScale: _maxZoom,
                              onChanged: _maybeCrop,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '双指缩放/拖动查看 · 双击 放大/回到整图',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
