import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/palette.dart';
import '../restore_types.dart';

/// 阶段②：框选图例 + 识别 + 清单核对
///
/// 图区/缩放条经 [imageStage]/[zoomStrip] 构建器注入（手势与装配留在
/// 页面 State），业务回调全部上抛。清单行占比条（_countBar）只依赖
/// 清单数据，收在本文件内。
class LegendStep extends StatelessWidget {
  final ImageStageBuilder imageStage;
  final ZoomStripBuilder zoomStrip;
  final TransformationController viewerCtrl;

  ///< 图区变换控制器（缩放条锚点用）
  final Size Function() displaySize;

  ///< 原图显示尺寸（面板高度预算用）
  final Size Function() stageViewSize;

  ///< 图区视口尺寸速记（缩放条边界用）
  final Rect? legendSel;

  ///< 图例选区（显示坐标）
  final CustomPainter? overlay;

  ///< 网格覆盖层（仅量化模式非空）
  final void Function(Rect) onSel;

  ///< 选区变更（拖画/挪框/把手）
  final VoidCallback onClearSel;

  ///< 清除选框
  final bool legendBusy;
  final bool legendByOcr;
  final bool panelExpanded;
  final TextEditingController colsCtrl;
  final TextEditingController rowsCtrl;
  final List<LegendEntry> legend;
  final LegendSort legendSort;

  ///< 清单排序（校对视角，默认识别顺序）
  final void Function(LegendSort) onSortChange;

  ///< 切换排序
  final BeadPalette palette;
  final VoidCallback onAutoSelect;

  ///< 自动框选图例区
  final VoidCallback onScan;

  ///< 识别图例
  final VoidCallback onGoAlign;

  ///< 跳过图例 / 下一步
  final VoidCallback onTogglePanel;

  ///< 展开/收起核对清单
  final VoidCallback onAddColor;

  ///< 添加颜色（补 OCR 漏识别）
  final void Function(LegendEntry entry) onChangeColor;

  ///< 修正条目色号
  final void Function(LegendEntry entry) onRemoveEntry;

  ///< 删除条目

  const LegendStep({
    super.key,
    required this.imageStage,
    required this.zoomStrip,
    required this.viewerCtrl,
    required this.displaySize,
    required this.stageViewSize,
    required this.legendSel,
    required this.overlay,
    required this.onSel,
    required this.onClearSel,
    required this.legendBusy,
    required this.legendByOcr,
    required this.panelExpanded,
    required this.colsCtrl,
    required this.rowsCtrl,
    required this.legend,
    required this.legendSort,
    required this.onSortChange,
    required this.palette,
    required this.onAutoSelect,
    required this.onScan,
    required this.onGoAlign,
    required this.onTogglePanel,
    required this.onAddColor,
    required this.onChangeColor,
    required this.onRemoveEntry,
  });

