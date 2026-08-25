import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
import '../../data/demo_palette.dart';
import '../editor/editor_page.dart';
import '../editor/grid_painter.dart';

/// 页面阶段：选图 -> 框图例 -> 网格对齐 -> 识别复核
enum _Stage { pick, legend, align, review }

/// 空白判定阈值：格色与候选色的 Lab 距离平方超过此值视为空白格
const double _blankDistSq = 900.0; // ΔE ≈ 30

/// OCR 常见字符混淆表（色号匹配用：印刷小字 0/O、1/I/L、2/Z、5/S、6/G、8/B、4/A 互混）
const Map<String, List<String>> _ocrConfusions = {
  "0": ["O"], "O": ["0"],
  "1": ["I", "L"], "I": ["1"], "L": ["1"],
  "2": ["Z"], "Z": ["2"],
  "5": ["S"], "S": ["5"],
  "6": ["G"], "G": ["6"],
  "8": ["B"], "B": ["8"],
  "4": ["A"], "A": ["4"],
};

/// 图例 OCR 识别元素（色号或颗数，带几何框供跨行配对）
class _OcrElem {
  final int seq; ///< 收集序（block/line/element 遍历序，保底配对用）
  final Rect rect; ///< 元素框（放大图坐标系；个别平台可能退化为 0 框）
  final int? code; ///< 色号 -> 调色板索引（与 count 互斥）
  final int? count; ///< 颗数
  bool used = false; ///< 已被配对消费（数字侧）
  int? pairedCount; ///< 色号侧配到的颗数
  // 【临时调试】配对的另一侧元素引用（调试视图画连线用，正式版随调试功能一起移除）
  _OcrElem? pairedWith;
  String dbgText = ""; ///< 【临时调试】OCR 原始文本
  _OcrElem(this.seq, this.rect, this.code, this.count);
}

/// 【临时调试】一次图例 OCR 的调试快照（正式版随调试视图一起移除）
class _OcrDebugInfo {
  final String source; ///< 来源（自动扫描档位 / 手动框选）
  final String imgPath; ///< 喂给 ML Kit 的放大选区图路径
  final int imgW, imgH; ///< 放大图尺寸（元素框坐标系）
  final List<_OcrElem> elems; ///< 全部识别元素（含配对引用）
  _OcrDebugInfo(this.source, this.imgPath, this.imgW, this.imgH, this.elems);
}

/// 图例条目：图纸图例里识别出的一个用色
class _LegendEntry {
  final int paletteIndex; ///< 调色板索引
  final int legendCount; ///< 图例区出现格数
  bool checked; ///< 是否纳入主体识别候选
  final TextEditingController countCtrl = TextEditingController(); ///< 图例标注数量（手填，对账用）

  _LegendEntry(this.paletteIndex, this.legendCount, {this.checked = true});

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
  Uint8List? _bytes; ///< 原图字节
  img.Image? _image; ///< 解码后的原图

  // ========== 色卡 ==========
  BeadPalette _palette = demoPalette; ///< 当前色卡（initState 异步换为选中色卡）
  List<PaletteInfo> _palettes = const []; ///< 可选色卡列表
  String _paletteId = "";

  // ========== 图例（步骤 1/2） ==========
  Rect? _legendSel; ///< 图例选区（显示坐标）
  final _legendColsCtrl = TextEditingController();
  final _legendRowsCtrl = TextEditingController();
  var _legendBusy = false;
  List<_LegendEntry> _legend = []; ///< 识别出的图例清单
  var _legendByOcr = false; ///< true=清单来自印刷色号（行列输入隐藏，网格层不画）
  var _viewMode = false; ///< true=查看模式（拖动滚动原图），false=框选模式（拖动改选区）
  var _panelExpanded = true; ///< 图例确认面板展开（收起后图片区变大，便于对照原图校对）
  final _legendSelKey = GlobalKey(); ///< 图例选区锚点（识别后自动滚动定位用）
  // 【临时调试】最近一次图例 OCR 的调试信息（放大图/元素/配对），正式版随调试视图一起移除
  _OcrDebugInfo? _ocrDebug;
  final _legendScrollCtrl = ScrollController(); ///< 图例阶段滚动控制（进入时滚到图片底部露出图例）

