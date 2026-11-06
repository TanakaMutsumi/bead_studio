import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import '../../../core/app_snack_bar.dart';
import '../../../core/xhs_link.dart';
import 'link_image_viewer.dart';

/// 小红书链接导入面板：粘贴链接 → 缩略图选一张 → 进还原流程；
/// 双击缩略图全屏看原图（右上角下载按钮存相册）。
///
/// [onImageChosen] 收到选中图的**原始字节**（镜像 CDN 原图，非 1080 压缩版），
/// 在面板关闭后回调，喂给与相册选图同一条还原链路。
Future<void> showXhsImportSheet(
  BuildContext context,
  void Function(Uint8List bytes) onImageChosen,
) async {
  final bytes = await showModalBottomSheet<Uint8List>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _XhsImportSheet(),
  );
  if (bytes != null) {
    onImageChosen(bytes);
  }
}

/// 原图字节缓存：双击查看与「开始还原」共用，避免同一张图下载两次
class _OrigCache {
  final Map<String, Uint8List> _map = {};
  Uint8List? get(String path) => _map[path];
  void put(String path, Uint8List bytes) => _map[path] = bytes;
}

class _XhsImportSheet extends StatefulWidget {
  const _XhsImportSheet();

  @override
  State<_XhsImportSheet> createState() => _XhsImportSheetState();
}

class _XhsImportSheetState extends State<_XhsImportSheet> {
  final _inputCtrl = TextEditingController();
  final _cache = _OrigCache();

  var _phase = _Phase.input; // 输入链接 / 解析中 / 缩略图选择
  XhsNote? _note;
  String? _error;
  int _selected = -1;
  var _downloading = false;

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
    if (text.isNotEmpty && extractXhsLink(text) != null) {
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
      final note = await fetchXhsNote(_inputCtrl.text);
      if (!mounted) {
        return;
      }
      setState(() {
        _note = note;
        _selected = note.images.length == 1 ? 0 : -1;
        _phase = _Phase.pick;
      });
    } on XhsLinkException catch (e) {
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

  /// 「开始还原」：下载选中图原图 → 关面板回传字节
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
    } on XhsLinkException catch (e) {
      if (mounted) {
        AppSnackBar.show(context, e.message);
        setState(() => _downloading = false);
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.show(context, '下载原图失败: $e');
        setState(() => _downloading = false);
      }
    }
  }

  Future<Uint8List> _ensureOriginal(XhsNoteImage img) async {
    final hit = _cache.get(img.originalPath);
    if (hit != null) {
      return hit;
    }
    final bytes = await downloadXhsOriginal(img);
    _cache.put(img.originalPath, bytes);
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.85;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.link, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _phase == _Phase.pick
                          ? (_note!.title.isEmpty ? '选择一张图纸' : _note!.title)
                          : '从小红书链接导入',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_phase == _Phase.pick)
                    IconButton(
                      tooltip: '重新输入链接',
                      onPressed: () => setState(() => _phase = _Phase.input),
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                ],
              ),
            ),
            Flexible(child: _buildBody()),
            if (_phase == _Phase.pick)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _selected >= 0 && !_downloading ? _confirm : null,
                    icon: _downloading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_downloading ? '正在下载原图…' : '开始还原'),
                  ),
                ),
              ),
          ],
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
              hintText: '粘贴小红书分享文案或链接\n（如 https://xhslink.cn/…）',
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
            '自动下载原图（免登录，画质比 App 内保存更好）',
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
                      img.thumbUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black12,
                        child: Center(
                          child: Icon(Icons.broken_image, color: Colors.black26),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 原始尺寸角标（页面元数据，一眼确认是高清原图）
              if (img.width > 0)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${img.width}×${img.height}',
                      style: const TextStyle(fontSize: 10, color: Colors.white),
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

  /// 双击缩略图 → 全屏看原图（可缩放，右上角下载）
  Future<void> _openViewer(int index) async {
    final img = _note!.images[index];
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LinkImageViewerPage(
          title: _note?.title ?? '',
          width: img.width,
          height: img.height,
          savePrefix: 'xhs',
          loadOriginal: () => _ensureOriginal(img),
        ),
      ),
    );
  }
}

enum _Phase { input, loading, pick }
