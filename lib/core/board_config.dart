/// 拼豆板配置：板尺寸 + 加粗框线间隔与相位 + 作品在板上的摆放偏移
///
/// 随作品 meta 持久化（一个作品一个进行中的拼豆会话，换配置覆盖）；
/// placed（拼装进度）是作品格索引，与板配置无关，重摆不清零
library;

class BoardConfig {
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
  final int ox;

  ///< 作品左上角在板上的列偏移
  final int oy;

  ///< 作品左上角在板上的行偏移
  const BoardConfig({
    required this.w,
    required this.h,
    this.interval = 5,
    this.phaseX = 0,
    this.phaseY = 0,
    this.ox = 0,
    this.oy = 0,
  });

  BoardConfig copyWith({
    int? w,
    int? h,
    int? interval,
    int? phaseX,
    int? phaseY,
    int? ox,
    int? oy,
  }) => BoardConfig(
    w: w ?? this.w,
    h: h ?? this.h,
    interval: interval ?? this.interval,
    phaseX: phaseX ?? this.phaseX,
    phaseY: phaseY ?? this.phaseY,
    ox: ox ?? this.ox,
    oy: oy ?? this.oy,
  );

  Map<String, dynamic> toJson() => {
    "w": w,
    "h": h,
    "interval": interval,
    "phaseX": phaseX,
    "phaseY": phaseY,
    "ox": ox,
    "oy": oy,
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
      ox: json["ox"] as int? ?? 0,
      oy: json["oy"] as int? ?? 0,
    );
  }
}
