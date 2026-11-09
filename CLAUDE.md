# CLAUDE.md

Flutter 拼豆图纸还原 App（Android 优先，web 兼容）。核心链路：相册/拍照导入 → 五步还原（①框图例 → ②九宫格对齐 → ③框选主体 → ④识别复核）→ 保存作品 → 板设置 → 拼豆页。

## 工作规矩（每会话必守）

- **本仓库自动 commit+push**：功能开发完成并验证后直接提交并推送 master，提交信息中文 conventional 风格（如 `feat(board): …`）。（visionfront 仓库相反——那边只给 message 不自动提交，勿混。）
- **禁止用 Read 工具看截图 PNG**（CDN 缓存污染前科，曾整轮假结论）——一律 PIL 像素分析（色块图/直方图/diff）。
- 改动影响流程行为时：改前复现 → 改后同操作对比 + 回归点验证。
- 代码内【临时调试】块是排查期产物，正式版要移除，不要当正式功能。

## 深入工作前先读

| 场景 | 文件 |
|------|------|
| 接续开发 / 项目现状 / 代码地图 / 环境全表 | `.claude/skills/project-status.md` |
| 走全流程 UI 测试（adb 坐标表/页面判别/坑清单） | `.claude/skills/full-flow-test.md` |
| 发新版本 / 出更新公告（模板每版必用，可 `/update-notice` 直调） | `.claude/skills/update-notice/SKILL.md` |
| 动图例/主体检测算法 | `docs/vision_tuning_notes.md` |

## Windows/adb 环境要点（详见 project-status §2）

- 命令链含 adb `/sdcard` 路径时开头 `export MSYS_NO_PATHCONV=1`
- adb pull 本地路径用 `D:/` 风格（`/d/` 间歇性报错）；临时文件放 `.test/`（/tmp 不跨 Bash 调用持久）
- GBK 控制台 python print 中文：`.encode('ascii','backslashreplace').decode('ascii')`
- 测试设备：模拟器 `emulator-5554`（adb 全路径 `/d/Android/Sdk/platform-tools/adb.exe`）
- 交付 APK 必须 `flutter build apk --release` 全架构包（`flutter run` 产物只有 x86，真机装不上）
