import 'dart:io' show Platform;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    show InputImage, TextRecognizer, TextRecognitionScript;
import 'package:image/image.dart' as img;

/// OCR 元素（展平）：文本 + 原图坐标框。原生通道与插件回退共用出参
class OcrTextElem {
  final String text;
  final Rect rect;

  ///< dart:ui Rect（与插件 boundingBox 同坐标口径）
  const OcrTextElem(this.text, this.rect);
}

const _ch = MethodChannel('bead_native_ocr');

/// 原生通道可用性：首次 MissingPluginException 后置 false（web/桌面/旧宿主）
bool _nativeOk = true;

/// RGBA 内存图 -> 展平元素表。Android 先走自建后台线程通道（见
/// MainActivity.kt 头注释：插件路径在平台线程=UI 线程上构位图+推理，每次
/// processImage 主线程 100%）；通道不可用返回 null，调用方用
/// [ocrRgbaPlugin] 回退（保功能，会冻结）。
Future<List<OcrTextElem>?> ocrRgba(img.Image v) async {
  if (!_nativeOk || kIsWeb || !Platform.isAndroid) {
    return null;
  }
  try {
    final res = await _ch.invokeMethod<List<dynamic>>('processRgba', {
      'bytes': v.getBytes(order: img.ChannelOrder.rgba),
      'width': v.width,
      'height': v.height,
    });
    if (res == null) {
      return null;
    }
    return [
      for (final e in res.cast<Map<dynamic, dynamic>>())
        OcrTextElem(
          e['t'] as String,
          Rect.fromLTRB(
            (e['l'] as num).toDouble(),
            (e['t2'] as num).toDouble(),
            (e['r'] as num).toDouble(),
            (e['b'] as num).toDouble(),
          ),
        ),
    ];
  } on MissingPluginException {
    _nativeOk = false; // 本进程内不再尝试，后续直接走插件回退
    return null;
  } on PlatformException {
    return null; // 原生侧 OCR 失败：交调用方回退插件路径
  }
}

/// RGBA 临时文件路径版（大段字节不进主 isolate，compute 出参零大对象）。
/// 文件由 isolate 写出，本函数只传路径；坐标口径同 [ocrRgba]。
Future<List<OcrTextElem>?> ocrRgbaFile(
  String path,
  int w,
  int h,
) async {
  if (!_nativeOk || kIsWeb || !Platform.isAndroid) {
    return null;
  }
  try {
    final res = await _ch.invokeMethod<List<dynamic>>('processRgbaFile', {
      'path': path,
      'width': w,
      'height': h,
    });
    if (res != null) {
      return [
        for (final e in res.cast<Map<dynamic, dynamic>>())
          OcrTextElem(
            e['t'] as String,
            Rect.fromLTRB(
              (e['l'] as num).toDouble(),
              (e['t2'] as num).toDouble(),
              (e['r'] as num).toDouble(),
              (e['b'] as num).toDouble(),
            ),
          ),
      ];
    }
    return null;
  } on MissingPluginException {
    _nativeOk = false;
    return null;
  } on PlatformException {
    return null; // 原生侧 OCR 失败：交调用方回退插件路径
  }
}

/// 磁盘图片文件 -> 展平元素表（解码在原生后台线程）。复核单格等
/// 「isolate 已产出 PNG 落盘」路径用；坐标口径同 [ocrRgba]。
Future<List<OcrTextElem>?> ocrImageFile(String path) async {
  if (!_nativeOk || kIsWeb || !Platform.isAndroid) {
    return null;
  }
  try {
    final res = await _ch.invokeMethod<List<dynamic>>('processImageFile', {
      'path': path,
    });
    if (res == null) {
      return null;
    }
    return [
      for (final e in res.cast<Map<dynamic, dynamic>>())
        OcrTextElem(
          e['t'] as String,
          Rect.fromLTRB(
            (e['l'] as num).toDouble(),
            (e['t2'] as num).toDouble(),
            (e['r'] as num).toDouble(),
            (e['b'] as num).toDouble(),
          ),
        ),
    ];
  } on MissingPluginException {
    _nativeOk = false;
    return null;
  } on PlatformException {
    return null; // 原生侧解码/OCR 失败：交调用方回退插件路径
  }
}

/// 插件回退路径（通道不可用时的保底，跑平台线程会冻结 UI）：与
/// [ocrRgba] 同出参
Future<List<OcrTextElem>> ocrRgbaPlugin(
  TextRecognizer recognizer,
  img.Image v,
) async {
  final recognized = await recognizer.processImage(
    InputImage.fromBitmap(
      bitmap: v.getBytes(order: img.ChannelOrder.rgba),
      width: v.width,
      height: v.height,
    ),
  );
  return [
    for (final block in recognized.blocks)
      for (final line in block.lines)
        for (final element in line.elements)
          OcrTextElem(
            element.text,
            element.boundingBox,
          ),
  ];
}

/// 文件版插件回退（原 fromFilePath 路径保真）
Future<List<OcrTextElem>> ocrFilePlugin(
  TextRecognizer recognizer,
  String path,
) async {
  final recognized = await recognizer.processImage(
    InputImage.fromFilePath(path),
  );
  return [
    for (final block in recognized.blocks)
      for (final line in block.lines)
        for (final element in line.elements)
          OcrTextElem(
            element.text,
            element.boundingBox,
          ),
  ];
}

/// 用完识别器后释放（原生通道版懒建单例，close 后下次调用自动重建）
Future<void> ocrClose() async {
  if (!_nativeOk || kIsWeb || !Platform.isAndroid) {
    return;
  }
  try {
    await _ch.invokeMethod<void>('close');
  } on MissingPluginException {
    _nativeOk = false;
  }
}

/// 兼容旧签名的插件识别器构造（回退路径用）
TextRecognizer newPluginRecognizer() =>
    TextRecognizer(script: TextRecognitionScript.latin);
