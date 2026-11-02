import 'package:flutter/widgets.dart';

/// 页面阶段：选图 -> 框图例 -> 九宫格对齐 -> 框选主体 -> 识别复核
enum RestoreStage { pick, legend, align, frame, review }

/// 图区构建器：页面 State 持有的统一手势图区（_imageStage 的签名）。
/// 各步骤 widget 经此获得图区（手势/缩放/覆盖层装配留在页面），
/// 不直接触碰页面内部状态
typedef ImageStageBuilder = Widget Function({
  required Rect? sel,
  required void Function(Rect) onSel,
  CustomPainter? overlay,
  List<Offset>? cornerPts,
  void Function(int, Offset)? onCornerDrag,
  Offset? miniAnchor,
  void Function(Offset)? onMiniAnchor,
  bool panFallback,
});

/// 画布缩放按钮条构建器（页面 _zoomStrip 的签名）
typedef ZoomStripBuilder = Widget Function(
  TransformationController ctrl,
  Size Function() contentSize, {
  double maxScale,
  Size Function()? viewport,
});

/// 图例条目：图纸图例里识别出的一个用色
class LegendEntry {
  final int paletteIndex;

  ///< 调色板索引
  final TextEditingController countCtrl = TextEditingController();

  ///< 图例标注数量（手填，对账用）

  LegendEntry(this.paletteIndex);

  /// 图例标注数量（空/非法返回 null = 不参与对账）
  int? get expectedCount => int.tryParse(countCtrl.text.trim());
}

/// 图例/作品信息的排序模式：色号序（A1 起自然序，仅排清单里有的，默认）/
/// 颗数从多到少 / 颗数从少到多 / 位置序（识别结果的逐行从左到右——
/// 即图例在图纸上的物理位置顺序）
///
/// 图例核对步选择后随作品保存（meta.sortMode），识别复核 chips 与用料
/// 统计等「这幅图的信息」展示沿用同一排序。旧作品存的 "reading" 是
/// 位置序的前身（读取侧做名字兼容）
enum LegendSort { code, countDesc, countAsc, position }

/// 排序模式短标签（排序控件/菜单显示用）
const Map<LegendSort, String> legendSortLabels = {
  LegendSort.code: "色号序",
  LegendSort.countDesc: "多→少",
  LegendSort.countAsc: "少→多",
  LegendSort.position: "位置序",
};

/// 图例清单排序比较器（LegendStep 列表与 ReviewStep chips 共用）：
/// [sort] 模式 + 参与排序的颗数取值函数（图例步传 expectedCount，
/// 复核步传 图例颗数 ?? 实际颗数）。position 模式即列表原始顺序
/// （识别输出已按逐行从左到右排好），比较器返回 0 保持稳定
int legendSortCompare(
  LegendSort sort,
  LegendEntry a,
  LegendEntry b,
  int Function(LegendEntry) countOf,
) {
  switch (sort) {
    case LegendSort.position:
      return 0;
    case LegendSort.countDesc:
      final d = countOf(b).compareTo(countOf(a));
      return d != 0 ? d : a.paletteIndex.compareTo(b.paletteIndex);
    case LegendSort.countAsc:
      final d = countOf(a).compareTo(countOf(b));
      return d != 0 ? d : a.paletteIndex.compareTo(b.paletteIndex);
    case LegendSort.code:
      // 调色板按 A1→A2→…→B1→… 自然序存储，索引序即色号序
      return a.paletteIndex.compareTo(b.paletteIndex);
  }
}

/// 图区手势上下文：build 闭包里的回调/选区/角点/约束打包，
/// 供 Listener 的四个指针处理方法共用（避免长参数表）
class StageCtx {
  final void Function(Rect) onSel;

  ///< 选区变更回调（图坐标）
  final Rect? sel;

  ///< 当前选区（角点校正模式下为 null）
  final List<Offset>? cornerPts;

  ///< 角点校正模式的四角点（null=非角点模式）
  final void Function(int, Offset)? onCornerDrag;

  ///< 角点拖拽回调（索引, 图坐标）
  final BoxConstraints cons;

  ///< 图区 viewport 约束（平移/捏合 clamp 用）
  final Offset? miniAnchor;

  ///< 九宫格标定框锚点（null=非九宫格模式）
  final void Function(Offset)? onMiniAnchor;

  ///< 九宫格锚点变更回调（图坐标）
  final bool panFallback;

  ///< 未命中九宫格/无选区时的拖动=true 平移画面查看（对齐步），
  ///false 画选区（框选步）——两步拆分后手势单一化的分派开关

  const StageCtx(
    this.onSel,
    this.sel,
    this.cornerPts,
    this.onCornerDrag,
    this.cons,
    this.miniAnchor,
    this.onMiniAnchor,
    this.panFallback,
  );
}
