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
| `lib/core/legend_detect.dart` | 图例区检测 v9（行游程法，app/模拟器唯一实现；canonical：宽 [1000,2048] native，窗外缩 1440） |
| `lib/core/board_detect.dart` | 列序尺检测 detectRulerTop（板底硬边界，主体检测封底用） |
| `lib/core/decode_image.dart` | 解码 Skia 优先 + 纯 Dart 回退（decodeImageRobust）；显示层重编码 JPEG + 长边限幅 |
| `lib/core/xhs_link.dart` / `lib/core/douyin_link.dart` | 链接导入解析（免登录）：分享文案提取链接；xhs 走 img-bd 域名+保 notes_pre_post 段拿 6400px 原图；douyin 走 Baiduspider UA→`share/note/{id}` SSR→JSON-LD 拿 q75.webp 签名 URL（按对象 uri 去 CDN 镜像重，~30 天时效） |
| `lib/features/restore/steps/xhs_import_sheet.dart` / `douyin_import_sheet.dart` / `link_image_viewer.dart` | 选图页链接导入面板（输入/解析/网格挑选三态，抖音同构）；共用大图查看器 `LinkImageViewerPage`（LOD 全分辨率裁片/双击 2.5×/保存相册，xhs/抖音共用） |

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
- 代码内【临时调试】块是排查期产物——**v0.2.0 发布前已全量清理**（8330fe3，2026-11-07：OCR 调试入口/面板/连线层、OcrDebugInfo 快照链、全部识别指纹 logcat 已删；`dbgText` 保留是算法工作字段、legend_ocr 内 `dbg`/`onDbg` 可选诊断钩子保留全 null 零成本）。再排查识别问题需临时加打印时，收尾记得删
- 改动影响流程行为时，测试方案走 CLAUDE 通用规矩：改前复现 → 改后同操作对比 + 回归点

## 5. 当前进度（2026-11-07）

**状态：v0.2.0 已交付**（识别链路含二遍补读/进度百分比/自定义列数，抖音无损通道，调试块全清；dist APK+公告已重出，release smoke 过）。已知问题清单 ①-⑦ 全部收口：

