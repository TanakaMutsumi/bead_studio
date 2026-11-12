import 'package:flutter/material.dart';

import 'core/app_info.dart';
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
      home: const _SplashGate(child: HomePage()),
    );
  }
}

/// 启动加载页（2026-11-12 需求：加载界面图标下方显示应用名与版本号）。
///
/// Android 12+ 系统启动图强制圆形图标、API 不支持图下文字，故系统段
/// 保持图标，进 Flutter 后首帧接一版品牌加载页：图标 + 应用名 + 版本号
/// （白底，与系统启动图背景一致视觉连续），展示约 0.6s 后淡出。主页在
/// 覆盖层下同步构建预热，不增加实际等待
class _SplashGate extends StatefulWidget {
  final Widget child;

  const _SplashGate({required this.child});

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  var _fading = false;

  ///< 开始淡出（展示时长已到）

  var _gone = false;

  ///< 淡出完成，覆盖层移除

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() => _fading = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (!_gone)
          // 覆盖层存在期间挡住输入（避免加载页下误触主页卡片）
          AbsorbPointer(
            child: AnimatedOpacity(
              opacity: _fading ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              onEnd: () {
                if (_fading && mounted) {
                  setState(() => _gone = true);
                }
              },
              child: Container(
                color: Colors.white,
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      "assets/icon/app_icon.png",
                      width: 112,
                      filterQuality: FilterQuality.medium,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      kAppName,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "v$kAppVersion",
                      style: TextStyle(fontSize: 13, color: Colors.black45),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
