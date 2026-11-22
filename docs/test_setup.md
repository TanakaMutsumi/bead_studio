# 模拟器测试环境搭建（换电脑部署）

> 在一台新的 Windows 电脑上，从零搭到「模拟器跑起来、豆田装上、基准图就位、测试全绿」。
> 按顺序执行，每一步末尾都有验收命令。
>
> 版本号和路径全部来自主开发机（2026-11-22 实测）。**按同样的路径装**，仓库里写死的 adb 路径和
> 测试坐标表就能原样使用。各步骤在本机的验证情况见文末「维护约定」。
>
> 只需要能编译 App 的话看 [build_setup.md](build_setup.md) 就够了；本文多出来的是模拟器、
> 测试资料和测试口径。

## 1. 开工前

| 项 | 要求 | 原因 |
|---|---|---|
| 系统 | Windows 10 / 11 x64 | 主开发机是 Win11 23H2 |
| 内存 | ≥ 16GB | 模拟器本身占 6GB，Gradle 另要 2GB |
| 磁盘 | 剩余 ≥ 40GB | Flutter 3.3G + Android SDK 约 7G + 模拟器数据 8G + Gradle 缓存 6G 起 |
| 虚拟化 | BIOS 里已开启 Intel VT-x / AMD-V | 模拟器要硬件加速 |
| 测试资料包 | 从主开发机导出，见 §5 | 基准图不入库，仓库里没有 |

两台机器用同一套目录布局（没有 D 盘时怎么办见 §10）：

| 用途 | 路径 |
|---|---|
| Flutter SDK | `D:\flutter` |
| Android SDK | `D:\Android\Sdk` |
| 仓库 | `D:\code\bead_studio` |
| 模拟器数据 | `D:\avd\bead_test.avd` |

路径里不要有中文和空格。

命令块标 **PowerShell** 的在 PowerShell 里执行（Win10/11 自带 5.1 即可），标 **Git Bash** 的在
Git Bash 里执行。adb 相关操作统一用 Git Bash：[full-flow-test.md](../.claude/skills/full-flow-test.md)
的命令都按 Git Bash 写，PowerShell 5.1 给 adb 传参有引号被剥的坑。

## 2. 基础工具

### 2.1 Git for Windows

从 https://git-scm.com/download/win 安装，默认选项即可（主开发机 2.47.0）。它自带 Git Bash。

Gitee 推送大于 1MB 的文件会被网关掐断，先把缓冲区调大：

```powershell
git config --global http.postBuffer 52428800
```

### 2.2 Flutter SDK（钉在 3.47.1）

下载固定版本（国内镜像，1.9GB）：

`https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.1-stable.zip`

```powershell
# PowerShell：解压后得到 D:\flutter（用 7-Zip 解压到 D:\ 也一样）
tar -xf "$env:USERPROFILE\Downloads\flutter_windows_3.47.1-stable.zip" -C D:\

# 镜像和 PATH（用户级环境变量，不需要管理员）
[Environment]::SetEnvironmentVariable("PUB_HOSTED_URL", "https://pub.flutter-io.cn", "User")
[Environment]::SetEnvironmentVariable("FLUTTER_STORAGE_BASE_URL", "https://storage.flutter-io.cn", "User")
[Environment]::SetEnvironmentVariable("Path", "D:\flutter\bin;" + [Environment]::GetEnvironmentVariable("Path", "User"), "User")
```

**重开一个 PowerShell** 再验收：

```powershell
flutter --version      # Flutter 3.47.1 • channel stable，Dart 3.13.1
```

不要执行 `flutter upgrade`。版本一变，`flutter analyze` 的基线和依赖解析结果都可能跟着变。

### 2.3 JDK 17

安装 Microsoft Build of OpenJDK 17（https://learn.microsoft.com/java/openjdk/download ，主开发机是
17.0.20.1）。MSI 默认会设好 `JAVA_HOME`。重开 PowerShell 验收：

```powershell
& "$env:JAVA_HOME\bin\java.exe" -version      # openjdk version "17.0.x" ... LTS
```

### 2.4 Python、Pillow、numpy

测试里的像素分析和仓库里的生成脚本都要用。安装 python.org 的 Python 3，安装时勾选 Add to PATH：

```powershell
python -m pip install pillow numpy
python -c "import PIL, numpy; print(PIL.__version__, numpy.__version__)"      # 主开发机：12.2.0 2.4.4
```

## 3. Android SDK（命令行，不需要 Android Studio）

