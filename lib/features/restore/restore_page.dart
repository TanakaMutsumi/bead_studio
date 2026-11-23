import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../core/adaptive_text.dart';
import '../../core/app_build.dart';
import '../../core/app_snack_bar.dart';
import '../../core/decode_image.dart';
import '../../core/draft_store.dart';
import '../../core/grid_detector.dart';
import '../../core/legend_detect.dart';
import '../../core/legend_ocr.dart';
import '../../core/palette.dart';
import '../../core/palette_registry.dart';
import '../../core/pattern_model.dart';
import '../../core/quantizer.dart';
import '../../core/responsive.dart';
import '../../core/subject_detect.dart';
import '../../core/zoom_controls.dart';
import '../editor/editor_page.dart';
import '../palette_picker.dart';
import '../works/works_page.dart';
import 'legend_ocr_runner.dart';
import 'restore_painters.dart';
import 'restore_types.dart';
import 'steps/align_step.dart';
import 'steps/frame_step.dart';
import 'steps/legend_step.dart';
import 'steps/pick_step.dart';
import 'steps/review_step.dart';

/// 空白判定阈值：格色与候选色的 Lab 距离平方超过此值视为空白格
const double _blankDistSq = 900.0; // ΔE ≈ 30

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

/// 图例带游程检测（顶层函数供 compute isolate 调用）：native 窗口全图
/// 半数行 × 全宽 getPixel、窗外相机原片还要先整图缩放——主 isolate 同步
/// 跑会冻结 UI（2026-11-02 模拟器实测载图自动预框段 0.7s），与
/// detectGridInIsolate 同理入 isolate。算法本体 legend_detect.dart 零改动
LegendDetectResult? detectLegendInIsolate(img.Image image) =>
    detectLegendCanonical(image);

/// 主体检测（顶层函数供 compute isolate 调用）：全图行列扫描同为主线程
/// 重活，进③自动框选与图例检测同批次入 isolate
class SubjectDetectArgs {
  final img.Image image;
  final double legendTop;
  final double pitchX, pitchY;
  const SubjectDetectArgs(this.image, this.legendTop, this.pitchX, this.pitchY);
}

SubjectBBox? detectSubjectInIsolate(SubjectDetectArgs a) {
  return detectSubjectBBox(
    a.image,
    legendTop: a.legendTop,
    pitchX: a.pitchX,
    pitchY: a.pitchY,
  );
}

/// 图例识别前置重活（compute isolate 入参/出参）：灰度构建 + 网格检测 +
/// 逐格采样量化打包一次过 isolate——空选区兜底是整图百万级 getPixel、
/// 宽松框选采样可达数万格 × 25 点，主 isolate 会冻结秒级（2026-11-02
/// 模拟器实测大框识别起步段 0.7s+）
class ScanLegendArgs {
  final img.Image image;
  final BeadPalette palette;
  final double rx, ry, rw, rh;
  const ScanLegendArgs(
    this.image,
    this.palette,
    this.rx,
    this.ry,
    this.rw,
    this.rh,
  );
}

class ScanLegendResult {
  final GridDetectResult? det;
  final Map<int, int> freq;
  const ScanLegendResult(this.det, this.freq);
}

ScanLegendResult scanLegendInIsolate(ScanLegendArgs a) {
  final image = a.image;
  final gray = <int>[];
  for (var y = a.ry.toInt(); y < a.ry + a.rh; y++) {
    for (var x = a.rx.toInt(); x < a.rx + a.rw; x++) {
      final p = image.getPixel(x, y);
      gray.add((p.r * 0.299 + p.g * 0.587 + p.b * 0.114).round());
    }
  }
  final det = detectGrid(gray, a.rw.toInt(), a.rh.toInt());
  var cols = 8, rows = 1;
  var pitchX = a.rw / cols, pitchY = a.rh / rows, offX = 0.0, offY = 0.0;
  if (det != null) {
    cols = det.cols;
    rows = det.rows;
    pitchX = det.pitchX;
    pitchY = det.pitchY;
    offX = det.offsetX;
    offY = det.offsetY;
  }
  final quantizer = Quantizer(a.palette);
  final freq = <int, int>{};
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final cx = a.rx + offX + (c + 0.5) * pitchX;
      final cy = a.ry + offY + (r + 0.5) * pitchY;
      final (sr, sg, sb) = sampleCenterMedian(image, cx, cy, pitchX, pitchY);
      final idx = quantizer.nearestIndex(sr, sg, sb);
      freq[idx] = (freq[idx] ?? 0) + 1;
    }
  }
  return ScanLegendResult(det, freq);
}

