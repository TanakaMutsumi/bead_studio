/// 像素引擎：图片 -> 拼豆网格的完整转换管线
///
/// 流程：解码 -> 中心裁剪到目标宽高比 -> 主色感知降采样 -> 量化（CIEDE2000）
///
/// 重活（裁剪/降采样/量化/去孤立点）全部入 compute isolate——自定义格子数
/// 无上限（400×400 = 16 万格也不冻 UI）；web 上 compute 退化为同线程直跑，
/// 行为不变。解码留在主 isolate（Skia 引擎依赖，decodeImageRobust 自身已
/// 按段入 isolate）。
///
/// 降采样为何不用盒式均值（v0.2.x 旧口径）：均值把边缘两侧的颜色混成
/// 中间色（红蓝边缘出一圈紫灰 fringe、无对应豆色）；主色感知采样取格内
/// 直方图多数 bin 的均值，边缘格整格落向占多数的一侧，饱和度保住。
/// 方案出处：Pyxelate（Sobel 边缘感知降采样）、Stack Overflow 降采样
/// 主色讨论——详见 docs/image_convert_notes.md。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'decode_image.dart';
import 'palette.dart';
import 'pattern_model.dart';
import 'quantizer.dart';

/// 源图裁剪区域（像素坐标）——image 4.x 无 Rect 公共类，自定义轻量版
class SourceRect {
  final int x, y, width, height;
  const SourceRect(this.x, this.y, this.width, this.height);
}

class PixelEngine {
  final BeadPalette palette;

  PixelEngine(this.palette);

  /// 图片字节 -> 拼豆图案
  ///
  /// [width]/[height] 目标格数（各 ≥1，无上限；耗时随格数平方增长，
  /// 超大格建议 UI 层提示）
  /// [style] 转换风格（blocks = 色块统一，detail = 保留细节）
  /// [sourceRect] 可选裁剪区域（像素坐标，null = 中心裁剪到目标宽高比）
  /// [metric] 像素->调色板匹配度量（默认 CIEDE2000）
  ///
  /// 解码走 decodeImageRobust（Skia 优先 + image 包回退，像素口径=libjpeg-turbo）
  Future<PatternModel> convert({
    required Uint8List bytes,
    required int width,
    required int height,
    ConvertStyle style = ConvertStyle.blocks,
    ConvertMetric metric = ConvertMetric.ciede2000,
    SourceRect? sourceRect,
  }) async {
    if (width < 1 || height < 1) {
      throw ArgumentError("格子数必须 ≥1");
    }

    final decoded = await decodeImageRobust(bytes);
    final rect = sourceRect ?? centerCropAspect(decoded, width, height);

    final grid = await compute(
      convertGrid,
      ConvertGridArgs(
        image: decoded,
        rect: rect,
        width: width,
        height: height,
        style: style,
        metric: metric,
        palette: palette,
      ),
    );

    return PatternModel(
      width: width,
      height: height,
      grid: grid,
      paletteIds: [for (final c in palette.colors) c.id],
    );
  }

  /// 中心裁剪到目标宽高比（object-fit: cover 语义）
  ///
  /// 正方形目标是旧「中心最大正方形」行为的推广；宽高比已一致时取整图
  static SourceRect centerCropAspect(img.Image image, int tw, int th) {
    final scale = math.max(tw / image.width, th / image.height);
    var cw = (tw / scale).round();
    var ch = (th / scale).round();
    if (cw < 1) cw = 1;
    if (cw > image.width) cw = image.width;
    if (ch < 1) ch = 1;
    if (ch > image.height) ch = image.height;
    final x = (image.width - cw) ~/ 2;
    final y = (image.height - ch) ~/ 2;
    return SourceRect(x, y, cw, ch);
  }

