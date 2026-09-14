/// 图例区自动检测（游程法 v9）——app 与离线模拟器共用的唯一实现
///
/// 纯 Dart、不依赖 Flutter（无 dart:ui）——`dart run tool/legend_sim.dart`
/// 可直接跑。返回**原图坐标**（走 [detectLegendCanonical] 时为调用入参
/// 原图坐标），显示坐标换算由调用方做。
///
/// v9 规则全貌（2026-09-14 定稿，11 张 fleet 全对；复刻自
/// `.test/wx_replica6.py`，算法演进史见 docs/vision_tuning_notes.md）：
///
/// 1. **行原型 A（经典色板行）**：`nB12>=3 且 maxLen12<=35%w 且
///    （maxLen12>=60 或（colors12>=3 且 nw<=0.75））`。图例色块是 12px+
///    纯色矩形（长游程），豆图每颗豆被格线打断（游程<=豆宽），整行纯色
///    背景只有 1 个超长游程。
/// 2. **B 密集色条原型已删除**（v9）：其两个"真例"实证都是假阳性——
///    u2/wx5 的 1386 全宽色条实为豆板底排豆子（42 块仅 2 色=图案条纹行，
///    真图例是其下方 1440-1475 的色片表格），wx4 横条本就无图例。
///    fleet 真图例清一色由 A 覆盖，wx4 正确返回 null。
/// 3. **贴行缘游程完全剔除**（页边框：wx1 两侧 ~290px 黑边）。
/// 4. **quiet 闸 nw<=0.35**：候选带上下 3 个采样行内任一行非白占比
///    <=0.35 才算隔离（u2 图例表文字行 nw 0.28-0.30 不再处死自己头顶
///    的色片行；板底纹带 0.45+ 仍被拦）。
/// 5. **带分类**：高带 >0.20h = 主体（tall）；>0.15h 且行通过率 <0.5 =
///    闸门拒（gate）；其余须过 quiet。
/// 6. **主体传播**：自底向上，tall 带为主体；主体上方 150px 内的带链
///    同为主体（画稿内部 >60px 空隙切出的碎片带全灭）。
/// 7. **跨度下限**：带内 >=12px 实块横向跨度 >=max(250px, 15%w)
///    （u2 板内色斑碎片带 [1294] 仅 63px）。
/// 8. **打分**：nSum8 + 饱和色数x15 + 底部位次x50——图例本质是饱和色板，
///    文字表格/灰线条的"色"多为非饱和灰。
/// 9. **带顶低饱和修剪**：胜出带砍掉带首 sat<2 的行（wx3 列序文本行
///    sat=0；真图例色板行 sat 高）。
/// 10. **向下延续走**：强内容行推进底边；弱墨行只保持行走；干净白隙
///    >6px 时前瞻 20px 跳接（有强行才跳）。强 = A 行，或 denseWide
///    （nw>=0.03 且 >=8 块跨度达标），或 darkText（深墨跨度达标、质量
///    >=15px、填充率 0.10-0.75——角水印/实心块/稀疏尘均拦）。
/// 11. **薄带上行走**（带高 <24px，距离上限 40px）：u2 原生照片偏糊，
///    图例表只剩一行色片行进带；上方紧贴的表格文字行收编为框顶（横向
///    并集其深墨范围），净白隙 >6px 即止且不前瞻——上方贴着板底列序尺，
///    不越界。无距离上限时弱墨保持会爬穿板底-图例间稀疏噪声带百像素级。
/// 12. **自适应顶垫边**：紧邻带顶上一行干净（nw<0.01）= 有白隙垫 10px；
///    有墨 = 贴豆板垫 4px。
/// 13. **左右各 +14px 补边**（u1 最边缘浅色块被判背景导致 minX/maxX 内收）。
library;

import 'package:image/image.dart' as img;

const _step = 2;

/// 量化色是否白背景：近白含浅灰底——三通道 nibble 全 >=11（原值 >=176）
/// 且极差 <=1（平灰）。部分图纸（微信图 wx1）用 ~187-214 平灰做版底/
/// 数字带底，按纯白（>=240）判会把灰底当内容。
bool qWhite(int q) {
  final r = (q >> 8) & 15, g = (q >> 4) & 15, b = q & 15;
  final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
  final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
  return mn >= 11 && mx - mn <= 1;
}

