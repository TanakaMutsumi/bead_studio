# 图片转换优化笔记（2026-11-17）

> 网上图片→像素图方案的调研结论、本项目取舍与实现锚点。动转换管线前先读。

## 1. 调研结论（网上主流方案盘点）

| 方案 | 核心做法 | 对本项目的价值 |
|------|----------|----------------|
| [Pyxelate](https://github.com/sedthh/pyxelate)（最流行开源像素画转换器） | Sobel 梯度方向感知降采样（HOG 思想）+ 贝叶斯 GMM 拟合调色 + SVD 降噪 + 可选抖动（naive/Bayer/FS/Atkinson） | 「降采样要感知内容，不能纯均值」的出处；抖动按图选 |
| [image2pixel 转换指南](https://image2pixel.com/blog/image-to-pixel-art-conversion-guide) / [dev.to Make It Pixel](https://dev.to/miguelmj/make-it-pixel-make-pixel-art-from-any-image-2o4n) | 通用流程：降采样 → 量化（K-means/median cut/八叉树）→ 感知色距匹配调色板 → 可选抖动 | K-means 预聚类思路；「匹配要用感知距离而非 RGB」 |
| [Stack Overflow: 降采样破坏主色](https://stackoverflow.com/questions/37402727) + [Wikipedia 图像缩放](https://en.wikipedia.org/wiki/Image_scaling) | 盒式均值把边缘两侧颜色混合出新颜色（灰边 fringe），众数/主色采样保留代表性色相 | **盒式均值的边缘混色缺陷定论**——本项目同病：红蓝图边缘紫灰圈 |
| [Delta E 101](http://zschuessler.github.io/DeltaE/learn) / [PubMed Gómez-Polo 2016](https://pubmed.ncbi.nlm.nih.gov/26412001) / [Datacolor](https://www.datacolor.com/business-solutions/blog/color-systems-cielab-cie2000) | CIE76 在饱和蓝区高估色差；CIEDE2000 与人眼感知一致性最好（工业配色金标准） | **豆色匹配从 ΔE76 升级 CIEDE2000 的依据** |
| [W3C OKLab 讲座](https://www.w3.org/Graphics/Color/Workshop/slides/talk/lilley)（Chris Lilley） | OKLab 色距均匀性优于 CIELAB（尤其高彩度色调保持） | 备选路线；CIEDE2000 验证文献更厚，选了后者 |
| 拼豆工具（[makebead](https://makebead.com)、[beadmapper](https://www.beadmapper.com)、[pixel-beads.net](https://www.pixel-beads.net) 等） | 自定义格数 + 色数限制；多数提供抖动开关 | 「自定义格子数」是品类标配；抖动对大色卡反而添噪（与本项目 v0.2 前实测一致） |

## 2. 本项目取舍（2026-11-17 落地）

### 2.1 采纳

1. **CIEDE2000 匹配**（`quantizer.dart#ciede2000` + `Quantizer.nearestIndexDe00`）
   - 图片转换专用；**图纸还原的色彩回退仍走 ΔE76**（识别基线调参口径，`quantizePixels` 默认 lab76，勿动）。
   - 性能两段式：ΔE76 廉价距离全表扫 + 下界剪枝（`ΔE76/8 ≥ 当前最优 ΔE00` 则跳过精算）。剪枝常数 8.0 是**实测校准值**：MARD 291 色 × 400 采样最差 ΔE76/ΔE00 比率 6.48（ΔE00 对大色差/高彩度差压缩剧烈）；3.0/4.5 会错杀真最近色（失准 +0.1~0.6 ΔE00，视觉难辨但性质不对）。
   - 相同 RGB 结果 memo（降采样后同色像素大量重复）。正确性由 `test/convert_de2000_test.dart` 双保险锁：Sharma 2005 官方 17 组向量（含色相回绕/近中性/暗色分支）+ 400 采样与全表暴力 argmin 零差。
2. **主色感知降采样**（`pixel_engine.dart#PixelEngine.dominantResize`）
   - 每目标格建 RGB333 直方图（512 bin），严格多数（>50%）bin 的均值出格色；无多数（渐变/混色格）回退整盒均值保抗噪。
   - 只在两维都缩小时启用；小图放大回退盒式均值（主色判定无意义）。
   - 单测锁定：5:3 多数不混色（旧均值出 (159,0,159) 紫灰）、平局回退均值、7红+1白噪点不污染。
3. **自定义无上限格子数 + compute isolate**
   - `PixelEngine.convert` 改 `width/height` 分离参数；中心裁剪推广为 `centerCropAspect`（object-fit: cover，正方形即旧中心方）。
   - 裁剪/降采样/量化/去孤立点全链入 `compute`（解码留主 isolate——Skia 依赖）。
   - UI（`import_page.dart`）：预设四档 + 「自定义」段（哨兵 0，同板设置 combobox 惯例）→ 宽/高自由输入对话框（≥1 拦截、无上限、`高按图片比例算` 按钮、实时颗数/耗时提示）；单边 ≥300 或总格 ≥10 万提示「转换耗时较长」。
   - `maxSpeckSizeFor(w, h)`：孤立点尺寸阈值随两边较大者放大（正方形行为不变）。

### 2.2 明确不采纳（有据）

- **误差扩散/有序抖动**（FS/Atkinson/Bayer）：v0.2 前实测——291 色 MARD 大色卡下抖动孤立率反而更高（52 板基线 16.9% → 29.7%/21.2%/44.1%），抖动是**小色卡**（≤32 色）恢复灰度的手段，拼豆大色卡不需要。拼豆工具普遍提供抖动开关是品类惯性，不是质量证据。
- **K-means/贝叶斯 GMM 预聚类选色**：我们的调色板是**固定实物色卡**（291 色全可购），预聚类会丢掉细粒度豆色差异；`unifyNearColors`（ΔE<10 视觉重复合并）已覆盖「减少碎色」诉求。
- **Sobel 边缘感知降采样**（Pyxelate 路线）：主色感知采样已解决边缘混色，Sobel 版实现复杂度高一个量级且对照片类输入收益有限。
- **OKLab**：实现更便宜，但 CIEDE2000 的工业验证文献更厚（配色/印刷行业口径），选验证优先。

## 3. 已知边界

- 超大格（如 400×400）转换在 isolate 内数秒级；不去孤立点的 detail 风格更快。UI 只提示不阻拦（需求即「无上限」）。
- CIEDE2000 剪枝常数 8.0 基于 MARD 实测；换更极端彩度跨度的新色卡时，重跑 `convert_de2000_test.dart` 的暴力对拍（400 采样）验证，失准则上调。
- `import_page.dart` 是 **CRLF** 行尾，Edit 工具按 LF 匹配会静默失败——用 python 脚本改（本轮实测踩坑）。
