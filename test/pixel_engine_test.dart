/// 像素引擎：主色感知降采样 / 中心裁剪宽高比 / 端到端转换（宽高分离）
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/pixel_engine.dart';

const _red = [255, 0, 0];
const _blue = [0, 0, 255];
const _white = [255, 255, 255];

img.Image _stripImage(List<List<int>> colors) {
  final im = img.Image(width: colors.length, height: 1);
  for (var x = 0; x < colors.length; x++) {
    final c = colors[x];
    im.setPixelRgba(x, 0, c[0], c[1], c[2], 255);
  }
  return im;
}

void main() {
  group('dominantResize 主色感知降采样', () {
    test('多数色占优（5:3）取多数 bin 均值，不被均值混色', () {
      final src = _stripImage([_red, _red, _red, _red, _red, _blue, _blue, _blue]);
      final out = PixelEngine.dominantResize(src, 1, 1);
      final p = out.getPixel(0, 0);
      // 旧盒式均值会得到 (159,0,159) 紫灰；主色感知保持纯红
      expect([p.r.toInt(), p.g.toInt(), p.b.toInt()], _red);
    });

    test('少数反转（3:5）取多数蓝', () {
      final src = _stripImage([_red, _red, _red, _blue, _blue, _blue, _blue, _blue]);
      final out = PixelEngine.dominantResize(src, 1, 1);
      final p = out.getPixel(0, 0);
      expect([p.r.toInt(), p.g.toInt(), p.b.toInt()], _blue);
    });

    test('无多数（4:4 平局）回退整盒均值', () {
      final src = _stripImage([_red, _red, _red, _red, _blue, _blue, _blue, _blue]);
      final out = PixelEngine.dominantResize(src, 1, 1);
      final p = out.getPixel(0, 0);
      expect([p.r.toInt(), p.g.toInt(), p.b.toInt()], [128, 0, 128]);
    });

    test('平色区单颗噪点不污染（7 红 + 1 白）', () {
      final src = _stripImage(
        [_red, _red, _red, _red, _red, _red, _red, _white],
      );
      final out = PixelEngine.dominantResize(src, 1, 1);
      final p = out.getPixel(0, 0);
      expect([p.r.toInt(), p.g.toInt(), p.b.toInt()], _red);
    });

    test('多格切分：色块边界对齐格界时各格纯净', () {
      // 8×1：左 4 红、右 4 蓝 -> 2 格，每格 4 源像素纯净
      final src = _stripImage([_red, _red, _red, _red, _blue, _blue, _blue, _blue]);
      final out = PixelEngine.dominantResize(src, 2, 1);
      final p0 = out.getPixel(0, 0);
      final p1 = out.getPixel(1, 0);
      expect([p0.r.toInt(), p0.g.toInt(), p0.b.toInt()], _red);
      expect([p1.r.toInt(), p1.g.toInt(), p1.b.toInt()], _blue);
    });

    test('二维盒切分尺寸正确', () {
      final src = img.Image(width: 10, height: 6);
      final out = PixelEngine.dominantResize(src, 4, 3);
      expect(out.width, 4);
      expect(out.height, 3);
    });
  });

  group('centerCropAspect 中心裁剪到目标宽高比', () {
    test('横图 -> 正方形取中心最大方', () {
      final im = img.Image(width: 100, height: 60);
      final r = PixelEngine.centerCropAspect(im, 40, 40);
      expect([r.x, r.y, r.width, r.height], [20, 0, 60, 60]);
    });

    test('竖图 -> 正方形取中心最大方', () {
      final im = img.Image(width: 60, height: 100);
      final r = PixelEngine.centerCropAspect(im, 40, 40);
      expect([r.x, r.y, r.width, r.height], [0, 20, 60, 60]);
    });

    test('横图 -> 窄高目标裁竖条', () {
      final im = img.Image(width: 100, height: 60);
      final r = PixelEngine.centerCropAspect(im, 20, 40);
      expect([r.x, r.y, r.width, r.height], [35, 0, 30, 60]);
    });

    test('宽高比一致取整图', () {
      final im = img.Image(width: 40, height: 40);
      final r = PixelEngine.centerCropAspect(im, 40, 40);
      expect([r.x, r.y, r.width, r.height], [0, 0, 40, 40]);
    });
  });

  group('convert 端到端（宽高分离）', () {
    const palette = BeadPalette([
      BeadColor("R1", "红", 0xFFFF0000),
      BeadColor("B1", "蓝", 0xFF0000FF),
      BeadColor("W1", "白", 0xFFFFFFFF),
    ]);

    img.Image halfRedHalfBlue(int w, int h) {
      final im = img.Image(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final red = x < w ~/ 2;
          im.setPixelRgba(x, y, red ? 255 : 0, 0, red ? 0 : 255, 255);
        }
      }
      return im;
    }

    test('正方形目标：左右半红蓝 -> 左半红豆右半蓝豆', () async {
      final bytes = Uint8List.fromList(
        img.encodePng(halfRedHalfBlue(16, 16)),
      );
      final model = await PixelEngine(palette).convert(
        bytes: bytes,
        width: 8,
        height: 8,
      );
      expect(model.width, 8);
      expect(model.height, 8);
      expect(model.grid.length, 64);
      expect(model.cell(0, 0), 0); // 红
      expect(model.cell(7, 0), 1); // 蓝
      expect(model.cell(0, 7), 0);
      expect(model.cell(7, 7), 1);
    });

    test('非方形目标（4×2）：中心裁剪 + 无变形量化', () async {
      final bytes = Uint8List.fromList(
        img.encodePng(halfRedHalfBlue(16, 16)),
      );
      final model = await PixelEngine(palette).convert(
        bytes: bytes,
        width: 4,
        height: 2,
      );
      expect(model.width, 4);
      expect(model.height, 2);
      expect(model.grid.length, 8);
      expect(model.cell(0, 0), 0);
      expect(model.cell(3, 1), 1);
    });

    test('非法尺寸抛 ArgumentError', () async {
      final bytes = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
      await expectLater(
        PixelEngine(palette).convert(bytes: bytes, width: 0, height: 4),
        throwsArgumentError,
      );
    });

    test('自定义 sourceRect 覆盖中心裁剪', () async {
      // 全红 8×8，sourceRect 只取右下 4×4 全蓝区域
      final im = img.Image(width: 8, height: 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final blue = x >= 4 && y >= 4;
          im.setPixelRgba(x, y, blue ? 0 : 255, 0, blue ? 255 : 0, 255);
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(im));
      final model = await PixelEngine(palette).convert(
        bytes: bytes,
        width: 2,
        height: 2,
        sourceRect: const SourceRect(4, 4, 4, 4),
      );
      expect(model.cell(0, 0), 1); // 裁剪区内全蓝
      expect(model.cell(1, 1), 1);
    });

    test('大格转换（120×90 非方形无上限路径）尺寸与内容正确', () async {
      final bytes = Uint8List.fromList(
        img.encodePng(halfRedHalfBlue(60, 90)),
      );
      final model = await PixelEngine(palette).convert(
        bytes: bytes,
        width: 120,
        height: 90,
      );
      expect(model.width, 120);
      expect(model.height, 90);
      expect(model.grid.length, 120 * 90);
      // 放大路径（源 60<120）走盒式均值，左红右蓝结构保持
      expect(model.cell(0, 0), 0);
      expect(model.cell(119, 89), 1);
    });
  });
}