/// 深墨：三通道 nibble 全 <=10（与 PIL `max(rc) <= 10` 等价）。
/// 只查红通道会把纯蓝/蓝紫（红暗但蓝亮）也计入深墨，dkMass/dkX 随之
/// 漂移（对抗验证确认的移植分歧点，fleet 黑字图未触发属潜伏缺陷）
bool _dark(int q) {
  final r = (q >> 8) & 15, g = (q >> 4) & 15, b = q & 15;
  final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
  return mx <= 10;
}

bool _saturated(int q) {
  final r = (q >> 8) & 15, g = (q >> 4) & 15, b = q & 15;
  final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
  final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
  return mx - mn >= 2;
}

/// 一条采样行的多桶游程特征（v9 口径）
class RowFeat {
  final int nB8; // >=8px 非白游程数
  final int nB12; // >=12px 非白游程数
  final int maxLen8, maxLen12, maxLenAny;
  final double nw; // 非白占比（贴边框游程已剔除）
  final int minX, maxX; // >=12px 实块横向范围（无则 1<<30 / -(1<<30)）
  final int dkX0, dkX1, dkMass; // 深墨游程范围与像素质量
  final int blkX0, blkX1; // >=8px 块横向范围
  final int colors12; // >=12px 实块的量化色数
  final Set<int> sat8; // >=8px 游程中饱和色（极差>=2）集合
  final bool ok; // 行原型 A

  const RowFeat({
    required this.nB8,
    required this.nB12,
    required this.maxLen8,
    required this.maxLen12,
    required this.maxLenAny,
    required this.nw,
    required this.minX,
    required this.maxX,
    required this.dkX0,
    required this.dkX1,
    required this.dkMass,
    required this.blkX0,
    required this.blkX1,
    required this.colors12,
    required this.sat8,
    required this.ok,
  });
}

/// 候选带的判定明细（离线对拍/排障用；app 内不消费）
class LegendBandInfo {
  final int top, bottom;
  final String? reject; // null=入围；否则拒绝原因
  final double score; // 入围带才有意义
  final int nSum; // 带内 nB8 之和
  final int satColors; // 带内饱和色并集数

  const LegendBandInfo(
    this.top,
    this.bottom,
    this.reject,
    this.score,
    this.nSum,
    this.satColors,
  );
}

/// 检测结果：原图坐标整数矩形 + 最优带得分 + 全部带明细 + 过程注记
class LegendDetectResult {
  final int left, top, right, bottom;
  final double score;
  final List<LegendBandInfo> bands;
  final List<String> notes; // 修剪/上走/下延注记（对拍排障用）

  const LegendDetectResult(
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.score,
    this.bands,
    this.notes,
  );
}

