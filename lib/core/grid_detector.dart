/// 网格对齐检测：从灰度像素图估计图纸/成品照的网格参数
///
/// 原理（原创实现）：
/// 1. 求水平/垂直边缘强度投影（相邻像素差的绝对值沿正交方向求和）
/// 2. 投影曲线的周期性峰 = 网格线位置
/// 3. 峰间距中位数 = 格距 pitch，首个内峰反推网格偏移
///
/// 适用于：正拍的规整像素图纸、珠子排列成品照（要求倾斜角小）
library;

/// 网格检测结果
class GridDetectResult {
  final double pitchX;

  ///< 水平格距（像素）
  final double pitchY;

  ///< 垂直格距（像素）
  final double offsetX;

  ///< 首列网格中心 x（像素）
  final double offsetY;

  ///< 首行网格中心 y（像素）
  final int cols;

  ///< 列数
  final int rows;

  ///< 行数

  const GridDetectResult({
    required this.pitchX,
    required this.pitchY,
    required this.offsetX,
    required this.offsetY,
    required this.cols,
    required this.rows,
  });
}

/// 在 [w]×[h] 灰度图（行优先，0-255）上检测网格，失败返回 null
GridDetectResult? detectGrid(List<int> gray, int w, int h) {
  final xs = _edgePeaks(gray, w, h, horizontal: true);
  final ys = _edgePeaks(gray, w, h, horizontal: false);
  if (xs == null || ys == null) {
    return null;
  }

  final pitchX = _medianSpacing(xs, w);
  final pitchY = _medianSpacing(ys, h);
  if (pitchX == null || pitchY == null) {
    return null;
  }

  // 网格中心偏移：首峰 - k*pitch 反推到网格起点附近
  final offX = xs.first - (xs.first / pitchX).floor() * pitchX + pitchX / 2;
  final offY = ys.first - (ys.first / pitchY).floor() * pitchY + pitchY / 2;
  final cols = ((w - offX + pitchX / 2) / pitchX).floor();
  final rows = ((h - offY + pitchY / 2) / pitchY).floor();

  if (cols < 4 || rows < 4 || cols > 400 || rows > 400) {
    return null;
  }
  return GridDetectResult(
    pitchX: pitchX,
    pitchY: pitchY,
    offsetX: offX,
    offsetY: offY,
    cols: cols,
    rows: rows,
  );
}

/// 边缘强度投影 + 峰检测
///
/// [horizontal] 为 true 时统计垂直边缘（x 方向的差分）沿 x 的分布，
/// 得到竖直网格线的 x 坐标序列；false 时同理得到水平线的 y 坐标
List<double>? _edgePeaks(
  List<int> gray,
  int w,
  int h, {
  required bool horizontal,
}) {
  final n = horizontal ? w : h;
  final other = horizontal ? h : w;
  if (n < 16 || other < 16) {
    return null;
  }

  // 投影：对每个 x，累加所有 y 上 |I(x+1,y)-I(x,y)|
  final proj = List<double>.filled(n, 0);
  for (var i = 0; i < n - 1; i++) {
    var sum = 0.0;
    for (var j = 0; j < other; j++) {
      final a = horizontal ? gray[j * w + i] : gray[i * w + j];
      final b = horizontal ? gray[j * w + i + 1] : gray[(i + 1) * w + j];
      sum += (b - a).abs();
    }
    proj[i] = sum / other;
  }

  // 3 点平滑去毛刺
  final smooth = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final a = proj[i > 0 ? i - 1 : i];
    final b = proj[i];
    final c = proj[i < n - 1 ? i + 1 : i];
    smooth[i] = (a + b + c) / 3;
  }

  // 阈值 = 均值 × 1.4（略高于噪声基线）
  final mean = smooth.reduce((a, b) => a + b) / n;
  final threshold = mean * 1.4;
  final minGap = (n / 200).clamp(2, 40).toDouble();

  final peaks = <double>[];
  var lastPeak = -minGap;
  for (var i = 1; i < n - 1; i++) {
    if (smooth[i] > threshold &&
        smooth[i] >= smooth[i - 1] &&
        smooth[i] > smooth[i + 1] &&
        i - lastPeak >= minGap) {
      peaks.add(i.toDouble());
      lastPeak = i.toDouble();
    }
  }
  return peaks.length >= 5 ? peaks : null;
}

/// 相邻峰间距的中位数（鲁棒估计格距），间距离散度过大返回 null
double? _medianSpacing(List<double> peaks, int n) {
  if (peaks.length < 5) {
    return null;
  }
  final gaps = <double>[];
  for (var i = 1; i < peaks.length; i++) {
    gaps.add(peaks[i] - peaks[i - 1]);
  }
  gaps.sort();
  final median = gaps[gaps.length ~/ 2];

  // 有效性：至少 60% 的间距落在中位数 ±35% 带内（排除误检峰）
  var inBand = 0;
  for (final g in gaps) {
    if ((g - median).abs() <= median * 0.35) {
      inBand++;
    }
  }
  if (inBand / gaps.length < 0.6 || median < 2 || median > n / 4) {
    return null;
  }
  return median;
}
