/// 豆板画布渲染器：板底格 + 相位加粗框线 + 多作品叠加（各带偏移）+ 拼装标记 +
/// 格子文字层（色号文本 / 高亮色行·列分组编号）
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/board_config.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';

/// 拼豆页格子文字层模式
enum LabelMode {
  /// 只显示色号（默认）
  id,

  /// 选中色号横向排列：同一板行内从左到右连续段编号 1,2,3…（每行重数；
  /// 段内被其他色号/空白隔断时重新从 1 起）
  rowNumber,

  /// 选中色号竖向排列：同一板列内从上到下连续段编号 1,2,3…（每列重数；
  /// 段内被其他色号/空白隔断时重新从 1 起）
  colNumber,
}

/// 画布上的一件渲染项（配置页/拼豆页共用）
class BoardPaintItem {
  final PatternModel model;

  ///< 作品图案
  final BeadPalette palette;

  ///< 渲染调色板（索引与 model.grid 对应）
  final int ox;

  ///< 左上角在板上的列偏移
  final int oy;

  ///< 左上角在板上的行偏移
  final String? highlightId;

  ///< 高亮色号（null = 关闭；其余色降饱和显示）
  final bool dimAll;

  ///< 整体压灰（拼豆页按作品方案的范围外作品：无高亮色可配对，
  ///< 所有格按未选中同款幅度向深灰混，与高亮中未选中豆观感一致）
  final Set<int>? placedCells;

  ///< 拼装已放格（本作品格扁平索引；null = 关闭）
  final Set<int>? pendingCells;

  ///< 批量完成待确认格（长按滑动圈选，松手确认前以高亮框显示；
  ///< 本作品格扁平索引；null/空 = 无）
  final bool showBorder;

  ///< 画作品边框（配置页开 / 拼豆页关）
  final bool selected;

  ///< 选中态（边框加粗蓝；配置页）
  final bool showClose;

  ///< 画右上角删除叉（仅配置页选中作品开 / 拼豆页关）

  const BoardPaintItem({
    required this.model,
    required this.palette,
    required this.ox,
    required this.oy,
    this.highlightId,
    this.dimAll = false,
    this.placedCells,
    this.pendingCells,
    this.showBorder = false,
    this.selected = false,
    this.showClose = false,
  });
}

class BoardPainter extends CustomPainter {
  final BoardConfig board;

  ///< 板配置（尺寸/加粗间隔/相位/粗线颜色；ox/oy 由各 item 自带）
  final List<BoardPaintItem> items;

  ///< 叠加的作品列表（后加入的画在上层）
  final LabelMode labelMode;

  ///< 格子文字层模式（拼豆页用；配置页保持默认只色号）
  final bool showLabels;

  ///< 是否绘制格子文字层（拼豆页开 / 配置页关，摆放时看色块即可）
  final bool showNonHiLabels;

  ///< 是否绘制未选中（非高亮）格的色号文本：高亮中可关掉只留选中色
  ///< 的编号降噪；无高亮时关掉 = 纯色块净板视图
  final double viewScale;

  ///< 当前视图缩放倍数（无 ctrl 时的静态取值：格线/对勾线宽补偿用）
  final TransformationController? ctrl;

  ///< 视图变换控制器（拼豆页传入）：paint 实时读缩放做线宽补偿，并
  ///< 以它为 repaint 监听——捏合/缩放条只改矩阵不 setState，构建时
  ///< 定格的 scale 会停在旧值（格线跟着图变粗挡内容）。配置页不传
  ///<（手势期 setState 跟随刷新 viewScale）
  static final Map<String, TextPainter> _labelCache = {};

  /// 文本排版宽度缓存（fontSize=24 下的像素宽，线性度量）：统一字号
  /// 换算用；同文本恒定
  static final Map<String, double> _emWidCache = {};

