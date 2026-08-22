/// 跨平台文件保存入口：web 走浏览器下载，非 web 由调用方直接写文件
library;

export 'file_saver_stub.dart' if (dart.library.html) 'file_saver_web.dart';
