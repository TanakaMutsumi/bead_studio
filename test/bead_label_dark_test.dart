import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bead_studio/core/palette.dart';

/// 色号黑白字判定（beadLabelDark）：WCAG 对比度取高，取代旧亮度阈值
/// >150（会把 M2 类浅灰米色判深出白字——2026-11-10 用户反馈）。
/// 关键色逐一锁行为，防回归。
void main() {
  test('近白浅豆（H1/H2/T1/E16）黑字', () {
    // H2 = mard (251,251,251)：用户反馈「白字看不见」的主角，必须黑字
    expect(beadLabelDark(const Color.fromARGB(255, 251, 251, 251)), isTrue);
    expect(beadLabelDark(const Color.fromARGB(255, 255, 255, 255)), isTrue);
    expect(beadLabelDark(const Color.fromARGB(255, 247, 218, 212)), isTrue); // E11
    expect(beadLabelDark(const Color.fromARGB(255, 251, 244, 236)), isTrue); // E16
  });

  test('浅灰米色（M2/H20 类，旧阈值判深出白字的错分队）黑字', () {
    expect(beadLabelDark(const Color.fromARGB(255, 144, 153, 148)), isTrue); // M2 luma~150
    expect(beadLabelDark(const Color.fromARGB(255, 150, 160, 159)), isTrue); // H20
    expect(beadLabelDark(const Color.fromARGB(255, 154, 166, 166)), isTrue); // H15
  });

  test('深色豆白字', () {
    expect(beadLabelDark(const Color.fromARGB(255, 24, 88, 162)), isFalse); // C16 深蓝
    expect(beadLabelDark(const Color.fromARGB(255, 22, 45, 123)), isFalse); // D4 藏青
    expect(beadLabelDark(const Color.fromARGB(255, 225, 3, 40)), isFalse); // F5 正红
  });

  test('中间饱和色（中蓝/紫类）偏白字', () {
    expect(beadLabelDark(const Color.fromARGB(255, 57, 119, 202)), isFalse); // C7 中蓝 4.5 vs 4.7
    expect(beadLabelDark(const Color.fromARGB(255, 179, 78, 198)), isFalse); // D5 紫红
    // 对比 genuinely 更高的玫粉仍黑字（黑 6.7 vs 白 3.1，字更清楚优先）
    expect(beadLabelDark(const Color.fromARGB(255, 232, 100, 158)), isTrue); // E4
  });

  test('高亮压暗后的底色（深灰区）统一白字', () {
    // H2 压暗 0.75 → (104,112,124)；任何豆压到这个区间都该出白字
    expect(beadLabelDark(const Color.fromARGB(255, 104, 112, 124)), isFalse);
  });
}
