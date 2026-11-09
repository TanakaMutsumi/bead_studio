---
name: full-flow-test
description: 拼豆 App（bead_studio）五步还原全流程自动化测试：adb 驱动模拟器走 选图→框图例→九宫格→框主体→识别→保存→拼豆，含坐标表/页面判别/坑清单。触发词：「走全流程」、「全流程测试」、「bead全流程」、「走流程测试」。
---

# 拼豆 App 全流程测试（full-flow-test）

> 多轮实测沉淀的可复用操作手册（模拟器 emulator-5554，1080×2340）。
> **每次走流程前先读本文件**；发现问题/修复后**必须回来更新 §7 修改记录与相关章节**。
> 问题清单跟踪在 `.test/full_flow_test.md`（本文件只管怎么测，那文件管还有什么没修）。

---

## 0. 环境准备

```bash
# 每次 Bash 会话开头（adb 命令内含 /sdcard 远端路径，防 MSYS 转换）
export MSYS_NO_PATHCONV=1
ADB="/d/Android/Sdk/platform-tools/adb.exe -s emulator-5554"

# 基准测试图：test_pic5.png（1440×2100，16 色图例，2026-08-27 基准图）
# 已在模拟器相册就位；若被清，重推：
$ADB push "D:/code/bead_studio/.test/test_pic5.png" /sdcard/Pictures/
$ADB shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
  -d file:///sdcard/Pictures/test_pic5.png

# 启动 App（冷启动，等 ~5s 到主页）
$ADB shell am force-stop com.beadstudio.bead_studio
$ADB shell am start -n com.beadstudio.bead_studio/.MainActivity
```

- 工作目录固定 `cd /d/code/bead_studio/.test`（临时文件用相对路径，/tmp 不跨 Bash 调用持久）
- **adb pull 的本地路径必须 `D:/...` Windows 风格**——`/d/...` msys 风格间歇性报 "cannot create file/directory"
- 清空测试数据（作品/豆板/app 数据）：`$ADB shell pm clear com.beadstudio.bead_studio`；相册清理直接 `rm /sdcard/Pictures/*.png` 后重启模拟器让 MediaStore 重建索引

### 0.1 走流程前必做：相册污染检查（②定案教训，2026-09-11）

**相册第一格 = date_added 最新条目**。调试期 screencap 到 `/sdcard/` 根目录的截图会被 MediaStore 索引并抢占第一格——曾导致 tap(539,1583) 选到 snap_snack.png（还原页自己的截图、内嵌 test_pic5 缩图），后续识别全程跑在"截图套图"上，自动框选位置随截图布局平移 ~180px，表象酷似"算法非确定"（实为输入图不同，算法两次都正确）。

```bash
# 1. 列出全部图片条目，确认最新（_id 最大/date_added 最新）的是 test_pic5
$ADB shell "content query --uri content://media/external/images/media --projection _id:_data:date_added"
# 2. 若根目录有调试截图残留：rm 后重启模拟器（死条目根治，见 §5.4）
$ADB shell "rm -f /storage/emulated/0/snap_*.png /storage/emulated/0/ld_*.png /storage/emulated/0/exp_*.png"
$ADB reboot   # MediaProvider 重建索引
```

### 0.2 载入图铁证取证：image_picker cache（app 实际拿到的字节）

`/data/data/com.beadstudio.bead_studio/cache/<uuid>/<MediaStore_id>.<ext>` 是 image_picker 把选中图拷进 app cache 的会话目录——**文件名即所选条目的 MediaStore _id**，与 0.1 的 query 结果对照即可铁证"这次到底选了哪张"（adb root 后可直读）：

```bash
$ADB shell "ls -la /data/data/com.beadstudio.bead_studio/cache/*/"   # 每个 UUID 目录一个所选文件
$ADB pull /data/data/com.beadstudio.bead_studio/cache/<uuid>/<id>.png D:/code/bead_studio/.test/picked_<id>.png
# md5 对比 .test/test_pic5.png（de94dca48fe2dc334f08b2655b6fc6ec）即知是否本尊
```

---

## 1. dump 解析模板（每次验证页面状态用）

```bash
$ADB shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
cd /d/code/bead_studio/.test && $ADB shell cat /sdcard/ui.xml > ui_now.xml
python -c "
import re
xml = open('ui_now.xml', encoding='utf-8', errors='ignore').read()
for n in re.findall(r'<node[^>]*/?>', xml):
    b = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', n)
    if not b: continue
    y=(int(b.group(2))+int(b.group(4)))//2; x=(int(b.group(1))+int(b.group(3)))//2
    t = re.search(r'text=\"([^\"]*)\"', n); d = re.search(r'content-desc=\"([^\"]*)\"', n); c = re.search(r'class=\"([^\"]*)\"', n)
    txt = (t.group(1) if t else '') or (d.group(1) if d else '')
    cls = c.group(1).split('.')[-1] if c else ''
    if txt or 'Edit' in cls:
        print(('%d %d %s %r' % (y, x, cls, txt[:60])).encode('ascii','backslashreplace').decode('ascii'))
"
```

- 输出格式 `y x 类名 repr(文本)`，坐标即节点中心，直接用于 tap
- **Flutter 按钮文本常在 content-desc 属性**（text 属性常为空），解析模板已兼容
- **dump 的 x 坐标对 Flutter 节点不可信**（曾报 813/1816 越界）、**y 坐标可信**——tap 前优先用文本行回读的真实中心，行内 x 坐标存疑时以页面布局推算
- GBK 控制台下中文必须 `ascii backslashreplace` 转义再 print（模板已含）
- dump 偶发空输出（对话框切换中节点树未刷新）：重 dump 一次或 PIL 补充判读

---

## 2. 全流程步骤（主页 → 图纸还原 → 保存 → 直接开始拼豆 → 拼豆页）

流程口径：**保存作品后跳过编辑器，直接进板设置开始拼豆**。

### 2.1 主页 → 图纸还原 → 选图

| 步骤 | 操作 | 坐标 | 等待/验证 |
|------|------|------|-----------|
| 1 | 主页点「图纸还原」 | (799,813) | dump 见 AppBar「图纸还原 · 选图」 |
| 2 | 点「从相册选择图纸」 | (540,1285) | 相册打开（选图页现 4 钮纵排：相册 1285 / 拍照 1450 / 小红书 1615 / 抖音 1780，均 x=540，2026-11-06 加抖音钮后实测；**误点拍照会进相机**——y 抄旧值/猜值是高发错误，tap 前先 dump） |
| 2.5 | **选图前验证相册第一格**（§0.1 query，最新条目须是 Pictures/test_pic5.png） | — | 条目不对先清理，勿盲选 |
| 3 | 选测试图（相册第一张网格位） | (177,1583) | sleep 5；解码后进①框图例，AppBar「① 框图例」 |