/// 游程法检测图例条带（v9，全规则见库注释）
LegendDetectResult? detectLegend(img.Image image) {
  final w = image.width, h = image.height;

  int qAt(int x, int y) {
    final p = image.getPixel(x, y);
    return ((p.r.toInt() >> 4) << 8) |
        ((p.g.toInt() >> 4) << 4) |
        (p.b.toInt() >> 4);
  }

  // --- 逐采样行游程扫描（多桶特征一次成型） ---
  final feats = <int, RowFeat>{};
  for (var y = 0; y < h; y += _step) {
    var nB8 = 0, nB12 = 0, maxLen8 = 0, maxLen12 = 0, maxLenAny = 0;
    var nonWhite = 0;
    var minX = 1 << 30, maxX = -(1 << 30);
    var dkX0 = 1 << 30, dkX1 = -(1 << 30), dkMass = 0;
    var blkX0 = 1 << 30, blkX1 = -(1 << 30);
    final colors12 = <int>{}, sat8 = <int>{};
    // 游程收集（结算统一在循环后，贴行缘 = 页边框不算任何内容）
    final runs = <(int, int, int)>[]; // (色, 长, 起点)
    var runCol = -1, runLen = 0, runStart = 0;
    for (var x = 0; x < w; x++) {
      final q = qAt(x, y);
      if (q == runCol) {
        runLen++;
      } else {
        if (runCol >= 0) runs.add((runCol, runLen, runStart));
        runCol = q;
        runLen = 1;
        runStart = x;
      }
    }
    if (runCol >= 0) runs.add((runCol, runLen, runStart));
    for (final (col, len, start) in runs) {
      if (col < 0 || qWhite(col)) continue;
      if (start == 0 || start + len >= w) continue; // 贴行缘页框
      nonWhite += len;
      if (len > maxLenAny) maxLenAny = len;
      if (_dark(col)) {
        // 深色墨迹：质量+跨度（填充率分家：笔画行 0.10-0.75 vs 实心块
        // ~1.0 / 稀疏尘 <0.10）
        dkMass += len;
        if (start < dkX0) dkX0 = start;
        if (start + len > dkX1) dkX1 = start + len;
      }
      if (len >= 8) {
        nB8++;
        if (len > maxLen8) maxLen8 = len;
        if (start < blkX0) blkX0 = start;
        if (start + len > blkX1) blkX1 = start + len;
        if (_saturated(col)) sat8.add(col);
        if (len >= 12) {
          nB12++;
          if (len > maxLen12) maxLen12 = len;
          colors12.add(col);
          if (start < minX) minX = start;
          if (start + len > maxX) maxX = start + len;
        }
      }
    }
    final nw = nonWhite / w;
    // 行原型 A（经典色板行）；B 密集色条原型 v9 已删除（见库注释 2）
    final okA = nB12 >= 3 &&
        maxLen12 <= w * 0.35 &&
        (maxLen12 >= 60 || (colors12.length >= 3 && nw <= 0.75));
    feats[y] = RowFeat(
      nB8: nB8,
      nB12: nB12,
      maxLen8: maxLen8,
      maxLen12: maxLen12,
      maxLenAny: maxLenAny,
      nw: nw,
      minX: minX,
      maxX: maxX,
      dkX0: dkX0,
      dkX1: dkX1,
      dkMass: dkMass,
      blkX0: blkX0,
      blkX1: blkX1,
      colors12: colors12.length,
      sat8: sat8,
      ok: okA,
    );
  }

  final legendRows = <int, RowFeat>{
    for (final e in feats.entries)
      if (e.value.ok) e.key: e.value,
  };
  if (legendRows.isEmpty) {
    return null;
  }

  // --- 聚簇成带（图例行间白隙 <= 60px 同带） ---
  final ys = legendRows.keys.toList()..sort();
  final bands = <List<int>>[
    [ys.first, ys.first],
  ];
  for (final y in ys.skip(1)) {
    if (y - bands.last[1] <= 60) {
      bands.last[1] = y;
    } else {
      bands.add([y, y]);
    }
  }

  // --- quiet 闸：带缘 3 个采样行内任一行 nw<=0.35 即隔离 ---
  bool quietOutside(int edge, bool below) {
    for (final d in [_step, _step * 2, _step * 3]) {
      final y = below ? edge + d : edge - d;
      final f = feats[y];
      if (f == null) return true; // 出图
      if (f.nw <= 0.35) return true;
    }
    return false;
  }

  // --- 带分类：tall/gate/quiet/ok ---
  String kindOf(List<int> b) {
    final (b0, b1) = (b[0], b[1]);
    if (b1 - b0 > h * 0.20) return 'tall';
    if (b1 - b0 > h * 0.15) {
      final n = legendRows.entries
          .where((e) => e.key >= b0 && e.key <= b1)
          .length;
      final ratio = n / ((b1 - b0) / _step + 1);
      return ratio >= 0.5 ? 'ok' : 'gate';
    }
    return (quietOutside(b0, false) && quietOutside(b1, true)) ? 'ok' : 'quiet';
  }

  // --- 主体传播：tall 带为主体；主体上方 150px 内的带链同为主体 ---
  final subject = <List<int>>{};
  for (final b in bands.reversed) {
    final isSubject = kindOf(b) == 'tall' ||
        subject.any((s) => s[0] > b[1] && s[0] - b[1] <= 150);
    if (isSubject) subject.add(b);
  }

  // --- 打分取最优（跨度下限 + 饱和色打分 + 底部位次） ---
  var bestScore = -1.0;
  List<int>? bestBand;
  RectI? bestRect; // (minX, b0, maxX, b1)
  final infos = <LegendBandInfo>[];
  final notes = <String>[];
  for (final b in bands) {
    final (b0, b1) = (b[0], b[1]);
    final kind = kindOf(b);
    if (kind != 'ok') {
      infos.add(LegendBandInfo(b0, b1, kind, 0, 0, 0));
      continue;
    }
    if (subject.contains(b)) {
      infos.add(LegendBandInfo(b0, b1, 'fragment(subject below)', 0, 0, 0));
      continue;
    }
    final rows = [
      for (final e in legendRows.entries)
        if (e.key >= b0 && e.key <= b1) e.value,
    ];
    // 跨度下限：图例至少横跨板宽一成半（板内色斑碎片带仅 63px）
    var extMin = 1 << 30, extMax = -(1 << 30);
    for (final f in rows) {
      if (f.minX < extMin) extMin = f.minX;
      if (f.maxX > extMax) extMax = f.maxX;
    }
    if (extMax - extMin < (250 > w * 0.15 ? 250 : w * 0.15)) {
      infos.add(LegendBandInfo(b0, b1, 'extent=${extMax - extMin}', 0, 0, 0));
      continue;
    }
    var nSum = 0;
    final satColors = <int>{};
    for (final f in rows) {
      nSum += f.nB8;
      satColors.addAll(f.sat8);
    }
    final score = nSum + satColors.length * 15.0 + (b0 + b1) / 2 / h * 50;
    infos.add(LegendBandInfo(b0, b1, null, score, nSum, satColors.length));
    if (score > bestScore) {
      bestScore = score;
      bestBand = b;
      bestRect = RectI(extMin, b0, extMax, b1);
    }
  }
  if (bestBand == null || bestRect == null) {
    return null; // 全带被拒（对拍排障看 wx_replica6.py 的逐带明细）
  }

  // --- 带顶低饱和修剪：砍掉带首 sat<2 的行（列序文本行 sat=0） ---
  var (b0, b1) = (bestBand[0], bestBand[1]);
  var trimRows = [
    for (final e in legendRows.entries)
      if (e.key >= b0 && e.key <= b1) e.key,
  ];
  while (trimRows.length > 2 && feats[trimRows.first]!.sat8.length < 2) {
    trimRows = trimRows.sublist(1);
  }
  if (trimRows.first > b0) {
    notes.add('band-top $b0->${trimRows.first}');
    b0 = trimRows.first;
    var mn = 1 << 30, mx = -(1 << 30);
    for (final y in trimRows) {
      final f = feats[y]!;
      if (f.minX < mn) mn = f.minX;
      if (f.maxX > mx) mx = f.maxX;
    }
    bestRect = RectI(mn, b0, mx, b1);
  }

  // --- 强内容行判据（延续走共用） ---
  final bandW = bestRect.maxX - bestRect.minX;
  final minSpan = 120 > bandW * 0.10 ? 120 : (bandW * 0.10).toInt();
  bool strong(int y) {
    final f = feats[y];
    if (f == null) return false;
    if (f.ok) return true;
    if (f.nw > 0.60 || f.maxLenAny >= 200) return false;
    // denseWide：密而宽（文字簇，>=8 块跨度达标）
    if (f.nw >= 0.03 && f.blkX1 - f.blkX0 >= minSpan) return true;
    // darkText：深墨成字——跨度达标、质量 >=15px、填充率 0.10-0.75
    //（角水印跨度不足、实心块 ~1.0、稀疏尘 <0.10 均拦下）
    final ds = f.dkX1 - f.dkX0;
    return f.nw >= 0.01 &&
        ds >= minSpan &&
        f.dkMass >= 15 &&
        f.dkMass / (ds > 0 ? ds : 1) >= 0.10 &&
        f.dkMass / (ds > 0 ? ds : 1) <= 0.75;
  }

  // 行走行横向范围：优先实块 x12，文字行退回深墨 dkX，再退 >=8 块 blkX
  (int, int)? extOf(int y) {
    final f = feats[y]!;
    if (f.minX < 1 << 30) return (f.minX, f.maxX);
    if (f.dkX0 < 1 << 30) return (f.dkX0, f.dkX1);
    if (f.blkX0 < 1 << 30) return (f.blkX0, f.blkX1);
    return null;
  }

  // --- 薄带上行走（带高 <24px）：收编上方紧贴的表格文字行 ---
  final thin = b1 - b0 < 24;
  var upTop = b0;
  var walkL = 1 << 30, walkR = -(1 << 30);
  if (thin) {
    var cleanU = 0;
    // 上走距离上限 40px：收编的是「紧贴」的文字行（u2 实测 22px）；无上限
    // 时弱墨保持会爬穿板底与图例间的稀疏噪声带百像素级（u1 纯 Dart 解码
    // 1296->1132 走 164px，把板底列序/暗影全吞进框）
    final floor = (b0 - 40).clamp(0, h - 1);
    for (var y = b0 - _step; y >= floor; y -= _step) {
      if (strong(y)) {
        upTop = y;
        final e = extOf(y);
        if (e != null) {
          if (e.$1 < walkL) walkL = e.$1;
          if (e.$2 > walkR) walkR = e.$2;
        }
        cleanU = 0;
        continue;
      }
      final f = feats[y];
      if (f != null && f.nw >= 0.03) {
        cleanU = 0; // 弱墨行保持行走
        continue;
      }
      cleanU += _step;
      if (cleanU > 6) break; // 净白隙止步（不前瞻——上方贴着列序尺）
    }
    if (upTop < b0) notes.add('upwalk $b0->$upTop');
  }

  // --- 向下延续走：强行推进底边，弱墨行保持，白隙靠前瞻 20px 跳接 ---
  var lastStrong = b1;
  var clean = 0;
  final limit =
      (b1 + (h * 0.12 < 200 ? h * 0.12 : 200)).toInt().clamp(0, h - 1).toInt();
  for (var y = b1 + _step; y <= limit; y += _step) {
    if (strong(y)) {
      lastStrong = y;
      clean = 0;
      continue;
    }
    final f = feats[y];
    final nw = f?.nw ?? 0.0;
    if (nw >= 0.03) {
      clean = 0; // 弱墨行（淡影/角页码）保持行走不推进
      continue;
    }
    clean += _step;
    if (clean > 6) {
      // 前瞻 20px：有强内容行则跳接，无则止步
      var jumped = false;
      for (var y2 = y + _step;
          y2 <= (y + 20 < limit ? y + 20 : limit);
          y2 += _step) {
        if (strong(y2)) {
          y = y2;
          lastStrong = y2; // 跳接行本身是强行（Python 版下一轮会重处理它）
          jumped = true;
          break;
        }
      }
      if (!jumped) break;
      clean = 0;
    }
  }

  // --- 最终矩形 ---
  var l = bestRect.minX, t = bestRect.top, r = bestRect.maxX;
  final bottom =
      (lastStrong + 10 + _step) < h ? lastStrong + 10 + _step : h;
  if (thin && walkL < 1 << 30) {
    // 薄带框横向只盖住色片段——并集上走文字行的深墨范围才盖全表
    if (walkL < l) l = walkL;
    if (walkR > r) r = walkR;
    t = upTop;
  }
  l = (l - 14).clamp(0, w).toInt();
  r = (r + 14).clamp(0, w).toInt();
  // 自适应顶垫边：紧邻上一行干净=有白隙垫10，有墨=贴豆板垫4
  final above = feats[t - _step];
  final padT = (above != null && above.nw >= 0.01) ? 4 : 10;
  t = (t - padT).clamp(0, h).toInt();
  if (lastStrong > b1) {
    notes.add('bottom ${b1 + 10 + _step}->$bottom');
  }
  return LegendDetectResult(
    l,
    t,
    r,
    bottom,
    bestScore,
    infos,
    notes,
  );
}

