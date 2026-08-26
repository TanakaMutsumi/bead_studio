/// web 平台：用隐藏 <a> 标签触发浏览器下载
library;

import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

/// 浏览器下载字节流为文件
Future<void> downloadBytes(Uint8List bytes, String filename) async {
  final encoded = base64Encode(bytes);
  final anchor = html.AnchorElement(
    href: 'data:application/octet-stream;base64,$encoded',
  )..download = filename;
  html.document.body?.children.add(anchor);
  anchor.click();
  anchor.remove();
}
