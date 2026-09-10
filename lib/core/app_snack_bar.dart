import 'dart:async';

import 'package:flutter/material.dart';

/// 顶部滑入的轻提示——全仓统一的提示通道（替代 SnackBar）
///
/// SnackBar 固定从底部弹出，会挡住页面底部的操作按钮（「开始转换」
/// 「开始拼豆」「导入作品」等都排布在页面底部），用户须等提示消失
/// 才能继续操作。本组件从顶部（AppBar 下缘）滑入，不占底部空间；
/// 提示条本身 IgnorePointer，不拦截其覆盖区域的点击。
class AppSnackBar {
  static OverlayEntry? _entry;

  ///< 当前显示中的提示（同时最多一条）
  static Timer? _timer;

  ///< 自动消失计时器

  /// 显示一条提示，3 秒后自动消失；新提示直接顶替旧提示
  static void show(BuildContext context, String message) {
    dismiss();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return;
    }
    _entry = OverlayEntry(builder: (_) => _TopTip(message: message));
    overlay.insert(_entry!);
    _timer = Timer(const Duration(seconds: 3), dismiss);
  }

  /// 立即收起当前提示
  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

/// 顶部胶囊提示条：从 AppBar 下缘滑入，深底白字，宽度随内容自适应
class _TopTip extends StatelessWidget {
  final String message;

  ///< 提示文案（支持插值字符串）
  const _TopTip({required this.message});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          // AppBar 下缘对齐（无 AppBar 的页面也统一此高度，离状态栏足够远）
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + kToolbarHeight),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            builder: (_, t, child) => Transform.translate(
              offset: Offset(0, -36 * (1 - t)),
              child: Opacity(opacity: t, child: child),
            ),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(24),
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