/// 格子中心 5×5 亮度中值采样（语义注释见 _RestorePageState._sampleCenter；
/// 抽顶层供 isolate 与主线程共用，_recognize 仍走方法壳调用保持原点）
(int, int, int) sampleCenterMedian(
  img.Image image,
  double cx,
  double cy,
  double cw,
  double ch,
) {
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
  pts.sort((x, y) => (x.$1 + x.$2 + x.$3) - (y.$1 + y.$2 + y.$3));
  return pts[pts.length ~/ 2];
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
  RestoreStage _stage = RestoreStage.pick;
  Uint8List? _bytes;

  ///< 原图字节
  img.Image? _image;

  ///< 解码后的原图

  // ========== 色卡 ==========
  BeadPalette _palette = const BeadPalette([]);

  // ========== 图例（步骤 1/2） ==========
  Rect? _legendSel;

  ///< 图例选区（显示坐标）
  final _legendColsCtrl = TextEditingController();
  final _legendRowsCtrl = TextEditingController();
  var _legendBusy = false;
  String? _legendProgLabel;

  ///< 图例识别阶段文案（null=未开始/无细粒度阶段），进度条配套
  int _legendProgDone = 0;
  int _legendProgTotal = 0;

  var _autoDetectBusy = false;

  ///< 自动框选（图例区/主体）isolate 检测进行中——body 整体 UI 锁之一
  int _busyGen = 0;

  ///< 忙操作代号（generation）：每次新链路启动 ++，用户终止也 ++。
  ///< 链路各检查点比对「启动时快照 != 当前值」即知已被终止（结果丢弃，
  ///< 只收自己的锁）。isolate 单元无法强杀，终止 = UI 立即解锁 + 后台
  ///< 链路在下个检查点（进度回调/await 返回）自停，避免双链路并发跑
  ///< 大图 OCR 的内存峰值
  bool _busyCancelled = false;

  ///< 最近一次忙操作是被用户终止的（启动新链路时清；终止路径不发
  ///< 「未识别到主体区」之类的误导提示）
  List<LegendEntry> _legend = [];

  ///< 识别出的图例清单
  var _legendByOcr = false;

  ///< true=清单来自印刷色号（行列输入隐藏，网格层不画）
  var _panelExpanded = true;

  ///< 图例确认面板展开（收起后图片区变大，便于对照原图校对）
  var _legendSort = LegendSort.code;

  ///< 清单校对排序（仅展示视图，_legend 本身始终保持识别阅读序）
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
  Size _stageViewSize = Size.zero;

  ///< 图区视口尺寸速记（_imageStage 内 LayoutBuilder 赋值）——缩放
  ///< 按钮外置后不在画布 Stack 内，探取失效，须显式传给 ZoomControls

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

  ///< 主识别进度（已确认格数/总格数，识别锁遮罩进度条用）：总格数起跑
  ///< 定格，已确认=两遍文本判据的权威命中数（色彩回退收尾瞬间补满）。
  ///< _recognTotal=0 时不显示百分比（其他遮罩场景）
  int _recognTotal = 0;
  int _recognDone = 0;

  ///< 耗时识别期整体 UI 锁：图例识别(_legendBusy)/格距检测(_detecting)/
  ///< 主体自动框选(_autoDetectBusy)/主识别(_recognizing) 任一进行中
  ///< =true——body 整体 AbsorbPointer+遮罩。识别全用起跑时的快照（选区/
  ///< 格距/色卡），完成后无条件写结果，识别中途重框选/调格距/切模式
  ///< 全是白调且状态与结果脱节，一律锁死等完成（用户 2026-11-06 定）。
  ///< AppBar 导航不锁（返回上一步/退出已有各自守卫提示）
  bool get _stageBusy =>
      _legendBusy || _detecting || _recognizing || _autoDetectBusy || _decoding;

  ///< UI 锁遮罩文案（按耗时量级排优先级：主识别最长放最前），未锁 null。
  ///< _decoding（选图页读字节+解码）只在 pick 阶段为真，与其余四锁互斥
  String? get _stageBusyLabel {
    if (_recognizing) {
      if (_recognTotal > 0) {
        final pct = (_recognDone * 100 / _recognTotal).round();
        return "正在识别，已确认 $_recognDone/$_recognTotal 格（$pct%）";
      }
      return "正在识别，请稍候…";
    }
    if (_legendBusy) {
      if (_legendProgLabel != null) {
        return _legendProgTotal > 0
            ? "正在识别图例：$_legendProgLabel $_legendProgDone/$_legendProgTotal"
            : "正在识别图例：$_legendProgLabel";
      }
      return "正在识别图例，请稍候…";
    }
    if (_detecting) {
      return "正在检测格距，请稍候…";
    }
    if (_autoDetectBusy) {
      return "正在自动框选，请稍候…";
    }
    if (_decoding) {
      return "正在导入图片，请稍候…";
    }
    return null;
  }

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
  int _reviewCrossCount = 6;

  ///< 复核截图墙每行列数（用户可调，跨阶段往返保持）
  double _alignStep = 0.01;

  ///< 九宫格微调步长档位（0.01/0.05/0.1/0.5/1 图片像素，
  /// 格子大小与上下左右微移共用；默认最细档）

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
  List<double> _cellScores = const [];

  ///< 各格识别置信度 0-1（与 grid 同序；复核截图墙按低分优先排序）

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

  Size? _lastMediaSize;

  ///< 上次媒体尺寸（didChangeDependencies 旋转/分屏检测对比用）

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sz = MediaQuery.sizeOf(context);
    final last = _lastMediaSize;
    _lastMediaSize = sz;
    if (last == null || _image == null || last == sz) {
      return;
    }
    // 屏幕尺寸变化（旋转/分屏/窗口拖拽）：显示坐标系整体按新旧显示宽度的比例重标定
    // （紧凑档 = 屏宽-24 之比；展开档 = 装入图区视口后的显示宽之比，平板竖屏转横屏
    // 会跳档）。存量四角/选区/锚点都是「图上的位置」，等比缩放后语
    // 义不变；直接沿用旧坐标在宽变窄时会落到新图界外——图外手圆被
    // ClipRect 裁剪 + 平移夹限双重锁死不可点（与换图残留同症状）
    final image = _image!;
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    double displayW(Size window) => restoreDisplaySize(
          window: window,
          topPadding: top,
          bottomInset: bottom,
          imageWidth: image.width,
          imageHeight: image.height,
        ).width;
    final f = displayW(sz) / displayW(last);
    Rect scaleRect(Rect r) =>
        Rect.fromLTRB(r.left * f, r.top * f, r.right * f, r.bottom * f);
    setState(() {
      if (_cornerPts != null) {
        _cornerPts = [
          for (final p in _cornerPts!) Offset(p.dx * f, p.dy * f),
        ];
      }
      _miniAnchor = _miniAnchor != null ? _miniAnchor! * f : null;
      _legendSel = _legendSel != null ? scaleRect(_legendSel!) : null;
      _selDisplay = _selDisplay != null ? scaleRect(_selDisplay!) : null;
    });
  }

  /// 加载选中色卡
  Future<void> _initPalette() async {
    final selected = await PaletteRegistry.loadSelected();
    if (!mounted) {
      return;
    }
    setState(() {
      _palette = selected.palette;
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
    // 选定即上 UI 锁（读字节+解码期间选图页此前无任何反馈，用户会连点
    // 重选/误开链接面板——2026-11-09 用户反馈）；_loadImageBytes 内部的
    // 置位/清位照旧兜底，这里只把锁提前到 readAsBytes
    _busyGen++;
    _busyCancelled = false;
    final gen = _busyGen;
    setState(() => _decoding = true);
    Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (e) {
      if (mounted) {
        setState(() => _decoding = false);
        AppSnackBar.show(context, "读取图片失败: $e");
      }
      return;
    }
    if (gen != _busyGen) {
      return; // 读字节期间被终止：弃图不解锁（_confirmCancelBusy 已清锁）
    }
    await _loadImageBytes(bytes);
  }

  /// 载入图片字节（相册/拍照/小红书链接共用）：解码 + 清空下游全部状态 +
  /// 自动预框图例
  Future<void> _loadImageBytes(Uint8List bytes) async {
    try {
      _busyGen++;
      _busyCancelled = false;
      final gen = _busyGen;
      setState(() => _decoding = true);
      // 显示层统一走重编码 JPEG + 长边限幅（decodeForDisplay），识别/裁剪
      // 仍用 decoded 原始像素
      final (decoded, display) = await decodeForDisplay(bytes);
      if (!mounted) {
        return;
      }
      if (gen != _busyGen) {
        return; // 解码期间被终止：弃图（锁已由 _confirmCancelBusy 清）
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
        _pitchY = 0;
        // 换图清空全部下游步骤状态（导航模型：返回=读该步最后状态，前进
        // =按当前图重推导；上游图一换，下游存量全部作废）。四角是旧图的
        // 显示坐标，长宽比不同时新图上整组落在图界外——图外手圆被
        // ClipRect 裁剪 + 平移夹限双重锁死，永久不可点（实测卡死现场）
        _useCornerAlign = false;
        _cornerPts = null;
        _colsCtrl.clear();
        _rowsCtrl.clear();
        _legendColsCtrl.clear();
        _legendRowsCtrl.clear();
        _reviewColor = -2;
        _picked.clear();
        _model = null;
        _cellRects = const [];
        _cellScores = const [];
        _reviewSeenColors = {};
        _cellSrc?.dispose();
        _cellSrc = null;
        _decoding = false;
        // 换图重置图区变换（上一张图的缩放/平移不带到新图）
        _viewerCtrl.value = Matrix4.identity();
        _stage = RestoreStage.legend;
      });
      // 载入即自动预框图例区（省一次手动框选）；识别不到就保持空选区，
      // 用户手动框或点 AppBar「自动框选」重试。检测走 isolate（异步），
      // 期间用户换图则丢弃旧图结果；_autoDetectBusy 同步置位（body UI
      // 锁）——预框落定前手拖的框不会被检测结果覆盖，也不会双跑；
      // finally 收锁防 isolate 异常把 UI 永久锁死，检测失败按无预框走
      final loadedImage = decoded;
      Rect? auto;
      setState(() => _autoDetectBusy = true);
      try {
        auto = await _autoDetectLegend();
      } catch (_) {
        auto = null;
      } finally {
        if (mounted) {
          setState(() => _autoDetectBusy = false);
        }
      }
      if (!mounted || !identical(_image, loadedImage) || gen != _busyGen) {
        return; // 预框期间换图/被终止：检测结果丢弃
      }
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

  /// 图片实际显示尺寸
  ///
  /// 紧凑档：可用宽 = 屏宽 - 两侧 12 padding（图横向铺满，与布局公式一致）。
  /// 展开档（平板横屏/桌面，图区居左、面板靠右）：图区又宽又矮，按屏宽铺满会让竖版
  /// 图纸高出视口数倍（minScale=1 缩不回去，底部的图例带够不着）——改为
  /// 整图等比装入图区视口（宽高同时受限，整幅可见）。
  /// 两档都只由窗口尺寸决定、与面板展开/步骤切换无关：显示坐标系在一幅
  /// 图的生命周期内保持稳定，存量选区/锚点/四角不会因面板高度变化而错位
  Size _displaySize() => restoreDisplaySize(
        window: MediaQuery.sizeOf(context),
        topPadding: MediaQuery.paddingOf(context).top,
        bottomInset: MediaQuery.viewPaddingOf(context).bottom,
        imageWidth: _image!.width,
        imageHeight: _image!.height,
      );

  // ==================== 图例区自动检测 ====================

  /// 自动检测图例条带：游程法——实现抽在 lib/core/legend_detect.dart
  /// `detectLegendCanonical`（app 与 tool/legend_sim.dart 离线模拟器共用
  /// 同一份，消灭双端口径漂移；原理注释见该文件。canonical：主流截图宽
  /// [1000,2048] 直接 native 跑，窗外尺寸缩到 1440 宽检测再映射回原图）。
  /// 检测本体走 compute isolate（见 detectLegendInIsolate 头注释）。
  /// 返回显示坐标选区；找不到/中途卸载返回 null（调用方静默或提示手动框选）。
  Future<Rect?> _autoDetectLegend() async {
    final image = _image;
    if (image == null) {
      return null;
    }
    final r = await compute(detectLegendInIsolate, image);
    if (!mounted) {
      return null;
    }
    if (r == null) {
      return null;
    }
    // 原图 -> 显示坐标（上下 +10 余量与左右不加 pad 的理由见共享实现）
    final scale = _displaySize().width / image.width;
    return Rect.fromLTWH(
      r.left * scale,
      r.top * scale,
      (r.right - r.left) * scale,
      (r.bottom - r.top) * scale,
    );
  }

  /// 触发自动框选（按钮）：成功设选区并提示，失败提示手动框选。
  /// 检测全程置 _autoDetectBusy（body UI 锁）——期间手拖选框/再点
  /// 按钮都会被遮罩拦下，检测结果与用户改动不互相覆盖
  Future<void> _autoSelectLegend() async {
    final image = _image;
    if (image == null || _autoDetectBusy) {
      return;
    }
    if (_legendBusy) {
      // AppBar 魔法棒不被 body 遮罩拦，单独提示（图例识别用的是按下时
      // 的选区快照，中途自动框选改框是白调）
      if (mounted) {
        AppSnackBar.show(context, "图例识别进行中，请等待完成");
      }
      return;
    }
    setState(() => _autoDetectBusy = true);
    try {
      final rect = await _autoDetectLegend();
      if (!mounted) {
        return;
      }
      if (rect == null) {
        AppSnackBar.show(context, "未识别到图例区，请手动框选");
        return;
      }
      if (!identical(_image, image)) {
        return; // 检测期间换图：旧图结果不写新图
      }
      setState(() => _legendSel = rect);
      AppSnackBar.show(context, "已自动框选图例区，可拖动调整");
    } finally {
      if (mounted) {
        setState(() => _autoDetectBusy = false);
      }
    }
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
    // 实现抽在顶层 sampleCenterMedian（与 isolate 共用），语义注释见其
    // 调用方 scanLegendInIsolate 上文与 sampleCenterMedian 头注释
    return sampleCenterMedian(_image!, cx, cy, cw, ch);
  }

  // ==================== 步骤 1/2：图例识别 ====================

  /// 识别图例：框选区域自动检测行列 -> 逐格采样 -> 聚合用色清单
  void _scanLegend() {
    final image = _image;
    if (image == null || _legendBusy) {
      return; // 已在识别：body 遮罩拦了主入口，双保险防极端时序重入
    }
    _busyGen++;
    _busyCancelled = false;
    final gen = _busyGen;
    setState(() {
      _legendBusy = true;
      _legendProgLabel = null;
      _legendProgDone = 0;
      _legendProgTotal = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final (rx, ry, rw, rh) = _selToImage(_legendSel);
      // 灰度整扫 + 网格检测 + 逐格中值采样是整选区像素遍历（大框=整图，
      // 主线程同步跑曾实测冻结 0.7s+），与 OCR 链一并入 compute isolate
      // （scanLegendInIsolate），主线程只做编排与状态写入
      final prep = await compute(
        scanLegendInIsolate,
        ScanLegendArgs(image, _palette, rx, ry, rw, rh),
      );
      if (!mounted) {
        return;
      }
      if (!identical(_image, image) || gen != _busyGen) {
        setState(() => _legendBusy = false);
        return;
      }
      final det = prep.det;
      final freq = prep.freq;
      var cols = 8, rows = 1;
      if (det != null) {
        cols = det.cols;
        rows = det.rows;
      }
      // OCR 权威模式：印刷色号是图纸的权威声明。读到的色号直接构成清单
      // （宽松框选把图案区框进来时，杂色量化条目全部被剔净），颗数随配对填入；
      // 读不到（web/异常/配对太少）回退纯色块量化清单（现状行为，颗数手填）。
      final pairs = await _ocrLegendPairs(
        rx,
        ry,
        rw,
        rh,
        onProgress: (label, done, total) {
          if (gen != _busyGen) {
            // 用户终止：抛出沿 runLegendOcr 链冒泡（其 catch 吞成空结果），
            // 逐 gap 中断后台重活；调用侧 gen 检查丢弃整轮清单
            throw const BusyCancelled();
          }
          if (mounted) {
            setState(() {
              _legendProgLabel = label;
              _legendProgDone = done;
              _legendProgTotal = total;
            });
          }
        },
      );
      if (!mounted) {
        return;
      }
      if (!identical(_image, image) || gen != _busyGen) {
        // OCR 期间换图/被终止：旧图清单丢弃只解除识别态，
        // 不写入新图的图例状态
        setState(() => _legendBusy = false);
        return;
      }
      for (final e in _legend) {
        e.countCtrl.dispose();
      }
      var entries = [
        for (final entry
            in freq.entries.toList()..sort((a, b) => b.value - a.value))
          LegendEntry(entry.key),
      ];
      var ocrHit = 0;
      var countHit = 0;
      var dupDropped = 0;
      if (pairs != null && pairs.length >= 3) {
        // 同一色号多锚点（图例重复印刷/OCR 重复读出）：不能一律取首条——
        // 首条若是颗数 0 的锚点，会把后面带颗数的挤掉，清单整列变 0。
        // 优先保留带颗数的；都有颗数保首条。map 保插入序 = 阅读序
        final byIdx = <int, LegendEntry>{};
        for (final (idx, count) in pairs) {
          final old = byIdx[idx];
          if (old == null) {
            final e = LegendEntry(idx);
            e.countCtrl.text = count.toString();
            byIdx[idx] = e;
            continue;
          }
          dupDropped++;
          final oldCount = int.tryParse(old.countCtrl.text) ?? 0;
          if (oldCount == 0 && count > 0) {
            old.countCtrl.text = count.toString();
          }
        }
        final byOcr = [for (final idx in byIdx.keys) byIdx[idx]!];
        for (final e in entries) {
          e.countCtrl.dispose(); // fallback 条目被 OCR 清单取代
        }
        entries = byOcr;
        ocrHit = byOcr.length;
        countHit = byOcr
            .where((e) => (int.tryParse(e.countCtrl.text) ?? 0) > 0)
            .length;
      }
      setState(() {
        _legendBusy = false;
        _legendProgLabel = null;
        _legendProgTotal = 0;
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
          "已按图例印刷色号识别 $ocrHit 色，颗数自动读取 $countHit 条"
          "${ocrHit - countHit > 0 ? "（${ocrHit - countHit} 条颗数待手填）" : ""}"
          "${dupDropped > 0 ? "，重复色号 $dupDropped 条已合并" : ""}，请对照原图核对",
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
  /// 编排实现抽在 legend_ocr_runner.dart `runLegendOcr`（放大/识别/修复/
  /// 配对/调试快照整链）。web 平台不可用 / 异常 / 无配对时返回 null
  /// （调用方回退色块量化清单）。
  Future<List<(int, int)>?> _ocrLegendPairs(
    double rx,
    double ry,
    double rw,
    double rh, {
    String source = "手动框选",
    void Function(String label, int done, int total)? onProgress,
  }) async {
    if (kIsWeb) {
      return null;
    }
    final image = _image;
    if (image == null) {
      return null;
    }
    final run = await runLegendOcr(
      image,
      _palette,
      rx,
      ry,
      rw,
      rh,
      source: source,
      onProgress: onProgress,
    );
    // 色卡外色号（如 MARD 卡没有的 H7）：无法入清单，明确提示用户手工补
    if (run.orphanNotes.isNotEmpty && mounted) {
      final names = run.orphanNotes.toSet().join("、");
      AppSnackBar.show(
        context,
        "识别到色卡外色号：$names（不在当前色卡，未入清单；如有需要请用\"添加颜色\"手工补）",
      );
    }
    return run.pairs;
  }

  /// 弹色卡选色器（修正图例色号 / 添加颜色 / 复核归类共用；弹窗本体
  /// 已抽到 palette_picker.dart 与编辑器共用，语义注释见彼处）
  Future<int?> _pickColorIndex({
    Set<int>? allowed,
    bool withBlank = false,
    String title = "选择色号",
  }) {
    return showPaletteColorPicker(
      context,
      palette: _palette,
      allowed: allowed,
      withBlank: withBlank,
      title: title,
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
    setState(() => _legend.add(LegendEntry(idx)));
  }

  /// 从图例清单删除条目（先释放控制器再移除，防二次 dispose）
  void _removeLegendEntry(LegendEntry entry) {
    setState(() {
      entry.countCtrl.dispose();
      _legend.remove(entry);
    });
  }

  /// 修正图例条目色号（若目标色已有条目则合并格数后删除本条）
  Future<void> _changeLegendColor(LegendEntry entry) async {
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
      _legend[_legend.indexOf(entry)] = LegendEntry(idx);
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
    _busyGen++;
    _busyCancelled = false;
    final gen = _busyGen;
    setState(() => _detecting = true);
    // postFrameCallback 让 _detecting 提示先渲染一帧再起 isolate
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return;
    }
    final det = await compute(detectGridInIsolate, image);
    if (!mounted) {
      return;
    }
    if (!identical(_image, image) || gen != _busyGen) {
      // 检测期间换图/被终止（isolate 跑着时经返回键回选图步重选）：旧图
      // 结果丢弃只解除检测态——_detecting 卡 true 会拦住新图的检测入口
      setState(() => _detecting = false);
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
        // 兜底默认：图宽/20，Y 取同值（方形格先验）——按高独立取
        // image.height/20 时非方形照片的默认格天生就是长方形（4:3 图
        // 出 4:3 格），标定起点就歪
        _pitchX = image.width / 20;
        _pitchY = _pitchX;
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

  /// 格子大小 ±（步长档位图片像素，X/Y 等比缩放，网格锚点不动）
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

  /// 微移九宫格（[dx]/[dy] 带符号图片像素步长，面板传 ±步长档位；
  /// 显示坐标换算）
  void _nudge(double dx, double dy) {
    final anchor = _miniAnchor;
    if (_pitchX <= 0 || _pitchY <= 0 || anchor == null) {
      return;
    }
    final ds = _displaySize();
    final image = _image!;
    setState(() {
      _miniAnchor = Offset(
        anchor.dx + dx * ds.width / image.width,
        anchor.dy + dy * ds.height / image.height,
      );
    });
  }

  /// 画布缩放按钮条：放大/缩小（以画面中心为锚）+ 还原全幅，横排外置
  /// 在图区与底部操作区之间——不悬浮在图上（会挡选区把手与图像内容）。
  /// 所有可缩放画布统一入口（手势缩放可发现性差，屏幕上要有显式按钮）。
  /// [viewport]：真实视口尺寸提供者（aspect-fit 画布=内容尺寸；铺满型
  /// 图区=_imageStage 速记的约束），锚点/平移夹限按它算
  Widget _zoomStrip(
    TransformationController ctrl,
    Size Function() contentSize, {
    double maxScale = kPhotoMaxZoom,
    Size Function()? viewport,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: ZoomControls(
          controller: ctrl,
          contentSize: contentSize,
          viewportSize: viewport ?? contentSize,
          maxScale: maxScale,
        ),
      ),
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

  /// 默认四角：近全图四角、四周内收 5%——角点正贴图边时把手圆一半在
  /// 图外（图边又常贴屏缘），手指按不到圆上；拼豆图案也几乎不顶满
  /// 图边，内收反而更接近真实图案边界
  List<Offset> _defaultCorners() {
    final ds = _displaySize();
    final mx = ds.width * 0.05, my = ds.height * 0.05;
    return [
      Offset(mx, my),
      Offset(ds.width - mx, my),
      Offset(ds.width - mx, ds.height - my),
      Offset(mx, ds.height - my),
    ];
  }

  /// 重置四角回默认位置
  void _resetCorners() {
    setState(() => _cornerPts = _defaultCorners());
  }

  /// 拖角更新（_imageStage 手势回调，p 为显示坐标）。四角恒钳制为
  /// 轴对齐矩形：对角固定、拖动点与其张成矩形，两邻角自动吸附到
  /// 新边——任意拖拽都拉不出梯形（矩形下双线性映射退化为仿射，
  /// 覆盖层网格与采样同源，不受影响）。拖动点先钳回图内，四角
  /// 不越出采样域
  void _onCornerDrag(int idx, Offset p) {
    if (_cornerPts == null || idx < 0 || idx >= 4) {
      return;
    }
    final ds = _displaySize();
    final q = Offset(
      p.dx.clamp(0.0, ds.width),
      p.dy.clamp(0.0, ds.height),
    );
    final rect = Rect.fromPoints(q, _cornerPts![(idx + 2) % 4]);
    setState(() {
      _cornerPts = [
        rect.topLeft,
        rect.topRight,
        rect.bottomRight,
        rect.bottomLeft,
      ];
    });
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
    if (image == null || _recognizing) {
      return; // 已在识别：body 遮罩拦了主入口，双保险防极端时序重入
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
    _busyGen++;
    _busyCancelled = false;
    final gen = _busyGen;
    setState(() {
      _recognizing = true;
      _recognTotal = cols * rows;
      _recognDone = 0;
    });
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
            final tl = bilinearQuad(qImg, c / cols, r / rows);
            final br = bilinearQuad(qImg, (c + 1) / cols, (r + 1) / rows);
            centers.add(
              bilinearQuad(qImg, (c + 0.5) / cols, (r + 0.5) / rows),
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
      final codeMap = buildCodeMap(_palette);
      final quantizer = Quantizer(_palette);
      final grid = List<int>.filled(cols * rows, 0);
      // 逐格识别置信度（复核截图墙排序用）：OCR 命中=1（印刷色号权威）；
      // 颜色采样按 Lab 距离线性折算（0=空白阈值处，1=正中色心）；直判
      // 空白=0。分数越低越可疑，截图墙按升序排——最可能认错的格先看
      final scores = List<double>.filled(cols * rows, 1.0);
      // 一遍：整图 OCR 分带识别（ocrCells 按 ~350px 切 2-8 带逐带识别），
      // 元素按几何归类回格；印刷色号是图纸的权威声明，命中候选色号的格
      // 直接采用。每带识别完回调一次：解析命中 + 进度上报（单张大图一次
      // processImage 中途零事件，0→72% 一跳突兀，用户 2026-11-06 定）
      final authoritative = List<bool>.filled(cols * rows, false);
      final txtByCell = <int, String>{};
      var ocrHit = 0;
      void resolveBand(Map<int, String> band) {
        if (gen != _busyGen) {
          throw const BusyCancelled(); // 用户终止：中断分带循环
        }
        if (!mounted) {
          return;
        }
        setState(() {
          band.forEach((i, txt) {
            txtByCell[i] = txt;
            final hit = codeMap[txt];
            if (hit != null &&
                (candidates.isEmpty || candidates.contains(hit))) {
              if (!authoritative[i]) {
                authoritative[i] = true;
                grid[i] = hit;
                ocrHit++;
              }
            }
          });
          _recognDone = ocrHit;
        });
      }

      try {
        await ocrCells(
          image,
          cellRects,
          centers,
          Offset(rx + offX, ry + offY),
          cols,
          rows,
          useCorner,
          pitchX,
          pitchY,
          onBand: resolveBand,
        );
      } on BusyCancelled {
        if (mounted) {
          setState(() {
            _recognizing = false;
            _recognTotal = 0;
            _recognDone = 0;
          });
        }
        return;
      }
      // 二遍逐格补读（文本第一判据，2026-11-06 用户反馈）：一遍整图 OCR
      // 没读到色号≠格内没有文本——字小/压格线/全局放大倍率不够都会漏，
      // 此前这些格直接落色彩回退（候选含近白时白底成片吸 H2 的根因即
      // 此）。逐格裁剪放大拼瓦分批补读：一次 processImage 读一批瓦（逐格
      // 单图调用要数秒×格数，见 ocrCells 头注），每批回调即时上报进度；
      // 瓦内仍读不到的才落色彩回退。格距错得离谱（未权威格 >900）时整轮
      // 跳过——批量大且结果多半无意义
      var pass2Done = 0;
      final retryIdx = <int>[
        for (var i = 0; i < grid.length; i++)
          if (!authoritative[i]) i,
      ];
      if (retryIdx.length <= 900) {
        try {
          await ocrCellsSecondPass(
            image,
            [for (final i in retryIdx) cellRects[i]],
            onBatch: (start, count, batch) {
              if (gen != _busyGen) {
                throw const BusyCancelled(); // 用户终止：中断补读批次
              }
              if (!mounted) {
                return;
              }
              setState(() {
                batch.forEach((k, txt) {
                  final i = retryIdx[start + k];
                  if (txt.isEmpty) {
                    return;
                  }
                  txtByCell[i] = txt;
                  final hit = codeMap[txt];
                  if (hit != null &&
                      (candidates.isEmpty || candidates.contains(hit))) {
                    if (!authoritative[i]) {
                      authoritative[i] = true;
                      grid[i] = hit;
                    }
                  }
                });
                // 本批瓦全部出最终判据（文本命中，或文本阶段终结→色彩回退
                // 在收尾循环定型）——进度按已确认格数计，每批稳步推进
                pass2Done += count;
                _recognDone = ocrHit + pass2Done;
              });
            },
          );
        } on BusyCancelled {
          if (mounted) {
            setState(() {
              _recognizing = false;
              _recognTotal = 0;
              _recognDone = 0;
            });
          }
          return;
        }
      }
      // 色彩回退：两遍文本都没给出候选色号的格。textless 判据用两遍合并
      // 结果——两遍都没读到文本=真·无字
      for (var i = 0; i < grid.length; i++) {
        if (authoritative[i]) {
          continue;
        }
        final txt = txtByCell[i];
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
        // E11 478→171 与基线零差）。
        // 文本第一判据（2026-11-06 用户反馈）：候选含近白色时旧逻辑整段
        // 跳过近白直判，图案区外白底全被 Lab 最近色吸成该近白色——H2=
        // (251,248,251) 与白纸底 distSq 极小，空白格成片虚涨成 H2，全要
        // 手工清。改为「格内无任何色号文本」的近白格仍直判空白：白豆格
        // 的色号是深墨印在近白底上=全图对比度最好的 OCR 情形，读到即走
        // 上方权威路径保色；有文字痕迹（读残的部分色号）的格保守沿用
        // 旧路径（2026-09-08 白豆误灭回归保护不撤，只补无文本白底漏洞）
        final textless = txt == null;
        final nearWhite = sr > 230 &&
            sg > 230 &&
            sb > 230 &&
            (math.max(sr, math.max(sg, sb)) - math.min(sr, math.min(sg, sb))) <
                25;
        if (_blankEnable && nearWhite && (!candNearWhite || textless)) {
          grid[i] = -1;
          scores[i] = 0;
        } else {
          final (idx, distSq) = quantizer.nearestWithin(
            sr,
            sg,
            sb,
            candidates.isEmpty ? null : candidates,
          );
          final blank = _blankEnable && distSq > _blankDistSq;
          grid[i] = blank ? -1 : idx;
          scores[i] = blank ? 0 : (1.0 - distSq / _blankDistSq).clamp(0.0, 1.0);
        }
      }
      if (!mounted) {
        return;
      }
      if (gen != _busyGen) {
        // 终止确认发生在最后一刻（回调检查全过）：结果仍丢弃
        setState(() {
          _recognizing = false;
          _recognTotal = 0;
          _recognDone = 0;
        });
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
        _cellScores = scores;
        _recognizing = false;
        _recognTotal = 0;
        _recognDone = 0;
        _reviewColor = -2;
        _picked.clear();
        // 出现色快照定格：归类候选不随后续归类动态缩水（见字段注释）
        _reviewSeenColors = {
          for (var i = 0; i < grid.length; i++)
            if (grid[i] >= 0) grid[i],
        };
        _stage = RestoreStage.review;
      });
      // 复核截图数据源异步解码，不阻塞进复核页（_displayBytes 是长边
      // 限幅显示版，原图直解码会超 GLES 2048 纹理上限）
      _loadCellSrc();
    });
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
        builder: (_) => EditorPage(
          model: model,
          palette: _palette,
          sortMode: _legendSort.name,
        ),
      ),
    );
  }

  /// 保存作品：命名 -> 存作品库 -> 二选一（回主页 / 进我的作品看新作品）
  Future<void> _saveWork() async {
    final model = _model;
    if (model == null) {
      return;
    }
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, "0");
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
    await DraftStore.saveWork(
      model,
      name: name.trim(),
      sortMode: _legendSort.name,
    );
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
            onPressed: () => Navigator.pop(dctx, "works"),
            child: const Text("进入我的作品"),
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
    // 确认即直达作品库：新作品按更新时间置顶可见。pushReplacement
    // 还原页出栈，作品页 back 直达主页，不回到已结束的还原现场
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => WorksPage(palette: _palette)),
    );
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

  /// 反选当前复核色：该色未选中的选中、已选中的取消（配合"全选"做
  /// 减法——先全选再点掉少数几个，不如全选+反选少数几个灵活）
  void _invertPickOfCurrent() {
    final model = _model;
    if (model == null || _reviewColor == -2) {
      return;
    }
    setState(() {
      for (var i = 0; i < model.grid.length; i++) {
        if (model.grid[i] == _reviewColor) {
          _picked.contains(i) ? _picked.remove(i) : _picked.add(i);
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
        // 手工归类是用户断言：置信度置顶，截图墙不再当可疑项置前
        if (i < _cellScores.length) {
          _cellScores[i] = 1;
        }
      }
      _picked.clear();
    });
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
    setState(() => _stage = RestoreStage.align);
    if (_miniAnchor == null) {
      _initMiniGrid();
    }
  }

  /// 进入「框选主体」阶段（九宫格已定每格尺寸，本步只框主体区域；
  /// 行列数 = 选区/格距 实时算，识别时直接采用）。已有选区按当前格距
  /// 重新吸附（回九宫格调过格子大小再进来，旧框立即归位整格）；无选区
  /// 先自动框选主体（与载入图自动预框图例同范式——排图例带后找豆行豆列
  /// 密集区，省一次手动拖框）。进入时自动全图化（还原全幅）：上一步
  /// 标定常放大到局部核对格线，带着放大视角进框选步会只看见图一角，
  /// 主体不在视野里、用户不知道这步要框什么
  Future<void> _goFrame() async {
    Rect? auto;
    if (_selDisplay == null) {
      auto = await _autoDetectSubject();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _stage = RestoreStage.frame;
      final sel = _selDisplay;
      if (sel != null) {
        _selDisplay = _snapSelToGrid(sel);
      } else if (auto != null) {
        _selDisplay = auto;
      }
    });
    _viewerCtrl.value = Matrix4.identity();
    if (auto != null) {
      AppSnackBar.show(context, "已自动框选主体，可拖动调整");
    }
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
    final prev = _stage == RestoreStage.review && _useCornerAlign
        ? RestoreStage.align
        : RestoreStage.values[_stage.index - 1];
    final prevName = switch (prev) {
      RestoreStage.pick => "选图",
      RestoreStage.legend => "① 框图例",
      RestoreStage.align => "② 九宫格对齐",
      RestoreStage.frame => "③ 框选主体",
      RestoreStage.review => "④ 识别复核",
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
    // 回框选步同样全图化（与 _goFrame 同理由：带着别步的放大视角
    // 进框选，主体不在视野里）
    if (prev == RestoreStage.frame) {
      _viewerCtrl.value = Matrix4.identity();
    }
  }

  /// 完全退出图纸还原确认：整个还原页出栈——选的图/图例清单/九宫格标定/
  /// 识别结果全部丢弃。与逐级「返回上一步」相对（那个保现场），AppBar
  /// 右上角 ✕ 入口（用户 2026-09-11 定稿：左上=上一步，右上=完全退出）
  Future<void> _confirmExitRestore() async {
    if (_recognizing) {
      // 与 _confirmBack 同款守卫：识别完成回调会无条件写结果并跳复核，
      // 识别中退出是白跑且用户会被强行拽回（mounted 守卫吞掉 setState）
      AppSnackBar.show(context, "识别进行中，请等待完成");
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text("退出图纸还原？"),
        content: const Text("整个页面将关闭，已选的图、图例清单、九宫格标定、识别结果全部丢失"),
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
    if (ok != true || !mounted) {
      return;
    }
    // pop() 直接退出整页：无条件 pop，不查询 PopScope 的 canPop（maybePop
    // 才会查询被拦截）——_saveWork「回到主页」分支同款既有范式
    Navigator.of(context).pop();
  }

  // ==================== 布局 ====================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 选图步（第一步）back 直接退出；中间步骤先确认返回上一步
      canPop: _stage == RestoreStage.pick,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _confirmBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          // 双返回入口（2026-09-11 用户定稿，取代此前「唯一箭头」方案）：
          // 左上角=返回上一步（弹确认、已调内容全保留）；右上角 ✕=完全
          // 退出图纸还原（弹确认后整页出栈）。系统自动 leading Back 关掉
          // 由自己的 leading 接管，系统 back 手势仍走 PopScope 同款确认
          automaticallyImplyLeading: false,
          // 选图步（第一步）也常驻返回箭头：无手势条/无返回键的全面屏机
          // 在第一步此前无路可退（2026-11-09 用户反馈）。选图步没有任何
          // 已调内容，直接出栈不弹确认；其余步骤仍是「返回上一步」弹确认
          leading: IconButton(
            onPressed: _stage == RestoreStage.pick
                ? () => Navigator.of(context).pop()
                : _confirmBack,
            icon: const Icon(Icons.arrow_back),
            tooltip: _stage == RestoreStage.pick ? "返回主页" : "返回上一步",
          ),
          // 标题接 AdaptiveTitleText（2026-11-18 用户反馈：①②③步的步骤名
          // 被 leading + 右侧 2~3 个图标挤压截断出省略号）——先缩字号完整
          // 显示，缩不下限才省略号；与编辑器/拼豆页等 AppBar 同款处理
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AdaptiveTitleText(switch (_stage) {
                RestoreStage.pick => "图纸还原 · 选图",
                RestoreStage.legend => "图纸还原 · ① 框图例",
                RestoreStage.align => "图纸还原 · ② 九宫格对齐",
                RestoreStage.frame => "图纸还原 · ③ 框选主体",
                RestoreStage.review => "图纸还原 · ④ 识别复核",
              }),
              Text(
                "构建 $appBuildLabel",
                style: const TextStyle(fontSize: 10, color: Colors.black38),
              ),
            ],
          ),
          actions: [
            // 2026-11-18 用户定稿：AppBar 只留右上 ✕。自动框选魔法棒（①页
            // 底部已有同功能按钮）与切换色卡图标按用户要求移除，色卡切换
            // 功能随入口移除（PaletteRegistry 仍按全局选中色卡加载）
            // 完全退出图纸还原：右上角 ✕（弹确认后整页出栈，与左上角
            // 「返回上一步」相对——一个保现场逐级退、一个整页丢弃退）
            if (_stage != RestoreStage.pick)
              IconButton(
                onPressed: _confirmExitRestore,
                icon: const Icon(Icons.close),
                tooltip: "退出图纸还原",
              ),
          ],
        ),
        body: _busyBarrier(
          switch (_stage) {
            RestoreStage.pick => _buildPick(),
            RestoreStage.legend => _buildLegend(),
            RestoreStage.align => _buildAlign(),
            RestoreStage.frame => _buildFrame(),
            RestoreStage.review => _buildReview(),
          },
        ),
      ),
    );
  }

  /// 耗时识别期 UI 锁遮罩（见 _stageBusy 字段注释）：整个步骤面板连同
  /// 图区一起 AbsorbPointer + 半透明黑遮罩——重框选/挪九宫格/调参/连点
  /// 按钮全部锁死，图与面板仍透出可见（用户知道锁的是哪一步在跑）。
  /// 各步骤按钮里的「识别中…」spinner 留着不动：遮罩是半透明的，双
  /// 反馈不冲突
  Widget _busyBarrier(Widget child) {
    final label = _stageBusyLabel;
    if (label == null) {
      return child;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        AbsorbPointer(absorbing: true, child: child),
        ColoredBox(
          color: Colors.black38,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                if (_recognizing && _recognTotal > 0) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 220,
                    child: LinearProgressIndicator(
                      value: _recognDone / _recognTotal,
                      minHeight: 6,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ],
                if (_legendBusy && _legendProgTotal > 0) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 220,
                    child: LinearProgressIndicator(
                      value: _legendProgDone / _legendProgTotal,
                      minHeight: 6,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                TextButton(
                  onPressed: _confirmCancelBusy,
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 26,
                      vertical: 8,
                    ),
                    minimumSize: const Size(0, 38),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(19),
                    ),
                  ),
                  child: const Text(
                    "终 止",
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 终止当前忙操作（遮罩上「终止」钮）：确认后作废旧链路（_busyGen++）
  /// 并立即清全部忙锁解锁 UI——isolate 单元无法强杀，后台链路在下个
  /// 检查点自停（见 _busyGen 注释），其收尾 setState 幂等无害
  Future<void> _confirmCancelBusy() async {
    final wasLegend = _legendBusy; // 快照：仅终止图例识别时清清单
    final ok = await showDialog<bool>(
      context: context,
      // 弹窗挂着期间操作可能自然跑完（识别比读弹窗+点按快）：弹窗内
      // 轮询 busy 态自动关闭，确认钮返回值一律 true——「还终止吗」的
      // 判定延到弹窗关闭后复查 _stageBusy，不做点按瞬间求值（此前
      // pop(!_stageBusy) 在点按帧求值，撞上完成帧会静默弹窗、结果照出，
      // 用户看着就像「选了终止却依旧在跑」）
      builder: (ctx) => _CancelBusyDialog(isBusy: () => _stageBusy),
    );
    if (ok != true || !mounted) {
      return;
    }
    if (!_stageBusy) {
      // 弹窗挂着期间操作已完成：结果已正常写入，终止无事可做
      AppSnackBar.show(context, "操作已完成，无需终止");
      return;
    }
    setState(() {
      _busyGen++;
      _busyCancelled = true;
      _decoding = false;
      _legendBusy = false;
      _detecting = false;
      _recognizing = false;
      _autoDetectBusy = false;
      _legendProgLabel = null;
      _legendProgDone = 0;
      _legendProgTotal = 0;
      _recognTotal = 0;
      _recognDone = 0;
      // 终止=进度彻底清零（2026-11-09 用户反馈）：终止图例识别时页面
      // 上残留的识别清单（含本次识别前就在的旧结果）一并清掉——页面
      // 回到未识别的干净状态，不留「进度还在」的表象；被终止链路的
      // 丢弃分支只收自己的锁不再碰 _legend，不会二次 dispose。终止
      // 其他链路（格距检测/主体框选等）不动清单——那是另一步的成果
      if (wasLegend && _legend.isNotEmpty) {
        for (final e in _legend) {
          e.countCtrl.dispose();
        }
        _legend = [];
        _legendByOcr = false;
        _legendColsCtrl.clear();
        _legendRowsCtrl.clear();
      }
    });
  }

  /// 阶段一：选图入口（面板实现在 steps/pick_step.dart）
  Widget _buildPick() {
    return PickStep(onPick: _pickImage, onLinkBytes: _loadImageBytes);
  }

  /// 命中选区把手（返回 0-7 索引，未命中返回 -1）
  ///
  /// 布局：0─1─2 / 3   4 / 5─6─7（四角 + 四边中点），命中半径按手指友好的
  /// 22px（随视图缩放补偿：除以 scale 后视觉命中区恒定——放大后 22 内容
  /// px 会变成 22×scale 屏幕px 的巨屏误触区，框中心拖动反被把手抢走）；
  /// 扁框（图例条带）按短边 1/3 收缩——否则半径 22 超过框高一半，
  /// 框中心拖动会误命中上/下边中把手，整框平移永远触发不了
  int _hitSelHandle(Rect sel, Offset p) {
    final scale = _viewerCtrl.value.storage[0];
    final radius = math.min(22.0, math.min(sel.width, sel.height) / 3) / scale;
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
          builder: (ctx, cons) {
            // 速记图区视口尺寸（无 setState，build 期间赋值）——缩放
            // 按钮已外置出画布 Stack，边界计算须显式传视口
            _stageViewSize = Size(cons.maxWidth, cons.maxHeight);
            return InteractiveViewer(
              maxScale: kPhotoMaxZoom,
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
                  final ctx = StageCtx(onSel, sel, cornerPts, onCornerDrag,
                      cons, miniAnchor, onMiniAnchor, panFallback);
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
                      // Align 在 IV(constrained:false) 的无界约束下会收缩成子尺寸、对齐失效：
                      // 先用视口尺寸的 SizedBox 把约束变有界再居中。展开档整图
                      // 装入后横向居中（不再贴左边留一大块空白）；手机上图宽
                      // =视口宽、垂直仍顶部对齐，逐像素不变
                      child: SizedBox(
                        width: cons.maxWidth,
                        height: cons.maxHeight,
                        child: Align(
                          alignment: Alignment.topCenter,
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
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              if (sel != null && sel.width > 2)
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: SelPainter(sel, ctrl: _viewerCtrl),
                                  ),
                                ),
                              if (overlay != null)
                                Positioned.fill(
                                  child:
                                      CustomPaint(painter: overlay, size: ds),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
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

  /// 图区指针按下：单指按拖动模式分派（把手/挪框/平移画面/画框兜底/
  /// 角点校正），第二指落下转捏合缩放（作废单指手势+恢复快照+记起始）
  void _onStagePointerDown(PointerDownEvent e, StageCtx ctx) {
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
    // 四角把手优先（角点校正模式）：命中则进入拖角。命中半径随视图
    // 缩放补偿（同 _hitMiniGrid）：放大后命中区视觉恒定，不会变成
    // 巨屏误触区抢走平移手势
    if (ctx.cornerPts != null) {
      _cornerDragIdx = -1;
      final hitR = 30 / _viewerCtrl.value.storage[0];
      for (var i = 0; i < ctx.cornerPts!.length; i++) {
        if ((ctx.cornerPts![i] - e.localPosition).distance <= hitR) {
          _cornerDragIdx = i;
          ctx.onCornerDrag?.call(i, e.localPosition);
          return;
        }
      }
      // 非角区拖动=平移画面（不画框：防误触清掉四角）——放大后要能
      // 挪图看其他角，与九宫格/框选步的框外拖动行为一致
      _panViewMode = true;
      return;
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
  void _onStagePointerMove(PointerMoveEvent e, StageCtx ctx) {
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
    if (_panViewMode) {
      _panViewBy(e.delta, ctx.cons);
      return;
    }
    if (ctx.cornerPts != null) {
      return; // 四角模式：非角区拖动已在按下时转平移，到这里不处理
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
      // span 闸门只是防 0 附近抖动，用显示坐标小值即可——曾用 24 显示
      // px：span 是显示坐标而 3×3 框宽随图片宽度缩放（1428 宽图在 384
      // 屏上格距 31 时框仅 ~25px），24px 闸门把格距下限抬到 ~30 图片
      // px，缩小拖到这就「卡死下不去」。真实下限由 px>=2（图片像素，
      // 与 ± 按钮同口径）把守
      if (span > 4 && _miniScaleBaseSpan > 1) {
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
  void _onStagePointerUp(PointerUpEvent e, StageCtx ctx) {
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
  void _onStagePointerCancel(PointerCancelEvent e, StageCtx ctx) {
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
      return CornerGridPainter(
        pts: pts,
        cols: cols,
        rows: rows,
        ctrl: _viewerCtrl,
      );
    }
    final anchor = _miniAnchor;
    if (anchor == null || _pitchX <= 0 || _pitchY <= 0) {
      return null;
    }
    final ds = _displaySize();
    final image = _image!;
    return MiniGridPainter(
      grid: Rect.fromLTWH(
        anchor.dx,
        anchor.dy,
        3 * _pitchX * ds.width / image.width,
        3 * _pitchY * ds.height / image.height,
      ),
      ctrl: _viewerCtrl,
    );
  }

  /// 图例网格覆盖层（按图例行列均分）
  GridOverlayPainter? _legendOverlay() {
    final cols = int.tryParse(_legendColsCtrl.text) ?? 0;
    final rows = int.tryParse(_legendRowsCtrl.text) ?? 0;
    if (cols < 1 || rows < 1) {
      return null;
    }
    final (rx, ry, rw, rh) = _selToImage(_legendSel);
    final ds = _displaySize();
    final image = _image!;
    return GridOverlayPainter(
      cols: cols,
      rows: rows,
      originDx: rx * ds.width / image.width,
      originDy: ry * ds.height / image.height,
      pitchDx: rw * ds.width / image.width / cols,
      pitchDy: rh * ds.height / image.height / rows,
    );
  }

  /// 阶段二：框选图例 + 识别 + 清单核对（面板实现在 steps/legend_step.dart）
  Widget _buildLegend() {
    return LegendStep(
      imageStage: _imageStage,
      zoomStrip: _zoomStrip,
      viewerCtrl: _viewerCtrl,
      displaySize: _displaySize,
      stageViewSize: () => _stageViewSize,
      legendSel: _legendSel,
      overlay: _legend.isNotEmpty && !_legendByOcr
          ? _legendOverlay()
          : null, // 网格层仅量化模式有参考意义
      onSel: (r) => setState(() => _legendSel = r),
      onClearSel: () => setState(() => _legendSel = null),
      legendBusy: _legendBusy,
      legendByOcr: _legendByOcr,
      panelExpanded: _panelExpanded,
      colsCtrl: _legendColsCtrl,
      rowsCtrl: _legendRowsCtrl,
      legend: _legend,
      legendSort: _legendSort,
      onSortChange: (s) => setState(() => _legendSort = s),
      palette: _palette,
      onAutoSelect: _autoSelectLegend,
      onScan: _scanLegend,
      onGoAlign: _goAlign,
      onTogglePanel: () => setState(() => _panelExpanded = !_panelExpanded),
      onAddColor: _addLegendColor,
      onChangeColor: _changeLegendColor,
      onRemoveEntry: _removeLegendEntry,
    );
  }

  /// 阶段②：九宫格标定每格大小（面板实现在 steps/align_step.dart；本步
  /// 只做标定，框选主体在下一步独立进行）；四角对齐作歪图透视备选（四角
  /// 即区域、无独立框选步，直接识别）
  Widget _buildAlign() {
    return AlignStep(
      imageStage: _imageStage,
      zoomStrip: _zoomStrip,
      viewerCtrl: _viewerCtrl,
      displaySize: _displaySize,
      stageViewSize: () => _stageViewSize,
      overlay: _mainOverlay(),
      cornerPts: _useCornerAlign ? _cornerPts : null,
      onCornerDrag: _onCornerDrag,
      miniAnchor: _useCornerAlign ? null : _miniAnchor,
      onMiniAnchor: (p) => setState(() => _miniAnchor = p),
      useCorner: _useCornerAlign,
      hint: _alignHint(),
      pitchX: _pitchX,
      recognizing: _recognizing,
      blankEnable: _blankEnable,
      colsCtrl: _colsCtrl,
      rowsCtrl: _rowsCtrl,
      onDimChanged: () => setState(() {}),
      onSwitchMode: _switchAlignMode,
      onResetCorners: _resetCorners,
      onBlankChanged: (v) => setState(() => _blankEnable = v),
      step: _alignStep,
      onStepChange: (v) => setState(() => _alignStep = v),
      onAdjustPitch: _adjustPitch,
      onNudge: _nudge,
      onRecognize: _recognize,
      onGoFrame: _goFrame,
      detecting: _detecting,
      onRedetect: _initMiniGrid,
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
  ///
  /// [selOverride] 供自动框选校验候选选区（先验行列数再决定是否落
  /// _selDisplay），默认读当前选区（现有调用点零改动）
  (int, int)? _plannedColsRows([Rect? selOverride]) {
    final anchor = _miniAnchor;
    final sel = selOverride ?? _selDisplay;
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
      return r; // 格距显示 <2px（与 FrameGridPainter 绘制阈值一致：该区间
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

  /// 自动检测主体区域：像素扫描/聚簇/数字边剔除的实现抽在
  /// lib/core/subject_detect.dart `detectSubjectBBox`（与图例检测同范式
  /// 的纯函数）。图例带取图例选区（或重新 isolate 检测的图例带），无图例
  /// 则整图视为候选区。返回吸附格线后的选区（显示坐标）；吸附后行列数
  /// 不在 4-400 返回 null（调用方提示手动框选）。检测全程 compute
  /// isolate（detectSubjectInIsolate），期间换图/卸载返回 null。
  Future<Rect?> _autoDetectSubject() async {
    final image = _image;
    if (image == null || _pitchX <= 0 || _pitchY <= 0 || _autoDetectBusy) {
      return null;
    }
    _busyGen++;
    _busyCancelled = false;
    final gen = _busyGen;
    setState(() => _autoDetectBusy = true);
    try {
      return await _autoDetectSubjectLocked(image, gen);
    } finally {
      if (mounted) {
        setState(() => _autoDetectBusy = false);
      }
    }
  }

  /// _autoDetectSubject 的检测本体（busy 已置位，进/出由外层 finally 收；
  /// [gen] 为启动时快照，两段 compute 之间据此弃终止结果）
  Future<Rect?> _autoDetectSubjectLocked(img.Image image, int gen) async {
    final w = image.width, h = image.height;
    // 图例带顶（图片坐标）：优先图例选区，其次自动检测的图例带；两皆无
    // 不排除（整图候选）
    var legendTop = h.toDouble();
    final legendSel = _legendSel;
    if (legendSel != null && legendSel.width > 8 && legendSel.height > 8) {
      legendTop = _selToImage(legendSel).$2;
    } else {
      final r = await compute(detectLegendInIsolate, image);
      if (r != null) {
        legendTop = r.top.toDouble(); // 检测结果本就是图片坐标，省显示坐标往返
      }
    }
    final bbox = await compute(
      detectSubjectInIsolate,
      SubjectDetectArgs(image, legendTop, _pitchX, _pitchY),
    );
    if (!mounted || !identical(_image, image) || gen != _busyGen) {
      return null; // 检测期间换图/被终止：结果弃
    }
    if (bbox == null) {
      return null;
    }
    // 图片坐标包围盒 -> 显示坐标 -> 吸附格线 -> 行列数校验
    final ds = _displaySize();
    var sel = Rect.fromLTRB(
      bbox.left * ds.width / w,
      bbox.top * ds.height / h,
      bbox.right * ds.width / w,
      bbox.bottom * ds.height / h,
    );
    sel = _snapSelToGrid(sel);
    final cr = _plannedColsRows(sel);
    if (cr == null) {
      return null;
    }
    return sel;
  }

  /// 触发自动框选主体（按钮）：成功设选区并提示，失败提示手动框选
  Future<void> _autoSelectSubject() async {
    final rect = await _autoDetectSubject();
    if (!mounted) {
      return;
    }
    if (rect == null) {
      if (!_busyCancelled) {
        // 终止路径静默退出（弹「未识别到主体区」会误导）
        AppSnackBar.show(context, "未识别到主体区，请手动框选");
      }
      return;
    }
    setState(() => _selDisplay = rect);
    AppSnackBar.show(context, "已自动框选主体，可拖动调整");
  }

  /// 阶段③：框选主体区域（面板实现在 steps/frame_step.dart；本步只做
  /// 框选——拖画/挪框/把手调大小，选区四边吸附格线由页面落状态时执行）
  Widget _buildFrame() {
    final sel = _selDisplay;
    return FrameStep(
      imageStage: _imageStage,
      zoomStrip: _zoomStrip,
      viewerCtrl: _viewerCtrl,
      displaySize: _displaySize,
      stageViewSize: () => _stageViewSize,
      sel: sel,
      overlay: _frameOverlay(),
      hint: _frameHint(),
      showAutoSelect: sel == null || sel.width <= 8,
      recognizing: _recognizing,
      blankEnable: _blankEnable,
      onSel: (r) => setState(() => _selDisplay = _snapSelToGrid(r)),
      onAutoSelect: _autoSelectSubject,
      onBlankChanged: (v) => setState(() => _blankEnable = v),
      onRecognize: _recognize,
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
    return FrameGridPainter(
      sel: sel,
      pitchDx: _pitchX * ds.width / image.width,
      pitchDy: _pitchY * ds.height / image.height,
      ctrl: _viewerCtrl,
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

  /// 阶段四：按色号分组复核 + 手工归类 + 图例数量对账（面板实现在
  /// steps/review_step.dart：总览豆图/截图墙/chips/操作条）
  Widget _buildReview() {
    return ReviewStep(
      zoomStrip: _zoomStrip,
      model: _model!,
      palette: _palette,
      legend: _legend,
      legendSort: _legendSort,
      cellRects: _cellRects,
      cellScores: _cellScores,
      cellSrc: _cellSrc,
      image: _image!,
      reviewColor: _reviewColor,
      crossCount: _reviewCrossCount,
      onCrossCountChange: (v) => setState(() => _reviewCrossCount = v),
      picked: _picked,
      reviewCtrl: _reviewCtrl,
      reviewCanvasSize: () => _reviewCanvasSize,
      onCanvasSize: (s) => _reviewCanvasSize = s,
      onChipTap: _reviewChipTap,
      onTogglePick: (i) => setState(() {
        _picked.contains(i) ? _picked.remove(i) : _picked.add(i);
      }),
      onPickCells: (cells, sel) => setState(() {
        // 绝对语义（置选/置不选）非翻转：拖选沿线重复应用同一格无副作用
        sel ? _picked.addAll(cells) : _picked.removeAll(cells);
      }),
      onSelectAll: _selectAllOfCurrent,
      onInvertPick: _invertPickOfCurrent,
      onClearPicked: () => setState(() => _picked.clear()),
      onReassign: _reassignPicked,
      hasClassifyTarget: _hasClassifyTarget(),
      onSave: _saveWork,
      onOpenEditor: _openEditor,
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
}

/// 终止确认弹窗（[_RestorePageState._confirmCancelBusy] 用）
///
/// 挂着的期间操作可能自然跑完（识别常比「读弹窗+点按」快）：弹窗内
/// 轮询 [isBusy]，完成后自动关闭——不留一个「已经不忙了还在问要不要
/// 终止」的误导弹窗。确认钮返回值一律 true，还忙不忙的判定由调用方在
/// 弹窗关闭后复查 busy 态（避免点按帧与完成帧的求值竞态）；自动关闭
/// 与按钮双通道 pop 用 _closed 门闩防重复 pop 误伤下层路由
class _CancelBusyDialog extends StatefulWidget {
  const _CancelBusyDialog({required this.isBusy});

  final bool Function() isBusy;

  @override
  State<_CancelBusyDialog> createState() => _CancelBusyDialogState();
}

class _CancelBusyDialogState extends State<_CancelBusyDialog> {
  Timer? _poll;
  var _closed = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!widget.isBusy()) {
        _close(false); // 操作已自然完成：结果照常落屏，弹窗自动收起
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _close(bool v) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("终止当前操作？"),
      content: const Text("已进行到一半的进度会丢弃，可随时重新发起。"),
      actions: [
        TextButton(
          onPressed: () => _close(false),
          child: const Text("继续等待"),
        ),
        TextButton(
          // 返回 true 无条件化：终止生效与否由调用方关闭后复查 busy
          onPressed: () => _close(true),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFFE53935),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
          child: const Text("终止"),
        ),
      ],
    );
  }
}

/// 图区里图片的显示尺寸（[RestorePage] 的 _displaySize；抽成顶层纯函数
/// 便于单测，不用在测试环境里解图 / 跑 isolate）。
///
/// 紧凑档：可用宽 = 窗口宽 - 两侧 12 padding（图横向铺满，与布局公式一致）。
/// 展开档（宽 ≥ 840dp 且高 ≥ 500dp 的窗口，平板横屏/桌面）：堆叠布局下若仍按
/// 窗口宽铺满，竖版图纸会高出视口数倍（minScale=1 缩不回去，底部的
/// 图例带够不着）——改为整图等比装入图区视口（宽高同时受限，整幅可见）。
/// 两档都只由窗口尺寸决定、与面板展开/步骤切换无关：显示坐标系在一幅
/// 图的生命周期内保持稳定，存量选区/锚点/四角不会因面板高度变化而错位。
///
/// [window] 窗口逻辑尺寸；[topPadding] 状态栏高度（AppBar 占的高度 = 它 + kToolbarHeight）；
/// [bottomInset] 底部系统栏内边距（SafeArea(top:false) 已消费 padding.bottom，但本公式
/// 从窗口总高起算，不减它会把图区多算高一截、图纸底部被裁掉）；
/// [imageWidth]/[imageHeight] 原图像素尺寸。
Size restoreDisplaySize({
  required Size window,
  required double topPadding,
  required double bottomInset,
  required int imageWidth,
  required int imageHeight,
}) {
  final compactW = window.width - 24;
  if (!isExpandedSize(window)) {
    return Size(compactW, compactW * imageHeight / imageWidth);
  }
  // 图区视口 = 窗口去掉图区 padding(12×2)、AppBar、缩放条、底部系统栏，
  // 再预留一份控制面板的常见高度（堆叠布局下面板高度随步骤/展开态变化，
  // 显示尺寸只能按固定预算算，否则面板一动图就重排、选区错位）
  final stageW = window.width - 24;
  final stageH = window.height -
      topPadding -
      bottomInset -
      kToolbarHeight -
      kZoomStripHeight -
      kStackedPanelBudget -
      24;
  final k = math.min(stageW / imageWidth, stageH / imageHeight);
  return Size(imageWidth * k, imageHeight * k);
}