> **相册第一格坐标 (177,1583)，不是屏幕中间 (539,1583)**——系统 PhotoPicker 是 3 列网格，第一张在左列；旧值 (539,1583) 是老版相册的单列大图时代实测，已作废（曾致整链 tap 落空白全流程走不动）。PhotoPicker 属系统组件，dump 坐标可信（x/y 都可用）；每轮 tap 前以 dump 实测为准。
| 3.5 | **选图后验证载入的是本尊**（可选铁证）：按 §0.2 列 picker cache 最新 UUID 目录，文件名应为 test_pic5 的 _id（清干净后通常 _id=83） | — | 或按 §6 特征反查：载入 snap 类 1080×2340 截图时自动框选落 y≈1500-1588（显示坐标随缩放换算），图例带 [1510,1576]、h/w=2.167 |

> 载入即自动预框图例（_autoDetectLegend 游程法）；若失败提示"未识别到图例区"，手动拖框或点「自动框选图例区」按钮/AppBar 魔法棒重试。

### 2.2 ① 框图例 → 识别

| 步骤 | 操作 | 坐标 | 验证 |
|------|------|------|------|
| 4 | 「识别图例」 | (413,2241) | sleep 4（OCR 慢）；dump 见「图例 N 色」摘要行 + 清单 |
| 4' | 或「跳过图例」 | (925,2241) | 直接进② |

test_pic5 基准：16 色图例，识别后清单应约 16 条（H7 黑 343 颗等为大量程色）。

### 2.3 ② 九宫格对齐

| 步骤 | 操作 | 坐标 | 验证 |
|------|------|------|------|
| 5 | 「下一步：九宫格对齐」 | (540,2241) | 自动检测格距 ~2s（compute isolate，主图用自相关版） |
| 6 | 「下一步：框选主体」 | (540,2241) | dump 见 AppBar「③ 框选主体」 |

### 2.4 ③ 框选主体 → 开始识别

| 步骤 | 操作 | 坐标 | 验证 |
|------|------|------|------|
| 7 | （修复①回归点）进③即自动框选主体 | — | hint「将按 N 行 × M 列切分主体」+ SnackBar「已自动框选主体」；**大图识别 sleep 7 不够要 12+**（test_pic5 45×50=2250 格实测 ~19s）；检测失败才手动拖框（无选区时按钮「自动框选主体」在屏） |
| 8 | 「开始识别」 | (796,2230) | sleep 按格子数给（小图 6 / 2250 格 20）；dump 见 AppBar「④ 识别复核」 |

### 2.5 ④ 复核 → 保存作品 → 直接开始拼豆

| 步骤 | 操作 | 坐标 | 验证 |
|------|------|------|------|
| 8.5 | （修复②回归点）dump 验证 AppBar **双入口**：左上「返回上一步」(77,213) + 右上「退出图纸还原」✕(1014,213)（pick 步两者皆无）；点 ✕ 弹「退出图纸还原？」确认框（取消 584,1359 / 退出 799,1359），点取消留在④ | — | dump 检查 |
| 9 | 「保存作品」 | (360,2241) | dump 见「保存作品」命名框 |
| 10 | 点 EditText → 清空 → 输名 | (540,1172)；输名序列见 §5.2 | dump EditText text='tb2' |
| 11 | 「保存」 | (754,1381) | dump 见「保存成功」框 |
| 12 | 「直接开始拼豆」 | (702,1332) | sleep 3；进板设置页（见 §2.6） |

### 2.6 板设置页 → 开始拼豆（对话框链，**每步 dump 验证后再 tap**）

| 步骤 | 操作 | 坐标 | 验证（dump 必须见到才继续） |
|------|------|------|---------------------------|
| 13 | 「开始拼豆」 | (719,2241) | 「保存并开始拼豆？」+ 否(573,1332)/是(771,1332) |
| 14 | 「是」 | (771,1332) | sleep 3 |
| 15 | 若板未命名→「保存豆板」命名框 | EditText(540,1172)/确认(754,1381) | dump 见标题「保存豆板」 |
| 16 | 输名序列 + 「确认」 | 同 §5.2；tap (754,1381) | 空名有框内红字拦截（⑦已修） |
| 17 | 验证进拼豆页 | — | AppBar「拼豆 · <作品名>」+「板 52×52 · 已放 0/N」+ 色条 |

### 2.7 拼豆页验证点

- dump：AppBar `拼豆 · <作品名>`（**标题是作品名不是板名**）、信息行 `板 52×52 · 每5格加粗 · 已放 0/N`、色条 `H22 11/11` 等（id 颗数/总数）
- PIL 色块图：深底(30,30,30) 大片黑区 + 右侧 ZoomControls 蓝钮列 + 底部色条彩块
- 点色再点格 = 标记已放（绿框+对勾）；back 自动保存进度（PopScope）

### 2.8 收尾（可选回归）

- 拼豆页 back → 回板设置页（进度已自动保存）
- 板设置 back → 回「保存成功」前的还原页（已知问题⑥：直接开始拼豆后 RestorePage 仍在栈内）

---

## 3. 全部实测坐标表（1080×2340；1080×2280 时代实测值沿用，重点控件已复核）

### 主页
| 控件 | 坐标 |
|------|------|
| 开始拼豆 | (281,813) |
| 图纸还原 | (799,813) |
| 图片转换 | (281,1816) |
| 我的作品 | (799,1816) |