主开发机没有装 Android Studio，整套工具链都是命令行装的。

1. 下载 Command line tools：https://developer.android.com/studio 页面底部的
   「Command line tools only」里的 Windows 包（约 156MB）。
2. 解压得到 `cmdline-tools` 文件夹，把它放到 `D:\Android\Sdk\cmdline-tools\latest`。
   注意最后一层目录名必须是 `latest`，正确结果是
   `D:\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat`。
3. 环境变量（PowerShell），然后重开终端：

   ```powershell
   [Environment]::SetEnvironmentVariable("ANDROID_HOME", "D:\Android\Sdk", "User")
   [Environment]::SetEnvironmentVariable("Path", "D:\Android\Sdk\platform-tools;D:\Android\Sdk\emulator;" + [Environment]::GetEnvironmentVariable("Path", "User"), "User")
   ```

4. 安装 SDK 包并接受许可：

   ```powershell
   & "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat" "platform-tools" "emulator" "platforms;android-36" "build-tools;36.0.0" "system-images;android-36;google_apis;x86_64"
   & "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat" --licenses      # 一路回答 y
   ```

   下载慢或失败时挂代理：在命令里加上
   `--proxy=http --proxy_host=127.0.0.1 --proxy_port=<代理端口>`。

5. 验收：

   ```powershell
   & "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat" --list_installed
   ```

   对照主开发机：

   | 包 | 主开发机版本 | 用途 |
   |---|---|---|
   | platform-tools | 37.0.1 | adb |
   | emulator | 37.1.11 | 模拟器本体 |
   | platforms;android-36 | rev 2 | compileSdk / targetSdk（Flutter 3.47.1 的默认值是 36） |
   | build-tools;36.0.0 | 36.0.0 | 主开发机只装了这一个 build-tools 就能构建 |
   | system-images;android-36;google_apis;x86_64 | rev 7 | 模拟器用的 Android 16 镜像 |

   新机器装到的 emulator 和 platform-tools 会比表里的版本新，没有影响。两点要注意：

   - 系统镜像必须选 **Google APIs**，不能选 Google Play。Play 版不能 `adb root`，
     full-flow-test.md §0.2 的取证步骤用不了。
   - 不要装 NDK。项目没有原生代码，`android/app/build.gradle.kts` 里特意没声明 ndkVersion，
     装了是白白多占 2.2GB。

最后跑一次自检：

```powershell
flutter doctor -v
```

只需要这三项是 `[√]`：**Flutter**、**Windows Version**、**Android toolchain**（末尾应有
`All Android licenses accepted.`）。Chrome、Network resources、Visual Studio 三项可以不是绿的：
主开发机上 Chrome 和 Network resources 同样不是绿的，不影响安卓测试。

## 4. 虚拟化

BIOS 已开启虚拟化之后，用**管理员** PowerShell 打开「Windows 虚拟机监控程序平台」，然后重启电脑：

```powershell
dism.exe /online /enable-feature /featurename:HypervisorPlatform /all /norestart
```

重启后验收：

```powershell
emulator -accel-check      # WHPX(...) is installed and usable.
```

## 5. 仓库与测试资料

### 5.1 拉仓库

```powershell
New-Item -ItemType Directory -Force D:\code | Out-Null
git clone https://gitee.com/TanakaMutsumi/bead_studio.git D:\code\bead_studio
cd D:\code\bead_studio
```

### 5.2 测试资料（不入库，从主开发机带过来）

`.test/` 整个目录在 [.gitignore](../.gitignore) 里，新机器上没有。需要的只有下面这些文件，
外加主开发机的 `pubspec.lock`，一共约 5MB。

**主开发机**导出（PowerShell，仓库根目录）：

```powershell
tar -a -cf "$env:USERPROFILE\Desktop\bead_test_kit.zip" .test/test_pic5.png .test/wx1.jpg .test/wx2.jpg .test/wx_replica.py .test/wx_replica4.py .test/wx_replica6.py .test/legend_detect_sim.py .test/ruler_detect.py .test/row_probe6.py .test/annotate_q.py .test/ruler_touch_sim.py .test/text_dim_probe.py .test/gen_h2_pic.py .test/full_flow_test.md pubspec.lock
```

**新机器**导入（PowerShell，仓库根目录，zip 路径按实际情况改）：

```powershell
tar -xf "$env:USERPROFILE\Desktop\bead_test_kit.zip" -C D:\code\bead_studio
(Get-FileHash -Algorithm MD5 .test\test_pic5.png).Hash.ToLower()      # de94dca48fe2dc334f08b2655b6fc6ec
```

