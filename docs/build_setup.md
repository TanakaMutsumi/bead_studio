# 开发环境搭建（Windows，全新机器）

从零把「豆田」跑起来的完整步骤。已有 Flutter 环境的可直接看 [README](../README.md) 的构建命令。
要连模拟器测试环境一起搭（命令行装 Android SDK、建模拟器、带测试资料），接着看
[test_setup.md](test_setup.md)。

## 1. Flutter SDK

1. 下载 zip：https://docs.flutter.dev/get-started/install/windows/mobile
   （国内镜像可加速，见下方环境变量）
2. 解压到 **不含中文/空格的路径**，如 `D:\flutter`
3. 配置用户环境变量（PowerShell，无需管理员）：

```powershell
# Flutter 镜像（国内必须，否则 pub 下载超时）
[Environment]::SetEnvironmentVariable("PUB_HOSTED_URL", "https://pub.flutter-io.cn", "User")
[Environment]::SetEnvironmentVariable("FLUTTER_STORAGE_BASE_URL", "https://storage.flutter-io.cn", "User")

# PATH 追加 D:\flutter\bin
$p = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "D:\flutter\bin;$p", "User")
```

4. 重开终端验证：`flutter --version`

## 2. Android Studio（提供 Android SDK）

1. 下载安装：https://developer.android.com/studio （国内直连可用）
2. 首次启动向导：装 Android SDK + SDK Platform（选最新稳定版 API）+ Platform-Tools
3. 更多设置里装 **Android SDK Command-line Tools**（flutter doctor 需要它接受许可）

## 3. 自检

```bash
flutter doctor            # 按提示补缺项
flutter doctor --android-licenses   # 全部 y 接受许可
```

手机：设置 → 开发者选项 → USB 调试，数据线连电脑，弹窗允许调试。

## 4. 运行 / 打包

```bash
git clone https://gitee.com/TanakaMutsumi/bead_studio.git
cd bead_studio
flutter pub get          # 拉依赖（首次）
flutter run              # 连接的安卓真机上运行（热重载 r 键）
flutter build apk --release   # 产物 build\app\outputs\flutter-apk\app-release.apk
```

> **交付/分发用的 APK 必须是 `flutter build apk --release` 的全架构包**：
> `flutter run` 的产物只含本机（模拟器 x86）架构，真机装不上。

APK 直接发微信/网盘即可安装（需在手机上允许「安装未知来源」）。
