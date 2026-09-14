import 'package:flutter/material.dart';

/// 豆板配置页的通用对话框（从页面抽出，context 显式传入）
///
/// 确认框：否(false) / 是(true)；[cancelLabel] 非空时首个按钮是显式
/// 「取消」（返回 null，与点外部同义）——是/否/取消三键场景用
Future<bool?> confirmDialog(
  BuildContext context,
  String title,
  String content, {
  String? cancelLabel,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        if (cancelLabel != null)
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(cancelLabel),
          ),
        TextButton(
          onPressed: () => Navigator.pop(dctx, false),
          child: const Text("否"),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dctx, true),
          child: const Text("是"),
        ),
      ],
    ),
  );
}

/// 单行输入对话框，取消返回 null；[emptyError] 非空时空值点确定
/// 不关框、输入框下红字提示（豆板名必填，替代旧版静默关框无反应）
Future<String?> inputDialog(
  BuildContext context,
  String title,
  String hint,
  TextEditingController ctrl, {
  String? emptyError,
}) {
  return showDialog<String>(
    context: context,
    builder: (dctx) => StatefulBuilder(
      builder: (dctx, setDState) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hint,
            errorText: ctrl.text.trim().isEmpty ? emptyError : null,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setDState(() {}), // 清空/回填后刷新红字状态
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () {
              if (emptyError != null && ctrl.text.trim().isEmpty) {
                setDState(() {}); // 空名拦截：只刷红字不关框
                return;
              }
              Navigator.pop(dctx, ctrl.text);
            },
            child: const Text("确定"),
          ),
        ],
      ),
    ),
  );
}
