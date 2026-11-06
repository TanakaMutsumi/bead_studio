# 抖音无损原图通道——调查结论与开发方案（交接文档）

> 2026-11-06 两轮调查定稿。本文给后续开发会话：所有结论均已实测验证，
> 复现脚本在 `.test/dy_*.py`，真值图在 `.test/dy_flav/`。
> 开发前先读 `CLAUDE.md` 与 `.claude/skills/project-status.md`（工作规矩、代码地图）。

## 0. 一句话结论

app 现行的 SSR 通道（q75.webp，有损 35-39dB）可以升级为**无损原图**：
`detail` JSON 的 **q75.jpeg 档与作者上传原图字节级相同**（md5 全等实测），
该 JSON 只需真浏览器/WebView 页面上下文发一次签名请求即可获得——
匿名可通、无需登录，**WebView 方案在 app 内可行**。

## 1. 质量地图（实测数字）

| 通道 | 质量 | 前置条件 |
|------|------|----------|
| SSR `~tplv-dy-aweme-images:q75.webp`（app 现行，`lib/core/douyin_link.dart`） | 有损：PSNR 35.12dB（耍起 img1）/ 39.33dB（奶龙 img0）vs 原图 | 爬虫 UA 直连，免浏览器免登录 |
| detail `url_list` 的 `.webp` 变体 | 同上（与 SSR 同源同档） | 见下 |
| **detail `url_list` 的 `.jpeg` 变体** | **= 原图字节（无损）**：与 `~noop.jpeg` md5 全等（耍起 img1 955593B、奶龙 img0 100575B 两例交叉验证） | 浏览器/WebView 页面上下文签名请求 |
| `video.origin_cover` 的 `~noop.jpeg` | 原图，但**每笔记只有封面一张** | 同上（仅首图，无通用价值） |

CDN 的 q75 jpeg 模板对 jpeg 上传是**直通不压缩**；webp 模板是真转码。
（旧结论"jpeg 档 +2dB"是误测，已推翻。）

## 2. 已验证事实（每条可复现）

1. **SSR 通道天花板就是 q75.webp**：SSR 页含内嵌 state 已全量审计，
   正文图规格仅 `~tplv-dy-aweme-images:q75` + webp；各爬虫 UA
   （Baidu/Google/bing/sogou）返回同一份包，无 jpeg 变体。→ `dy_seo_scan.py` `dy_ssr_flav.py`
2. **detail 请求可脱离浏览器重放**：真浏览器页面内 fetch 后抓到的完整 URL
   （含 `a_bogus`+`timestamp`+`x-secsdk-web-signature`+`uifid` 参数），
   用 python requests 原样 GET 即 200 全量；**唯一要求 `Cookie: ttwid=…`**
   （无效/缺失 ttwid → 200 空体；其余 30+ cookie、UA、headers 都不需要）。→ `dy_replay.py` `dy_replay2.py`
3. **ttwid 无 JS 铸造**：POST `ttwid.bytedance.com/ttwid/union/register/`
   （body 见 §5）→ 响应 Set-Cookie 取 ttwid；重铸后重放照通。→ `dy_ttwid.py`
4. **签名绑 URL 内容**：URL 里换 `aweme_id` → 403 `Sign Invalid`，
   一把签名只能取一个作品，无跨作品重放捷径。三个签名参数全必须
   （逐个删均 403：`Signature Not Found` / `Sign Invalid`）。→ `dy_replay2.py` `dy_sig_probe.py`
5. **签名时效 ≥11 分钟**（会话内实测，重铸 ttwid 后重放仍通）；未测更长。
6. **`x-secsdk-web-signature` 非平凡哈希**：1764 组合 md5/sha1/sha256
   爆破无命中；PyPI 无纯 python 实现。→ **纯 Dart 离线签名不可行**。→ `dy_final_probe.py`
7. **匿名可通**：验证用的 Edge 会话 cookie 里无 sessionid（未登录），
   页面内 fetch 照样 200。
8. **SSR 图列表 = detail 图列表（同对象、同序）**：两笔记当日对齐
   `same-order=True`。注意**作者会改图**：耍起笔记当天下午从 3 图变 2 图
   （对象 uri 全换），抓包/真值以当次为准。→ `dy_now_align.py` `dy_uri_diff.py`
9. **CDN 图片下载不挑客户端**：签名图片 URL 用任意 UA 直下即可
   （无需 cookie）。→ `dy_collect.py`
10. CDN Accept 内容协商无效（字节不变）；URL 规格段（`~tplv-...` 或
    `~noop`）改写一律 403（签名锁路径+规格）。

## 3. 推荐实现方案：WebView 一次性签名

**原则：SSR 通道保留为唯一兜底，WebView 无损档做成增强路径，失败静默回退。**