| 文件 | 作用 |
|---|---|
| `test_pic5.png`（2.7MB） | 全流程基准图 |
| `wx1.jpg`、`wx2.jpg` | 微信图基准，`dart run tool/legend_sim.dart` 的输入 |
| `wx_replica.py`、`wx_replica4.py`、`wx_replica6.py`、`legend_detect_sim.py` | 图例检测算法的 Python 复刻，离线对拍用 |
| `ruler_detect.py`、`row_probe6.py`、`annotate_q.py`、`ruler_touch_sim.py`、`text_dim_probe.py`、`gen_h2_pic.py` | 探针脚本 |
| `full_flow_test.md` | 早期的问题清单 |
| `pubspec.lock` | 主开发机的依赖解析结果。仓库不跟踪这个文件，带上它 `flutter pub get` 才会解析出同一批版本 |

### 5.3 拉依赖

```powershell
flutter pub get
```

## 6. 模拟器 bead_test

仓库里带了建模拟器的脚本，普通权限即可：

```powershell
# PowerShell，仓库根目录
powershell -ExecutionPolicy Bypass -File scripts\create_test_avd.ps1
emulator -list-avds          # 输出 bead_test
```

没有 D 盘，或 D 盘空间不够 12GB 时，用 `-Dir` 指定别的位置（纯英文、不含空格）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\create_test_avd.ps1 -Dir E:\avd\bead_test.avd
```

脚本做的事是手写两个文本文件（`%USERPROFILE%\.android\avd\bead_test.ini` 和
`D:\avd\bead_test.avd\config.ini`），磁盘镜像在首次开机时由模拟器自己生成。已经存在时脚本会跳过，
不会覆盖。

**不要用 `avdmanager`**。它有两个坑，都写在脚本头部，其中一条要记住：avdmanager 只要被加载，
就会把这台机器上已有 AVD 的 config.ini 重写成规范格式并补默认键，哪怕这次操作和那个 AVD 无关。

脚本里和测试直接相关的参数：

| 参数 | 值 | 影响 |
|---|---|---|
| `hw.lcd.width` / `hw.lcd.height` | 1080 × 2340（440dpi） | full-flow-test.md 的坐标表全部按它实测，分辨率不同整套坐标作废 |
| `hw.cpu.ncore` | 4 | |
| `hw.ramSize` / `vm.heapSize` | 6144 / 1024 | 大图识别对内存敏感，保持原值，调小后没有验证过 |
| `hw.keyboard` | yes | 电脑键盘可以直接输入 |
| `hw.mainKeys` | no | 屏内导航栏。手势条在 y=2304–2311，与主开发机截图一致 |
| `tag.id` | google_apis | 可以 `adb root` |

Windows 用户名含中文时，可以先设用户环境变量 `ANDROID_AVD_HOME=D:\avd` 再跑脚本，`.ini` 会放到
那里而不是用户目录（模拟器 37.1.11 实测认这个变量）。

### 开机

```powershell
emulator -avd bead_test -no-snapshot
```

首次开机要生成磁盘镜像并初始化系统，比平时慢，等几分钟到桌面。

**每次都用 `-no-snapshot`**。快照会把坏掉的图形状态和删过的文件一起带回来
（full-flow-test.md §5.4）。

等开机完成（Git Bash）：

```bash
export MSYS_NO_PATHCONV=1
ADB="/d/Android/Sdk/platform-tools/adb.exe -s emulator-5554"
$ADB wait-for-device shell 'until [[ $(getprop sys.boot_completed) == 1 ]]; do sleep 1; done'
```

验收（Git Bash）：

```bash
$ADB devices                                  # emulator-5554   device
$ADB shell wm size                            # Physical size: 1080x2340
$ADB shell getprop ro.build.version.sdk       # 36
$ADB root                                     # restarting adbd as root
```

关闭模拟器：`$ADB emu kill`。

## 7. 把豆田装到模拟器

```powershell
flutter run -d emulator-5554
```

首次构建要下载 Gradle 9.3.1 和依赖，需要几分钟。不需要热重载的话也可以只构建再安装：

```powershell
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

验收：模拟器里出现「豆田」，主页有四个入口。

镜像已经在仓库里配好，不用另外设置：Gradle 发行版走腾讯镜像
（`android/gradle/wrapper/gradle-wrapper.properties`），Maven 依赖走阿里云镜像
（`android/settings.gradle.kts`、`android/build.gradle.kts`）。构建卡住看 §11。

