import 'package:flutter/material.dart';

import 'features/home/home_page.dart';

/// 路由观察者：页面间 push/pop 的可见性通知（豆板选择页靠 didPopNext
/// 在从板设置/拼豆页返回时刷新列表——2026-11-11 拼豆进度记忆链路）
final RouteObserver<PageRoute<dynamic>> routeObserver =
    RouteObserver<PageRoute<dynamic>>();

void main() {
  runApp(const BeadStudioApp());
}

class BeadStudioApp extends StatelessWidget {
  const BeadStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "豆田",
      debugShowCheckedModeBanner: false,
      navigatorObservers: [routeObserver],
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4FA8E8),
        useMaterial3: true,
        brightness: Brightness.light,
        fontFamily: "NotoSansSC", // 本地打包字体，避免 web 端从 gstatic 拉中文分片被墙
      ),
      // Android 15 起强制 edge-to-edge：窗口会画到三键/手势导航栏后面，
      // 内容被系统导航栏挡住。全局包一层 SafeArea 让整个导航区（含各页面、
      // 底部弹窗、snackbar）避开系统栏；露出的条带用 scaffold 背景色填充。
      // SafeArea 只消费 padding，键盘（viewInsets）仍由 Scaffold 正常处理。
      builder: (context, child) {
        return Container(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: SafeArea(top: false, child: child!),
        );
      },
      home: const HomePage(),
    );
  }
}