  @override
  Widget build(BuildContext context) {
    final scanned = legend.isNotEmpty;
    // 排序只做展示视图，不动页面清单（其顺序即位置序——识别输出的
    // 逐行从左到右，对账/复核用）；
    // 未填颗数视为最小值——升序排最前（待校对优先暴露）、降序垫底。
    // 比较器与复核 chips 共用（legendSortCompare）
    final sorted = legendSort == LegendSort.position ? legend : [...legend]
      ..sort(
        (a, b) => legendSortCompare(
          legendSort,
          a,
          b,
          (e) => e.expectedCount ?? -1,
        ),
      );
    return LayoutBuilder(builder: (context, cons) {
      // 展开态清单高度自适应：图是宽适配的固定显示高度（displaySize），
      // 图例带就在图底部——面板（含缩放条）超出剩余空间会把图的下半截
      // 挤出视口，没法对照原图核对色号/颗数。展开态固定开销：图区
      // padding 24 + 缩放条 ~38 + 摘要行 ~34 + 间距 12 + 操作行 ~44 +
      // 间距 8 + 底 padding 12 ≈ 172（排序下拉并入摘要行、添加颜色并入
      // 操作行，不再各占一行）
      final imgH = displaySize().height;
      // 清单高度 =「剩余空间（视口 - 图高 - 固定开销 172）」与「视口 42%」
      // 取大者：竖版图（图高≈视口 6 成）剩余空间是负数，旧式被钳到 96，
      // 清单一次只露两行没法核对。清单多拿的空间由图区 Expanded 吸收
      //（图下半出视口，滚轮/双指平移看回；收起清单即完整露出原图图例带）
      final listH = math
          .max(cons.maxHeight - imgH - 172, cons.maxHeight * 0.42)
          .clamp(120.0, 420.0);
      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: imageStage(
                sel: legendSel,
                onSel: onSel,
                overlay: overlay,
              ),
            ),
          ),
          zoomStrip(
            viewerCtrl,
            displaySize,
            viewport: stageViewSize,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!scanned) ...[
                  const Text(
                    "① 只框出图纸底部的图例区（色号 + 颗数对照表）",
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 8),
                  // 显式自动框选入口：载入时已自动尝试过，选区被改动或
                  // 想重选时可随时点这里重跑（AppBar 魔法棒同功能）。
                  // 清除选框：自动框选错位时框常压在图边缘（如贴底的页脚
                  // 灰线带），把手出不了图没法抓——一键消掉旧框重新拖
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onAutoSelect,
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: const Text("自动框选图例区"),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: legendSel == null ? null : onClearSel,
                          icon: const Icon(Icons.backspace_outlined, size: 18),
                          label: const Text("清除选框"),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: legendBusy ? null : onScan,
                          icon: legendBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.document_scanner, size: 18),
                          label: Text(legendBusy ? "识别中…" : "识别图例"),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: onGoAlign,
                        child: const Text("跳过图例"),
                      ),
                    ],
                  ),
                ] else ...[
                  // 摘要行：点击展开/收起核对清单——收起后底部只占一行，
                  // 原图下半部（图例区）进入视野，用户按原图图例逐一核对色号与颗数
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: onTogglePanel,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  panelExpanded
                                      ? Icons.keyboard_arrow_down
                                      : Icons.keyboard_arrow_up,
                                  size: 22,
                                  color: Colors.black54,
                                ),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: Text(
                                    panelExpanded
                                        ? "图例 ${legend.length} 色（点此收起，露出原图核对）"
                                        : "图例 ${legend.length} 色（点此展开核对清单）",
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 总豆数徽标（识别复核「总豆数」chip 同款样式）：
                      // 全部条目颗数之和，核对「清单加总 vs 图纸标注总颗数」
                      // 一眼可读；收起/展开态都常驻
                      _totalChip(),
                      if (!panelExpanded)
                        FilledButton.tonal(
                          onPressed: onGoAlign,
                          child: const Text("下一步"),
                        )
                      else
                        // 排序下拉并入摘要行（原独立排序行把清单挤得太短）；
                        // 该排序同时管识别复核 chips 与作品信息展示
                        _sortPopup(),
                    ],
                  ),
                  if (panelExpanded) ...[
                    const SizedBox(height: 4),
                    if (!legendByOcr)
                      Row(
                        children: [
                          SizedBox(
                            width: 64,
                            child: TextField(
                              controller: colsCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: "列",
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text("×"),
                          ),
                          SizedBox(
                            width: 64,
                            child: TextField(
                              controller: rowsCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: "行",
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: legendBusy ? null : onScan,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text("重新识别"),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _addColorBtn(),
                        ],
                      )
                    else
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: legendBusy ? null : onScan,
                            icon: legendBusy
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh, size: 18),
                            label: Text(legendBusy ? "识别中…" : "重新框选后识别"),
                          ),
                          const Spacer(),
                          _addColorBtn(),
                        ],
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: listH,
                      child: ListView.builder(
                        itemCount: sorted.length,
                        itemBuilder: (_, i) {
                          final e = sorted[i];
                          final c = palette.colors[e.paletteIndex];
                          // 行距 3：isDense 输入框行与行紧贴会上下遮挡；
                          // key 挂条目：排序切换时行随条目走，输入框焦点
                          // /光标不串行（无 key 时按位置复用元素状态）
                          return Padding(
                            key: ValueKey(e),
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Tooltip(
                                  message: "点击修改色号",
                                  child: InkWell(
                                    onTap: () => onChangeColor(e),
                                    child: SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: ColoredBox(
                                              color: Color.fromARGB(
                                                255,
                                                c.r,
                                                c.g,
                                                c.b,
                                              ),
                                            ),
                                          ),
                                          // 右下角编辑角标：提示色块可点改色号
                                          Positioned(
                                            right: 0,
                                            bottom: 0,
                                            child: Container(
                                              color: Colors.white70,
                                              padding: const EdgeInsets.all(1),
                                              child: const Icon(
                                                Icons.edit,
                                                size: 10,
                                                color: Colors.black54,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(width: 52, child: Text(c.id)),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 72,
                                  child: TextField(
                                    controller: e.countCtrl,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      hintText: "颗数",
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 9,
                                      ),
                                    ),
                                  ),
                                ),
                                // 占比条：填了颗数后按各色占比填充（颜色即豆色），
                                // 填满中间空白让行更紧凑有信息量
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _countBar(sorted, e, c),
                                ),
                                const SizedBox(width: 8),
                                // 删除该色（识别错误且不需要的条目）
                                SizedBox(
                                  width: 30,
                                  height: 32,
                                  child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    iconSize: 16,
                                    tooltip: "删除该色",
                                    onPressed: () => onRemoveEntry(e),
                                    icon: const Icon(
                                      Icons.close,
                                      color: Colors.black38,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: onGoAlign,
                            icon: const Icon(Icons.arrow_forward),
                            label: Text(
                              "下一步：九宫格对齐（${legend.length}色）",
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      );
    });
  }

  /// 总豆数徽标（摘要行右侧）：已填条目的颗数之和，随输入框敲键实时
  /// 刷新（Listenable.merge 全部 countCtrl，只重建本徽标不动整页）。
  /// 有未填条目时括注未填色数——总和不全时核对口径要能看出来；
  /// 一条都没填不显示（全 0 的"共 0 颗"没有核对价值）
  Widget _totalChip() {
    return ListenableBuilder(
      listenable: Listenable.merge([for (final e in legend) e.countCtrl]),
      builder: (_, __) {
        var total = 0;
        var filled = 0;
        for (final e in legend) {
          final c = e.expectedCount;
          if (c != null && c > 0) {
            filled++;
            total += c;
          }
        }
        if (filled == 0) {
          return const SizedBox.shrink();
        }
        final missing = legend.length - filled;
        return Container(
          margin: const EdgeInsets.only(left: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black38),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.grain, size: 14, color: Colors.black54),
              const SizedBox(width: 4),
              Text(
                missing > 0 ? "共 $total 颗（$missing 色未填）" : "共 $total 颗",
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 排序下拉（摘要行右侧）：四模式单选菜单，当前模式带勾；
  /// 比独立分段按钮行省一整行高度（原清单被挤太短）
  Widget _sortPopup() {
    return PopupMenuButton<LegendSort>(
      tooltip: "排序方式",
      initialValue: legendSort,
      onSelected: onSortChange,
      itemBuilder: (_) => [
        for (final e in LegendSort.values)
          PopupMenuItem(
            value: e,
            child: Row(
              children: [
                Icon(
                  e == legendSort ? Icons.check : Icons.check,
                  size: 16,
                  color: e == legendSort ? Colors.blue : Colors.transparent,
                ),
                const SizedBox(width: 4),
                Text(legendSortLabels[e]!),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.sort, size: 14, color: Colors.black54),
            const SizedBox(width: 2),
            Text(
              legendSortLabels[legendSort]!,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const Icon(Icons.arrow_drop_down, size: 16, color: Colors.black54),
          ],
        ),
      ),
    );
  }

  /// 添加色号按钮（操作行右端）：补 OCR 漏识别的色——原在清单末尾，
  /// 需滚到最底才能看到；带文字标签（纯图标实测看不出是加颜色的入口）
  Widget _addColorBtn() {
    return TextButton.icon(
      onPressed: onAddColor,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      icon: const Icon(Icons.add_circle_outline, size: 18),
      label: const Text("添加色号"),
    );
  }
}

/// 清单行占比条：该色颗数占全部颗数的比例（条色即豆色），
/// 未填颗数时返回空位保持行对齐
Widget _countBar(List<LegendEntry> legend, LegendEntry e, BeadColor c) {
  final cnt = e.expectedCount;
  var total = 0;
  for (final o in legend) {
    total += o.expectedCount ?? 0;
  }
  if (cnt == null || cnt <= 0 || total <= 0) {
    return const SizedBox.shrink();
  }
  final ratio = (cnt / total).clamp(0.0, 1.0);
  return Row(
    children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: Container(
            height: 6,
            color: Colors.black.withValues(alpha: 0.06),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ratio,
              child: Container(
                color: Color.fromARGB(255, c.r, c.g, c.b),
              ),
            ),
          ),
        ),
      ),
      SizedBox(
        width: 38,
        child: Text(
          "${(ratio * 100).toStringAsFixed(0)}%",
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 11, color: Colors.black45),
        ),
      ),
    ],
  );
}
