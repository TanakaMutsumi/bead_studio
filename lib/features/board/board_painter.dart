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
  final bool dimScope;

  ///< 单件口径的范围外作品（未选色时整件略灰——含已放格与对勾，
  ///<「当前拼哪件」一眼可辨；选色后由 dimAll 接管更强压暗。
  ///< 2026-11-12 用户反馈：未放豆退后上线后未选色态范围内/外都按
  ///< 各自进度退后，作品间的区分没了）
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
    this.dimScope = false,
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
  final bool showMajorLines;

  ///< 是否画 interval 加粗分割线（板设置/拼豆页开——数格定位参考；
  ///< 选择页缩略图关——小尺寸下粗网格满屏遮挡作品，2026-11-12 反馈。
  ///< 板最外边框不受此开关影响）
  final bool thumbnail;

  ///< 缩略图模式（豆板选择页，2026-11-12 需求）：去板底填色（透明底）
  ///< + 去全部格线（细线与加粗线同 showMajorLines=false 一并关——
  ///< 豆板原图只留作品色块），板最外框换浅黑细线（black38）。红标等
  ///< item 层标注不受影响照画
  final int padL, padT, padR, padB;

  ///< 画布四侧的板外余量（格数，boardPads 算实际悬挂量）：作品悬挂出板
  ///< 的部分画在这里。CustomPaint 越界绘制会被画布 cull 矩形裁掉
  ///<（2026-11-12 设备实勘：悬挂带纯背景色零像素），必须把余量算进
  ///< 画布尺寸、原点平移到板左上角。全 0 = 画布即板（拼豆页/无悬挂态），
  ///< 行为与旧版完全一致
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

  ///< 未选色（高亮关）且该作品有拼豆进度时，**已放豆**的退后基色：
  ///< 中性冷灰（比 _dimGray 亮一档）。已放豆色按 0.4 向它混、对勾同步
  ///< 变灰；未放豆保持原色醒目——「拼过的退场、还没拼的跳出」，视线
  ///< 自然落在待拼部分（2026-11-12 用户两轮定稿：先做「未放退后」后
  ///< 反转为此方向=任务视角）。取中性中灰而非 _dimGray：向深灰混对
  ///< 深色豆（H7 纯黑）几乎拉不开差，中灰对深浅两个方向都有明显差；
  ///< 0.4 幅度比高亮的 0.75 温和，色相仍可辨
  static const _idleGray = Color(0xFF8A93A3);

  ///< 圈选待确认格的默认 overlay：蓝色框+罩（蓝=「选中/待确认」的
  ///< UI 惯用色）
  static const _pendBlueRing = Color(0xFF1565C0);
  static const _pendBlueFill = Color(0xFF1976D2);

  ///< 底色偏蓝（如 C16 深蓝豆）时蓝框隐形 → 换琥珀色 overlay。蓝/琥珀
  ///< 两候选按 WCAG 对比度对底色取高（与色号黑白字 beadLabelDark 同
  ///< 思路；2026-11-12 用户反馈：C16 类蓝豆上圈选根本看不清）
  static const _pendAmberRing = Color(0xFFF57C00);
  static const _pendAmberFill = Color(0xFFF57C00);

  ///< 已放对勾三档（十九轮选色中层级重做）：选中色已放豆（填色层
  ///< 0.35 轻压暗）配**鲜艳绿**；非选中色已放豆（0.75 深压暗）配暗
  ///< 一档绿；亮度不足时 _checkOver 向白提亮保证「勾比豆本身亮」
  static const _checkVivid = Color(0xFF4CAF50);
  static const _checkDim = Color(0xFF2E7D32);

  ///< 未选色时的对勾：随已放豆退后混灰（0.45 保绿意，2026-11-12
  ///< 反转定稿维持）——勾底豆已向中灰退，亮度天然足够
  static final _checkIdle = Color.lerp(
    const Color(0xFF2E7D32),
    const Color(0xFF8A93A3),
    0.45,
  )!;

  /// 对勾绿按需提亮：勾必须比所在豆（混合后的实际底色）亮——浅色豆
  /// 压暗后仍偏亮（白豆 0.35 档 ≈ 185 亮度），固定绿会沉底看不清；
  /// 每次向白混 0.35 直到亮度高出底色 0.08（上限三步，最浅底色也够）
  static Color _checkOver(Color base, Color green) {
    final target = _luma(base) + 0.08;
    var c = green;
    for (var i = 0; i < 3 && _luma(c) <= target; i++) {
      c = Color.lerp(c, Colors.white, 0.35)!;
    }
    return c;
  }

  /// WCAG 相对亮度（palette#beadLabelDark 同式）。
  /// 【坑】Color.r/g/b 已是 0-1 浮点分量（旧 int API 时代写法是 v/255
  /// 再判 0.03928——迁移后等于把分量又除 255，所有颜色亮度恒 ~0.0002，
  /// 圈选蓝/琥珀比对在测试色上恰好同判才没暴露；十九轮勾色提亮依赖
  /// 真亮度才现形）——lin 直接吃 0-1 分量
  static double _luma(Color c) {
    double lin(double u) {
      return u <= 0.03928
          ? u / 12.92
          : math.pow((u + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  }

  /// 两色 WCAG 对比度（1 = 无差别；≥3 小格上已可辨）
  static double _contrast(Color a, Color b) {
    final la = _luma(a), lb = _luma(b);
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  BoardPainter({
    required this.board,
    required this.items,
    this.labelMode = LabelMode.id,
    this.showLabels = false,
    this.showNonHiLabels = true,
    this.viewScale = 1.0,
    this.showMajorLines = true,
    this.thumbnail = false,
    this.padL = 0,
    this.padT = 0,
    this.padR = 0,
    this.padB = 0,
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
    // 画布含板外余量（padL/padT/padR/padB，四侧各自实际悬挂量）：格尺寸
    // 按「板+四侧余量」全幅算，原点平移到板左上角——此后所有绘制仍用
    // 板坐标，与 pad=0 完全同式
    final cellW = size.width / (board.w + padL + padR);
    final cellH = size.height / (board.h + padT + padB);
    // 视图缩放（格线/对勾线宽补偿基准，见 _scale 注释）
    final scale = _scale;
    final numbers =
        (labelMode != LabelMode.id && items.any((e) => e.highlightId != null))
            ? _buildNumbers()
            : const <int, int>{};

    // 板底：无高亮 = 白（空白格必须白底，不沉底变黑）；高亮中 = 中灰
    //（空白区与其他色号豆一起变灰衬托选中色）。任一 item 带高亮即算
    //（按作品方案下仅范围内作品有）。只填板区——余量区保持透明，页面
    // 背景透出，板边界一眼可辨
    final hiOn = items.any((e) => e.highlightId != null);
    canvas.save();
    canvas.translate(padL * cellW, padT * cellH);
    // 板底：缩略图不填（透明底，卡片面透出即板界）
    if (!thumbnail) {
      canvas.drawRect(
        Offset.zero & Size(board.w * cellW, board.h * cellH),
        Paint()..color = hiOn ? _dimGray : const Color(0xFFFAFAFA),
      );
    }

    // 各作品格（板外部分画布自裁；越界索引/调色板缺失跳过）
    final gridPaint = Paint()..style = PaintingStyle.fill;
    final dimmedCells = <int>{};

    ///< 压暗/退后格集合（文字层随之退后）
    final cellBase = <int, Color>{};

    ///< 每格实际底色（含各种压暗混合），文字层判黑白字直接查表，
    ///<不再按「是否压暗」重新推一遍混合公式
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
          final key = itemIdx * 10000000 + y * m.width + x;
          final placed = item.placedCells;
          final cellIdx = y * m.width + x;
          final placedHere =
              placed != null && placed.isNotEmpty && placed.contains(cellIdx);
          if (item.dimAll ||
              item.highlightId != null && c.id != item.highlightId) {
            // 未选中豆大比例向深灰混（0.75：整体沉到深灰区衬托选中色，
            // 残留 25% 色相隐约可辨；早期 lerp 黑 0.78 连色相带层次全灭）
            color = Color.lerp(color, _dimGray, 0.75)!;
            dimmedCells.add(key);
          } else if (item.highlightId == null && item.dimScope) {
            // 单件口径范围外（未选色）：整件略灰——含已放格（与范围内
            // 的「已放原色跳出」拉开，「当前拼哪件」一眼可辨；幅度同
            // 未放退后 0.4，色相仍可辨）。选色后走上面 dimAll 0.75
            color = Color.lerp(color, _idleGray, 0.4)!;
            dimmedCells.add(key);
          } else if (item.highlightId == null && placedHere) {
            // 未选色且有进度：**已放豆**向中性灰轻混退后（对勾同步变
            // 灰），未放豆保持原色醒目——拼过的退场、待拼的跳出，视线
            // 落在还没拼的部分（2026-11-12 用户反转定稿；placedCells
            // 为空=无进度可对比，全板原色——板设置页/缩略图不受影响）
            color = Color.lerp(color, _idleGray, 0.4)!;
            dimmedCells.add(key);
          }
          cellBase[key] = color;
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

    // 冲突标注（2026-11-12 加深定稿：红罩+深红描边，浅红罩用户反馈不够
    // 醒目）——两类同款画法：①压豆重叠：同一板格被两件作品同时占豆
    //（两边都非空格），豆级判定，空豆位置的交叠不标也不拦开始拼豆，
    // 只在板内标注；②豆子出板：作品悬挂出界的非空白格（空白格出界
    // 不标也不拦）。都画在豆色块之后、格线/文字之前，豆色仍从半透明
    // 罩下透出可辨
    final conflictFill = Paint()
      ..color = const Color(0xFFE53935).withValues(alpha: 0.42)
      ..style = PaintingStyle.fill;
    final conflictStroke = Paint()
      ..color = const Color(0xFFB71C1C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / scale;
    void markCell(int bx, int by) {
      final rect = Rect.fromLTWH(bx * cellW, by * cellH, cellW, cellH);
      canvas.drawRect(rect, conflictFill);
      canvas.drawRect(rect.deflate(0.6 / scale), conflictStroke);
    }

    for (var i = 0; i < items.length; i++) {
      final a = items[i];
      // ② 豆子出板标注（悬挂部分照画——板设置页画布板外区域可见）
      final am = a.model;
      for (var y = 0; y < am.height; y++) {
        for (var x = 0; x < am.width; x++) {
          if (am.grid[y * am.width + x] < 0) {
            continue;
          }
          final bx = a.ox + x, by = a.oy + y;
          if (bx < 0 || bx >= board.w || by < 0 || by >= board.h) {
            markCell(bx, by);
          }
        }
      }
      // ① 压豆重叠标注
      for (var j = i + 1; j < items.length; j++) {
        final b = items[j];
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
            final av = a.model.grid[(by - a.oy) * a.model.width + (bx - a.ox)];
            final bv = b.model.grid[(by - b.oy) * b.model.width + (bx - b.ox)];
            if (av >= 0 && bv >= 0) {
              markCell(bx, by);
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
    if (!thumbnail) {
      for (var x = 0; x <= board.w; x++) {
        final p = x * cellW;
        canvas.drawLine(Offset(p, 0), Offset(p, board.h * cellH), linePaint);
      }
      for (var y = 0; y <= board.h; y++) {
        final p = y * cellH;
        canvas.drawLine(Offset(0, p), Offset(board.w * cellW, p), linePaint);
      }
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
            // 字色深浅按混合后的实际底色判（cellBase 已含 0.75 压暗与
            // 0.4 退后两种混合；混后原色深浅大体保留）。判法 WCAG 黑白
            // 对比度取高（beadLabelDark）：旧亮度阈值 >150 把 M2 类浅灰
            // 米色判深出白字，浅底白字看不见（2026-11-10 用户反馈）
            final base = cellBase[key] ?? Color.fromARGB(255, c.r, c.g, c.b);
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

    // 拼装已放格（选色中两档对比，2026-11-13 用户定稿）：
    // - 选中色的已放豆：**v1 白罩强对比回归**——半透明白罩 α0.5 整格
    //   提亮盖过豆色与色号（「强对比到不用显示色号都可以」，用户原
    //   话）+ 鲜艳绿勾（白底上绿勾本身清晰，不再向白提亮）；
    // - 非选中色的已放豆（选色中）：填色层 0.75 深压暗 + 暗一档绿勾
    //   （勾亮度不足时向白提亮，保证比豆本身亮）；
    // - 未选色时：已放豆整体向 _idleGray 退后（见填色层），对勾同步
    //   混灰退场（0.45 保绿意可辨，2026-11-12 反转定稿，维持）
    for (var itemIdx = 0; itemIdx < items.length; itemIdx++) {
      final item = items[itemIdx];
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
        final v = m.grid[i];
        final sel = hi != null &&
            v >= 0 &&
            v < m.paletteIds.length &&
            m.paletteIds[v] == hi;
        if (hi == null) {
          // 未选色：对勾随已放豆混灰退场（勾底为豆退后色，亮度足够）
          check.color = _checkIdle;
        } else if (sel) {
          // 选中色已放：v1 白罩整格提亮（盖住色号标签）+ 鲜艳绿勾
          canvas.drawRect(rect, veil);
          check.color = _checkVivid;
        } else {
          // 非选中色已放：暗一档绿，不足比豆亮时向白提亮
          final base = cellBase[itemIdx * 10000000 + i] ??
              Color.fromARGB(
                255,
                item.palette.colors[v].r,
                item.palette.colors[v].g,
                item.palette.colors[v].b,
              );
          check.color = _checkOver(base, _checkDim);
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

    // 批量完成待确认格（长按滑动圈选，松手确认前）：高亮框 + 半透明
    // 罩，与已放的「白罩+绿勾」和未放的纯豆色都拉开对比。overlay 色
    // **按该格底色自适应**：蓝/琥珀两候选按 WCAG 对比度取高——蓝豆
    //（C16 类）/深色底上蓝框隐形换琥珀，浅色底保持蓝（2026-11-12
    // 用户反馈圈选在蓝豆上看不清；思路同色号黑白字自适应）
    for (var itemIdx = 0; itemIdx < items.length; itemIdx++) {
      final item = items[itemIdx];
      final pending = item.pendingCells;
      final m = item.model;
      if (pending == null || pending.isEmpty) {
        continue;
      }
      for (final i in pending) {
        if (i < 0 || i >= m.grid.length || m.grid[i] < 0) {
          continue;
        }
        final v = m.grid[i];
        final bead = item.palette.colors[v];

        ///< 底色=该格混合后实际观感（含高亮/退后混合；cellBase 未记
        ///<（理论上不发生）回落豆原色）
        final base = cellBase[itemIdx * 10000000 + i] ??
            Color.fromARGB(255, bead.r, bead.g, bead.b);
        final amber =
            _contrast(base, _pendAmberRing) > _contrast(base, _pendBlueRing);
        final fill = Paint()
          ..color = (amber ? _pendAmberFill : _pendBlueFill).withValues(
            alpha: amber ? 0.30 : 0.38,
          )
          ..style = PaintingStyle.fill;
        final ring = Paint()
          ..color = amber ? _pendAmberRing : _pendBlueRing
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0 / scale;
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
    // interval=0 = 无分割线（2026-11-12 需求：分割线下拉含「无」档）；
    // %0 会抛除零，必须守卫。majorColor 全透明（十八轮「不显示」档）=
    // 分块结构保留但不画线（拼豆页区块圈选仍按 interval 分块）
    if (showMajorLines && !thumbnail && iv > 0 && majorColor.a != 0) {
      for (var x = 0; x <= board.w; x++) {
        if ((x + board.phaseX) % iv == 0) {
          final p = x * cellW;
          canvas.drawLine(
            Offset(p, 0),
            Offset(p, board.h * cellH),
            majorPaint,
          );
        }
      }
      for (var y = 0; y <= board.h; y++) {
        if ((y + board.phaseY) % iv == 0) {
          final p = y * cellH;
          canvas.drawLine(
            Offset(0, p),
            Offset(board.w * cellW, p),
            majorPaint,
          );
        }
      }
    }
    // 板外框：常规深黑粗线；缩略图换浅黑细线（去格线后外框是唯一
    // 板界提示，太重会在小尺寸下压作品）
    final boardBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (thumbnail ? 1.2 : 2.2) / scale
      ..color = thumbnail ? Colors.black38 : Colors.black87;
    canvas.drawRect(
      Offset.zero & Size(board.w * cellW, board.h * cellH),
      boardBorder,
    );

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
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BoardPainter oldDelegate) {
    return oldDelegate.board != board ||
        oldDelegate.labelMode != labelMode ||
        oldDelegate.showLabels != showLabels ||
        oldDelegate.showNonHiLabels != showNonHiLabels ||
        oldDelegate.viewScale != viewScale ||
        oldDelegate.showMajorLines != showMajorLines ||
        oldDelegate.thumbnail != thumbnail ||
        oldDelegate.padL != padL ||
        oldDelegate.padT != padT ||
        oldDelegate.padR != padR ||
        oldDelegate.padB != padB ||
        oldDelegate.items.length != items.length ||
        oldDelegate.items != items;
  }
}
