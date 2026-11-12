/// 拼豆板配置：板尺寸 + 加粗框线间隔与相位 + 粗线颜色 + 作品在板上的摆放偏移
///
/// 随作品 meta 持久化（一个作品一个进行中的拼豆会话，换配置覆盖）；
/// placed（拼装进度）是作品格索引，与板配置无关，重摆不清零
library;

class BoardConfig {
  static const int defaultMajorColor = 0xFFFF9800;

  ///< 粗框线默认颜色（橙——深色豆上压得住的亮色）
  static const int hiddenMajorColor = 0x00000000;

  ///< 粗框线「不显示」（全透明 ARGB，2026-11-12 十八轮）：与 null（默认
  ///< 橙）区分——interval 分块结构保留（拼豆页区块圈选仍按它分块），
  ///< 只是不画粗线；painter 侧按 alpha==0 跳过
  final int w;

  ///< 板宽（格）
  final int h;

  ///< 板高（格）
  final int interval;

  ///< 加粗框线间隔（每 N 格一条粗线）
  final int phaseX;

  ///< 竖粗线相位（0..interval-1，线 x 满足 (x+phaseX)%interval==0）
  final int phaseY;

  ///< 横粗线相位（0..interval-1，线 y 满足 (y+phaseY)%interval==0）
  final int? majorColor;

  ///< 粗框线颜色 ARGB（null = 默认橙；板配置页可选，随板持久化）
  final int ox;

  ///< 作品左上角在板上的列偏移
  final int oy;

  ///< 作品左上角在板上的行偏移
  final int rot;

  ///< 作品变换：顺时针 90° 步数（0-3）
  final bool flipH;

  ///< 作品变换：左右翻转
  final bool flipV;

  ///< 作品变换：上下翻转
  const BoardConfig({
    required this.w,
    required this.h,
    this.interval = 5,
    this.phaseX = 0,
    this.phaseY = 0,
    this.majorColor,
    this.ox = 0,
    this.oy = 0,
    this.rot = 0,
    this.flipH = false,
    this.flipV = false,
  });

  BoardConfig copyWith({
    int? w,
    int? h,
    int? interval,
    int? phaseX,
    int? phaseY,
    int? majorColor,
    int? ox,
    int? oy,
    int? rot,
    bool? flipH,
    bool? flipV,
  }) =>
      BoardConfig(
        w: w ?? this.w,
        h: h ?? this.h,
        interval: interval ?? this.interval,
        phaseX: phaseX ?? this.phaseX,
        phaseY: phaseY ?? this.phaseY,
        majorColor: majorColor ?? this.majorColor,
        ox: ox ?? this.ox,
        oy: oy ?? this.oy,
        rot: rot ?? this.rot,
        flipH: flipH ?? this.flipH,
        flipV: flipV ?? this.flipV,
      );

  Map<String, dynamic> toJson() => {
        "w": w,
        "h": h,
        "interval": interval,
        "phaseX": phaseX,
        "phaseY": phaseY,
        "majorColor": majorColor,
        "ox": ox,
        "oy": oy,
        "rot": rot,
        "flipH": flipH,
        "flipV": flipV,
      };

  static BoardConfig? fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return null;
    }
    return BoardConfig(
      w: json["w"] as int,
      h: json["h"] as int,
      interval: json["interval"] as int? ?? 5,
      phaseX: json["phaseX"] as int? ?? 0,
      phaseY: json["phaseY"] as int? ?? 0,
      majorColor: json["majorColor"] as int?,
      ox: json["ox"] as int? ?? 0,
      oy: json["oy"] as int? ?? 0,
      rot: json["rot"] as int? ?? 0,
      flipH: json["flipH"] as bool? ?? false,
      flipV: json["flipV"] as bool? ?? false,
    );
  }
}
