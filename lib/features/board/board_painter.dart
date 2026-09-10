/// 豆板画布渲染器：板底格 + 相位加粗框线 + 多作品叠加（各带偏移）+ 拼装标记 +
/// 格子文字层（色号文本 / 高亮色行·列分组编号）
library;

import 'package:flutter/material.dart';

import '../../core/board_config.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';

/// 拼豆页格子文字层模式
enum LabelMode {
  /// 只显示色号（默认）
  id,

  /// 选中色号横向排列：同一板行内从左到右编号 1,2,3…（每行重数）
  rowNumber,

  /// 选中色号竖向排列：同一板列内从上到下编号 1,2,3…（每列重数）
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
  final Set<int>? placedCells;

  ///< 拼装已放格（本作品格扁平索引；null = 关闭）
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
    this.placedCells,
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
  final bool darkBoard;

  ///< 深底模式（拼豆页开 / 配置页关）：板底深色、细线浅色、板外框跟
  ///< 粗线色——高亮豆与粗参考线在深底上更醒目，空白格沉底不抢视线
  final double viewScale;

  ///< 当前视图缩放倍数（删除叉尺寸/线宽补偿用：画布放大后视觉恒定）
  static final Map<String, TextPainter> _labelCache = {};

  ///< 文字绘制缓存（painter 每 build 新建，缓存须跨实例共享；key 含文本+字号+颜色）

  BoardPainter({
    required this.board,
    required this.items,
    this.labelMode = LabelMode.id,
    this.showLabels = false,
    this.darkBoard = false,
    this.viewScale = 1.0,
    super.repaint,
  });

  /// 高亮色的行/列分组编号：key = itemIdx*1e7 + cellIdx
  Map<int, int> _buildNumbers() {
    if (items.isEmpty) {
      return const {};
    }
    final hi = items.first.highlightId;
    // 收集 (板x, 板y, key)，按模式分组编号（跨作品统一板坐标）
    final cells = <(int, int, int)>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.highlightId != hi) {
        continue; // 未开高亮（各 item 的 highlightId 一致）
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
    for (final (bx, by, key) in cells) {
      final g = byRow ? by : bx;
      if (g != groupKey) {
        groupKey = g;
        n = 0;
      }
      n++;
      numbers[key] = n;
    }
    return numbers;
  }

  /// 画格子文字（色号/编号），TextPainter 按内容+字号+颜色缓存
  ///
  /// 字号跟随格子尺寸（无下限）：小格子字小，画布放大后矢量渲染依然清晰
  void _drawLabel(Canvas canvas, String text, Rect rect, bool light) {
    if (text.isEmpty) {
      return;
    }
    final px = ((rect.width * 0.58).clamp(1.0, 13.0) * 2).roundToDouble() / 2;
    final color = light ? Colors.black87 : Colors.white;
    final key = "$text|$px|${color.value}";
    var tp = _labelCache[key];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
              fontSize: px, color: color, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _labelCache[key] = tp;
    }
    tp.paint(canvas,
        Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / board.w;
    final cellH = size.height / board.h;
    final numbers =
        (labelMode != LabelMode.id && items.any((e) => e.highlightId != null))
            ? _buildNumbers()
            : const <int, int>{};

    // 板底（深底模式：空白格沉底变黑，高亮豆更突出）
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = darkBoard ? const Color(0xFF1E1E1E) : const Color(0xFFFAFAFA),
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
          if (item.highlightId != null && c.id != item.highlightId) {
            // 未选中豆整体压黑（拼豆页高亮模式）：色相残留可见但足够暗，
            // 与深板底一起把选中色衬出来；记下被压暗格，文字层换浅色字
            color = Color.lerp(color, Colors.black, 0.78)!;
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

    // 细格线全长（深底上换浅色才可见）；interval 加粗线单独挪到豆色块/
    // 文字层之后画（见下），避免被豆的颜色压掉
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = darkBoard ? Colors.white12 : Colors.black12;
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
            final key = itemIdx * 10000000 + y * m.width + x;
            final text =
                (isHi && numbers.containsKey(key)) ? "${numbers[key]}" : c.id;
            // 被压暗的格子豆色已近黑，原色深浅判定失效——强制浅色字
            final light = !dimmedCells.contains(key) &&
                c.r * 0.299 + c.g * 0.587 + c.b * 0.114 > 150;
            _drawLabel(
              canvas,
              text,
              Rect.fromLTWH(
                (item.ox + x) * cellW,
                (item.oy + y) * cellH,
                cellW,
                cellH,
              ),
              light,
            );
          }
        }
      }
    }

    // 拼装已放格：半透明白罩 + 绿对勾（EditorPage 拼装标记同款观感）
    for (final item in items) {
      final placed = item.placedCells;
      final m = item.model;
      if (placed == null || placed.isEmpty) {
        continue;
      }
      final veil = Paint()
        ..color = Colors.white.withValues(alpha: 0.5)
        ..style = PaintingStyle.fill;
      final check = Paint()
        ..color = const Color(0xFF2E7D32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
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
        canvas.drawRect(rect, veil);
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

    // interval 加粗线 + 板最外边框（顶层：豆色块/文字/已放标记之后画，
    // 不被豆的颜色压掉）。粗线颜色可配（板配置页色板入口，随板持久化），
    // 默认橙一类亮色——深色豆上压得住；深底模式板外框跟粗线色（黑线在
    // 深底不可见），浅底配置页外框保持深黑
    final majorColor = Color(board.majorColor ?? BoardConfig.defaultMajorColor);
    final majorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
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
      ..strokeWidth = 2.2
      ..color = darkBoard ? majorColor : Colors.black87;
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
      final r = 13.0 / viewScale;
      final ring = Paint()
        ..color = const Color(0xFFC62828)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 / viewScale;
      canvas.drawCircle(center, r, Paint()..color = Colors.white);
      canvas.drawCircle(center, r, ring);
      final s = r * 0.5;
      final cross = Paint()
        ..color = const Color(0xFFC62828)
        ..strokeWidth = 2.2 / viewScale
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
        oldDelegate.darkBoard != darkBoard ||
        oldDelegate.viewScale != viewScale ||
        oldDelegate.items.length != items.length ||
        oldDelegate.items != items;
  }
}
