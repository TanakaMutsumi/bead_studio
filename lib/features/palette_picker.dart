import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/palette.dart';

/// 色卡选色器弹窗（图例修正色号 / 添加颜色 / 复核归类 / 编辑器选绘画色
/// / 全局换色共用）：全部色号网格 + 右侧字母序目录（通讯录式，点字母
/// 跳到该字母组）+ 右上角搜索（色号/名称模糊过滤）。点中即选、返回
/// 索引（-1 = 空白，null = 取消）
///
/// [allowed] 非空时只显示集合内的色号（复核归类限定图例色 + 识别结果
/// 中出现过的色——识别候选本就来自图例，归到图例外的色会让图例对账
/// 口径混入外色）；[withBlank] 为 true 时首格是「空白」（归类到空白
/// 用，点中返回 -1）。
Future<int?> showPaletteColorPicker(
  BuildContext context, {
  required BeadPalette palette,
  Set<int>? allowed,
  bool withBlank = false,
  String title = "选择色号",
}) {
  final indices = <int>[
    if (withBlank) -1,
    for (var i = 0; i < palette.colors.length; i++)
      if (allowed == null || allowed.contains(i)) i,
  ];
  return showDialog<int>(
    context: context,
    builder: (_) => _PalettePickerDialog(
      palette: palette,
      indices: indices,
      title: title,
    ),
  );
}

class _PalettePickerDialog extends StatefulWidget {
  final BeadPalette palette;
  final List<int> indices;
  final String title;

  const _PalettePickerDialog({
    required this.palette,
    required this.indices,
    required this.title,
  });

  @override
  State<_PalettePickerDialog> createState() => _PalettePickerDialogState();
}

class _PalettePickerDialogState extends State<_PalettePickerDialog> {
  static const _rowExtent = 56.0;

  ///< 网格行高固定值（字母目录按行跳转的换算基准）

  var _query = '';
  final _gridScroll = ScrollController();

  ///< 字母 -> 该字母首个色号在 indices 中的位次（目录跳转目标）
  late final Map<String, int> _letterFirst;

  ///< 目录字母（按调色板序出现的去重首字母，天然字母序）
  late final List<String> _letters;

  @override
  void initState() {
    super.initState();
    _letterFirst = {};
    for (var k = 0; k < widget.indices.length; k++) {
      final i = widget.indices[k];
      if (i < 0) {
        continue; // 空白格不参与字母分组
      }
      final ch = widget.palette.colors[i].id[0].toUpperCase();
      _letterFirst.putIfAbsent(ch, () => k);
    }
    _letters = _letterFirst.keys.toList();
  }

  @override
  void dispose() {
    _gridScroll.dispose();
    super.dispose();
  }

  /// 搜索过滤后的位次列表（空搜索 = 全量）
  List<int> _visible() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      return List<int>.generate(widget.indices.length, (k) => k);
    }
    return [
      for (var k = 0; k < widget.indices.length; k++)
        if (_matches(widget.indices[k], q)) k,
    ];
  }

  bool _matches(int i, String q) {
    if (i < 0) {
      return q.contains('空') || q.contains('blank');
    }
    final c = widget.palette.colors[i];
    return c.id.toLowerCase().contains(q) ||
        c.name.toLowerCase().contains(q);
  }

  /// 点目录字母：跳到该字母组首行（过滤态目录隐藏，仅全量态可达）
  void _jumpToLetter(String letter) {
    if (!_gridScroll.hasClients || _gridScroll.positions.length != 1) {
      return;
    }
    final k = _letterFirst[letter];
    if (k == null) {
      return;
    }
    final target = (k ~/ 6) * (_rowExtent + 4);
    _gridScroll.position.jumpTo(
      target
          .clamp(
            _gridScroll.position.minScrollExtent,
            _gridScroll.position.maxScrollExtent,
          )
          .toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible();
    // 高度随可用空间走：键盘弹出时不至于把网格整个盖掉
    final avail = MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final gridHeight = math.min(440.0, math.max(240.0, avail * 0.66));
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(widget.title)),
          SizedBox(
            width: 158,
            height: 40,
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: "搜索色号/名称",
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: gridHeight,
        child: visible.isEmpty
            ? const Center(
                child: Text("无匹配色号", style: TextStyle(color: Colors.black45)),
              )
            : Stack(
                children: [
                  GridView.builder(
                    controller: _gridScroll,
                    padding: const EdgeInsets.only(right: 22),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                          mainAxisExtent: _rowExtent,
                        ),
                    itemCount: visible.length,
                    itemBuilder: (ctx, k) => _cell(ctx, widget.indices[visible[k]]),
                  ),
                  // 右侧字母目录：仅全量态显示（过滤结果无字母分组意义）
                  if (_query.trim().isEmpty && _letters.isNotEmpty)
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: 20,
                      child: Column(
                        children: [
                          for (final l in _letters)
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _jumpToLetter(l),
                                child: Center(
                                  child: Text(
                                    l,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      height: 1,
                                      color: Colors.blueAccent,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
      ],
    );
  }

  /// 单个色号格（空白格 = 空白返回 -1）
  Widget _cell(BuildContext ctx, int i) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, i),
      // FittedBox 防格子竖向溢出：大色卡(291 色)行高较矮 + 系统字体
      // 缩放时 Column(色块+文字) 放不下会渲染 "BOTTOM OVERFLOWED"
      // 溢出条（用户看到的 "BOTTOM OV" 就是它），scaleDown 整体缩放兜底
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (i < 0)
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black38),
                ),
                child: const Icon(
                  Icons.close,
                  size: 20,
                  color: Colors.black45,
                ),
              )
            else
              Container(
                width: 34,
                height: 34,
                color: Color.fromARGB(
                  255,
                  widget.palette.colors[i].r,
                  widget.palette.colors[i].g,
                  widget.palette.colors[i].b,
                ),
              ),
            Text(
              i < 0 ? "空白" : widget.palette.colors[i].id,
              style: const TextStyle(fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
