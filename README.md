# 豆田 (Bead Studio)

图片 → 拼豆图案 的安卓工具（Flutter）。

## 功能（v0.1 MVP）

| 模块 | 说明 |
|------|------|
| 图片导入 | 相册 / 拍照，自动取中心正方形 |
| 像素化 | 盒式均值缩放到板尺寸（26×26 / 29×29 / 52×52 / 78×78），源头抑制采样噪声 |
| 调色板量化 | Lab 空间最近邻匹配（感知均匀，优于 RGB 距离） |
| 转换风格 | 色块（默认：保边平滑 + 近似色统一 + 孤立点清除，相近色融合成整块）/ 细节（保留微小色差，适合线稿） |
| 画布编辑 | 画笔 / 橡皮 / 油漆桶（连通域填充）/ 撤销（50 步） |
| 本地草稿 | JSON 自动保存/恢复 |
| 用料统计 | 每种颜色颗数 + 总数 |
| 导出 | PNG（带网格线、每 10 格加粗） |

> 演示调色板为 40 色自拟近似值（`lib/data/demo_palette.dart`）。
> 正式版应实测采购珠子颜色生成色卡 JSON 加载。

## 环境安装（首次）

### 1. Flutter SDK

1. 下载 zip：https://docs.flutter.dev/get-started/install/windows/mobile
   （国内镜像可加速，见下方环境变量）
2. 解压到 **不含中文/空格的路径**，如 `D:\flutter`
3. 配置用户环境变量（PowerShell，管理员不必）：

```powershell
# Flutter 镜像（国内必须，否则 pub 下载超时）
[Environment]::SetEnvironmentVariable("PUB_HOSTED_URL", "https://pub.flutter-io.cn", "User")
[Environment]::SetEnvironmentVariable("FLUTTER_STORAGE_BASE_URL", "https://storage.flutter-io.cn", "User")

# PATH 追加 D:\flutter\bin
$p = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "D:\flutter\bin;$p", "User")
```

4. 重开终端验证：`flutter --version`

### 2. Android Studio（提供 Android SDK）

1. 下载安装：https://developer.android.com/studio （国内直连可用）
2. 首次启动向导：装 Android SDK + SDK Platform（选最新稳定版 API）+ Platform-Tools
3. 更多设置里装 **Android SDK Command-line Tools**（flutter doctor 需要它接受许可）

### 3. 自检

```bash
flutter doctor            # 按提示补缺项
flutter doctor --android-licenses   # 全部 y 接受许可
```

手机：设置 → 开发者选项 → USB 调试，数据线连电脑，弹窗允许调试。

## 运行 / 打包

```bash
cd D:\code\bead_studio
flutter pub get          # 拉依赖（首次）
flutter run              # 连接的安卓真机上运行（热重载 r 键）
flutter build apk --release   # 产物 build\app\outputs\flutter-apk\app-release.apk
```

APK 直接发微信/网盘即可安装（需在手机上允许"安装未知来源"）。

## 代码结构

```
lib/
├── main.dart                    入口 + 主题
├── core/
│   ├── palette.dart             BeadColor / BeadPalette 调色板模型
│   ├── quantizer.dart           Lab 转换 + 最近邻 + 色块统一（保边平滑/近似色合并/孤立点清除）
│   ├── pixel_engine.dart        解码→裁剪→缩放→量化 完整管线
│   ├── pattern_model.dart       图案网格 + 油漆桶 + 统计 + 序列化 + PNG 导出
│   └── draft_store.dart         草稿 JSON 存取
├── data/
│   └── demo_palette.dart        演示 40 色（自拟值，正式版换实测色卡）
└── features/
    ├── import/import_page.dart  导入页（选图/尺寸/转换风格）
    ├── editor/
    │   ├── editor_page.dart     编辑器（工具/颜色条/撤销/保存/导出/统计入口）
    │   └── grid_painter.dart    CustomPainter 网格渲染
    └── stats/stats_page.dart    用料统计
```

## 后续路线（对照原版待补）

- [ ] 交互式裁剪（选区域而非固定中心方形）
- [ ] 矩形板（非正方形）支持
- [ ] 编辑器：旋转 / 镜像 / 批量换色 / 改尺寸重排 / 图层
- [ ] 调色板管理（多套色卡切换、按品牌加载）
- [ ] 导出分享（系统分享面板，需 share_plus 插件）
- [ ] （可选）3D 立体预览（WebView + WebGL 自研 shader）
- [ ] （可选）OCR 实物还原图案（需训练分类模型）