  /// 主色感知降采样：每个目标格取源盒内 RGB333 直方图，严格多数（>50%）
  /// bin 的均值；无多数（渐变/混色格）回退整盒均值（保抗噪）
  ///
  /// 仅降采样适用（两维都缩小）；含放大维时回退盒式均值（小图放大，
  /// 主色判定无意义）。静态公开供单测直测。
  static img.Image dominantResize(img.Image src, int tw, int th) {
    final out = img.Image(width: tw, height: th);
    final sw = src.width, sh = src.height;
    const bins = 512; // RGB333：r>>5 <<6 | g>>5 <<3 | b>>5
    final cnt = List<int>.filled(bins, 0);
    final sr = List<int>.filled(bins, 0);
    final sg = List<int>.filled(bins, 0);
    final sb = List<int>.filled(bins, 0);
    final touched = <int>[];

    for (var ty = 0; ty < th; ty++) {
      final y0 = ty * sh ~/ th;
      var y1 = (ty + 1) * sh ~/ th;
      if (y1 <= y0) y1 = y0 + 1;
      if (y1 > sh) y1 = sh;
      for (var tx = 0; tx < tw; tx++) {
        final x0 = tx * sw ~/ tw;
        var x1 = (tx + 1) * sw ~/ tw;
        if (x1 <= x0) x1 = x0 + 1;
        if (x1 > sw) x1 = sw;

        var total = 0;
        var sumR = 0, sumG = 0, sumB = 0;
        touched.clear();
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            final p = src.getPixel(x, y);
            final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
            final bin = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
            if (cnt[bin] == 0) {
              touched.add(bin);
            }
            cnt[bin]++;
            sr[bin] += r;
            sg[bin] += g;
            sb[bin] += b;
            total++;
            sumR += r;
            sumG += g;
            sumB += b;
          }
        }
        if (total == 0) {
          // 源图空（不会发生，防御）：保持黑
          out.setPixelRgba(tx, ty, 0, 0, 0, 255);
          continue;
        }

        var best = -1;
        var bestCnt = 0;
        for (final bin in touched) {
          if (cnt[bin] > bestCnt) {
            bestCnt = cnt[bin];
            best = bin;
          }
        }

        int or_, og, ob;
        if (best >= 0 && bestCnt * 2 > total) {
          // 多数 bin：用该 bin 均值（bin 内还有 8 级通道内的细微差异，均值保留）
          or_ = (sr[best] / bestCnt).round();
          og = (sg[best] / bestCnt).round();
          ob = (sb[best] / bestCnt).round();
        } else {
          or_ = (sumR / total).round();
          og = (sumG / total).round();
          ob = (sumB / total).round();
        }
        out.setPixelRgba(tx, ty, or_, og, ob, 255);

        for (final bin in touched) {
          cnt[bin] = 0;
          sr[bin] = 0;
          sg[bin] = 0;
          sb[bin] = 0;
        }
      }
    }
    return out;
  }
}

/// compute 参数（全字段可跨 isolate 直传）
class ConvertGridArgs {
  final img.Image image;
  final SourceRect rect;
  final int width, height;
  final ConvertStyle style;
  final ConvertMetric metric;
  final BeadPalette palette;
  const ConvertGridArgs({
    required this.image,
    required this.rect,
    required this.width,
    required this.height,
    required this.style,
    required this.metric,
    required this.palette,
  });
}

/// isolate 内执行的转换主体（顶层函数供 compute 调用）
List<int> convertGrid(ConvertGridArgs a) {
  final cropped = img.copyCrop(
    a.image,
    x: a.rect.x,
    y: a.rect.y,
    width: a.rect.width,
    height: a.rect.height,
  );

  // 降采样：两维都缩小走主色感知，否则盒式均值（小图放大回退）
  final downX = cropped.width >= a.width;
  final downY = cropped.height >= a.height;
  final resized = downX && downY
      ? PixelEngine.dominantResize(cropped, a.width, a.height)
      : img.copyResize(
          cropped,
          width: a.width,
          height: a.height,
          interpolation: img.Interpolation.average,
        );

  final n = a.width * a.height;
  final pr = List<int>.filled(n, 0);
  final pg = List<int>.filled(n, 0);
  final pb = List<int>.filled(n, 0);
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final p = resized.getPixel(x, y);
      final i = y * a.width + x;
      pr[i] = p.r.toInt();
      pg[i] = p.g.toInt();
      pb[i] = p.b.toInt();
    }
  }

  return Quantizer(a.palette).quantizePixels(
    pixelsR: pr,
    pixelsG: pg,
    pixelsB: pb,
    width: a.width,
    height: a.height,
    style: a.style,
    metric: a.metric,
  );
}
