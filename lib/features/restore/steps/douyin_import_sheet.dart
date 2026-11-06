import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../../../core/app_snack_bar.dart';
import '../../../core/douyin_detail.dart';
import '../../../core/douyin_link.dart';
import 'link_image_viewer.dart';

/// 抖音链接导入面板：粘贴分享文案 → 缩略图选一张 → 进还原流程；
/// 双击缩略图全屏查看（右上角下载按钮存相册）。
///
/// [onImageChosen] 收到选中图的图片字节（优先无损 q75.jpeg 档＝作者
/// 上传原字节，隐藏 WebView 提取签名 URL；失败静默回退 SSR q75.webp），
/// 在面板关闭后回调，喂给与相册选图同一条还原链路。
Future<void> showDouyinImportSheet(
  BuildContext context,
  void Function(Uint8List bytes) onImageChosen,
) async {
  final bytes = await showModalBottomSheet<Uint8List>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // 下拉手势整个关闭面板：解析/下载期会误关导致导入中断，全程禁用。
    // 注意 showDragHandle 必须一起去掉——SDK 在 enableDrag:false 时反而
    // 给把手单独挂拖拽检测（把手保留为关闭途径），留着照样能拖关
    //（关闭走返回键/点外部，忙碌期由面板内 PopScope 拦截）
    enableDrag: false,
    builder: (_) => const _DouyinImportSheet(),
  );
  if (bytes != null) {
    onImageChosen(bytes);
  }
}

/// 图片字节缓存：双击查看与「开始还原」共用，避免同一张图下载两次
class _BytesCache {
  final Map<String, Uint8List> _map = {};
  Uint8List? get(String key) => _map[key];
  void put(String key, Uint8List bytes) => _map[key] = bytes;
}

class _DouyinImportSheet extends StatefulWidget {
  const _DouyinImportSheet();

  @override
  State<_DouyinImportSheet> createState() => _DouyinImportSheetState();
}

class _DouyinImportSheetState extends State<_DouyinImportSheet> {
  final _inputCtrl = TextEditingController();
  final _cache = _BytesCache();

  var _phase = _Phase.input; // 输入链接 / 解析中 / 缩略图选择
  DouyinNote? _note;
  String? _error;
  int _selected = -1;
  var _downloading = false;

  /// 无损增强通道（WebView 签名 detail）：对象 id → jpeg 原图 URL；
  /// null/空 = 未就绪或失败，SSR webp 兜底。UI 不因它失败而变化
  Map<String, String>? _lossless;
  var _boosting = false;
  Completer<void>? _boostDone;

