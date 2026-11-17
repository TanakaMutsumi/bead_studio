/// CIEDE2000 实现正确性 + 短名单匹配与暴力对拍 + 量化误差对比
///
/// 向量出处：Sharma, Wu & Dalal (2005) "The CIEDE2000 Color-Difference
/// Formula: Implementation Notes..." 官方 34 组测试对（此处取覆盖色相回绕/
/// 近中性/暗色等边角分支的子集），是 CIEDE2000 实现的行业验收标准。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/core/palette.dart';
import 'package:bead_studio/core/quantizer.dart';

/// Sharma 2005 测试向量（Lab1, Lab2, 期望 ΔE00）
const _sharmaVectors = [
  ([50.0, 2.6772, -79.7751], [50.0, 0.0, -82.7485], 2.0425),
  ([50.0, 3.1571, -77.2803], [50.0, 0.0, -82.7485], 2.8615),
  ([50.0, 2.8361, -74.02], [50.0, 0.0, -82.7485], 3.4412),
  ([50.0, 0.0, 0.0], [50.0, -1.0, 2.0], 2.3669),
  ([50.0, 2.49, -0.001], [50.0, -2.49, 0.0009], 7.1792),
  ([50.0, 2.49, -0.001], [50.0, -2.49, 0.0011], 7.2195),
  ([50.0, -0.001, 2.49], [50.0, 0.0009, -2.49], 4.8045),
  ([50.0, -0.001, 2.49], [50.0, 0.0011, -2.49], 4.7461),
  ([50.0, 2.5, 0.0], [73.0, 25.0, -18.0], 27.1492),
  ([50.0, 2.5, 0.0], [56.0, -27.0, -3.0], 31.9030),
  ([50.0, 2.5, 0.0], [50.0, 3.1736, 0.5854], 1.0),
  ([60.2574, -34.0099, 36.2677], [60.4626, -34.1751, 39.4387], 1.2644),
  ([61.2901, 3.7196, -5.3901], [61.4292, 2.248, -4.962], 1.8731),
  ([22.7233, 20.0904, -46.694], [23.0331, 14.973, -42.5619], 2.0373),
  ([90.8027, -2.0831, 1.441], [91.1528, -1.6435, 0.0447], 1.4441),
  ([6.7747, -0.2908, -2.4247], [5.8714, -0.0985, -2.2286], 0.6377),
  ([2.0776, 0.0795, -1.135], [0.9033, -0.0636, -0.5514], 0.9082),
];

BeadPalette loadMard() {
  final raw = File('assets/palettes/mard.json').readAsStringSync();
  return BeadPalette.fromJson(jsonDecode(raw) as List<dynamic>);
}

