---
name: project-status
description: 拼豆 App（bead_studio）项目状态快照——环境、开发内容、代码地图、进度、工作规矩，新会话接续开发前读这一份即可零背景上手。触发词：「项目状态」、「接续开发」、「现在做什么」、「继续拼豆项目」、「bead_studio 上下文」。
---

# 拼豆 App 项目状态（project-status）

> **新会话接续 bead_studio 开发先读本文件**——一页拿到环境/进度/代码地图/规矩，
> 不依赖任何历史会话记忆。发生大进展（新功能落地/问题清单变化/新基线）后
> 回来更新 §5 进度表，保持快照新鲜。

---

## 1. 这是什么项目

Flutter 拼豆图纸还原 App（Android 优先，web 兼容）：

- **核心链路**：相册/拍照导入拼豆图纸 → 五步还原（①框图例 → ②九宫格对齐 → ③框选主体 → ④识别复核）→ 保存作品 → 板设置（豆板布局）→ 拼豆页（对照放置）
- **主页四入口**：开始拼豆（板设置）/ 图纸还原 / 图片转换 / 我的作品
- **技术栈**：Flutter (Dart)、google_mlkit_text_recognition（OCR）、image 包（像素级处理）、compute isolate（重活出主线程防 ANR）、自绘 CustomPainter（网格/选区/手势叠加层）

识别哲学：**印刷色号是图纸的权威声明**——OCR 命中候选色号的格直接采用，读不到才回落 Lab 最近色采样；偏色过大判空白格。

## 2. 开发与测试环境

| 项 | 值 |
|------|----|
| 仓库 | `D:\code\bead_studio`（git，**自动 commit+push** 规矩见 §4） |
| 包名 | `com.beadstudio.bead_studio` |
| 测试设备 | Android 模拟器 `emulator-5554`（1080×2340） |
| adb | `/d/Android/Sdk/platform-tools/adb.exe -s emulator-5554` |
| Shell | Windows msys bash——**每条命令链开头 `export MSYS_NO_PATHCONV=1`**（否则 adb 内 /sdcard 远端路径被 MSYS 转换静默失败） |
| 测试资料 | `.test/` 目录（基准图 test_pic5.png / 问题清单 full_flow_test.md / 游程法复刻 legend_detect_sim.py） |

UI 自动化测试走 `full-flow-test` skill（adb 驱动全流程：坐标表、页面判别、坑清单、相册污染检查）。跑测试前必读那份文件。

## 3. 代码地图

### 按文件

| 文件 | 职责 |
|------|------|
| `lib/features/restore/restore_page.dart` | **主战场**（~5400 行）：五步还原页全部逻辑 |
| `lib/features/board/board_setup_page.dart` | 板设置页：豆板布局、多作品摆位（支持旋转/翻转）、开始拼豆 |
| `lib/features/editor/` | 图案编辑器（editor_page / grid_painter） |
| `lib/features/assemble/` | 拼豆页：点色点格标记已放、进度保存 |
| `lib/core/grid_detector.dart` | 格距检测：detectGrid（中位数法，图例用）/ detectGridAutocorr（自相关法，主体用——豆圆弧次峰场景中位数法会锁错） |
| `lib/core/quantizer.dart` | Lab 距离最近色量化 |
| `lib/core/palette_registry.dart` | 色卡注册与切换（MARD 等，色号 id 如 H7/A16） |
| `lib/core/draft_store.dart` | 作品/豆板持久化 |
| `lib/core/decode_image.dart` | 显示层重编码 JPEG + 长边限幅（识别/裁剪仍用原始像素） |

### restore_page.dart 内关键算法（排查问题先看这些）

