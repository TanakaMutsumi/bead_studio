import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_build.dart';
import '../../core/app_snack_bar.dart';
import '../../core/decode_image.dart';
import '../../core/draft_store.dart';
import '../../core/grid_detector.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/pattern_model.dart';
import '../../core/quantizer.dart';
import '../../core/zoom_controls.dart';
import '../board/board_setup_page.dart';
import '../editor/editor_page.dart';
import '../editor/grid_painter.dart';

/// 页面阶段：选图 -> 框图例 -> 九宫格对齐 -> 框选主体 -> 识别复核
enum _Stage { pick, legend, align, frame, review }

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

/// 灰度构建 + 主体格距自相关检测（顶层函数供 compute isolate 调用）
///
/// 主体图用自相关版 detectGridAutocorr：图纸格内豆圆弧产生 8-14px 次峰，
/// 峰间距中位数法（detectGrid）在这类图上会锁到次结构或离散检验失败
/// （2026-09-08 pic5 实测 X 方向 in-band 0.49 返回 null，兜底格距差真值
/// 2.3 倍）；图例路径仍走 detectGrid（色块行结构简单，中位数法已验证
/// 稳定）。百万像素级逐像素扫描同步执行会冻结 UI 秒级，移入 isolate。
GridDetectResult? detectGridInIsolate(img.Image image) {
  final gray = <int>[];
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      gray.add((p.r * 0.299 + p.g * 0.587 + p.b * 0.114).round());
    }
  }
  return detectGridAutocorr(gray, image.width, image.height);
}

/// 格子 OCR 裁剪参数（encodeCellOcrPng 的 compute 入参）
class _CellOcrArgs {
  final img.Image image;

  ///< 原图（isolate 内裁剪）
  final int x, y, w, h;

  ///< 裁剪区（图片坐标）
  final double scale;

  ///< 放大倍率（1.0=不缩放）
  const _CellOcrArgs(this.image, this.x, this.y, this.w, this.h, this.scale);
}