  /// 量 [text] 在 fontSize 24 / w600 下的排版宽——供统一字号换算
  ///（px = 目标宽 × 24 / 宽度），结果缓存
  static double _textWid24(String text) {
    var w = _emWidCache[text];
    if (w == null) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      w = tp.width;
      if (_emWidCache.length > 2000) {
        _emWidCache.clear();
      }
      _emWidCache[text] = w;
    }
    return w;
  }

  ///< 文字绘制缓存（painter 每 build 新建，缓存须跨实例共享；key 含文本+字号+颜色）

  ///< 高亮模式的板底/压暗豆共同基色：接近黑色的深冷灰 slate-700
  ///<（亮度 ~64）。豆色按 0.75 幅度向它混——未选中整体沉到亮度
  ///< ~55-110 深灰区（保留 25% 色相隐约可辨），选中色以全彩跳出，
  ///< 差异一眼可辨；文字仍按 0.5 幅度混保持可读
  static const _dimGray = Color(0xFF374151);

  BoardPainter({
    required this.board,
    required this.items,
    this.labelMode = LabelMode.id,
    this.showLabels = false,
    this.showNonHiLabels = true,
    this.viewScale = 1.0,
    TransformationController? ctrl,
  })  : ctrl = ctrl,
        super(repaint: ctrl);

  /// 线宽补偿用视图缩放：ctrl 实时值优先，无 ctrl 回落构建时的
  /// viewScale（配置页路径）
  double get _scale => ctrl?.value.getMaxScaleOnAxis() ?? viewScale;

  /// 高亮色的行/列分组编号：key = itemIdx*1e7 + cellIdx
  Map<int, int> _buildNumbers() {
    if (items.isEmpty) {
      return const {};
    }
    // 按作品方案下各 item 的 highlightId 可不同（范围内才有）——取第一个
    // 非空的作高亮色号
    String? hi;
    for (final e in items) {
      if (e.highlightId != null) {
        hi = e.highlightId;
        break;
      }
    }
    if (hi == null) {
      return const {};
    }
    // 收集 (板x, 板y, key)，按模式分组编号（跨作品统一板坐标）
    final cells = <(int, int, int)>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.highlightId != hi) {
        continue; // 未参与当前高亮（无高亮/按作品方案的范围外作品）
      }
      final m = item.model;
      for (var c = 0; c < m.grid.length; c++) {
        final v = m.grid[c];
        if (v < 0 || v >= item.palette.colors.length) {
          continue;
        }
        if (item.palette.colors[v].id == hi) {
          cells.add((
            item.ox + c % m.width,
            item.oy + c ~/ m.width,
            i * 10000000 + c
          ));
        }
      }
    }
    final byRow = labelMode == LabelMode.rowNumber;
    cells.sort((a, b) => byRow
        ? (a.$2 == b.$2 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2))
        : (a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1)));
    final numbers = <int, int>{};
    var groupKey = -1;
    var n = 0;
    var prevBx = -1, prevBy = -1;
    for (final (bx, by, key) in cells) {
      final g = byRow ? by : bx;
      // 同组内还须与前一格紧邻（横向=同行右邻 / 竖向=同列下邻）；
      // 被其他色号或空白隔断时重新从 1 起排（间隔计数：B1 B1 B1 B2 B2
      // B1 B1 B1 -> 1 2 3 B2 B2 1 2 3）
      final contiguous = byRow
          ? (by == prevBy && bx == prevBx + 1)
          : (bx == prevBx && by == prevBy + 1);
      if (g != groupKey || !contiguous) {
        groupKey = g;
        n = 0;
      }
      n++;
      numbers[key] = n;
      prevBx = bx;
      prevBy = by;
    }
    return numbers;
  }

  /// 画格子文字（色号/编号），TextPainter 按内容+有效字号+颜色缓存
  ///
  /// 字号 [px] 由调用方统一算好（全板最宽码收进 0.88 格宽，见 paint()
  /// 文字层；所有标签同大小，2026-11-11 用户反馈按码长各自缩参差）。
  /// [light] 豆底亮度判浅（自适应模式选黑白字用）；[dimmed] = 高亮中
  /// 未选中色的格：字色向共同基色轻混 0.15 退后一点（早期 0.5 会把字
  /// 洗成与压暗底只差 ~1.9:1 的灰白——2026-11-10 用户反馈「H2 白字
  /// 根本看不见」的实锤，0.15 后对比 ~4:1 仍可读）。
  ///
  /// 锐度：画布处于视图缩放变换下，直接按格子字号画会被先栅格化再经
  /// 变换拉伸——放大后是一团均匀色带（实测 5.4× 下黑字没有任何深色
  /// 核心）。以格中心为锚先 scale(1/s) 回屏幕分辨率、按有效字号
  /// effPx=px*s 栅格化，视觉尺寸不变、任意缩放下锐利。
  void _drawLabel(
    Canvas canvas,
    String text,
    Rect rect,
    double px,
    bool light, {
    bool dimmed = false,
  }) {
    if (text.isEmpty) {
      return;
    }
    // 字色统一自适应（2026-11-11 用户定稿：全黑/全白档移除，三档选择器
    // 从拼豆页撤下）——浅豆黑字/深豆白字，对比度法判深浅（beadLabelDark）
    var color = light ? Colors.black87 : Colors.white;
    if (dimmed) {
      color = Color.lerp(color, _dimGray, 0.15)!;
    }
    final s = _scale;
    final effPx = (px * s * 2).roundToDouble() / 2;
    final key = "$text|$effPx|${color.toARGB32()}";
    if (_labelCache.length > 600) {
      _labelCache.clear(); // 捏合连续缩放会生成大量中间档，防缓存无界
    }
    var tp = _labelCache[key];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
              fontSize: effPx, color: color, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _labelCache[key] = tp;
    }
    final center = rect.center;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1 / s);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / board.w;
    final cellH = size.height / board.h;
    // 视图缩放（格线/对勾线宽补偿基准，见 _scale 注释）
    final scale = _scale;
    final numbers =
        (labelMode != LabelMode.id && items.any((e) => e.highlightId != null))
            ? _buildNumbers()
            : const <int, int>{};

    // 板底：无高亮 = 白（空白格必须白底，不沉底变黑）；高亮中 = 中灰
    //（空白区与其他色号豆一起变灰衬托选中色）。任一 item 带高亮即算
    //（按作品方案下仅范围内作品有）
    final hiOn = items.any((e) => e.highlightId != null);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = hiOn ? _dimGray : const Color(0xFFFAFAFA),
    );

    // 各作品格（板外部分画布自裁；越界索引/调色板缺失跳过）
    final gridPaint = Paint()..style = PaintingStyle.fill;
    final dimmedCells = <int>{};
    for (var itemIdx = 0; itemIdx < items.length; itemIdx++) {
      final item = items[itemIdx];
      final m = item.model;
      for (var y = 0; y < m.height; y++) {
        for (var x = 0; x < m.width; x++) {
          final v = m.grid[y * m.width + x];
          if (v < 0 || v >= item.palette.colors.length) {
            continue;
          }
          final c = item.palette.colors[v];
          var color = Color.fromARGB(255, c.r, c.g, c.b);
          if (item.dimAll ||
              item.highlightId != null && c.id != item.highlightId) {
            // 未选中豆大比例向深灰混（0.75：整体沉到深灰区衬托选中色，
            // 残留 25% 色相隐约可辨；早期 lerp 黑 0.78 连色相带层次全灭）
            color = Color.lerp(color, _dimGray, 0.75)!;
            dimmedCells.add(itemIdx * 10000000 + y * m.width + x);
          }
          gridPaint.color = color;
          final rect = Rect.fromLTWH(
            (item.ox + x) * cellW,
            (item.oy + y) * cellH,
            cellW,
            cellH,
          );
          canvas.drawRect(rect, gridPaint);
        }
      }
    }

    // 重叠标注：同一板格被两件作品同时占豆（两边都非空格）才铺浅红——
    // 豆级判定，空豆位置的交叠不标也不拦开始拼豆；超板悬挂部分只在板内
    // 标注。画在豆色块之后、格线/文字之前，豆色仍从半透明下透出可辨
    if (items.length > 1) {
      final overlapPaint = Paint()
        ..color = const Color(0xFFFFCDD2).withValues(alpha: 0.55)
        ..style = PaintingStyle.fill;
      for (var i = 0; i < items.length; i++) {
        for (var j = i + 1; j < items.length; j++) {
          final a = items[i], b = items[j];
          final x0 = math.max(math.max(a.ox, b.ox), 0);
          final y0 = math.max(math.max(a.oy, b.oy), 0);
          final x1 = math.min(
            math.min(a.ox + a.model.width, b.ox + b.model.width),
            board.w,
          );
          final y1 = math.min(
            math.min(a.oy + a.model.height, b.oy + b.model.height),
            board.h,
          );
          for (var by = y0; by < y1; by++) {
            for (var bx = x0; bx < x1; bx++) {
              final av =
                  a.model.grid[(by - a.oy) * a.model.width + (bx - a.ox)];
              final bv =
                  b.model.grid[(by - b.oy) * b.model.width + (bx - b.ox)];
              if (av >= 0 && bv >= 0) {
                canvas.drawRect(
                  Rect.fromLTWH(bx * cellW, by * cellH, cellW, cellH),
                  overlapPaint,
                );
              }
            }
          }
        }
      }
    }

    // 细格线全长（灰底上略加深保证可见）；interval 加粗线单独挪到豆色块/
    // 文字层之后画（见下），避免被豆的颜色压掉。线宽随视图缩放补偿
    //（除以 scale）：参考线只作定位用，画布放大后跟着变粗会盖住豆色/
    // 文字（用户反馈挡显示），补偿后视觉恒定细线
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5 / scale
      ..color = hiOn ? Colors.black26 : Colors.black12;
    for (var x = 0; x <= board.w; x++) {
      final p = x * cellW;
      canvas.drawLine(Offset(p, 0), Offset(p, size.height), linePaint);
    }
    for (var y = 0; y <= board.h; y++) {
      final p = y * cellH;
      canvas.drawLine(Offset(0, p), Offset(size.width, p), linePaint);
    }

    // 文字层：默认每格显示色号；高亮 + 编号模式时高亮格改为行/列分组编号
    if (showLabels) {
      // 统一字号：以「本板全部作品调色板最宽色号（编号模式再含最宽
      // 编号）收进 0.88 格宽」为准，所有标签同大小——按码长各自缩会
      // 两位码大三位码小，混排参差（2026-11-11 用户二连反馈）。上限
      // 仍是经典 0.58×格宽：纯两位码板维持原大小不放大。
      var worst24 = 0.0;
      for (final item in items) {
        for (final c in item.palette.colors) {
          final w = _textWid24(c.id);
          if (w > worst24) {
            worst24 = w;
          }
        }
      }
      if (labelMode != LabelMode.id) {
        for (final v in numbers.values) {
          final w = _textWid24("$v");
          if (w > worst24) {
            worst24 = w;
          }
        }
      }
      final basePx = (cellW * 0.58).clamp(1.0, 13.0);
      final labelPx =
          worst24 > 0 ? math.min(basePx, cellW * 0.88 * 24 / worst24) : basePx;
      for (var itemIdx = 0; itemIdx < items.length; itemIdx++) {
        final item = items[itemIdx];
        final m = item.model;
        for (var y = 0; y < m.height; y++) {
          for (var x = 0; x < m.width; x++) {
            final v = m.grid[y * m.width + x];
            if (v < 0 || v >= item.palette.colors.length) {
              continue;
            }
            final c = item.palette.colors[v];
            final isHi = item.highlightId != null && c.id == item.highlightId;
            if (!isHi && !showNonHiLabels) {
              continue; // 只看色块：未选中格不画色号文本
            }
            final key = itemIdx * 10000000 + y * m.width + x;
            final text =
                (isHi && numbers.containsKey(key)) ? "${numbers[key]}" : c.id;
            // 压暗格字色按混合后的实际底色判深浅（与豆底同款 0.75 混合
            // 幅度；混后原色深浅大体保留，深字浅底/浅字深底仍然成立）。
            // 判法改 WCAG 黑白对比度取高（beadLabelDark）：旧亮度阈值
            // >150 把 M2 类浅灰米色判深出白字，浅底白字看不见
            //（2026-11-10 用户反馈自适应没生效）
            final base = dimmedCells.contains(key)
                ? Color.lerp(
                    Color.fromARGB(255, c.r, c.g, c.b),
                    _dimGray,
                    0.75,
                  )!
                : Color.fromARGB(255, c.r, c.g, c.b);
            final light = beadLabelDark(base);
            _drawLabel(
              canvas,
              text,
              Rect.fromLTWH(
                (item.ox + x) * cellW,
                (item.oy + y) * cellH,
                cellW,
                cellH,
              ),
              labelPx,
              light,
              dimmed: dimmedCells.contains(key),
            );
          }
        }
      }
    }

    // 拼装已放格：绿对勾常显；「变浅」白罩只在选中该豆色时施加于该色
    // 的已放格——未选色时全部已放格保持原豆色+对勾（2026-11-11 用户
    // 反馈：已放格一律变浅后区分度太低；变浅是「选中色核对已放」的
    // 专属效果）。选其他色时，非选中色的已放格随整体压暗即可
    for (final item in items) {
      final placed = item.placedCells;
      final m = item.model;
      if (placed == null || placed.isEmpty) {
        continue;
      }
      final hi = item.highlightId;
      final veil = Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..style = PaintingStyle.fill;
      final check = Paint()
        ..color = const Color(0xFF2E7D32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 / scale
        ..strokeCap = StrokeCap.round;
      for (final i in placed) {
        if (i < 0 || i >= m.grid.length || m.grid[i] < 0) {
          continue;
        }
        final x = i % m.width, y = i ~/ m.width;
        final rect = Rect.fromLTWH(
          (item.ox + x) * cellW,
          (item.oy + y) * cellH,
          cellW,
          cellH,
        );
        // 白罩仅：有选中色 且 该格豆色 == 选中色（调色板索引越界不算）
        final v = m.grid[i];
        if (hi != null &&
            v >= 0 &&
            v < m.paletteIds.length &&
            m.paletteIds[v] == hi) {
          canvas.drawRect(rect, veil);
        }
        final cx = rect.center.dx, cy = rect.center.dy;
        canvas.drawLine(
          Offset(cx - cellW * 0.22, cy),
          Offset(cx - cellW * 0.05, cy + cellH * 0.2),
          check,
        );
        canvas.drawLine(
          Offset(cx - cellW * 0.05, cy + cellH * 0.2),
          Offset(cx + cellW * 0.28, cy - cellH * 0.2),
          check,
        );
      }
    }

    // 批量完成待确认格（长按滑动圈选，松手弹确认前）：蓝色高亮框 +
    // 半透明蓝罩——与已放的「白罩+绿勾」和未放的纯豆色都拉开对比，
    // 松手后「将变为已完成」与「旧已完成」一眼可辨（2026-11-11 需求）
    for (final item in items) {
      final pending = item.pendingCells;
      final m = item.model;
      if (pending == null || pending.isEmpty) {
        continue;
      }
      final fill = Paint()
        ..color = const Color(0xFF1976D2).withValues(alpha: 0.38)
        ..style = PaintingStyle.fill;
      final ring = Paint()
        ..color = const Color(0xFF1565C0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 / scale;
      for (final i in pending) {
        if (i < 0 || i >= m.grid.length || m.grid[i] < 0) {
          continue;
        }
        final rect = Rect.fromLTWH(
          (item.ox + i % m.width) * cellW,
          (item.oy + i ~/ m.width) * cellH,
          cellW,
          cellH,
        );
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect.deflate(0.8 / scale), ring);
      }
    }

    // interval 加粗线 + 板最外边框（顶层：豆色块/文字/已放标记之后画，
    // 不被豆的颜色压掉）。粗线颜色可配（板配置页色板入口，随板持久化），
    // 默认橙一类亮色——深色豆上压得住；板外框深黑（浅底/灰底均可见）。
    // 线宽随缩放补偿 + 整体调细（1.5→1.2）：加粗线只是数格定位参考，
    // 比细线醒目即可，粗了在放大视角下盖豆（用户反馈挡显示）
    final majorColor = Color(board.majorColor ?? BoardConfig.defaultMajorColor);
    final majorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / scale
      ..color = majorColor;
    final iv = board.interval;
    for (var x = 0; x <= board.w; x++) {
      if ((x + board.phaseX) % iv == 0) {
        final p = x * cellW;
        canvas.drawLine(Offset(p, 0), Offset(p, size.height), majorPaint);
      }
    }
    for (var y = 0; y <= board.h; y++) {
      if ((y + board.phaseY) % iv == 0) {
        final p = y * cellH;
        canvas.drawLine(Offset(0, p), Offset(size.width, p), majorPaint);
      }
    }
    final boardBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2 / scale
      ..color = Colors.black87;
    canvas.drawRect(Offset.zero & size, boardBorder);

    // 作品边框（豆板配置页）：选中加粗蓝，未选中细灰
    for (final item in items) {
      if (!item.showBorder) {
        continue;
      }
      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = item.selected ? 3 : 1
        ..color = item.selected ? Colors.blue : Colors.black26;
      canvas.drawRect(
        Rect.fromLTWH(
          item.ox * cellW,
          item.oy * cellH,
          item.model.width * cellW,
          item.model.height * cellH,
        ),
        border,
      );
    }

    // 作品右上角删除叉（豆板配置页，仅选中作品）：白底红圈圆钮压在作品
    // 右上角顶点上，所有作品层画完后统一画保证浮在最上层；
    // 尺寸/线宽按视图缩放补偿（放大后视觉恒定），命中检测在页层同款换算
    for (final item in items) {
      if (!item.showClose) {
        continue;
      }
      final center = Offset(
        (item.ox + item.model.width) * cellW,
        item.oy * cellH,
      );
      final r = 13.0 / scale;
      final ring = Paint()
        ..color = const Color(0xFFC62828)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 / scale;
      canvas.drawCircle(center, r, Paint()..color = Colors.white);
      canvas.drawCircle(center, r, ring);
      final s = r * 0.5;
      final cross = Paint()
        ..color = const Color(0xFFC62828)
        ..strokeWidth = 2.2 / scale
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(center.dx - s, center.dy - s),
        Offset(center.dx + s, center.dy + s),
        cross,
      );
      canvas.drawLine(
        Offset(center.dx - s, center.dy + s),
        Offset(center.dx + s, center.dy - s),
        cross,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) {
    return oldDelegate.board != board ||
        oldDelegate.labelMode != labelMode ||
        oldDelegate.showLabels != showLabels ||
        oldDelegate.showNonHiLabels != showNonHiLabels ||
        oldDelegate.viewScale != viewScale ||
        oldDelegate.items.length != items.length ||
        oldDelegate.items != items;
  }
}