  // ========== 主体对齐（步骤 3/4） ==========
  Rect? _selDisplay; ///< 主体选区（显示坐标）
  final _colsCtrl = TextEditingController();
  final _rowsCtrl = TextEditingController();
  var _detecting = false;
  var _recognizing = false;
  double _pitchX = 0, _pitchY = 0; ///< 网格格距（图片坐标）
  double _offX = 0, _offY = 0; ///< 第一根网格线相对选区左上偏移（图片坐标）
  bool _blankEnable = true; ///< 偏色过大识别为空白格

  // ========== 复核（步骤 5） ==========
  PatternModel? _model;
  int _reviewColor = -2; ///< 当前复核色：-2 关闭 / -1 空白 / >=0 调色板索引
  final Set<int> _picked = {}; ///< 选中的格子（扁平索引）

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
    _legendScrollCtrl.dispose();
    _colsCtrl.dispose();
    _rowsCtrl.dispose();
    _legendColsCtrl.dispose();
    _legendRowsCtrl.dispose();
    for (final e in _legend) {
      e.countCtrl.dispose();
    }
    super.dispose();
  }

  // ==================== 选图 ====================

  Future<void> _pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 100);
    if (picked == null) {
      return;
    }
    try {
      final bytes = await picked.readAsBytes();
      final decoded = await decodeImageRobust(bytes);
      if (!mounted) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _image = decoded;
        _legendSel = null;
        _selDisplay = null;
        _legend = [];
        _legendByOcr = false;
        _pitchX = 0;
        _model = null;
        _stage = _Stage.legend;
      });
      // 图例印在图纸底部，而图片高于视口时初始只显示到图案中部（底部面板又占掉
      // 一截视口），用户根本看不到图例、只能框到猫身 -> OCR 失败回退量化错误清单。
      // 进入图例阶段先滚到底部，图例条带直接可见。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_legendScrollCtrl.hasClients) {
          _legendScrollCtrl.jumpTo(_legendScrollCtrl.position.maxScrollExtent);
        }
      });
    } catch (e) {
      // 解码失败必须弹提示（曾经异常被吞表现为"选图无反应"）
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("无法解码图片: $e")));
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
        for (final entry in freq.entries.toList()..sort((a, b) => b.value - a.value))
          _LegendEntry(entry.key, entry.value),
      ];
      var ocrHit = 0;
      if (pairs != null && pairs.length >= 3) {
        final byOcr = <_LegendEntry>[];
        final seen = <int>{};
        for (final (idx, count) in pairs) {
          if (!seen.add(idx)) {
            continue; // 同一色号多次出现（图例重复/误读），取首条
          }
          final e = _LegendEntry(idx, freq[idx] ?? 1);
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
        // 识别完成自动切查看模式：拖动原图与清单对照校对（面板收起后可见整幅原图）
        _viewMode = true;
        _panelExpanded = true;
      });
      // 自动滚动到图例选区：原图下半部（图例所在）立即进入视野供校对
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final selCtx = _legendSelKey.currentContext;
        if (selCtx != null) {
          Scrollable.ensureVisible(
            selCtx,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            alignment: 0.5,
          );
        }
      });
      if (ocrHit > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("已按图例印刷色号识别 $ocrHit 色，颗数自动读取 $ocrHit 条，请对照原图核对")),
        );
      } else if (pairs != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("框选区域未读到图例文字，以下按色块识别仅作参考；请只框选图纸底部的色块+色号+数字区域")),
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
  Future<List<(int, int)>?> _ocrLegendPairs(double rx, double ry, double rw, double rh,
      {String source = "手动框选"}) async {
    if (kIsWeb) {
      return null;
    }
    final image = _image;
    if (image == null) {
      return null;
    }
    try {
      final crop = img.copyCrop(image, x: rx.toInt(), y: ry.toInt(), width: rw.toInt(), height: rh.toInt());
      // 小字放大提高识别率：按高度放大到 ~480px（数字高 ~60px+）。
      // 固定 ×3 在小选区（裁剪后图例条带小）下分辨率不足，数字 64 会误读成 61
      final scale = (480 / rh).clamp(2, 6);
      final scaled = img.copyResize(crop, width: (crop.width * scale).round());
      final tmp = File("${(await getTemporaryDirectory()).path}/legend_ocr.png");
      await tmp.writeAsBytes(img.encodePng(scaled));

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final recognized = await recognizer.processImage(InputImage.fromFilePath(tmp.path));
      await recognizer.close();

      // 精确 + 混淆变体查找表：variant -> 调色板索引
      final codeMap = <String, int>{};
      for (var i = 0; i < _palette.colors.length; i++) {
        final variants = <String>{};
        _collectCodeVariants(_palette.colors[i].id.toUpperCase(), 0, "", variants);
        for (final v in variants) {
          codeMap[v] ??= i; // 变体撞车时先到先得
        }
      }

      // 收集全部色号/颗数元素（带几何框：颗数可能在色号下一行，纯行内序配不上）
      final elems = <_OcrElem>[];
      var seq = 0;
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          for (final element in line.elements) {
            final text = element.text.trim().toUpperCase().replaceAll(" ", "");
            // 色号最多 4 字符（A1/H12 型），长文本是正文/杂项不做色号
            if (text.length <= 4) {
              final code = codeMap[text];
              if (code != null) {
                final e = _OcrElem(seq++, element.boundingBox, code, null);
                e.dbgText = element.text; // 【临时调试】保留原始文本
                elems.add(e);
                continue;
              }
            }
            final n = _parseCountText(element.text);
            if (n != null) {
              final e = _OcrElem(seq++, element.boundingBox, null, n);
              e.dbgText = element.text; // 【临时调试】保留原始文本
              elems.add(e);
            }
          }
        }
      }
      // 【临时调试】保存本次 OCR 快照（放大图 + 元素 + 配对前状态），正式版移除
      _ocrDebug = _OcrDebugInfo(source, tmp.path, scaled.width, scaled.height, elems);
      return _pairLegendOcr(elems);
    } catch (_) {
      return null;
    }
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
    final heights = [for (final e in elems) if (e.rect.height > 0) e.rect.height];
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
    final belowFirst = [...codes]..sort((a, b) => b.rect.top.compareTo(a.rect.top));
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

    // 阅读顺序输出：先上后下，同行先左后右
    final sorted = [...codes]..sort((a, b) {
        final dy = a.rect.top - b.rect.top;
        return dy.abs() > avgH * 0.7 ? (dy > 0 ? 1 : -1) : a.rect.left.compareTo(b.rect.left);
      });
    return [
      for (final c in sorted)
        if (c.pairedCount != null) (c.code!, c.pairedCount!),
    ];
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
    var t = raw.trim().toUpperCase().replaceAll(",", "").replaceAll(" ", "");
    t = t.replaceAll("O", "0").replaceAll("I", "1").replaceAll("L", "1").replaceAll("S", "5").replaceAll("B", "8");
    if (!RegExp(r"^\d+$").hasMatch(t)) {
      return null;
    }
    final v = int.tryParse(t);
    return (v == null || v <= 0 || v > 100000) ? null : v;
  }

  /// 弹全色卡选色器（修正图例色号用）
  Future<int?> _pickColorIndex() {
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("选择正确色号"),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: GridView.count(
            crossAxisCount: 6,
            children: [
              for (var i = 0; i < _palette.colors.length; i++)
                InkWell(
                  onTap: () => Navigator.pop(ctx, i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(width: 34, height: 34, color: Color.fromARGB(255, _palette.colors[i].r, _palette.colors[i].g, _palette.colors[i].b)),
                      Text(_palette.colors[i].id, style: const TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
      ),
    );
  }

  /// 修正图例条目色号（若目标色已有条目则合并格数后删除本条）
  Future<void> _changeLegendColor(_LegendEntry entry) async {
    final idx = await _pickColorIndex();
    if (idx == null) {
      return;
    }
    setState(() {
      final dup = _legend.where((e) => e != entry && e.paletteIndex == idx).toList();
      if (dup.isNotEmpty) {
        dup.first.countCtrl.dispose();
        _legend.remove(dup.first);
      }
      _legend[_legend.indexOf(entry)] = _LegendEntry(idx, entry.legendCount, checked: entry.checked);
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("行列数须在 4-400 之间")));
      return;
    }
    if (_pitchX <= 0 || _pitchY <= 0) {
      _recomputePitchFromField();
    }
    setState(() => _recognizing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final (rx, ry, _, _) = _selToImage(_selDisplay);
      final candidates = <int>{
        for (final e in _legend)
          if (e.checked) e.paletteIndex,
      };
      final quantizer = Quantizer(_palette);
      final grid = List<int>.filled(cols * rows, 0);
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final cx = rx + _offX + (c + 0.5) * _pitchX;
          final cy = ry + _offY + (r + 0.5) * _pitchY;
          final (sr, sg, sb) = _sampleCenter(cx, cy, _pitchX, _pitchY);
          final (idx, distSq) = quantizer.nearestWithin(sr, sg, sb, candidates.isEmpty ? null : candidates);
          grid[r * cols + c] = (_blankEnable && distSq > _blankDistSq) ? -1 : idx;
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
      MaterialPageRoute(builder: (_) => EditorPage(model: model, palette: _palette)),
    );
  }

  /// 图例标注数量（无勾选条目/未填返回 null = 不对账）
  int? _expectedOf(int paletteIndex) {
    for (final e in _legend) {
      if (e.checked && e.paletteIndex == paletteIndex) {
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("归类")),
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

  /// 进入「框选主体」阶段：回到框选模式（该阶段第一动作是重新框选）
  void _goAlign() {
    setState(() {
      _viewMode = false;
      _stage = _Stage.align;
    });
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
            Text("构建 $appBuildLabel", style: const TextStyle(fontSize: 10, color: Colors.black38)),
          ],
        ),
        actions: [
          // 【临时调试】图例 OCR 调试入口：识别后即可查看放大图/元素/配对，正式版移除
          if (_stage == _Stage.legend && _ocrDebug != null)
            IconButton(onPressed: _showOcrDebug, icon: const Icon(Icons.bug_report), tooltip: "OCR 调试"),
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
                        if (p.id == _paletteId) const Icon(Icons.check, size: 18),
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("已切换到${target.label}，图例需重新识别")));
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
            const Text("框图例 → 核对用色 → 对齐网格 → 识别 → 手工纠错", style: TextStyle(fontSize: 12, color: Colors.black45)),
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

  /// 图片 + 框选/查看双模式手势 + 可选网格覆盖（图例/对齐阶段共用）
  ///
  /// 框选模式：拖动 = 改选区（滚动锁定）；查看模式：拖动 = 上下滚动原图（不碰选区）。
  /// 顶部浮动胶囊即时切换——识别出清单后需对照原图校对，查看模式让原图下半部（图例区）
  /// 可滚入视野，不被底部面板永久遮挡。
  Widget _imageStage({
    required Rect? sel,
    required void Function(Rect) onSel,
    _GridOverlayPainter? overlay,
    Key? selAnchorKey,
    ScrollController? scrollCtrl,
  }) {
    final ds = _displaySize();
    return Stack(
      children: [
        SingleChildScrollView(
          controller: scrollCtrl,
          physics: _viewMode ? null : const NeverScrollableScrollPhysics(),
          child: GestureDetector(
            onPanDown: _viewMode ? null : (d) => onSel(Rect.fromPoints(d.localPosition, d.localPosition)),
            onPanUpdate: _viewMode ? null : (d) => onSel(Rect.fromPoints(sel!.topLeft, d.localPosition)),
            child: Stack(
              children: [
                Image.memory(_bytes!, width: ds.width, height: ds.height, fit: BoxFit.fill),
                if (sel != null && sel.width > 2)
                  Positioned.fill(child: CustomPaint(painter: _SelPainter(sel))),
                // 选区锚点：给 Scrollable.ensureVisible 定位（透明占位，不参与绘制）
                if (selAnchorKey != null && sel != null && sel.width > 2)
                  Positioned.fromRect(rect: sel, child: SizedBox(key: selAnchorKey)),
                if (overlay != null)
                  Positioned.fill(child: CustomPaint(painter: overlay, size: ds)),
              ],
            ),
          ),
        ),
        Positioned(top: 4, left: 0, right: 0, child: Center(child: _modePill())),
      ],
    );
  }

  /// 模式切换胶囊（浮在图片顶部）
  Widget _modePill() {
    final viewing = _viewMode;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(16),
      color: viewing ? const Color(0xFF1565C0) : const Color(0xFFE65100),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _viewMode = !_viewMode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(viewing ? Icons.open_with : Icons.crop_free, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                viewing ? "查看模式 · 上下拖动原图，点此切回框选" : "框选模式 · 拖出选区，点此切为拖动查看",
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 当前网格覆盖层（无有效参数返回 null）
  _GridOverlayPainter? _mainOverlay() {
    final cols = int.tryParse(_colsCtrl.text) ?? 0;
    final rows = int.tryParse(_rowsCtrl.text) ?? 0;
    if (_pitchX <= 0 || _pitchY <= 0 || cols < 1 || rows < 1) {
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
              overlay: scanned && !_legendByOcr ? _legendOverlay() : null, // 网格层仅量化模式有参考意义
              selAnchorKey: _legendSelKey,
              scrollCtrl: _legendScrollCtrl,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!scanned) ...[
                const Text("① 只框出图纸底部的图例区（色号 + 颗数对照表）", style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _legendBusy ? null : _scanLegend,
                        icon: _legendBusy
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.document_scanner, size: 18),
                        label: Text(_legendBusy ? "识别中…" : "识别图例"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      onPressed: _goAlign,
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
                        onTap: () => setState(() => _panelExpanded = !_panelExpanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(
                                _panelExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                                size: 22,
                                color: Colors.black54,
                              ),
                              const SizedBox(width: 2),
                              Expanded(
                                child: Text(
                                  _panelExpanded
                                      ? "图例 ${_legend.length} 色 · 已勾 ${_legend.where((e) => e.checked).length} 色（点此收起，露出原图核对）"
                                      : "图例 ${_legend.length} 色 · 已勾 ${_legend.where((e) => e.checked).length} 色（点此展开核对清单）",
                                  style: const TextStyle(fontSize: 12, color: Colors.black54),
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
                            decoration: const InputDecoration(labelText: "列", border: OutlineInputBorder(), isDense: true),
                          ),
                        ),
                        const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text("×")),
                        SizedBox(
                          width: 64,
                          child: TextField(
                            controller: _legendRowsCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(labelText: "行", border: OutlineInputBorder(), isDense: true),
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
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(_legendBusy ? "识别中…" : "重新框选后识别"),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 168,
                    child: ListView.builder(
                      itemCount: _legend.length,
                      itemBuilder: (_, i) {
                        final e = _legend[i];
                        final c = _palette.colors[e.paletteIndex];
                        return Row(
                          children: [
                            InkWell(
                              onTap: () => _changeLegendColor(e),
                              child: Container(width: 28, height: 28, color: Color.fromARGB(255, c.r, c.g, c.b)),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(width: 52, child: Text(c.id)),
                            Text("图例占${e.legendCount}格", style: const TextStyle(fontSize: 12, color: Colors.black45)),
                            const Spacer(),
                            SizedBox(
                              width: 72,
                              child: TextField(
                                controller: e.countCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: "颗数",
                                  hintText: "按原图填",
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            Checkbox(value: e.checked, onChanged: (v) => setState(() => e.checked = v ?? false)),
                          ],
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
                          label: Text("下一步：框选主体（勾选${_legend.where((e) => e.checked).length}色）"),
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
    final paired = dbg.elems.where((e) => e.code != null && e.pairedCount != null).length;
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
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ],
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
                        Image.file(File(dbg.imgPath), fit: BoxFit.fill),
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

  /// 阶段三：框选主体 + 网格对齐（自动检测 + 格子大小/微移）
  Widget _buildAlign() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _imageStage(
              sel: _selDisplay,
              onSel: (r) => setState(() => _selDisplay = r),
              overlay: _mainOverlay(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _pitchX > 0 ? "网格已覆盖（蓝线）· 不对齐就微调下方参数" : "② 框选主体图案区域，或直接自动检测",
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
                      decoration: const InputDecoration(labelText: "列数", border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text("×")),
                  Expanded(
                    child: TextField(
                      controller: _rowsCtrl,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _recomputePitchFromField(),
                      decoration: const InputDecoration(labelText: "行数", border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _detecting ? null : _autoDetect,
                    icon: _detecting
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_awesome, size: 18),
                    label: const Text("自动检测"),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text("格子大小"),
                  IconButton(onPressed: _pitchX > 0 ? () => _adjustPitch(-0.2) : null, icon: const Icon(Icons.remove_circle_outline)),
                  Text(_pitchX > 0 ? _pitchX.toStringAsFixed(2) : "--"),
                  IconButton(onPressed: _pitchX > 0 ? () => _adjustPitch(0.2) : null, icon: const Icon(Icons.add_circle_outline)),
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
                      title: const Text("偏色过大识别为空白格", style: TextStyle(fontSize: 13)),
                      value: _blankEnable,
                      onChanged: (v) => setState(() => _blankEnable = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _recognizing ? null : _recognize,
                      icon: _recognizing
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
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
    final blankCount = model.cellCount - counts.values.fold<int>(0, (a, b) => a + b);
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
                          if (cx < 0 || cx >= model.width || cy < 0 || cy >= model.height) {
                            return;
                          }
                          setState(() {
                            final i = cy * model.width + cx;
                            _picked.contains(i) ? _picked.remove(i) : _picked.add(i);
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
                                highlightIndex: _reviewColor >= 0 ? _reviewColor : null,
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
                                  painter: _ReviewMarksPainter(model: model, picked: _picked),
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
  Widget _buildReviewChips(List<int> order, Map<int, int> counts, int blankCount) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _reviewChip(
            lead: Container(width: 20, height: 20, decoration: BoxDecoration(border: Border.all(color: Colors.black38)), child: const Icon(Icons.close, size: 14)),
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
                lead: Container(width: 20, height: 20, color: Color.fromARGB(255, c.r, c.g, c.b)),
                label: expected == null ? "${c.id} $actual" : "${c.id} $actual/$expected",
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
          child: Row(children: [lead, const SizedBox(width: 4), Text(label, style: const TextStyle(fontSize: 12))]),
        ),
      ),
    );
  }

  /// 复核操作条：对账状态 + 选中操作 + 进编辑器
  Widget _buildReviewActions(List<int> order, Map<int, int> counts, int blankCount) {
    var mismatch = 0;
    var accounted = 0;
    for (final e in _legend) {
      if (!e.checked) {
        continue;
      }
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
              style: TextStyle(fontSize: 12, color: mismatch == 0 ? Colors.green : Colors.orange),
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
                onPressed: _picked.isEmpty ? null : () => setState(() => _picked.clear()),
                child: Text("清除选中(${_picked.length})"),
              ),
              const Spacer(),
              FilledButton.icon(onPressed: _openEditor, icon: const Icon(Icons.edit), label: const Text("进编辑器")),
            ],
          ),
        ],
      ),
    );
  }
}

/// 选区绘制：外部半透明遮罩 + 蓝色边框
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

    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    path.addPath(Path()..addRect(rect), Offset.zero);
    canvas.drawPath(Path.combine(PathOperation.difference, path, Path()), mask);
    canvas.drawRect(rect, border);
  }

  @override
  bool shouldRepaint(covariant _SelPainter oldDelegate) => oldDelegate.rect != rect;
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
  final double originDx; ///< 第一根竖线 x（显示坐标）
  final double originDy; ///< 第一根横线 y（显示坐标）
  final double pitchDx; ///< 横向格距（显示坐标）
  final double pitchDy; ///< 纵向格距（显示坐标）

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
  bool shouldRepaint(covariant _BlankMarksPainter oldDelegate) => oldDelegate.model != model;
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
      canvas.drawLine(Offset(cx - s * 0.2, cy), Offset(cx - s * 0.05, cy + s * 0.18), check);
      canvas.drawLine(Offset(cx - s * 0.05, cy + s * 0.18), Offset(cx + s * 0.25, cy - s * 0.18), check);
    }
  }

  @override
  bool shouldRepaint(covariant _ReviewMarksPainter oldDelegate) => oldDelegate.picked != picked;
}