### 图纸还原页（按阶段）
| 控件 | 坐标 |
|------|------|
| 选图页 从相册选择图纸 | (540,1285) |
| 选图页 拍照图纸（勿误点） | (540,1450) |
| 选图页 小红书链接导入 | (540,1615) |
| 选图页 抖音链接导入 | (540,1780) |
| 相册第一张（PhotoPicker 3 列网格） | (177,1583) |
| ①/③/④ 左上 返回上一步 | (77,213) 固定（leading 位） |
| ①/③/④ 右上 退出图纸还原 ✕ | (1014,213) 固定（actions 末位，pick 步无） |
| 退出确认框 取消/退出 | (584,1359)/(799,1359) |
| ③ 自动框选主体（按钮，仅无选区时显示） | (540,2087) |
| ① 自动框选图例区（左半）/ 清除选框（右半） | (275,2087)/(805,2087)（布局推算值，tap 前 dump 实测） |
| ① 自动框选图例（AppBar 魔法棒） | (882,213)（箭头750/魔法棒882/色卡1014 同排） |
| ① 识别图例 | (413,2175)（2026-11-06 实测；旧表 2241，底行整体漂移 ~66px——每次以 dump 为准） |
| ① 跳过图例 | (925,2175) |
| ② 下一步（对齐） | (540,2175) |
| ③ 开始识别 | (796,2164) |
| ④ 全选当前色 | (211,2021) |
| ④ 清除选中(N) | (569,2021) |
| ④ 归类到…（Wrap 折行后第二行） | (212,2087) |
| ④ 每行N格下拉（截图墙模式，缩放条左端；总览模式不显示） | (175,1490)（2026-11-06 实测 bounds [44,1453][307,1527]，选项 4/5/6/8/10/12） |
| ④ 保存作品 | (360,2175) |
| ④ 进编辑器 | (867,2175) |
| 命名框 EditText | (540,1172)（无键盘时；弹键盘后 ~821，一律 dump 实测） |
| 命名框 保存 | (754,1381)（弹键盘后 ~1031） |
| 保存成功 留在本页 | (387,1332) |
| 保存成功 直接开始拼豆 | (702,1332) |

### 豆板选择页（BoardSelectPage，主页「开始拼豆」第一跳）
| 控件 | 坐标 |
|------|------|
| AppBar 新建空板 | (1014,213) |
| 板卡片（第一格，含缩略图+名称） | (191,525)——**卡片中心在网格列内非屏幕中线**，dump 取 clickable 节点 bounds 再 tap |
| 卡片角标菜单（打开/重命名/删除） | 卡片右上 (约 x+140,y-160)，dump 实测 |
| 空板自动跳转 | 首次加载列表为空 → 自动 pushReplacement 新板设置（无板时代旧直达习惯） |

### 板设置页（BoardSetupPage）
| 控件 | 坐标 |
|------|------|
| 移除选中作品 | (882,213) |
| 豆板菜单 | (1014,213) |
| 开始拼豆 | (719,2241) |
| 添加作品 | (212,2241) |
| ZoomControls 放大/缩小/还原（画布与底栏间外置条） | (769,2112)/(879,2112)/(989,2112) |
| 保存并开始拼豆 是/否 | (771,1332)/(573,1332) |
| 保存豆板 EditText/取消/确认 | dump 实测为准（IME 顶起会整体上移，本轮 821/539/754,1058），标题「保存豆板」 |
| 删除作品 否/是 | (618,1359)/(816,1359)，标题 (540,1029) |

### 拼豆页（AssemblePage）
| 控件 | 位置 |
|------|------|
| AppBar 标题 | `拼豆 · <作品名>`（y≈344） |
| 保存进度 | AppBar 最右 (1014,213)，actions 仅此一钮 |
| 粗框线颜色圆钮 | 信息行 (606,356)，点开共用色板 BottomSheet（8 圆钮两行 y1949/2103，会话内生效不落盘） |
| 显示/隐藏未选中色号文本 | 信息行右 (700,356)，常显 |
| 只显示色号/横向排列/竖向排列 | 信息行最右 (895,356)，常显 |
| ZoomControls 放大/缩小/还原 | 画布与色条间外置条：(769,2079)/(879,2079)/(989,2079)（AppBar 顶置离图太远已撤） |
| 色条 | 底部 y≈2235 横排，块宽 48 |

---

## 4. 页面判别方法

### 4.1 dump 文本判别（首选）

| 页面 | 特征节点 |
|------|---------|
| 主页 | 四大按钮文本 |
| 还原① | AppBar `图纸还原 · ① 框图例` |
| 还原④ | `④ 识别复核` + 「保存作品」「进编辑器」 |
| 板设置 | `添加作品`+`开始拼豆` 底部双钮 |
| 拼豆页 | `拼豆 · ` 标题 + `板 52×52` 信息行 + 色条 `11/11` |
| 命名框 | 标题 `保存作品`/`保存豆板` + EditText + 保存/确认 |

### 4.2 PIL 色块图（dump 无文本节点时兜底）

```bash
$ADB shell screencap -p /sdcard/s.png && $ADB pull /sdcard/s.png D:/code/bead_studio/.test/s.png >/dev/null
cd /d/code/bead_studio/.test && python -c "
from PIL import Image
im = Image.open('s.png').convert('RGB')
sm = im.resize((48,36), Image.BILINEAR)
chars = []
for py in range(36):
    row = ''
    for px in range(48):
        r,g,b = sm.getpixel((px,py))
        mx,mn = max(r,g,b), min(r,g,b)
        if mx>230 and mn>210: c='.'
        elif mx<50: c='#'
        elif b>r+30 and b>g+10: c='B'
        elif r>g+40 and r>b+40: c='R'
        elif g>r+30 and g>b+30: c='G'
        elif mx-mn<25: c='g'
        else: c='o'
        row += c
    chars.append(row)
print('\n'.join(chars))
"
```

- 对话框：浅灰底 + 白卡（大块 g 中嵌 . 行）+ 蓝钮 B 块
- 键盘：底部 ~40% 高密 . 与 g 相间条带
- 拼豆页：板区大片 # + 右缘 B 列（ZoomControls）+ 底部彩条
- **禁止用 Read 工具看截图 PNG**（CDN 缓存污染前科，曾整轮假结论）——一律 PIL 像素分析（色块图/直方图/行剖面/diff）

---

## 5. 坑与规矩（实测教训，必读）

### 5.1 对话框操作三规矩

1. **每个对话框操作前必须 dump 验证目标按钮节点存在后再 tap**——盲 tap 会点在弹出动画间隙/切换中的旧页面上，状态机错位后连锁误触。
2. **禁用 keyevent 111 (ESC)**——ESC 收 IME 键盘的同时会 dismiss 整个 Flutter 对话框。收键盘只能 tap 对话框空白或直接 tap 确认按钮。
3. **键盘弹出后对话框按钮位置可能被顶起**——输名后重新 dump 找按钮实际 bounds。

### 5.2 输名可靠序列（EditText 预置默认名时）