## 8. 测试怎么跑

命令都在仓库根目录执行。

| 层级 | 命令 | 通过标准（主开发机 2026-11-22 实测） |
|---|---|---|
| 静态检查 | `flutter analyze` | 没有 error。存量 1 条 warning + 89 条 info 共 90 条，不阻塞 |
| 单元 / 组件测试 | `flutter test -j 2` | `All tests passed!`，161 项，约 16 秒 |
| 全流程 UI 测试 | 对 Claude 说「走全流程」，或按 [full-flow-test.md](../.claude/skills/full-flow-test.md) 手动走 | test_pic5：图例 16 色 / 共 1336 颗，④ 总豆数 1307（基准见该文 §6） |
| 集成测试（可选） | `flutter test integration_test/legend_batch_test.dart -d emulator-5554` | 输出 `[batch]` 开头的汇总行供离线复核，本身不断言结果 |

两点注意：

- `flutter test` 的 `-j 2` 不能省。默认并发下最重的用例会挂死十几分钟，零输出。
- 集成测试跑完会把 App 从模拟器上卸载，之后要重新 `flutter run` 装回去。

## 9. 基准图进相册

全流程测试从相册选 `test_pic5.png`，所以要先推进模拟器并让媒体库索引到它（Git Bash）：

```bash
$ADB push "D:/code/bead_studio/.test/test_pic5.png" /sdcard/Pictures/
$ADB shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/test_pic5.png
$ADB shell "content query --uri content://media/external/images/media --projection _id:_data:date_added"
```

最后一条的输出里应有 `/sdcard/Pictures/test_pic5.png`。文件名保持纯英文：中文名会让上面那条广播
静默失效，图不在相册里。每次走流程前照 full-flow-test.md §0.1 检查相册第一格是不是它。

## 10. 换机器才会遇到的事

**路径。** 按 §1 的布局装，下面这些写死的地方就不用动。装在别处的话，是这些位置：

| 文件 | 写死的内容 |
|---|---|
| [CLAUDE.md](../CLAUDE.md) | adb 全路径 `/d/Android/Sdk/platform-tools/adb.exe` |
| [.claude/skills/project-status.md](../.claude/skills/project-status.md) §2 | 仓库路径、adb 路径 |
| [.claude/skills/full-flow-test.md](../.claude/skills/full-flow-test.md) §0、§4.2 | `$ADB` 别名、`cd /d/code/bead_studio/.test` |
| [scripts/push_pic.bat](../scripts/push_pic.bat) | `D:\Android\Sdk\platform-tools\adb.exe` |
| [scripts/subset_font.py](../scripts/subset_font.py) | `D:\code\bead_studio\...`（改字体子集时才会用到） |

用 Claude Code 驱动测试的话，开局直接告诉它实际的 SDK 路径和仓库路径。

**Claude 的本地记忆不随仓库走。** 主开发机 Claude 记忆里的环境类配方（模拟器联网、黑屏、adb 僵死等）
已经并进本文 §11。

**APK 签名。** release 包用的是 debug 签名，每台电脑一把钥匙。新机器打的包装不到已装着旧包的手机上，
要先卸载；两台机器出的包互相也覆盖不了。

**Gitee 推送。** 新机器第一次 push 会要求登录 Gitee。

## 11. 排障

