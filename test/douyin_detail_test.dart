// 抖音无损通道 URL 提取回归（fixtures 为 2026-11-06 真实响应原样，
// 结构变化会先在这里红）。WebView 探测器是平台行为，不在单测覆盖。
//
// 通道演进（docs/douyin_lossless_channel.md）：detail API 在 WebView 内被
// 页面加固层扣住不放行，现通道改为「hydrate 后 DOM 提取 jpeg 签名 URL」，
// 本组测试锚定 URL→映射这一层（DOM 提取与 detail url_list 同构）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bead_studio/core/douyin_detail.dart';
import 'package:bead_studio/core/douyin_link.dart';

/// fixture detail JSON → url_list 平铺（与 DOM 提取产出同构的输入）
List<String> _urlListOf(String fixtureBody) {
  final obj = jsonDecode(fixtureBody) as Map;
  final detail = obj['aweme_detail'] as Map;
  final out = <String>[];
  for (final e in (detail['images'] as List).cast<Map>()) {
    out.addAll((e['url_list'] as List).whereType<String>());
  }
  return out;
}

void main() {
  final shuaqiUrls = _urlListOf(
    File('test/fixtures/douyin_detail_shuaqi.json').readAsStringSync(),
  );
  final nailongUrls = _urlListOf(
    File('test/fixtures/douyin_detail_nailong.json').readAsStringSync(),
  );

  group('mapJpegUrls（真实 fixture url_list，同构于 DOM 提取输入）', () {
    test('耍起：2 图，全为 jpeg 档，对象 id 与 SSR 对齐键同构', () {
      final jpegs = mapJpegUrls(shuaqiUrls);
      expect(jpegs, hasLength(2));
      for (final u in jpegs.values) {
        expect(u, contains('~tplv-dy-aweme-images:q75.jpeg'));
        expect(u, startsWith('https://'));
      }
      // 对象 id = 路径 `~` 前段（与 douyinObjectIdOf(SSR url) 同一键空间）
      for (final oid in jpegs.keys) {
        expect(oid, isNotEmpty);
        expect(oid, isNot(contains('~')));
        expect(douyinObjectIdOf(jpegs[oid]!), oid);
      }
    });

    test('奶龙：jpeg URL 与抓包真值一致（字节无损通道的 URL 级锚点）', () {
      final jpegs = mapJpegUrls(nailongUrls);
      expect(jpegs, hasLength(2));
      // manifest（.test/dy_flav/nailong_manifest.json）里 img0 jpeg 原样
      expect(
        jpegs['oUAwyzif9qEMGoEfC4DiHRFRAON0wA3ILZKAQA'],
        startsWith(
          'https://p9-pc-sign.douyinpic.com/tos-cn-i-0813c000-ce/'
          'oUAwyzif9qEMGoEfC4DiHRFRAON0wA3ILZKAQA~tplv-dy-aweme-images:q75.jpeg',
        ),
      );
    });

    test('同组只收首个 jpeg 档（webp/重复 URL 不产出）', () {
      final jpegs = mapJpegUrls([
        ...shuaqiUrls,
        // 重复注入一个不同 dir 的同对象 webp（SSR 跨通道 dir 不稳定的实况）
        shuaqiUrls.first.replaceAll(':q75.jpeg', ':q75.webp'),
      ]);
      expect(jpegs, hasLength(2));
    });

    test('空表/仅 webp 抛业务异常（SSR 兜底路径）', () {
      expect(() => mapJpegUrls(const []),
          throwsA(isA<DouyinLinkException>()));
      expect(
        () => mapJpegUrls(
          shuaqiUrls.map((u) => u.replaceAll(':q75.jpeg', ':q75.webp')).toList(),
        ),
        throwsA(isA<DouyinLinkException>()),
      );
    });

    test('头像/贴纸等非正文 URL 不产出', () {
      final jpegs = mapJpegUrls([
        ...shuaqiUrls,
        'https://p3.douyinpic.com/aweme/100x100/avatar.jpeg',
      ]);
      expect(jpegs, hasLength(2));
    });
  });

  group('douyinObjectIdOf', () {
    test('取路径 `~` 前段（dir 变化不影响）', () {
      const a = 'https://p3-pc-sign.douyinpic.com/tos-cn-i-0813c001/'
          'oYCVDE8IBX0FzCYSgifvAkAArizxA1AA572evu~tplv-dy-aweme-images:q75.jpeg?x=1';
      const b = 'https://p9-pc-sign.douyinpic.com/tos-cn-i-0813/'
          'oYCVDE8IBX0FzCYSgifvAkAArizxA1AA572evu~tplv-dy-aweme-images:q75.webp';
      expect(douyinObjectIdOf(a), 'oYCVDE8IBX0FzCYSgifvAkAArizxA1AA572evu');
      expect(douyinObjectIdOf(a), douyinObjectIdOf(b));
      expect(douyinObjectIdOf('not a url'), '');
    });
  });
}