| # | 问题 | 结论 |
|---|------|------|
| ① | 进③不自动框选主体 | 已修（`_autoDetectSubject` 无选区自动跑 + 显式按钮重试） |
| ② | 自动框选"非确定"漂移 | **定案非代码 bug**——相册污染（/sdcard 根目录调试截图抢第一格）误选截图；测试前必做相册检查（full-flow-test §0.1） |
| ③④ | 返回入口混乱 / 归类按钮溢出 | 已修（先 5663396 唯一箭头+Wrap 折行，同日下午推翻为 f4bb17f 双入口） |
| ⑤ | 主体框选含图例带 | 已修（排除图例带 + 桥接隔断，bbox 严格不含图例） |
| ⑥ | 直接拼豆后还原页压底 | 已修（pushReplacement）+ AppBar 双入口定稿（左上=返回上一步保现场，右上 ✕=整页退出） |
| ⑦ | 空名保存豆板 | 已修（框内红字拦截，65d4fed） |
| wx1 泛化 | 微信图自动框图例框贴底（误框页脚灰线带） | 已修（图例检测 v4：近白含平灰背景 + 页边框游程剔除 + 色数打分；主体检测同源剔边框；①页加「清除选框」按钮；离线 wx1 命中真图例/test_pic5 零差，**模拟器全流程回归待做**；release APK 已出给用户真机试用） |
| 五修 | 缩放按钮挡图/图例面板遮图/主体框选含数字边/拼豆页空白黑底/编号间隔不重排 | 已修——ZoomControls 全线外置（还原页外置条/板设置外置条/拼豆页画布下外置条，AppBar 顶置一轮后按用户反馈撤回）、`_buildLegend` 高度自适应、`_autoDetectSubject` 四边半格步进剔数字带（cov≤0.7 且 cf≤0.35）、BoardPainter 无高亮白底+高亮压暗近黑深冷灰 0xFF374151（豆色 lerp 0.75 沉底、文字 0.5 保可读，经 158→113→64 三轮用户反馈迭代定稿）+ 文字层控件常显与未选中文本开关 + 拼豆页粗线颜色会话内可改（共用 `major_color_picker.dart`）、`_buildNumbers` 连续段编号隔断重排 |
| 拼豆色条排序 | 完成色垫后 + 图例同款四模式排序 | 已落地（2026-11-02）——`orderAssembleColors`（assemble_page 顶层纯函数）：剩余 0 的色整段垫后，段内按 色号序/多→少/少→多/位置序（位置序=totals 插入序=网格扫描首现序，图例物理位置序未存档无从还原，与用料统计页同口径）；排序下拉并入摘要行（legend_step 同款）；初始沿用作品 meta.sortMode（`legendSortFromName` 抽到 restore_types 共用，stats 页去重），会话内切换不回写（板级视图防跨作品互相覆盖）；测试 `test/assemble_color_order_test.dart` 11 项（含 412 逻辑宽窄屏溢出回归） |
| 六项 UI 改进 | 复核选中灰显/原位聚焦/手圆缩放/细参考线/字色三模式/进③自动全图 | 已落地（2026-11-02，63e856c）——① 复核缩略图选中态 `ColorFilter.saturation(0)`+黑罩 35%+`ReviewMarksPainter` 填充改黑 55%（蓝框白勾保留）② 原位查看 `_CellFocusPainter` 外圈 Path.difference 拉黑 50%+黄框高亮目标格（不再用边框挡豆号）③ 手圆绘制抽 `paintHandleCircle` 公共函数（Sel/CornerGrid/MiniGrid 三处共用），painter 挂 `repaint: ctrl`，线宽/半径按视图 scale 补偿；`_hitSelHandle` 命中半径同步除 scale ④⑤ BoardPainter 细线 0.5/粗线 1.2/边框 2.2（÷scale）+ `LabelColorMode` 三模式（自适应默认：浅豆黑字/深豆白字，H2 可见）拼豆页对比度图标切换；色条 chip 文字对比度同步加强 ⑥ 进③框主体/返回③时 `_viewerCtrl.value = Matrix4.identity()` 自动全图化。构建遇 daemon 卡死×2，改 gradle 离线 x64 配方装机（见 memory gradle-offline-x64-build）；analyze 0 错、52 测试全过、已装模拟器待用户手测 |
| 图例识别防冻结（2026-11-05） | 识别卡顿 | **已收口**。Dart 侧（2c6decc）：`decode_image._fromRawRgba` 逐像素拷贝入 compute；`restore_page` 自动框选/框主体/识别三链路重活入 isolate；`legend_ocr_runner` 段图 RGBA 落临时文件走 `ocrRgbaFile` 只传路径；`native_ocr.dart` 通道桥接（MissingPluginException/PlatformException→回退插件路径）。Kotlin 侧在 MainActivity.kt（后台 executor 建位图+推理、`copyPixelsFromBuffer` 直拷保 F19/C4 读数逐字节一致），随小红书功能提交。**S2 归因定案（当日续测）**：早期"mlkit .so 占主线程 ~50%"系 simpleperf 误归属——干净复测（全进程 simpleperf + kill -3 全线程栈 + Dart VM profiler 三方对齐）证实 **ML Kit 推理 0% 在主线程**（noncooperative-×4/ocr_segm×3/vkp-mediapipe 池原生线程并行跑），主 isolate 仅 ~15% CPU：60% self 在 `_drawFrame` 渲染钩子（spinner 动画 tick 驱动的常规重绘）+11% syscall+3.5% `applyPhantomParenStrip` 后处理；识别期间连拍 diff 证实 spinner 连续转动=UI 存活。旧"phase_probe 忙段 4-8s"是利用率>40% 的墙钟段长非 CPU 秒数。**注意**：VM service 的 `setVMTimelineFlags` RPC 会引爆引擎 DartWorker SIGSEGV（libflutter strdup 空指针），排障勿用；相册首格排序键=文件 mtime（date_modified）非 date_added——adb push 保旧 mtime 会排到后位，push 后要 touch+`content call --method scan_file`（su 2000 执行，root uid 报"UID 0 has no associated package"） |

