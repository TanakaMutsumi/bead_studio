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

/// 主体网格周期检测（自相关 + 谐波约简）——detectGrid 的主体图增强版
///
/// 图纸每格内部含多条边缘（豆圆弧/印刷细节），投影峰间距呈「格内次峰
/// 8-14px + 真周期 31px」混布，中位数会落到次峰带且离散检验失败返回
/// null（2026-09-08 pic5 实测：X 方向 median=13、in-band 0.49 被判
/// 无效，兜底 pitch=图宽/20 差真值 2.3 倍）。本函数改用投影自相关：
/// 相关最强的 lag 往往是真周期的整数倍（粗格线每 k 格一条时更突出），
/// 对最强 lag 的 k 分频（k 从 1 升序即分频从大到小）依次检验「分频
/// 自身是显著 lag + 自身相关显著 + 显著 lag 集大多数是其近整数倍」，
/// 第一个通过的即基周期。倍频自然约简到基频；半频无法靠整数倍判据
/// 拒绝——b 的整数倍必是 b/2 的偶数倍，harm(b/2)≥harm(b) 恒成立，
/// 唯一闸门是「候选自身必须是显著 lag」：真周期在自己 lag 处必有
/// 显著局部极大，半频处没有（2026-09-08 review 端到端仿真证实：
/// 不加此判据时真值 31 被次峰稀释拒掉、半频 15.5 以 harm 100% 通过，
/// 返回半距 → 列数翻倍隔列采样，且半频格线一半压在真格线上目视
/// 难察觉）。格线相位用周期折叠：投影按周期取模叠加，环形平滑后
/// 最强相位即首条格线位置（与九宫格锚点同语义：第一根格线交点）。
GridDetectResult? detectGridAutocorr(List<int> gray, int w, int h) {
  final projX = _edgeProjection(gray, w, h, horizontal: true);
  final projY = _edgeProjection(gray, w, h, horizontal: false);
  if (projX == null || projY == null) {
    return null;
  }
  final pitchX = _basePitchByAutocorr(projX);
  final pitchY = _basePitchByAutocorr(projY);
  if (pitchX == null || pitchY == null) {
    return null;
  }
  // 轴间一致性闸门：照片像素是方形的，两轴真格距差只应来自轻微透视
  //（个位数百分比）。两轴各自独立做 k 分频扫描，一侧锁到谐波（半频/
  // 倍频）或格内次结构时，格距比会明显偏离 1（如 0.5/2），且无法判定
  // 哪一侧错——静默采用会把每个格切成 1×2/2×1 的长方形（部分设备图
  // 上已发生）。宁可判无效走「图宽/20 默认 + 手动调整」兜底
  final pr = pitchX > pitchY ? pitchX / pitchY : pitchY / pitchX;
  if (pr > 1.2) {
    return null;
  }
  final offX = _phaseByFold(projX, pitchX);
  final offY = _phaseByFold(projY, pitchY);
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

/// 边缘强度投影（峰检测前半段抽出共享）：[horizontal] 为 true 时返回
/// 垂直边缘沿 x 的分布（竖直格线检测用），否则水平边缘沿 y 的分布。
/// 尺寸过小返回 null
List<double>? _edgeProjection(
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
  return proj;
}

/// 自相关基周期：去均值归一化自相关 -> 显著 lag 集 -> 最强 lag 的 k
/// 分频从大到小找第一个「自身是显著 lag + 自身相关显著 + 显著集 50%+
/// 是其近整数倍（±3px）」的分频。找不到返回 null
double? _basePitchByAutocorr(List<double> proj) {
  final n = proj.length;
  // 最小周期 8：格距 <8px 的拼豆图纸不存在（1440 宽图 180 列已到上限），
  // 且 b=6 时 ±3 近整数倍容差覆盖整个相位空间（任意整数到最近 6 倍数
  // 距离 ≤3），harm 判据彻底失效
  const minLag = 8;
  final maxLag = n ~/ 4;
  if (maxLag <= minLag) {
    return null;
  }
  var mean = 0.0;
  for (final v in proj) {
    mean += v;
  }
  mean /= n;
  var variance = 0.0;
  for (final v in proj) {
    variance += (v - mean) * (v - mean);
  }
  variance /= n;
  if (variance <= 0) {
    return null;
  }
  final corr = List<double>.filled(maxLag + 1, 0);
  for (var lag = minLag; lag <= maxLag; lag++) {
    var s = 0.0;
    for (var i = 0; i + lag < n; i++) {
      s += (proj[i] - mean) * (proj[i + lag] - mean);
    }
    corr[lag] = s / (n - lag) / variance;
  }
  // 显著 lag 集（局部极大且高于噪声线）与其中相关最强者
  const kSig = 0.3;
  final sig = <int>[];
  var l1 = minLag;
  for (var lag = minLag + 1; lag < maxLag; lag++) {
    if (corr[lag] > kSig &&
        corr[lag] >= corr[lag - 1] &&
        corr[lag] > corr[lag + 1]) {
      sig.add(lag);
      if (corr[lag] > corr[l1]) {
        l1 = lag;
      }
    }
  }
  if (sig.isEmpty) {
    return null;
  }
  for (var k = 1; k <= 8; k++) {
    final b = l1 / k;
    if (b < minLag) {
      break;
    }
    // 半频闸门（见函数组头注释）：候选自身（±1 容差）必须是显著 lag
    // ——真周期在自己 lag 处必有显著局部极大，半频处没有。没有这条，
    // harm 对半频零分辨力（b 的整数倍必是 b/2 的偶数倍），半频候选
    // harm 得分只会 ≥ 真周期，k 升序扫描会先撞上通过验收的半频
    final bi = b.round();
    var selfSig = false;
    for (var d = -1; d <= 1 && !selfSig; d++) {
      selfSig = sig.contains(bi + d);
    }
    if (!selfSig) {
      continue;
    }
    var selfMax = 0.0;
    for (var d = -2; d <= 2; d++) {
      final i = (b + d).round();
      if (i >= minLag && i <= maxLag && corr[i] > selfMax) {
        selfMax = corr[i];
      }
    }
    if (selfMax < kSig) {
      continue;
    }
    // 谐波覆盖率 50%：格内次峰（8-14px）天然稀释真周期的覆盖率
    // （次峰 lag 不是真周期整数倍），60% 会把真值拒掉送给半频/兜底
    var harm = 0;
    for (final s in sig) {
      if ((s - (s / b).round() * b).abs() <= 3) {
        harm++;
      }
    }
    if (harm >= sig.length * 0.5) {
      return b;
    }
  }
  return null;
}

/// 周期折叠相位：投影按 [pitch] 取模叠加成相位直方图，环形 3 点平滑后
/// 最强相位 = 全部格线对齐的位置（首条格线，相对投影起点）
double _phaseByFold(List<double> proj, double pitch) {
  final n = proj.length;
  final nb = pitch.floor();
  if (nb < 2) {
    return 0;
  }
  final fold = List<double>.filled(nb, 0);
  for (var i = 0; i < n; i++) {
    final ph = i - (i / pitch).floor() * pitch;
    fold[ph.round().clamp(0, nb - 1)] += proj[i];
  }
  var best = 0;
  var bestV = -1.0;
  for (var ph = 0; ph < nb; ph++) {
    // 环形平滑：相邻相位（含回卷）平均后比较，格线峰落在相位边界不分裂
    final v =
        (fold[(ph + nb - 1) % nb] + fold[ph] + fold[(ph + 1) % nb]) / 3;
    if (v > bestV) {
      bestV = v;
      best = ph;
    }
  }
  return best.toDouble();
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
