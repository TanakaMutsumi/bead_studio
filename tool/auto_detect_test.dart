// 自动框选算法移植验证：与 python 原型同一逻辑跑 test_pic4/pic5
// 用法: dart run tool/auto_detect_test.dart
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:image/image.dart' as img;

class R {
  final double l, t, r, b;
  const R(this.l, this.t, this.r, this.b);
  @override
  String toString() => 'R($l, $t, $r, $b)';
}

class RowFeat {
  final int nBlocks, maxLen, minX, maxX;
  final double nonWhite;
  final Set<int> colors;
  const RowFeat(this.nBlocks, this.maxLen, this.nonWhite, this.colors,
      this.minX, this.maxX);
}

bool qWhite(int q) =>
    ((q >> 8) & 15) >= 15 && ((q >> 4) & 15) >= 15 && (q & 15) >= 15;

void main() {
  for (final name in ['build/test_pic4.png', 'build/test_pic5.png']) {
    final sw = Stopwatch()..start();
    final image = img.decodeImage(File(name).readAsBytesSync())!;
    print('$name ${image.width}x${image.height}');
    const step = 2, runMin = 20;
    final w = image.width, h = image.height;
    final feats = <int, RowFeat>{};
    for (var y = 0; y < h; y += step) {
      var nonWhite = 0, nBlocks = 0, maxLen = 0;
      var minX = 1 << 30, maxX = -(1 << 30);
      final colors = <int>{};
      var runCol = -1, runLen = 0, runStart = 0;
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        final q = ((p.r.toInt() >> 4) << 8) |
            ((p.g.toInt() >> 4) << 4) |
            (p.b.toInt() >> 4);
        if (!qWhite(q)) {
          nonWhite++;
        }
        if (q == runCol) {
          runLen++;
        } else {
          if (runLen >= runMin && !qWhite(runCol)) {
            nBlocks++;
            if (runLen > maxLen) maxLen = runLen;
            colors.add(runCol);
            if (runStart < minX) minX = runStart;
            if (runStart + runLen > maxX) maxX = runStart + runLen;
          }
          runCol = q;
          runLen = 1;
          runStart = x;
        }
      }
      if (runLen >= runMin && !qWhite(runCol)) {
        nBlocks++;
        if (runLen > maxLen) maxLen = runLen;
        colors.add(runCol);
        if (runStart < minX) minX = runStart;
        if (runStart + runLen > maxX) maxX = runStart + runLen;
      }
      feats[y] = RowFeat(nBlocks, maxLen, nonWhite / w, colors, minX, maxX);
    }
    final legendRows = <int, RowFeat>{};
    feats.forEach((y, f) {
      final ok = f.nBlocks >= 3 &&
          f.maxLen <= w * 0.35 &&
          (f.maxLen >= 60 || (f.colors.length >= 3 && f.nonWhite <= 0.75));
      if (ok) legendRows[y] = f;
    });
    print('  legendRows=${legendRows.length}  耗时 ${sw.elapsedMilliseconds}ms');
    if (legendRows.isEmpty) continue;
    final ys = legendRows.keys.toList()..sort();
    print('  图例行 y: ${ys.first}-${ys.last}');
    final bands = <List<int>>[
      [ys.first, ys.first]
    ];
    for (final y in ys.skip(1)) {
      if (y - bands.last[1] <= 60) {
        bands.last[1] = y;
      } else {
        bands.add([y, y]);
      }
    }
    print('  bands=${bands.map((b) => '${b[0]}-${b[1]}').join(', ')}');

    bool quietOutside(int edge, bool below) {
      for (final d in [step, step * 2, step * 3]) {
        final y = below ? edge + d : edge - d;
        final f = feats[y];
        if (f == null) return true;
        if (f.nonWhite <= 0.10 || f.nBlocks <= 2) return true;
      }
      return false;
    }

    var bestScore = -1.0;
    R? bestRect;
    for (final b in bands) {
      if (b[1] - b[0] > h * 0.15) {
        print('  band ${b[0]}-${b[1]} 带高超限跳过');
        continue;
      }
      final qTop = quietOutside(b[0], false), qBot = quietOutside(b[1], true);
      if (!qTop || !qBot) {
        print('  band ${b[0]}-${b[1]} quiet(top=$qTop,bot=$qBot) 不满足跳过');
        continue;
      }
      var nSum = 0, minX = 1 << 30, maxX = -(1 << 30);
      legendRows.forEach((y, f) {
        if (y >= b[0] && y <= b[1]) {
          nSum += f.nBlocks;
          if (f.minX < minX) minX = f.minX;
          if (f.maxX > maxX) maxX = f.maxX;
        }
      });
      final score = nSum + (b[0] + b[1]) / 2 / h * 50;
      print('  band ${b[0]}-${b[1]} nSum=$nSum score=$score');
      if (score > bestScore) {
        bestScore = score;
        bestRect = R(
          (minX - 15).clamp(0, w - 4).toDouble(),
          (b[0] - 10).clamp(0, h - 4).toDouble(),
          (maxX + 15).clamp(4, w).toDouble(),
          (b[1] + 10 + step).clamp(4, h).toDouble(),
        );
      }
    }
    print('  => $bestRect (score $bestScore)');
  }
}
