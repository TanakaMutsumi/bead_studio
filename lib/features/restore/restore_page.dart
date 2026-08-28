import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_build.dart';
import '../../core/decode_image.dart';
import '../../core/grid_detector.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/pattern_model.dart';
import '../../core/quantizer.dart';
import '../editor/editor_page.dart';
import '../editor/grid_painter.dart';

/// 页面阶段：选图 -> 框图例 -> 网格对齐 -> 识别复核
enum _Stage { pick, legend, align, review }

/// 空白判定阈值：格色与候选色的 Lab 距离平方超过此值视为空白格
const double _blankDistSq = 900.0; // ΔE ≈ 30

/// 四角双线性插值：单位网格坐标 (u,v)∈[0,1]² -> 平面坐标
///
/// q 为四角 [左上, 右上, 右下, 左下]（对应单位坐标 (0,0)(1,0)(1,1)(0,1)）。
/// 四角对齐模式的核心几何：用户把 4 个角点拖到图案网格的四个角，
/// 识别采样与网格覆盖层的全部交点都经此映射反求，两处坐标同源。
Offset _bilinearQuad(List<Offset> q, double u, double v) {
  final a = (1 - u) * (1 - v);
  final b = u * (1 - v);
  final c = u * v;
  final d = (1 - u) * v;
  return Offset(
    a * q[0].dx + b * q[1].dx + c * q[2].dx + d * q[3].dx,
    a * q[0].dy + b * q[1].dy + c * q[2].dy + d * q[3].dy,
  );
}

/// OCR 常见字符混淆表（色号匹配用：印刷小字 0/O、1/I/L、2/Z、5/S、6/G、8/B、4/A 互混）
const Map<String, List<String>> _ocrConfusions = {
  "0": ["O"],
  "O": ["0"],
  "1": ["I", "L"],
  "I": ["1"],
  "L": ["1"],
  "2": ["Z"],
  "Z": ["2"],
  "5": ["S"],
  "S": ["5"],
  "6": ["G"],
  "G": ["6"],
  "8": ["B"],
  "B": ["8"],
  "4": ["A"],
  "A": ["4"],
};

/// 掉字母色号的色块采样：图例条目整条是彩色豆底块（色号/颗数直接印在彩底上），
/// 取色号框外扩窗口内高饱和像素的 RGB 均值——黑/白文字与白色底块饱和度低，
/// 天然被排除，剩下的就是豆底颜色
(int, int, int)? _sampleSwatch(img.Image image, Rect codeRect) {
  final m = codeRect.height;
  final left = (codeRect.left - m).round().clamp(0, image.width - 1);
  final right = (codeRect.right + m).round().clamp(0, image.width - 1);
  final top = (codeRect.top - m * 0.6).round().clamp(0, image.height - 1);
  final bottom = (codeRect.bottom + m * 0.6).round().clamp(0, image.height - 1);
  var sr = 0, sg = 0, sb = 0, n = 0;
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      final p = image.getPixel(x, y);
      final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (mx - mn < 40) {
        continue; // 黑/白文字与白底低饱和，排除
      }
      sr += r;
      sg += g;
      sb += b;
      n++;
    }
  }
  if (n < 20) {
    return null; // 采样点太少（白底条目无彩底），不可信
  }
  return (sr ~/ n, sg ~/ n, sb ~/ n);
}