```bash
$ADB shell input tap 540 1172        # 点 EditText 聚焦
sleep 1
$ADB shell input keyevent 123        # MOVE_END 光标到尾
# DEL×8（keyevent 67）；IME composing 下盲删会残留/错位
sleep 1
$ADB shell input text tb2            # 纯 ASCII 名（中文 input text 不支持）
sleep 1
# dump 验证 EditText text == 'tb2' 后再 tap 确认
```

### 5.3 环境/编码坑

- `export MSYS_NO_PATHCONV=1` 必须在最前；adb pull 本地路径用 `D:/` 风格
- Bash 每次调用后 cwd 重置，bead_studio 命令以 `cd /d/code/bead_studio/...` 开头
- /tmp 不跨 Bash 调用持久，临时文件在 .test 目录用相对路径
- python print 中文/特殊 unicode 在 GBK 控制台崩溃，一律 `.encode('ascii','backslashreplace').decode('ascii')`
- adb 命令在 `while read` 循环里吃循环 stdin，须加 `</dev/null`

### 5.4 模拟器系统层坑

- **SystemUI ANR 对话框**（"App 无响应"）：对话框属 system_server，am/input 都点不动——`keyevent 4 (BACK)` 再 `keyevent 66 (ENTER)` 可关；副作用 app 被带崩，重启 app 即可
- **MediaStore 死条目**：相册显示的幽灵条目若 content delete 删不掉，先查条目指向的文件是否真实存在（多半是 /storage/emulated/0/ 根目录的历史调试图）——rm 文件 + 重启模拟器，MediaProvider 重建索引
- **AppSnackBar 顶部胶囊 3 秒消失**（不是 Material 底部条）：显示在屏幕顶部 y≈120-210 的深色胶囊，3s 自动消失——验证 snackbar 的 dump/截图必须在「触发动作完成 + 3s」窗口内查屏幕**顶部**；去底部找会误判"没提示"

---

## 6. 基准数据（test_pic5）

- 测试图：test_pic5.png（1440×2100，16 色图例；相册中 2026-08-27 拍摄条目，md5 de94dca48fe2dc334f08b2655b6fc6ec）
- **自动框选选区（原图坐标）**：y∈[1674,1792]——sim best band [1684,1780]（score=579.2）上下各 +10 余量；y≥1782 全白
- **现行识别基线（2026-11-07 定，二遍补读版 0ce0af9）**：图例 16 色/共 1336 颗；②格距 31.33；③自动主体 39×43（bbox=[126,272 1344,1616]，legendTop=1674）；④**总豆数 1307**/空白 370/⚠4 项数量有误（C16 432/433、F2 17/21、F5 85/101、H7 335/343）——识别指纹 logcat 打印已随调试清理移除，回归对账看这组 UI 读数即可（debug 构建期指纹 `识别 39x43 | OCR命中 1195+80(补读,色彩分歧1)/1677`）
- 历史：整图单遍 OCR 命中 1202（0792177）；分带一遍 -7 带缘归位差、二遍补读 +80，净增 73
- 板默认 52×52、每 5 格加粗；back 自动保存、拼豆页点色点格标记均正常
- **选错图特征指纹（②定案沉淀）**：误载入还原页截图（snap 类 1080×2340，h/w=2.167）时，游程法 best band 落 [1510,1576]（app 选区 [1500,1588]，内嵌图纸被屏幕 UI 平移 ~180px）——看到这组数即相册污染选错图，先走 §0.1 清理
- **微信图 wx1 基准（1920×1200 横版）**：两侧 ~290px 黑边 + 蓝框围主体（顶 y60-88/底 y930-956/竖线 x~307,1589）+ 顶部数字带（灰 214 底，y64-140）+ 真图例 y960-1016（~45 格小色板拼条，白底）+ 页脚灰线 y1182-1188；**旧版算法把页脚带当图例（框贴底 y1172-1200）即此图误判指纹**，v4 算法离线命中 (306,962,1600,1112)；相册就位走 §0.1 流程后第一格
- 复现工具：`.test/wx_replica4.py`（游程法 v4 Python 复刻 = app 现行算法，`python wx_replica4.py <图>` 离线对拍；`wx_replica.py` 为 v1 旧版基线对照；.test/ 本地目录不入库）

---

## 7. 修改记录（发现问题/修复后回写）

