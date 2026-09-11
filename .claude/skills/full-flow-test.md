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
| 2 | 点「从相册选择图纸」 | 主页下方按钮，dump 找 | 相册打开 |
| 3 | 选测试图（相册第一张网格位） | (539,1583) | sleep 3；解码后进①框图例，AppBar「① 框图例」 |

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
| 7 | 拖框主体（swipe 起点→终点） | 例 (300,700)→(800,1500) | 框上出现「N行 × M列」徽标 |
| 8 | 「开始识别」 | (796,2230) | sleep 6（OCR+采样）；dump 见 AppBar「④ 识别复核」 |

### 2.5 ④ 复核 → 保存作品 → 直接开始拼豆

| 步骤 | 操作 | 坐标 | 验证 |
|------|------|------|------|
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
| 相册第一张 | (539,1583) |
| ① 自动框选图例区（按钮） | (540,2087) |
| ① 自动框选图例（AppBar 魔法棒） | (882,213) |
| ① 识别图例 | (413,2241) |
| ① 跳过图例 | (925,2241) |
| ② 下一步（对齐） | (540,2241) |
| ③ 开始识别 | (796,2230) |
| ④ 保存作品 | (360,2241) |
| ④ 进编辑器 | (867,2241) |
| 命名框 EditText | (540,1172) |
| 命名框 保存 | (754,1381) |
| 保存成功 留在本页 | (387,1332) |
| 保存成功 直接开始拼豆 | (702,1332) |

### 板设置页（BoardSetupPage）
| 控件 | 坐标 |
|------|------|
| 移除选中作品 | (882,213) |
| 豆板菜单 | (1014,213) |
| 开始拼豆 | (719,2241) |
| 添加作品 | (212,2241) |
| ZoomControls 放大/缩小/还原 | (997,1795)/(997,1938)/(997,2081) |
| 保存并开始拼豆 是/否 | (771,1332)/(573,1332) |
| 保存豆板 EditText/取消/确认 | (540,1172)/(539,1381)/(754,1381)，标题「保存豆板」(540,1007) |
| 删除作品 否/是 | (618,1359)/(816,1359)，标题 (540,1029) |

### 拼豆页（AssemblePage）
| 控件 | 位置 |
|------|------|
| AppBar 标题 | `拼豆 · <作品名>`（y≈349） |
| 保存进度 | AppBar 右侧，dump 找「保存进度」 |
| ZoomControls | 右缘三钮 |
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
- **Flutter SnackBar 4s 超时消失**：验证 snackbar 的 dump/截图必须在 tap 后 4s 窗口内完成

---

## 6. 基准数据（test_pic5）

- 测试图：test_pic5.png（1440×2100，16 色图例；相册中 2026-08-27 拍摄条目）
- 图例带位置（游程法实测）：y≈1684-1780（原图坐标），y≥1782 全白
- 识别基线参考：H7 纯黑 343 颗（2026-09-08 离线验证）
- 板默认 52×52、每 5 格加粗；back 自动保存、拼豆页点色点格标记均正常

---

## 7. 修改记录（发现问题/修复后回写）

| 日期 | 修改人 | 内容 |
|------|--------|------|
| 2026-09-11 | Claude | skill 初建：从 .test/full_flow_test.md 操作手册部分迁移升级，新增 test_pic5 基准、x 坐标不可信/D:/ 路径/ANR 处理/MediaStore 清理/snackbar 4s 窗口等本轮教训；问题清单仍留在 .test/full_flow_test.md 跟踪（①②④待修，③⑤⑥⑦已修提交） |