```
用户贴链接 → extractDouyinLink（已有）
  → SSR 解析（已有，拿标题+图数+uriKey 列表，webp 缩略图先用）
  → [增强] 打开隐藏 WebView 加载 www.douyin.com/note/{id}
      → 页面 JS 就绪后注入 fetch detail（页面补丁过的 fetch 自动加签）
      → 取回 JSON，解析 images[].url_list 的 .jpeg 变体（按 uri 对齐 SSR 列表）
      → URL 交给 Dart，普通 HTTP 下载（无需 cookie）
  → WebView 任何环节失败（超时/风控壳/无 images）→ 用 SSR webp 结果，UI 不变
```

### 实现要点（均为实测踩坑，勿跳过）

- **WebView UA 必须伪装成桌面 Chrome**。Android WebView 默认 UA 带
  `; wv)` 会命中移动端站（移动 web 是已死通道，只给 `shrink:480` 小图）。
  用 §5 的桌面 UA 串整体覆盖。
- **WebView 视口给桌面宽度**（≥1280 逻辑宽），防 PC 页按窄屏降级。
- 页面加载后 **JS 需就绪再注入**（签名由页面补丁的 window.fetch 完成）：
  Playwright 实测 `domcontentloaded` 后再等 ~6s 稳妥；就绪判据可直接试
  fetch，结果空/异常就重试（总超时建议 15-20s，2-3 次重试）。
- 首开可能有登录弹窗：不影响注入 fetch（Playwright 里按 Esc 只是习惯动作）。
- **风控壳识别**：普通 UA 直接 GET PC 页只有 6341 字节壳；WebView 里
  真渲染 JS 一般不触发，但注入前可查 `document.body.innerText.length` 过小即判壳重试。
- **解析规则**（与 SSR 同思路）：
  - 只取含 `~tplv-dy-aweme-images` 的 URL（过滤头像/贴纸/分享卡）
  - 按对象 uri（路径 `~` 前段）分组，**组内优先 `.jpeg` 后缀**；uri 对齐 SSR 的 uriKey 防错位
  - 校验 `aweme_detail.aweme_id` == 期望 id；`images` 为空 → 按视频作品/失效处理走兜底
  - 标题用 `aweme_detail.desc`（或沿用 SSR 的，两者一致）
- **下载校验魔数**（JPEG `FF D8 FF`）——复用 `douyin_link.dart` 现有思路。
- 不需要 ttwid 铸造（WebView 页面自己带 cookie；图片 CDN 也不挑）。
  §5 的 ttwid+重放配方留给 PC 侧工具或未来无 WebView 平台备用。
- **PNG 上传的笔记未测**：jpeg 档对 jpeg 上传是直通；若作者传的是 PNG，
  jpeg 档可能是转码（无损性不保证，仍应 ≥ webp 档）。可用封面 noop 对拍
  md5 验证（cover uri == images[?] 的 uri 即可对拍）。

### 备选方案（不推荐先做）

- **纯 Dart 直连 detail**：需离线实现 `a_bogus`+`x-secsdk-web-signature`
  （§2.6 已证无现成实现，逆向成本高且随官方更新漂移）。仅当 WebView 方案
  在真机大面积失效时再评估。
- **PC 侧工具**（导出图片再导入 app）：`dy_browser_replay.py` +
  `dy_collect.py` 已是现成脚本。

## 4. 错误指纹速查

| 现象 | 含义 | 处置 |
|------|------|------|
| detail 200 但 body 空（len=0） | ttwid 缺失/无效 | WebView 场景不会遇到；脚本场景重铸 ttwid |
| 403 `Blocked by ArgusSecurityPlugin Signature Not Found` | URL 少签名参数 | 检查 a_bogus/timestamp/x-secsdk-web-signature |
| 403 `… Sign Invalid` | 签名与 URL 内容不符（被改过/过期） | 重新签名，勿复用旧签名换 id |
| SSR 页 6341 字节 | PC 风控壳（普通 UA 直连） | 用爬虫 UA 或真浏览器 |
| `status_code:1 "Url doesn't match"` | 打错端点（m.douyin/iesdouyin web/api） | 死路，勿再试 |
| 图片 403/400 | 签名 URL 被改写或过期 | 只原样使用 URL，勿动规格段 |

## 5. 关键配方（照抄即可）

**桌面 UA**（WebView 覆盖 / 脚本用）：
```
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
```

**页面内 fetch detail**（Playwright/WebView 注入 JS，已被页面自动加签）：
```js
async (noteId) => {
  const q = 'device_platform=webapp&aid=6383&channel=channel_pc_web'
    + '&pc_client_type=1&version_code=170400&version_name=17.4.0'
    + '&cookie_enabled=true&platform=PC&downlink=10&quality_type=0'
    + '&aweme_id=' + noteId;
  const r = await fetch('/aweme/v1/web/aweme/detail/?' + q,
      {credentials: 'include', headers: {'Accept': 'application/json'}});
  return await r.text();  // ~26KB JSON
}
```