/// 裁剪+缩放+PNG 编码（顶层函数供 compute isolate 调用）：喂 ML Kit 前
/// 的重活，百万像素级同步跑在主 isolate 会冻结 UI 秒级（ANR），与
/// encodeDisplayJpg 同理
Uint8List _encodeCellOcrPng(_CellOcrArgs a) {
  final crop = img.copyCrop(a.image, x: a.x, y: a.y, width: a.w, height: a.h);
  final out = a.scale == 1.0
      ? crop
      : img.copyResize(crop, width: (crop.width * a.scale).round());
  return img.encodePng(out);
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
/// 2. 核对图例识别结果（附属面板，收起可露出原图对照）
/// 3. 九宫格对齐（独立步骤，只做标定）：3×3 标定框拖到图上任意一组格子
///    上，调格子大小（± 精调/拖右下角缩放/微移）使 9 格与图纸格子完全
///    重叠 -> 定出每格尺寸
/// 4. 框选主体（独立步骤，只做框选）-> 开始识别：格线按九宫格相位铺进
///    选区逐小格采样（行列数 = 选区尺寸/格距 自动算，框住主体即天然
///    排除图例区）
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

  ///< 选区把手拖拽中（-1=非把手，0-7=把手索引）
  bool _panViewMode = false;

  ///< 拖动=平移画面模式（框外空白拖动走此路，放大观察用）
  Offset? _selMoveFrom;

  ///< 框内挪框起点（图坐标，null=非挪框）
  Rect? _selMoveBase;

  ///< 框内挪框开始时的选区
  Offset? _drawFrom;

  ///< 画新框的按下起点（onPanDown 只记录不落框，首帧 onPanUpdate 才画——
  ///双指缩放第一指按下时 pan 尚未裁决，立即画零点框会把选区破坏掉）
  ///< 本次 pan 开始前的选区快照：抬手总位移 <_tapRecoverDist 视为点击，
  ///恢复快照——pan 首个 update 必然已位移超 touch slop(18px)，逐帧阈值
  ///拦不住真实点击抖动，只能事后回溯（onPanEnd 判定）
  Rect? _gestureStartSel;

  ///< 点击/拖画的分界总位移（逻辑像素）：真实画框挪框远超此值，
  ///触屏/鼠标点击抖动（含 slop 起步位移）达不到
  static const _tapRecoverDist = 60.0;

  ///< pan 起点（onPanDown 记录，与 _lastPanPos 差值=总位移）
  Offset? _panStartPos;

  ///< pan 过程最新位置（onPanEnd 的 DragEndDetails 无位置，靠 update 持续记）
  Offset? _lastPanPos;

  DateTime? _panStartTime;

  ///< 本次 pan 按下时刻（onPanDown 记）：手势总时长参与轻扫判定——
  ///与末速组合使用（短时长+高末速=轻扫），单独时长短不回溯

  int _ptrCount = 0;

  ///< 当前按下的指针数（Listener 原始计数）：>=2 说明用户意图是双指
  ///捏合缩放/触控板手势，正在进行的单指框选必须作废
  bool _gestureVoided = false;

  ///< true=本次手势已被第二指作废（已恢复快照），pan update/end 不再
  ///生效——覆盖「慢双指」：第一指先超 slop 让 pan 赢了竞技场，第二指
  ///再落下时 scale 已抢不回手势，第一指的 pan 会继续画框，靠此标志拦截

  static const _flingVelocity = 500.0;

  ///< 快速轻扫速度分界（逻辑px/s）：与时长条件组合判定误触（见
  ///_flingMaxElapsed），单独速度不回溯——中慢速拖画速度可能波动超阈值
  static const _flingRecoverDist = 220.0;

  ///< 轻扫回溯的位移上限（逻辑px）：位移小于此值才可能判误触
  static const _flingMaxElapsed = 400;

  ///< 误触手势的时长上限（毫秒）：真实"滑动点击"整个手势 300ms 内
  ///完成（快速划过抬手）；有意拖画要对准框的位置，按住拖 400ms+。
  ///时长+位移（<260ms 兜底速度缺失）或 时长+速度+位移 双条件回溯

  final TransformationController _viewerCtrl = TransformationController();

  ///< 图区变换（滚轮平移 / 自实现双指捏合缩放 / 双击复位）
  final TransformationController _reviewCtrl = TransformationController();
  Size _reviewCanvasSize = Size.zero;

  ///< 复核总览画布内容尺寸速记（builder 内赋值，缩放边界计算用）

  ///< 复核总览变换（还原全幅按钮复位用）
  final GlobalKey _viewerKey = GlobalKey();

  ///< InteractiveViewer 的 RenderBox key：捏合锚点需要 global→viewport
  ///局部坐标换算（PointerEvent.position 是全局坐标，含 AppBar 偏移）
  final Map<int, Offset> _activePtrs = {};

  ///< 活动指针表（pointer id → 全局位置）：双指 span/center 计算源，
  ///也是 _ptrCount 的真值（length）
  double _pinchStartSpan = 0;

  ///< 捏合起始两指间距（<=1 视为无效）
  Offset _pinchStartCenter = Offset.zero;

  ///< 捏合起始两指中心（viewport 局部坐标）
  Matrix4? _pinchStartMatrix;

  ///< 捏合起始矩阵（非增量式推算当前矩阵，避免逐帧累积误差）
  Offset? _prevMoveScreen;

  ///< 倒数第二次 move 全局位置（抬手末速计算）
  DateTime? _prevMoveTime;

  Offset? _lastMoveScreen;

  ///< 最近一次 move 全局位置（与 _prev 配对算末速，替代 DragEndDetails.velocity）
  DateTime? _lastMoveTime;
  Uint8List? _displayBytes;

  ///< 显示用重编码 JPEG（decodeForDisplay 产物，识别/裁剪仍用 _image 原始像素）
  bool _decoding = false;

  ///< 解码/重编码中（图片区遮罩，避免"白屏不知发生什么"）

  // ========== 主体对齐（步骤 3/4） ==========
  final _colsCtrl = TextEditingController();
  final _rowsCtrl = TextEditingController();
  var _detecting = false;
  var _recognizing = false;
  double _pitchX = 0, _pitchY = 0;

  ///< 网格格距（图片坐标，九宫格标定出的每格尺寸）
  Rect? _selDisplay;

  ///< 主体选区（显示坐标，九宫格定格距后框选，行列数=选区/格距自动算）
  Offset? _miniAnchor;

  ///< 九宫格标定框左上角（显示坐标，即第一根格线交点）
  Offset? _miniDragFrom;

  ///< 九宫格拖动起点（图坐标，null=非拖动中）
  Offset? _miniDragBase;

  ///< 九宫格拖动开始时的锚点
  bool _miniScaleDrag = false;

  ///< 九宫格缩放把手拖拽中（拖动=调格距，对角固定）
  Offset? _miniScaleOpp;

  ///< 缩放拖动的固定对角（显示坐标）：拖右下把手=左上角（锚点）固定，
  ///拖左上把手=右下角固定
  bool _miniScaleFixedTL = true;

  ///< true=固定角是左上（锚点不动，拖右下把手）；false=固定角是右下
  double _miniScaleBaseSpan = 0;

  ///< 缩放拖动起始 span（按下时把手到锚点 max(|dx|,|dy|)）
  double _miniScaleBasePx = 0;

  ///< 缩放拖动起始格距 X（f 比例缩放基准，保住非方形 pitchY 不被抹平）
  double _miniScaleBasePy = 0;

  ///< 缩放拖动起始格距 Y
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
  List<Rect> _cellRects = const [];

  ///< 各格矩形（图片坐标，与 grid 扁平索引同序；复核截图取材用）
  ui.Image? _cellSrc;

  ///< 复核截图数据源（_displayBytes 限幅版解码的 ui.Image）
  Set<int> _reviewSeenColors = {};

  ///< 进复核时识别出现过的色快照（「归类到…」候选之一，识别完成时
  ///定格——若按实时 countByColor 重算，跳过图例场景下某色格子全部
  ///归走后该色会从弹窗与 chips 永久消失，归错想归回无入口）

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
    _reviewCtrl.dispose();
    _cellSrc?.dispose();
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
        _miniAnchor = null;
        _selDisplay = null;
        _legend = [];
        _legendByOcr = false;
        _pitchX = 0;
        _model = null;
        _cellRects = const [];
        _reviewSeenColors = {};
        _cellSrc?.dispose();
        _cellSrc = null;
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
        AppSnackBar.show(context, "无法解码图片: $e");
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
      AppSnackBar.show(context, "未识别到图例区，请手动框选");
      return;
    }
    setState(() => _legendSel = rect);
    AppSnackBar.show(context, "已自动框选图例区，可拖动调整");
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

  /// 格子中心 5×5 亮度中值采样（避开网格线，抗印刷色号文字污染）
  ///
  /// 图纸每格中心印着色号/数字（白亮小字）+ 豆圆右上高光，均值采样会被
  /// 少数派亮像素抬高（黑格底色 0-9 被抬到 13-45 的中灰带，2026-09-08
  /// pic5 实测 H7 343 颗崩到 5）。25 点按亮度（r+g+b）排序取中值像素：
  /// 白字与高光被排到亮侧丢弃，中值稳定落回印刷底色（离线同款验证：
  /// 亮度 0-9 纯黑格 348 颗精确对上基线 H7 343）。
  (int, int, int) _sampleCenter(double cx, double cy, double cw, double ch) {
    final image = _image!;
    final pts = <(int, int, int)>[];
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final px = (cx + dx * (cw / 6)).round();
        final py = (cy + dy * (ch / 6)).round();
        if (px < 0 || px >= image.width || py < 0 || py >= image.height) {
          continue;
        }
        final p = image.getPixel(px, py);
        pts.add((p.r.toInt(), p.g.toInt(), p.b.toInt()));
      }
    }
    if (pts.isEmpty) {
      // 全部采样点出界（四角模式角点拖出图界、格中心在图外）返回纯白
      // 而非纯黑：(0,0,0) 会以 Lab 距离 0 归到 H7 纯黑豆，图外整片
      // 格子被计成黑豆对账虚涨；纯白走近白/偏色判定，空白开关开启时
      // 正确落空白（图外格=空白），关闭时归候选最近色（不判空白语义
      // 下的合理回退）
      return (255, 255, 255);
    }
    pts.sort((a, b) => (a.$1 + a.$2 + a.$3) - (b.$1 + b.$2 + b.$3));
    return pts[pts.length ~/ 2];
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
        AppSnackBar.show(
          context,
          "已按图例印刷色号识别 $ocrHit 色，颗数自动读取 $ocrHit 条，请对照原图核对",
        );
      } else if (pairs != null) {
        AppSnackBar.show(
          context,
          "框选区域未读到图例文字，以下按色块识别仅作参考；请只框选图纸底部的色块+色号+数字区域",
        );
      } else if (det == null) {
        AppSnackBar.show(context, "未检出图例网格，按 8×1 均分识别；不准可改行列数后重新识别");
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

      // 精确 + 混淆变体查找表（图例 OCR 与格子 OCR 共用）
      final codeMap = _buildCodeMap();

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
        AppSnackBar.show(
          context,
          "识别到色卡外色号：$names（不在当前色卡，未入清单；如有需要请用\"添加颜色\"手工补）",
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

  /// 全色卡「精确 + 混淆变体」查找表：variant -> 调色板索引（图例 OCR
  /// 与格子 OCR 共用；变体撞车先到先得）
  Map<String, int> _buildCodeMap() {
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
        codeMap[v] ??= i;
      }
    }
    return codeMap;
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

  /// 弹色卡选色器（修正图例色号 / 添加颜色 / 复核归类共用）
  ///
  /// [allowed] 非空时只显示集合内的色号（复核归类限定图例色 + 识别结果
  /// 中出现过的色——识别候选本就来自图例，归到图例外的色会让图例对账
  /// 口径混入外色）；[withBlank] 为 true 时首格是「空白」（归类到空白
  /// 用，点中返回 -1；返回 null 一律表示取消）。
  Future<int?> _pickColorIndex({
    Set<int>? allowed,
    bool withBlank = false,
    String title = "选择色号",
  }) {
    final indices = <int>[
      if (withBlank) -1,
      for (var i = 0; i < _palette.colors.length; i++)
        if (allowed == null || allowed.contains(i)) i,
    ];
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: GridView.count(
            crossAxisCount: 6,
            children: [
              for (final i in indices)
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
                              _palette.colors[i].r,
                              _palette.colors[i].g,
                              _palette.colors[i].b,
                            ),
                          ),
                        Text(
                          i < 0 ? "空白" : _palette.colors[i].id,
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
      AppSnackBar.show(context, "${_palette.colors[idx].id} 已在清单中");
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

  // ==================== 步骤 3/4：九宫格标定 ====================

  /// 初始化九宫格标定：全图投影自动检测取格距，锚点取「不越过图中心
  /// 的最近格线交点」（图纸主体多居中，标定框放正中一眼可核，不必从图
  /// 边缘拖回；floor 恒不越过中心 → 3×3 框必覆盖图中心；相位沿用检测
  /// 值整数格对齐，虚线延伸格仍与图纸格线同相）；
  /// 检测不到用全图宽/20 兜底、锚点放图中央。进入对齐阶段时调一次，
  /// 回对齐微调不重跑。
  /// 灰度构建 + 自相关检测走 compute isolate：全图逐像素同步扫描
  /// （12MP 手机照片百万次 getPixel）在 UI 线程会冻结秒级（与
  /// encodeDisplayJpg 同理），期间动画/触摸全无响应。
  Future<void> _initMiniGrid() async {
    final image = _image;
    if (image == null || _detecting) {
      return; // 检测进行中防重入（来回切阶段触发两次会竞态覆盖锚点）
    }
    setState(() => _detecting = true);
    // postFrameCallback 让 _detecting 提示先渲染一帧再起 isolate
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }
    final det = await compute(detectGridInIsolate, image);
    // 【临时调试】初始化检测全参数打 logcat（格距初值排查），正式版移除
    debugPrint(
      "【临时调试】initMiniGrid img=${image.width}x${image.height} "
      "det=${det == null ? "null" : "px=${det.pitchX.toStringAsFixed(2)} py=${det.pitchY.toStringAsFixed(2)} ox=${det.offsetX.toStringAsFixed(1)} oy=${det.offsetY.toStringAsFixed(1)} ${det.cols}x${det.rows}"}",
    );
    if (!mounted) {
      return;
    }
    final ds = _displaySize();
    setState(() {
      _detecting = false;
      if (det != null) {
        _pitchX = det.pitchX;
        _pitchY = det.pitchY;
        // 锚点取不越过图中心的最近格线交点（floor 恒不越过中心 → 3×3
        // 框必覆盖图中心；相位沿用检测值 offsetX/Y + 整数格，虚线延伸格
        // 与图纸格线保持同相）。界内约束对整数格数 k 做（粗格距下 3×3
        // 框从中心交点放不下时按格回退），而非对最终显示坐标截断——截
        // 断会把锚点推离格线交点、虚线整体离相；k=0（首条格线）必在界
        // 内（检测通过时 offset ≤ 宽-3.5×格距），区间非空
        final kxMax =
            ((image.width - 3 * det.pitchX - det.offsetX) / det.pitchX).floor();
        final kyMax =
            ((image.height - 3 * det.pitchY - det.offsetY) / det.pitchY)
                .floor();
        final kx = ((image.width / 2 - det.offsetX) / det.pitchX)
            .floor()
            .clamp(0, math.max(0, kxMax));
        final ky = ((image.height / 2 - det.offsetY) / det.pitchY)
            .floor()
            .clamp(0, math.max(0, kyMax));
        _miniAnchor = Offset(
          (det.offsetX + kx * det.pitchX) * ds.width / image.width,
          (det.offsetY + ky * det.pitchY) * ds.height / image.height,
        );
      } else {
        _pitchX = image.width / 20;
        _pitchY = image.height / 20;
        _miniAnchor = Offset(
          ds.width / 2 - 1.5 * _pitchX * ds.width / image.width,
          ds.height / 2 - 1.5 * _pitchY * ds.height / image.height,
        );
      }
    });
    if (det == null) {
      AppSnackBar.show(context, "未自动检出格距，已按默认值放置九宫格，请手动调整大小对齐");
    }
  }

  /// 命中九宫格标定框：2=左上缩放把手、1=右下缩放把手、0=框体（拖动
  /// 移动）、-1=未命中
  ///
  /// 把手先判（半径 26/scale：随视图缩放补偿，放大后命中区视觉恒定，
  /// 不会变成巨屏误触区）；否则框体外扩半格作移动命中区（手指按在格
  /// 线上也算框内）
  int _hitMiniGrid(Offset anchor, Offset p) {
    final scale = _viewerCtrl.value.storage[0];
    final ds = _displaySize();
    final image = _image!;
    final w = 3 * _pitchX * ds.width / image.width;
    final h = 3 * _pitchY * ds.height / image.height;
    final radius = 26 / scale;
    if ((anchor - p).distance <= radius) {
      return 2;
    }
    if (((anchor + Offset(w, h)) - p).distance <= radius) {
      return 1;
    }
    final area = Rect.fromLTWH(
      anchor.dx - w / 6,
      anchor.dy - h / 6,
      w + w / 3,
      h + h / 3,
    );
    return area.contains(p) ? 0 : -1;
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

  /// 微移九宫格（步进 = 格距 / 8，显示坐标换算）
  void _nudge(double dx, double dy) {
    final anchor = _miniAnchor;
    if (_pitchX <= 0 || _pitchY <= 0 || anchor == null) {
      return;
    }
    final ds = _displaySize();
    final image = _image!;
    final stepX = _pitchX * ds.width / image.width / 8;
    final stepY = _pitchY * ds.height / image.height / 8;
    setState(() {
      _miniAnchor = Offset(anchor.dx + dx * stepX, anchor.dy + dy * stepY);
    });
  }

  /// 紧凑图标按钮（对齐面板格子大小/微移行专用）：默认 IconButton 48
  /// 逻辑宽，一行 6 个加标签在窄屏溢出，压到 36 宽/22 图标
  Widget _compactIconBtn({
    required IconData icon,
    VoidCallback? onPressed,
    String? tooltip,
  }) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      iconSize: 22,
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon),
    );
  }

  /// 画布缩放控制组：放大/缩小（以画面中心为锚）+ 还原全幅（所有可缩放
  /// 画布统一入口——手势缩放可发现性差，屏幕上要有显式按钮）。
  /// [viewportIsContent]：Center 内 constrained InteractiveViewer 的真实
  /// 视口=画布盒（与内容同尺寸），须显式传视口——探外层 Stack 会把锚点
  /// 偏移、letterbox 轴平移夹限算错（图区 constrained:false 铺满 Stack
  /// 的接入保持默认探取）
  Widget _zoomCtrls(
    TransformationController ctrl,
    Size Function() contentSize, {
    double maxScale = 8,
    bool viewportIsContent = false,
  }) {
    return ZoomControls(
      controller: ctrl,
      contentSize: contentSize,
      viewportSize: viewportIsContent ? contentSize : null,
      maxScale: maxScale,
    );
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

  /// 默认四角：全图四角
  List<Offset> _defaultCorners() {
    final ds = _displaySize();
    return [
      Offset.zero,
      Offset(ds.width, 0),
      Offset(ds.width, ds.height),
      Offset(0, ds.height),
    ];
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
  ///
  /// 九宫格标定模式：主体选区 + 标定格距切分，格线相位锚定九宫格（锚点
  /// 对格距取模铺进选区——九宫格不必框在选区内，它与图纸格子重叠即全图
  /// 同相），行列数 = 选区尺寸/格距 自动算；四角模式：行列数手填，采样
  /// 中心经四角双线性映射反求。
  void _recognize() {
    final image = _image;
    if (image == null) {
      return;
    }
    final useCorner =
        _useCornerAlign && _cornerPts != null && _cornerPts!.length == 4;
    var cols = 0, rows = 0;
    var rx = 0.0, ry = 0.0, offX = 0.0, offY = 0.0;
    var pitchX = 0.0, pitchY = 0.0;
    if (useCorner) {
      cols = int.tryParse(_colsCtrl.text) ?? 0;
      rows = int.tryParse(_rowsCtrl.text) ?? 0;
      if (cols < 4 || rows < 4 || cols > 400 || rows > 400) {
        AppSnackBar.show(context, "行列数须在 4-400 之间");
        return;
      }
    } else {
      // 格距快照：await OCR 期间「回九宫格」按钮仍可点（调格距），活读
      // 字段会让几何切分与元素归类用上不同格距而串格——全程用快照
      pitchX = _pitchX;
      pitchY = _pitchY;
      final anchor = _miniAnchor;
      final sel = _selDisplay;
      if (_pitchX <= 0 || _pitchY <= 0 || anchor == null) {
        AppSnackBar.show(context, "九宫格未就绪，请等自动检测完成或手动调整");
        return;
      }
      if (sel == null || sel.width <= 8 || sel.height <= 8) {
        AppSnackBar.show(context, "请先在图上拖框选中主体区域（拼豆格子部分，扁框无效）");
        return;
      }
      final (sx, sy, sw, sh) = _selToImage(sel);
      rx = sx;
      ry = sy;
      final ds = _displaySize();
      final ax = anchor.dx * image.width / ds.width;
      final ay = anchor.dy * image.height / ds.height;
      offX = (ax - rx) % pitchX;
      if (offX < 0) {
        offX += pitchX;
      }
      offY = (ay - ry) % pitchY;
      if (offY < 0) {
        offY += pitchY;
      }
      // 相位残差钳制：框选步选区四边已吸附格线，(锚点-选区左缘) 数学上
      // 是格距整数倍，但吸附在显示坐标、相位在图片坐标，两次换算的浮点
      // 求值顺序不同，残差 ±1e-12 落负侧时 % 回绕成 pitchX-ε，切分数比
      // 框上徽标少 1 且首列整列右移一格。真实相位偏移不可能在百万分之
      // 一像素量级，钳回 0 无误伤（_plannedColsRows 同款）
      if (offX < 1e-6 || pitchX - offX < 1e-6) {
        offX = 0;
      }
      if (offY < 1e-6 || pitchY - offY < 1e-6) {
        offY = 0;
      }
      cols = ((sw - offX) / pitchX + 0.5).floor();
      rows = ((sh - offY) / pitchY + 0.5).floor();
      if (cols < 4 || rows < 4 || cols > 400 || rows > 400) {
        AppSnackBar.show(context, "按当前格距切分为 $cols×$rows，超出 4-400，请调整框选范围或格子大小");
        return;
      }
      _colsCtrl.text = cols.toString();
      _rowsCtrl.text = rows.toString();
    }
    setState(() => _recognizing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
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
      // 候选集是否含近白色（白/米白/银白系，MARD 卡 14 色如 H1/T1 纯白）：
      // 含则跳过近白直判空白——白是拼豆常见大用量色，直判会把该色全部
      // 格子误灭为空白（该色计数恒 0 与图例对账必失败，2026-09-08 review
      // 确认为回归：旧代码白豆格走 nearestWithin 正确归 H1 distSq≈0）。
      // 候选无近白色时近白格必是图案区外白底，直判空白不受影响
      final candNearWhite = candidates.any((i) {
        final c = _palette.colors[i];
        return c.r > 230 &&
            c.g > 230 &&
            c.b > 230 &&
            (math.max(c.r, math.max(c.g, c.b)) -
                    math.min(c.r, math.min(c.g, c.b))) <
                25;
      });
      // 几何循环：先算全部格子中心/矩形（图片坐标）——OCR 元素归类与
      // 色彩采样共用同一套几何，九宫格/四角两模式在此归一
      final centers = <Offset>[];
      final cellRects = <Rect>[];
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          if (useCorner) {
            // 四角双线性：矩形取对角交点包围盒（近似），中心取映射中点
            final tl = _bilinearQuad(qImg, c / cols, r / rows);
            final br = _bilinearQuad(qImg, (c + 1) / cols, (r + 1) / rows);
            centers.add(
              _bilinearQuad(qImg, (c + 0.5) / cols, (r + 0.5) / rows),
            );
            cellRects.add(Rect.fromPoints(tl, br));
          } else {
            final left = rx + offX + c * pitchX;
            final top = ry + offY + r * pitchY;
            centers.add(Offset(left + pitchX / 2, top + pitchY / 2));
            cellRects.add(Rect.fromLTWH(left, top, pitchX, pitchY));
          }
        }
      }
      // OCR 轮：选区整图单次识别（逐格 ~1600 次 processImage 要数分钟），
      // 元素按几何归类回格；印刷色号是图纸的权威声明，命中候选色号的格
      // 直接采用，读不到的回落色彩识别
      final ocrByCell = await _ocrCells(
        cellRects,
        centers,
        Offset(rx + offX, ry + offY),
        cols,
        rows,
        useCorner,
        pitchX,
        pitchY,
      );
      final codeMap = _buildCodeMap();
      final quantizer = Quantizer(_palette);
      final grid = List<int>.filled(cols * rows, 0);
      var ocrHit = 0;
      for (var i = 0; i < grid.length; i++) {
        final txt = ocrByCell[i];
        if (txt != null) {
          final hit = codeMap[txt];
          if (hit != null && (candidates.isEmpty || candidates.contains(hit))) {
            grid[i] = hit;
            ocrHit++;
            continue;
          }
        }
        final (sr, sg, sb) = _sampleCenter(
          centers[i].dx,
          centers[i].dy,
          cellRects[i].width,
          cellRects[i].height,
        );
        // 近白直判空白：图案区外的白底/浅灰底到浅粉 E11 的 Lab 距离
        // ~380，低于空白阈值 900，大片白底会被误归浅粉（pic5 实测
        // E11 171→478 超涨 3 倍）；纯白/近白（min>230 且极差<25）直接
        // 判空白，真浅粉豆 g/b≤218 不会命中不受影响（同款离线验证
        // E11 478→171 与基线零差）。候选集含近白色（图纸用白豆）时
        // 跳过——见上方 candNearWhite 注释
        final nearWhite = sr > 230 &&
            sg > 230 &&
            sb > 230 &&
            (math.max(sr, math.max(sg, sb)) - math.min(sr, math.min(sg, sb))) <
                25;
        if (_blankEnable && nearWhite && !candNearWhite) {
          grid[i] = -1;
        } else {
          final (idx, distSq) = quantizer.nearestWithin(
            sr,
            sg,
            sb,
            candidates.isEmpty ? null : candidates,
          );
          grid[i] = (_blankEnable && distSq > _blankDistSq) ? -1 : idx;
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
        _cellRects = cellRects;
        _recognizing = false;
        _reviewColor = -2;
        _picked.clear();
        // 出现色快照定格：归类候选不随后续归类动态缩水（见字段注释）
        _reviewSeenColors = {
          for (var i = 0; i < grid.length; i++)
            if (grid[i] >= 0) grid[i],
        };
        _stage = _Stage.review;
      });
      // 复核截图数据源异步解码，不阻塞进复核页（_displayBytes 是长边
      // 限幅显示版，原图直解码会超 GLES 2048 纹理上限）
      _loadCellSrc();
      // 【临时调试】识别计数打 logcat（基线比对用），正式版移除
      final dbgCnt = <int, int>{};
      for (final g in grid) {
        dbgCnt[g] = (dbgCnt[g] ?? 0) + 1;
      }
      final dbgPairs = [
        for (final k in dbgCnt.keys.toList()..sort())
          "${k < 0 ? "BLANK" : _palette.colors[k].id}=${dbgCnt[k]}",
      ].join(" ");
      debugPrint(
        "【临时调试】识别 $cols x $rows | OCR命中 $ocrHit/${cols * rows} | $dbgPairs",
      );
    });
  }

  /// 选区整图单次 OCR：裁全部格子包围盒外扩半格，放大喂 ML Kit，元素
  /// 中心换算回图片坐标归类到格（九宫格模式按格线相位解析 col/row +
  /// 中心距校验；四角模式取最近格中心），同格多元素按 x 排序拼接成
  /// 整串色号。返回 格扁平索引 -> 拼接文本；web/异常/无识别返回空 map
  /// （调用方回落色彩识别）。
  Future<Map<int, String>> _ocrCells(
    List<Rect> cellRects,
    List<Offset> centers,
    Offset gridOrigin,
    int cols,
    int rows,
    bool useCorner,
    double pitchX,
    double pitchY,
  ) async {
    if (kIsWeb) {
      return const {};
    }
    final image = _image;
    if (image == null || cellRects.isEmpty) {
      return const {};
    }
    try {
      // 裁剪范围：全部格子包围盒外扩半格（边缘格文字完整）
      var bLeft = image.width.toDouble();
      var bTop = image.height.toDouble();
      var bRight = 0.0, bBottom = 0.0;
      var sumW = 0.0, sumH = 0.0;
      for (final cr in cellRects) {
        if (cr.left < bLeft) {
          bLeft = cr.left;
        }
        if (cr.top < bTop) {
          bTop = cr.top;
        }
        if (cr.right > bRight) {
          bRight = cr.right;
        }
        if (cr.bottom > bBottom) {
          bBottom = cr.bottom;
        }
        sumW += cr.width;
        sumH += cr.height;
      }
      final avgW = sumW / cellRects.length;
      final avgH = sumH / cellRects.length;
      final cx0 = (bLeft - avgW / 2).clamp(0.0, image.width - 4.0);
      final cy0 = (bTop - avgH / 2).clamp(0.0, image.height - 4.0);
      final cx1 = (bRight + avgW / 2).clamp(cx0 + 4.0, image.width.toDouble());
      final cy1 =
          (bBottom + avgH / 2).clamp(cy0 + 4.0, image.height.toDouble());
      final cropW = (cx1 - cx0).toInt();
      final cropH = (cy1 - cy0).toInt();
      // 放大策略：目标宽 3600（格内色号字小，格距 ~31px 时字高 ~10px，
      // 不放大 ML Kit 读不出），上限 6 防小选区过度放大锯齿化丢字；大选区
      // （相机原片 crop ≥3600px 宽）不再强制放大——旧版 clamp 下限 2.0 会
      // 把 4000px crop 拉到 8000px 宽（48MP），并按 ML Kit 输入上限把输出
      // 宽 cap 在 3800 内（同图例路径 widthCap），防超限后 processImage
      // 异常被下方 catch 吞掉整轮 OCR 静默失效
      var scale = (3600 / cropW).clamp(1.0, 6.0);
      final widthCap = 3800 / cropW;
      if (scale > widthCap) {
        scale = widthCap;
      }
      // 裁剪/缩放/PNG 编码走 compute isolate：百万像素级同步重活（大图
      // 12MP+）在主 isolate 会冻结 UI 秒级（ANR），与 encodeDisplayJpg
      // 同理
      final pngBytes = await compute(
        _encodeCellOcrPng,
        _CellOcrArgs(image, cx0.toInt(), cy0.toInt(), cropW, cropH, scale),
      );
      final tmp = File(
        "${(await getTemporaryDirectory()).path}/cells_ocr.png",
      );
      await tmp.writeAsBytes(pngBytes);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(tmp.path),
      );
      await recognizer.close();
      // 元素中心（放大图坐标）-> 图片坐标 -> 归类到格
      final rawByCell = <int, List<(double, String)>>{};
      final centerLimit = 0.65 * math.max(avgW, avgH);
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          for (final element in line.elements) {
            final text = element.text.trim().toUpperCase().replaceAll(" ", "");
            if (text.isEmpty ||
                text.length > 4 ||
                !RegExp(r'^[A-Z0-9]+$').hasMatch(text)) {
              continue; // 只收色号样式（≤4 字母数字），长文本/杂项不做
            }
            final bc = element.boundingBox.center;
            final p = Offset(cx0 + bc.dx / scale, cy0 + bc.dy / scale);
            int? cellIdx;
            if (!useCorner) {
              // 九宫格模式：按格线相位直接解析 col/row，中心距校验防
              // 串格（文字压在格线上时 floor 会落到邻格）
              final col = ((p.dx - gridOrigin.dx) / pitchX).floor();
              final row = ((p.dy - gridOrigin.dy) / pitchY).floor();
              if (col >= 0 && col < cols && row >= 0 && row < rows) {
                final idx = row * cols + col;
                if ((p - centers[idx]).distance < centerLimit) {
                  cellIdx = idx;
                }
              }
            }
            if (cellIdx == null) {
              // 兜底（四角模式主路径）：最近格中心，超限丢弃。格子联合
              // 包围盒（不含外扩半格）之外的元素是选区外内容（行列编号/
              // 图例杂文）——裁剪外扩半格会把它读进 OCR，若被收进边缘格
              // 会与格内色号按 x 拼接成 "F2"+"1"→"F21" 型错串（撞上混淆
              // 变体即按 OCR 权威错认上色），直接丢弃
              if (p.dx < bLeft ||
                  p.dx > bRight ||
                  p.dy < bTop ||
                  p.dy > bBottom) {
                continue;
              }
              var best = -1;
              var bestD = double.infinity;
              for (var i = 0; i < centers.length; i++) {
                final d = (p - centers[i]).distance;
                if (d < bestD) {
                  bestD = d;
                  best = i;
                }
              }
              if (best >= 0 && bestD < centerLimit) {
                cellIdx = best;
              }
            }
            if (cellIdx != null) {
              rawByCell.putIfAbsent(cellIdx, () => []).add((p.dx, text));
            }
          }
        }
      }
      // 同格多元素（"F" "2" 分开识别等）按 x 排序拼接
      final out = <int, String>{};
      rawByCell.forEach((idx, list) {
        list.sort((a, b) => a.$1.compareTo(b.$1));
        out[idx] = [for (final t in list) t.$2].join();
      });
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// 复核截图数据源：解码 _displayBytes（长边限幅显示版）为 ui.Image，
  /// 供格子截图 drawImageRect 取材
  Future<void> _loadCellSrc() async {
    final bytes = _displayBytes;
    if (bytes == null) {
      return;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    try {
      final im = await completer.future;
      if (!mounted) {
        im.dispose();
        return;
      }
      setState(() {
        _cellSrc?.dispose();
        _cellSrc = im;
      });
    } catch (_) {
      // 解码失败保持 null，截图区显示占位
    }
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

  /// 保存作品：命名 -> 存作品库 -> 可选直接进入拼豆板设置
  Future<void> _saveWork() async {
    final model = _model;
    if (model == null) {
      return;
    }
    final now = DateTime.now();
    final two = (int v) => v.toString().padLeft(2, "0");
    final ctrl = TextEditingController(
      text:
          "图案 ${now.month}${two(now.day)}日 ${two(now.hour)}:${two(now.minute)}",
    );
    final name = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text("保存作品"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            labelText: "作品名",
            counterText: "",
          ),
          onSubmitted: (v) => Navigator.pop(dctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, ctrl.text),
            child: const Text("保存"),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) {
      return;
    }
    final file = await DraftStore.saveWork(model, name: name.trim());
    if (!mounted) {
      return;
    }
    final next = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text("保存成功"),
        content: Text("「${name.trim()}」已存入作品库"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, "home"),
            child: const Text("回到主页"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, "assemble"),
            child: const Text("直接开始拼豆"),
          ),
        ],
      ),
    );
    if (next == null || !mounted) {
      return; // 点对话框外留在本页（可继续调整后重存/进编辑器）
    }
    if (next == "home") {
      Navigator.of(context).pop();
      return;
    }
    final entry = await DraftStore.readEntry(file);
    if (!mounted) {
      return;
    }
    // pushReplacement：还原页出栈，板设置 back 直达主页；还原现场不再
    // 保留，需要再进从「我的作品」打开该作品
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => BoardSetupPage(initial: entry)),
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
    final n = _picked.length;
    setState(() {
      for (final i in _picked) {
        model.grid[i] = target;
      }
      _picked.clear();
    });
    // 【临时调试】归类执行打 logcat（复核纠错链路验证用），正式版移除
    final cnt = <int, int>{};
    for (final g in model.grid) {
      cnt[g] = (cnt[g] ?? 0) + 1;
    }
    debugPrint(
      "【临时调试】手工归类 $n 格 -> ${target < 0 ? "空白" : _palette.colors[target].id} | ${[
        for (final k in cnt.keys.toList()..sort())
          "${k < 0 ? "BLANK" : _palette.colors[k].id}=${cnt[k]}",
      ].join(" ")}",
    );
  }

  /// 「归类到…」是否还有有效目标：图例色或出现色快照非空（可归色），
  /// 或当前筛选色不是空白（可归空白）。两者皆无 = 图例空 + 识别全空白
  /// 的病态态：唯一可选项「空白」与选中格同色，归类是静默无效操作，
  /// 禁用按钮防无效点击
  bool _hasClassifyTarget() {
    if (_legend.isNotEmpty || _reviewSeenColors.isNotEmpty) {
      return true;
    }
    return _reviewColor != -1;
  }

  /// 「归类到…」按钮：弹受限选色器后归类选中格。候选 = 图例清单色号 ∪
  /// 识别出现色快照（「跳过图例」直接识别时图例为空，靠快照兜底；快照
  /// 在识别完成时定格，不随归类缩水）+ 首格「空白」——复核归类是把错认
  /// 格子拨回正确用色，开放全色卡会归出图例外的色，图例对账口径混入
  /// 外色（用户反馈：只应能归到图例色号和空白）
  Future<void> _reassignPicked() async {
    if (_picked.isEmpty) {
      return;
    }
    final allowed = <int>{
      for (final e in _legend) e.paletteIndex,
      ..._reviewSeenColors,
    };
    final target = await _pickColorIndex(
      allowed: allowed,
      withBlank: true,
      title: "归类到",
    );
    if (target == null || !mounted) {
      return;
    }
    await _classifyPickedTo(target);
  }

  /// 进入「九宫格对齐」阶段：首次进入自动初始化标定框（回对齐微调不重跑）
  void _goAlign() {
    if (_recognizing) {
      // 识别进行中回对齐：识别完成会写结果并跳复核，中途调格距白调
      AppSnackBar.show(context, "识别进行中，请等待完成");
      return;
    }
    setState(() => _stage = _Stage.align);
    if (_miniAnchor == null) {
      _initMiniGrid();
    }
  }

  /// 进入「框选主体」阶段（九宫格已定每格尺寸，本步只框主体区域；
  /// 行列数 = 选区/格距 实时算，识别时直接采用）。已有选区按当前格距
  /// 重新吸附（回九宫格调过格子大小再进来，旧框立即归位整格）
  void _goFrame() {
    setState(() {
      _stage = _Stage.frame;
      final sel = _selDisplay;
      if (sel != null) {
        _selDisplay = _snapSelToGrid(sel);
      }
    });
  }

  /// back 退出确认：中间步骤的 back 不直接退页（那样整个还原流程——
  /// 选的图/图例框/九宫格标定——全丢），先问是否只返回上一步；
  /// 已调内容全部保留，第一步（选图）back 才直接退出
  Future<void> _confirmBack() async {
    if (_recognizing) {
      // 与 _goAlign 同款守卫：识别完成回调会无条件写结果并跳复核（见
      // _recognize 末尾 setState），识别中返回上一步是白调且用户会被
      // 强行拽回复核
      AppSnackBar.show(context, "识别进行中，请等待完成");
      return;
    }
    // 四角对齐流程无独立框选步（②四角直接识别，见 _buildAlign），从复核
    // 返回应回②对齐，而不是落入本流程不存在的③框选主体
    final prev = _stage == _Stage.review && _useCornerAlign
        ? _Stage.align
        : _Stage.values[_stage.index - 1];
    final prevName = switch (prev) {
      _Stage.pick => "选图",
      _Stage.legend => "① 框图例",
      _Stage.align => "② 九宫格对齐",
      _Stage.frame => "③ 框选主体",
      _Stage.review => "④ 识别复核",
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text("返回上一步？"),
        content: Text("回到「$prevName」。已选的图、图例框、九宫格标定都保留，不会丢失"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text("返回上一步"),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() => _stage = prev);
  }

  /// 「退出」按钮确认：完全退出图纸还原（选的图/图例框/九宫格标定/识别
  /// 结果全部丢弃；已单独保存进作品库的作品不受影响）。与「上一步」
  /// 相对：上一步保留现场只回退阶段。识别完成回调处处有 mounted 守卫，
  /// 识别中退出页面安全（后台 compute 跑完即弃），不拦
  Future<void> _confirmExitRestore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text("退出图纸还原？"),
        content: const Text("已识别、已调整的内容将全部丢弃（已保存进作品库的作品不受影响）"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text("退出"),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  // ==================== 布局 ====================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 选图步（第一步）back 直接退出；中间步骤先确认返回上一步
      canPop: _stage == _Stage.pick,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _confirmBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(switch (_stage) {
                _Stage.pick => "图纸还原 · 选图",
                _Stage.legend => "图纸还原 · ① 框图例",
                _Stage.align => "图纸还原 · ② 九宫格对齐",
                _Stage.frame => "图纸还原 · ③ 框选主体",
                _Stage.review => "图纸还原 · ④ 识别复核",
              }),
              Text(
                "构建 $appBuildLabel",
                style: const TextStyle(fontSize: 10, color: Colors.black38),
              ),
            ],
          ),
          actions: [
            // 回退入口只留两处：系统 back（同款确认弹窗）+ 各步具名快捷
            // 钮（框选步「回九宫格」/复核步「回对齐」，直达不弹确认）——
            // 再放通用「上一步」会与之重复（框选步两个按钮同为回对齐）
            // 显式「退出」按钮：完全退出图纸还原。第一步无可丢内容直接退；
            // 中间步弹确认——与回退相对：回退保留现场只回退阶段，
            // 退出丢弃已调的图例/标定/识别结果（已保存进作品库的不受影响）
            IconButton(
              onPressed: _stage == _Stage.pick
                  ? () => Navigator.of(context).pop()
                  : _confirmExitRestore,
              icon: const Icon(Icons.logout),
              tooltip: "退出图纸还原",
            ),
            // 复核发现问题多半是网格没对齐：一键回对齐阶段微调后重识别
            // （网格参数/选区/图例都保留，直接可调）
            if (_stage == _Stage.review)
              TextButton.icon(
                onPressed: _goAlign,
                icon: const Icon(Icons.undo, size: 18),
                label: const Text("回对齐"),
              ),
            // 框选步发现格距不对：回九宫格步重新标定（选区保留，回来直接用）
            if (_stage == _Stage.frame)
              TextButton.icon(
                onPressed: _goAlign,
                icon: const Icon(Icons.undo, size: 18),
                label: const Text("回九宫格"),
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
            if (_stage == _Stage.legend ||
                _stage == _Stage.align ||
                _stage == _Stage.frame)
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
          _Stage.frame => _buildFrame(),
          _Stage.review => _buildReview(),
        },
      ),
    );
  }

  /// 切换色卡（图例清单作废，需重新识别）
  Future<void> _switchPalette(String id) async {
    if (id == _paletteId) {
      return;
    }
    if (_recognizing) {
      // 识别进行中换色卡：await 前后建的候选集（旧卡）与色号查找表（新
      // 卡）混判错认，拒绝——识别结束（进复核或回失败）后再切
      if (mounted) {
        AppSnackBar.show(context, "识别进行中，请等识别完成后再切换色卡");
      }
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
    AppSnackBar.show(context, "已切换到${target.label}，图例需重新识别");
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
              "框图例 → 核对用色 → 九宫格对齐 → 框选主体 → 识别 → 手工纠错",
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

  /// 图片 + 统一框选手势 + 可选网格覆盖（图例/对齐/框选阶段共用）
  ///
  /// 单指：空白处拖动 = 画新选区；选区内部拖动 = 整框平移（框完想挪位置
  /// 不必重画）；四角/四边把手 = 微调大小。双指：捏合缩放 + 拖动平移原图
  /// （InteractiveViewer 承担，查看大图不需要独立的查看模式）。
  /// [cornerPts] 非空时四角把手接管手势（拖角微调，非角区拖动不画框防误触清角）。
  /// [miniAnchor] 非空时九宫格标定框参与手势（命中拖动/角缩放）。标定与
  /// 框选分两步不同屏：[panFallback] 为 true（九宫格对齐步）时未命中九宫格
  /// 的拖动 = 平移画面查看；false（框选主体步）时回落画选区。
  Widget _imageStage({
    required Rect? sel,
    required void Function(Rect) onSel,
    CustomPainter? overlay,
    List<Offset>? cornerPts,
    void Function(int, Offset)? onCornerDrag,
    Offset? miniAnchor,
    void Function(Offset)? onMiniAnchor,
    bool panFallback = false,
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
            // 单指拖动逻辑与双指捏合缩放全部由 child 内 Listener 原始事件
            // 自实现（不用 InteractiveViewer 的 scale 手势）：child 一旦声明
            // pan/scale 手势就会在竞技场抢走第一指，双指捏合时 scale 手势
            // 只剩一根手指无法算 span——Ctrl+左键/双指捏合缩放彻底失效
            //（2026-08-28 实测）。Listener 不进竞技场，原始事件全量可得。
            scaleEnabled: false,
            panEnabled: false,
            constrained: false,
            key: _viewerKey,
            child: Builder(
              builder: (_) {
                final ctx = _StageCtx(onSel, sel, cornerPts, onCornerDrag, cons,
                    miniAnchor, onMiniAnchor, panFallback);
                return Listener(
                  // 滚轮=纵向平移浏览（图例清单展开会挡住图片下部，靠滚轮看回）
                  onPointerSignal: (s) => _onImgPointerSignal(s, cons),
                  onPointerDown: (e) => _onStagePointerDown(e, ctx),
                  onPointerMove: (e) => _onStagePointerMove(e, ctx),
                  onPointerUp: (e) => _onStagePointerUp(e, ctx),
                  onPointerCancel: (e) => _onStagePointerCancel(e, ctx),
                  // 桌面触控板捏合/双指滚动走独立的 PointerPanZoom 事件流：
                  // 缩放暂不支持，只作废进行中的单指手势防误框
                  onPointerPanZoomStart: (_) => _onStagePanZoomStart(onSel),
                  child: GestureDetector(
                    // 双击复位视角：滚轮平移把图（连同选区框）滚出视口后，
                    // 框没被删只是看不见——双击立即回到全图视角找回
                    onDoubleTap: () {
                      _viewerCtrl.value = Matrix4.identity();
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
                );
              },
            ),
          ),
        ),
        // 缩放控制组（放大/缩小/还原全幅）：三步共用图区
        _zoomCtrls(_viewerCtrl, _displaySize),
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

  /// 图区指针按下：单指按拖动模式分派（把手/挪框/平移画面/画框兜底/
  /// 角点校正），第二指落下转捏合缩放（作废单指手势+恢复快照+记起始）
  void _onStagePointerDown(PointerDownEvent e, _StageCtx ctx) {
    _activePtrs[e.pointer] = e.position;
    _ptrCount = _activePtrs.length;
    if (_ptrCount >= 2) {
      if (_ptrCount == 2) {
        _gestureVoided = true;
        final startSel = _gestureStartSel;
        if (startSel != null) {
          ctx.onSel(startSel);
        }
        _clearDragState();
        final pts = _activePtrs.values.toList();
        _pinchStartSpan = (pts[0] - pts[1]).distance;
        _pinchStartCenter = ((pts[0] + pts[1]) / 2) - _viewerOrigin();
        _pinchStartMatrix = _viewerCtrl.value.clone();
      }
      return; // 三指及以上不处理
    }
    // —— 单指按下：模式判定 ——
    _gestureVoided = false;
    _drawFrom = null;
    _gestureStartSel = null;
    _panStartPos = e.position;
    _lastPanPos = e.position;
    _panStartTime = DateTime.now();
    _prevMoveScreen = null;
    _prevMoveTime = null;
    _lastMoveScreen = e.position;
    _lastMoveTime = DateTime.now();
    // 四角把手优先（角点校正模式）：命中则进入拖角
    if (ctx.cornerPts != null) {
      _cornerDragIdx = -1;
      for (var i = 0; i < ctx.cornerPts!.length; i++) {
        if ((ctx.cornerPts![i] - e.localPosition).distance <= 30) {
          _cornerDragIdx = i;
          ctx.onCornerDrag?.call(i, e.localPosition);
          return;
        }
      }
      return; // 非角区拖动不画框：防误触清掉四角
    }
    // 九宫格标定框：缩放把手/框体拖动优先；未命中按 panFallback 分派
    // （对齐步=平移画面查看，框选步=画选区）——标定与框选两步不同屏
    if (ctx.miniAnchor != null && _pitchX > 0) {
      final hit = _hitMiniGrid(ctx.miniAnchor!, e.localPosition);
      if (hit == 1 || hit == 2) {
        _miniScaleDrag = true;
        // 固定对角：拖右下把手（hit==1）=左上角（锚点）不动；拖左上把手
        //（hit==2）=右下角不动。f 比例缩放基准快照：按下时对角到手指的
        // span（max(|dx|,|dy|)，对角线长斜向 √2 超调）与双 pitch——拖动
        // 中按比值同乘，保住非方形 pitchY
        final ds = _displaySize();
        final image = _image!;
        _miniScaleFixedTL = hit == 1;
        _miniScaleOpp = hit == 1
            ? ctx.miniAnchor!
            : ctx.miniAnchor! +
                Offset(
                  3 * _pitchX * ds.width / image.width,
                  3 * _pitchY * ds.height / image.height,
                );
        final d = e.localPosition - _miniScaleOpp!;
        _miniScaleBaseSpan = math.max(d.dx.abs(), d.dy.abs());
        _miniScaleBasePx = _pitchX;
        _miniScaleBasePy = _pitchY;
        return;
      }
      if (hit == 0) {
        _miniDragFrom = e.localPosition;
        _miniDragBase = ctx.miniAnchor!;
        return;
      }
    }
    // 把手 -> 拖把手调框；框内 -> 挪框；框外空白 -> 平移画面（放大观察，
    // 不建新框）；无框 -> 拖画建框兜底（panFallback 步无选区交互，直接
    // 平移查看）。快照供画框误触回溯与手势取消恢复；把手/挪框抬手不回
    // 溯（见 _onStagePointerUp）——把手按下须先命中命圈=明确调框意图，
    // 且微调正是小位移快松手，回溯会误杀；把手跨格误拖不自动恢复，需
    // 手动拖回或框外重画
    final sel = ctx.sel;
    _gestureStartSel = sel;
    _selHandleDrag = (sel != null && sel.width > 2)
        ? _hitSelHandle(sel, e.localPosition)
        : -1;
    if (_selHandleDrag < 0) {
      if (sel != null && sel.width > 2) {
        if (sel.contains(e.localPosition)) {
          _selMoveFrom = e.localPosition;
          _selMoveBase = sel;
        } else {
          _panViewMode = true;
        }
      } else if (ctx.panFallback) {
        _panViewMode = true; // 对齐步框外拖动=平移查看（不画选区）
      } else {
        _drawFrom = e.localPosition;
      }
    }
  }

  /// 图区指针移动：双指捏合改矩阵；单指按模式处理（角点/平移画面/挪框/
  /// 把手/画框）。localPosition 经 InteractiveViewer 逆变换即图坐标
  void _onStagePointerMove(PointerMoveEvent e, _StageCtx ctx) {
    if (_activePtrs.containsKey(e.pointer)) {
      _activePtrs[e.pointer] = e.position;
    }
    if (_ptrCount >= 2) {
      final base = _pinchStartMatrix;
      if (base != null && _pinchStartSpan > 1 && _activePtrs.length >= 2) {
        final pts = _activePtrs.values.toList();
        final span = (pts[0] - pts[1]).distance;
        final center = ((pts[0] + pts[1]) / 2) - _viewerOrigin();
        _applyPinch(base, span, center, ctx.cons);
      }
      return;
    }
    if (_gestureVoided) {
      return;
    }
    _prevMoveScreen = _lastMoveScreen;
    _prevMoveTime = _lastMoveTime;
    _lastMoveScreen = e.position;
    _lastMoveTime = DateTime.now();
    _lastPanPos = e.position;
    if (_cornerDragIdx >= 0) {
      ctx.onCornerDrag?.call(_cornerDragIdx, e.localPosition);
      return;
    }
    if (ctx.cornerPts != null) {
      return;
    }
    if (_panViewMode) {
      _panViewBy(e.delta, ctx.cons);
      return;
    }
    // 九宫格缩放把手（左上/右下双把手）：按下时快照的 span/双格距为
    // 基准，当前到固定对角的 span 按比值同乘（与 _adjustPitch 同语义）
    //——绝对 span 直算在等比显示下 py≡px 恒成立，一次拖拽就把非方形
    // pitchY 抹平；span 取 max(|dx|,|dy|)（对角线长斜向超调，把手会
    // 脱离手指）。拖左上把手时锚点=右下固定角-3 格新格距（对角不动）
    if (_miniScaleDrag && ctx.miniAnchor != null && _miniScaleOpp != null) {
      final image = _image!;
      final d = e.localPosition - _miniScaleOpp!;
      final span = math.max(d.dx.abs(), d.dy.abs());
      if (span > 24 && _miniScaleBaseSpan > 1) {
        final f = span / _miniScaleBaseSpan;
        final px = _miniScaleBasePx * f;
        final py = _miniScaleBasePy * f;
        if (px >= 2 && px <= image.width / 4) {
          final ds = _displaySize();
          final w = 3 * px * ds.width / image.width;
          final h = 3 * py * ds.height / image.height;
          // 拖左上把手：新锚点 = 固定右下角 - 3 格新格距，clamp 图内
          //（上界兜底非负，同九宫格拖动）
          final anchor = _miniScaleFixedTL
              ? _miniScaleOpp!
              : Offset(
                  (_miniScaleOpp!.dx - w)
                      .clamp(0.0, math.max(0.0, ds.width - w))
                      .toDouble(),
                  (_miniScaleOpp!.dy - h)
                      .clamp(0.0, math.max(0.0, ds.height - h))
                      .toDouble(),
                );
          setState(() {
            _pitchX = px;
            _pitchY = py;
            _miniAnchor = anchor;
          });
        }
      }
      return;
    }
    // 九宫格拖动：按起点位移移动锚点，clamp 图内防拖丢
    if (_miniDragFrom != null && _miniDragBase != null) {
      final delta = e.localPosition - _miniDragFrom!;
      final base = _miniDragBase!;
      final ds = _displaySize();
      final image = _image!;
      final w = 3 * _pitchX * ds.width / image.width;
      final h = 3 * _pitchY * ds.height / image.height;
      // 上界兜底非负：「格子大小 +」无上限，格距放大到 3 格超图宽时
      // ds.width - w 为负，clamp 负上界直接抛 ArgumentError（手势卡死）
      final left = (base.dx + delta.dx)
          .clamp(0.0, math.max(0.0, ds.width - w))
          .toDouble();
      final top = (base.dy + delta.dy)
          .clamp(0.0, math.max(0.0, ds.height - h))
          .toDouble();
      ctx.onMiniAnchor?.call(Offset(left, top));
      return;
    }
    final sel = ctx.sel;
    if (_selMoveFrom != null && _selMoveBase != null) {
      // 框内挪框：按起点位移移动选区，clamp 图内防拖丢
      final delta = e.localPosition - _selMoveFrom!;
      final base = _selMoveBase!;
      final dsz = _displaySize();
      // 上界兜底非负（同九宫格拖动：选区宽超出图显示宽时防负上界崩溃）
      final left = (base.left + delta.dx)
          .clamp(0.0, math.max(0.0, dsz.width - base.width))
          .toDouble();
      final top = (base.top + delta.dy)
          .clamp(0.0, math.max(0.0, dsz.height - base.height))
          .toDouble();
      ctx.onSel(Rect.fromLTWH(left, top, base.width, base.height));
      return;
    }
    if (_selHandleDrag >= 0 && sel != null) {
      ctx.onSel(_applySelHandle(sel, _selHandleDrag, e.localPosition));
      return;
    }
    if (_drawFrom != null) {
      ctx.onSel(Rect.fromPoints(_drawFrom!, e.localPosition));
    }
  }

  /// 图区指针抬起：全部抬起时按 位移+时长+速度 三重判定回溯误触；
  /// 捏合结束剩一指则转为平移画面继续跟手
  void _onStagePointerUp(PointerUpEvent e, _StageCtx ctx) {
    _activePtrs.remove(e.pointer);
    _ptrCount = _activePtrs.length;
    if (_ptrCount == 1) {
      _enterPanViewAfterPinch();
      return;
    }
    if (_ptrCount > 0) {
      return;
    }
    _pinchStartMatrix = null;
    final startSel = _gestureStartSel;
    final start = _panStartPos;
    if (!_gestureVoided && startSel != null && start != null) {
      final end = _lastPanPos ?? start;
      final dist = (end - start).distance;
      // 误触回溯判定：点击抖动（位移<_tapRecoverDist）或轻扫（时长短
      // 且末速高）恢复手势前快照。吸附格线后小拖快松即可得整格框——
      // 曾按「时长<260ms 也判轻扫」回溯，把这类精确框选整批误杀（框选
      // 主体步松手必弹回的主因），现只认末速。
      // 挪框/把手不回溯（所见即所得）：挪框有实时视觉反馈、误挪一眼
      // 可见可再挪回来；把手按下点须先命中命圈，本身是明确调框意图，
      // 且微调正是小位移+快松手——回溯只拦画框（覆盖旧框）的破坏性误触
      final v = _releaseVelocity();
      final elapsed = _panStartTime == null
          ? 9999
          : DateTime.now().difference(_panStartTime!).inMilliseconds;
      final quickSlide = dist < _flingRecoverDist &&
          elapsed < _flingMaxElapsed &&
          v > _flingVelocity;
      if (_selHandleDrag < 0 &&
          _selMoveFrom == null &&
          (dist < _tapRecoverDist || quickSlide)) {
        ctx.onSel(startSel);
      }
    }
    _clearDragState();
  }

  /// 指针异常中止（系统夺走等）：剩一指转平移画面，全抬起视为手势作废
  ///——恢复按下前选区快照（cancel 意味着手势没走完，中间态不留）
  void _onStagePointerCancel(PointerCancelEvent e, _StageCtx ctx) {
    _activePtrs.remove(e.pointer);
    _ptrCount = _activePtrs.length;
    if (_ptrCount == 1) {
      _enterPanViewAfterPinch();
      return;
    }
    if (_ptrCount > 0) {
      return;
    }
    _pinchStartMatrix = null;
    final startSel = _gestureStartSel;
    if (!_gestureVoided && startSel != null) {
      ctx.onSel(startSel);
    }
    _clearDragState();
  }

  /// 捏合结束（2→1 指）：剩余手指转为平移画面继续跟手，不触发框回溯
  void _enterPanViewAfterPinch() {
    _pinchStartMatrix = null;
    _panViewMode = true;
    _gestureVoided = false;
    _panStartTime = DateTime.now();
    _gestureStartSel = null;
    _panStartPos = null;
    _lastPanPos = null;
  }

  /// 桌面触控板手势开始（独立事件流，无 pointer id）：作废进行中的单指
  /// 手势防误框，触控板捏合缩放暂不支持
  void _onStagePanZoomStart(void Function(Rect) onSel) {
    final startSel = _gestureStartSel;
    if (startSel != null) {
      onSel(startSel);
    }
    _clearDragState();
  }

  /// 双指捏合：由起始矩阵+当前 span/center 非增量式推算新矩阵——锚点=
  /// 起始两指中心（该处内容跟手移到当前中心），span 比例定缩放倍率，
  /// scale 与平移均 clamp（同滚轮平移边界），避免逐帧增量累积误差
  void _applyPinch(
      Matrix4 base, double span, Offset center, BoxConstraints cons) {
    final s0 = base.storage[0];
    if (s0 <= 0 || _pinchStartSpan <= 1) {
      return;
    }
    final s1 = (s0 * span / _pinchStartSpan).clamp(1.0, 8.0);
    final c0 = _pinchStartCenter;
    final t0 = base.getTranslation();
    // 屏幕点 p = t + s*x；要求捏合起始锚点 c0 的内容出现在 center：
    // t1 = center - (c0 - t0) * s1/s0
    var dx = center.dx - (c0.dx - t0.x) * (s1 / s0);
    var dy = center.dy - (c0.dy - t0.y) * (s1 / s0);
    final dsz = _displaySize();
    final minX = math.min(0.0, cons.maxWidth - dsz.width * s1);
    final minY = math.min(0.0, cons.maxHeight - dsz.height * s1);
    dx = dx.clamp(minX, 0.0).toDouble();
    dy = dy.clamp(minY, 0.0).toDouble();
    // 直设矩阵元（translate/scale 已废弃）：纯平移 + 等比缩放，无旋转
    final m = Matrix4.identity();
    m.setEntry(0, 0, s1);
    m.setEntry(1, 1, s1);
    m.setEntry(0, 3, dx);
    m.setEntry(1, 3, dy);
    _viewerCtrl.value = m;
  }

  /// viewport 左上角的全局坐标：PointerEvent.position 是全局坐标（含
  /// AppBar 偏移），矩阵 translation 是 viewport 局部坐标，换算差此原点
  Offset _viewerOrigin() {
    final obj = _viewerKey.currentContext?.findRenderObject();
    if (obj is RenderBox) {
      return obj.localToGlobal(Offset.zero);
    }
    return Offset.zero;
  }

  /// 抬手末速（逻辑px/s）：最近两帧 move 位移/时间差——自实现手势没有
  /// DragEndDetails.velocity，末速只作误触判定的辅助条件，近似即可
  double _releaseVelocity() {
    final a = _prevMoveScreen;
    final b = _lastMoveScreen;
    final ta = _prevMoveTime;
    final tb = _lastMoveTime;
    if (a == null || b == null || ta == null || tb == null) {
      return 0;
    }
    final dt = tb.difference(ta).inMicroseconds;
    if (dt <= 0) {
      return 0;
    }
    return (b - a).distance / (dt / 1e6);
  }

  /// 清空单指手势中间态（不动 _activePtrs/_ptrCount/_pinch*）
  void _clearDragState() {
    _drawFrom = null;
    _gestureStartSel = null;
    _panStartPos = null;
    _lastPanPos = null;
    _cornerDragIdx = -1;
    _selHandleDrag = -1;
    _panViewMode = false;
    _selMoveFrom = null;
    _selMoveBase = null;
    _miniDragFrom = null;
    _miniDragBase = null;
    _miniScaleDrag = false;
    _miniScaleOpp = null;
    _miniScaleBaseSpan = 0;
    _miniScaleBasePx = 0;
    _miniScaleBasePy = 0;
    _gestureVoided = false;
    _panStartTime = null;
    _prevMoveScreen = null;
    _prevMoveTime = null;
    _lastMoveScreen = null;
    _lastMoveTime = null;
  }

  /// 单指拖动平移画面（框存在时的默认拖动行为——放大观察）。与滚轮
  /// 平移（_onImgPointerSignal）同 clamp：[viewport-图, 0]，滚到边界即停；
  /// delta 为屏幕坐标增量直接累加矩阵平移分量，内容跟手
  void _panViewBy(Offset delta, BoxConstraints cons) {
    final cur = _viewerCtrl.value;
    final scale = cur.storage[0];
    final ds = _displaySize();
    final minX = math.min(0.0, cons.maxWidth - ds.width * scale);
    final minY = math.min(0.0, cons.maxHeight - ds.height * scale);
    final dx = (cur.getTranslation().x + delta.dx).clamp(minX, 0.0).toDouble();
    final dy = (cur.getTranslation().y + delta.dy).clamp(minY, 0.0).toDouble();
    // 直设矩阵元（translate/scale 已废弃）：纯平移 + 等比缩放，无旋转
    final m = Matrix4.identity();
    m.setEntry(0, 0, scale);
    m.setEntry(1, 1, scale);
    m.setEntry(0, 3, dx);
    m.setEntry(1, 3, dy);
    _viewerCtrl.value = m;
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

  /// 当前对齐覆盖层（无有效参数返回 null）
  ///
  /// 四角模式：四角双线性网格；九宫格模式：3×3 标定框——识别切分的格线
  /// 相位与格距全部由它导出，所见即所采。
  CustomPainter? _mainOverlay() {
    if (_useCornerAlign) {
      final pts = _cornerPts;
      final cols = int.tryParse(_colsCtrl.text) ?? 0;
      final rows = int.tryParse(_rowsCtrl.text) ?? 0;
      if (pts == null || pts.length != 4 || cols < 1 || rows < 1) {
        return null;
      }
      return _CornerGridPainter(pts: pts, cols: cols, rows: rows);
    }
    final anchor = _miniAnchor;
    if (anchor == null || _pitchX <= 0 || _pitchY <= 0) {
      return null;
    }
    final ds = _displaySize();
    final image = _image!;
    return _MiniGridPainter(
      grid: Rect.fromLTWH(
        anchor.dx,
        anchor.dy,
        3 * _pitchX * ds.width / image.width,
        3 * _pitchY * ds.height / image.height,
      ),
      scale: _viewerCtrl.value.storage[0],
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
                // 显式自动框选入口：载入时已自动尝试过，选区被改动或
                // 想重选时可随时点这里重跑（AppBar 魔法棒同功能）
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _autoSelectLegend,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Text("自动框选图例区"),
                  ),
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
                            "下一步：九宫格对齐（${_legend.length}色）",
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

  /// 阶段②：九宫格标定每格大小（本步只做标定，框选主体在下一步独立
  /// 进行）；四角对齐作歪图透视备选（四角即区域、无独立框选步，直接识别）
  Widget _buildAlign() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _imageStage(
              // 本步无选区交互：sel 恒 null，九宫格未命中的拖动走
              // panFallback=平移画面查看（放大核对格线重叠情况）
              sel: null,
              onSel: (_) {},
              overlay: _mainOverlay(),
              cornerPts: _useCornerAlign ? _cornerPts : null,
              onCornerDrag: _onCornerDrag,
              miniAnchor: _useCornerAlign ? null : _miniAnchor,
              onMiniAnchor: (p) => setState(() => _miniAnchor = p),
              panFallback: true,
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
                    icon: Icon(Icons.grid_3x3, size: 18),
                    label: Text("九宫格标定"),
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
                    : _alignHint(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_useCornerAlign) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: TextField(
                        controller: _colsCtrl,
                        keyboardType: TextInputType.number,
                        // 四角覆盖层读 controller 文本定行列，改动即重画
                        onChanged: (_) => setState(() {}),
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
                        controller: _rowsCtrl,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: "行",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _resetCorners,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text("重置四角"),
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.document_scanner),
                        label: Text(_recognizing ? "识别中…" : "开始识别"),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // 紧凑 IconButton（36 逻辑点击区 + 22 图标）+ 格子大小/微移
                // 拆两行：单行放 6 个按钮加标签在窄屏/大字体下仍会溢出
                // （用户实测微移控件被裁出屏错误显示）
                Row(
                  children: [
                    const Text("格子大小"),
                    _compactIconBtn(
                      onPressed: _pitchX > 0 ? () => _adjustPitch(-0.2) : null,
                      icon: Icons.remove_circle_outline,
                    ),
                    Text(_pitchX > 0 ? _pitchX.toStringAsFixed(2) : "--"),
                    _compactIconBtn(
                      onPressed: _pitchX > 0 ? () => _adjustPitch(0.2) : null,
                      icon: Icons.add_circle_outline,
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Text("微移"),
                    _compactIconBtn(
                      onPressed: _pitchX > 0 ? () => _nudge(-1, 0) : null,
                      icon: Icons.arrow_left,
                      tooltip: "左移",
                    ),
                    _compactIconBtn(
                      onPressed: _pitchX > 0 ? () => _nudge(0, -1) : null,
                      icon: Icons.arrow_upward,
                      tooltip: "上移",
                    ),
                    _compactIconBtn(
                      onPressed: _pitchX > 0 ? () => _nudge(0, 1) : null,
                      icon: Icons.arrow_downward,
                      tooltip: "下移",
                    ),
                    _compactIconBtn(
                      onPressed: _pitchX > 0 ? () => _nudge(1, 0) : null,
                      icon: Icons.arrow_right,
                      tooltip: "右移",
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed:
                        _pitchX > 0 && _miniAnchor != null ? _goFrame : null,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text("下一步：框选主体"),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 九宫格对齐步骤的引导（本步只做标定，框选主体在下一步）
  String _alignHint() {
    if (_detecting) {
      return "正在自动检测格距并放置九宫格…";
    }
    if (_pitchX <= 0 || _miniAnchor == null) {
      return "拖动九宫格、调格子大小，使 9 格与图纸上的格子完全重叠";
    }
    return "已定每格 ${_pitchX.toStringAsFixed(1)} 像素 · 对齐无误后进入下一步框选主体";
  }

  /// 按当前主体选区 + 标定格距推算切分行列数（与 _recognize 同公式，
  /// 格线相位锚定九宫格）；不满足 4-400 返回 null
  (int, int)? _plannedColsRows() {
    final anchor = _miniAnchor;
    final sel = _selDisplay;
    final image = _image;
    if (anchor == null ||
        sel == null ||
        sel.width <= 8 ||
        sel.height <= 8 ||
        image == null ||
        _pitchX <= 0 ||
        _pitchY <= 0) {
      return null;
    }
    final (rx, ry, rw, rh) = _selToImage(sel);
    final ds = _displaySize();
    var offX = (anchor.dx * image.width / ds.width - rx) % _pitchX;
    if (offX < 0) {
      offX += _pitchX;
    }
    var offY = (anchor.dy * image.height / ds.height - ry) % _pitchY;
    if (offY < 0) {
      offY += _pitchY;
    }
    // 吸附选区的相位残差钳制（同 _recognize：防 % 回绕成 pitch-ε 少切
    // 一列/行，与框上徽标数不一致）
    if (offX < 1e-6 || _pitchX - offX < 1e-6) {
      offX = 0;
    }
    if (offY < 1e-6 || _pitchY - offY < 1e-6) {
      offY = 0;
    }
    final cols = ((rw - offX) / _pitchX + 0.5).floor();
    final rows = ((rh - offY) / _pitchY + 0.5).floor();
    if (cols < 4 || rows < 4 || cols > 400 || rows > 400) {
      return null;
    }
    return (cols, rows);
  }

  /// 选区吸附到九宫格格线（框选主体步）：四边各吸附最近格线（相位锚定
  /// 标定锚点），框的任何变化都是整格增减；两边吸到同一条格线（输入框
  /// 小于半格：微拖抖动/把手收过头压扁）时不吸附保持原框，不保底膨胀
  /// 成 1×1 格——那会锁死重画路径且收框时保底推错边整框跳格（见下方
  /// 退化分支注释）；不出图（出图按整格调回，框比图还大等极端态放弃
  /// 吸附保持原框）
  Rect _snapSelToGrid(Rect r) {
    final anchor = _miniAnchor;
    final image = _image;
    if (anchor == null || image == null || _pitchX <= 0 || _pitchY <= 0) {
      return r;
    }
    final ds = _displaySize();
    final pitchDx = _pitchX * ds.width / image.width;
    final pitchDy = _pitchY * ds.height / image.height;
    if (pitchDx < 2 || pitchDy < 2) {
      return r; // 格距显示 <2px（与 _FrameGridPainter 绘制阈值一致：该区间
      // 格线/行列徽标都不画），吸附步进低于触摸精度，保持自由框选
    }
    double snap(double v, double origin, double pitch) =>
        origin + ((v - origin) / pitch).round() * pitch;
    var l = snap(r.left, anchor.dx, pitchDx);
    var t = snap(r.top, anchor.dy, pitchDy);
    var rt = snap(r.right, anchor.dx, pitchDx);
    var b = snap(r.bottom, anchor.dy, pitchDy);
    if (rt - l < pitchDx || b - t < pitchDy) {
      // 两边吸附到同一条格线（输入框小于半格：点击抖动的微拖、把手收
      // 过头压扁成细条）→ 放弃吸附保持原框。原「保底膨胀成 1×1 格」有
      // 两个坑：① 微拖抖动膨胀出 width>2 的死格选区后，框外拖动被分派
      // 为平移画面、「另起新框」路径锁死（改动前 ≤2px 微拖按无框自愈）；
      // ② 拖左/上把手收框压扁时保底推进右/下边，未拖动的对边整格跳走、
      // 框跟着手指跑。保持小框让调用方按无框/细条处理即可自愈重画
      return r;
    }
    // 出图整格调回（平移量为整数格，保持格线对齐）
    if (l < 0) {
      final s = (-l / pitchDx).ceil() * pitchDx;
      l += s;
      rt += s;
    }
    if (t < 0) {
      final s = (-t / pitchDy).ceil() * pitchDy;
      t += s;
      b += s;
    }
    if (rt > ds.width) {
      final s = ((rt - ds.width) / pitchDx).ceil() * pitchDx;
      l -= s;
      rt -= s;
    }
    if (b > ds.height) {
      final s = ((b - ds.height) / pitchDy).ceil() * pitchDy;
      t -= s;
      b -= s;
    }
    if (l < 0 || t < 0 || rt > ds.width || b > ds.height) {
      return r;
    }
    return Rect.fromLTRB(l, t, rt, b);
  }

  /// 阶段③：框选主体区域（九宫格已定格距，本步只做框选——拖画/挪框/
  /// 把手调大小）。选区四边吸附格线（相位锚定九宫格锚点）：框的一切
  /// 变化都是整格增减，框到哪格就是哪格；覆盖层只在选区内铺格线并在
  /// 框上方实时显示行列数（不再全图画虚线格——标定只用来约束框选，
  /// 图面保持干净）
  Widget _buildFrame() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _imageStage(
              sel: _selDisplay,
              onSel: (r) => setState(() => _selDisplay = _snapSelToGrid(r)),
              overlay: _frameOverlay(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_frameHint(), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
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

  /// 框选步覆盖层：选区内格线（相位锚定九宫格锚点，选区四边已吸附格线
  /// ——所见格数即切分格数）+ 框上方行列数徽标实时跟手；未框选时不画
  /// 任何东西（标定结果只约束框选，不整图铺虚线）
  CustomPainter? _frameOverlay() {
    final anchor = _miniAnchor;
    final image = _image;
    final sel = _selDisplay;
    if (anchor == null ||
        image == null ||
        _pitchX <= 0 ||
        _pitchY <= 0 ||
        sel == null ||
        sel.width < 2 ||
        sel.height < 2) {
      return null;
    }
    final ds = _displaySize();
    return _FrameGridPainter(
      sel: sel,
      pitchDx: _pitchX * ds.width / image.width,
      pitchDy: _pitchY * ds.height / image.height,
      scale: _viewerCtrl.value.storage[0],
    );
  }

  /// 框选主体步骤的引导：未框选提示拖框，已框选实时预告切分行列数
  String _frameHint() {
    final sel = _selDisplay;
    if (sel == null || sel.width <= 8 || sel.height <= 8) {
      return "在图上拖框选中主体区域（拼豆格子部分）；框边自动吸附格线、按整格增减，行列数实时显示在框上方";
    }
    final cr = _plannedColsRows();
    return cr == null
        ? "框选范围与格距不匹配（切分数超 4-400），请调整框选或回九宫格调格子大小"
        : "将按 ${cr.$2} 行 × ${cr.$1} 列切分主体，点「开始识别」";
  }

  /// 阶段四：按色号分组复核 + 手工归类 + 图例数量对账
  ///
  /// 筛选关闭（-2）显示总览豆图；选中色号切换为该色全部格子的截图墙
  /// （截图取自原图同位置，肉眼核对印刷色号/颜色，错认的点击选中后
  /// 重新归类）
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
            child: _reviewColor == -2
                ? _buildReviewOverview()
                : _buildCellGallery(),
          ),
        ),
        _buildReviewActions(order, counts, blankCount),
      ],
    );
  }

  /// 总览：整幅豆图（长按拖动缩放、点选格子）
  Widget _buildReviewOverview() {
    final model = _model!;
    return Stack(
      children: [
        Center(
          child: InteractiveViewer(
            maxScale: 12,
            transformationController: _reviewCtrl,
            child: AspectRatio(
              aspectRatio: model.width / model.height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cellW = constraints.maxWidth / model.width;
                  final cellH = constraints.maxHeight / model.height;
                  // 速记画布内容尺寸（无 setState，build 期间赋值）——
                  // ZoomControls 缩放边界计算用
                  _reviewCanvasSize = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
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
        _zoomCtrls(
          _reviewCtrl,
          () => _reviewCanvasSize,
          maxScale: 12,
          viewportIsContent: true,
        ),
      ],
    );
  }

  /// 截图墙：当前复核色全部格子的原图截图（_cellRects 与 grid 扁平索引
  /// 同序），点击选中/取消，配合「归类到…」或点目标色号 chip 重新分配
  Widget _buildCellGallery() {
    final model = _model!;
    final src = _cellSrc;
    final cells = [
      for (var i = 0; i < model.grid.length; i++)
        if (model.grid[i] == _reviewColor) i,
    ];
    if (src == null) {
      return Center(
        child: Text(
          "截图加载中…（共 ${cells.length} 格）",
          style: const TextStyle(fontSize: 13, color: Colors.black45),
        ),
      );
    }
    final image = _image!;
    final scaleX = src.width / image.width;
    final scaleY = src.height / image.height;
    final srcBounds = Rect.fromLTWH(
      0,
      0,
      src.width.toDouble(),
      src.height.toDouble(),
    );
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: cells.length,
      itemBuilder: (_, k) {
        final i = cells[k];
        // 格矩形（原图坐标）-> 截图源坐标（_cellSrc 是限幅显示版，按比例
        // 换算），intersect 源界防超界（四角模式角点拖出图界时矩形越界，
        // drawImageRect srcRect 越界直接抛异常）
        Rect? srcRect;
        if (i < _cellRects.length) {
          final cr = _cellRects[i];
          final r = Rect.fromLTWH(
            cr.left * scaleX,
            cr.top * scaleY,
            cr.width * scaleX,
            cr.height * scaleY,
          ).intersect(srcBounds);
          if (!r.isEmpty) {
            srcRect = r;
          }
        }
        final picked = _picked.contains(i);
        return GestureDetector(
          onTap: () => setState(() {
            _picked.contains(i) ? _picked.remove(i) : _picked.add(i);
          }),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: picked ? Colors.blue : Colors.black12,
                width: picked ? 2.5 : 1,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (srcRect != null)
                  ClipRect(
                    child: CustomPaint(
                      painter: _CellThumbPainter(src: src, srcRect: srcRect),
                      size: Size.infinite,
                    ),
                  ),
                // 右下角行列号（1 起）：错认截图回报位置用
                Positioned(
                  right: 1,
                  bottom: 1,
                  child: Container(
                    color: Colors.black45,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      "${i % model.width + 1},${i ~/ model.width + 1}",
                      style: const TextStyle(fontSize: 8, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
  /// （再点同一 chip 回 -2 总览取消筛选）
  void _reviewChipTap(int target) {
    if (_picked.isNotEmpty && target != _reviewColor) {
      _classifyPickedTo(target);
      return;
    }
    setState(() {
      _reviewColor = target == _reviewColor ? -2 : target;
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
            "④ 点色号筛选看该色格子截图 → 点截图选中 → 归类到图例色号或空白；再点同一色号回总览",
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
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _picked.isEmpty || !_hasClassifyTarget()
                    ? null
                    : _reassignPicked,
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text("归类到…"),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saveWork,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text("保存作品"),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
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

/// 图区手势上下文：build 闭包里的回调/选区/角点/约束打包，
/// 供 Listener 的四个指针处理方法共用（避免长参数表）
class _StageCtx {
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

  const _StageCtx(
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

/// 九宫格标定覆盖层：3×3 标定框（细线）+ 全图同相位虚线延伸格 +
/// 左上/右下双缩放把手（仅「② 九宫格对齐」步使用；框选主体步的
/// 选区内格线见 _FrameGridPainter）
///
/// 识别切分的格距与格线相位全部由这个框导出（格距 = 边长/3，锚点 =
/// 左上角即第一根格线交点）。虚线延伸格从锚点按格距铺满全图、与九宫格
/// 同相位——比对齐不必只盯着 9 格：外围任何一格的虚线压住图纸格线即
/// 对齐成功。线宽/把手尺寸按当前视图缩放补偿（除以 scale）：放大后
/// 视觉尺寸恒定，粗线不糊掉格线、大把手不遮挡内容不误触。
class _MiniGridPainter extends CustomPainter {
  final Rect grid;

  ///< 3×3 框（显示坐标）
  final double scale;

  ///< 当前视图缩放倍数（InteractiveViewer 矩阵，尺寸补偿用）

  _MiniGridPainter({required this.grid, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final pitchDx = grid.width / 3;
    final pitchDy = grid.height / 3;
    if (pitchDx < 2 || pitchDy < 2) {
      return;
    }
    // 全图同相位虚线格：x/y 起点取锚点对格距取模（与九宫格共用原点），
    // 段长 = 格距/3、空隙 = 格距/6（视觉密度随格距自适应），全部收进
    // 一个 Path 一次 stroke。alpha/线宽加强（用户实测原 0.35/0.8 在
    // 彩色图纸上几乎看不见，对齐无从核对）
    final dashP = Paint()
      ..color = const Color(0xFFE65100).withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 / scale;
    final path = Path();
    var x0 = grid.left % pitchDx;
    if (x0 < 0) {
      x0 += pitchDx;
    }
    final dashY = pitchDy / 3;
    final stepY = dashY + pitchDy / 6;
    for (var x = x0; x <= size.width; x += pitchDx) {
      for (var y = 0.0; y < size.height;) {
        path.moveTo(x, y);
        path.lineTo(x, math.min(y + dashY, size.height));
        y += stepY;
      }
    }
    var y0 = grid.top % pitchDy;
    if (y0 < 0) {
      y0 += pitchDy;
    }
    final dashX = pitchDx / 3;
    final stepX = dashX + pitchDx / 6;
    for (var y = y0; y <= size.height; y += pitchDy) {
      for (var x = 0.0; x < size.width;) {
        path.moveTo(x, y);
        path.lineTo(math.min(x + dashX, size.width), y);
        x += stepX;
      }
    }
    canvas.drawPath(path, dashP);
    // 3×3 实线框（细）：粗线在格距 ~22 显示px 时占格边 9%，压住图纸
    // 格线没法比对是否重叠（用户实测反馈），细到 1.4/scale 视觉恒定
    final outline = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 / scale;
    canvas.drawRect(grid, outline);
    // 内部十字线：2 竖 + 2 横（1/3、2/3 处）
    final inner = Paint()
      ..color = const Color(0xFFE65100).withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9 / scale;
    for (var i = 1; i <= 2; i++) {
      final x = grid.left + grid.width * i / 3;
      canvas.drawLine(Offset(x, grid.top), Offset(x, grid.bottom), inner);
      final y = grid.top + grid.height * i / 3;
      canvas.drawLine(Offset(grid.left, y), Offset(grid.right, y), inner);
    }
    // 左上/右下双缩放把手：拖右下=左上角（锚点）不动调格距；拖左上=
    // 右下角不动。白底橙圈，半径随缩放补偿（放大后不会变巨误触）
    final fill = Paint()..color = Colors.white;
    final stroke = Paint()
      ..color = const Color(0xFFE65100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 / scale;
    for (final handle in [grid.topLeft, grid.bottomRight]) {
      canvas.drawCircle(handle, 8 / scale, fill);
      canvas.drawCircle(handle, 8 / scale, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniGridPainter oldDelegate) =>
      oldDelegate.grid != grid || oldDelegate.scale != scale;
}

/// 框选主体覆盖层：选区内格线（相位锚定九宫格锚点，选区四边已吸附
/// 格线——所见格数 = 识别切分格数）+ 选区上缘行列数徽标（拖框/缩放
/// 实时跟手，格数超识别范围 4-400 转红提醒）
///
/// 九宫格标定只负责定格距与相位（对齐步完成），本层不再全图画虚线
/// 格——框外区域保持干净，格线只铺在选区内。徽标/字号按当前视图缩放
/// 补偿（除以 scale）：放大后视觉尺寸恒定。
class _FrameGridPainter extends CustomPainter {
  final Rect sel;

  ///< 选区（显示坐标，四边已吸附格线）
  final double pitchDx;

  ///< 横向格距（显示坐标）
  final double pitchDy;

  ///< 纵向格距（显示坐标）
  final double scale;

  ///< 当前视图缩放倍数（尺寸补偿用）

  _FrameGridPainter({
    required this.sel,
    required this.pitchDx,
    required this.pitchDy,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    if (pitchDx < 2 || pitchDy < 2) {
      return;
    }
    final cols = (sel.width / pitchDx).round();
    final rows = (sel.height / pitchDy).round();
    // 选区内格线：选区四边本身就是格线（吸附），从左上铺 cols+1 竖线、
    // rows+1 横线（计数循环防浮点漂移多画/漏画边缘线）
    final line = Paint()
      ..color = const Color(0xFFE65100).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 / scale;
    final path = Path();
    for (var i = 0; i <= cols; i++) {
      final x = sel.left + i * pitchDx;
      path.moveTo(x, sel.top);
      path.lineTo(x, sel.bottom);
    }
    for (var j = 0; j <= rows; j++) {
      final y = sel.top + j * pitchDy;
      path.moveTo(sel.left, y);
      path.lineTo(sel.right, y);
    }
    canvas.drawPath(path, line);
    // 行列数徽标：选区上缘外居中，出屏（框贴画布顶）收进框内；格数超
    // 识别范围转红（底部引导文案同时说明原因）
    final outOfRange = cols < 4 || rows < 4 || cols > 400 || rows > 400;
    final tp = TextPainter(
      text: TextSpan(
        text: "$rows行 × $cols列",
        style: TextStyle(
          color: Colors.white,
          fontSize: 12 / scale,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final padH = 8 / scale;
    final padV = 4 / scale;
    final bw = tp.width + padH * 2;
    final bh = tp.height + padV * 2;
    final bx = (sel.center.dx - bw / 2)
        .clamp(0.0, math.max(0.0, size.width - bw))
        .toDouble();
    final gap = 6 / scale;
    final by = sel.top - bh - gap >= 0
        ? sel.top - bh - gap
        : math.min(sel.top + gap, math.max(0.0, size.height - bh));
    final badge = RRect.fromRectAndRadius(
      Rect.fromLTWH(bx, by, bw, bh),
      Radius.circular(bh / 2),
    );
    canvas.drawRRect(
      badge,
      Paint()
        ..color =
            outOfRange ? const Color(0xFFC62828) : const Color(0xFFE65100),
    );
    tp.paint(canvas, Offset(bx + padH, by + padV));
  }

  @override
  bool shouldRepaint(covariant _FrameGridPainter oldDelegate) =>
      oldDelegate.sel != sel ||
      oldDelegate.pitchDx != pitchDx ||
      oldDelegate.pitchDy != pitchDy ||
      oldDelegate.scale != scale;
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

/// 复核截图墙的格子截图：从限幅显示版 ui.Image 按 srcRect 取格绘制
class _CellThumbPainter extends CustomPainter {
  final ui.Image src;

  ///< 限幅显示版图（_displayBytes 解码）
  final Rect srcRect;

  ///< 取材区（src 坐标，已 intersect 源界）

  _CellThumbPainter({required this.src, required this.srcRect});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      src,
      srcRect,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _CellThumbPainter oldDelegate) =>
      oldDelegate.src != src || oldDelegate.srcRect != srcRect;
}
