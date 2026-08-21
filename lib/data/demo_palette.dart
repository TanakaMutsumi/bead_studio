/// 演示调色板：40 色常用拼豆色系（色值为自拟近似值，仅用于开发验证）
///
/// 正式版应替换为实际采购珠子的实测色卡：
/// 拍标准光源下的珠子实物 -> 取中心区域均值 -> 写入 JSON 加载
library;

import '../core/palette.dart';

const demoPalette = BeadPalette([
  BeadColor("P01", "白色", 0xFFFFFF),
  BeadColor("P02", "奶白", 0xFAF4E8),
  BeadColor("P03", "奶油", 0xFFF4E3C1),
  BeadColor("P04", "柠檬黄", 0xFFF9E547),
  BeadColor("P05", "金黄", 0xF5C518),
  BeadColor("P06", "土黄", 0xD9A419),
  BeadColor("P07", "橙色", 0xF77C31),
  BeadColor("P08", "深橙", 0xE05A1B),
  BeadColor("P09", "红色", 0xE3242B),
  BeadColor("P10", "深红", 0xA31621),
  BeadColor("P11", "酒红", 0x6E0F1C),
  BeadColor("P12", "粉色", 0xF9A7C3),
  BeadColor("P13", "桃粉", 0xF47FB0),
  BeadColor("P14", "玫瑰粉", 0xE75480),
  BeadColor("P15", "肤色", 0xF5D3B8),
  BeadColor("P16", "深肤", 0xD9A066),
  BeadColor("P17", "浅棕", 0xB07A45),
  BeadColor("P18", "棕色", 0x7A4A2B),
  BeadColor("P19", "深棕", 0x4E342E),
  BeadColor("P20", "卡其", 0xBDB76B),
  BeadColor("P21", "军绿", 0x5D6E4E),
  BeadColor("P22", "草绿", 0x4CAF50),
  BeadColor("P23", "浅绿", 0xA8D77B),
  BeadColor("P24", "深绿", 0x226B3F),
  BeadColor("P25", "薄荷", 0x9FE2BF),
  BeadColor("P26", "湖蓝", 0x21A8B0),
  BeadColor("P27", "天蓝", 0x4FA8E8),
  BeadColor("P28", "蓝色", 0x2B57D6),
  BeadColor("P29", "深蓝", 0x1A3A9E),
  BeadColor("P30", "藏蓝", 0x101F55),
  BeadColor("P31", "紫色", 0x7B4FBF),
  BeadColor("P32", "深紫", 0x4A2C8A),
  BeadColor("P33", "丁香紫", 0xBFA8D9),
  BeadColor("P34", "浅灰", 0xC8C8C8),
  BeadColor("P35", "中灰", 0x909090),
  BeadColor("P36", "深灰", 0x4F4F4F),
  BeadColor("P37", "黑色", 0x1B1B1B),
  BeadColor("P38", "银色", 0xD9DDE3),
  BeadColor("P39", "金色", 0xC9A227),
  BeadColor("P40", "暗玫红", 0x8E3B57),
]);