/// 掉字母色号按「数字后缀候选 + 条目色块颜色最近匹配」补全。
/// 返回补全的调色板索引；候选为空/色块不可采样/颜色差过远（色卡切换
/// 不对或本就不是色号）时返回 null 保守放弃
int? _fixCodeBySwatch(
  BeadPalette palette,
  int bareNum,
  Rect codeRect,
  img.Image scaled,
) {
  final suffix = bareNum.toString();
  final cands = <int>[
    for (var i = 0; i < palette.colors.length; i++)
      if (palette.colors[i].id.length == suffix.length + 1 &&
          palette.colors[i].id.endsWith(suffix))
        i,
  ];
  if (cands.isEmpty) {
    return null;
  }
  final swatch = _sampleSwatch(scaled, codeRect);
  if (swatch == null) {
    return null;
  }
  var best = -1;
  var bestDist = 1 << 30;
  for (final i in cands) {
    final c = palette.colors[i];
    final d = (c.r - swatch.$1) * (c.r - swatch.$1) +
        (c.g - swatch.$2) * (c.g - swatch.$2) +
        (c.b - swatch.$3) * (c.b - swatch.$3);
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  if (best < 0 || bestDist > 120 * 120 * 3) {
    return null;
  }
  return best;
}

/// 图例 OCR 识别元素（色号或颗数，带几何框供跨行配对）
class _OcrElem {
  final int seq;

  ///< 收集序（block/line/element 遍历序，保底配对用）
  final Rect rect;

  ///< 元素框（放大图坐标系；个别平台可能退化为 0 框）
  final int? code;

  ///< 色号 -> 调色板索引（与 count 互斥）
  final int? count;

  ///< 颗数
  bool used = false;

  ///< 已被配对消费（数字侧）
  int? pairedCount;

  ///< 色号侧配到的颗数
  // 【临时调试】配对的另一侧元素引用（调试视图画连线用，正式版随调试功能一起移除）
  _OcrElem? pairedWith;
  String dbgText = "";

  ///< 【临时调试】OCR 原始文本
  _OcrElem(this.seq, this.rect, this.code, this.count);
}

/// 【临时调试】一次图例 OCR 的调试快照（正式版随调试视图一起移除）
class _OcrDebugInfo {
  final String source;

  ///< 来源（自动扫描档位 / 手动框选）
  final String imgPath;

  ///< 喂给 ML Kit 的放大选区图路径
  final int imgW, imgH;

  ///< 放大图尺寸（元素框坐标系）
  final List<_OcrElem> elems;

  ///< 全部识别元素（含配对引用）
  final double selX, selY, selW, selH;

  ///< 框选区（原图坐标）——复现框选用
  _OcrDebugInfo(
    this.source,
    this.imgPath,
    this.imgW,
    this.imgH,
    this.elems,
    this.selX,
    this.selY,
    this.selW,
    this.selH,
  );
}

/// 图例条目：图纸图例里识别出的一个用色
class _LegendEntry {
  final int paletteIndex;

  ///< 调色板索引
  final TextEditingController countCtrl = TextEditingController();

  ///< 图例标注数量（手填，对账用）

  _LegendEntry(this.paletteIndex);

  /// 图例标注数量（空/非法返回 null = 不参与对账）
  int? get expectedCount => int.tryParse(countCtrl.text.trim());
}

/// 图纸还原页：复刻原 App 五步链路
///
/// 1. 只框出图纸的图例区域 -> 识别图纸用色清单（可勾选/换色号/填数量）
/// 2. 核对图例识别结果
/// 3. 框选主体 + 九宫格对齐（自动检测 + 格子大小/微移可视化调整）
/// 4. 检查网格覆盖是否对齐
/// 5. 识别后按色号分组复核，错误格子手工归类 + 图例数量对账
class RestorePage extends StatefulWidget {
  const RestorePage({super.key});

  @override
  State<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends State<RestorePage> {
  _Stage _stage = _Stage.pick;
  Uint8List? _bytes;

  ///< 原图字节
  img.Image? _image;

  ///< 解码后的原图

  // ========== 色卡 ==========
  BeadPalette _palette = const BeadPalette([]);

  ///< 当前色卡（初始空占位，initState 异步换为选中色卡）
  List<PaletteInfo> _palettes = const [];

  ///< 可选色卡列表
  String _paletteId = "";

  // ========== 图例（步骤 1/2） ==========
  Rect? _legendSel;

  ///< 图例选区（显示坐标）
  final _legendColsCtrl = TextEditingController();
  final _legendRowsCtrl = TextEditingController();
  var _legendBusy = false;
  List<_LegendEntry> _legend = [];

  ///< 识别出的图例清单
  var _legendByOcr = false;

  ///< true=清单来自印刷色号（行列输入隐藏，网格层不画）
  var _panelExpanded = true;

  ///< 图例确认面板展开（收起后图片区变大，便于对照原图校对）
  // 【临时调试】最近一次图例 OCR 的调试信息（放大图/元素/配对），正式版随调试视图一起移除
  _OcrDebugInfo? _ocrDebug;
  int _selHandleDrag = -1;

  ///< 选区把手拖拽中（-1=画新框，0-7=把手索引）
  Offset? _selMoveFrom;

  ///< 整框拖动起点（null=非移框）
  Rect? _selMoveBase;

  ///< 整框拖动开始时的选区
  Offset? _drawFrom;

  ///< 画新框的按下起点（onPanDown 只记录不落框，首帧 onPanUpdate 才画——
  ///双指缩放第一指按下时 pan 尚未裁决，立即画零点框会把选区破坏掉）
  bool _drawActive = false;

  ///< 画框累计位移已超过启动阈值（<10px 的轻点微动不落新框，防覆盖现有选区）
  final TransformationController _viewerCtrl = TransformationController();

  ///< 图区变换（滚轮纵向平移浏览；双指捏合缩放仍由 InteractiveViewer 手势承担）
  Uint8List? _displayBytes;

  ///< 显示用重编码 JPEG（decodeForDisplay 产物，识别/裁剪仍用 _image 原始像素）
  bool _decoding = false;

  ///< 解码/重编码中（图片区遮罩，避免"白屏不知发生什么"）

  // ========== 主体对齐（步骤 3/4） ==========
  Rect? _selDisplay;

  ///< 主体选区（显示坐标）
  final _colsCtrl = TextEditingController();
  final _rowsCtrl = TextEditingController();
  var _detecting = false;
  var _recognizing = false;
  double _pitchX = 0, _pitchY = 0;

  ///< 网格格距（图片坐标）
  double _offX = 0, _offY = 0;

  ///< 第一根网格线相对选区左上偏移（图片坐标）
  bool _blankEnable = true;

  ///< 偏色过大识别为空白格

  // ========== 四角对齐（歪图透视矫正，均分网格救不了斜拍） ==========
  var _useCornerAlign = false;

  ///< true=四角映射网格（复刻原版 corner_grid_alignment），false=均分网格
  List<Offset>? _cornerPts;

  ///< 四角（显示坐标，顺序：左上/右上/右下/左下），双线性映射网格交点
  int _cornerDragIdx = -1;

  ///< 拖拽中的角索引（-1=无）

  // ========== 复核（步骤 5） ==========
  PatternModel? _model;
  int _reviewColor = -2;

  ///< 当前复核色：-2 关闭 / -1 空白 / >=0 调色板索引
  final Set<int> _picked = {};

  ///< 选中的格子（扁平索引）

  @override
  void initState() {
    super.initState();
    _initPalette();
  }

  /// 加载选中色卡 + 全部可选色卡
  Future<void> _initPalette() async {
    final selected = await PaletteRegistry.loadSelected();
    final all = await PaletteRegistry.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _palette = selected.palette;
      _paletteId = selected.id;
      _palettes = all;
    });
  }

  @override
  void dispose() {
    _colsCtrl.dispose();
    _rowsCtrl.dispose();
    _legendColsCtrl.dispose();
    _legendRowsCtrl.dispose();
    for (final e in _legend) {
      e.countCtrl.dispose();
    }
    _viewerCtrl.dispose();
    super.dispose();
  }

  // ==================== 选图 ====================

  Future<void> _pickImage(ImageSource source) async {
    // 不传 imageQuality：任何非空值都会触发解码->重编码（quality 100 也逃不掉），
    // 微信压过的小图再吃一次代际损失；不传则原字节直读
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) {
      return;
    }
    try {
      setState(() => _decoding = true);
      final bytes = await picked.readAsBytes();
      // 显示层统一走重编码 JPEG + 长边限幅（decodeForDisplay），识别/裁剪
      // 仍用 decoded 原始像素
      final (decoded, display) = await decodeForDisplay(bytes);
      if (!mounted) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _displayBytes = display;
        _image = decoded;
        _legendSel = null;
        _selDisplay = null;
        _legend = [];
        _legendByOcr = false;
        _pitchX = 0;
        _model = null;
        _decoding = false;
        // 换图重置图区变换（上一张图的缩放/平移不带到新图）
        _viewerCtrl.value = Matrix4.identity();
        // 换图即清空调试快照：新图识别前 AppBar 不显示旧图的调试入口，
        // 否则点开看到的是上一张图的放大图/元素，误导排障
        _ocrDebug = null;
        _stage = _Stage.legend;
      });
      // 载入即自动预框图例区（省一次手动框选）；识别不到就保持空选区，
      // 用户手动框或点 AppBar「自动框选」重试
      final auto = _autoDetectLegend();
      if (auto != null) {
        setState(() => _legendSel = auto);
      }
    } catch (e) {
      // 解码失败必须弹提示（曾经异常被吞表现为"选图无反应"）
      if (mounted) {
        setState(() => _decoding = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("无法解码图片: $e")));
      }
    }
  }

  // ==================== 坐标换算 ====================

  /// 图片实际显示尺寸（与布局公式一致：可用宽 = 屏幕 - 两侧 12 padding）
  Size _displaySize() {
    final ctx = context;
    final displayW = MediaQuery.sizeOf(ctx).width - 24;
    return Size(displayW, displayW * _image!.height / _image!.width);
  }

  // ==================== 图例区自动检测 ====================

  /// 量化色是否白背景（r/g/b 量化后均 >= 15，即原值 >= 240）
  static bool _qWhite(int q) =>
      ((q >> 8) & 15) >= 15 && ((q >> 4) & 15) >= 15 && (q & 15) >= 15;

  /// 自动检测图例条带：游程法（原型已用两张实测图验证）
  ///
  /// 原理：图例色块是 20px+ 的纯色矩形（长游程），豆图每颗豆之间被格线
  /// 打断（游程 <= 豆宽），整行纯色背景/边框则只有 1 个超长游程——三者
  /// 按「块数 >= 3 且最长 <= 35% 行宽 且（最长 >= 60 或 多色且带白隙）」
  /// 区分出图例行；图例行聚簇成带，带高 <= 15% 图高，且带外必须是低信息
  /// 行（白隙或纯色隔离带，豆图大块同色区上下仍是密集豆行，据此排除）。
  /// 返回显示坐标选区；找不到返回 null（调用方静默或提示手动框选）。
  Rect? _autoDetectLegend() {
    final image = _image;
    if (image == null) {
      return null;
    }
    const step = 2, runMin = 20;
    final w = image.width, h = image.height;
    // 逐采样行：颜色量化(RGB>>4 打包)游程扫描
    final feats = <int, _RowFeat>{};
    for (var y = 0; y < h; y += step) {
      var nonWhite = 0, nBlocks = 0, maxLen = 0;
      var minX = 1 << 30, maxX = -(1 << 30);
      final colors = <int>{};
      var runCol = -1, runLen = 0, runStart = 0;
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        final q = ((p.r.toInt() >> 4) << 8) |
            ((p.g.toInt() >> 4) << 4) |
            (p.b.toInt() >> 4);
        if (!_qWhite(q)) {
          nonWhite++;
        }
        if (q == runCol) {
          runLen++;
        } else {
          if (runLen >= runMin && !_qWhite(runCol)) {
            nBlocks++;
            maxLen = maxLen < runLen ? runLen : maxLen;
            colors.add(runCol);
            if (runStart < minX) {
              minX = runStart;
            }
            if (runStart + runLen > maxX) {
              maxX = runStart + runLen;
            }
          }
          runCol = q;
          runLen = 1;
          runStart = x;
        }
      }
      if (runLen >= runMin && !_qWhite(runCol)) {
        nBlocks++;
        maxLen = maxLen < runLen ? runLen : maxLen;
        colors.add(runCol);
        if (runStart < minX) {
          minX = runStart;
        }
        if (runStart + runLen > maxX) {
          maxX = runStart + runLen;
        }
      }
      feats[y] = _RowFeat(nBlocks, maxLen, nonWhite / w, colors, minX, maxX);
    }
    // 图例行判定
    final legendRows = <int, _RowFeat>{};
    feats.forEach((y, f) {
      final ok = f.nBlocks >= 3 &&
          f.maxLen <= w * 0.35 &&
          (f.maxLen >= 60 || (f.colors.length >= 3 && f.nonWhite <= 0.75));
      if (ok) {
        legendRows[y] = f;
      }
    });
    if (legendRows.isEmpty) {
      return null;
    }
    // 聚簇成带（图例行间白隙 <= 60px 同带）
    final ys = legendRows.keys.toList()..sort();
    final bands = <List<int>>[
      [ys.first, ys.first]
    ];
    for (final y in ys.skip(1)) {
      if (y - bands.last[1] <= 60) {
        bands.last[1] = y;
      } else {
        bands.add([y, y]);
      }
    }
    // 带外低信息检查（图例是独立区块，上下必有白隙/纯色隔离）
    bool quietOutside(int edge, bool below) {
      for (final d in [step, step * 2, step * 3]) {
        final y = below ? edge + d : edge - d;
        final f = feats[y];
        if (f == null) {
          return true; // 出图
        }
        if (f.nonWhite <= 0.10 || f.nBlocks <= 2) {
          return true;
        }
      }
      return false;
    }

    // 打分取最优带：块数和 + 底部位置加分（图例惯例在图纸底部）
    var bestScore = -1.0;
    Rect? bestRect;
    for (final b in bands) {
      if (b[1] - b[0] > h * 0.15) {
        continue;
      }
      if (!quietOutside(b[0], false) || !quietOutside(b[1], true)) {
        continue;
      }
      var nSum = 0, minX = 1 << 30, maxX = -(1 << 30);
      legendRows.forEach((y, f) {
        if (y >= b[0] && y <= b[1]) {
          nSum += f.nBlocks;
          if (f.minX < minX) {
            minX = f.minX;
          }
          if (f.maxX > maxX) {
            maxX = f.maxX;
          }
        }
      });
      final score = nSum + (b[0] + b[1]) / 2 / h * 50;
      if (score > bestScore) {
        bestScore = score;
        // 原图坐标 rect（上下 +10 余量；左右不加 pad——识别链按选区宽定
        // 放大倍率（3800 宽 cap），框得越宽小字放大越小，pic4 的 F5 在
        // pad 后 978 宽/scale3.88 下 ML Kit 漏读、948 宽/scale4.0 稳定）
        bestRect = Rect.fromLTRB(
          minX.clamp(0, w - 4).toDouble(),
          (b[0] - 10).clamp(0, h - 4).toDouble(),
          maxX.clamp(4, w).toDouble(),
          (b[1] + 10 + step).clamp(4, h).toDouble(),
        );
      }
    }
    // 原图 -> 显示坐标
    final rect = bestRect;
    if (rect == null) {
      return null;
    }
    final scale = _displaySize().width / w;
    return Rect.fromLTWH(
      rect.left * scale,
      rect.top * scale,
      rect.width * scale,
      rect.height * scale,
    );
  }

  /// 触发自动框选（按钮）：成功设选区并提示，失败提示手动框选
  void _autoSelectLegend() {
    final rect = _autoDetectLegend();
    if (rect == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("未识别到图例区，请手动框选")),
      );
      return;
    }
    setState(() => _legendSel = rect);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("已自动框选图例区，可拖动调整")),
    );
  }

  /// 选区（显示坐标）-> 图片坐标矩形；空选区返回全图
  (double, double, double, double) _selToImage(Rect? sel) {
    final image = _image!;
    final ds = _displaySize();
    if (sel != null && sel.width > 8 && sel.height > 8) {
      final scaleX = image.width / ds.width;
      final scaleY = image.height / ds.height;
      final rx = (sel.left * scaleX).clamp(0.0, image.width - 4.0);
      final ry = (sel.top * scaleY).clamp(0.0, image.height - 4.0);
      final rw = (sel.width * scaleX).clamp(4.0, image.width - rx);
      final rh = (sel.height * scaleY).clamp(4.0, image.height - ry);
      return (rx, ry, rw, rh);
    }
    return (0, 0, image.width.toDouble(), image.height.toDouble());
  }

  /// 格子中心 3×3 均值采样（避开网格线/边缘，抗高光干扰）
  (int, int, int) _sampleCenter(double cx, double cy, double cw, double ch) {
    final image = _image!;
    var sr = 0, sg = 0, sb = 0, n = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final px = (cx + dx * (cw / 6)).round();
        final py = (cy + dy * (ch / 6)).round();
        if (px < 0 || px >= image.width || py < 0 || py >= image.height) {
          continue;
        }
        final p = image.getPixel(px, py);
        sr += p.r.toInt();
        sg += p.g.toInt();
        sb += p.b.toInt();
        n++;
      }
    }
    return n == 0 ? (0, 0, 0) : (sr ~/ n, sg ~/ n, sb ~/ n);
  }

  // ==================== 步骤 1/2：图例识别 ====================

  /// 识别图例：框选区域自动检测行列 -> 逐格采样 -> 聚合用色清单
  void _scanLegend() {
    final image = _image;
    if (image == null) {
      return;
    }
    setState(() => _legendBusy = true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final (rx, ry, rw, rh) = _selToImage(_legendSel);
      final gray = <int>[];
      for (var y = ry.toInt(); y < ry + rh; y++) {
        for (var x = rx.toInt(); x < rx + rw; x++) {
          final p = image.getPixel(x, y);
          gray.add((p.r * 0.299 + p.g * 0.587 + p.b * 0.114).round());
        }
      }
      final det = detectGrid(gray, rw.toInt(), rh.toInt());
      var cols = 8, rows = 1;
      var pitchX = rw / cols, pitchY = rh / rows, offX = 0.0, offY = 0.0;
      if (det != null) {
        cols = det.cols;
        rows = det.rows;
        pitchX = det.pitchX;
        pitchY = det.pitchY;
        offX = det.offsetX;
        offY = det.offsetY;
      }
      final quantizer = Quantizer(_palette);
      final freq = <int, int>{};
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final cx = rx + offX + (c + 0.5) * pitchX;
          final cy = ry + offY + (r + 0.5) * pitchY;
          final (sr, sg, sb) = _sampleCenter(cx, cy, pitchX, pitchY);
          final idx = quantizer.nearestIndex(sr, sg, sb);
          freq[idx] = (freq[idx] ?? 0) + 1;
        }
      }
      // OCR 权威模式：印刷色号是图纸的权威声明。读到的色号直接构成清单
      // （宽松框选把图案区框进来时，杂色量化条目全部被剔净），颗数随配对填入；
      // 读不到（web/异常/配对太少）回退纯色块量化清单（现状行为，颗数手填）。
      final pairs = await _ocrLegendPairs(rx, ry, rw, rh);
      if (!mounted) {
        return;
      }
      for (final e in _legend) {
        e.countCtrl.dispose();
      }
      var entries = [
        for (final entry
            in freq.entries.toList()..sort((a, b) => b.value - a.value))
          _LegendEntry(entry.key),
      ];
      var ocrHit = 0;
      if (pairs != null && pairs.length >= 3) {
        final byOcr = <_LegendEntry>[];
        final seen = <int>{};
        for (final (idx, count) in pairs) {
          if (!seen.add(idx)) {
            continue; // 同一色号多次出现（图例重复/误读），取首条
          }
          final e = _LegendEntry(idx);
          e.countCtrl.text = count.toString();
          byOcr.add(e);
        }
        for (final e in entries) {
          e.countCtrl.dispose(); // fallback 条目被 OCR 清单取代
        }
        entries = byOcr;
        ocrHit = byOcr.length;
      }
      setState(() {
        _legendBusy = false;
        _legendColsCtrl.text = cols.toString();
        _legendRowsCtrl.text = rows.toString();
        _legend = entries;
        _legendByOcr = ocrHit > 0;
        _panelExpanded = true;
      });
      // 自动滚动定位已随滚动视口移除（双指捏合缩放 + 双指拖动平移可达图例区）
      if (ocrHit > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("已按图例印刷色号识别 $ocrHit 色，颗数自动读取 $ocrHit 条，请对照原图核对"),
          ),
        );
      } else if (pairs != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("框选区域未读到图例文字，以下按色块识别仅作参考；请只框选图纸底部的色块+色号+数字区域"),
          ),
        );
      } else if (det == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("未检出图例网格，按 8×1 均分识别；不准可改行列数后重新识别")),
        );
      }
    });
  }

  /// OCR 图例选区 -> [(印刷色号调色板索引, 印刷颗数)] 按阅读顺序
  ///
  /// 图纸图例每条目 = 色块 + 色号 + 颗数（印刷数字）；颗数有时跟在色号右侧同行，
  /// 有时印在色号/色块正下方。裁剪选区放大 3 倍喂 ML Kit，先收集全部色号/颗数
  /// element（带几何框），再走 [_pairLegendOcr] 两轮配对。
  /// web 平台不可用 / 异常 / 无配对时返回 null（调用方回退色块量化清单）。
  Future<List<(int, int)>?> _ocrLegendPairs(
    double rx,
    double ry,
    double rw,
    double rh, {
    String source = "手动框选",
  }) async {
    if (kIsWeb) {
      return null;
    }
    final image = _image;
    if (image == null) {
      return null;
    }
    // 【临时调试】每次识别尝试先清旧快照：本次失败不留上一张图的旧数据
    _ocrDebug = null;
    var dbgPath = ""; // 【临时调试】异常路径已产出的放大图路径（crop/写盘成功后才有值）
    var dbgW = 0;
    var dbgH = 0;
    try {
      final crop = img.copyCrop(
        image,
        x: rx.toInt(),
        y: ry.toInt(),
        width: rw.toInt(),
        height: rh.toInt(),
      );
      // 小字放大提高识别率：按高度放大到 ~960px（数字高 ~120px+）。
      // 固定 ×2/×3 在小字图例（色号字高 ~20 原图像素）下分辨率不足，
      // 实测 480 目标时第三行 5 条目只读出 3 个色号（2026-08-27 pic4），
      // 提到 960 后字高 ~74px 识别稳定；同时按宽度 cap 防超 ML Kit 输入上限
      var scale = (960 / rh).clamp(3.0, 8.0);
      final widthCap = 3800 / rw;
      if (scale > widthCap) {
        scale = widthCap;
      }
      final scaled = img.copyResize(crop, width: (crop.width * scale).round());
      final tmp = File(
        "${(await getTemporaryDirectory()).path}/legend_ocr.png",
      );
      await tmp.writeAsBytes(img.encodePng(scaled));
      dbgPath = tmp.path; // 【临时调试】记下放大图，异常路径的快照也要能看图
      dbgW = scaled.width;
      dbgH = scaled.height;

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(tmp.path),
      );
      await recognizer.close();

      // 精确 + 混淆变体查找表：variant -> 调色板索引
      final codeMap = <String, int>{};
      for (var i = 0; i < _palette.colors.length; i++) {
        final variants = <String>{};
        _collectCodeVariants(
          _palette.colors[i].id.toUpperCase(),
          0,
          "",
          variants,
        );
        for (final v in variants) {
          codeMap[v] ??= i; // 变体撞车时先到先得
        }
      }

      // 收集全部色号/颗数元素（带几何框：颗数可能在色号下一行，纯行内序配不上）；
      // 原图轮/反色轮共用同一收集逻辑
      List<_OcrElem> collect(RecognizedText result, int seqStart) {
        final out = <_OcrElem>[];
        var seq = seqStart;
        for (final block in result.blocks) {
          for (final line in block.lines) {
            for (final element in line.elements) {
              final text = element.text.trim().toUpperCase().replaceAll(
                    " ",
                    "",
                  );
              // 色号最多 4 字符（A1/H12 型），长文本是正文/杂项不做色号。
              // 纯数字文本即使命中混淆变体（8↔B 使 "81"→B1）也先按颗数
              // 收集——它更常是左侧色号的真颗数（"H7 81" 行的 81），
              // 配对后仍未消费的裸数字才兜底回落为色号
              if (text.length <= 4 && RegExp(r'^[A-Z]').hasMatch(text)) {
                final code = codeMap[text];
                if (code != null) {
                  final e = _OcrElem(seq++, element.boundingBox, code, null);
                  e.dbgText = element.text; // 【临时调试】保留原始文本
                  out.add(e);
                  continue;
                }
              }
              final n = _parseCountText(element.text);
              if (n != null) {
                final e = _OcrElem(seq++, element.boundingBox, null, n);
                e.dbgText = element.text; // 【临时调试】保留原始文本
                out.add(e);
              }
            }
          }
        }
        return out;
      }

      final elems = collect(recognized, 0);
      // 掉字母色号修复：深底反白/浅底浅字色号被 ML Kit 吞掉首字母，读成
      // 无括号纯数字 count（真颗数全部带括号 (N)）。当图内带括号颗数占绝对
      // 多数（≥6 且 ≥2×无括号数）时，无括号纯数字判定为掉字母色号：按数字
      // 后缀取色卡候选，用条目色块颜色（色号左侧最饱和区）最近匹配补全。
      // 后缀候选多（如 16 有 A16~H16），颜色是唯一决定性约束——图例色块
      // 印的就是该色号的实物色。
      var fixedCount = 0;
      final parenCount =
          elems.where((e) => e.code == null && e.dbgText.contains("(")).length;
      final bareCount =
          elems.where((e) => e.code == null && !e.dbgText.contains("(")).length;
      if (parenCount >= 6 && bareCount > 0 && bareCount * 2 <= parenCount) {
        final bare = elems
            .where((e) => e.code == null && !e.dbgText.contains("("))
            .toList();
        for (final e in bare) {
          final best = _fixCodeBySwatch(_palette, e.count!, e.rect, scaled);
          if (best == null) {
            continue;
          }
          final fixed = _OcrElem(e.seq, e.rect, best, null);
          fixed.dbgText = "${e.dbgText}→${_palette.colors[best].id}(色块补全)";
          elems.remove(e);
          elems.add(fixed);
          fixedCount++;
        }
      }
      // 孤儿颗数二次 OCR：带括号颗数的左侧同行/正上方近旁都没有色号元素，
      // 说明该条目的色号整条被 ML Kit 吞掉（深底白字识别不稳定；H7 案例：
      // (343) 正常读出而 H7 消失）。裁「左邻元素右缘 -> 颗数左缘」的空隙
      // 小区放大后单独再识别（原图 + 反色两轮），读出的色号补回元素表参与
      // 最终配对
      final orphanNotes = <String>[];
      final gapFixed = await _fixOrphanCountCodes(
        elems,
        scaled,
        codeMap,
        tmp,
        orphanNotes,
      );
      // 【临时调试】保存本次 OCR 快照（放大图 + 元素 + 配对前状态 + 框选区），正式版移除
      _ocrDebug = _OcrDebugInfo(
        source,
        tmp.path,
        scaled.width,
        scaled.height,
        elems,
        rx,
        ry,
        rw,
        rh,
      );
      // 【临时调试】元素明细同时打 logcat 与写文件（个别环境 logcat 收不到
      // flutter tag，文件可 adb pull，像素判读调试面板太费劲），正式版移除
      final dbgLines = <String>[
        "框选($source) $rx,$ry ${rw}x$rh elems=${elems.length}(色块补全$fixedCount, 空隙OCR$gapFixed, 括号颗数$parenCount/裸数字$bareCount) img=${scaled.width}x${scaled.height}"
            "${orphanNotes.isEmpty ? "" : " 色卡外色号=[${orphanNotes.toSet().join(" ")}]"}",
      ];
      for (final e in elems) {
        final kind = e.code != null
            ? "code:${_palette.colors[e.code!].id}"
            : "count:${e.count}";
        dbgLines.add(
          "elem $kind raw=\"${e.dbgText}\" "
          "rect=(${e.rect.left.toInt()},${e.rect.top.toInt()} "
          "${e.rect.width.toInt()}x${e.rect.height.toInt()})",
        );
      }
      final paired = _pairLegendOcr(elems).toList();
      // 配对后兜底：仍未消费的裸数字若命中混淆变体（掉字母色号 "81"→B1
      // 型），回落为色号条目（颗数 0，进未配色号提示让用户手填）。先配对
      // 后兜底的顺序保证 "H7 81" 型同行的 81 优先成为左侧色号的颗数，
      // 而不是被 B1 变体抢走导致 H7 悬空
      for (final e in [...elems]) {
        if (e.code != null || e.used || e.dbgText.contains("(")) {
          continue;
        }
        final t = e.dbgText.trim().toUpperCase().replaceAll(" ", "");
        final hit = t.length <= 4 ? codeMap[t] : null;
        if (hit == null) {
          continue;
        }
        final fixed = _OcrElem(e.seq, e.rect, hit, null);
        fixed.dbgText = "${e.dbgText}→${_palette.colors[hit].id}(变体兜底)";
        elems.remove(e);
        elems.add(fixed);
        paired.add((hit, 0));
      }
      final unpaired = elems
          .where((e) => e.code != null && e.pairedCount == null)
          .map((e) => "${_palette.colors[e.code!].id}(${e.dbgText})")
          .join(" ");
      dbgLines.add(
        "result=${paired.length}对 未配色号=[${unpaired.isEmpty ? "无" : unpaired}] ${[
          for (final (idx, n) in paired) "${_palette.colors[idx].id}=$n"
        ].join(" ")}",
      );
      for (final l in dbgLines) {
        debugPrint("【临时调试】$l");
      }
      File("${tmp.parent.path}/legend_ocr_log.txt").writeAsStringSync(
        dbgLines.join("\n"),
      );
      // 色卡外色号（如 MARD 卡没有的 H7）：无法入清单，明确提示用户手工补
      if (orphanNotes.isNotEmpty && mounted) {
        final names = orphanNotes.toSet().join("、");
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "识别到色卡外色号：$names（不在当前色卡，未入清单；如有需要请用\"添加颜色\"手工补）",
            ),
          ),
        );
      }
      return paired;
    } catch (_) {
      // 【临时调试】识别抛异常也记快照（source 标"异常"）：调试视图能看到放大图 + 0 个
      // 元素——比入口直接消失更有排障价值；放大图都没产出（crop 就失败）则保持 null
      if (dbgPath.isNotEmpty) {
        _ocrDebug = _OcrDebugInfo(
          "$source（异常）",
          dbgPath,
          dbgW,
          dbgH,
          const [],
          rx,
          ry,
          rw,
          rh,
        );
      }
      return null;
    }
  }

  /// 孤儿颗数修复：带括号颗数的左侧同行/正上方近旁都没有色号元素，说明该
  /// 条目的色号整条被 ML Kit 吞掉（H7 案例：(343) 读出而 H7 消失）。裁
  /// 「左邻元素右缘 -> 颗数左缘」的空隙小区放大后单独再识别，读出的色号
  /// 按空隙几何位置补回 [elems] 参与最终配对。
  /// 返回补全数；识别到但当前色卡没有的色号（如 MARD 卡外的 H7）收集到
  /// [orphanNotes] 供上层提示用户手工补。[tmpBase] 只取目录，临时文件名固定
  Future<int> _fixOrphanCountCodes(
    List<_OcrElem> elems,
    img.Image scaled,
    Map<String, int> codeMap,
    File tmpBase,
    List<String> orphanNotes,
  ) async {
    if (elems.isEmpty) {
      return 0;
    }
    var heightSum = 0.0;
    for (final e in elems) {
      heightSum += e.rect.height;
    }
    final avgH = heightSum > 0 ? heightSum / elems.length : 40.0;
    final codes = elems.where((e) => e.code != null).toList();

    // 色号近旁判定窗口与 _pairLegendOcr 两轮配对一致，配得上的不是孤儿
    bool hasCodeNearby(_OcrElem c) {
      for (final s in codes) {
        final dy = (s.rect.center.dy - c.rect.center.dy).abs();
        // 同行左侧窗口（配对轮 1 同款）
        if (dy <= avgH * 0.7 &&
            s.rect.right < c.rect.left + avgH * 0.5 &&
            c.rect.left - s.rect.right <= avgH * 4) {
          return true;
        }
        // 正上方窗口（配对轮 2 同款）
        if (s.rect.bottom <= c.rect.center.dy &&
            c.rect.center.dy - s.rect.top <= avgH * 2.5 &&
            (s.rect.center.dx - c.rect.center.dx).abs() <= avgH * 3) {
          return true;
        }
      }
      return false;
    }

    final orphans = elems
        .where(
          (e) => e.code == null && e.dbgText.contains("(") && !hasCodeNearby(e),
        )
        .toList();
    if (orphans.isEmpty) {
      return 0;
    }
    var nextSeq = 0;
    for (final e in elems) {
      if (e.seq >= nextSeq) {
        nextSeq = e.seq + 1;
      }
    }
    var fixed = 0;
    for (final c in orphans) {
      // 空隙左界：左邻元素（同行、在颗数左侧、不太远）的最大右缘
      var gLeft = c.rect.left - avgH * 6;
      for (final e in elems) {
        if (identical(e, c)) {
          continue;
        }
        final dy = (e.rect.center.dy - c.rect.center.dy).abs();
        if (dy > avgH * 0.8 || e.rect.right >= c.rect.left) {
          continue;
        }
        if (c.rect.left - e.rect.right > avgH * 8) {
          continue;
        }
        if (e.rect.right > gLeft) {
          gLeft = e.rect.right;
        }
      }
      if (gLeft < 0) {
        gLeft = 0;
      }
      final gapW = c.rect.left - gLeft;
      // 空隙窄于一个字高：位置上放不下色号，跳过
      if (gapW < avgH * 0.8) {
        continue;
      }
      final gTop = (c.rect.top - avgH * 0.8).clamp(0.0, scaled.height - 1.0);
      final gBottom = (c.rect.bottom + avgH * 0.8)
          .clamp(gTop + 1.0, scaled.height.toDouble());
      final gap = img.copyCrop(
        scaled,
        x: gLeft.toInt(),
        y: gTop.toInt(),
        width: gapW.toInt(),
        height: (gBottom - gTop).toInt(),
      );
      final hit = await _ocrGapText(
        img.copyResize(gap, width: gap.width * 2),
        File("${tmpBase.parent.path}/legend_ocr_gap.png"),
      );
      if (hit == null) {
        continue;
      }
      final (text, rel) = hit;
      // 空隙小区坐标 -> 放大图坐标（gap 又放大了 2 倍）
      final abs = Rect.fromLTWH(
        gLeft + rel.left / 2,
        gTop + rel.top / 2,
        rel.width / 2,
        rel.height / 2,
      );
      final code = codeMap[text];
      if (code != null) {
        final ne = _OcrElem(nextSeq++, abs, code, null);
        ne.dbgText = "$text(空隙OCR)";
        elems.add(ne);
        fixed++;
        continue;
      }
      // 掉字母裸数字：与全图轮同一套「后缀候选 + 色块颜色」补全
      final n = _parseCountText(text);
      if (n != null && n < 1000) {
        final idx = _fixCodeBySwatch(_palette, n, abs, scaled);
        if (idx != null) {
          final ne = _OcrElem(nextSeq++, abs, idx, null);
          ne.dbgText = "$text→${_palette.colors[idx].id}(空隙OCR+色块)";
          elems.add(ne);
          fixed++;
          continue;
        }
      }
      // 色号样式但色卡没有：提示用户用"添加颜色"补
      if (RegExp(r'^[A-Z]{1,2}\d{1,2}$').hasMatch(text)) {
        orphanNotes.add(text);
      }
    }
    return fixed;
  }

  /// 空隙小区单独识别：原图 + 反色（深底白字对反色更稳定）两轮，返回第一
  /// 个「像色号」的元素文本与其在 [gapBig] 中的框；每轮内色号样式优先于
  /// 裸数字，未识别到返回 null
  Future<(String, Rect)?> _ocrGapText(img.Image gapBig, File tmp) async {
    await tmp.writeAsBytes(img.encodePng(gapBig));
    final inverted = img.Image.from(gapBig);
    for (final p in inverted) {
      p.r = 255 - p.r;
      p.g = 255 - p.g;
      p.b = 255 - p.b;
    }
    final codeLike = RegExp(r'^[A-Z]{1,2}\d{1,2}$');
    final numLike = RegExp(r'^\d{1,3}$');
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      for (var round = 0; round < 2; round++) {
        if (round == 1) {
          await tmp.writeAsBytes(img.encodePng(inverted));
        }
        final recognized = await recognizer.processImage(
          InputImage.fromFilePath(tmp.path),
        );
        (String, Rect)? numHit;
        for (final block in recognized.blocks) {
          for (final line in block.lines) {
            for (final element in line.elements) {
              final text =
                  element.text.trim().toUpperCase().replaceAll(" ", "");
              if (text.length > 4) {
                continue; // 长文本是杂项，不是色号
              }
              if (codeLike.hasMatch(text)) {
                return (text, element.boundingBox);
              }
              if (numHit == null && numLike.hasMatch(text)) {
                numHit = (text, element.boundingBox);
              }
            }
          }
        }
        if (numHit != null) {
          return numHit;
        }
      }
    } finally {
      await recognizer.close();
    }
    return null;
  }

  /// 色号与颗数配对（两轮，几何驱动）
  ///
  /// 轮 1：颗数与色号同行且在其右侧 -> 最近者配对（A6 64 型布局）；
  /// 轮 2：未配色号找正下方紧邻数字（垂直近 + 水平接近，H2/118 型布局），
  ///       按色号从下往上处理——下方行的色号先消费下方数字，避免上一行
  ///       漏配的色号抢走下一行的颗数。
  /// 几何框缺失（个别平台 rect 退化）时退回收集序「色号后第一个数字」。
  List<(int, int)> _pairLegendOcr(List<_OcrElem> elems) {
    final codes = elems.where((e) => e.code != null).toList();
    final nums = elems.where((e) => e.count != null).toList();
    if (codes.isEmpty || nums.isEmpty) {
      return const [];
    }
    final heights = [
      for (final e in elems)
        if (e.rect.height > 0) e.rect.height,
    ];
    if (heights.isEmpty) {
      return _pairInSeqOrder(codes, nums);
    }
    final avgH = heights.reduce((a, b) => a + b) / heights.length;

    // 轮 1：同行右侧最近的未消费数字
    for (final c in codes) {
      _OcrElem? best;
      for (final n in nums) {
        if (n.used || n.rect.center.dx <= c.rect.center.dx) {
          continue;
        }
        if ((n.rect.center.dy - c.rect.center.dy).abs() > avgH * 0.7) {
          continue; // 不同行
        }
        if (n.rect.left - c.rect.right > avgH * 4) {
          continue; // 颗数紧邻色号；远处数字属邻条目，不抢（否则 B1 颗数
          // 漏读时会横跨抢走 H15 的颗数，H15 再抢 M3 的，链式错位尾部落空）
        }
        if (best == null || n.rect.left < best.rect.left) {
          best = n;
        }
      }
      if (best != null) {
        best.used = true;
        c.pairedCount = best.count;
        // 【临时调试】记录配对引用供调试视图画连线
        c.pairedWith = best;
        best.pairedWith = c;
      }
    }

    // 轮 2：正下方紧邻数字（从下往上的色号顺序）
    final belowFirst = [...codes]
      ..sort((a, b) => b.rect.top.compareTo(a.rect.top));
    for (final c in belowFirst) {
      if (c.pairedCount != null) {
        continue;
      }
      _OcrElem? best;
      for (final n in nums) {
        if (n.used || n.rect.top <= c.rect.center.dy) {
          continue; // 必须在色号下方
        }
        if (n.rect.top - c.rect.center.dy > avgH * 2.5) {
          continue; // 只认紧邻下方
        }
        final dx = (n.rect.center.dx - c.rect.center.dx).abs();
        if (dx > avgH * 3) {
          continue; // 水平接近（同列附近），不跨到邻条目
        }
        // 水平距离优先：正下方布局里水平对齐是本质特征；top 只差 OCR 框
        // 噪声几像素，若 top 优先会把邻条目的颗数抢过来（H2 抢到 H3 的 31）
        if (best == null ||
            dx < (best.rect.center.dx - c.rect.center.dx).abs() ||
            (dx == (best.rect.center.dx - c.rect.center.dx).abs() &&
                n.rect.top < best.rect.top)) {
          best = n;
        }
      }
      if (best != null) {
        best.used = true;
        c.pairedCount = best.count;
        // 【临时调试】记录配对引用供调试视图画连线
        c.pairedWith = best;
        best.pairedWith = c;
      }
    }

    // 阅读顺序输出：先上后下，同行先左后右。
    // 未配上颗数的色号也保留（颗数 0）：条目本身是真的（OCR 漏读了它的颗数），
    // 丢弃会让清单直接少一色（H15 曾因此消失）；颗数 0 用户在清单里手改即可
    final sorted = [...codes]..sort((a, b) {
        final dy = a.rect.top - b.rect.top;
        return dy.abs() > avgH * 0.7
            ? (dy > 0 ? 1 : -1)
            : a.rect.left.compareTo(b.rect.left);
      });
    return [for (final c in sorted) (c.code!, c.pairedCount ?? 0)];
  }

  /// 保底配对：按收集顺序「色号 -> 其后第一个数字」（几何框不可用时）
  List<(int, int)> _pairInSeqOrder(List<_OcrElem> codes, List<_OcrElem> nums) {
    final merged = [...codes, ...nums]..sort((a, b) => a.seq.compareTo(b.seq));
    final pairs = <(int, int)>[];
    int? cur;
    for (final e in merged) {
      if (e.code != null) {
        cur = e.code;
      } else if (cur != null) {
        pairs.add((cur, e.count!));
        cur = null; // 一条色号只配第一个数字，防后续串号
      }
    }
    return pairs;
  }

  /// 递归生成色号的 OCR 混淆变体（0/O、1/I/L、2/Z、5/S、6/G、8/B、4/A）
  void _collectCodeVariants(String src, int i, String cur, Set<String> out) {
    if (i == src.length) {
      out.add(cur);
      return;
    }
    _collectCodeVariants(src, i + 1, cur + src[i], out);
    for (final alt in _ocrConfusions[src[i]] ?? const <String>[]) {
      _collectCodeVariants(src, i + 1, cur + alt, out);
    }
  }

  /// 解析 OCR 数字文本为颗数（容忍逗号/空格/字母混淆），非法返回 null
  int? _parseCountText(String raw) {
    // 图例颗数常带包围符号印制（如 "A6 (64)"、全角括号、书名号等），先剥掉再解析；
    // 带括号的数字剥不掉会整条丢弃——色号找到了却配不上颗数就是这种格式
    var t = raw.trim().toUpperCase();
    t = t.replaceAll(RegExp(r"[()\[\]{}（）【】《》〈〉「」『』]"), "");
    t = t.replaceAll(",", "").replaceAll(" ", "");
    t = t
        .replaceAll("O", "0")
        .replaceAll("I", "1")
        .replaceAll("L", "1")
        .replaceAll("S", "5")
        .replaceAll("B", "8");
    if (!RegExp(r"^\d+$").hasMatch(t)) {
      return null;
    }
    final v = int.tryParse(t);
    return (v == null || v <= 0 || v > 100000) ? null : v;
  }

  /// 弹全色卡选色器（修正图例色号 / 添加颜色两用）
  Future<int?> _pickColorIndex() {
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("选择色号"),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: GridView.count(
            crossAxisCount: 6,
            children: [
              for (var i = 0; i < _palette.colors.length; i++)
                InkWell(
                  onTap: () => Navigator.pop(ctx, i),
                  // FittedBox 防格子竖向溢出：大色卡(291 色)行高较矮 + 系统字体
                  // 缩放时 Column(色块+文字) 放不下会渲染 "BOTTOM OVERFLOWED"
                  // 溢出条（用户看到的 "BOTTOM OV" 就是它），scaleDown 整体缩放兜底
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          color: Color.fromARGB(
                            255,
                            _palette.colors[i].r,
                            _palette.colors[i].g,
                            _palette.colors[i].b,
                          ),
                        ),
                        Text(
                          _palette.colors[i].id,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
        ],
      ),
    );
  }

  /// 添加颜色到图例清单（补 OCR 漏识别的色；已在清单则提示）
  Future<void> _addLegendColor() async {
    final idx = await _pickColorIndex();
    if (idx == null || !mounted) {
      return;
    }
    if (_legend.any((e) => e.paletteIndex == idx)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${_palette.colors[idx].id} 已在清单中")),
      );
      return;
    }
    setState(() => _legend.add(_LegendEntry(idx)));
  }

  /// 从图例清单删除条目（先释放控制器再移除，防二次 dispose）
  void _removeLegendEntry(_LegendEntry entry) {
    setState(() {
      entry.countCtrl.dispose();
      _legend.remove(entry);
    });
  }

  /// 清单行占比条：该色颗数占全部颗数的比例（条色即豆色），
  /// 未填颗数时返回空位保持行对齐
  Widget _countBar(_LegendEntry e, BeadColor c) {
    final cnt = e.expectedCount;
    var total = 0;
    for (final o in _legend) {
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

  /// 修正图例条目色号（若目标色已有条目则合并格数后删除本条）
  Future<void> _changeLegendColor(_LegendEntry entry) async {
    final idx = await _pickColorIndex();
    if (idx == null) {
      return;
    }
    setState(() {
      final dup =
          _legend.where((e) => e != entry && e.paletteIndex == idx).toList();
      if (dup.isNotEmpty) {
        dup.first.countCtrl.dispose();
        _legend.remove(dup.first);
      }
      _legend[_legend.indexOf(entry)] = _LegendEntry(idx);
      entry.countCtrl.dispose();
    });
  }

  // ==================== 步骤 3/4：主体网格对齐 ====================

  /// 自动检测主体网格（选区内投影分析），初始化微调参数
  void _autoDetect() {
    final image = _image;
    if (image == null) {
      return;
    }
    if (_useCornerAlign) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("自动检测只支持均分网格；歪图请拖四角对齐，或切回均分网格再检测")),
      );
      return;
    }
    setState(() => _detecting = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final (rx, ry, rw, rh) = _selToImage(_selDisplay);
      final gray = <int>[];
      for (var y = ry.toInt(); y < ry + rh; y++) {
        for (var x = rx.toInt(); x < rx + rw; x++) {
          final p = image.getPixel(x, y);
          gray.add((p.r * 0.299 + p.g * 0.587 + p.b * 0.114).round());
        }
      }
      final result = detectGrid(gray, rw.toInt(), rh.toInt());
      if (!mounted) {
        return;
      }
      setState(() {
        _detecting = false;
        if (result != null) {
          _colsCtrl.text = result.cols.toString();
          _rowsCtrl.text = result.rows.toString();
          _pitchX = result.pitchX;
          _pitchY = result.pitchY;
          _offX = result.offsetX;
          _offY = result.offsetY;
        }
      });
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("未检测到网格，请框选更规整的区域或手动填行列数")),
        );
      }
    });
  }

  /// 行列数手改 -> 按选区均分重算网格参数（放弃自动检测结果）
  void _recomputePitchFromField() {
    if (_useCornerAlign) {
      // 四角模式：pitch/off 不参与，但覆盖层 _CornerGridPainter 依赖
      // cols/rows（经 controller 文本读取），必须 rebuild 才会重画
      setState(() {});
      return;
    }
    final cols = int.tryParse(_colsCtrl.text) ?? 0;
    final rows = int.tryParse(_rowsCtrl.text) ?? 0;
    if (cols < 1 || rows < 1 || _image == null) {
      return;
    }
    final (_, _, rw, rh) = _selToImage(_selDisplay);
    setState(() {
      _pitchX = rw / cols;
      _pitchY = rh / rows;
      _offX = 0;
      _offY = 0;
    });
  }

  /// 格子大小 ±（图片坐标步进 0.2，X/Y 等比缩放，网格锚点不动）
  void _adjustPitch(double step) {
    if (_pitchX <= 0 || _pitchY <= 0) {
      return;
    }
    final f = (_pitchX + step) / _pitchX;
    if (f <= 0) {
      return;
    }
    setState(() {
      _pitchX *= f;
      _pitchY *= f;
    });
  }

  /// 微移网格（步进 = 格距 / 8）
  void _nudge(double dx, double dy) {
    if (_pitchX <= 0 || _pitchY <= 0) {
      return;
    }
    setState(() {
      _offX += dx * _pitchX / 8;
      _offY += dy * _pitchY / 8;
    });
  }

  // ==================== 四角对齐 ====================

  /// 切换对齐模式；首次进四角模式用选区（或全图）四角初始化角点
  void _switchAlignMode(bool corner) {
    setState(() {
      _useCornerAlign = corner;
      _cornerDragIdx = -1;
      if (corner && (_cornerPts == null || _cornerPts!.length != 4)) {
        _cornerPts = _defaultCorners();
      }
    });
  }

  /// 默认四角：选区四角（无选区=全图四角）
  List<Offset> _defaultCorners() {
    final ds = _displaySize();
    final sel = (_selDisplay != null && _selDisplay!.width > 8)
        ? _selDisplay!
        : Rect.fromLTWH(0, 0, ds.width, ds.height);
    return [sel.topLeft, sel.topRight, sel.bottomRight, sel.bottomLeft];
  }

  /// 重置四角回默认位置
  void _resetCorners() {
    setState(() => _cornerPts = _defaultCorners());
  }

  /// 拖角更新（_imageStage 手势回调，p 为显示坐标）
  void _onCornerDrag(int idx, Offset p) {
    if (_cornerPts == null || idx < 0 || idx >= 4) {
      return;
    }
    setState(() => _cornerPts![idx] = p);
  }

  // ==================== 识别 + 复核 ====================

  /// 限色识别：图例勾选色为候选集，逐格中心采样 -> Lab 最近色；偏色过大判空白
  void _recognize() {
    final image = _image;
    if (image == null) {
      return;
    }
    final cols = int.tryParse(_colsCtrl.text) ?? 0;
    final rows = int.tryParse(_rowsCtrl.text) ?? 0;
    if (cols < 4 || rows < 4 || cols > 400 || rows > 400) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("行列数须在 4-400 之间")));
      return;
    }
    final useCorner =
        _useCornerAlign && _cornerPts != null && _cornerPts!.length == 4;
    if (!useCorner && (_pitchX <= 0 || _pitchY <= 0)) {
      _recomputePitchFromField();
    }
    setState(() => _recognizing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final (rx, ry, _, _) = _selToImage(_selDisplay);
      // 四角映射模式：角点（显示坐标）-> 图片坐标，采样中心/格宽高全部
      // 经双线性映射反求（与覆盖层网格线同源，所见即所采）
      var qImg = const <Offset>[];
      if (useCorner) {
        final ds = _displaySize();
        final image = _image!;
        qImg = [
          for (final p in _cornerPts!)
            Offset(
              p.dx * image.width / ds.width,
              p.dy * image.height / ds.height,
            ),
        ];
      }
      final candidates = <int>{
        for (final e in _legend) e.paletteIndex,
      };
      final quantizer = Quantizer(_palette);
      final grid = List<int>.filled(cols * rows, 0);
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          double cx, cy, cw, ch;
          if (useCorner) {
            final tl = _bilinearQuad(qImg, c / cols, r / rows);
            final tr = _bilinearQuad(qImg, (c + 1) / cols, r / rows);
            final bl = _bilinearQuad(qImg, c / cols, (r + 1) / rows);
            final br = _bilinearQuad(qImg, (c + 1) / cols, (r + 1) / rows);
            final center = _bilinearQuad(
              qImg,
              (c + 0.5) / cols,
              (r + 0.5) / rows,
            );
            cx = center.dx;
            cy = center.dy;
            cw = ((tl - tr).distance + (bl - br).distance) / 2;
            ch = ((tl - bl).distance + (tr - br).distance) / 2;
          } else {
            cx = rx + _offX + (c + 0.5) * _pitchX;
            cy = ry + _offY + (r + 0.5) * _pitchY;
            cw = _pitchX;
            ch = _pitchY;
          }
          final (sr, sg, sb) = _sampleCenter(cx, cy, cw, ch);
          final (idx, distSq) = quantizer.nearestWithin(
            sr,
            sg,
            sb,
            candidates.isEmpty ? null : candidates,
          );
          grid[r * cols + c] =
              (_blankEnable && distSq > _blankDistSq) ? -1 : idx;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _model = PatternModel(
          width: cols,
          height: rows,
          grid: grid,
          paletteIds: [for (final c in _palette.colors) c.id],
        );
        _recognizing = false;
        _reviewColor = -2;
        _picked.clear();
        _stage = _Stage.review;
      });
    });
  }

  void _openEditor() {
    final model = _model;
    if (model == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorPage(model: model, palette: _palette),
      ),
    );
  }

  /// 图例标注数量（无勾选条目/未填返回 null = 不对账）
  int? _expectedOf(int paletteIndex) {
    for (final e in _legend) {
      if (e.paletteIndex == paletteIndex) {
        return e.expectedCount;
      }
    }
    return null;
  }

  /// 全选当前复核色的全部格子
  void _selectAllOfCurrent() {
    final model = _model;
    if (model == null || _reviewColor == -2) {
      return;
    }
    setState(() {
      for (var i = 0; i < model.grid.length; i++) {
        if (model.grid[i] == _reviewColor) {
          _picked.add(i);
        }
      }
    });
  }

  /// 把选中格子归类到目标色（-1 = 空白）
  Future<void> _classifyPickedTo(int target) async {
    if (_picked.isEmpty || target == _reviewColor) {
      return;
    }
    final label = target < 0 ? "空白" : _palette.colors[target].id;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("手工归类"),
        content: Text("把选中的 ${_picked.length} 格归类为「$label」？"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("归类"),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    final model = _model!;
    setState(() {
      for (final i in _picked) {
        model.grid[i] = target;
      }
      _picked.clear();
    });
  }

  /// 进入「框选主体」阶段（该阶段第一动作是重新框选）
  void _goAlign() {
    setState(() => _stage = _Stage.align);
  }

  // ==================== 布局 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(switch (_stage) {
              _Stage.pick => "图纸还原 · 选图",
              _Stage.legend => "图纸还原 · ① 框图例",
              _Stage.align => "图纸还原 · ② 网格对齐",
              _Stage.review => "图纸还原 · ③ 识别复核",
            }),
            Text(
              "构建 $appBuildLabel",
              style: const TextStyle(fontSize: 10, color: Colors.black38),
            ),
          ],
        ),
        actions: [
          // 复核发现问题多半是网格没对齐：一键回对齐阶段微调后重识别
          // （网格参数/选区/图例都保留，直接可调）
          if (_stage == _Stage.review)
            TextButton.icon(
              onPressed: _goAlign,
              icon: const Icon(Icons.undo, size: 18),
              label: const Text("回对齐"),
            ),
          // 自动框选图例区（载入时已自动尝试过，这里供失败重试/重新选）
          if (_stage == _Stage.legend)
            IconButton(
              onPressed: _autoSelectLegend,
              icon: const Icon(Icons.auto_awesome),
              tooltip: "自动框选图例",
            ),
          // 【临时调试】图例 OCR 调试入口：识别后即可查看放大图/元素/配对，正式版移除
          if (_stage == _Stage.legend && _ocrDebug != null)
            IconButton(
              onPressed: _showOcrDebug,
              icon: const Icon(Icons.bug_report),
              tooltip: "OCR 调试",
            ),
          if (_stage == _Stage.legend || _stage == _Stage.align)
            PopupMenuButton<String>(
              tooltip: "切换色卡",
              icon: const Icon(Icons.palette),
              onSelected: (id) => _switchPalette(id),
              itemBuilder: (_) => [
                for (final p in _palettes)
                  PopupMenuItem(
                    value: p.id,
                    child: Row(
                      children: [
                        if (p.id == _paletteId)
                          const Icon(Icons.check, size: 18),
                        Text(p.label),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: switch (_stage) {
        _Stage.pick => _buildPick(),
        _Stage.legend => _buildLegend(),
        _Stage.align => _buildAlign(),
        _Stage.review => _buildReview(),
      },
    );
  }

  /// 切换色卡（图例清单作废，需重新识别）
  Future<void> _switchPalette(String id) async {
    if (id == _paletteId) {
      return;
    }
    await PaletteRegistry.saveSelectedId(id);
    if (!mounted) {
      return;
    }
    final target = _palettes.where((p) => p.id == id).first;
    setState(() {
      _paletteId = id;
      _palette = target.palette;
      for (final e in _legend) {
        e.countCtrl.dispose();
      }
      _legend = [];
      _legendByOcr = false;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text("已切换到${target.label}，图例需重新识别")));
  }

  /// 阶段一：选图入口
  Widget _buildPick() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_on, size: 72, color: Colors.black26),
            const SizedBox(height: 16),
            const Text("导入拼豆图纸，五步还原为可编辑图案", textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              "框图例 → 核对用色 → 对齐网格 → 识别 → 手工纠错",
              style: TextStyle(fontSize: 12, color: Colors.black45),
            ),
            const SizedBox(height: 32),
            FilledButton.tonalIcon(
              onPressed: () => _pickImage(ImageSource.gallery),
              icon: const Icon(Icons.photo_library),
              label: const Text("从相册选择图纸"),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => _pickImage(ImageSource.camera),
              icon: const Icon(Icons.photo_camera),
              label: const Text("拍照图纸"),
            ),
          ],
        ),
      ),
    );
  }

  /// 命中选区把手（返回 0-7 索引，未命中返回 -1）
  ///
  /// 布局：0─1─2 / 3   4 / 5─6─7（四角 + 四边中点），命中半径按手指友好的
  /// 22px；扁框（图例条带）按短边 1/3 收缩——否则半径 22 超过框高一半，
  /// 框中心拖动会误命中上/下边中把手，整框平移永远触发不了
  int _hitSelHandle(Rect sel, Offset p) {
    final radius = math.min(22.0, math.min(sel.width, sel.height) / 3);
    final pts = [
      sel.topLeft,
      Offset(sel.center.dx, sel.top),
      sel.topRight,
      Offset(sel.left, sel.center.dy),
      Offset(sel.right, sel.center.dy),
      sel.bottomLeft,
      Offset(sel.center.dx, sel.bottom),
      sel.bottomRight,
    ];
    for (var i = 0; i < pts.length; i++) {
      if ((pts[i] - p).distance <= radius) {
        return i;
      }
    }
    return -1;
  }

  /// 按把手索引更新选区（角把手锁对角、边中把手只动一条边），防反转最小 4px
  Rect _applySelHandle(Rect sel, int h, Offset p) {
    var l = sel.left;
    var t = sel.top;
    var r = sel.right;
    var b = sel.bottom;
    if (h == 0 || h == 3 || h == 5) {
      l = p.dx;
    }
    if (h == 2 || h == 4 || h == 7) {
      r = p.dx;
    }
    if (h == 0 || h == 1 || h == 2) {
      t = p.dy;
    }
    if (h == 5 || h == 6 || h == 7) {
      b = p.dy;
    }
    if (r - l < 4) {
      if (h == 0 || h == 3 || h == 5) {
        l = r - 4;
      } else {
        r = l + 4;
      }
    }
    if (b - t < 4) {
      if (h == 0 || h == 1 || h == 2) {
        t = b - 4;
      } else {
        b = t + 4;
      }
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  /// 图片 + 统一框选手势 + 可选网格覆盖（图例/对齐阶段共用）
  ///
  /// 单指：空白处拖动 = 画新选区；选区内部拖动 = 整框平移（框完想挪位置
  /// 不必重画）；四角/四边把手 = 微调大小。双指：捏合缩放 + 拖动平移原图
  /// （InteractiveViewer 承担，查看大图不需要独立的查看模式）。
  /// [cornerPts] 非空时四角把手接管手势（拖角微调，非角区拖动不画框防误触清角）。
  Widget _imageStage({
    required Rect? sel,
    required void Function(Rect) onSel,
    CustomPainter? overlay,
    List<Offset>? cornerPts,
    void Function(int, Offset)? onCornerDrag,
  }) {
    final ds = _displaySize();
    return Stack(
      children: [
        // 双指捏合缩放原图（小图/微信压缩图的图例条带不放大看不清、框不准）。
        // InteractiveViewer 必须直接持有有界 viewport：之前套在
        // SingleChildScrollView 里（child 拿到无界高度约束），其变换矩阵
        // 算坏、child 整块渲染消失（图区纯白，2026-08-26 模拟器二分实测：
        // 同字节同页面，裸 Image.memory 彩、InteractiveViewer 包装白）。
        // 查看模式的"拖动浏览"由滚轮平移 + 双指拖动承担。
        LayoutBuilder(
          builder: (ctx, cons) => InteractiveViewer(
            maxScale: 8,
            minScale: 1,
            transformationController: _viewerCtrl,
            // 滚轮缩放禁用开关：InteractiveViewer 滚轮缩放量 = exp(-dy/scaleFactor)，
            // 取无穷大恒为 1（源码 _receivedPointerSignal），滚轮成无操作——
            // 平移浏览交给 child 内 Listener（_onImgPointerSignal）；scaleFactor
            // 只作用于滚轮，双指捏合缩放不受影响（不能用 scaleEnabled:false，
            // 它会连捏合一起禁掉）
            scaleFactor: double.infinity,
            // 单指手势留给框选（child GestureDetector 优先）；双指捏合缩放、
            // 双指拖动平移由 scale 手势自带 translation 承担
            panEnabled: false,
            constrained: false,
            child: Listener(
              // 滚轮=纵向平移浏览（图例清单展开会挡住图片下部，靠滚轮看回）
              onPointerSignal: (s) => _onImgPointerSignal(s, cons),
              child: GestureDetector(
                onPanDown: (d) {
                  // 每次按下先清上一轮拖画残留（上轮被双指取消时不会走到 End）
                  _drawFrom = null;
                  _drawActive = false;
                  // 四角把手优先：命中则进入拖角，不走框选
                  if (cornerPts != null) {
                    _cornerDragIdx = -1;
                    for (var i = 0; i < cornerPts.length; i++) {
                      if ((cornerPts[i] - d.localPosition).distance <= 30) {
                        _cornerDragIdx = i;
                        onCornerDrag?.call(i, d.localPosition);
                        return;
                      }
                    }
                    return; // 非角区拖动不画框：防误触清掉四角
                  }
                  // 落点在把手上 -> 拖把手微调选区；选区内部 -> 整框平移
                  // （第一次框完想挪位置直接拖走，不必重画）；空白 -> 画新框
                  // （只记起点：双指缩放第一指落框外时不破坏现有选区）
                  _selHandleDrag = (sel != null && sel.width > 2)
                      ? _hitSelHandle(sel, d.localPosition)
                      : -1;
                  if (_selHandleDrag < 0) {
                    if (sel != null &&
                        sel.width > 2 &&
                        sel.contains(d.localPosition)) {
                      _selMoveFrom = d.localPosition;
                      _selMoveBase = sel;
                    } else {
                      _drawFrom = d.localPosition;
                    }
                  }
                },
                onPanUpdate: (d) {
                  if (_cornerDragIdx >= 0) {
                    onCornerDrag?.call(_cornerDragIdx, d.localPosition);
                    return;
                  }
                  if (cornerPts != null) {
                    return;
                  }
                  if (_selMoveFrom != null && _selMoveBase != null) {
                    // 整框平移：按起点位移移动选区，clamp 图内防拖丢
                    final delta = d.localPosition - _selMoveFrom!;
                    final base = _selMoveBase!;
                    final left = (base.left + delta.dx).clamp(
                      0.0,
                      ds.width - base.width,
                    );
                    final top = (base.top + delta.dy).clamp(
                      0.0,
                      ds.height - base.height,
                    );
                    onSel(Rect.fromLTWH(left, top, base.width, base.height));
                    return;
                  }
                  if (_selHandleDrag >= 0 && sel != null) {
                    onSel(
                      _applySelHandle(sel, _selHandleDrag, d.localPosition),
                    );
                    return;
                  }
                  if (_drawFrom != null) {
                    // 启动阈值：累计位移 <10 逻辑像素视为轻点微动，不落新框
                    // （真实鼠标轻点常带 1-2px 抖动，原首帧即画会覆盖掉现有选区）
                    if (!_drawActive) {
                      if ((d.localPosition - _drawFrom!).distance < 10) {
                        return;
                      }
                      _drawActive = true;
                    }
                    onSel(Rect.fromPoints(_drawFrom!, d.localPosition));
                  }
                },
                onPanEnd: (_) {
                  // 只清"本轮真的画过"的误触小框；未达启动阈值的轻点完全不动现有选区
                  if (_drawActive &&
                      sel != null &&
                      (sel.width < 4 || sel.height < 4)) {
                    onSel(Rect.zero);
                  }
                  _drawFrom = null;
                  _drawActive = false;
                  _cornerDragIdx = -1;
                  _selHandleDrag = -1;
                  _selMoveFrom = null;
                  _selMoveBase = null;
                },
                // 双指缩放时 pan 手势在竞技场输给 scale：清状态防残留
                onPanCancel: () {
                  _drawFrom = null;
                  _drawActive = false;
                  _cornerDragIdx = -1;
                  _selHandleDrag = -1;
                  _selMoveFrom = null;
                  _selMoveBase = null;
                },
                child: Stack(
                  children: [
                    Image.memory(
                      _displayBytes ?? _bytes!,
                      width: ds.width,
                      height: ds.height,
                      fit: BoxFit.fill,
                      // 解码失败必须可见（红底提示），不能静默白屏让用户"不知发生了什么"
                      errorBuilder: (ctx, error, stack) {
                        return ColoredBox(
                          color: Colors.redAccent,
                          child: Center(
                            child: Text(
                              "显示解码失败: $error",
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        );
                      },
                    ),
                    if (sel != null && sel.width > 2)
                      Positioned.fill(
                        child: CustomPaint(painter: _SelPainter(sel)),
                      ),
                    if (overlay != null)
                      Positioned.fill(
                        child: CustomPaint(painter: overlay, size: ds),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_decoding)
          Positioned.fill(
            child: Container(
              color: Colors.white,
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text("正在解码图片…", style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 滚轮纵向平移浏览图区：滚轮缩放已被 scaleFactor:infinity 禁掉
  ///（见 _imageStage 内注释），此处是滚轮的唯一效果。
  /// 平移量 clamp 在 [viewport-图, 0]，滚到底不再滚动；缩放后按当前
  /// scale 折算可平移范围。图例清单面板挡住图片下部时靠滚轮回看。
  void _onImgPointerSignal(PointerSignalEvent s, BoxConstraints cons) {
    if (s is! PointerScrollEvent) {
      return;
    }
    final cur = _viewerCtrl.value;
    final scale = cur.storage[0];
    final ds = _displaySize();
    final minX = math.min(0.0, cons.maxWidth - ds.width * scale);
    final minY = math.min(0.0, cons.maxHeight - ds.height * scale);
    final dx =
        (cur.getTranslation().x - s.scrollDelta.dx).clamp(minX, 0.0).toDouble();
    final dy =
        (cur.getTranslation().y - s.scrollDelta.dy).clamp(minY, 0.0).toDouble();
    // 直设矩阵元（translate/scale 已废弃）：纯平移 + 等比缩放，无旋转
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(0, 3, dx);
    m.setEntry(1, 3, dy);
    _viewerCtrl.value = m;
  }

  /// 当前网格覆盖层（无有效参数返回 null）
  CustomPainter? _mainOverlay() {
    final cols = int.tryParse(_colsCtrl.text) ?? 0;
    final rows = int.tryParse(_rowsCtrl.text) ?? 0;
    if (cols < 1 || rows < 1) {
      return null;
    }
    if (_useCornerAlign) {
      final pts = _cornerPts;
      if (pts == null || pts.length != 4) {
        return null;
      }
      return _CornerGridPainter(pts: pts, cols: cols, rows: rows);
    }
    if (_pitchX <= 0 || _pitchY <= 0) {
      return null;
    }
    final (rx, ry, _, _) = _selToImage(_selDisplay);
    final ds = _displaySize();
    final image = _image!;
    return _GridOverlayPainter(
      cols: cols,
      rows: rows,
      originDx: (rx + _offX) * ds.width / image.width,
      originDy: (ry + _offY) * ds.height / image.height,
      pitchDx: _pitchX * ds.width / image.width,
      pitchDy: _pitchY * ds.height / image.height,
    );
  }

  /// 图例网格覆盖层（按图例行列均分）
  _GridOverlayPainter? _legendOverlay() {
    final cols = int.tryParse(_legendColsCtrl.text) ?? 0;
    final rows = int.tryParse(_legendRowsCtrl.text) ?? 0;
    if (cols < 1 || rows < 1) {
      return null;
    }
    final (rx, ry, rw, rh) = _selToImage(_legendSel);
    final ds = _displaySize();
    final image = _image!;
    return _GridOverlayPainter(
      cols: cols,
      rows: rows,
      originDx: rx * ds.width / image.width,
      originDy: ry * ds.height / image.height,
      pitchDx: rw * ds.width / image.width / cols,
      pitchDy: rh * ds.height / image.height / rows,
    );
  }

  /// 阶段二：框选图例 + 识别 + 清单核对
  Widget _buildLegend() {
    final scanned = _legend.isNotEmpty;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _imageStage(
              sel: _legendSel,
              onSel: (r) => setState(() => _legendSel = r),
              overlay: scanned && !_legendByOcr
                  ? _legendOverlay()
                  : null, // 网格层仅量化模式有参考意义
            ),
          ),
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
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _legendBusy ? null : _scanLegend,
                        icon: _legendBusy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.document_scanner, size: 18),
                        label: Text(_legendBusy ? "识别中…" : "识别图例"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(onPressed: _goAlign, child: const Text("跳过图例")),
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
                        onTap: () =>
                            setState(() => _panelExpanded = !_panelExpanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(
                                _panelExpanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.keyboard_arrow_up,
                                size: 22,
                                color: Colors.black54,
                              ),
                              const SizedBox(width: 2),
                              Expanded(
                                child: Text(
                                  _panelExpanded
                                      ? "图例 ${_legend.length} 色（点此收起，露出原图核对）"
                                      : "图例 ${_legend.length} 色（点此展开核对清单）",
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
                    if (!_panelExpanded)
                      FilledButton.tonal(
                        onPressed: _goAlign,
                        child: const Text("下一步"),
                      ),
                  ],
                ),
                if (_panelExpanded) ...[
                  const SizedBox(height: 4),
                  if (!_legendByOcr)
                    Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: TextField(
                            controller: _legendColsCtrl,
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
                            controller: _legendRowsCtrl,
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
                            onPressed: _legendBusy ? null : _scanLegend,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text("重新识别"),
                          ),
                        ),
                      ],
                    )
                  else
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _legendBusy ? null : _scanLegend,
                        icon: _legendBusy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(_legendBusy ? "识别中…" : "重新框选后识别"),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 168,
                    child: ListView.builder(
                      itemCount: _legend.length + 1,
                      itemBuilder: (_, i) {
                        // 末尾常驻「添加颜色」行：补 OCR 漏识别的色
                        if (i == _legend.length) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _addLegendColor,
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text("添加颜色"),
                            ),
                          );
                        }
                        final e = _legend[i];
                        final c = _palette.colors[e.paletteIndex];
                        // 行距 3：isDense 输入框行与行紧贴会上下遮挡
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Tooltip(
                                message: "点击修改色号",
                                child: InkWell(
                                  onTap: () => _changeLegendColor(e),
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
                                child: _countBar(e, c),
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
                                  onPressed: () => _removeLegendEntry(e),
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
                          onPressed: _goAlign,
                          icon: const Icon(Icons.arrow_forward),
                          label: Text(
                            "下一步：框选主体（${_legend.length}色）",
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
  }

  /// 【临时调试】图例 OCR 调试视图：喂给 ML Kit 的放大图 + 元素框 + 配对连线
  ///
  /// 用于排查「为什么框选后读出来是错的」：
  /// - 图本身不对（框错区域）-> 放大图一眼看出
  /// - 字读错（OCR 误识别）-> 元素列表看原始文本
  /// - 配对错（色号-颗数连错线）-> 红色连线直观可见
  /// 正式版随调试功能一起移除。
  void _showOcrDebug() {
    final dbg = _ocrDebug;
    if (dbg == null) {
      return;
    }
    final codes = dbg.elems.where((e) => e.code != null).length;
    final nums = dbg.elems.where((e) => e.count != null).length;
    final paired =
        dbg.elems.where((e) => e.code != null && e.pairedCount != null).length;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.bug_report, size: 18, color: Colors.black54),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "OCR 调试 · ${dbg.source} · 色号$codes/颗数$nums/配上$paired对",
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            // 【临时调试】框选区（原图坐标）：报坐标可精确复现同一次框选
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 16, 4),
              child: Text(
                "框选(原图坐标): x=${dbg.selX.round()} y=${dbg.selY.round()} · ${dbg.selW.round()}×${dbg.selH.round()}",
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),
            // 放大图 1:1 显示（横向滚动看细节），元素框与连线直接用图坐标
            Expanded(
              flex: 6,
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: dbg.imgW.toDouble(),
                    height: dbg.imgH.toDouble(),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 放大图宽可达 ~4800，超 GLES 纹理上限（2048）会渲染成
                        // 一条带——超限时按解码目标宽限幅（等比，不放大小图）
                        Image.file(
                          File(dbg.imgPath),
                          fit: BoxFit.fill,
                          cacheWidth: dbg.imgW > kDisplayMaxEdge
                              ? kDisplayMaxEdge
                              : null,
                        ),
                        CustomPaint(painter: _OcrDebugPainter(dbg.elems)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 元素明细：原始文本 + 几何框 + 配对结果
            Expanded(
              flex: 4,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                itemCount: dbg.elems.length,
                itemBuilder: (_, i) {
                  final e = dbg.elems[i];
                  final geo = "(${e.rect.left.toInt()},${e.rect.top.toInt()} "
                      "${e.rect.width.toInt()}×${e.rect.height.toInt()})";
                  return Text(
                    e.code != null
                        ? "色号「${e.dbgText}」$geo → ${e.pairedCount ?? "✗未配上"}"
                        : "颗数「${e.dbgText}」$geo ${e.used ? "已消费" : "未消费"}",
                    style: TextStyle(
                      fontSize: 11,
                      color: e.code != null
                          ? (e.pairedCount != null ? Colors.green : Colors.red)
                          : Colors.blue,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 阶段三：框选主体 + 网格对齐（均分网格自动检测/微移 + 四角对齐透视矫正）
  Widget _buildAlign() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _imageStage(
              // 四角模式选区框不显示（四角即区域），手势也只认角把手
              sel: _useCornerAlign ? null : _selDisplay,
              onSel: (r) => setState(() => _selDisplay = r),
              overlay: _mainOverlay(),
              cornerPts: _useCornerAlign ? _cornerPts : null,
              onCornerDrag: _onCornerDrag,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.grid_4x4, size: 18),
                    label: Text("均分网格"),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.crop_free, size: 18),
                    label: Text("四角对齐"),
                  ),
                ],
                selected: {_useCornerAlign},
                onSelectionChanged: (sel) => _switchAlignMode(sel.first),
              ),
              const SizedBox(height: 6),
              Text(
                _useCornerAlign
                    ? "把 4 个圆点拖到图案网格的四个角（斜拍/歪图用此模式，网格随四角透视贴合）"
                    : _pitchX > 0
                        ? "网格已覆盖（蓝线）· 不对齐就微调下方参数"
                        : "② 框选主体图案区域，或直接自动检测",
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _colsCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _recomputePitchFromField(),
                      decoration: const InputDecoration(
                        labelText: "列数",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text("×"),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _rowsCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _recomputePitchFromField(),
                      decoration: const InputDecoration(
                        labelText: "行数",
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed:
                        (_detecting || _useCornerAlign) ? null : _autoDetect,
                    icon: _detecting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, size: 18),
                    label: const Text("自动检测"),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_useCornerAlign)
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _resetCorners,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text("重置四角"),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "填好行列数，拖四角压住格线后开始识别",
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    const Text("格子大小"),
                    IconButton(
                      onPressed: _pitchX > 0 ? () => _adjustPitch(-0.2) : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text(_pitchX > 0 ? _pitchX.toStringAsFixed(2) : "--"),
                    IconButton(
                      onPressed: _pitchX > 0 ? () => _adjustPitch(0.2) : null,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                    const VerticalDivider(width: 12),
                    const Text("微移"),
                    IconButton(
                      onPressed: _pitchX > 0 ? () => _nudge(-1, 0) : null,
                      icon: const Icon(Icons.arrow_left),
                      tooltip: "左移",
                    ),
                    IconButton(
                      onPressed: _pitchX > 0 ? () => _nudge(0, -1) : null,
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: "上移",
                    ),
                    IconButton(
                      onPressed: _pitchX > 0 ? () => _nudge(0, 1) : null,
                      icon: const Icon(Icons.arrow_downward),
                      tooltip: "下移",
                    ),
                    IconButton(
                      onPressed: _pitchX > 0 ? () => _nudge(1, 0) : null,
                      icon: const Icon(Icons.arrow_right),
                      tooltip: "右移",
                    ),
                  ],
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        "偏色过大识别为空白格",
                        style: TextStyle(fontSize: 13),
                      ),
                      value: _blankEnable,
                      onChanged: (v) => setState(() => _blankEnable = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _recognizing ? null : _recognize,
                      icon: _recognizing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.document_scanner),
                      label: Text(_recognizing ? "识别中…" : "开始识别"),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 阶段四：按色号分组复核 + 手工归类 + 图例数量对账
  Widget _buildReview() {
    final model = _model!;
    final counts = model.countByColor();
    final blankCount =
        model.cellCount - counts.values.fold<int>(0, (a, b) => a + b);
    final order = counts.keys.toList()..sort((a, b) => counts[b]! - counts[a]!);
    return Column(
      children: [
        _buildReviewChips(order, counts, blankCount),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: InteractiveViewer(
                maxScale: 12,
                child: AspectRatio(
                  aspectRatio: model.width / model.height,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final cellW = constraints.maxWidth / model.width;
                      final cellH = constraints.maxHeight / model.height;
                      return GestureDetector(
                        onTapUp: (d) {
                          if (_reviewColor == -2) {
                            return;
                          }
                          final cx = (d.localPosition.dx / cellW).floor();
                          final cy = (d.localPosition.dy / cellH).floor();
                          if (cx < 0 ||
                              cx >= model.width ||
                              cy < 0 ||
                              cy >= model.height) {
                            return;
                          }
                          setState(() {
                            final i = cy * model.width + cx;
                            _picked.contains(i)
                                ? _picked.remove(i)
                                : _picked.add(i);
                          });
                        },
                        child: Stack(
                          children: [
                            CustomPaint(
                              size: Size.infinite,
                              painter: GridPainter(
                                model: model,
                                palette: _palette,
                                selectedColorIndex: -1,
                                highlightIndex:
                                    _reviewColor >= 0 ? _reviewColor : null,
                              ),
                            ),
                            if (_reviewColor == -1)
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _BlankMarksPainter(model: model),
                                ),
                              ),
                            if (_picked.isNotEmpty)
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _ReviewMarksPainter(
                                    model: model,
                                    picked: _picked,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        _buildReviewActions(order, counts, blankCount),
      ],
    );
  }

  /// 复核色号 chips（空白 + 各色 + 图例数量对账）
  Widget _buildReviewChips(
    List<int> order,
    Map<int, int> counts,
    int blankCount,
  ) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _reviewChip(
            lead: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black38),
              ),
              child: const Icon(Icons.close, size: 14),
            ),
            label: "空白 $blankCount",
            selected: _reviewColor == -1,
            onTap: () => _reviewChipTap(-1),
          ),
          for (final idx in order)
            () {
              final c = _palette.colors[idx];
              final expected = _expectedOf(idx);
              final actual = counts[idx] ?? 0;
              final ok = expected == null ? null : actual == expected;
              return _reviewChip(
                lead: Container(
                  width: 20,
                  height: 20,
                  color: Color.fromARGB(255, c.r, c.g, c.b),
                ),
                label: expected == null
                    ? "${c.id} $actual"
                    : "${c.id} $actual/$expected",
                selected: _reviewColor == idx,
                ok: ok,
                onTap: () => _reviewChipTap(idx),
              );
            }(),
        ],
      ),
    );
  }

  /// 点复核 chip：有选中格且点的是不同色 -> 手工归类；否则切换筛选色
  void _reviewChipTap(int target) {
    if (_picked.isNotEmpty && target != _reviewColor) {
      _classifyPickedTo(target);
      return;
    }
    setState(() {
      _reviewColor = target;
      _picked.clear();
    });
  }

  Widget _reviewChip({
    required Widget lead,
    required String label,
    required bool selected,
    bool? ok,
    VoidCallback? onTap,
  }) {
    final border = ok == false
        ? Colors.orange
        : ok == true
            ? Colors.green
            : (selected ? Colors.blue : Colors.black26);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: border, width: selected ? 2 : 1),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              lead,
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  /// 复核操作条：对账状态 + 选中操作 + 进编辑器
  Widget _buildReviewActions(
    List<int> order,
    Map<int, int> counts,
    int blankCount,
  ) {
    var mismatch = 0;
    var accounted = 0;
    for (final e in _legend) {
      final expected = e.expectedCount;
      if (expected != null) {
        accounted++;
        if ((counts[e.paletteIndex] ?? 0) != expected) {
          mismatch++;
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "③ 点色号筛选 → 点格子选中 → 再点目标色号归类；长按拖动可缩放画布",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          if (accounted > 0)
            Text(
              mismatch == 0 ? "✓ 数量一致" : "⚠ $mismatch 项数量有误（实际/图例）",
              style: TextStyle(
                fontSize: 12,
                color: mismatch == 0 ? Colors.green : Colors.orange,
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: _reviewColor == -2 ? null : _selectAllOfCurrent,
                child: const Text("全选当前色"),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _picked.isEmpty
                    ? null
                    : () => setState(() => _picked.clear()),
                child: Text("清除选中(${_picked.length})"),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _openEditor,
                icon: const Icon(Icons.edit),
                label: const Text("进编辑器"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 选区绘制：外部半透明遮罩 + 蓝色边框
/// 一行的游程特征（长游程 = 图例色块；豆子/文字游程短），图例自动检测用
class _RowFeat {
  final int nBlocks;

  ///< 长游程块数
  final int maxLen;

  ///< 最长游程
  final double nonWhite;

  ///< 非白像素占比
  final Set<int> colors;

  ///< 块颜色集合
  final int minX;

  ///< 块起点最小 x
  final int maxX;

  ///< 块终点最大 x
  const _RowFeat(this.nBlocks, this.maxLen, this.nonWhite, this.colors,
      this.minX, this.maxX);
}

class _SelPainter extends CustomPainter {
  final Rect rect;

  _SelPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final mask = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // 框外略暗遮罩：整图挖掉选区（difference 两个独立 path，不能用
    // addPath 叠进同一个 path——nonzero 填充规则下重叠区 winding=2 仍
    // 被填充，遮罩会盖住选区内部，框内外无明暗区分）
    final outer = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final inner = Path()..addRect(rect);
    canvas.drawPath(
      Path.combine(PathOperation.difference, outer, inner),
      mask,
    );
    canvas.drawRect(rect, border);
    // 8 个编辑把手（四角+四边中点）：白底橙圈，可拖动扩大缩小选区
    final handlePts = [
      rect.topLeft,
      Offset(rect.center.dx, rect.top),
      rect.topRight,
      Offset(rect.left, rect.center.dy),
      Offset(rect.right, rect.center.dy),
      rect.bottomLeft,
      Offset(rect.center.dx, rect.bottom),
      rect.bottomRight,
    ];
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final p in handlePts) {
      canvas.drawCircle(p, 6, fill);
      canvas.drawCircle(p, 6, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _SelPainter oldDelegate) =>
      oldDelegate.rect != rect;
}

/// 【临时调试】OCR 元素叠加层：绿框=色号、蓝框=颗数、红线=配对连线
///
/// 画布尺寸与放大图 1:1（外层 SizedBox 定死 imgW×imgH），元素框直接绘制。
/// 正式版随调试功能一起移除。
class _OcrDebugPainter extends CustomPainter {
  final List<_OcrElem> elems;

  _OcrDebugPainter(this.elems);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final codeP = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final numP = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final lineP = Paint()
      ..color = Colors.red
      ..strokeWidth = 2;
    for (final e in elems) {
      if (e.rect.width <= 0 || e.rect.height <= 0) {
        continue; // 几何框退化的元素画不了框
      }
      canvas.drawRect(e.rect, e.code != null ? codeP : numP);
      final other = e.pairedWith;
      if (e.code != null && other != null && other.rect.width > 0) {
        canvas.drawLine(e.rect.center, other.rect.center, lineP);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OcrDebugPainter oldDelegate) => true;
}

/// 网格覆盖层：把识别网格线画在图上，肉眼核对是否压住真实格线
class _GridOverlayPainter extends CustomPainter {
  final int cols;
  final int rows;
  final double originDx;

  ///< 第一根竖线 x（显示坐标）
  final double originDy;

  ///< 第一根横线 y（显示坐标）
  final double pitchDx;

  ///< 横向格距（显示坐标）
  final double pitchDy;

  ///< 纵向格距（显示坐标）

  _GridOverlayPainter({
    required this.cols,
    required this.rows,
    required this.originDx,
    required this.originDy,
    required this.pitchDx,
    required this.pitchDy,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i <= cols; i++) {
      final x = originDx + i * pitchDx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var i = 0; i <= rows; i++) {
      final y = originDy + i * pitchDy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant _GridOverlayPainter oldDelegate) =>
      oldDelegate.cols != cols ||
      oldDelegate.rows != rows ||
      oldDelegate.originDx != originDx ||
      oldDelegate.originDy != originDy ||
      oldDelegate.pitchDx != pitchDx ||
      oldDelegate.pitchDy != pitchDy;
}

/// 四角对齐覆盖层：双线性网格线 + 四角大把手（显示坐标）
///
/// 网格交点全部经 [_bilinearQuad] 反求——与识别采样同源，
/// 蓝线压住哪格，识别就采哪格（所见即所采）。
class _CornerGridPainter extends CustomPainter {
  final List<Offset> pts;

  ///< 四角（显示坐标）：左上/右上/右下/左下
  final int cols;
  final int rows;

  _CornerGridPainter(
      {required this.pts, required this.cols, required this.rows});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final line = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    // 竖线：每条经 rows+1 个交点折线连接（双线性下相邻交点连线即格线）
    for (var i = 0; i <= cols; i++) {
      final u = i / cols;
      final start = _bilinearQuad(pts, u, 0);
      final path = Path()..moveTo(start.dx, start.dy);
      for (var j = 1; j <= rows; j++) {
        final p = _bilinearQuad(pts, u, j / rows);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, line);
    }
    // 横线
    for (var j = 0; j <= rows; j++) {
      final v = j / rows;
      final path = Path();
      final start = _bilinearQuad(pts, 0, v);
      path.moveTo(start.dx, start.dy);
      for (var i = 1; i <= cols; i++) {
        final p = _bilinearQuad(pts, i / cols, v);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, line);
    }
    // 四角大把手：白底橙圈（比选区把手大，透视拖拽目标）
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = const Color(0xFF7B1FA2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final p in pts) {
      canvas.drawCircle(p, 10, fill);
      canvas.drawCircle(p, 10, stroke);
    }
    // 四边形轮廓
    final outline = Paint()
      ..color = const Color(0xFF7B1FA2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final quad = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();
    canvas.drawPath(quad, outline);
  }

  @override
  bool shouldRepaint(covariant _CornerGridPainter oldDelegate) =>
      oldDelegate.pts != pts ||
      oldDelegate.cols != cols ||
      oldDelegate.rows != rows;
}

/// 空白复核：空白格铺淡红色
class _BlankMarksPainter extends CustomPainter {
  final PatternModel model;

  _BlankMarksPainter({required this.model});

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / model.width;
    final paint = Paint()..color = Colors.red.withValues(alpha: 0.18);
    for (var i = 0; i < model.grid.length; i++) {
      if (model.grid[i] >= 0) {
        continue;
      }
      final x = i % model.width, y = i ~/ model.width;
      canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BlankMarksPainter oldDelegate) =>
      oldDelegate.model != model;
}

/// 选中格标记：蓝色覆盖 + 右上角对勾
class _ReviewMarksPainter extends CustomPainter {
  final PatternModel model;
  final Set<int> picked;

  _ReviewMarksPainter({required this.model, required this.picked});

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / model.width;
    final cellH = size.height / model.height;
    final fill = Paint()..color = Colors.blue.withValues(alpha: 0.3);
    final border = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final check = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final i in picked) {
      final x = i % model.width, y = i ~/ model.width;
      final rect = Rect.fromLTWH(x * cellW, y * cellH, cellW, cellH);
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, border);
      final cx = rect.center.dx, cy = rect.center.dy;
      final s = cellW < cellH ? cellW : cellH;
      canvas.drawLine(
        Offset(cx - s * 0.2, cy),
        Offset(cx - s * 0.05, cy + s * 0.18),
        check,
      );
      canvas.drawLine(
        Offset(cx - s * 0.05, cy + s * 0.18),
        Offset(cx + s * 0.25, cy - s * 0.18),
        check,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReviewMarksPainter oldDelegate) =>
      oldDelegate.picked != picked;
}
