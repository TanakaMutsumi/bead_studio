import 'package:flutter/widgets.dart';

/// 平板 / 宽屏适配：断点、判定与限宽工具
///
/// 2026-11-22 用户反馈「平板上看到的 UI 不一样」。此前全仓没有响应式逻辑，
/// 所有页面按手机竖屏（~393dp 宽）用 Row/Expanded 铺满写的，放到平板上
/// 被横向拉伸 2~3 倍。这里只按**窗口逻辑尺寸**分三档，不看机型——手机、
/// 平板、分屏、桌面窗口一律同一套规则：
///
/// | 档位 | 判定 | 手机竖屏 / 平板竖屏 / 平板横屏 |
/// |------|------|------|
/// | 紧凑 | 宽 < [kMediumWidth] | 手机竖屏：原有布局，**逐像素不变** |
/// | 中等 | 宽 ≥ [kMediumWidth] | 平板竖屏、手机横屏：单列内容不再铺满——限宽居中或分栏 |
/// | 展开 | 宽 ≥ [kExpandedWidth] 且高 ≥ [kExpandedMinHeight] | 平板横屏、桌面窗口：画布页改「画布居左 + 控制面板靠右」 |
///
/// 平板竖屏（~800dp 宽）不够展开档：右侧面板占 360dp 后画布只剩 ~440dp，
/// 反而比上下堆叠更小，所以竖屏平板走中等档的堆叠布局。
const double kMediumWidth = 600;

/// 展开档的最小宽度（Material 3 窗口尺寸类「expanded」的起点）
const double kExpandedWidth = 840;

/// 展开档的最小高度：手机横屏（~851×393）宽度够但高度不够，堆叠布局
/// 和侧栏布局都放不下，不进展开档（保持与改动前一致，不在本次适配范围）
const double kExpandedMinHeight = 500;

/// 右侧控制面板的宽度：接近手机竖屏的可用宽度，面板里的按钮行 / 输入行
/// 沿用手机排版，不必另调。**固定不随窗口收窄**——面板内容（分段按钮等）是
/// 按手机可用宽度排的，收到 ~270dp 会横向溢出
const double kSidePanelWidth = 360;

/// 放下右侧面板后，左侧主区至少还要有这么宽（预览 / 图区才有意义）
const double kSidePanelRest = 340;

/// 宽度 [width] 的窗口能否在右侧放下 [kSidePanelWidth] 的面板：
/// 展开档（平板横屏 / 桌面）必然满足；中等档里 600~700dp 的窄窗口不满足
/// ——硬放会把左侧主区挤到 ~200dp，这类窗口保持上下单列
bool fitsSidePanel(double width) =>
    width >= kSidePanelWidth + 1 + kSidePanelRest;

/// 图区下方缩放条的整体高度：`ZoomControls` 按钮 34 + 页面 `_zoomStrip`
/// 的上下 padding 各 2。展开档按它反推图区视口高度（图整幅装入视口），
/// 这两处尺寸改动时同步改这里
const double kZoomStripHeight = 38;

/// 窗口是否达到中等档（平板竖屏及以上宽度）
bool isMediumWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kMediumWidth;

/// 窗口尺寸是否达到展开档（平板横屏 / 桌面）
bool isExpandedSize(Size window) =>
    window.width >= kExpandedWidth && window.height >= kExpandedMinHeight;

/// 窗口是否达到展开档（平板横屏 / 桌面）
bool isExpandedWidth(BuildContext context) =>
    isExpandedSize(MediaQuery.sizeOf(context));

/// 中等档起给内容限宽并居中：列表、表单这类单列内容在平板上不再被拉到
/// 整屏宽（文字贴左、数字贴右隔着上千 dp）。
///
/// 紧凑档（手机竖屏）**原样返回 child，不包任何节点**——手机布局零影响。
class ContentWidth extends StatelessWidget {
  final Widget child;

  ///< 限宽的内容

  final double maxWidth;

  ///< 中等档起的最大内容宽度

  const ContentWidth({super.key, required this.child, this.maxWidth = 640});

  @override
  Widget build(BuildContext context) {
    if (!isMediumWidth(context)) {
      return child;
    }
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
