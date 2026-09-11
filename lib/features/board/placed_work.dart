/// 板上的一件作品：条目 + 渲染调色板 + 摆放偏移 + 变换（旋转/翻转）
///
/// 偏移可变（配置页拖动直接改）；调色板初始为空，resolveForModel
/// 完成后经 copyWith 换成作品专属调色板再重画。
/// 变换（rot/flipH/flipV）只作用于渲染/交互快照 [model] 与 [placed]，
/// entry.model 恒为原始坐标系——保存进度时经 toOriginalCells 逆映射
/// 回原坐标，作品文件不感知变换
library;

import 'dart:math' as math;

import '../../core/draft_store.dart';
import '../../core/palette.dart';
import '../../core/pattern_model.dart';

class PlacedWork {
  final WorkEntry entry;

  ///< 作品条目（元数据 + 原始图案 + 原坐标拼装进度）
  final BeadPalette palette;

  ///< 渲染调色板（resolveForModel 结果）
  int ox;

  ///< 左上角在板上的列偏移（拖动可变）
  int oy;

  ///< 左上角在板上的行偏移（拖动可变）
  int rot;

  ///< 顺时针 90° 步数（0-3）
  bool flipH;

  ///< 左右翻转
  bool flipV;

  ///< 上下翻转

  PatternTransform get _transform =>
      PatternTransform(rot: rot, flipH: flipH, flipV: flipV);

  /// 变换后坐标系快照：渲染/命中/统计全程用它（entry.model 恒原始）
  late PatternModel _model = _transform.applyTo(entry.model);

  PatternModel get model => _model;

  /// 变换坐标系下的已放格子（构造时由 entry.placed 正向映射灌入）
  final Set<int> placed = {};

  PlacedWork({
    required this.entry,
    required this.palette,
    this.ox = 0,
    this.oy = 0,
    this.rot = 0,
    this.flipH = false,
    this.flipV = false,
  }) {
    placed.addAll(_forwardCells(entry.placed));
  }

  /// 原坐标格集合 -> 变换坐标格集合
  Set<int> _forwardCells(Set<int> cells) {
    final t = _transform;
    if (t.isIdentity) {
      return cells;
    }
    final m = entry.model;
    final (w2, h2) = t.sizeOf(m.width, m.height);
    return {
      for (final i in cells)
        if (i >= 0 && i < m.grid.length)
          () {
            final (X, Y) = t.forward(
              m.width,
              m.height,
              i % m.width,
              i ~/ m.width,
            );
            return Y * w2 + X;
          }(),
    };
  }

  /// 变换坐标格集合 -> 原坐标格集合（保存进度用）
  Set<int> toOriginalCells(Set<int> cells) {
    final t = _transform;
    if (t.isIdentity) {
      return cells;
    }
    final m = entry.model;
    return {
      for (final i in cells)
        if (i >= 0 && i < m.grid.length)
          () {
            final (x, y) = t.inverse(
              m.width,
              m.height,
              i % _model.width,
              i ~/ _model.width,
            );
            return y * m.width + x;
          }(),
    };
  }

  /// 当前进度的原坐标快照（保存用）
  Set<int> placedOriginal() => toOriginalCells(placed);

  /// 更新变换：placed 先逆映射回原坐标暂存，重算快照后正向重灌——
  /// 任何变换组合下进度不丢
  void setTransform({int? rot, bool? flipH, bool? flipV}) {
    final orig = placedOriginal();
    this.rot = rot ?? this.rot;
    this.flipH = flipH ?? this.flipH;
    this.flipV = flipV ?? this.flipV;
    _model = _transform.applyTo(entry.model);
    placed
      ..clear()
      ..addAll(_forwardCells(orig));
  }

  /// 作品是否完全放进板内（按变换后尺寸）
  bool fits(int bw, int bh) => _model.width <= bw && _model.height <= bh;

  /// 把偏移 clamp 进板合法范围（超板作品落 (0,0)，按变换后尺寸）
  void clampTo(int bw, int bh) {
    ox = ox.clamp(0, math.max(0, bw - _model.width)).toInt();
    oy = oy.clamp(0, math.max(0, bh - _model.height)).toInt();
  }

  PlacedWork copyWith({BeadPalette? palette}) {
    final w = PlacedWork(
      entry: entry,
      palette: palette ?? this.palette,
      ox: ox,
      oy: oy,
      rot: rot,
      flipH: flipH,
      flipV: flipV,
    );
    // placed 平移：变换相同坐标一致，整组复制（不能用构造器的
    // entry.placed——那是原坐标系）
    w.placed
      ..clear()
      ..addAll(placed);
    return w;
  }
}