**ttwid 无 JS 铸造**（POST `https://ttwid.bytedance.com/ttwid/union/register/`，
`Content-Type: application/json`，Set-Cookie 里取 `ttwid`）：
```json
{"region":"cn","aid":1768,"needFid":false,"service":"www.ixigua.com",
 "migrate_info":{"ticket":"","source":"node"},"cbUrlProtocol":"https","union":true}
```

**detail JSON 取图**（Python 伪码，Dart 同构）：
```python
for img in ad["aweme_detail"]["images"]:
    pick = {}
    for u in img["url_list"]:
        if "~tplv-dy-aweme-images" not in u: continue
        uri = u.split("/")[-1].split("~")[0]          # 对象 uri
        ext = u.rsplit(".",1)[-1].split("?")[0]        # webp / jpeg
        pick.setdefault(uri, {})[ext] = u              # 组内 jpeg 优先
    urls = [v["jpeg"] if "jpeg" in v else v["webp"] for v in pick.values()]
# 封面真值（可选对拍）：ad["aweme_detail"]["video"]["origin_cover"]["url_list"]
# 中含 ~noop 的 URL
```

## 6. 测试材料与验收标准

**测试笔记**（2026-11-06 有效；作者可能改图，改图后对象 uri 会换）：
- 耍起/steamhappy 拼豆：note_id `7687190758894337000`，短链 `https://v.douyin.com/6ARM84jrb5w`，2 图（img1 真值 2160×2498、955593B）
- 辛香儿/奶龙吐舌：note_id `7696956677741325050`，短链 `https://v.douyin.com/yHBNikNQFrc`，2 图（img0 真值 1180×1460、100575B）

**真值**：`.test/dy_flav/{shuaqi,nailong}_{i}_{jpeg,webp,noop}.bin`（当日
detail/noop 原样字节）+ `_manifest.json`（URL 记录）。

**验收**：
1. 两笔记经新通道导入，下载字节 md5 == 对应 `.bin`（笔记未改图时）；
   尺寸与真值一致。
2. WebView 失败注入（断网/壳页）→ 自动回退 SSR webp，功能不劣于现状。
3. 视频链接/失效链接仍走现有错误提示（`DouyinLinkException` 文案不变）。
4. `flutter test` 全绿（现有 `douyin_link_test.dart` 6 项不许回归），
   `flutter analyze` 无新增 error。
5. 模拟器全流程：抖音链接导入 → 缩略图（可先 SSR webp 秒出，无损档到位后
   替换）→ 查看器放大细节应明显优于 webp（局部高频区域）。

**复现/工具脚本**（`.test/`，均 `python -I` 运行）：
`dy_browser_replay.py`（Playwright 抓签名请求+存 detail JSON）、
`dy_collect.py`（解析下载各档）、`dy_replay.py`/`dy_replay2.py`（重放+最小依赖）、
`dy_ttwid.py`（ttwid 铸造）、`dy_sig_probe.py`（签名性质）、
`dy_final_probe.py`（爆破+移动端死路）、`dy_now_align.py`（SSR/detail 对齐）。

## 7. 死路清单（全部实测过，勿再耗时间）

URL 规格段/扩展名改写（403）；CDN Accept 协商；SEO 包找 jpeg（各爬虫 UA 同包）；
移动 web `m.douyin.com`/`iesdouyin.com` 的 `web/api/v2` detail（"Url doesn't match"）；
`iteminfo`（encrypt_data_miss）；`api.amemv.com feed`（通用推荐流不含目标）；
`aweme.snssdk.com feed`（status 2154）；`m.snssdk.com`（连不上）；`slidesinfo`
（服务端损坏）；PC lightbox 查看器（自身就是 q75）；watermark `download_url_list`
（q75+水印）；`original_images`/`image_infos` 字段（恒空）；x-secsdk-web-signature
简单哈希爆破（1764 组合无命中）；PyPI 纯 python a_bogus（不存在）。

## 8. 现有代码挂点

- `lib/core/douyin_link.dart`：SSR 通道全套（提取/解析/下载/异常），
  `DouyinNoteImage{url, uriKey}` 的 uriKey 就是对象 uri——detail 的 jpeg
  URL 按 uriKey 对齐替换即可。
- `lib/features/restore/steps/douyin_import_sheet.dart`：三态面板，
  `_BytesCache` 按 uriKey 缓存——无损档替换发生在同一层。
- `lib/features/restore/steps/link_image_viewer.dart`：共用查看器，无需动。
- 建议新增 `lib/core/douyin_detail.dart`（WebView 签名取 detail）保持
  `douyin_link.dart` 纯净；WebView 依赖建议 `webview_flutter`（或团队熟悉的
  `flutter_inappwebview`，能更方便设 UA/隐藏）。
