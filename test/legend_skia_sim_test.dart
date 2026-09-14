// Skia 解码口径的图例检测模拟（flutter_test 在 flutter_tester 引擎里跑，
// ui.instantiateImageCodec 可用 = 复刻 app decodeImageRobust 的回退路径）。
//
// 用法：flutter test test/legend_skia_sim_test.dart
// 输出与 tool/legend_sim.dart / wx_replica4.py 同格式 RESULT 行，
// 并 dump Skia 解码像素到 .test/skia_dump_<name>.png 供 PIL 逐像素对比。
//
// 背景（2026-09-14 定位）：wx2(39_242) 纯 Dart 解码抛
// ImageException: Unknown JPEG marker d3 → 真机必走 Skia 回退；
// PIL 与纯 Dart 两口径都无法代表真机像素，必须三口径都验证。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:bead_studio/core/board_detect.dart';
import 'package:bead_studio/core/legend_detect.dart';

/// 复刻 decode_image.dart _fromRawRgba（私有无法 import，逐行同实现）
img.Image _fromRawRgba(ByteData rgba, int width, int height) {
  final out = img.Image(width: width, height: height);
  final data = rgba.buffer.asUint8List();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      out.setPixelRgba(x, y, data[i], data[i + 1], data[i + 2], data[i + 3]);
    }
  }
  return out;
}

Future<img.Image> _decodeSkia(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final rgba = await frame.image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  if (rgba == null) {
    throw StateError('Skia decode returned null bytes');
  }
  return _fromRawRgba(rgba, frame.image.width, frame.image.height);
}

void _report(String tag, img.Image image) {
  final r = detectLegendCanonical(image);
  if (r == null) {
    print('$tag RESULT: null');
    return;
  }
  for (final b in r.bands) {
    final s = b.reject == null
        ? 'score=${b.score.toStringAsFixed(1)} nSum8=${b.nSum} sat=${b.satColors}'
        : 'rejected: ${b.reject}';
    print('$tag   band [${b.top}, ${b.bottom}] $s');
  }
  for (final n in r.notes) {
    print('$tag   note: $n');
  }
  print('$tag RESULT: (${r.left}, ${r.top}, ${r.right}, ${r.bottom}) '
      'score=${r.score.toStringAsFixed(1)}');
  print('$tag ruler top: ${detectRulerTop(image, r.top)}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const files = [
    '.test/test_pic5.png',
    '.test/wx1.jpg',
    '.test/wx2.jpg',
    '.test/wx3.jpg',
    '.test/wx4.jpg',
    '.test/wx5.jpg',
    '.test/wx6.jpg',
    '.test/u1.jpg',
    '.test/u2.jpg',
    '.test/u3.jpg',
    '.test/new1.jpg',
  ];
  test('skia-path legend detection over fleet', () async {
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      // 先看纯 Dart 是否失败（失败=设备走 Skia，即本测试覆盖的路径）
      var dartFailed = false;
      try {
        dartFailed = img.decodeImage(bytes) == null;
      } catch (_) {
        dartFailed = true;
      }
      final skia = await _decodeSkia(bytes);
      final name = f.split('/').last;
      print('== $name ${skia.width}x${skia.height} '
          '(pure-dart decode ${dartFailed ? "FAILED -> device uses THIS skia path" : "ok"})');
      _report('skia:', skia);
      final dump =
          File('.test/skia_dump_${name.replaceAll(RegExp(r'\.[^.]+$'), '')}.png');
      dump.writeAsBytesSync(img.encodePng(skia));
      print('   dumped -> ${dump.path}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