void main() {
  group('ciede2000 Sharma 官方测试向量', () {
    for (var i = 0; i < _sharmaVectors.length; i++) {
      final (lab1, lab2, expected) = _sharmaVectors[i];
      test('向量 ${i + 1}: $lab1 vs $lab2 = $expected', () {
        final de = ciede2000(lab1, lab2);
        expect(de, closeTo(expected, 1e-4));
        // 对称性
        expect(ciede2000(lab2, lab1), closeTo(expected, 1e-4));
      });
    }
  });

  group('nearestIndexDe00 短名单与暴力对拍（MARD 291 色）', () {
    test('随机 400 色与全表 CIEDE2000 暴力 argmin 一致', () {
      final palette = loadMard();
      final q = Quantizer(palette);
      final rng = math.Random(42);
      // 全 RGB 空间均匀撒点 + 蓝紫区加密（ΔE76 最易失准的区域）
      final samples = <List<int>>[
        for (var i = 0; i < 300; i++)
          [rng.nextInt(256), rng.nextInt(256), rng.nextInt(256)],
        for (var i = 0; i < 100; i++)
          [rng.nextInt(120), rng.nextInt(80), 155 + rng.nextInt(100)],
      ];
      for (final rgb in samples) {
        final fast = q.nearestIndexDe00(rgb[0], rgb[1], rgb[2]);
        var brute = 0;
        var best = double.infinity;
        final lab = _rgbToLabForTest(rgb[0], rgb[1], rgb[2]);
        for (var j = 0; j < palette.colors.length; j++) {
          final de = ciede2000(
            lab,
            _rgbToLabForTest(
              palette.colors[j].r,
              palette.colors[j].g,
              palette.colors[j].b,
            ),
          );
          if (de < best) {
            best = de;
            brute = j;
          }
        }
        expect(fast, brute, reason: 'RGB$rgb 短名单失准: fast=$fast brute=$brute');
      }
    });

    test('memo 命中返回一致结果', () {
      final q = Quantizer(loadMard());
      final a = q.nearestIndexDe00(30, 60, 200);
      final b = q.nearestIndexDe00(30, 60, 200);
      expect(a, b);
    });
  });

  group('量化误差：CIEDE2000 度量不劣于 ΔE76', () {
    test('蓝紫渐变逐像素匹配的平均 ΔE00 误差对比（纯匹配口径）', () {
      final palette = loadMard();
      final q = Quantizer(palette);
      // 蓝 -> 紫渐变（ΔE76 失准区），加少量绿->青渐变对照
      final px = <List<int>>[];
      for (var i = 0; i < 64; i++) {
        final t = i / 63;
        px.add([(60 * t).round(), (40 * t).round(), (255 - 50 * t).round()]);
      }
      for (var i = 0; i < 32; i++) {
        final t = i / 31;
        px.add([(20 * t).round(), (200 * t).round(), (120 * t).round()]);
      }

      // 直接逐像素比最近色匹配（不经 quantizePixels 的近似色统一/
      // 去孤立点管线——那两步按频率合并可能改写选择，度量属性会被淹没）
      var sum76 = 0.0, sum00 = 0.0;
      for (final p in px) {
        final lab = _rgbToLabForTest(p[0], p[1], p[2]);
        final c76 = palette.colors[q.nearestIndex(p[0], p[1], p[2])];
        final c00 = palette.colors[q.nearestIndexDe00(p[0], p[1], p[2])];
        sum76 += ciede2000(lab, _rgbToLabForTest(c76.r, c76.g, c76.b));
        sum00 += ciede2000(lab, _rgbToLabForTest(c00.r, c00.g, c00.b));
      }
      final err76 = sum76 / px.length, err00 = sum00 / px.length;
      expect(err00, lessThanOrEqualTo(err76 + 1e-9),
          reason: 'de00 度量平均误差 $err00 应 ≤ lab76 度量 $err76');
    });
  });

  group('maxSpeckSizeFor', () {
    test('随边长放大且非方形取大边', () {
      expect(maxSpeckSizeFor(26, 26), 2);
      expect(maxSpeckSizeFor(29, 29), 2);
      expect(maxSpeckSizeFor(52, 52), 3);
      expect(maxSpeckSizeFor(78, 78), 4);
      expect(maxSpeckSizeFor(80, 40), 4);
      expect(maxSpeckSizeFor(40, 80), 4);
      expect(maxSpeckSizeFor(1, 1), 1);
    });
  });
}

/// 与实现同口径的 RGB->Lab（测试独立重写，互为校验）
List<double> _rgbToLabForTest(int r, int g, int b) {
  double f(num c) {
    final v = c / 255.0;
    return v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  final lr = f(r), lg = f(g), lb = f(b);
  final x = (lr * 0.4124 + lg * 0.3576 + lb * 0.1805) / 0.95047;
  final y = lr * 0.2126 + lg * 0.7152 + lb * 0.0722;
  final z = (lr * 0.0193 + lg * 0.1192 + lb * 0.9505) / 1.08883;
  double pivot(double t) => t > 0.008856
      ? math.pow(t, 1.0 / 3.0).toDouble()
      : 7.787 * t + 16.0 / 116.0;
  final fx = pivot(x), fy = pivot(y), fz = pivot(z);
  return [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)];
}
