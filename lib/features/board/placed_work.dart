/// 板上的一件作品：条目 + 渲染调色板 + 摆放偏移
///
/// 偏移可变（配置页拖动直接改）；调色板初始为空，resolveForModel
/// 完成后经 copyWith 换成作品专属调色板再重画
library;

import 'dart:math' as math;

import '../../core/draft_store.dart';
import '../../core/palette.dart';

class PlacedWork {
  final WorkEntry entry;

  ///< 作品条目（元数据 + 图案 + 拼装进度）
  final BeadPalette palette;

  ///< 渲染调色板（resolveForModel 结果）
  int ox;

  ///< 左上角在板上的列偏移（拖动可变）
  int oy;

  ///< 左上角在板上的行偏移（拖动可变）

  PlacedWork({
    required this.entry,
    required this.palette,
    this.ox = 0,
    this.oy = 0,
  });

  /// 作品是否完全放进板内
  bool fits(int bw, int bh) =>
      entry.model.width <= bw && entry.model.height <= bh;

  /// 把偏移 clamp 进板合法范围（超板作品落 (0,0)）
  void clampTo(int bw, int bh) {
    final m = entry.model;
    ox = ox.clamp(0, math.max(0, bw - m.width)).toInt();
    oy = oy.clamp(0, math.max(0, bh - m.height)).toInt();
  }

  PlacedWork copyWith({BeadPalette? palette}) => PlacedWork(
    entry: entry,
    palette: palette ?? this.palette,
    ox: ox,
    oy: oy,
  );
}