| 性能三项复核（2026-11-05） | 识别耗时 / 识别期卡顿 / 放大卡顿 | 模拟器冷进程实测：**识别墙钟 4.7–9.3s**（含段图切分+OCR+配对），主线程 CPU 仅 1.45–2.64s（15–30%），spinner 连拍 diff 全程连续转动=无冻结；结果指纹稳定（16 对、C16=433，与基线零差）。**放大无卡顿**（显示位图已 4096 上限）：① 按钮缩放 ×6 连点 0.85s CPU/3.49s 墙钟（24%）；① 无捏合手势是设计如此（InteractiveViewer 属 ③）；③ 捏合放大 0.29s/1.73s（17%）、放大态平移 0.23s/次、快速平移 ×4 0.51s/2.73s（19%）——全部远离饱和。帧级 vsync 量化在 API36 模拟器无工具可用（timestats/--latency/gfxinfo 均不跟踪 Flutter 帧），卡顿结论以主线程 CPU 占用+画面连拍 diff 为准 |
| 三项体验改进（2026-11-06） | ①图例总豆数 / ②识别期 UI 锁 / ③复核范围连选 | **已落地实测**（用户 2026-11-06 三点反馈）：① `LegendStep._totalChip` 摘要行右侧「共 N 颗」徽标（Listenable.merge 全部 countCtrl，敲键只重建徽标；有未填项括注「X 色未填」）——实测 test_pic5 共 1336 颗、改 C16 433→500 即时变 1403；② `_stageBusy`（_legendBusy/_detecting/_recognizing/_autoDetectBusy 任一）时 body 整体 `AbsorbPointer`+black38 遮罩+文案（`_busyBarrier`）——识别中重框选/挪九宫格/切模式全锁死；新 `_autoDetectBusy` 盖载入预框/魔法棒/主体自动框选（`_autoDetectSubject` 拆 `_autoDetectSubjectLocked`+try/finally 收锁），`_scanLegend`/`_recognize` 加重入守卫、`_switchPalette` 守卫扩到 _stageBusy（AppBar 不被遮罩拦）——实测图例识别 +0.3s 遮罩（lum 91.6→58.4=−38%）、识别中滑动被吞、锁随完成解除；③ 复核截图墙长按拖选改**范围连选**：`_dragAnchorCR` 锚点格 + `_applyDragRange`（锚点到指下格整片矩形，绝对语义可重放、自动滚屏重放全范围），`_tileCR`/`_cellAt` 重构——实测 4×2 对角拖=清除选中(8)（旧路径式~4-5 格）。回归：保存 bfx2→拼豆页 `已放 0/1307`（=④总豆数）零差。**注意**：test_pic5 ③框选 v4 后 bbox=[126,272 1344,1616] rowsCols=43×39（旧基线 50×45 未复核过 v4），识别 H7 对账——待办基线核对时一并看 |
| 近白空白误判 + 复核每行列数（2026-11-06 二轮） | 空白吸成 H2 / 截图墙列数固定 | **已落地实测**（用户同日二轮反馈，0792177）：① `_recognize` 近白分支加 `textless`（格内无任何色号文本）——候选含近白色时（H2=(251,251,251) 与白纸底 ΔE 微小，纯色判据天然不可分，文本是唯一判据）旧 candNearWhite 逃逸把白底成片吸成该色；现无文本近白格仍直判空白，有文字痕迹（读残色号）保守旧路径（09-08 白豆回归保护不撤）。合成复现图 `.test/gen_h2_pic.py`（24×24 图例含 H2，232 空白/344 有色；格距 48 检测零差，主体自动框选在平涂合成图失败→手动拖框吸附 24×24 精确）：改前 `H2=268 BLANK=0` → 改后 `H2=36 BLANK=232` 与真值一分不差；test_pic5 改前改后指纹**逐字节零差**（`39x43 OCR 1202/1677 BLANK=370 C16=432…H7=335`）② 复核截图墙每行列数可选 4/5/6/8/10/12（`_reviewCrossCount` 页面态 + `_crossCountPicker` 缩放条左端常显——chips 横滚末端会被裁不可发现；总览模式不显示）——实测选 12 → dump 标签计数每行恰 12 块，12 列下范围连选 3×2=清除选中(6) 精确。**发布 v0.2.0**：pubspec 0.1.0→0.2.0，`dist/bead_studio_v0.2.0.apk`（全架构 arm/arm64/x64 + mlkit 验证，模拟器冒烟主页四钮正常），根目录 `CHANGELOG.md` 建立（Keep a Changelog + SemVer 口径，0.1.0/0.1.1 追溯补档），用户公告 `dist/更新公告_v0.2.0.md` |
| 抖音链接导入（2026-11-06） | 选图页第 4 钮「抖音链接导入」 | **已落地实测**（用户指令：画质结论无论如何先上功能）——`core/douyin_link.dart`：分享文案提 `v.douyin.com` 短链 → **Baiduspider UA** 原生通道逐跳 302（普通 UA 只给数据加载已死的 JS 壳页）→ `iesdouyin.com/share/note/{id}/` SSR → JSON-LD `@type=article` image 数组 `q75.webp` 签名 URL（对象 uri 去重多 CDN 镜像；签名不挑客户端 ~30 天时效）；`steps/douyin_import_sheet.dart` 三态面板与 xhs 同构；查看器从 xhs 抽共用 `link_image_viewer.dart`（行为不变），顺手修 `photoLodCropRect` 守卫（原图长边≤显示上限 LOD 永不触发——原版小图 zoom=1 也过阈值，双击回整图会白算一次裁片）。**画质定案**：免登录通道天花板=q75.webp（分辨率=作者上传尺寸不缩水、PSNR~35dB、平坦色块色偏 0.6 级对识别零风险）；+2dB 的 q75.jpeg 仅浏览器页面内 detail JSON url_list 可得，免浏览器通道全试尽（detail API×多平台参数/aweme feed/api.amemv/aweme.snssdk/iesdouyin iteminfo/m.snssdk/lightbox/mobileweb）皆无。模拟器实测：耍起链接 3 图进①框图例、奶龙链接全流程至识别 18 色/1403 颗、xhs 假链接冒烟不回归；单测 8 项新增、全量 76 绿 |
| 抖音无损原图通道（2026-11-07，12a472b） | SSR webp → DOM 提取 q75.jpeg 原字节 | **已落地 e2e 字节级验收**——隐藏 WebView（桌面 UA+1280 视口）加载 PC 笔记页，hydrate 后 DOM 里就有整份 url_list（含 q75.jpeg 签名 URL，=作者上传原字节 md5 实证），正则提取零 API 请求零签名；detail API 在 WebView 内被 Argus 加固层扣死（fetch/XHR 永久 pending、iframe 无签名 403 Uifid）勿再试。实现 `core/douyin_detail.dart`（DouyinDetailProbe + mapJpegUrls + `douyinObjectIdOf` 对齐键——dir 段跨通道不稳定勿用 uriKey）；提取正则两坑：DOM 里 `&` 是字面 `&` 须全量还原、URL 尾随 `\"` 残影要在字符类排除 `\`。验收：shuaqi/nailong 三图 len+head+tail 指纹==`.test/dy_flav/*.bin`、403 回退 SSR 两实证、83 测试绿。**CDP 勿 attach**（反调试投毒 renderer SIGTRAP 杀整个 app），排查走 setOnConsoleMessage→logcat。全部配方/死路见 `docs/douyin_lossless_channel.md` |
| 二遍逐格补读 + 进度百分比 + 自定义列数（2026-11-07，0ce0af9） | 漏读格错色 / 大图识别无进度 / 列数档不够 | **已落地全流程回归**——① `ocrCellsSecondPass`+`encodeTilesJpg`（legend_ocr.dart）：一遍未读到色号的格外扩 30% 裁剪、放大到槽宽 160、拼白底瓦阵（亮度极差<22 留白不喂）分批 ~120 瓦补读，`onBatch` 每批回调；② `ocrCells` 分带识别（~350px/带 2-8 带，`onBand` 进度回调），restore_page 遮罩文案「已确认 N/M 格（x%）」；③ 复核列数「自定义…」弹窗 2-16（含 PopupMenu initialValue 断言修复）。**test_pic5 基线（改后新基准）**：`识别 39x43 | OCR命中 1195+80(补读,色彩分歧1)/1677`、总豆数 1307、图例 16 色 1336 颗——对比 0792177 旧基准整图单遍 1202：分带一遍 -7（带缘元素归位差，补读全兜住），二遍 +80 净增 73；39×43 与上会话 45×50 框内容一致（两框均 1307 豆，大框只是多包 573 空白格）。新增 `test/review_cross_count_test.dart`，83 测试绿 |
| 豆田定名 + 图标体系 + v0.2.0 大版本重整（2026-11-07~09） | 定名/自适应图标/长图/交付重组 | **已定稿**——① 定名「豆田」七处统一（caa5b07）；② 图标 13 稿 5 轮定稿「图纸格豆苗」（`scripts/gen_app_icon.py` art_M，apply 一键铺全部槽位：legacy 5 密度/自适应三层 5 密度/web 4 图+favicon），迭代长图 `docs/icon_design_journey.py→png`（反馈一律总结成改善需求不引原话）；③ 自适应三连修：分层错位→前景满画布同坐标（29a9af7）、遮罩内灰框→满铺出血格线无限延伸（647a5d7）、豆苗尺寸三轮定稿 **58% 居中出血**（54598e4，实测桌面遮罩=65% 圆 r=0.326C，居中方形上限 46%，用户拍板不配遮罩直接放大）；④ **横线丢失坑**：`_bleed_lattice_mask` 用 `base is off` 身份判断，ax0/ay0 同值时 CPython 常量合并为同一对象→两遍全画竖线，已改轴标签判断（6a07835）——改等值参数后必须复验双向格线；⑤ **交付重整（2026-11-09，用户指令集合成 v0.2.0 大版本）**：CHANGELOG「未发布」段（四项改进+豆田）并入 `[0.2.0] 2026-11-09`，`dist/更新公告_v0.2.0.md` 重写（15 项全量）+ 新生成器 `scripts/gen_update_notice.py`→公告图 **v4 定稿（2160×4662，四轮返工）**：头图格纹+圆图标、标题与徽标净距≥30px（v3 压叠被点名）、定名卡、四个亮点数据块（大字+两行完整说明，禁凑数块）、五功能卡双列小卡（Segoe UI Emoji 彩色图标+粗标题+灰说明，奇数末条通栏）、无安装卡；内容只讲最终结果不写设计过程——模板固化 `.claude/skills/update-notice.md` 每版必用，`dist/bead_studio_v0.2.0.apk` **替换为全量包**（96,520,229B，md5 `e9aa588b…5b69`，含豆田定名+图标体系），1105/1106/1107 时间戳包保留作历史，pubspec 保持 0.2.0 不动 |
| 四项改进（2026-11-07 二轮） | 九宫格步长档 / 豆板选择页 / 链接导入防误触 / 图例识别提速+进度条 | **已落地模拟器实测**——① ②面板步长档 chips 0.01/0.05/0.1/0.5/1（默认 0.01），格子大小±与微移共用 `_alignStep`，方向钮统一线型箭头——实测默认档 +0.01（31.33→31.34）、切「1」档 +1.00（→32.34）；② 主页「开始拼豆」先入豆板选择页（新 `board_select_page.dart`：BoardPainter 缩略图/件数/时间/重命名/删除/新建空板，形态同我的作品，pushReplacement 导航；首次空列表自动跳新板设置保留旧直达习惯，删光后不跳）——实测空板自动跳、存板 bd1 后列表/点卡带 `initialBoard` 进板设置全链；③ xhs/抖音导入面板忙碌锁：解析中 PopScope 拦返回+点外部（顶部 snackbar「正在解析链接，请稍候…」实测），下载中内容 AbsorbPointer 黑26 遮罩但留 scrim 逃生口；**`enableDrag:false` 必须连 `showDragHandle` 一起去掉**——SDK（bottom_sheet.dart:373）在 enableDrag:false 时反而给把手单独挂 `_BottomSheetGestureDetector`（把手保留为关闭途径），实测留着把手照样能拖关；④ 图例识别加 24MP 像素预算 `kLegendScaleBudgetPx`（legend_ocr_runner 压轴 clamp）+ 全链进度回调（阶段文案+n/m 计数条；core 四条 fix* 链 `FixProgress` 回调，runner 注入文案）——**6K 可丽饼原图（5960×7976，图例条 5749×537）打点实测**：Before 预算禁用态 prep ×7.06=40606×3793≈154MP 耗 37.7s、13 段 OCR 11.8s，**84s 处补读链 java.lang.OutOfMemoryError（139MB 单笔分配）进程死亡**（用户「识别特别久」根因坐实：慢+内存爆）；After ×2.79=16014×1496=24MP，prep 5.4s、5 段 OCR 3.3s、补读盲区 27.5s，**总 36.9s/35.1s 两跑均完整出 37 色 2585 颗**；test_pic5 回归 16 色/1336 颗/3.5s 与 §6 基线零差（≤14MP 常规图不触预算）。临时 [legendT] 打点已全清，83 测试绿。**交付**：用户要求不升版本——`dist/bead_studio_1107_0555.apk`（时间戳命名同 1105/1106 先例，96,601,636B，md5 `6fdbe2df…b522`，全架构 release + 裸 gradle 前手工剔 Registrant integration_test 块），v0.2.0 正名包（95,905,044B）保留未动，模拟器装包冒烟主页四钮+豆板选择页（bd1 卡片）正常；pubspec 保持 0.2.0，CHANGELOG 四项仍在「未发布」段待下次 bump 归位 |
| 终止按钮二轮打磨（2026-11-09 三轮） | 终止语义清零 / 按钮不醒目 | **已落地**（用户二点反馈）——① 终止=进度彻底清零：`_confirmCancelBusy` 弹窗前快照 `wasLegend`，确认终止时除忙锁/进度字段外，终止图例识别的场合连页面上的识别清单一并清（dispose countCtrl+置空+清行列输入）——不留「进度还在」的表象；终止其他链路（格距/主体等）不动清单（那是另一步的成果）；② 终止钮 white12 小字 → **红底白字胶囊钮**（0xFFE53935，padding 26/8 + 圆角 19 + 字重 600），遮罩上像素实证按钮区 90% 红色。**验证**：识别完成 37/2585 → 再识别 4s 终止 → dump 无「图例 N 色」无清单行（清零生效）；pic5 回归 16/1336；83 测试绿。**①页结果态没有「重新识别」入口**（只有重新选图/下一步）——带旧清单的终止只能经改框（手势注入难），清单清零由同批 setState 机制推定（m5/m6 已实证终止机制+锁清+进度清） |
| 忙操作终止按钮（2026-11-09 二轮） | 遮罩期无逃生口 | **已落地模拟器实测**（用户：有进度条的操作都要能终止）——`_busyGen` generation 作废机制：新链路入口与用户终止各 ++，链路快照比对不一致即弃结果只收锁（isolate 无法强杀，终止=UI 立即解锁+后台下个检查点自停，避免双链路并发跑大图 OCR 的内存峰值）。遮罩（`_busyBarrier`）加「终止」TextButton → AlertDialog（继续等待/终止）；确认时若链路已自然完成只关弹窗提示「操作已完成」不误删刚落定的结果（pop(ctx, !_stageBusy) + await 后复查）。检查点全覆盖：`_pickImage`（readAsBytes 后）、`_loadImageBytes`（decode 后/预框后）、`_scanLegend`（prep compute 后/onProgress 回调抛/pairs 返回后）、`_initMiniGrid`、`_autoDetectSubjectLocked`、`_recognize`（resolveBand/onBatch 回调抛+写结果前）。core 层仅加公开 `BusyCancelled` 异常（legend_ocr.dart）+ ocrCells/ocrCellsSecondPass 的 `on BusyCancelled rethrow` 放行（其余异常照旧吞空结果）；runLegendOcr 的 catch(_) 吞取消=空 pairs 返回，调用方 gen 检查丢弃，core 单测零影响。**实测**：6K 图例识别冷跑 4s 处终止 → 3.5s 后无结果写入、「识别图例」按钮回归、页面可操作；终止后再识别完整出 37 色/2585 颗零差；继续等待分支识别正常完成 37/2585；test_pic5 回归 16 色/1336 颗；83 测试绿、analyze 0 错。**adb 验证局限**：6K decode 热跑 ~1s，遮罩渲染+两跳 tap+弹窗 semantics 挂载延迟掐不进窗口——decode 中途终止未在 adb 下复现（真实手指无此延迟，机制与已验证的识别终止同构） |
| 三项体验修复（2026-11-09） | 导入无反馈 / 选图页无返回 / 补读链进度圈卡 | **已落地模拟器实测**（用户三点反馈）——① `_pickImage` 解码期 `_decoding` 置位并入 `_stageBusy`（遮罩文案「正在导入图片，请稍候…」），readAsBytes 包 try/catch 报「读取图片失败」——实测 6K 相册导入帧 2-11 全帧有变化、遮罩区 black38 + spinner 白像素实证；② 选图页 AppBar 常驻返回钮（pick 步 `Navigator.pop` tooltip「返回主页」，其余步仍 `_confirmBack`「返回上一步」）——实测 tap 回主页 ✓；③ **fix* 补读链重活出主线程**（legend_ocr.dart）：新增 `GapVariantArgs/GapVariantOut` + 顶层 `buildGapVariant` + `compute` 包装 `gapVariant()`——copyResize/全像素反相/binarize/_binarizeDarkBarText/_adaptiveBinarize/padding/rgba 构建全进 isolate（Isolate.exit 传回 v+rgba+inverted+rgbaInverted），`fixOrphanCountCodes` 梯子、`fixOrphanCodeCounts`/`fixRightCountsByLayout`、`fixBlindGridCodes`、`ocrGapVariants` 变体循环全部改走之；`ocrRgba` 加 `rgba:` 参数直传预备字节（native_ocr 小改），`ocrGapText` 加 `inverted/rgba/rgbaInverted` 参数避免主线程重算。算法顺序/懒惰性/像素位级不变，注入 `ocrGap` 的单测路径等价图像。**实测**：6K 图例识别 70 帧 burst，改前 32.5s 含 4 段冻结（~15 stalled 帧≈7s，含补读盲区段），改后 12s 0 stall run（仅 1 孤立帧=点击瞬间），**结果 37 色/2585 颗与改前逐项零差**；test_pic5 回归 16 色/1336 颗。83 测试绿、analyze 0 错。**验证期环境事故**：模拟器图形栈崩（screencap 全黑但进程活/语义树完好/HOME 也黑）判为模拟器问题非 app——`-no-snapshot` 冷启动恢复，教训入 memory emulator-gfx-blackout 与 full-flow-test §7 |

最新提交见 git log（五修在 f4bb17f 之后）。全流程实测通过：主页 → 还原五步 → 保存 → 板命名 → 拼豆页（`板 52×52 · 已放 0/1371` + 色条齐全），识别基线零差（H7=343）。

**下一步候选**（用户未定，勿擅自启动）：用户真机反馈跟进（v0.2.0 已交付：识别基线见 full-flow-test §6）、更多图纸泛化测试（wx1 真机流程未复核）、UI 打磨。~~软件定名~~（2026-11-07 已定名**「豆田」**：manifest label（原竟是裸代号 bead_studio）/main.dart/home AppBar/README/pubspec description/web title 七处齐改，launcher 与主页统一显示豆田）。~~【临时调试】块清理~~（2026-11-07 已完成，8330fe3）。

## 6. 相关文件索引

| 文件 | 用途 |
|------|------|
| `CLAUDE.md` | 每会话自动加载的常守规矩（自动 commit+push / 禁 Read 看图 / 环境坑）——skill 未触发时的保底层 |
| `.claude/skills/full-flow-test.md` | 全流程测试手册（**走测试前必读**） |
| `.test/full_flow_test.md` | 问题清单与坐标总表（测试沉淀，还有没修的看这里） |
| `.test/wx_replica6.py` | 游程法 v9 PIL 复刻（调参真相源，对拍用） |
| `docs/vision_tuning_notes.md` | 视觉检测调参笔记（v1→v9 演进/教训/方法论——动检测规则前先读） |
| `.test/ruler_detect.py` / `row_probe6.py` / `annotate_q.py` | 列序尺原型 / 行特征探针 / 标注图生成 |
| `.test/test_pic5.png` | 基准测试图（1440×2100，16 色图例，md5 `de94dca48fe2dc334f08b2655b6fc6ec`） |
