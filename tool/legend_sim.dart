// 图例检测离线模拟器：与 app 同一解码路径 + 同一 detectLegend 实现
//
// 用法（仓库根目录）：
//   dart run tool/legend_sim.dart .test/wx1.jpg .test/wx2.jpg ...
//   dart run tool/legend_sim.dart --dump .test/wx1.jpg   # 另存 Dart 解码像素 PNG
//   dart run tool/legend_sim.dart --native .test/wx1.jpg # 跳过 1440 宽归一化
//
// 解码口径复刻 lib/core/decode_image.dart decodeImageRobust 第一步：
// img.decodeImage（纯 Dart image 包）。返回 null/抛异常时 app 会回退
// Skia(libjpeg-turbo)——CLI 里跑不了 dart:ui，此时提示改用 PIL 复刻
// （wx_replica4.py，PIL 即 libjpeg-turbo 口径）。
//
// 输出 RESULT 行与 .test/wx_replica4.py 同格式（annotate.py 可直接解析）。
import 'dart:io';

import 'package:image/image.dart' as img;

import '../lib/core/board_detect.dart';
import '../lib/core/legend_detect.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/legend_sim.dart [--dump|--native] <img>...');
    exitCode = 2;
    return;
  }
  final dump = args.contains('--dump');
  final native = args.contains('--native');
  final paths =
      args.where((a) => a != '--dump' && a != '--native').toList();
  for (final arg in paths) {
    final bytes = File(arg).readAsBytesSync();
    // --- 与 app 相同的解码尝试 ---
    img.Image? image;
    Object? err;
    try {
      image = img.decodeImage(bytes);
    } catch (e) {
      err = e;
    }
    if (image == null) {
      print('$arg: dart-decode FAILED ($err)');
      print('  -> device falls back to Skia(libjpeg-turbo); '
          'use .test/wx_replica6.py (PIL) for that path');
      continue;
    }
    print('$arg: dart-decode OK ${image.width}x${image.height}');
    if (dump) {
      final out = arg.replaceAll(RegExp(r'[\\/]', multiLine: false), '_');
      final f = File('dart_dump_$out.png');
      f.writeAsBytesSync(img.encodePng(image));
      print('  dumped dart pixels -> ${f.path}');
    }
    // --- 与 app 相同的检测实现（v9：默认 1440 宽归一化，--native 跳过） ---
    final r = native ? detectLegend(image) : detectLegendCanonical(image);
    if (r == null) {
      print('RESULT: null');
      continue;
    }
    for (final b in r.bands) {
      final tag = b.reject == null
          ? 'score=${b.score.toStringAsFixed(1)} nSum8=${b.nSum} sat=${b.satColors}'
          : 'rejected: ${b.reject}';
      print('  band [${b.top}, ${b.bottom}] $tag');
    }
    for (final n in r.notes) {
      print('  $n');
    }
    print('RESULT: (${r.left}, ${r.top}, ${r.right}, ${r.bottom}) '
        'score=${r.score.toStringAsFixed(1)}');
    final rt = detectRulerTop(image, r.top);
    print('  ruler top: $rt');
  }
}