| 现象 | 原因 | 处理 |
|---|---|---|
| `flutter doctor` 里 Chrome、Network resources 不是绿的 | 没装 Chrome、访问不到 maven.google.com | 忽略，与安卓测试无关 |
| 模拟器启动报 `x86_64 emulation currently requires hardware acceleration` | 没开虚拟化，或没开「Windows 虚拟机监控程序平台」 | 回 §4 |
| 启动报 `FATAL ... CPU Architecture 'arm' is not supported`，前面还有 `Failed to process .ini file ...\config.ini` | `.ini` 里的 `path=` 指错了目录（手写时反斜杠被吞） | `powershell -ExecutionPolicy Bypass -File scripts\create_test_avd.ps1 -Force` |
| 找不到 `emulator` 命令 | PATH 还没生效 | 重开终端；或用全路径 `D:\Android\Sdk\emulator\emulator.exe` |
| 模拟器全黑但 `adb shell` 还通；删过的图又出现；清掉的状态回来了 | 快照带回了坏状态 | `$ADB emu kill`，再用 `-no-snapshot` 冷启动。判别方法：按 HOME 键后截屏，HOME 也黑才是模拟器的问题 |
| 模拟器里完全断网（ping 不通、DNS 报错） | 宿主机的 Clash 类代理开了 TUN 模式，劫持了模拟器的网络 | `$ADB shell settings put global http_proxy 10.0.2.2:<宿主机代理端口>`（主开发机是 7890）。撤销：`settings put global http_proxy :0`。小红书 / 抖音链接导入测试需要这一步 |
| `flutter test ... -d emulator-5554` 卡在 `Installing...` 不动 | 电脑侧 adb 服务僵死 | `adb kill-server`，用 `adb install -r` 确认能装，再重跑 |
| `flutter test` 挂死十几分钟，零输出 | 默认并发下的调度问题 | 加 `-j 2` |
| `flutter test` 编译期失败 | 可用内存被模拟器和编辑器吃光 | 关掉模拟器再跑。主开发机有过可用内存只剩 0.7GB 时编译失败的记录 |
| Gradle 构建卡死（java 进程 CPU 长时间是 0） | Gradle daemon 挂死 | 结束所有 java 进程后重试。成功构建过一次之后，连续卡死可以走离线构建：在 `android` 目录执行 `.\gradlew.bat assembleDebug -Ptarget-platform=android-x64 --offline --no-daemon` |
| 构建卡在下载依赖 | 国内直连 Google / Maven 仓库慢或超时 | 仓库里已配阿里云镜像。仍然不行，在 `%USERPROFILE%\.gradle\gradle.properties` 里填代理（`systemProp.https.proxyHost` 和 `systemProp.https.proxyPort`）。主开发机的经验是镜像比代理稳 |
| `avdmanager create avd` 报 `Cannot invoke IdDisplay.getId() because "tag" is null` | 旧版 cmdline-tools 读不懂新版镜像的元数据 | 别用 avdmanager，用 `scripts\create_test_avd.ps1` |
| PowerShell 里 `adb exec-out screencap -p > x.png` 得到打不开的 PNG | PowerShell 5.1 的 `>` 按文本处理，毁掉二进制 | 截图在 Git Bash 里做，或按 full-flow-test.md §4.2：先 `adb shell screencap -p /sdcard/s.png` 再 `adb pull` |

## 12. 主开发机参考环境

| 项 | 值 |
|---|---|
| 系统 | Windows 11 家庭中文版 23H2（10.0.22631），16GB 内存 |
| Flutter | 3.47.1 stable（Dart 3.13.1） |
| JDK | Microsoft OpenJDK 17.0.20.1，通过 `JAVA_HOME` 指定 |
| Android SDK | `D:\Android\Sdk`（`ANDROID_HOME`），包清单见 §3 |
| Android Studio | 未安装 |
| 模拟器 | emulator 37.1.11；AVD `bead_test`，数据目录 8.4GB |
| 加速 | Windows Hypervisor Platform（WHPX） |
| Git | 2.47.0.windows.2 |
| Python | 3.14.4，Pillow 12.2.0，numpy 2.4.4 |
| Node | 24.14.0，只有 `scripts/serve_web.mjs` 用，安卓测试不需要 |

磁盘占用：Flutter 3.3G，Android SDK 约 7G（系统镜像 4.3G、cmdline-tools 1.2G、emulator 1.1G、
其余 0.4G），模拟器数据 8.4G，Gradle 缓存 6.3G。

## 维护约定

环境有变化时同步更新本文和 [scripts/create_test_avd.ps1](../scripts/create_test_avd.ps1)：
升 Flutter 版本、换系统镜像版本、改模拟器参数、测试基线数字变化。

2026-11-22 在主开发机上实际执行过的：

- §3 的包清单（`sdkmanager --list_installed` 和 `--list`）和 `flutter doctor -v` 的输出
- §4 的验收命令 `emulator -accel-check`
- §5 的资料包导出、导入（md5 回环一致）
- §6 的脚本：已存在时跳过且不改动原文件、五种错误输入会被拦下、创建后模拟器能解析出
  `x86_64` 和 `1080x2340`
- §8 的基线数字：`flutter analyze` 90 条、`flutter test -j 2` 161 项全过
- §11 里「`path=` 写错」那一行的报错原文

没有在主开发机上重做的（那边已经装好，磁盘和内存也不允许再来一遍）：各工具的首次安装、
模拟器首次开机、开机后的验收命令、`flutter run` 首次构建、集成测试命令。
在新机器上第一次走通之后，把实际的耗时和踩到的坑回填到本文。
