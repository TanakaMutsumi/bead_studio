import 'package:flutter/material.dart';

/// 标题自适应文本：先缩字号把整段放下（下限 [minScale]），仍放不下
/// 才退回省略号截断。
///
/// 2026-11-10 用户反馈：作品名/文件名稍长，AppBar 标题就被「…」截死
/// （编辑器、拼豆页、图片查看器、链接导入等处处如此）。普通做法
/// `maxLines:1 + ellipsis` 一律截；这里默认先等比缩字号——名字完整
/// 可读优先于字号恒定，只有缩到下限还放不下（超长文件名）才截断。
class AdaptiveTitleText extends StatelessWidget {
  const AdaptiveTitleText(
    this.text, {
    super.key,
    this.style,
    this.minScale = 0.62,

    ///< 字号缩放下限（默认标题字号的 62%，再小就不可读了）
    this.maxLines = 1,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;

  ///< 缩放下限之下的部分维持该字号并省略号截断
  final double minScale;
  final int maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || text.isEmpty) {
          return Text(text,
              style: effective, maxLines: maxLines, textAlign: textAlign);
        }
        // 量一下这段文本单行铺满要多宽
        final tp = TextPainter(
          text: TextSpan(text: text, style: effective),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: TextDirection.ltr,
          maxLines: maxLines,
        )..layout(maxWidth: double.infinity);
        final need = tp.width;
        if (need <= constraints.maxWidth) {
          return Text(text,
              style: effective, maxLines: maxLines, textAlign: textAlign);
        }
        final scale = constraints.maxWidth / need;
        if (scale >= minScale) {
          // 缩一点就能放下：等比缩，完整显示
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(text,
                style: effective, maxLines: maxLines, textAlign: textAlign),
          );
        }
        // 超长名：按下限字号渲染，余下部分省略号
        return Text(
          text,
          style: _scaled(effective, minScale),
          maxLines: maxLines,
          textAlign: textAlign,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }

  /// 字号相关的量一起缩（fontSize / height / letterSpacing / wordSpacing）
  static TextStyle _scaled(TextStyle s, double k) {
    // 取局部变量再判空：类属性不能空提升（getter 每次取值可能不同）
    final fs = s.fontSize;
    final hgt = s.height;
    final ls = s.letterSpacing;
    final ws = s.wordSpacing;
    return s.copyWith(
      fontSize: (fs ?? 16) * k,
      height: hgt == null ? null : hgt * k,
      letterSpacing: ls == null ? null : ls * k,
      wordSpacing: ws == null ? null : ws * k,
    );
  }
}
