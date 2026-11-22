<#
.SYNOPSIS
  创建本项目的测试模拟器 bead_test（不需要 Android Studio，也不走 avdmanager）。

.DESCRIPTION
  AVD 本质是两个 ini 文本文件：
    %USERPROFILE%\.android\avd\<名称>.ini   指向数据目录
    <数据目录>\config.ini                   硬件参数
  磁盘镜像在首次开机时由模拟器自动生成。写入的 config.ini 取自主开发机
  bead_test：原有 26 项硬件参数原值照抄，分辨率、内存等参数在每台机器上都
  一致——full-flow-test.md 的坐标表全部按 1080x2340 实测。

  不要用 avdmanager（主开发机 2026-11-22 实测两个坑）：
    1. `avdmanager create avd` 报 "Cannot invoke IdDisplay.getId() because tag is
       null"（旧 cmdline-tools 读不懂新版 system-images 的 package.xml）；
    2. 它只要被加载，就会把机器上已有的 AVD 的 config.ini 重写成规范格式
       并补默认键——哪怕这次操作跟那个 AVD 无关。

  前置条件见 docs/test_setup.md：ANDROID_HOME 已设置，且已安装
  emulator 与 system-images;android-36;google_apis;x86_64。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\create_test_avd.ps1
  powershell -ExecutionPolicy Bypass -File scripts\create_test_avd.ps1 -Dir E:\avd\bead_test.avd
  powershell -ExecutionPolicy Bypass -File scripts\create_test_avd.ps1 -Force   # 只重写两个 ini，不动磁盘镜像
#>
param(
    [string]$Name    = "bead_test",
    [string]$Dir     = "D:\avd\bead_test.avd",
    [string]$SdkRoot = $env:ANDROID_HOME,
    [string]$IniDir  = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ---- 前置检查 ----
if (-not $SdkRoot) {
    throw "未设置 ANDROID_HOME（Android SDK 根目录）。先按 docs/test_setup.md 配好环境变量，或用 -SdkRoot 指定。"
}
$SdkRoot = $SdkRoot.TrimEnd("\")
$emu = Join-Path $SdkRoot "emulator\emulator.exe"
if (-not (Test-Path $emu)) {
    throw "找不到模拟器程序：$emu。先按 docs/test_setup.md 安装 SDK 包（emulator）。"
}
$sysdir = Join-Path $SdkRoot "system-images\android-36\google_apis\x86_64"
foreach ($f in "system.img", "kernel-ranchu") {
    if (-not (Test-Path (Join-Path $sysdir $f))) {
        throw "系统镜像不完整：缺少 $sysdir\$f。先按 docs/test_setup.md 安装 system-images;android-36;google_apis;x86_64。"
    }
}
if (-not (Test-Path ([IO.Path]::GetPathRoot($Dir)))) {
    throw "盘符不存在：$Dir。用 -Dir 指定一个剩余空间 >= 12GB 的路径。"
}
if ($Dir -match "[^\x20-\x7e]") {
    throw "路径只能用英文字母、数字和符号（不能有中文）：$Dir"
}
if ($Dir -match " ") {
    throw "路径不能含空格：$Dir"
}
# <名称>.ini 放在模拟器的 AVD 目录：设了 ANDROID_AVD_HOME 就用它，否则用默认的
# %USERPROFILE%\.android\avd（Windows 用户名含中文时可设 ANDROID_AVD_HOME=D:\avd 避开）
if (-not $IniDir) {
    $IniDir = if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME } else { Join-Path $env:USERPROFILE ".android\avd" }
}

# ---- 已存在则不覆盖 ----
$cfgPath = Join-Path $Dir "config.ini"
$iniPath = Join-Path $IniDir "$Name.ini"
if ((Test-Path $cfgPath) -or (Test-Path $iniPath)) {
    if (-not $Force) {
        Write-Output "已存在，未改动：$cfgPath"
        Write-Output "              $iniPath"
        Write-Output "要重建请加 -Force（只重写这两个 ini，不动磁盘镜像）。"
        exit 0
    }
}

# ---- config.ini：取自主开发机 D:\avd\bead_test.avd\config.ini ----
# 主开发机的 config.ini 只写了 26 项（分辨率/内存/GPU 等），hw.mainKeys、
# hw.dPad、hw.sdCard 等硬件开关靠模拟器默认值；这里把全部 37 项写成显式值，
# 换模拟器版本也不会变。hw.mainKeys=no = 屏内导航栏（主开发机实际就是
# 这种形态：截图底部有手势条）。
$config = @"
AvdId=$Name
PlayStore.enabled=false
abi.type=x86_64
avd.ini.encoding=UTF-8
disk.dataPartition.size=6442450944
fastboot.forceColdBoot=no
hw.accelerated.gpu.enabled=yes
hw.accelerated.gpu.mode=host
hw.accelerometer=yes
hw.audioInput=yes
hw.battery=yes
hw.cpu.arch=x86_64
hw.cpu.ncore=4
hw.dPad=no
hw.device.hash2=MD5:3274126e0242a0d86339850416b0ce34
hw.device.manufacturer=Google
hw.device.name=pixel_5
hw.gps=yes
hw.gpu.enabled=yes
hw.gpu.mode=host
hw.keyboard=yes
hw.lcd.density=440
hw.lcd.height=2340
hw.lcd.width=1080
hw.mainKeys=no
hw.ramSize=6144
hw.sdCard=yes
hw.sensors.orientation=yes
hw.sensors.proximity=yes
hw.trackBall=no
image.sysdir.1=system-images\android-36\google_apis\x86_64\
runtime.network.latency=none
runtime.network.speed=full
showDeviceFrame=no
tag.display=Google APIs
tag.id=google_apis
vm.heapSize=1024
"@

New-Item -ItemType Directory -Force $Dir, $IniDir | Out-Null
# UTF-8 无 BOM + LF 行尾：模拟器的 ini 解析器按原始字节读
[IO.File]::WriteAllText($cfgPath, (($config + "`n") -replace "`r`n", "`n"))
[IO.File]::WriteAllText($iniPath, "avd.ini.encoding=UTF-8`npath=$Dir`n")

Write-Output "已写入：$cfgPath"
Write-Output "已写入：$iniPath"
Write-Output "模拟器当前可见的 AVD："
& $emu -list-avds
Write-Output ""
Write-Output "下一步：emulator -avd $Name -no-snapshot   （首次开机要生成磁盘镜像，约 1-3 分钟）"