/// 归一化入口：绝对像素阈值（>=8/12 游程桶、15px 墨质量、250px 跨度
/// 下限、14px 补边）随分辨率漂移——超窗宽度先缩放到 1440 宽检测，再把
/// 矩形映射回原图坐标。
///
/// **native 优先窗口 [1000, 2048]**（fleet 实证 wx1@1920：缩放到 1440 后
/// 豆板格线（~3px）被 LANCZOS 涂掉，板内 bead 游程两两合并越过 12px 桶，
/// 原本把板体切成多带的格线行集体过原型 A，全图连成一个 tall 巨带吞掉
/// 图例带 → null；native 下格线行 nB12=0 正确切带。缩放对细格线纹理是
/// 破坏性操作，行级无法补救）。窗口内主流截图宽 1080/1280/1440/1920 已
/// 全部 native 验证通过；窗外小图（缩略图）与超大图（相机原片）仍缩放。
LegendDetectResult? detectLegendCanonical(img.Image image) {
  const canon = 1440;
  final w = image.width;
  if (w >= 1000 && w <= 2048) {
    return detectLegend(image);
  }
  final scaled = img.copyResize(image, width: canon);
  final r = detectLegend(scaled);
  if (r == null) return null;
  final sx = w / scaled.width, sy = image.height / scaled.height;
  return LegendDetectResult(
    (r.left * sx).round().clamp(0, w).toInt(),
    (r.top * sy).round().clamp(0, image.height).toInt(),
    (r.right * sx).round().clamp(0, w).toInt(),
    (r.bottom * sy).round().clamp(0, image.height).toInt(),
    r.score,
    r.bands,
    r.notes,
  );
}

/// 内部用轻量整数矩形（minX/top/maxX/bottom）
class RectI {
  final int minX, top, maxX, bottom;
  const RectI(this.minX, this.top, this.maxX, this.bottom);
}