  @override
  void initState() {
    super.initState();
    _prefillClipboard();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  /// 打开即读剪贴板：分享文案通常已经复制好，省一次粘贴
  Future<void> _prefillClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isNotEmpty && extractDouyinLink(text) != null) {
      if (mounted) {
        setState(() => _inputCtrl.text = text);
      }
    }
  }

  Future<void> _fetch() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    try {
      final note = await fetchDouyinNote(_inputCtrl.text);
      if (!mounted) {
        return;
      }
      setState(() {
        _note = note;
        _selected = note.images.length == 1 ? 0 : -1;
        _phase = _Phase.pick;
        _lossless = null;
      });
      _startBoost(note);
    } on DouyinLinkException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _phase = _Phase.input;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '获取失败：$e\n（网页版受浏览器跨域限制，请用 App）';
          _phase = _Phase.input;
        });
      }
    }
  }

  /// 无损增强：SSR 解析成功后挂隐藏 WebView 加载 PC 笔记页，从 hydrate
  /// 后的 DOM 提取 q75.jpeg 签名 URL（= 原图字节）。任何失败静默回退
  /// SSR webp（见 docs/douyin_lossless_channel.md）
  void _startBoost(DouyinNote note) {
    final id = note.noteId;
    // 旧探测器（若有）立即失效结算，避免与新一轮竞争
    final old = _boostDone;
    if (old != null && !old.isCompleted) {
      old.complete();
    }
    // webview_flutter 不支持 web（SSR 在 web 上也过不了 CORS，理论到不了
    // 这里，防御性短路）
    if (id == null || kIsWeb) {
      if (mounted) {
        setState(() => _boosting = false);
      }
      return;
    }
    _boostDone = Completer<void>();
    setState(() => _boosting = true);
  }

  Future<Uint8List> _ensureOriginal(DouyinNoteImage img) async {
    final hit = _cache.get(img.uriKey);
    if (hit != null) {
      return hit;
    }
    // 增强通道在跑：预算内等它（拿到才下载无损档）；超时/失败照走 SSR
    final boost = _boostDone;
    if (boost != null) {
      try {
        await boost.future.timeout(const Duration(seconds: 58));
      } on Exception {
        // 探测器自身 55s 预算兜底，这里只是双保险
      }
    }
    final jpeg = _lossless?[douyinObjectIdOf(img.url)];
    Uint8List bytes;
    if (jpeg != null) {
      try {
        bytes = await downloadDouyinUrl(jpeg);
      } on Exception {
        bytes = await downloadDouyinImage(img); // 无损下载失败回退
      }
    } else {
      bytes = await downloadDouyinImage(img);
    }
    _cache.put(img.uriKey, bytes);
    return bytes;
  }

  /// 「开始还原」：下载选中图（优先无损档）→ 关面板回传字节
  Future<void> _confirm() async {
    if (_note == null || _selected < 0 || _downloading) {
      return;
    }
    final img = _note!.images[_selected];
    setState(() => _downloading = true);
    try {
      final bytes = await _ensureOriginal(img);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(bytes);
    } on DouyinLinkException catch (e) {
      if (mounted) {
        AppSnackBar.show(context, e.message);
        setState(() => _downloading = false);
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, '下载图片失败: $e');
        setState(() => _downloading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.85;
    // 解析中锁整个面板（返回键/点外部都拦——中断即整轮作废）；下载/
    // 无损增强等待只锁内容不拦退出（最长可达数十秒，卡死时要留逃生口）
    final parsing = _phase == _Phase.loading;
    final busy = parsing || _downloading;
    return PopScope(
      canPop: !parsing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          AppSnackBar.show(context, '正在解析链接，请稍候…');
        }
      },
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 隐藏 WebView（0.01 高，ClipRect 内）——无损增强探测器；
                  // ValueKey(noteId)：换链接重解析时旧 State 干净作废
                  if (_boosting && _note?.noteId != null)
                    DouyinDetailProbe(
                      key: ValueKey(_note!.noteId),
                      noteId: _note!.noteId!,
                      onJpegs: (m) {
                        if (mounted && _boosting) {
                          setState(() => _lossless = m);
                        }
                      },
                      onDone: () {
                        if (!mounted || !_boosting) {
                          return;
                        }
                        setState(() => _boosting = false);
                        final b = _boostDone;
                        if (b != null && !b.isCompleted) {
                          b.complete();
                        }
                      },
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.music_note, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _phase == _Phase.pick
                                ? (_note!.title.isEmpty
                                    ? '选择一张图纸'
                                    : _note!.title)
                                : '从抖音链接导入',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (_phase == _Phase.pick)
                          IconButton(
                            tooltip: '重新输入链接',
                            onPressed: () =>
                                setState(() => _phase = _Phase.input),
                            icon: const Icon(Icons.refresh, size: 20),
                          ),
                      ],
                    ),
                  ),
                  Flexible(child: _buildBody()),
                  if (_phase == _Phase.pick &&
                      (_boosting || (_lossless?.isNotEmpty ?? false)))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: _boosting
                            ? const [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.6),
                                ),
                                SizedBox(width: 6),
                                Text(
                                  '正在尝试获取无损原图…',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.black45),
                                ),
                              ]
                            : const [
                                Icon(Icons.verified,
                                    size: 14, color: Colors.green),
                                SizedBox(width: 4),
                                Text(
                                  '无损原图已就绪',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.green),
                                ),
                              ],
                      ),
                    ),
                  if (_phase == _Phase.pick)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed:
                              _selected >= 0 && !_downloading ? _confirm : null,
                          icon: _downloading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.auto_awesome),
                          label: Text(
                            _downloading
                                ? (_boosting ? '正在获取原图…' : '正在下载图片…')
                                : '开始还原',
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // 忙碌锁：半透明遮罩吞掉内容区一切点击（换选/重新输入/双击大图），
              // 既有进度反馈（按钮 spinner/无损提示行）从遮罩下透出可辨
              if (busy)
                Positioned.fill(
                  child: AbsorbPointer(
                    child: ColoredBox(color: Colors.black26),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return switch (_phase) {
      _Phase.input => _buildInput(),
      _Phase.loading => const Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在解析链接…', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      _Phase.pick => _buildGrid(),
    };
  }

  Widget _buildInput() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _inputCtrl,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: '粘贴抖音分享文案或链接\n（如 https://v.douyin.com/xxxxx/）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _fetch,
            icon: const Icon(Icons.search),
            label: const Text('获取图片'),
          ),
          const SizedBox(height: 6),
          const Text(
            '免登录获取，分辨率与作者发布一致',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Colors.black38),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    final images = _note!.images;
    return GridView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: images.length,
      itemBuilder: (_, i) {
        final img = images[i];
        final selected = _selected == i;
        return GestureDetector(
          onTap: () => setState(() => _selected = i),
          onDoubleTap: () => _openViewer(i),
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.black12,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      img.url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black12,
                        child: Center(
                          child:
                              Icon(Icons.broken_image, color: Colors.black26),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (selected)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Icon(
                    Icons.check_circle,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 双击缩略图 → 全屏查看（可缩放，右上角下载）
  Future<void> _openViewer(int index) async {
    final img = _note!.images[index];
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LinkImageViewerPage(
          title: _note?.title ?? '',
          width: 0,
          height: 0,
          savePrefix: 'douyin',
          loadOriginal: () => _ensureOriginal(img),
        ),
      ),
    );
  }
}

enum _Phase { input, loading, pick }