- `_autoDetectLegend` 游程法图例带检测（载入即自动预框）
- `_autoDetectSubject` 主体自动框选（排除图例带 → 行扫描聚簇+内容桥接 → 带内列扫描 → 包围盒 → 吸附格线）
- `_recognize` 识别主流程（几何切分 + OCR 权威 + 色彩回退 + 近白空白判定 + 候选集含近白跳过空白直判）
- `_pairLegendOcr` 色号-颗数两轮几何配对（同行右侧 / 正下方）；`_ocrConfusions` 混淆变体表（0/O、1/I/L…）；孤儿颗数空隙二次 OCR + 色块颜色补全
- `_imageStage` 手势系统（单指框选/挪框/把手微调，双指捏合缩放非增量式矩阵，误触三重判定回溯）
- 阶段枚举 `_Stage { pick, legend, align, frame, review }`

## 4. 工作规矩（与其他仓库不同，勿混）

- **本仓库自动 commit+push**（visionfront 相反——那边只给 message 不自动提交）
- **禁止用 Read 工具看截图 PNG**（CDN 缓存污染前科，曾整轮假结论）——一律 PIL 像素分析（色块图/直方图/diff）
- GBK 控制台 print 中文必须 `.encode('ascii','backslashreplace').decode('ascii')`
- /tmp 不跨 Bash 调用持久——临时文件放 `.test/` 用相对路径；adb pull 本地路径用 `D:/` 风格（`/d/` 间歇性报错）
- 代码内【临时调试】块（debugPrint / OCR 调试视图）是排查期产物，标了正式版移除——看到不要当正式功能；清理它们本身是待办
- 改动影响流程行为时，测试方案走 CLAUDE 通用规矩：改前复现 → 改后同操作对比 + 回归点

## 5. 当前进度（2026-09-11）

**状态：全流程闭环，无待办。** 已知问题清单 ①-⑦ 全部收口；用户五项体验修复（同日第二轮）也已落地实测：

| # | 问题 | 结论 |
|---|------|------|
| ① | 进③不自动框选主体 | 已修（`_autoDetectSubject` 无选区自动跑 + 显式按钮重试） |
| ② | 自动框选"非确定"漂移 | **定案非代码 bug**——相册污染（/sdcard 根目录调试截图抢第一格）误选截图；测试前必做相册检查（full-flow-test §0.1） |
| ③④ | 返回入口混乱 / 归类按钮溢出 | 已修（先 5663396 唯一箭头+Wrap 折行，同日下午推翻为 f4bb17f 双入口） |
| ⑤ | 主体框选含图例带 | 已修（排除图例带 + 桥接隔断，bbox 严格不含图例） |
| ⑥ | 直接拼豆后还原页压底 | 已修（pushReplacement）+ AppBar 双入口定稿（左上=返回上一步保现场，右上 ✕=整页退出） |
| ⑦ | 空名保存豆板 | 已修（框内红字拦截，65d4fed） |
| 五修 | 缩放按钮挡图/图例面板遮图/主体框选含数字边/拼豆页空白黑底/编号间隔不重排 | 已修——ZoomControls 全线外置（还原页外置条/板设置外置条/拼豆页 AppBar）、`_buildLegend` 高度自适应、`_autoDetectSubject` 四边半格步进剔数字带（cov≤0.7 且 cf≤0.35）、BoardPainter 无高亮白底+高亮压暗统一冷蓝灰 0xFF6B7280（豆色/文字同 lerp 0.5 变灰）、`_buildNumbers` 连续段编号隔断重排 |

最新提交见 git log（五修在 f4bb17f 之后）。全流程实测通过：主页 → 还原五步 → 保存 → 板命名 → 拼豆页（`板 52×52 · 已放 0/1371` + 色条齐全），识别基线零差（H7=343）。

**下一步候选**（用户未定，勿擅自启动）：真机验证、更多图纸泛化测试、UI 打磨、【临时调试】块清理。

## 6. 相关文件索引

| 文件 | 用途 |
|------|------|
| `.claude/skills/full-flow-test.md` | 全流程测试手册（**走测试前必读**） |
| `.test/full_flow_test.md` | 问题清单与坐标总表（测试沉淀，还有没修的看这里） |
| `.test/legend_detect_sim.py` | 游程法 Python 复刻（离线对拍用，换输入文件名即可） |
| `.test/test_pic5.png` | 基准测试图（1440×2100，16 色图例，md5 `de94dca48fe2dc334f08b2655b6fc6ec`） |