| 日期 | 修改人 | 内容 |
|------|--------|------|
| 2026-11-09 三轮 | Claude | **终止按钮二轮打磨（清零语义+红底醒目）实测通过**。本轮流程操作教训：a) **①页结果态与未识别态按钮布局完全不同**——结果态底部是「下一步：九宫格对齐 (44,2109)(782,2241)」，坐标恰与未识别态「识别图例」(413,2175) 重叠！用未识别态坐标 tap 会**误进②页**，之后的「终止验证」全部假阳性（清单消失其实是页面跳走了）——**每步 tap 前必须 dump 验证当前页面态**（结果态特征：有「重新选图识别/添加颜色/下一步」）；b) **结果态改框重新识别无法注入**——图区 swipe 被 InteractiveViewer 捏合/平移手势抢走，拖框不落（连试不中）；带旧清单的终止场景 adb 造不出，靠代码路径推定；c) **冷启动装包后主页就绪要 6s+**——dump 轮询确认再导航，直接 tap 会误进相机（相机寄生复发）；d) 结果态→②用 AppBar 返回上一步也要过确认框（「返回上一步」按钮 y~1359，与 AppBar 顶钮 (77,213) 同名不同位） |
| 2026-11-09 二轮 | Claude | **忙操作「终止」按钮实测通过**（图例识别中途终止生效/继续等待分支/弹窗挂死补丁/test_pic5 回归 16色1336颗），实现见 project-status §5 同日二轮行。本轮流程操作教训：a) **确认弹窗的按钮 tap 常一次落空**（dialog semantics 挂载延迟，dump 里按钮在但 input tap 无效）——快速链要补点一次（间隔 0.4s+）；b) **adb 掐不住亚秒窗口**：6K decode 热跑仅 ~1s，遮罩渲染 ~0.3s，剩余窗口 < adb 两跳 tap（每跳 ~150ms）+弹窗挂载延迟——「遮罩中终止短操作」在 adb 下不可稳定复现，真实手指无此延迟，验证转走长窗口链路（图例识别 ~12s 冷跑）同构机制；c) **dump 判定词撞车**：pick 页 desc 含「小红书链接导入/抖音链接导入」与「框图例 → 核对用色…」流程说明——判定「导入中/已进①」会被误报，用「请稍候」（遮罩文案）与「从相册选择图纸」（pick 页铁证）等独占词；d) **①页 AppBar 返回上一步弹的是确认框**（非直接返回）——自动化里点 (77,213) 后必须先处理弹窗再继续导航，否则后续 tap 全落偏；e) **PhotoPicker 网格同会话持续漂移**（第三次打开 y=1583→849→672-1027 三种位置）——每次必 dump 实测 `content-desc="Photo taken on …"` 节点 bounds，别信上次坐标 |
| 2026-11-09 | Claude | **三项体验修复实测通过（导入等待遮罩/选图页返回钮/补读链出主线程）**，实现见 project-status §5 同日行。验证：选图页「返回主页」(77,213) tap 回主页 ✓；6K 导入期帧差分析抓到 black38 遮罩+spinner 文本 ✓；6K 图例识别 70 帧 burst——改前基线 32.5s 含 4 段冻结（~15 stalled 帧≈7s，crop 380,980-700,1420 差分<200px 判 stall），改后 0 stall run 仅 1 孤立帧，**结果 37 色/2585 颗与改前逐项零差**；test_pic5 回归 16 色/1336 颗 ✓。本轮环境教训：a) **模拟器图形栈会崩**（连续 burst+OCR 高负载后 screencap 全黑但 pidof 活/logcat 无 FATAL/语义树完好/焦点正常）——**判别铁证是 HOME 也黑**（app 黑不了系统 launcher），先 keyevent 3 截屏再怀疑 app；恢复必须 `-no-snapshot` 冷启动（快照 load 会把坏图形带回，实测重启两次才悟）；b) **quickboot 快照连磁盘一起回滚**——会话内 rm 的调试图/清过的 MediaStore 幽灵条目在快照恢复后全部复活，清相册污染后要 `-no-snapshot` 重启才留得住；c) 相册再被根目录调试图抢首格（icon_check*.png 6 条）——`$ADB shell "rm -f '$p'"` 嵌套引号 rm 落空（ls 验证文件都在），**adb shell rm 多文件直接平铺无引号**，删完 broadcast 扫 Pictures 即可（content delete 清不掉幽灵行，别费劲）；d) PhotoPicker 网格 dump 抓不到缩略图节点（只 2 个 clickable）——PIL 行方差扫带（y≈1420-1750，var>40=照片内容）定位网格行再按 3 列分位 |
| 2026-11-07 二轮 | Claude | **四项改进实测通过（步长档/豆板选择页/导入忙碌锁/图例预算+进度条）**。本轮流程操作教训：a) **PhotoPicker 网格纵向位置会漂**（同会话两次打开：第一次第一行 y=1583，第二次 y=849，疑与上次选中态/边缘动画有关）——选图 tap 前必 dump 实测网格 y；b) **`enableDrag:false` 关不住 modal 底板的拖把手**——SDK bottom_sheet.dart 在 enableDrag:false 时反而给 showDragHandle 单独挂 `_BottomSheetGestureDetector`（把手保留为关闭途径），实测把手区下扫照样关面板；**要彻底禁拖必须连 `showDragHandle: true` 一起删**（xhs/抖音面板已改，把手消失后面板顶上移 ~100px，坐标随之变）；c) **dump 输出格式是 `y x 类 文本`**——PopupMenuItem 坐标 (904,510) 曾被当 (540,510) 点空，x/y 谁先谁后看模板注释，Flutter 节点 x 本不可信但菜单/相册属系统组件坐标双可信；d) **gradle daemon 卡死复发**（新 daemon 0 CPU 停 12 分钟+昨晚僵尸 daemon 同存）——杀全部 java/dart 进程走离线配方 39s 过（见 memory gradle-offline-x64-build）；e) **图例 6K 原图识别 OOM 崩溃坐实**：logcat `FATAL EXCEPTION: pool-3-thread-1 java.lang.OutOfMemoryError (139MB allocation)`，堆顶仅 201MB——大图排查先看 AndroidRuntime FATAL 而非只盯 flutter tag；f) ②面板「格子大小」± 钮无 tooltip 不入语义树——PIL 放大行条带定位圆钮中心（本轮 −(260,1845) +(470,1845)），步长档 chips 有文本可直接 dump |
| 2026-11-07 | Claude | **二遍逐格补读回归通过（0ce0af9）+ 调试块全量清理（8330fe3）+ v0.2.0 交付物重出**（release 全架构 APK 95,905,044B md5 `62766C30…541`，smoke：release 全流程 ①16色/1336颗→④总豆数 1307 与 debug 逐项一致，识别中实时进度 93% 抓到实证）。基线换新见 §6（39×43/1307/1336——**上会话 45×50 挂账与 39×43 内容一致**：两框均 1307 豆，大框只多包 573 空白格，几何上 45 列×31.33=1410px 超 bbox 宽即证其框松）。本轮环境教训：a) **PowerShell→adb 的 `content query --projection a,b` 引号被剥整串当一个列名**（Invalid column）——省 projection 全列 query 再 Select-String 过滤最稳；b) **任务记录被相机寄生**：install -r 杀进程后 `am start` 报 "delivered to running top-most instance" 且前台是 camera2（TaskInfo baseIntent=bead MainActivity 但 topActivity=CaptureActivity）——`am start -n … -f 0x10008000`（NEW_TASK|CLEAR_TASK）重建任务即好，勿误判 app 崩溃；c) 识别指纹 logcat 打印已删，回归对账走 §6 UI 读数（共N颗/总豆数/空白/⚠项），别再 grep 临时调试 |
| 2026-11-06 | Claude | **近白空白文本第一判据 + 复核每行列数实测通过，v0.2.0 发布**（实现详见 project-status §5 同日二轮行）。本轮流程操作教训：a) **会话 shell 已由 Bash 换成 PowerShell 5.1**——`>` 重定向是文本模式会毁二进制（screencap PNG 直接 UnidentifiedImageError），**二进制落盘一律 `cmd /c "adb exec-out screencap -p > x.png"`**；无 `&&`；内联 python 引号地狱改为先写 .py 文件再 `python -I` 执行；b) **`su 2000 content call --method scan_file` 本轮返回 STREAM=null 且未索引**（与 11-06 上午教训 d 矛盾，不可依赖），`am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://…` 稳定索引——推图后必 query 验证再选图；c) **平涂合成图（色块+白缝、无照片纹理）主体自动框选会失败**（聚到单格 rowsCols=null）——手动拖框是正路：PIL 定位黑环/内容包围盒 → `input swipe x1 y1 x2 y2 500`，吸附按整格归位（合成图 24×24 精确）；d) 复核「每行N格」选择器**放 chips 横滚行末端会被裁不可发现**，落在缩放条左端才常显（§3 已加坐标）；e) 冷启动盲走导航链曾整链漂到图片转换页——每步 dump 验证再 tap 是铁律 |
| 2026-11-06 | Claude | **抖音链接导入上线 + xhs 查看器抽共用**（`lib/core/douyin_link.dart` + `steps/douyin_import_sheet.dart`；查看器抽为 `steps/link_image_viewer.dart` 供 xhs/抖音共用，LOD/双击/保存相册行为不变）。配方：分享文案提取 `v.douyin.com` 短链 → **Baiduspider UA** 过原生通道逐跳 302（普通 UA 只给数据加载已死的 JS 壳页）→ `iesdouyin.com/share/note/{id}/` SSR → JSON-LD `@type=article` image 数组拿 `~tplv-dy-aweme-images:q75.webp` 签名 URL（按对象 uri 去重多 CDN 镜像；签名不挑客户端 ~30 天时效）。画质结论：分辨率=作者上传尺寸不缩水，q75.webp PSNR~35dB 对识别零风险；更优 q75.jpeg(+2dB) 仅浏览器页面内 fetch 可得，免浏览器通道全试尽（detail API/amemv/lightbox/mobileweb）皆无，不追。模拟器实测：耍起链接 3 图进①框图例、奶龙链接全流程至识别 18 色/1403 颗；xhs 冒烟（假链接→正确报错）不回归。**选图页坐标改为 4 钮纵排：相册 1285/拍照 1450/小红书 1615/抖音 1780（§2.1/§3 已更新）**。本轮教训：a) **Dart raw 字符串不做插值**——lint 改 `r'…$_var'` 后正则成字面量 `$urlChars`，模拟器表象「未识别到抖音链接」，单测才暴露；要插值必须非 raw 串+`\\.` 转义；b) **adb input text 带 URL 尾斜杠会被 IME 组合态搅坏**（打出 `…/v`，DEL 追打无效）——BACK×2 关面板重开 sheet 重打，且不带尾斜杠；c) **adb 打不了双击**（两次 input tap 间隔必超 300ms 窗口）——查看器双击/LOD 交互改 widget test 覆盖；d) **flutter_test 两坑**：引擎 codec 对 webp 挂起不抛错（fixture 换 PNG），`compute()` 真 isolate 在 FakeAsync 区永不跑——`tester.runAsync` 轮询真实时间窗(2s×N)直到出图再断言，`pumpAndSettle` 会因 spinner 假超时；e) `photoLodCropRect` 补守卫：原图长边≤显示上限时 LOD 永不触发（原版小图 zoom=1 也过阈值，双击回整图会白算一次裁片叠显同像素 JPEG，违背其注释契约）；大图路径（>4096 被压显示）行为不变 |
| 2026-11-06 | Claude | **三项体验改进实测通过**（①图例总豆数徽标 ②识别期 body UI 锁 ③复核长按范围连选，实现详见 project-status §5 同日行）。本轮流程操作教训：a) **`flutter build apk --debug` 报 "Gradle threw an error while downloading artifacts"（6.9s 快败）→ 装了 08:19 旧 APK 整轮假验证**（chip 不显示、遮罩拍不到都是旧包）——安装前必 `stat` APK mtime 对构建时间；构建直接走 gradle-offline-x64-build 配方（2m25s 过）；b) **识别速度已远快于旧表 sleep 值**：test_pic5 图例识别 <1.5s 完成（旧表 sleep 4 保守无妨，但**拍识别中遮罩要 +0.3s 级快拍**，+1.5s 已错过）；主体识别 1677 格 ~7s（旧表 2250 格 20s 的线性外推过保守）；c) **`input motionevent UP` 在 API36 需带坐标**（`UP x y`），裸 `UP` 抛 IllegalArgumentException 指针悬死——复核范围连选就是用它注入（DOWN → hold 0.9s → 逐段 MOVE → UP x y），4×2 对角拖=清除选中(8) 一次验过；d) 相册又被 xhs 残图抢首格（§0.1 复发第三次）——`touch + su 2000 content call scan_file` 刷新 mtime 排前即可，不必删图；e) test_pic5 ③ v4 bbox=[126,272 1344,1616] 43×39（2026-09-11 旧基线 50×45 未过 v4），识别总豆数 1307、图例印刷和 1336——v4 基线核对待办时以此为起点 |
| 2026-09-14 | Claude | **v9 图例检测上线 + 列序尺接入主体 + Skia 优先解码——wx1 全流程回归通过**（图例 v1→v9 调参史与算法注释见 `docs/vision_tuning_notes.md`、`lib/core/legend_detect.dart`/`board_detect.dart`）。本轮流程实测（wx1 1920×1200）：①自动框图例 legendTop=962 与 fleet 真值 (292,962,1614,1130) 零差→OCR 图例 29 色；②色卡确认 OCR 30 对；③主体框 bbox=[472,232 1448,956] rowsCols=26×34（native 窗口不缩放）；④复核 AppBar 双入口+退出框取消回归 ✓→保存作品 wxv1→板 52×52→豆板 wxv1b→拼豆页 `拼豆 · wxv1 · 板 52×52 · 已放 0/882`，色条 H2 274/H4 125/M12 117/H6 116… 与识别日志逐色一致（884−2 空白=882）。**本轮流程操作教训**：a) **中途 `screencap /sdcard/x.png` 会被 MediaStore 索引抢相册第一格（§0.1 二次复发，本轮连续两轮报废）——流程内截图一律 `adb exec-out screencap -p > 本地.png` 直拉 PC，不落设备存储即零污染**；b) **uiautomator dump 在识别计算/页面切换瞬间会返回全空文本的 29 节点树**（语义树未挂上，非 app 挂死）——隔几秒重试，或退回 exec-out 截图 PIL 块图分析（AppBar 双入口即像素验证：chevron/✕ 暗像素计数）；c) 命名对话框自动聚焦弹键盘整体上移：保存作品·保存钮 (754,1031)、豆板·确认 (754,1058)，一律 dump 实测；d) 识别耗时按格数给 sleep 后仍要轮询 CPU/logcat 确认完成（本轮 884 格 ~55s 才出识别日志，比 2250 格经验值慢——模拟器负载相关）。**wx1 全流程基准**（§6 已有单图指纹）：legendTop=962 / bbox=[472,232 1448,956] / rowsCols=26×34 / OCR 402/884 命中 / 拼豆页 0/882 || 2026-09-11 | Claude | **微信图 wx1 泛化修复 + ①清除选框 + release APK**（用户实测反馈：自动识别图例失败后框压在图最底部贴边抓不到）：①**根因**——wx1 两侧 ~290px 黑边 + 版底/数字带用 ~187-214 平灰 + 蓝框围主体，旧游程法按纯白(≥240)判背景：灰底被 JPEG 抖动切成大量 ≥20px 游程（数字带整行 45+「块」）+ 黑边让每行白送 2 块，全页聚成巨带被高度上限整体拒绝，只剩页脚灰线带得分胜出 → 框贴底（离线复刻 `.test/wx_replica.py` 逐行对拍定位）。②**图例检测 v4**——`_qWhite` 改近白含平灰（nibble 全 ≥11/≥176 且极差 ≤1）；贴行缘游程（页边框）不计块/不撑选区/不算内容占比；打分加色数项 `nSum + colors×15 + 底部位次`（图例带几十种色 vs 单色数字带/大色块主体几种）。离线：wx1 由页脚误框 (0,1172,1920,1200) → 真图例 (306,962,1600,1112)（band[972,1100] score1148 胜出）；test_pic5 选区 (37,1674,1404,1792) 与 v1/app 基线**逐值零差**。③**主体检测同源修**——行扫描跳过贴行缘非白游程、列扫描从图顶/图底向内找首个白像素（黑边整列不再恒 1.0 密集），防主体框撑满整页。④**①页加「清除选框」按钮**（与自动框选并排，有选区时可点）——错位框贴边把手出不了图没法抓，一键消掉重画。⑤出 `app-release.apk` 88.4MB 供用户真机试用（模拟器冒烟：装包启动主页四钮正常）。**教训**：a) 离线复刻要与 app 算法逐句对齐（本轮曾因复刻口径偏差两轮空转，逐行重读源码后一次命中）；b) 巨带高度拒绝会连带吞掉带内真图例——聚簇前先想清楚「谁在给每行白送块」（页边框/灰底是隐形噪声底座）；c) 排查「设备返回 null 但复刻说有解」先查两端解码差异与贴边 knife-edge 行。**待办**：模拟器全流程回归（wx1 走通 ①-④、test_pic5 框选/bbox logcat 基线核对）暂停待用户安排 |
| 2026-09-11 | Claude | 拼豆页两新需求（用户反馈）：①**拼豆页可改粗框线颜色**——抽共用 `major_color_picker.dart`（预设 8 色 BottomSheet，板设置页原 `_pickMajorColor` 重构共用），拼豆页信息行加 28px 色钮，`_majorColor` 会话内覆盖传 `board.copyWith(majorColor:)`，不回写板文件（持久配色仍走板设置页，两页状态互不踩）；实测点钮选红 0xFFE53935 → 画布红粗线 62562px、橙 0。②**缩放/还原钮从 AppBar 撤回贴画布**——AppBar 顶置离图太远，移到画布与色条间外置条 y=2079（AppBar 仅剩保存进度）；实测放大两连击主红线间距 100px→155.6px（1.5625×=1.25²）、还原全幅后线位与初始逐线一致。③教训：**装包冷启动 sleep 8 仍可能不够**（本轮两次导航链首击落空进选图页）——导航前先 dump 轮询确认主页四钮就绪再 tap；zoom 验证用**粗线间距测量**（extent 包围盒对缩放不敏感曾误判没生效） |
| 2026-09-11 | Claude | 拼豆页高亮观感第三轮 + 文字层控件（用户反馈"近黑深灰、要有选中差异"+两控件需求）：①基色再深化为**近黑深冷灰 slate-700 0xFF374151**（亮度 ~64）且**豆色混合幅度 0.5→0.75**——未选中整体沉到亮度 32-79 区（板内 72% 像素），选中色全彩跳出；文字层亮度判定基准同步 0.75（防深浅选反）、字色本身仍 0.5 保可读。实测：基调 (52,68,84) 37.2%、亮度桶 2-4 占 72%（上版集中 112-127）、纯白仅剩 2.9%。②信息行两控件**常显**（原先模式切换钮藏在选中后）：「只显示色号/横向/竖向」TextButton + 新增「显示/隐藏未选中色号文本」IconButton（`_showOtherIds`，BoardPainter `showNonHiLabels` 参数，非高亮格不画色号文本；无高亮时关=纯色块净板）。实测无高亮 dump 两控件均在（(700,356)/(895,356)），C16 高亮下开关 OFF 未选中区文字像素 2318→0、选中区不变。③教训：**装包后冷启动 sleep 8 再导航**（6s 不够曾致整链 tap 错位落选图页），长导航链每步 dump |
| 2026-09-11 | Claude | 拼豆页高亮压暗基调两轮调优（用户反馈迭代）：①未选中色号**文字同步变灰**——`_drawLabel` 加 `dimmed` 参数，压暗格字色向共同基色 lerp 0.5（与豆底同幅度），不再保持全对比抢焦（白字→~186 带色相、黑字→~64，非纯白/近黑）；②基色 0xFF9E9E9E 用户反馈不够暗 → 先 gray600 0xFF757575 再定稿**冷蓝灰 slate 0xFF6B7280**（亮度 ~113 持平 gray600、r<g<b 与选中蓝框同调）。实测（bfx 板选 C16）：基调 (108,116,132) 占 37.2% r<g<b、深豆(H7 dim ~lum73)格白字变灰带 1033px 纯白残留仅 0.5%（边缘抗锯齿）、浅豆格黑字 45-80 带无近黑；无高亮回归白底 43.5% 主导不变。探针脚本 `.test/text_dim_probe.py` |
| 2026-09-11 | Claude | 用户五修复实施+实测回写（zoom 外置/UI 配色/编号重排）：**问题1 缩放按钮外置**——ZoomControls 去 Positioned 悬浮改纯 Row（横排三钮），还原页 ①②③④ 图区与底部面板间插 `_zoomStrip`（右对齐；`_imageStage` LayoutBuilder 速记 `_stageViewSize` 显式传视口），板设置画布与底栏间同款条，拼豆页进 AppBar actions（在「保存进度」左侧）；实测 ① 识别前三钮 y=1900/识别展开后 y=1600（面板高自适应挤压图区）、板设置 y=2112、拼豆页 AppBar (659/769/879,213)+保存进度(1014,213)，拼豆页 AppBar 放大两连点板面正确扩展。**问题3 图例面板自适应高度**——`_buildLegend` 套 LayoutBuilder，`listH=(maxHeight-imgH-172).clamp(96,168)` 替固定 168；实测识别展开态印刷图例带（彩色行 y1400-1510）完整可见于缩放条上方，仅图底纯白边距被裁。**问题2 主体框选剔除行列数字边**——`_autoDetectSubject` bbox 后加四边半格步进剔除（步长 0.5×pitch、上限 4 带/边、采样步 2、白=r,g,b≥240、彩色墨=极差≥45：cov<0.02 白隙穿越/cov≤0.7 且 cf≤0.35 数字剔/其余豆带停），残余<半格由 snap 归位；离线合成贴边数字带验证剔后误差<3px、无数字图零误剪（`.test/ruler_touch_sim.py`/`ruler_trim_sim.py`）；本尊 logcat `bbox=[0,84 1438,1672] trim=[0.0,84.0 1438.0,1672.0] rowsCols=50x45` 与基线零差。**问题4 拼豆页空白配色**——BoardPainter 删 darkBoard：无高亮板底 0xFFFAFAFA 白、高亮统一 `_dimGray` 0xFF9E9E9E、压暗豆 `lerp(color,dimGray,0.5)`、细线 black26/black12、文字亮度按混合色算；实测无高亮画布 66.6% 白（原近黑），选 C16 后黑区 7.3%→0.7%、灰 128-160 带占 23.8%（灰非黑）。**问题5 编号间隔重排**——`_buildNumbers` 连续段编号：同行且 bx=prev+1（或同列 by=prev+1）才续号，被其他色号/空白隔断重新从 1 起（代码级修复）。**坐标回写**：保存成功框 回到主页(361,1332)/直接开始拼豆(676,1332)；命名/豆板对话框 IME 顶起整体上移（作品名 EditText 822/保存 1031；豆板名 821/确认 1058）——一律 dump 实测为准。全流程闭环：识别基线零差（H7=343 C16=433）、保存 fx1→板 bfx→拼豆页 `板 52×52 · 已放 0/1371` |
| 2026-09-11 | Claude | 用户两修复实施+实测回写：**修复⑤ 主体自动框选排除图例**——新 `_autoDetectSubject`（排除图例带→行扫描 dense=0.22 聚簇+内容桥接 bridge=0.03/gap≤60→带内列扫描同法→包围盒→`_snapSelToGrid` 吸附→`_plannedColsRows` 4-400 校验），`_goFrame` 无选区时自动跑（进③即出框）+ 无选区时按钮「自动框选主体」显式重试入口；logcat 实测 test_pic5 `legendTop=1674 bbox=[0,84 1438,1672] rowsCols=50x45`——底边 1672 严格不含图例带（顶 1674）、上白边 84 裁掉、行列与格距 31.33 吻合。**修复⑥ AppBar 双入口（推翻 09-11 上午"唯一箭头"方案）**——左上=返回上一步（弹确认保现场，pick 步不显示）+ 右上 ✕=完全退出图纸还原（`_confirmExitRestore` 复活：弹确认后 `Navigator.pop()` 整页出栈绕过 PopScope）；实测 ①③④ 三页双入口并存、④ 点 ✕ 弹「退出图纸还原？」(取消 584,1359/退出 799,1359)、取消留在④。§2.4 步骤7/§2.5 步骤8.5/§3 坐标表同步；**大图识别耗时**：2250 格 sleep 7 不够需 12+（本轮实测 ~19s）。全流程闭环：主页→还原→①②③④→保存 bd3→直接拼豆→板命名 board3→拼豆页 `板 52×52 · 已放 0/1336`+色条齐全 |
| 2026-09-11 | Claude | ①④修复实测回写：（④=用户本轮新定义两问题）问题1 返回入口唯一化——AppBar `automaticallyImplyLeading:false` 关系统 Back + 删「退出图纸还原」「回对齐」「回九宫格」三冗余钮 + `_confirmExitRestore` 死方法，actions 首位唯一左箭头（pick 步不显示）；问题2 复核操作条三按钮 Row→Wrap 折行（实测默认字体下「归类到…」自动折第二行 y=2087，完整在屏）。实测：①/③/④ 三页 AppBar 均唯一箭头；箭头弹「返回上一步？」确认（④→③ 文案正确、选区 37×23 保留）闭环通过。**坐标漂移记录**：选图页「从相册选择图纸」(540,1483)/「拍照图纸」(540,1648)（误点拍照进相机一次）；**相册第一格 (177,1583) 非 (539,1583)**——PhotoPicker 3 列网格第一张在左列，旧单列大图时代坐标作废（曾致整链 tap 落空白）；§2.1/§3 坐标表全部更新，加「tap 前 dump 实测为准」提醒 |
| 2026-09-11 | Claude | ②定案回写：自动框选"非确定"表象根因=相册污染（根目录 7 张调试截图抢占第一格，误选 snap_snack 还原页截图）；游程法零 bug——sim 于误选图跑出 band [1510,1576] 与 app 选区 [1500,1588] 逐像素吻合，本尊 band [1684,1780] 亦吻合。新增 §0.1 相册污染检查/§0.2 picker cache 取证（文件名=MediaStore _id 铁证）；§2.1 加选图前 query 验证 + 选图后本尊验证步骤；§5.4 修正 snackbar 描述（AppSnackBar 顶部胶囊 3s，y≈120-210，非底部条 4s）；§6 补选区/指纹基准。教训：**图区视口高宽比是布局常量（Expanded 视口），与载入什么图无关，不能用于推断载入图属性**（曾据此推理两轮全废） |
| 2026-09-11 | Claude | skill 初建：从 .test/full_flow_test.md 操作手册部分迁移升级，新增 test_pic5 基准、x 坐标不可信/D:/ 路径/ANR 处理/MediaStore 清理/snackbar 4s 窗口等本轮教训；问题清单仍留在 .test/full_flow_test.md 跟踪（①②④待修，③⑤⑥⑦已修提交） |
