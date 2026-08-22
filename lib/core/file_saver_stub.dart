/// 非 web 平台占位（实际落盘逻辑在调用方，此桩不会被调用）
library;

import 'dart:typed_data';

/// 浏览器下载字节流（非 web 平台为空实现）
Future<void> downloadBytes(Uint8List bytes, String filename) async {}
